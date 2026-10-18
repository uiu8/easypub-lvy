// 设置（D4-I，V8 按设计换视图外壳）：分类导航、分组卡片与开关行按设计重写；各分类内容与保存逻辑沿用原实现。
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/layout_service.dart';
import '../../application/cleanup_rule_resolution.dart';

import 'package:flutter/material.dart';

import 'automatic_rules_editor.dart';
import 'file_name_author_settings.dart';

import '../../application/settings_service.dart';
import '../../application/chapter_rules_service.dart';
import '../rules/rules_sheet.dart';
import '../../application/conversion_desktop.dart';
import '../../application/library_service.dart';
import '../../application/check_cache_service.dart';
import '../../application/app_info.dart';
import '../shell/workspace_leave.dart';
import '../app/update_prompt.dart';
import '../../application/parallel_books.dart';
import '../../application/crash_log_service.dart';
import '../errors.dart';
import '../controls/controls.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    this.desktop,
    this.picker,
    this.library,
    this.openFavorites,
    this.pageTitle,
    this.performanceScrollController,
    this.pickLegacyFile,
    this.appInfo = loadAppInfo,
  });

  /// 读取版本与本版更新（V22，SET-066）；测试可以替换。
  final Future<AppInfo> Function() appInfo;
  final SettingsService settings;
  final ConversionDesktop? desktop;
  final BookFilePicker? picker;
  final LibraryService? library;
  final VoidCallback? openFavorites;
  final ValueNotifier<String>? pageTitle;
  final ScrollController? performanceScrollController;
  final Future<String?> Function()? pickLegacyFile;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int tab = 0;
  final migrationPath = TextEditingController();
  String migrationResult = '';
  Map<String, dynamic>? migrationData;
  int migrationGeneration = 0;
  bool saving = false;
  String saveStatus = '修改后自动保存';
  String? desktopDirectory;
  bool probing = false;
  String? converterPath;
  bool kfxProbing = false;
  String? kfxPath;
  Map<String, dynamic>? backupInspection;

  /// 版本与本版更新（SET-066），进入页面时读取一次。
  AppInfo? info;

  /// 检查缓存的统计（SET-065）；进入“数据与迁移”时读取。
  CheckCachePreview? checkCache;
  bool checkCacheBusy = false;
  String checkCacheError = '';
  final _emptyFavorites = ValueNotifier<List<String>>(const []);

  /// 分区名称与各页标题一致（SET-062）；配置迁移并入“数据与迁移”，
  /// 设置的来源层级并入“关于与许可”。
  static const tabs = [
    '外观与交互',
    '导入与收藏',
    '成品与输出',
    '自动检查',
    '转换工具',
    '数据与迁移',
    '关于与许可',
  ];
  static const tabIcons = [
    Icons.palette_outlined,
    Icons.drive_folder_upload_outlined,
    Icons.output,
    Icons.fact_check_outlined,
    Icons.swap_horiz,
    Icons.restore,
    Icons.info_outline,
  ];
  @override
  void initState() {
    super.initState();
    // load() 一开始就会同步通知共享状态；放到首帧之后，避免在构建期间刷新其他页面
    // （从“变更记录”进入设置时，正在释放的记录页会收到通知而报错，V15）。
    widget.appInfo().then((value) {
      if (mounted) setState(() => info = value);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.settings.load().then((_) {
        if (!mounted) return;
        _probeBundledConverter();
        _probeBundledKfxConverter();
      });
    });
    final desktop = widget.desktop;
    if (desktop is OutputDirectoryDesktop) {
      (desktop as OutputDirectoryDesktop)
          .defaultOutputDirectory()
          .then((path) {
            if (mounted) setState(() => desktopDirectory = path);
          })
          .catchError((Object error) {
            if (mounted) setState(() => desktopDirectory = '桌面位置不可用，请选择文件夹');
          });
    }
  }

  Future<String?> _existingConverter(String? path) async {
    final desktop = widget.desktop;
    if (path == null) return null;
    if (desktop is ConverterFileDesktop &&
        !await (desktop as ConverterFileDesktop).converterExists(path)) {
      return null;
    }
    return path;
  }

  Future<void> _probeBundledConverter() async {
    final desktop = widget.desktop;
    if (desktop == null) return;
    setState(() => probing = true);
    try {
      final configured =
          (widget.settings.snapshot.value.configuration['kindle_converter']
                      as String? ??
                  '')
              .trim();
      final path = configured.isNotEmpty
          ? configured
          : await desktop.bundledConverter();
      final existing = await _existingConverter(path);
      if (mounted) setState(() => converterPath = existing);
    } catch (_) {
      if (mounted) setState(() => converterPath = null);
    } finally {
      if (mounted) setState(() => probing = false);
    }
  }

  Future<void> _chooseKfxConverter() async {
    try {
      final path = await widget.desktop?.chooseConverter();
      if (path != null && mounted) {
        await save({'kfx_converter': path});
        if (mounted) await _probeBundledKfxConverter();
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _probeBundledKfxConverter() async {
    final desktop = widget.desktop;
    if (desktop is! KfxConversionDesktop) return;
    setState(() => kfxProbing = true);
    try {
      final configured =
          (widget.settings.snapshot.value.configuration['kfx_converter']
                      as String? ??
                  '')
              .trim();
      final path = configured.isNotEmpty
          ? configured
          : await (desktop as KfxConversionDesktop).bundledKfxConverter();
      final existing = await _existingConverter(path);
      if (mounted) setState(() => kfxPath = existing);
    } catch (_) {
      if (mounted) setState(() => kfxPath = null);
    } finally {
      if (mounted) setState(() => kfxProbing = false);
    }
  }

  Future<void> _chooseConverter() async {
    final desktop = widget.desktop;
    if (desktop == null || probing) return;
    try {
      final path = await desktop.chooseConverter();
      if (path != null && mounted) {
        await save({'kindle_converter': path});
        if (mounted) await _probeBundledConverter();
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _chooseOutputDirectory() async {
    final picker = widget.picker;
    if (picker == null || saving) return;
    final path = await picker.chooseFolder();
    if (path == null || !mounted) return;
    await save({'output_directory': path});
  }

  Future<void> _chooseImportDirectory() async {
    final picker = widget.picker;
    if (picker == null || saving) return;
    final path = await picker.chooseFolder();
    if (path == null || !mounted) return;
    await save({'import_directory': path});
  }

  Future<void> _addFavorite() async {
    final picker = widget.picker;
    final library = widget.library;
    if (picker == null || library == null || saving) return;
    final path = await picker.chooseFolder();
    if (path == null || !mounted) return;
    if (!await library.setFavorite(path, true) && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('收藏文件夹保存失败，当前列表未改变。')));
    }
  }

  Future<void> _favoriteAction(String path, String action) async {
    final library = widget.library;
    if (library == null || saving) return;
    setState(() => saving = true);
    try {
      bool ok = true;
      if (action == 'rename') {
        var value = library.favoriteName(path);
        final name = await showDialog<String>(
          context: context,
          builder: (dialogContext) => DeskAlert(
            title: const Text('重命名收藏'),
            content: TextFormField(
              key: const ValueKey('settings-favorite-name'),
              initialValue: value,
              autofocus: true,
              decoration: const InputDecoration(labelText: '收藏名称'),
              onChanged: (next) => value = next,
              onFieldSubmitted: (next) => Navigator.pop(dialogContext, next),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, value),
                child: const Text('保存名称'),
              ),
            ],
          ),
        );
        if (name == null || !mounted) return;
        ok = await library.renameFavorite(path, name);
      } else if (action == 'relocate') {
        final next = await widget.picker?.chooseFolder();
        if (next == null || !mounted) return;
        ok = await library.relocateFavorite(path, next);
      } else if (action == 'remove') {
        ok = await library.setFavorite(path, false);
      }
      if (!ok && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('收藏修改未能保存，原设置保留。')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('收藏操作失败，请重试。')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _openFavorite(String path) async {
    try {
      await widget.desktop?.openDirectory(path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开该收藏文件夹。')));
      }
    }
  }

  /// 在应用内显示一段文本（完整说明、崩溃日志），不调用外部程序。
  Future<void> _showText(String title, String text) => showDialog<void>(
    context: context,
    builder: (dialogContext) => DeskDialog(
      title: title,
      closeTooltip: '关闭',
      width: 720,
      onClose: () => Navigator.pop(dialogContext),
      actions: [
        DeskButton('关闭', onPressed: () => Navigator.pop(dialogContext)),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: mono(12, c: dialogContext.desk.ink),
          ),
        ),
      ),
    ),
  );

  /// 版本与更新（V68，SET-071–073）：检查、下载、重启更新与回退；没有更新服务时不显示。
  List<Widget> _updateGroup() {
    if (AppUpdateScope.maybeOf(context) == null) return const [];
    final library = widget.library, picker = widget.picker;
    return [
      groupTitle('版本与更新', ''),
      settingCard(
        UpdateSettingsGroup(
          leave: library == null || picker == null
              ? () async => true
              : () => confirmWorkspaceLeave(
                  context,
                  library,
                  picker,
                  action: '重启更新',
                ),
        ),
      ),
    ];
  }

  /// 本版更新（SET-066）：摘自包内说明；开发版本不显示。
  List<Widget> _releaseNotesGroup() {
    final current = info;
    if (current == null || !current.packaged || current.releaseNotes.isEmpty) {
      return const [];
    }
    final d = context.desk;
    return [
      groupTitle('本版更新', '摘自包内“${current.notesName}”。'),
      settingCard(
        Column(
          key: const ValueKey('settings-release-notes'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current.releaseNotes.join('\n'),
              style: ui(12.5, c: d.ink2, h: 1.6),
            ),
            const SizedBox(height: 6),
            DeskButton(
              '查看完整说明',
              key: const ValueKey('settings-release-notes-full'),
              quiet: true,
              onPressed: () => _showText(current.notesName, current.notesText),
            ),
          ],
        ),
      ),
    ];
  }

  /// 崩溃日志（SET-067）：只读，保存在本机设置目录。
  List<Widget> _crashLogGroup() {
    final service = widget.settings is CrashLogService
        ? widget.settings as CrashLogService
        : null;
    if (service == null) return const [];
    final d = context.desk;
    final logs = service.crashLogs();
    String two(int v) => v.toString().padLeft(2, '0');
    final latest = logs.firstOrNull;
    final directory = service.crashLogDirectory;
    return [
      groupTitle('崩溃日志', '程序意外出错时自动记录在本机设置目录，不会上传；最多保留 50 份。'),
      settingCard(
        Row(
          key: const ValueKey('settings-crash-logs'),
          children: [
            Expanded(
              child: Text(
                latest == null
                    ? '还没有崩溃记录。'
                    : '共 ${logs.length} 份 · 最近一次 ${two(latest.time.month)}-${two(latest.time.day)} ${two(latest.time.hour)}:${two(latest.time.minute)}',
                style: ui(12.5, c: d.ink2),
              ),
            ),
            if (directory != null && widget.desktop != null && latest != null)
              DeskButton(
                '打开文件夹',
                key: const ValueKey('settings-crash-logs-folder'),
                quiet: true,
                onPressed: () async {
                  try {
                    await widget.desktop!.openDirectory(directory);
                  } catch (error) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          deskErrorText(error, '未能打开崩溃日志文件夹：$error'),
                        ),
                      ),
                    );
                  }
                },
              ),
            if (latest != null) ...[
              const SizedBox(width: 8),
              DeskButton(
                '查看最近一份',
                key: const ValueKey('settings-crash-logs-latest'),
                quiet: true,
                onPressed: () async {
                  String text;
                  try {
                    text = await service.readCrashLog(latest);
                  } catch (error) {
                    text = '读取失败：$error';
                  }
                  if (mounted) await _showText('最近一份崩溃日志', text);
                },
              ),
            ],
          ],
        ),
      ),
    ];
  }

  CheckCacheService? get _checkCacheService =>
      widget.settings is CheckCacheService
      ? widget.settings as CheckCacheService
      : null;

  Future<void> _loadCheckCache() async {
    final service = _checkCacheService;
    if (service == null || checkCacheBusy) return;
    setState(() {
      checkCacheBusy = true;
      checkCacheError = '';
    });
    try {
      final preview = await service.previewCheckCacheCleanup();
      if (mounted) setState(() => checkCache = preview);
    } catch (error) {
      if (mounted) {
        setState(
          () => checkCacheError = deskErrorText(error, '检查缓存统计失败：$error'),
        );
      }
    } finally {
      if (mounted) setState(() => checkCacheBusy = false);
    }
  }

  /// 清理检查缓存（CHK-061）：先列出将删除的份数与大小，确认后才删除。
  Future<void> _cleanCheckCache() async {
    final service = _checkCacheService;
    final preview = checkCache;
    if (service == null || preview == null || checkCacheBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => DeskAlert(
        title: const Text('清理检查缓存？'),
        content: Text(
          [
            '将删除 ${preview.removable} 份（${formatFileSize(preview.removableBytes)}）：',
            if (preview.unattributed > 0)
              '· 旧版本、无法归属到书的 ${preview.unattributed} 份',
            if (preview.older > 0) '· 各书更早的结果 ${preview.older} 份',
            '保留 ${preview.kept} 份：书库中每本书的当前稿与上一稿，以及其他项目中的书各自最近两份。',
            '只删除 check-reports 中的缓存文件，不碰书稿；删除后重新检查即可。',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('settings-check-cache-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('删除 ${preview.removable} 份'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => checkCacheBusy = true);
    CheckCacheCleanupResult? result;
    String failure = '';
    try {
      result = await service.cleanCheckCache(preview);
    } catch (error) {
      failure = deskErrorText(error, '检查缓存清理失败：$error');
    } finally {
      if (mounted) setState(() => checkCacheBusy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == null
              ? failure
              : '已删除 ${result.deleted} 份检查缓存（${formatFileSize(result.bytes)}）'
                    '${result.skipped > 0 ? '；${result.skipped} 份在统计后发生了变化，没有删除' : ''}。',
        ),
      ),
    );
    await _loadCheckCache();
  }

  List<Widget> _checkCacheGroup() {
    final d = context.desk;
    final preview = checkCache;
    if (preview == null &&
        !checkCacheBusy &&
        checkCacheError.isEmpty &&
        _checkCacheService != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadCheckCache();
      });
    }
    String two(int v) => v.toString().padLeft(2, '0');
    final last = preview?.lastCleanup;
    Widget tile(String label, String value, String key) => Expanded(
      child: Container(
        key: ValueKey('settings-check-cache-$key'),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: d.sunken,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: ui(11.5, c: d.ink3)),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(13, c: d.ink),
            ),
          ],
        ),
      ),
    );
    return [
      const SizedBox(height: 10),
      groupTitle(
        '检查缓存',
        '检查结果的缓存，只用于更快显示上次检查；删除后重新检查即可，不影响书稿。'
            '每本书保留当前稿和上一稿的结果；其他项目中的书各保留最近两份。只在你点“清理…”时删除。',
      ),
      if (_checkCacheService == null)
        Text('当前运行环境没有检查缓存。', style: ui(12, c: d.ink3))
      else ...[
        Row(
          children: [
            tile(
              '缓存',
              preview == null
                  ? (checkCacheBusy ? '正在统计…' : '—')
                  : '${preview.total} 份 · ${formatFileSize(preview.totalBytes)}',
              'total',
            ),
            const SizedBox(width: 8),
            tile(
              '可清理',
              preview == null
                  ? '—'
                  : '${preview.removable} 份 · ${formatFileSize(preview.removableBytes)}',
              'removable',
            ),
            const SizedBox(width: 8),
            tile(
              '上次清理',
              last == null
                  ? (preview == null ? '—' : '还没有清理过')
                  : '${two(last.at.month)}-${two(last.at.day)} · ${last.deleted} 份',
              'last',
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (checkCacheError.isNotEmpty) ...[
          Text(checkCacheError, style: ui(12, c: d.pen, h: 1.5)),
          const SizedBox(height: 8),
        ],
        actionRow([
          DeskButton(
            '清理…',
            key: const ValueKey('settings-check-cache-clean'),
            icon: Icons.cleaning_services_outlined,
            onPressed:
                checkCacheBusy || preview == null || preview.removable == 0
                ? null
                : _cleanCheckCache,
          ),
          DeskButton(
            '重新统计',
            key: const ValueKey('settings-check-cache-refresh'),
            quiet: true,
            onPressed: checkCacheBusy ? null : _loadCheckCache,
          ),
        ]),
        const SizedBox(height: 12),
      ],
    ];
  }

  Future<void> _backupSettings() async {
    final picker = widget.picker;
    final backup = widget.settings is SettingsBackupService
        ? widget.settings as SettingsBackupService
        : null;
    if (picker == null || backup == null || saving) return;
    final destination = await picker.chooseFolder();
    if (destination == null || !mounted) return;
    final ok = await save({'backup_directory': destination});
    if (!ok && mounted) return;
    if (!mounted) return;
    setState(() {
      saving = true;
      saveStatus = '正在创建备份…';
    });
    String? path;
    try {
      path = await backup.createBackup(destination);
    } catch (_) {
      path = null;
    } finally {
      if (mounted) {
        setState(() {
          saving = false;
          saveStatus = path == null ? '备份失败，请重试' : '已自动保存';
        });
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(path == null ? '设置备份失败，当前设置未改变。' : '设置已备份到 $path'),
        ),
      );
    }
  }

  Future<void> _restoreSettings() async {
    final picker = widget.picker;
    final backup = widget.settings is SettingsBackupService
        ? widget.settings as SettingsBackupService
        : null;
    if (picker == null || backup == null || saving) return;
    final path = await picker.chooseFolder();
    if (path == null || !mounted) return;
    if (!mounted) return;
    setState(() {
      saving = true;
      saveStatus = '正在读取备份…';
    });
    Map<String, dynamic>? inspection;
    try {
      inspection = await backup.inspectBackup(path);
    } catch (_) {
      inspection = null;
    } finally {
      if (mounted) {
        setState(() {
          saving = false;
          saveStatus = inspection == null ? '备份读取失败' : '已自动保存';
        });
      }
    }
    if (!mounted) return;
    if (inspection == null) {
      setState(() => backupInspection = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('备份读取失败，当前设置未改变。')));
      return;
    }
    setState(() => backupInspection = inspection);
    final fields =
        (inspection['fields'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => DeskAlert(
        title: const Text('确认恢复设置'),
        content: Text('备份包含 ${fields.length} 组设置字段。确认后会写入新的设置代际，当前书稿和成品不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!mounted) return;
    setState(() {
      saving = true;
      saveStatus = '正在恢复设置…';
    });
    bool ok;
    try {
      ok = await backup.restoreBackup(path);
    } catch (_) {
      ok = false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
    if (!mounted) return;
    if (ok) {
      await widget.settings.load();
      if (!mounted) return;
      setState(() => backupInspection = null);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '设置已恢复，当前书稿和成品未修改。' : '恢复失败，当前设置未改变。')),
    );
  }

  Future<void> _resetAppearance() async {
    await save({
      'ui_theme': 'paper',
      'ui_scale': 1.0,
      'ui_density': 'standard',
      'ui_follow_system_scale': true,
      'reduced_motion': false,
      'restore_window': true,
    });
  }

  Future<void> _resetCurrentTab() async {
    switch (tab) {
      case 0:
        return _resetAppearance();
      case 1:
        await save({
          'import_recursive': false,
          'check_after_import': true,
          'import_directory': '',
          'default_language': 'zh-CN',
        });
      case 2:
        await save({
          'output_format': 'EPUB',
          'output_directory': '',
          'output_collision_policy': 'preserve',
          'output_naming': 'title',
          'epub_conversion_mode': 'layout',
          'parallel_books': 'auto',
          'generate_cover': true,
          'show_output_acceptance': true,
          'attach_conversion_report': true,
        });
      case 3:
        await save({
          'automatic_cleanup_pipeline': null,
          'automatic_cleanup_rules': [
            for (final rule in defaultCleanupPipeline) rule['kind'],
          ],
        });
      default:
        await save({});
    }
  }

  Future<void> _openLicense(String category) async {
    final desktop = widget.desktop;
    if (desktop == null || desktop is! LicenseDesktop) return;
    final licenseDesktop = desktop as LicenseDesktop;
    try {
      final path = await licenseDesktop.licenseDirectory(category);
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前运行目录没有附带这类许可文件。')));
        return;
      }
      await desktop.openDirectory(path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开许可目录。')));
      }
    }
  }

  @override
  void dispose() {
    migrationPath.dispose();
    _emptyFavorites.dispose();
    super.dispose();
  }

  Future<bool> save(Map<String, dynamic> patch) async {
    if (saving) return false;
    setState(() {
      saving = true;
      saveStatus = '正在保存…';
    });
    var ok = false;
    try {
      ok = await widget.settings.savePatch(patch);
      if (mounted) {
        setState(() => saveStatus = ok ? '已自动保存' : '保存失败，请重试刚才的更改');
      }
      if (mounted && !ok) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存失败，原设置保持不变。')));
      }
    } catch (_) {
      if (mounted) setState(() => saveStatus = '保存失败，请重试刚才的更改');
    } finally {
      if (mounted) setState(() => saving = false);
    }
    return ok;
  }

  // 分区只留标题；说明一律收进各组标题旁的“?”（SET-068）。
  Widget section(String title, List<Widget> children) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
          child: Text(title, style: ui(18, w: 650, c: d.ink)),
        ),
        Expanded(
          child: DeskScrollView(
            key: ValueKey(tab),
            controller: widget.performanceScrollController,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
        if (tab <= 3)
          Container(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: d.line)),
            ),
            child: actionRow([
              DeskButton(
                '恢复本页默认…',
                icon: Icons.restart_alt_rounded,
                onPressed: saving ? null : _resetCurrentTab,
                quiet: true,
              ),
            ]),
          ),
      ],
    );
  }

  Widget toggle(
    SettingsSnapshot state,
    String label,
    String detail,
    String key,
    bool value,
  ) {
    final d = context.desk;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: saving ? null : () => save({key: !value}),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: d.line)),
          ),
          child: Row(
            children: [
              // 文字与问号占满剩余宽度，开关始终靠右（V43，SET-070）。
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(label, style: ui(13, c: d.ink)),
                    ),
                    if (detail.isNotEmpty) DeskHelp(detail),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: value,
                onChanged: saving ? null : (next) => save({key: next}),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget groupTitle(String title, String detail) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(title, style: ui(13.5, w: 650, c: d.ink)),
              ),
              if (detail.isNotEmpty)
                DeskHelp(detail, key: ValueKey('settings-help-$title')),
            ],
          ),
        ],
      ),
    );
  }

  Widget settingCard(Widget child, {Color? color}) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: color ?? d.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }

  Widget valueField(String label, String value, {IconData? icon}) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Text(label, style: ui(13, c: d.ink)),
          const SizedBox(width: 16),
          Expanded(
            child: Tooltip(
              message: value,
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: ui(13, c: d.ink2),
              ),
            ),
          ),
          if (icon != null) ...[
            const SizedBox(width: 6),
            Icon(icon, size: 16, color: d.ink3),
          ],
        ],
      ),
    );
  }

  Widget note(String title, String detail, {bool warning = false}) =>
      DeskNote(detail, title: title, tone: warning ? Tone.warn : Tone.neutral);

  Widget actionRow(List<Widget> children) => Wrap(
    spacing: 10,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );

  Widget readOnlyRow(
    String title, {
    IconData icon = Icons.check_circle_outline,
  }) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Icon(icon, color: d.ink2, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title, style: ui(13, c: d.ink)),
          ),
          const DeskTag('必需', Tone.neutral),
        ],
      ),
    );
  }

  Widget body(SettingsSnapshot state) => switch (tab) {
    0 => section('外观与交互', [
      valueField('主题', '宣纸'),
      const SizedBox(height: 12),
      // 主题色（V69，G-072）：点色块立即生效并保存。
      Row(
        key: const ValueKey('settings-accent'),
        children: [
          Expanded(
            child: Text('主题色', style: ui(13, c: context.desk.ink)),
          ),
          for (final a in deskAccents)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: a.label,
                child: Semantics(
                  button: true,
                  selected:
                      deskAccentOf(state.configuration['ui_accent']).id == a.id,
                  label: '主题色：${a.label}',
                  child: InkWell(
                    key: ValueKey('settings-accent-${a.id}'),
                    customBorder: const CircleBorder(),
                    onTap: saving ? null : () => save({'ui_accent': a.id}),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: a.accent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color:
                              deskAccentOf(state.configuration['ui_accent'])
                                      .id ==
                                  a.id
                              ? context.desk.ink
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child:
                          deskAccentOf(state.configuration['ui_accent']).id ==
                              a.id
                          ? Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: a.onAccent,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      DeskChoice<double>(
        key: ValueKey(state.configuration['ui_scale']),
        initialValue:
            (state.configuration['ui_scale'] as num?)?.toDouble() ?? 1,
        decoration: const InputDecoration(labelText: '应用文字比例'),
        items: const [
          DropdownMenuItem(value: 1, child: Text('标准 · 100%')),
          DropdownMenuItem(value: 1.15, child: Text('较大 · 115%')),
          DropdownMenuItem(value: 1.3, child: Text('大 · 130%')),
          DropdownMenuItem(value: 1.5, child: Text('特大 · 150%')),
        ],
        onChanged: saving
            ? null
            : (v) {
                if (v != null) save({'ui_scale': v});
              },
      ),
      toggle(
        state,
        '跟随系统文字大小',
        '应用比例在系统文字大小基础上调整',
        'ui_follow_system_scale',
        state.configuration['ui_follow_system_scale'] != false,
      ),
      DeskChoice<String>(
        value: state.configuration['ui_density'] as String? ?? 'standard',
        decoration: const InputDecoration(labelText: '控件密度'),
        items: const [
          DropdownMenuItem(value: 'standard', child: Text('标准')),
          DropdownMenuItem(value: 'compact', child: Text('紧凑')),
        ],
        onChanged: saving
            ? null
            : (value) {
                if (value != null) save({'ui_density': value});
              },
      ),
      toggle(
        state,
        '减少动画',
        '系统已减少动画时始终遵循',
        'reduced_motion',
        state.reducedMotion,
      ),
      toggle(
        state,
        '恢复上次窗口大小与位置',
        '',
        'restore_window',
        state.configuration['restore_window'] != false,
      ),
    ]),
    1 => section('导入与收藏', [
      groupTitle('章节识别', '管理以后导入默认；已有书籍在章节页预览重新识别。'),
      if (widget.library is ChapterRulesService)
        Align(
          alignment: Alignment.centerLeft,
          child: DeskButton(
            '识别规则与预设',
            icon: Icons.rule,
            onPressed: () => showChapterRulesDialog(
              context,
              service: widget.library as ChapterRulesService,
            ),
          ),
        ),
      groupTitle('默认导入位置', '导入创建工作引用或工作副本；不会移动或覆盖原文件。'),
      Row(
        children: [
          Expanded(
            child: valueField(
              '打开文件时使用',
              (state.configuration['import_directory'] as String?) ??
                  '上次访问的文件夹',
              icon: Icons.folder_open,
            ),
          ),
          const SizedBox(width: 10),
          DeskButton(
            '选择文件夹…',
            icon: Icons.folder_open,
            onPressed: widget.picker == null ? null : _chooseImportDirectory,
          ),
        ],
      ),
      const SizedBox(height: 14),
      groupTitle('收藏文件夹', ''),
      ValueListenableBuilder<List<String>>(
        valueListenable: widget.library?.favoriteFolders ?? _emptyFavorites,
        builder: (context, folders, _) => settingCard(
          folders.isEmpty
              ? ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.folder_off_outlined),
                  title: DeskText('尚未收藏文件夹'),
                )
              : SizedBox(
                  height: folders.length.clamp(1, 4) * 72.0,
                  child: ListView.separated(
                    primary: false,
                    itemCount: folders.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, index) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_outlined),
                      title: DeskText(
                        widget.library!.favoriteName(folders[index]),
                        bold: true,
                        lines: 1,
                      ),
                      subtitle: Tooltip(
                        message: folders[index],
                        child: DeskText(
                          folders[index],
                          size: 12,
                          color: context.desk.ink2,
                          lines: 1,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DeskButton(
                            '浏览',
                            onPressed: widget.desktop == null
                                ? null
                                : () => _openFavorite(folders[index]),
                            quiet: true,
                          ),
                          DeskCommandMenu<String>(
                            tooltip: '收藏操作',
                            enabled: !saving,
                            onSelected: (action) =>
                                _favoriteAction(folders[index], action),
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                height: 36,
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              PopupMenuItem(
                                height: 36,
                                value: 'relocate',
                                enabled: widget.picker != null,
                                child: const Text('重新定位'),
                              ),
                              const PopupMenuItem(
                                height: 36,
                                value: 'remove',
                                child: Text('取消收藏'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
      actionRow([
        DeskButton(
          '添加收藏',
          icon: Icons.star_outline,
          onPressed: widget.library == null ? null : _addFavorite,
        ),
        DeskButton('管理收藏', onPressed: widget.openFavorites, quiet: true),
      ]),
      toggle(
        state,
        '递归扫描子文件夹',
        '',
        'import_recursive',
        state.configuration['import_recursive'] == true,
      ),
      toggle(
        state,
        '导入后检查章节识别结果',
        '检查不修改正文；问题显示在章节工作台',
        'check_after_import',
        state.configuration['check_after_import'] != false,
      ),
      // 从文件名提取作者（V72，LIB-116）。
      FileNameAuthorSettings(
        configuration: state.configuration,
        saving: saving,
        save: save,
      ),
      DeskChoice<String>(
        key: ValueKey(
          'language-${state.configuration['default_language']}-$saving',
        ),
        isExpanded: true,
        initialValue:
            state.configuration['default_language'] as String? ?? 'zh-CN',
        decoration: const InputDecoration(labelText: '缺少语言信息时使用'),
        items: const [
          DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
          DropdownMenuItem(value: 'zh-TW', child: Text('繁体中文')),
          DropdownMenuItem(value: 'en', child: Text('英语')),
          DropdownMenuItem(value: 'ja', child: Text('日语')),
        ],
        onChanged: saving ? null : (value) => save({'default_language': value}),
      ),
    ]),
    2 => section('成品与输出', [
      groupTitle('默认输出格式', ''),
      // KFX 需要的 Bokai 在“转换工具”中管理，这里只在 KFX 选项下注明（SET-063）。
      DeskFormGrid(
        columns: 4,
        minColumnWidth: 150,
        children: [
          for (final item in [
            ('EPUB', '通用阅读器'),
            ('AZW3', 'Kindle 本地传书'),
            ('MOBI', '兼容输出'),
            ('KFX', 'Kindle 增强排版 · 需要 Bokai，见转换工具'),
          ])
            InkWell(
              onTap: saving ? null : () => save({'output_format': item.$1}),
              borderRadius: BorderRadius.circular(8),
              child: settingCard(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: DeskText(item.$1, bold: true)),
                        Icon(
                          ((state.configuration['output_format'] as String?) ??
                                      'EPUB') ==
                                  item.$1
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color:
                              ((state.configuration['output_format']
                                          as String?) ??
                                      'EPUB') ==
                                  item.$1
                              ? context.desk.accent
                              : context.desk.ink2,
                          size: 19,
                        ),
                      ],
                    ),
                    DeskText(item.$2, size: 12, color: context.desk.ink2),
                  ],
                ),
                color:
                    ((state.configuration['output_format'] as String?) ??
                            'EPUB') ==
                        item.$1
                    ? context.desk.accentSoft
                    : context.desk.surface,
              ),
            ),
        ],
      ),
      // 同时处理的书（V38，SET-069）：导入、书库检查、转换前检查与转换共用。
      const SizedBox(height: 14),
      groupTitle(
        '同时处理的书',
        '导入、书库检查、转换前检查和转换时，同时处理几本书。本数越多越快，也越占内存：'
            '普通小说转换时每本约 40–60 MB，特别长或插图很多的书约 100–200 MB。'
            '选 1 本与以前相同，逐本处理；处理结果与逐本处理完全一样。',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: KeyedSubtree(
          key: const ValueKey('settings-parallel_books'),
          child: DeskSegmented<String>(
            value: (state.configuration['parallel_books'] as String?) ?? 'auto',
            options: parallelBookChoices,
            onChanged: saving
                ? null
                : (value) => save({'parallel_books': value}),
          ),
        ),
      ),
      const SizedBox(height: 4),
      DeskText(
        '本机 ${logicalProcessors()} 个逻辑处理器 · 自动为 ${autoParallelBooks()} 本',
        key: const ValueKey('settings-parallel-books-note'),
        size: 11.5,
        color: context.desk.ink3,
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: valueField(
              '默认成品文件夹',
              (state.configuration['output_directory'] as String? ?? '')
                      .trim()
                      .isEmpty
                  ? desktopDirectory ?? '桌面（默认）'
                  : state.configuration['output_directory'] as String,
            ),
          ),
          const SizedBox(width: 10),
          DeskButton(
            '浏览…',
            icon: Icons.folder_open,
            onPressed: widget.picker == null ? null : _chooseOutputDirectory,
          ),
        ],
      ),
      const SizedBox(height: 12),
      DeskFormGrid(
        children: [
          DeskChoice<String>(
            key: ValueKey(
              'collision-${state.configuration['output_collision_policy']}-$saving',
            ),
            isExpanded: true,
            initialValue:
                (state.configuration['output_collision_policy'] as String?) ??
                'preserve',
            decoration: const InputDecoration(labelText: '同名文件处理'),
            items: const [
              DropdownMenuItem(value: 'preserve', child: Text('保留并编号')),
              DropdownMenuItem(value: 'ask', child: Text('每次询问')),
            ],
            onChanged: saving
                ? null
                : (value) => value == null
                      ? null
                      : save({'output_collision_policy': value}),
          ),
          DeskChoice<String>(
            key: ValueKey(
              'naming-${state.configuration['output_naming']}-$saving',
            ),
            isExpanded: true,
            initialValue:
                (state.configuration['output_naming'] as String?) ?? 'title',
            decoration: const InputDecoration(labelText: '命名方式'),
            items: const [
              DropdownMenuItem(value: 'title_author', child: Text('书名·作者')),
              DropdownMenuItem(value: 'title', child: Text('仅书名')),
              DropdownMenuItem(value: 'filename', child: Text('原文件名')),
            ],
            onChanged: saving
                ? null
                : (value) =>
                      value == null ? null : save({'output_naming': value}),
          ),
          // EPUB 的默认转换路径（V27，OUT-080）；转换页每本书还可以单独切换。
          DeskChoice<String>(
            key: ValueKey(
              'epub-mode-${state.configuration['epub_conversion_mode']}-$saving',
            ),
            isExpanded: true,
            initialValue:
                (state.configuration['epub_conversion_mode'] as String?) ??
                'layout',
            decoration: const InputDecoration(labelText: 'EPUB 原稿转换'),
            items: const [
              DropdownMenuItem(value: 'layout', child: Text('使用软件排版')),
              DropdownMenuItem(value: 'original', child: Text('保持原格式')),
            ],
            onChanged: saving
                ? null
                : (value) => value == null
                      ? null
                      : save({'epub_conversion_mode': value}),
          ),
        ],
      ),
      const SizedBox(height: 12),
      settingCard(
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.insert_drive_file_outlined),
          title: DeskText(
            '文件名示例：${switch (state.configuration['output_naming']) {
              'title_author' => '书名 - 作者',
              'filename' => '原文件名',
              _ => '书名',
            }}.${((state.configuration['output_format'] as String?) ?? 'EPUB').toLowerCase()}',
            bold: true,
          ),
          trailing: const DeskHelp('同名文件默认保留，转换任务会生成新的目标文件。'),
        ),
      ),
      const Divider(height: 24),
      const SizedBox(height: 12),
      toggle(
        state,
        '缺少封面时生成文字封面',
        '使用当前书名与作者，转换前可预览',
        'generate_cover',
        state.configuration['generate_cover'] != false,
      ),
      if ((state.configuration['output_format'] as String?) == 'MOBI')
        note('MOBI 转换器', '默认使用随包 Kindling，可在转换工具中选择其他已支持的转换器。', warning: true),
    ]),
    3 => section('自动检查', [
      if (state.status.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DeskText(state.status, size: 12, color: context.desk.ink2),
        ),
      groupTitle(
        '始终执行',
        '保护成品生成流程，不能关闭。\n'
            '· 文件与输出位置：原稿可读、路径可写、同名冲突处理明确\n'
            '· 格式与转换器：所选格式受支持，外部工具已通过可用性检测\n'
            '· 元信息与资源：语言、封面要求及被引用资源符合输出约束\n'
            '· 章节结构与编号：入库时检查跳号、回退、重复标题与层级；修改后原结果标记过期\n'
            '问题不等于结论：跳号不能证明正文缺失；自动检查不会擅自补章、重排或改号。',
      ),
      settingCard(readOnlyRow('文件与输出位置 · 格式与转换器 · 元信息与资源 · 章节结构与编号')),
      const SizedBox(height: 14),
      groupTitle('文本清理检测', '入库后按勾选规则检测；清理前可查看原稿与差异。'),
      AutomaticRulesEditor(
        loadPresets: widget.settings is CleanupPresetCatalog
            ? (widget.settings as CleanupPresetCatalog).cleanupPresets
            : null,
        configuration: state.configuration,
        save: save,
        busy: saving,
      ),
    ]),
    4 => section('转换工具', [
      settingCard(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, color: context.desk.accent),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [DeskText('EPUB', size: 18, bold: true)],
                  ),
                ),
                Chip(label: Text('随应用提供')),
              ],
            ),
            const SizedBox(height: 14),
            valueField('工具位置', '使用内置模块', icon: Icons.folder_outlined),
          ],
        ),
      ),
      const SizedBox(height: 12),
      settingCard(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, color: context.desk.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          DeskText('KFX / Bokai', size: 18, bold: true),
                          const DeskHelp('KFX 转换会实际调用 Bokai，并在任务中显示运行结果。'),
                        ],
                      ),
                      DeskText(
                        '独立 KFX 生成器 · 用于 Kindle 增强排版',
                        size: 12,
                        color: context.desk.ink2,
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    kfxProbing
                        ? '检测中'
                        : kfxPath == null
                        ? '未找到工具'
                        : '已定位路径',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: valueField(
                    '工具位置',
                    kfxProbing
                        ? '正在检查便携包内的 Bokai…'
                        : kfxPath ??
                              (state.configuration['kfx_converter']
                                      as String? ??
                                  '应用目录\\converters\\bokai.exe'),
                    icon: Icons.folder_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                DeskButton(
                  '浏览…',
                  icon: Icons.folder_open,
                  onPressed: kfxProbing ? null : _chooseKfxConverter,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Spacer(),
                DeskButton(
                  '重新定位',
                  icon: Icons.refresh,
                  onPressed: kfxProbing ? null : _probeBundledKfxConverter,
                  quiet: true,
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      settingCard(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, color: context.desk.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          DeskText('Kindle AZW3', size: 18, bold: true),
                          const DeskHelp('转换时会实际调用所选工具，并在任务中显示运行结果。'),
                        ],
                      ),
                      DeskText(
                        '使用应用附带工具，也可指定兼容版本',
                        size: 12,
                        color: context.desk.ink2,
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    probing
                        ? '检测中'
                        : converterPath == null
                        ? '未找到工具'
                        : '已定位路径',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: valueField(
                    '工具位置',
                    probing
                        ? '正在检查便携包内的 Kindling…'
                        : converterPath ??
                              (state.configuration['kindle_converter']
                                      as String? ??
                                  '应用目录\\converters\\kindling.exe'),
                    icon: Icons.folder_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                DeskButton(
                  '浏览…',
                  icon: Icons.folder_open,
                  onPressed: probing ? null : _chooseConverter,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Spacer(),
                DeskButton(
                  '重新定位',
                  icon: Icons.refresh,
                  onPressed: probing ? null : _probeBundledConverter,
                  quiet: true,
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      settingCard(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, color: context.desk.accent),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          DeskText('MOBI', size: 18, bold: true),
                          const DeskHelp(
                            'MOBI 与 AZW3 共用 Kindling；选择的转换器会保存到全局设置。',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Chip(label: Text('与 AZW3 共用工具')),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: valueField(
                    '工具位置',
                    probing
                        ? '正在检查便携包内的 Kindling…'
                        : converterPath ??
                              (state.configuration['kindle_converter']
                                      as String? ??
                                  '应用目录\\converters\\kindling.exe'),
                    icon: Icons.folder_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                DeskButton(
                  '浏览…',
                  icon: Icons.folder_open,
                  onPressed: probing ? null : _chooseConverter,
                ),
              ],
            ),
          ],
        ),
      ),
    ]),
    5 => section('数据与迁移', [
      groupTitle('配置与项目备份', '备份偏好与规则；原稿和成品由各自文件夹保存。'),
      Row(
        children: [
          Expanded(
            child: valueField(
              '备份目录',
              (state.configuration['backup_directory'] as String?) ?? '尚未选择',
            ),
          ),
          const SizedBox(width: 10),
          DeskButton(
            '浏览…',
            icon: Icons.folder_open,
            onPressed:
                widget.picker == null ||
                    widget.settings is! SettingsBackupService
                ? null
                : _backupSettings,
          ),
        ],
      ),
      toggle(
        state,
        '重要设置变更前创建备份',
        '保存前保留上一份配置',
        'backup_before_change',
        state.configuration['backup_before_change'] == true,
      ),
      actionRow([
        DeskButton(
          '立即备份',
          icon: Icons.backup_outlined,
          onPressed:
              widget.picker == null || widget.settings is! SettingsBackupService
              ? null
              : _backupSettings,
        ),
        DeskButton(
          '从备份恢复…',
          onPressed:
              widget.picker == null || widget.settings is! SettingsBackupService
              ? null
              : _restoreSettings,
        ),
      ]),
      if (backupInspection != null)
        note(
          '已读取备份，等待确认',
          '字段：${(backupInspection!['fields'] as List?)?.whereType<String>().join('、') ?? ''}',
        ),
      ..._checkCacheGroup(),
      // 配置迁移直接放在这里，不再单独占一个分区（SET-062）。
      groupTitle('迁移旧版配置', '先检查旧 XML/JSON，再由你确认写入新配置；检查不会自动覆盖当前设置。'),
      ..._migration(state),
      const SizedBox(height: 14),
    ]),
    _ => section('关于与许可', [
      settingCard(
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.auto_stories_outlined,
            color: context.desk.accent,
            size: 30,
          ),
          title: DeskText('EasyPub++', size: 22, bold: true),
          subtitle: DeskText('长篇书稿制作与 Kindle 转换', color: context.desk.ink2),
        ),
      ),
      groupTitle('版本信息', '来自发布包中的 version.json；直接从源码运行时显示“开发版本（未打包）”。'),
      settingCard(
        Column(
          children: [
            ListTile(
              key: const ValueKey('settings-app-version'),
              contentPadding: EdgeInsets.zero,
              title: const DeskText('应用版本'),
              trailing: DeskText(
                info == null
                    ? '正在读取…'
                    : !info!.packaged
                    ? '开发版本（未打包）'
                    : [
                        info!.version,
                        info!.date,
                      ].where((v) => v.isNotEmpty).join(' · '),
              ),
            ),
            if (info?.packaged == true && info!.commit.isNotEmpty) ...[
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('settings-app-commit'),
                contentPadding: EdgeInsets.zero,
                title: const DeskText('构建提交'),
                trailing: DeskText(
                  info!.uncommittedChanges
                      ? '${info!.commit}（含未提交改动）'
                      : info!.commit,
                ),
              ),
            ],
            const Divider(height: 1),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: DeskText('制作引擎'),
              trailing: DeskText('EasyPub Rust'),
            ),
            const Divider(height: 1),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: DeskText('平台'),
              trailing: DeskText('Windows · 桌面版'),
            ),
          ],
        ),
      ),
      ..._updateGroup(),
      ..._releaseNotesGroup(),
      ..._crashLogGroup(),
      groupTitle('许可与依赖', '随发布包提供第三方许可；转换工具许可分别列出。'),
      settingCard(
        Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: const DeskText('应用与源代码许可', bold: true),
              subtitle: DeskText(
                '查看本版本附带说明',
                size: 12,
                color: context.desk.ink2,
              ),
              trailing: DeskButton(
                '查看',
                onPressed: widget.desktop is LicenseDesktop
                    ? () => _openLicense('app')
                    : null,
                quiet: true,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.apps_outlined),
              title: const DeskText('Flutter、Dart 与 Rust 依赖', bold: true),
              subtitle: DeskText(
                '组件清单与许可证文本',
                size: 12,
                color: context.desk.ink2,
              ),
              trailing: DeskButton(
                '查看',
                onPressed: widget.desktop is LicenseDesktop
                    ? () => _openLicense('dependencies')
                    : null,
                quiet: true,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.extension_outlined),
              title: const DeskText('外部转换工具', bold: true),
              subtitle: DeskText(
                '按启用工具显示来源与许可',
                size: 12,
                color: context.desk.ink2,
              ),
              trailing: DeskButton(
                '工具配置',
                onPressed: () => setState(() => tab = 4),
                quiet: true,
              ),
            ),
          ],
        ),
      ),
      // 原“字段来源”分区只有说明文字，并入这里（SET-062）。
      groupTitle('设置的来源与优先级', '同一项设置有多个来源时，后面的覆盖前面的。'),
      for (final entry in const [
        ('元信息', '书籍信息页 / 文件夹映射'),
        ('排版', '全局默认 → 本书设置 → 本次转换'),
        ('清理规则', '规则预设 → 本书清理面板'),
        ('输出格式', '设置默认 → 转换页本次选择'),
      ])
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: DeskText(entry.$1, bold: true),
          subtitle: DeskText(entry.$2, size: 12, color: context.desk.ink2),
        ),
    ]),
  };
  List<Widget> _migration(SettingsSnapshot state) => [
    Row(
      children: [
        Expanded(
          child: TextField(
            controller: migrationPath,
            onChanged: (_) => setState(() {
              migrationGeneration++;
              migrationData = null;
              migrationResult = '';
            }),
            decoration: const InputDecoration(labelText: '旧设置文件路径'),
          ),
        ),
        const SizedBox(width: 8),
        DeskButton(
          '浏览…',
          icon: Icons.folder_open,
          onPressed: widget.pickLegacyFile == null || saving
              ? null
              : () async {
                  final path = await widget.pickLegacyFile!();
                  if (mounted && path != null) {
                    setState(() {
                      migrationGeneration++;
                      migrationPath.text = path;
                      migrationData = null;
                      migrationResult = '';
                    });
                  }
                },
        ),
      ],
    ),
    const SizedBox(height: 12),
    Wrap(
      spacing: 8,
      children: [
        DeskButton(
          '检查旧设置',
          onPressed: saving
              ? null
              : () async {
                  if (migrationPath.text.trim().isEmpty) {
                    setState(() => migrationResult = '请输入旧设置文件路径。');
                    return;
                  }
                  final requestedPath = migrationPath.text.trim();
                  final request = ++migrationGeneration;
                  try {
                    final result = await widget.settings.inspectLegacy(
                      requestedPath,
                    );
                    if (mounted &&
                        request == migrationGeneration &&
                        migrationPath.text.trim() == requestedPath) {
                      setState(() {
                        migrationData = result;
                        final report = result['report'] as Map;
                        final values = Map<String, dynamic>.from(
                          report['proposed_layout'] as Map,
                        );
                        final rules = report['proposed_recognition'] is Map;
                        final presets =
                            (report['proposed_recognition_presets'] as List? ??
                                    [])
                                .length;
                        migrationResult =
                            values.isEmpty && !rules && presets == 0
                            ? '未找到可自动迁移的默认设置，请查看逐项检查结果。'
                            : '已读取 ${values.length} 项排版设置${rules ? '、章节识别默认' : ''}${presets > 0 ? '、$presets 个识别预设' : ''}；确认后用于以后导入。';
                      });
                    }
                  } catch (_) {
                    if (mounted) {
                      setState(() => migrationResult = '旧设置读取失败，当前设置未改变。');
                    }
                  }
                },
        ),
        DeskButton(
          '清除结果',
          quiet: true,
          onPressed: () => setState(() {
            migrationResult = '';
            migrationData = null;
          }),
        ),
        if (migrationData != null)
          DeskButton(
            '确认迁移可识别字段',
            primary: true,
            onPressed: saving
                ? null
                : () async {
                    final requestedPath = migrationPath.text.trim();
                    if (requestedPath.isEmpty) {
                      setState(() => migrationResult = '旧设置路径已变化，请重新检查。');
                      return;
                    }
                    final data = migrationData!;
                    final report = data['report'] as Map;
                    final values = Map<String, dynamic>.from(
                      report['proposed_layout'] as Map,
                    );
                    final patch = <String, dynamic>{
                      if (values.isNotEmpty) 'layout_defaults': values,
                      if (report['proposed_recognition'] is Map)
                        'recognition_defaults': report['proposed_recognition'],
                      if ((report['proposed_recognition_presets'] as List? ??
                              [])
                          .isNotEmpty)
                        'recognition_presets': [
                          ...widget
                                      .settings
                                      .snapshot
                                      .value
                                      .configuration['recognition_presets']
                                  as List? ??
                              [],
                          ...report['proposed_recognition_presets'] as List,
                        ],
                    };
                    if (patch.isEmpty) {
                      setState(() => migrationResult = '没有可安全迁移的字段，当前设置未改变。');
                      return;
                    }
                    if (await widget.settings.savePatch(patch) && mounted) {
                      setState(() {
                        migrationResult = '已迁移 ${patch.length} 组字段；当前书籍和原稿未修改。';
                        migrationData = null;
                      });
                    }
                  },
          ),
      ],
    ),
    if (migrationData != null) ...[
      if (migrationData!['report']['proposed_recognition'] is Map)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: DeskText('章节规则可迁移为导入默认；已有手工章节树不会重建。', bold: true),
        ),
      for (final item
          in (migrationData!['report']['items'] as List).cast<Map>().where(
            (v) =>
                v['target'] == 'recognition_defaults' ||
                v['target'] == 'recognition_presets' ||
                '${v['source']}'.contains('Pattern'),
          ))
        ListTile(
          dense: true,
          title: Text('${item['source']}'),
          subtitle: Text('${item['reason']}'),
          trailing: Text(item['status'] == 'recognition_ready' ? '可迁移' : '待调整'),
        ),
      const SizedBox(height: 18),
      for (final group in const {
        '正文与段落': [
          'font_size',
          'font_size_unit',
          'font_family',
          'line_height',
          'paragraph_indent',
          'fullwidth_indent',
          'paragraph_spacing',
          'text_alignment',
          'remove_blank_lines',
        ],
        '页边距': [
          'margin_top',
          'margin_top_unit',
          'margin_bottom',
          'margin_bottom_unit',
          'margin_left',
          'margin_left_unit',
          'margin_right',
          'margin_right_unit',
        ],
        '目录': ['include_toc', 'visible_toc', 'chapter_navigation'],
      }.entries)
        if (group.value.any(
          (key) => (migrationData!['report']['proposed_layout'] as Map)
              .containsKey(key),
        )) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: DeskText(group.key, bold: true),
          ),
          for (final key in group.value)
            if ((migrationData!['report']['proposed_layout'] as Map)
                .containsKey(key))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: DeskText(_migrationLabel(key), size: 13),
                subtitle: DeskText(
                  '当前默认：${_migrationValue((state.configuration['layout_defaults'] as Map?)?[key])}',
                  size: 12,
                  color: context.desk.ink2,
                ),
                trailing: DeskText(
                  _migrationValue(
                    migrationData!['report']['proposed_layout'][key],
                  ),
                  color: context.desk.accent,
                ),
              ),
        ],
    ],
    if (migrationResult.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: DeskText(migrationResult),
      ),
  ];
  String _migrationLabel(String key) {
    if (key.endsWith('_unit')) {
      return '${layoutNumbers[key.substring(0, key.length - 5)] ?? '字号'}单位';
    }
    return layoutNumbers[key] ??
        layoutFlags[key] ??
        {'font_family': '字体', 'text_alignment': '对齐'}[key] ??
        key;
  }

  String _migrationValue(Object? value) {
    if (value == null) return '未设置';
    if (value is bool) return value ? '开启' : '关闭';
    return const {
          'justify': '两端对齐',
          'start': '随文字方向',
          'left': '左对齐',
          'center': '居中',
          'right': '右对齐',
        }[value] ??
        '$value';
  }

  void selectTab(int index) => setState(() {
    tab = index;
    widget.pageTitle?.value = tabs[index];
  });

  Widget navigation() {
    final d = context.desk;
    return Container(
      width: 220,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: tabs.length,
              itemBuilder: (_, index) {
                final on = tab == index;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Material(
                    color: on ? d.surface : Colors.transparent,
                    elevation: on ? 1 : 0,
                    shadowColor: Colors.black.withValues(alpha: .25),
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => selectTab(index),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(
                              tabIcons[index],
                              size: 17,
                              color: on ? d.ink : d.ink3,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                tabs[index],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ui(
                                  13,
                                  w: on ? 620 : 500,
                                  c: on ? d.ink : d.ink2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Row(
              children: [
                Dot(
                  saveStatus.contains('失败')
                      ? d.tone(Tone.pen).$1
                      : d.tone(Tone.ok).$1,
                  size: 6,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    saveStatus,
                    key: const ValueKey('settings-save-status'),
                    style: ui(
                      11.5,
                      c: saveStatus.contains('失败') ? d.pen : d.ink3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<SettingsSnapshot>(
        valueListenable: widget.settings.snapshot,
        builder: (context, state, _) {
          final d = context.desk;
          return Material(
            color: d.canvas,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: d.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: LayoutBuilder(
              builder: (context, bounds) {
                if (bounds.maxWidth < 800) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: DeskChoice<int>(
                          key: ValueKey(tab),
                          initialValue: tab,
                          decoration: const InputDecoration(labelText: '设置分类'),
                          items: [
                            for (final entry in tabs.indexed)
                              DropdownMenuItem(
                                value: entry.$1,
                                child: Text(entry.$2),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() {
                                tab = value;
                                widget.pageTitle?.value = tabs[value];
                              });
                            }
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 16, 0),
                        child: Text(
                          saveStatus,
                          key: const ValueKey('settings-save-status'),
                          style: ui(
                            11.5,
                            c: saveStatus.contains('失败') ? d.pen : d.ink3,
                          ),
                        ),
                      ),
                      Expanded(child: body(state)),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    navigation(),
                    Expanded(child: body(state)),
                  ],
                );
              },
            ),
          );
        },
      );
}
