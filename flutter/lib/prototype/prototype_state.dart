import 'dart:convert';
import 'dart:async';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as source_paths;

import '../application/source_refresh_service.dart';
import '../application/book_source_errors.dart';

import '../src/rust/api.dart' as api;

import 'txt_import.dart';
import 'project_io.dart' as projects;
import '../state/output_store.dart';
import '../state/shelf_store.dart';
import '../state/production_store.dart';
import '../state/manuscript_store.dart';
import '../state/cleanup_store.dart';

part 'source_refresh.dart';

enum DeskPage {
  library,
  folders,
  production,
  conversion,
  tasks,
  history,
  settings,
  repair,
}

class SampleBook {
  SampleBook(
    this.id,
    this.title,
    this.author,
    this.chapters,
    this.status, {
    this.source,
    this.format = 'TXT',
    this.hasCover = true,
  });
  final String id, title, author, status, format;
  final int chapters;
  bool hasCover;
  final ImportedTxt? source;
  bool get isDemo => source == null;
  String get path => source?.path ?? 'D:\\样书\\$title.${format.toLowerCase()}';
}

final sampleBooks = [
  SampleBook('river', '长河照影', '林间客', 690, '4 组待核对'),
  SampleBook('mountain', '山海来信', '无涯', 248, '本地未见异常', format: 'EPUB'),
  SampleBook('rain', '听雨集', '闻舟', 86, '尚未检查', hasCover: false),
  SampleBook('moon', '月下行舟：一段很长的归途', '青砚', 1204, '检查已过期'),
];

const bibliographicFields = <String, String>{
  'translator': '译者',
  'isbn': 'ISBN',
  'publication_date': '出版日期',
  'publisher': '出版社',
  'category': '类别',
  'series': '系列',
  'series_index': '系列序号',
  'subjects': '主题 / 标签',
  'language': '语言',
};

class BookDraft {
  Map<String, dynamic> layoutOrigins = {};
  Map<String, dynamic> metadataOrigins = {};
  BookDraft(SampleBook book) : title = book.title, author = book.author;
  String title, author;
  String description = '';
  Map<String, String> bibliographic = {
    for (final key in bibliographicFields.keys) key: '',
  };
  double fontSize = 18, lineHeight = 1.2;
  String fontSizeUnit = '%';
  int fullwidthIndent = 2;
  bool removeBlankLines = true;
  String textAlignment = 'start';
  // 竖排与纵中横位数（V28，LAY-104）。
  String writingMode = 'horizontal';
  int verticalDigits = 2;
  // 章节标题样式（V36，LAY-117）。
  String headingStyle = 'classic';
  // 场景分隔样式（V46，LAY-118）。
  static const _ruleOptionDefaults = <String, dynamic>{
    'cleanup_pipeline': null,
    'scene_symbols': null,
    'disabled': <String>[],
    'restore_values': <String, dynamic>{},
  };
  Map<String, dynamic> _ruleOptions = {..._ruleOptionDefaults};
  Map<String, dynamic> get ruleOptions => _ruleOptions;
  set ruleOptions(Map<String, dynamic> value) {
    _ruleOptions = {..._ruleOptionDefaults, ...value};
  }

  Map<String, dynamic>? ruleToggleHistory;
  String sceneBreakStyle = 'keep';
  String noteStyle = 'off';
  // 章首段落样式（V49，LAY-119）。
  String firstParagraphStyle = 'normal';
  // 统一章首图（V54，LAY-124）。
  String? chapterHeadImage;
  String chapterHeadScope = 'chapter';
  String chapterHeadWidth = 'half';
  // 系统提示与诗词（V50，LAY-121/122）。
  String systemBlockStyle = 'box';
  String verseBlockStyle = 'center';
  List<Map<String, dynamic>> blockAnnotations = [];
  List<Map<String, dynamic>> manualNotes = [];
  List<Map<String, dynamic>> supplementalPages = [];
  String additionalCss = '';
  String additionalCssBase = '';
  Map<String, dynamic>? additionalCssBundle;
  List<String> cssFontPermissions = [];
  double paragraphIndent = 0.0;
  double paragraphSpacing = 0.6;
  double marginTop = 0.0;
  String marginTopUnit = 'px';
  double marginRight = 3.0;
  String marginRightUnit = 'px';
  double marginBottom = 0.0;
  String marginBottomUnit = 'px';
  double marginLeft = 3.0;
  String marginLeftUnit = 'px';
  bool includeToc = true;
  bool visibleToc = false;
  bool chapterNavigation = false;
  String? coverPath;

  /// 新书默认“完整显示”：EPUB 封面页放下整张封面，不裁切（V16 后用户决定，OUT-075）。
  String coverFit = 'contain';
  Map<String, dynamic>? coverCrop;
  Map<String, dynamic>? coverDesign;
  String fontFamily = 'Microsoft YaHei';
  Map<String, dynamic>? fontResource;
  List<Map<String, dynamic>> illustrations = [];
  Map<String, dynamic>? epubResources;
}

/// Navigation and ephemeral form state. No editable Rust tree is duplicated.
class ProductionPreview {
  ProductionPreview(this.request, this.result, this.guard);
  final String request;
  final Map<String, dynamic> result;
  final Map<String, String> guard;
  final compositionGuards = <String, String>{};
}

/// Detached, single-use domain mutation. Validate every domain before publishing
/// any of them; callers must not await between validation and publication.
class PreparedStateChange {
  PreparedStateChange(this.validate, this.publish);
  final VoidCallback validate, publish;
}

class DetachedBooks {
  DetachedBooks._(this.ids, this.epoch, this._restore);
  final Set<String> ids;
  final int epoch;
  final void Function() _restore;
  bool restored = false;
}

class PrototypeState extends ChangeNotifier {
  int removalEpoch = 0;
  final bookMembership = <String, int>{};

  DetachedBooks detachBooks(Set<String> ids) {
    final positions = <(int, SampleBook)>[
      for (var i = 0; i < shelf.books.length; i++)
        if (ids.contains(shelf.books[i].id) && !shelf.books[i].isDemo)
          (i, shelf.books[i]),
    ];
    if (ids.isEmpty || positions.length != ids.length) {
      throw const FormatException('书库已变化，请重新选择要移除的书籍。');
    }
    final beforeCurrent = currentId;
    final beforeSelected = shelf.selected.intersection(ids);
    final restorers = <void Function()>[];
    void take<T>(Map<String, T> map) {
      final values = <String, T>{};
      for (final id in ids) {
        if (map.containsKey(id)) values[id] = map.remove(id) as T;
      }
      restorers.add(() => map.addAll(values));
    }

    change(() {
      for (final id in ids) {
        bookMembership[id] = (bookMembership[id] ?? 0) + 1;
      }
      take(production.drafts);
      take(metadata);
      take(cleanup.drafts);
      take(cleanup.histories);
      take(cleanup.historyStatus);
      take(production.histories);
      take(manuscript.effectiveHistories);
      take(manuscript.structureHistories);
      take(manuscript.structures);
      take(manuscript.recognitionDrafts);
      take(manuscript.findingReviews);
      take(manuscript.manualEditDrafts);
      take(_bookCatalogs);
      take(_catalogSources);
      take(production.coverInputs);
      take(production.resourceIssues);
      take(production.publicationReports);
      shelf.books.removeWhere((b) => ids.contains(b.id));
      shelf.selected.removeAll(ids);
      if (ids.contains(currentId)) {
        currentId = shelf.books.where((b) => !b.isDemo).firstOrNull?.id ?? '';
      }
    });
    return DetachedBooks._(Set.unmodifiable(ids), removalEpoch, () {
      for (final item in positions) {
        shelf.books.insert(item.$1.clamp(0, shelf.books.length), item.$2);
      }
      for (final restore in restorers) {
        restore();
      }
      shelf.selected.addAll(beforeSelected);
      if (ids.contains(beforeCurrent)) {
        currentId = beforeCurrent;
      }
    });
  }

  void restoreDetachedBooks(DetachedBooks snapshot) {
    if (snapshot.restored || snapshot.epoch != removalEpoch) {
      throw const FormatException('移除记录已失效，不能恢复到另一个项目。');
    }
    if (shelf.books.any((b) => snapshot.ids.contains(b.id))) {
      throw const FormatException(
        '其中的书已重新导入；如需旧版本，请先移除新条目，再在恢复记录中选择原来的移除记录。新草稿也会保留在恢复记录中。',
      );
    }
    change(() {
      for (final id in snapshot.ids) {
        bookMembership[id] = (bookMembership[id] ?? 0) + 1;
      }
      snapshot._restore();
      snapshot.restored = true;
    });
  }

  /// Monotonic state generation used by read-only projections and caches.
  int stateRevision = 0;

  /// Task progress is persisted by output history, independently of book edits.
  bool taskNotification = false;

  /// 书籍信息、封面、插图、排版等制作设置与其历史（V20 拆到 state/production_store.dart）。
  late final ProductionStore production = ProductionStore(this);

  /// 转换任务与输出记录（V20 拆到 state/output_store.dart）。
  late final OutputStore outputs = createOutputs();

  /// 测试可以覆盖它来替换保存行为。
  @protected
  OutputStore createOutputs() => OutputStore(this);

  PrototypeState({
    this.settingsDirectory,
    ImportTxt? importer,
    projects.SaveProject? projectSaver,
    projects.OpenProject? projectOpener,
  }) : _importer = importer ?? readBook,
       _projectSaver = projectSaver ?? projects.saveProject,
       _projectOpener = projectOpener ?? projects.openProject;
  final String? settingsDirectory;
  Map<String, dynamic> globalConfiguration = {
    'layout_defaults': <String, dynamic>{},
    'layout_presets': <dynamic>[],
    'output_batches': <dynamic>[],
    'favorite_folders': <dynamic>[],
  };

  /// 书库中的书、勾选与收藏文件夹（V20 拆到 state/shelf_store.dart）。
  late final ShelfStore shelf = ShelfStore(this);
  String? globalSettingsToken;
  String globalSettingsStatus = '';
  bool globalSettingsLoaded = false;
  bool globalSettingsBusy = false;
  Future<bool>? _settingsLoad;
  Future<bool> loadGlobalSettings() {
    if (globalSettingsBusy && _settingsLoad == null) return Future.value(false);
    return _settingsLoad ??= _loadGlobalSettings().whenComplete(
      () => _settingsLoad = null,
    );
  }

  Future<Map<String, dynamic>> resolvedFactoryLayout() async {
    final result = jsonDecode(
      await api.resolveLayoutSettingsText(layersJson: '{}'),
    ) as Map;
    return Map<String, dynamic>.from(result['values'] as Map);
  }

  Future<Map<String, dynamic>> inspectLegacySettings(String path) async =>
      Map<String, dynamic>.from(
        jsonDecode(await api.inspectLegacySettingsText(path: path)) as Map,
      );

  Future<Map<String, dynamic>> resolvedGlobalLayout() async {
    final result = jsonDecode(
      await api.resolveLayoutSettingsText(
        layersJson: jsonEncode({
          'global': globalConfiguration['layout_defaults'],
        }),
      ),
    ) as Map;
    return Map<String, dynamic>.from(result['values'] as Map);
  }

  Future<bool> _loadGlobalSettings() async {
    if (settingsDirectory == null) return true;
    change(() => globalSettingsBusy = true);
    try {
      final result = jsonDecode(
        await api.loadSettingsText(directory: settingsDirectory!),
      ) as Map<String, dynamic>;
      change(() {
        globalConfiguration = Map<String, dynamic>.from(
          result['configuration'] as Map,
        );
        outputs.loadBatchRecords(globalConfiguration);
        shelf.favoriteFolders
          ..clear()
          ..addAll(
            ((globalConfiguration['favorite_folders'] as List?) ?? const [])
                .whereType<String>()
                .where((path) => path.trim().isNotEmpty)
                .map(normalizeFolderPath)
                .toSet(),
          );
        final configuredTheme = globalConfiguration['ui_theme'];
        if (configuredTheme is String &&
            {'paper', 'night', 'contrast'}.contains(configuredTheme)) {
          theme = configuredTheme;
        }
        final configuredMotion = globalConfiguration['reduced_motion'];
        if (configuredMotion is bool) reducedMotion = configuredMotion;
        globalSettingsToken = result['token'] as String?;
        globalSettingsLoaded = true;
        globalSettingsStatus =
            (result['retired_check_fields'] as List? ?? []).isEmpty
            ? '全局设置已读取。'
            : '全局设置已读取；旧版无效检查开关已停用，检查使用当前章节规则和文本规则。';
      });
      return true;
    } catch (_) {
      change(() {
        globalSettingsLoaded = false;
        globalSettingsStatus = '全局设置读取失败，请检查设置目录；新书导入已暂停，已有项目设置不变。';
      });
      return false;
    } finally {
      change(() => globalSettingsBusy = false);
    }
  }

  List<Map<String, dynamic>> get globalFolderRules =>
      ((globalConfiguration['folder_rules'] as List?) ?? const [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();

  Future<bool> saveGlobalFolderRules(List<Map<String, dynamic>> rules) async {
    if (importing || projectBusy || production.busy) return false;
    if (!globalSettingsLoaded && !await loadGlobalSettings()) return false;
    final ok = await saveGlobalConfiguration(
      Map<String, dynamic>.from(globalConfiguration)
        ..['folder_rules'] = jsonDecode(jsonEncode(rules)),
      globalSettingsToken,
    );
    if (ok) change(() => globalSettingsStatus = '全局映射规则已保存，之后导入时自动匹配。');
    return ok;
  }

  Future<bool> saveGlobalPresets(
    List<Map<String, dynamic>> presets,
    String? expectedToken,
  ) => saveGlobalConfiguration(
    Map<String, dynamic>.from(globalConfiguration)
      ..['layout_presets'] = jsonDecode(jsonEncode(presets)),
    expectedToken,
  );

  /// Persist settings owned by the application shell while preserving the
  /// optimistic token and the rest of the global configuration.
  Future<bool> saveGlobalConfigurationPatch(Map<String, dynamic> patch) async {
    if (!await loadGlobalSettings()) return false;
    final configuration = Map<String, dynamic>.from(globalConfiguration)
      ..addAll(jsonDecode(jsonEncode(patch)) as Map<String, dynamic>);
    final ok = await saveGlobalConfiguration(
      configuration,
      globalSettingsToken,
    );
    if (ok) {
      final nextTheme = patch['ui_theme'];
      final nextMotion = patch['reduced_motion'];
      change(() {
        if (nextTheme is String &&
            {'paper', 'night', 'contrast'}.contains(nextTheme)) {
          theme = nextTheme;
        }
        if (nextMotion is bool) reducedMotion = nextMotion;
      });
    }
    return ok;
  }

  static String normalizeFolderPath(String path) {
    final value = path.trim();
    if (value.isEmpty) return '';
    try {
      final absolute = Directory(value).absolute.path;
      if (RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(absolute)) return absolute;
      return absolute.replaceFirst(RegExp(r'[\\/]$'), '');
    } catch (_) {
      return '';
    }
  }

  Future<bool> saveGlobalConfiguration(
    Map<String, dynamic> configuration,
    String? expectedToken,
  ) async {
    if (settingsDirectory == null ||
        globalSettingsBusy ||
        !globalSettingsLoaded ||
        expectedToken != globalSettingsToken) {
      return false;
    }
    change(() => globalSettingsBusy = true);
    try {
      final result = jsonDecode(
        await api.saveSettingsText(
          directory: settingsDirectory!,
          expectedToken: expectedToken,
          configurationJson: jsonEncode(configuration),
        ),
      ) as Map<String, dynamic>;
      change(() {
        globalConfiguration = Map<String, dynamic>.from(
          result['configuration'] as Map,
        );
        globalSettingsToken = result['token'] as String?;
        globalSettingsStatus = '全局排版配置已保存；已有书籍和项目保持原设置。';
      });
      return true;
    } catch (_) {
      change(() => globalSettingsStatus = '保存失败：请检查数值范围，或重新读取另一窗口更新的设置；本次未覆盖。');
      return false;
    } finally {
      change(() => globalSettingsBusy = false);
    }
  }

  final projects.SaveProject _projectSaver;
  final projects.OpenProject _projectOpener;
  final _bookCatalogs = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? savedReferenceCatalog(String bookId) {
    final book = shelf.books.where((b) => b.id == bookId).firstOrNull;
    return book != null && _catalogSources[bookId] == book.source?.sourceId
        ? _bookCatalogs[bookId]
        : null;
  }

  void saveReferenceCatalog(String bookId, Map<String, dynamic> snapshot) {
    final book = shelf.books.firstWhere((b) => b.id == bookId);
    if (book.source == null) throw const FormatException('请先导入真实书稿。');
    change(() {
      _bookCatalogs[bookId] = snapshot;
      _catalogSources[bookId] = book.source!.sourceId;
    });
  }

  final _catalogSources = <String, String>{};
  bool projectBusy = false;
  String projectPath = '', projectStatus = '';
  String? savedProjectIdentity;
  String get projectIdentity =>
      jsonEncode(projectDocument()..remove('current_path'));
  bool get canSaveProject =>
      !importing && !projectBusy && !cleanup.historyBusy && !production.busy;
  final ImportTxt _importer;
  bool _disposed = false, _cancelImport = false;

  /// 预先解析的书稿（V38，LIB-115）：导入多本时几本同时读取与识别，写入书库仍按顺序逐本进行。
  final Map<String, Future<ImportedTxt>> _prefetched = {};

  /// 开始预先解析 [path]；只读取与识别书稿，不改书库。导入取消时随之取消。
  void prefetchImport(String path) {
    final key = path.trim();
    if (key.isEmpty || _prefetched.containsKey(key)) return;
    final future = _importer(key, () => _cancelImport || _disposed);
    // 预先解析的结果可能用不上（导入被取消）；错误在真正导入这本时再处理。
    future.ignore();
    _prefetched[key] = future;
  }

  /// 丢弃还没用上的预先解析结果。
  void dropPrefetchedImports() => _prefetched.clear();
  String currentId = 'river';
  // The production workspace starts in the approved 宣纸 theme.  Night
  // mode remains an explicit user preference in settings, rather than a
  // hidden default that makes newly imported books look like a demo.
  String theme = 'paper';
  String output = r'D:\EasyPub\输出', format = 'EPUB';
  String importStatus = '';
  bool importing = false;
  bool reducedMotion = false;

  String catalogReason(String reason) => switch (reason) {
    'catalog_too_large' ||
    'request_too_large' => '目录最多支持 30000 章、8 MiB 文本。请去除正文或无关内容后重新导入。',
    'catalog_cancelled' => '目录请求已取消。',
    'network_timeout' => '网络超时，请稍后重试。',
    'network_failed' => '网络连接失败，请检查连接或使用已保存的目录。',
    'http_failed' => '网站返回了错误页面，请稍后重试或换一个来源。',
    'not_found' => '网站上找不到这个页面，请检查地址或换一个来源。',
    'verification_required' => '起点要求网页验证，请在浏览器完成验证后重试，或使用本地目录。',
    'login_required' => '起点要求登录，可填写仅用于本次请求的 Cookie。',
    'rate_limited' => '起点限制了请求频率，请稍后重试。',
    'network_busy' => '已有目录请求正在处理，请稍后重试。',
    'invalid_qidian_url' || 'unsupported_source' => '请输入起点书籍网址或书号；当前不接入其他站点。',
    'credential_read_failed' => '本机保存的Cookie无法读取，可重新保存、清除，或取消使用已保存Cookie。',
    'credential_save_failed' => 'Cookie保存失败，原有凭据保持不变，请检查本机目录是否可写或被占用。',
    'credential_clear_failed' => 'Cookie清除失败，原有凭据仍保留，请检查文件是否被占用。',
    'credential_protection_failed' => 'Windows用户保护失败，未保存Cookie。',
    'credential_storage_unavailable' => '本机凭据目录不可用，仍可使用当前窗口Cookie。',
    'credential_storage_unsupported' => '当前系统不支持本机凭据保护，仍可单次使用Cookie。',
    'credential_storage_busy' => '凭据存储忙碌，请稍后重试。',
    'invalid_cookie_format' =>
      'Cookie格式无法识别。支持name=value、Cookie:前缀、Netscape、浏览器JSON及名字=＋制表符＋值（可折行）。',
    'cookie_import_too_large' => 'Cookie导入内容或请求头过大，请仅导出起点所需凭据。',
    'cookie_origin_mismatch' => '凭据只能用于起点HTTPS目录请求。',
    'cookie_no_applicable_entries' => '没有适用于当前请求的Cookie，请检查域名、路径及有效期。',
    'cookie_ambiguous' => '存在同名同路径但值不同的Cookie，请重新导出单一会话。',
    'cookie_partition_unsupported' => '暂不支持分区Cookie，请使用当前请求的Cookie请求头。',
    'book_identity_mismatch' => '网页书号与请求不一致，目录未采用。',
    'cache_invalid' || 'cache_read_failed' => '本地缓存不可用，请选择重新联网获取。',
    'catalog_snapshot_invalid' => '保存的目录校验失败，请重新读取。',
    'parse_failed_no_catalog_entries' ||
    'parse_failed_invalid_payload' => '未能解析目录，可能是网页结构变化或文件不是目录。',
    'search_empty_or_layout_changed' => '搜索没有可用候选或页面结构变化，请尝试书籍网址。',
    'local_catalog_unreadable' => '无法读取本地目录，请检查路径和权限。',
    'unmatched' => '本地标题未在目录中定位',
    'ambiguous_cross_volume' => '跨分组同名，请选择对应章节',
    'duplicate_local_chapter_body_not_removed' => '重复定位，正文保留待核对',
    'order_conflict_review_required' => '顺序不同，可预览整章归位',
    'existing_volume_or_intro_requires_review' => '已有分组或卷首正文需核对',
    'volume_boundary_not_proven' => '分组边界证据不足',
    'not_located_no_body_created' => '未定位到本地正文，不会补造章节',
    'catalog_scope_not_verified_complete' => '目录完整性未确认',
    'reorder_requires_complete_unique_alignment' => '归位需要完整目录和逐章唯一对应',
    'volume_intro_requires_review' => '卷首正文与首章不一致，不能自动归位',
    'choose_new_output_path' => '输出文件已存在或与原稿冲突，请更换新文件名。',
    'reopen_preview' => '原稿已在外部修改，请重新导入并生成预览。',
    'invalid_explicit_choice' => '章节对应选择已失效，请重新选择',
    'confirm_current_nonempty_plan' => '计划已变化或没有选中修改，请重新预览',
    _ => bookSourceErrorReasons[reason] ?? '未完成：$reason',
  };

  final metadata = <String, (String, String)>{};

  /// 文本清理（V20 拆到 state/cleanup_store.dart）。
  late final CleanupStore cleanup = CleanupStore(this);

  /// 章节结构、人工编辑与有效书稿的章节修改历史（V20 拆到 state/manuscript_store.dart）。
  late final ManuscriptStore manuscript = ManuscriptStore(this);
  BookDraft get draft =>
      production.drafts.putIfAbsent(currentId, () => BookDraft(current));
  String get title => draft.title;
  set title(String value) => draft.title = value;
  String get author => draft.author;
  set author(String value) => draft.author = value;
  String? get coverPath => draft.coverPath;
  set coverPath(String? value) {
    if (draft.coverPath != value) draft.coverDesign = null;
    draft.coverPath = value;
  }

  String get coverFit => draft.coverFit;
  set coverFit(String value) => draft.coverFit = value;
  String get fontFamily => draft.fontFamily;
  set fontFamily(String value) => draft.fontFamily = value;
  double get fontSize => draft.fontSize;
  set fontSize(double value) => draft.fontSize = value;
  double get lineHeight => draft.lineHeight;
  set lineHeight(double value) => draft.lineHeight = value;
  bool get includeToc => draft.includeToc;
  set includeToc(bool value) => draft.includeToc = value;
  bool get queueActive => outputs.batchBusy || outputs.running;
  SampleBook get current => shelf.books.firstWhere((b) => b.id == currentId);

  String displayTitle(SampleBook book) => metadata[book.id]?.$1 ?? book.title;

  /// 实际填写的作者；没有填写时为空字符串（成品、文件名和书库都用它，V15）。
  String authorOf(SampleBook book) =>
      (metadata[book.id]?.$2 ?? book.author).trim();

  String illustrationContext(String bookId) => jsonEncode([
    production.guardFor(bookId),
    manuscript.structures[bookId],
    manuscript.structureHistories[bookId],
    manuscript.effectiveHistories[bookId],
    manuscript.manualEditDrafts[bookId],
    cleanup.drafts[bookId],
    current.id,
  ]);

  String publicationContext(String bookId) => illustrationContext(bookId);

  /// Conversion identity follows the actual publication input, not navigation.
  String conversionContext(String bookId) => jsonEncode([
    publicationRequest(bookId),
    bookMembership[bookId] ?? 0,
    removalEpoch,
  ]);

  Map<String, dynamic> publicationRequest(String bookId) {
    final book = shelf.books.firstWhere((b) => b.id == bookId && !b.isDemo);
    final draft = manuscript.manualEditDrafts[bookId];
    final actions = draft == null
        ? null
        : (draft['history'] as List)[draft['cursor'] as int] as List;
    return {
      'source_id': book.source!.sourceId,
      'revision': book.source!.revision,
      'settings': production.settings(bookId),
      if (manuscript.structures[bookId] != null)
        'structure': manuscript.structures[bookId],
      if (actions != null && actions.isNotEmpty)
        'manual': {'kind': 'manual_batch', 'actions': actions},
      if (cleanup.drafts[bookId] != null) 'cleanup': cleanup.drafts[bookId],
      'post_edits': manuscript.effectiveSelection(bookId),
    };
  }

  List<Map<String, dynamic>> folderRules = [];
  bool projectFolderRulesEnabled = false;
  List<Map<String, dynamic>> get effectiveFolderRules => [
    for (final rule in globalFolderRules) {...rule, 'priority': 0},
    if (projectFolderRulesEnabled)
      for (final rule in folderRules) {...rule, 'priority': 1},
  ];
  List<Map<String, dynamic>> layoutPresets = [];
  List<Map<String, dynamic>> cleanupPresets = [];

  Future<ProductionPreview> previewFolderMapping(
    List<Map<String, dynamic>> rules,
    List<String> targets, {
    Map<String, Set<String>> overrides = const {},
    Map<String, Set<String>> restoreFields = const {},
  }) async {
    if (targets.toSet().length != targets.length) {
      throw const FormatException('目标书稿重复。');
    }
    return production.previewChanges({
      for (final id in targets)
        id: {
          'op': 'folder_mapping',
          'source_path': (() {
            final source = shelf.books
                .firstWhere((b) => b.id == id && !b.isDemo)
                .source!;
            return source.originPath ?? source.path;
          })(),
          'rules': rules,
          'override_fields': (overrides[id] ?? const <String>{}).toList(),
          'restore_fields': (restoreFields[id] ?? const <String>{}).toList(),
        },
    });
  }

  void change(VoidCallback action, {bool taskOnly = false}) {
    if (_disposed) return;
    action();
    stateRevision++;
    taskNotification = taskOnly;
    try {
      notifyListeners();
    } finally {
      taskNotification = false;
    }
  }

  @override
  void dispose() {
    _cancelImport = true;
    outputs.cancelRunning();
    _disposed = true;
    super.dispose();
  }

  /// Non-visual import outcome for the new application boundary. Unlike a
  /// library-membership check, this distinguishes a failed reimport from a
  /// successful import of a file that was already present.
  Future<bool> importBookOutcome(
    String path, {
    DeskPage destination = DeskPage.library,
  }) async {
    return _importBook(path, destination: destination);
  }

  Future<bool> _importBook(
    String path, {
    DeskPage destination = DeskPage.library,
  }) async {
    if (importing ||
        projectBusy ||
        cleanup.historyBusy ||
        production.busy ||
        path.trim().isEmpty) {
      return false;
    }
    change(() {
      importing = true;
      _cancelImport = false;
      importStatus = '正在读取书稿…';
    });
    try {
      Map<String, dynamic>? initialLayout;
      final globalFields = <String>{};
      if (settingsDirectory != null) {
        if (!await loadGlobalSettings()) {
          throw FormatException(globalSettingsStatus);
        }
        initialLayout = await resolvedGlobalLayout();
        globalFields.addAll(
          (globalConfiguration['layout_defaults'] as Map).keys.cast<String>(),
        );
      }
      if (_cancelImport || _disposed) return false;
      final source =
          await (_prefetched.remove(path.trim()) ??
              _importer(path.trim(), () => _cancelImport));
      if (_cancelImport || _disposed) return false;
      final originalPath = source.originPath ?? source.path;
      final importedResources = source.resourceReport;
      final importedMetadata = (importedResources?['metadata'] as Map?)
          ?.cast<String, dynamic>();
      final id = originalPath.toLowerCase();
      final name = originalPath.replaceAll('\\', '/').split('/').last;
      final book = SampleBook(
        id,
        (importedMetadata?['title'] as String?)?.trim().isNotEmpty == true
            ? (importedMetadata!['title'] as String).trim()
            : name.replaceFirst(
                RegExp(r'\.(txt|epub)$', caseSensitive: false),
                '',
              ),
        (importedMetadata?['author'] as String?)?.trim().isNotEmpty == true
            ? (importedMetadata!['author'] as String).trim()
            : '',
        source.headings,
        '已识别 · 尚未检查',
        source: source,
        format: bookFormatForPath(originalPath),
        hasCover: false,
      );
      final existing = shelf.books.indexWhere((b) => b.id == id);
      if (existing >= 0) {
        // Reimport must not transplant old line-bound histories onto new bytes.
        // The explicit refresh proposal owns all replacement and field adoption.
        final same = shelf.books[existing].source?.sourceId == source.sourceId;
        change(() {
          currentId = id;
          if (destination == DeskPage.conversion) shelf.selected.add(id);
          importStatus = same
              ? '已在书库，保留现有草稿；更新来源信息请使用“刷新来源”。'
              : '来源内容已变化，现有草稿保留；请在书籍菜单选择“刷新来源”。';
        });
        return true;
      }
      var draft = existing < 0
          ? BookDraft(book)
          : (production.drafts[id] ?? BookDraft(book));
      final mappingRules = effectiveFolderRules;
      final mappingGuard = jsonEncode(mappingRules);
      Map<String, dynamic>? importedHistory;
      var unavailableRules = 0;

      if (existing < 0) {
        if (initialLayout != null) {
          final v = initialLayout;
          draft
            ..layoutOrigins = {
              for (final entry in v.entries)
                entry.key: {
                  'source': globalFields.contains(entry.key)
                      ? 'global'
                      : 'factory',
                  'value': entry.value,
                },
            }
            ..fontSize = (v['font_size'] as num).toDouble()
            ..fontSizeUnit = v['font_size_unit'] as String? ?? 'px'
            ..fullwidthIndent = (v['fullwidth_indent'] as num? ?? 0).toInt()
            ..removeBlankLines = v['remove_blank_lines'] == true
            ..lineHeight = (v['line_height'] as num).toDouble()
            ..textAlignment = v['text_alignment'] as String
            ..writingMode = v['writing_mode'] as String? ?? 'horizontal'
            ..verticalDigits = (v['vertical_digits'] as num? ?? 2).toInt()
            ..headingStyle = v['heading_style'] as String? ?? 'classic'
            ..ruleOptions = Map<String, dynamic>.from(
              v['rule_options'] as Map? ?? {},
            )
            ..ruleToggleHistory = (v['rule_toggle_history'] as Map?)
                ?.cast<String, dynamic>()
            ..sceneBreakStyle = v['scene_break_style'] as String? ?? 'keep'
            ..noteStyle = v['note_style'] as String? ?? 'off'
            ..firstParagraphStyle =
                v['first_paragraph_style'] as String? ?? 'normal'
            ..chapterHeadImage = v['chapter_head_image'] as String?
            ..chapterHeadScope = v['chapter_head_scope'] as String? ?? 'chapter'
            ..chapterHeadWidth = v['chapter_head_width'] as String? ?? 'half'
            ..systemBlockStyle = v['system_block_style'] as String? ?? 'box'
            ..verseBlockStyle = v['verse_block_style'] as String? ?? 'center'
            ..blockAnnotations = (v['block_annotations'] as List? ?? [])
                .map((a) => Map<String, dynamic>.from(a as Map))
                .toList()
            ..manualNotes = (v['manual_notes'] as List? ?? [])
                .map((a) => Map<String, dynamic>.from(a as Map))
                .toList()
            ..supplementalPages = (v['supplemental_pages'] as List? ?? [])
                .map((a) => Map<String, dynamic>.from(a as Map))
                .toList()
            ..fontFamily = v['font_family'] as String
            ..paragraphIndent = (v['paragraph_indent'] as num).toDouble()
            ..paragraphSpacing = (v['paragraph_spacing'] as num).toDouble()
            ..marginTop = (v['margin_top'] as num).toDouble()
            ..marginTopUnit = v['margin_top_unit'] as String? ?? 'em'
            ..marginRight = (v['margin_right'] as num).toDouble()
            ..marginRightUnit = v['margin_right_unit'] as String? ?? 'em'
            ..marginBottom = (v['margin_bottom'] as num).toDouble()
            ..marginBottomUnit = v['margin_bottom_unit'] as String? ?? 'em'
            ..marginLeft = (v['margin_left'] as num).toDouble()
            ..marginLeftUnit = v['margin_left_unit'] as String? ?? 'em'
            ..includeToc = v['include_toc'] as bool
            ..visibleToc = v['visible_toc'] as bool
            ..chapterNavigation = v['chapter_navigation'] as bool;
        }
      }
      draft.epubResources = importedResources;
      final importedPlacements =
          (importedResources?['image_placements'] as List?)
              ?.whereType<Map>()
              .map((row) => row.cast<String, dynamic>())
              .where(
                (row) => row['path'] is String && row['source_line'] is num,
              )
              .map(
                (row) => <String, dynamic>{
                  'path': row['path'],
                  'caption': row['caption'] as String? ?? '',
                  'alt': row['alt'] as String? ?? '',
                  'source_line': (row['source_line'] as num).toInt(),
                },
              )
              .toList(growable: false) ??
          const <Map<String, dynamic>>[];
      if (existing < 0 && importedPlacements.isNotEmpty) {
        draft.illustrations = importedPlacements;
      }
      // Reimport refreshes the source, not the user's saved production draft.
      // In particular an empty value may be an intentional manual clear.
      // Source metadata is used only when initializing a new book.
      if (existing < 0 && importedMetadata != null) {
        draft.description = importedMetadata['description'] as String? ?? '';
        for (final key in bibliographicFields.keys) {
          final metadataKey = key == 'publication_date'
              ? 'publication_date'
              : key;
          final value = importedMetadata[metadataKey];
          if (value is String && value.trim().isNotEmpty) {
            draft.bibliographic[key] = value.trim();
          }
        }
      }
      final importedCover = importedResources?['cover_path'] as String?;
      if (existing < 0 && importedCover != null && importedCover.isNotEmpty) {
        draft.coverPath = importedCover;
      }
      if (existing < 0) {
        final sourceValues = production.valuesOf(draft);
        draft.metadataOrigins = {
          for (final key in [
            'title',
            'author',
            'description',
            ...bibliographicFields.keys,
            'cover_path',
            'cover_fit',
            'cover_crop',
            'cover_design',
          ])
            key: {'source': 'imported', 'value': sourceValues[key]},
        };
      }
      if (existing < 0 && mappingRules.isNotEmpty) {
        final values = production.valuesOf(draft);
        final request = jsonEncode({
          'targets': [
            {
              'book_id': id,
              'current': values,
              'history': {
                'source_id': source.sourceId,
                'revision': source.revision,
                'states': [values],
                'cursor': 0,
              },
              'change': {
                'op': 'folder_mapping',
                'source_path': originalPath,
                'rules': mappingRules,
              },
            },
          ],
        });
        try {
          final preview = await production.productionRequest(request);
          if (_cancelImport || _disposed) return false;
          final result = await production.productionRequest(
            request,
            apply: true,
            planId: preview['plan_id'] as String,
            confirmed: true,
          );
          if (_cancelImport || _disposed) return false;
          if (jsonEncode(effectiveFolderRules) != mappingGuard) {
            throw const FormatException('映射规则在入库期间变化，请重新导入。');
          }
          final item = (result['items'] as List).single as Map;
          draft = production.draftFromProduction(
            book,
            item['after'] as Map,
            importedResources,
          );
          importedHistory = Map<String, dynamic>.from(item['history'] as Map);
          unavailableRules =
              ((item['mapping'] as Map?)?['unavailable'] as List? ?? const [])
                  .length;
        } catch (error) {
          throw const FormatException('入库映射未完成，请检查命中规则的字段和封面资源；书稿尚未加入书库。');
        }
      }
      final ruleDefaults = globalConfiguration['rule_defaults'] as Map?;
      if (existing < 0 && ruleDefaults != null) {
        final values = production.valuesOf(draft);
        values.addAll((ruleDefaults['layout'] as Map).cast<String, dynamic>());
        values['layout_origins'] = <String, dynamic>{};
        values['rule_options'] = {
          ...(ruleDefaults['rule_options'] as Map).cast<String, dynamic>(),
          'cleanup_pipeline': ruleDefaults['pipeline'],
        };
        draft = production.draftFromProduction(book, values, importedResources);
        importedHistory = null;
      }
      var importedStructure = source.initialStructure;
      if (existing < 0 &&
          source.originPath == null &&
          (ruleDefaults?['rules'] ??
                  globalConfiguration['recognition_defaults'])
              is Map) {
        final defaults = Map<String, dynamic>.from(
          (ruleDefaults?['rules'] ??
                  globalConfiguration['recognition_defaults'])
              as Map,
        )..['origin'] = 'import_default';
        final recognized = jsonDecode(
          await api.editStructureDraft(
            sourceId: source.sourceId,
            revision: source.revision,
            draftJson: '',
            commandJson: jsonEncode({'op': 'recognize', 'rules': defaults}),
          ),
        ) as Map;
        importedStructure = Map<String, dynamic>.from(
          (recognized['history'] as List).first as Map,
        );
        if (_cancelImport || _disposed) return false;
      }
      change(() {
        if (existing < 0) {
          shelf.books.insert(0, book);
        } else {
          shelf.books[existing] = book;
        }
        production.drafts[id] = draft;
        if (importedStructure != null) {
          manuscript.structures[id] = importedStructure;
        }
        metadata[id] = (draft.title, draft.author);
        if (importedHistory != null) production.histories[id] = importedHistory;
        book.hasCover = draft.coverPath?.isNotEmpty == true;
        currentId = id;
        if (destination == DeskPage.conversion) {
          // A book imported specifically for conversion is the explicit
          // current target.  Keep the library's demo selection untouched,
          // but make the production conversion table start with this source
          // checked instead of showing a populated table with zero output.
          shelf.selected.add(id);
        }
        importStatus = source.originPath == null
            ? '已读取 ${source.lines} 行 · ${source.headings} 个标题 · ${source.encoding}'
            : '已提取 EPUB 工作副本：${source.lines} 行 · ${source.headings} 个标题 · 原 EPUB 未改动';
        if (unavailableRules > 0) {
          importStatus += ' · $unavailableRules 条离线或不可访问规则未参与';
        }
      });
      return true;
    } catch (error) {
      change(() {
        importStatus = error is FormatException
            ? error.message.toString()
            : '读取失败，请检查路径和文件权限。';
      });
      return false;
    } finally {
      change(() => importing = false);
    }
  }

  Map<String, dynamic> projectDocument() {
    final books = shelf.books.where((b) => !b.isDemo).toList();
    return {
      'schema': 1,
      'rule_id': 'builtin-heading-v1',
      'folder_rules': jsonDecode(jsonEncode(folderRules)),
      'project_folder_rules_enabled': projectFolderRulesEnabled,
      'layout_presets': jsonDecode(jsonEncode(layoutPresets)),
      'cleanup_presets': jsonDecode(jsonEncode(cleanupPresets)),
      'recognition_presets': jsonDecode(
        jsonEncode(manuscript.recognitionPresets),
      ),
      if (manuscript.recognitionDrafts[r'$defaults'] != null)
        'recognition_default_draft': manuscript.recognitionDrafts[r'$defaults'],
      'current_path':
          books.where((b) => b.id == currentId).firstOrNull?.path ??
          books.firstOrNull?.path ??
          '',
      'output': output,
      'format': format,
      'books': books.map((b) {
        final d = production.drafts.putIfAbsent(b.id, () => BookDraft(b));
        return {
          'path': b.path,
          if (b.source!.originPath != null) 'origin_path': b.source!.originPath,
          'source_id': b.source!.sourceId,
          if (production.settings(b.id)['metadata_origins'] != null)
            'metadata_origins': production.settings(b.id)['metadata_origins'],
          if (production.settings(b.id)['layout_origins'] != null)
            'layout_origins': production.settings(b.id)['layout_origins'],
          'revision': b.source!.revision,
          'title': d.title,
          'author': d.author,
          'description': d.description,
          ...d.bibliographic,
          'font_size': d.fontSize,
          'font_size_unit': d.fontSizeUnit,
          'fullwidth_indent': d.fullwidthIndent,
          'remove_blank_lines': d.removeBlankLines,
          'line_height': d.lineHeight,
          'text_alignment': d.textAlignment,
          'writing_mode': d.writingMode,
          'vertical_digits': d.verticalDigits,
          'heading_style': d.headingStyle,
          'rule_options': d.ruleOptions,
          if (d.ruleToggleHistory != null)
            'rule_toggle_history': d.ruleToggleHistory,
          'scene_break_style': d.sceneBreakStyle,
          'note_style': d.noteStyle,
          'first_paragraph_style': d.firstParagraphStyle,
          if (d.chapterHeadImage != null)
            'chapter_head_image': d.chapterHeadImage,
          'chapter_head_scope': d.chapterHeadScope,
          'chapter_head_width': d.chapterHeadWidth,
          'system_block_style': d.systemBlockStyle,
          'verse_block_style': d.verseBlockStyle,
          if (d.blockAnnotations.isNotEmpty)
            'block_annotations': d.blockAnnotations,
          if (d.manualNotes.isNotEmpty) 'manual_notes': d.manualNotes,
          if (d.supplementalPages.isNotEmpty)
            'supplemental_pages': d.supplementalPages,
          'additional_css': d.additionalCss,
          'additional_css_base': d.additionalCssBase,
          'additional_css_bundle': d.additionalCssBundle,
          'css_font_permissions': d.cssFontPermissions,
          'paragraph_indent': d.paragraphIndent,
          'paragraph_spacing': d.paragraphSpacing,
          'margin_top': d.marginTop,
          'margin_top_unit': d.marginTopUnit,
          'margin_right': d.marginRight,
          'margin_right_unit': d.marginRightUnit,
          'margin_bottom': d.marginBottom,
          'margin_bottom_unit': d.marginBottomUnit,
          'margin_left': d.marginLeft,
          'margin_left_unit': d.marginLeftUnit,
          'include_toc': d.includeToc,
          'visible_toc': d.visibleToc,
          'chapter_navigation': d.chapterNavigation,
          'cover_path': d.coverPath,
          'cover_fit': d.coverFit,
          'cover_crop': d.coverCrop,
          'cover_design': d.coverDesign,
          'font_family': d.fontFamily,
          'font_resource': d.fontResource,
          if (d.illustrations.isNotEmpty) 'illustrations': d.illustrations,
          if (d.epubResources != null) 'epub_resources': d.epubResources,
          if (production.histories[b.id] != null)
            'production_history': production.histories[b.id],
          'selected': shelf.selected.contains(b.id),
          if (cleanup.drafts[b.id] != null) 'cleanup': cleanup.drafts[b.id],
          if (cleanup.histories[b.id] != null)
            'cleanup_history': cleanup.histories[b.id],
          if (manuscript.structureHistories[b.id] != null)
            'structure_history': manuscript.structureHistories[b.id],
          if (manuscript.structures[b.id] != null)
            'structure': manuscript.structures[b.id],
          if (manuscript.recognitionDrafts[b.id] != null)
            'recognition_draft': manuscript.recognitionDrafts[b.id],
          if (manuscript.findingReviews[b.id] != null)
            'review': manuscript.findingReviews[b.id],
          if (manuscript.effectiveHistories[b.id] != null)
            'effective_history': manuscript.effectiveHistories[b.id],
          if (manuscript.manualEditDrafts[b.id] != null)
            'manual_draft': manuscript.manualEditDrafts[b.id],
          if (_catalogSources[b.id] == b.source!.sourceId &&
              _bookCatalogs[b.id] != null)
            'reference_catalog': _bookCatalogs[b.id],
        };
      }).toList(),
    };
  }

  Future<bool> saveProjectOutcome(String path) async {
    if (!canSaveProject) return false;
    change(() {
      projectBusy = true;
      projectStatus = '正在保存项目…';
    });
    try {
      final changes = <String, Map<String, dynamic>>{
        for (final book in shelf.books.where(
          (b) => !b.isDemo && production.histories.containsKey(b.id),
        ))
          book.id: {'op': 'inspect'},
      };
      if (changes.isNotEmpty) {
        final p = await production.previewChanges(changes);
        if (!await production.confirm(p)) {
          throw FormatException(production.batchStatus);
        }
      }
      // Freeze both the persisted document and its identity before yielding.
      // Later edits remain dirty even when this save completes successfully.
      final payload =
          jsonDecode(jsonEncode(projectDocument())) as Map<String, dynamic>;
      final savedIdentity = jsonEncode(
        Map<String, dynamic>.from(payload)..remove('current_path'),
      );
      await _projectSaver(path.trim(), payload);
      change(() {
        projectPath = path.trim();
        savedProjectIdentity = savedIdentity;
        projectStatus = '项目已另存。移动项目时请同时移动配套 CSS 资源和编辑检查点目录；原稿及其他外部资源仍为引用。';
      });
      return true;
    } catch (error) {
      change(
        () => projectStatus = error is FormatException
            ? error.message.toString()
            : '项目保存失败，原有文件未被覆盖。',
      );
      return false;
    } finally {
      change(() => projectBusy = false);
    }
  }

  Future<bool> openProjectOutcome(String path) async {
    return _replaceProject(path, () => _projectOpener(path.trim()));
  }

  Future<bool> clearWorkspace() => _replaceProject(
    '',
    () async => (jsonDecode(
      await api.clearWorkspaceText(output: output, format: format),
    ) as Map).cast<String, dynamic>(),
    clearing: true,
  );

  Future<bool> _replaceProject(
    String path,
    Future<Map<String, dynamic>> Function() load, {
    bool clearing = false,
  }) async {
    if (importing ||
        projectBusy ||
        cleanup.historyBusy ||
        production.busy ||
        queueActive) {
      return false;
    }
    change(() {
      projectBusy = true;
      projectStatus = '正在验证项目及原稿…';
    });
    try {
      final result = await load();
      final openedIssues = (result['resource_issues'] as List? ?? const [])
          .cast<Map>();
      final doc = result['project'] as Map<String, dynamic>;
      final restoredCleanupPresets = (doc['cleanup_presets'] as List? ?? [])
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
      final restoredRecognitionPresets =
          (doc['recognition_presets'] as List? ?? [])
              .map((p) => Map<String, dynamic>.from(p as Map))
              .toList();
      final restoredLayoutPresets = (doc['layout_presets'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final restoredFolderRules = (doc['folder_rules'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final rows = (doc['books'] as List).cast<Map<String, dynamic>>();
      final summaries = (result['summaries'] as List)
          .cast<Map<String, dynamic>>();
      final books = <SampleBook>[];
      final drafts = <String, BookDraft>{};
      final selection = <String>{};
      final catalogs = <String, Map<String, dynamic>>{};
      final reviews = <String, Map<String, dynamic>>{};
      final effectiveHistory = <String, Map<String, dynamic>>{};
      final manualDrafts = <String, Map<String, dynamic>>{};
      final cleanups = <String, Map<String, dynamic>>{};
      final cleanupHistory = <String, Map<String, dynamic>>{};
      final productionHistory = <String, Map<String, dynamic>>{};
      final structures = <String, Map<String, dynamic>>{};
      final recognition = <String, Map<String, dynamic>>{};
      if (doc['recognition_default_draft'] is Map) {
        recognition[r'$defaults'] = Map<String, dynamic>.from(
          doc['recognition_default_draft'] as Map,
        );
      }
      final structuralHistory = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final path = row['path'] as String;
        final summary = summaries.firstWhere((s) => s['path'] == path);
        final source = ImportedTxt(
          path: path,
          sourceId: summary['source_id'] as String,
          revision: summary['revision'] as int,
          encoding: summary['encoding'] as String,
          lines: summary['lines'] as int,
          headings: summary['headings'] as int,
          originPath: row['origin_path'] as String?,
          resourceReport: (row['epub_resources'] as Map?)
              ?.cast<String, dynamic>(),
        );
        final b = SampleBook(
          (source.originPath ?? path).toLowerCase(),
          row['title'] as String,
          row['author'] as String,
          source.headings,
          '已识别 · 尚未检查',
          source: source,
          format: bookFormatForPath(source.originPath ?? path),
          hasCover: false,
        );
        books.add(b);
        if (row['cleanup'] is Map) {
          cleanups[b.id] = (row['cleanup'] as Map).cast<String, dynamic>();
        }
        if (row['production_history'] is Map) {
          productionHistory[b.id] = (row['production_history'] as Map)
              .cast<String, dynamic>();
        }
        if (row['cleanup_history'] is Map) {
          cleanupHistory[b.id] = (row['cleanup_history'] as Map)
              .cast<String, dynamic>();
        }
        if (row['structure_history'] is Map) {
          structuralHistory[b.id] = (row['structure_history'] as Map)
              .cast<String, dynamic>();
        }
        if (row['structure'] is Map) {
          structures[b.id] = (row['structure'] as Map).cast<String, dynamic>();
        }
        if (row['recognition_draft'] is Map) {
          recognition[b.id] = Map<String, dynamic>.from(
            row['recognition_draft'] as Map,
          );
        }
        if (row['review'] is Map) {
          reviews[b.id] = (row['review'] as Map).cast<String, dynamic>();
        }
        if (row['effective_history'] is Map) {
          effectiveHistory[b.id] = (row['effective_history'] as Map)
              .cast<String, dynamic>();
        }
        if (row['manual_draft'] is Map) {
          manualDrafts[b.id] = (row['manual_draft'] as Map)
              .cast<String, dynamic>();
        }
        if (row['reference_catalog'] is Map) {
          catalogs[b.id] = (row['reference_catalog'] as Map)
              .cast<String, dynamic>();
        }
        drafts[b.id] = BookDraft(b)
          ..metadataOrigins = Map<String, dynamic>.from(
            row['metadata_origins'] as Map? ?? {},
          )
          ..layoutOrigins = Map<String, dynamic>.from(
            row['layout_origins'] as Map? ?? {},
          )
          ..description = row['description'] as String
          ..bibliographic = {
            for (final key in bibliographicFields.keys)
              key: row[key] as String? ?? '',
          }
          ..fontSize = (row['font_size'] as num).toDouble()
          ..fontSizeUnit = row['font_size_unit'] as String? ?? 'px'
          ..fullwidthIndent = (row['fullwidth_indent'] as num? ?? 0).toInt()
          ..removeBlankLines = row['remove_blank_lines'] == true
          ..lineHeight = (row['line_height'] as num).toDouble()
          ..textAlignment = row['text_alignment'] as String? ?? 'start'
          ..writingMode = row['writing_mode'] as String? ?? 'horizontal'
          ..verticalDigits = (row['vertical_digits'] as num? ?? 2).toInt()
          ..headingStyle = row['heading_style'] as String? ?? 'classic'
          ..ruleOptions = Map<String, dynamic>.from(
            row['rule_options'] as Map? ?? {},
          )
          ..ruleToggleHistory = (row['rule_toggle_history'] as Map?)
              ?.cast<String, dynamic>()
          ..sceneBreakStyle = row['scene_break_style'] as String? ?? 'keep'
          ..noteStyle = row['note_style'] as String? ?? 'off'
          ..firstParagraphStyle =
              row['first_paragraph_style'] as String? ?? 'normal'
          ..chapterHeadImage = row['chapter_head_image'] as String?
          ..chapterHeadScope = row['chapter_head_scope'] as String? ?? 'chapter'
          ..chapterHeadWidth = row['chapter_head_width'] as String? ?? 'half'
          ..systemBlockStyle = row['system_block_style'] as String? ?? 'box'
          ..verseBlockStyle = row['verse_block_style'] as String? ?? 'center'
          ..blockAnnotations = (row['block_annotations'] as List? ?? [])
              .map((a) => Map<String, dynamic>.from(a as Map))
              .toList()
          ..manualNotes = (row['manual_notes'] as List? ?? [])
              .map((a) => Map<String, dynamic>.from(a as Map))
              .toList()
          ..supplementalPages = (row['supplemental_pages'] as List? ?? [])
              .map((a) => Map<String, dynamic>.from(a as Map))
              .toList()
          ..additionalCss = row['additional_css'] as String? ?? ''
          ..additionalCssBase = row['additional_css_base'] as String? ?? ''
          ..cssFontPermissions =
              (row['css_font_permissions'] as List? ?? const []).cast<String>()
          ..additionalCssBundle = (row['additional_css_bundle'] as Map?)
              ?.cast<String, dynamic>()
          ..paragraphIndent = (row['paragraph_indent'] as num? ?? 2.0)
              .toDouble()
          ..paragraphSpacing = (row['paragraph_spacing'] as num? ?? 0.5)
              .toDouble()
          ..marginTop = (row['margin_top'] as num? ?? 0.0).toDouble()
          ..marginTopUnit = row['margin_top_unit'] as String? ?? 'em'
          ..marginRight = (row['margin_right'] as num? ?? 0.0).toDouble()
          ..marginRightUnit = row['margin_right_unit'] as String? ?? 'em'
          ..marginBottom = (row['margin_bottom'] as num? ?? 0.0).toDouble()
          ..marginBottomUnit = row['margin_bottom_unit'] as String? ?? 'em'
          ..marginLeft = (row['margin_left'] as num? ?? 0.0).toDouble()
          ..marginLeftUnit = row['margin_left_unit'] as String? ?? 'em'
          ..visibleToc = row['visible_toc'] as bool? ?? false
          ..chapterNavigation = row['chapter_navigation'] as bool? ?? false
          ..includeToc = row['include_toc'] as bool;
        if (row['cover_path'] is String &&
            (row['cover_path'] as String).trim().isNotEmpty) {
          drafts[b.id]!.coverPath = (row['cover_path'] as String).trim();
        }
        drafts[b.id]!
          ..coverFit = (row['cover_fit'] as String?) ?? 'cover'
          ..coverCrop = (row['cover_crop'] as Map?)?.cast<String, dynamic>()
          ..coverDesign = (row['cover_design'] as Map?)?.cast<String, dynamic>()
          ..fontFamily = (row['font_family'] as String?) ?? 'Microsoft YaHei'
          ..fontResource = (row['font_resource'] as Map?)
              ?.cast<String, dynamic>()
          ..epubResources = (row['epub_resources'] as Map?)
              ?.cast<String, dynamic>()
          ..illustrations = (row['illustrations'] as List? ?? const [])
              .whereType<Map>()
              .map((item) => item.cast<String, dynamic>())
              .toList();
        if (row['selected'] as bool) selection.add(b.id);
      }
      final currentSourcePath = (doc['current_path'] as String).toLowerCase();
      final nextId =
          books
              .where((b) => b.source!.path.toLowerCase() == currentSourcePath)
              .firstOrNull
              ?.id ??
          currentSourcePath;
      if (books.isEmpty
          ? nextId.isNotEmpty
          : !books.any((b) => b.id == nextId)) {
        throw const FormatException('项目缺少当前书记录。');
      }
      change(() {
        removalEpoch++;
        bookMembership.clear();
        shelf.books
          ..clear()
          ..addAll(books);
        production.drafts
          ..clear()
          ..addAll(drafts);
        metadata.clear();
        shelf.selected
          ..clear()
          ..addAll(selection);
        currentId = nextId;
        output = doc['output'] as String;
        format = doc['format'] as String;
        cleanup.drafts
          ..clear()
          ..addAll(cleanups);
        cleanup.histories
          ..clear()
          ..addAll(cleanupHistory);
        cleanup.historyStatus.clear();
        production.coverInputs.clear();
        production.resourceIssues.clear();
        production.publicationReports.clear();
        for (final issue in openedIssues) {
          final sourcePath = (issue['book_path'] as String).toLowerCase();
          final id =
              books
                  .where((b) => b.source!.path.toLowerCase() == sourcePath)
                  .firstOrNull
                  ?.id ??
              sourcePath;
          production.resourceIssues
              .putIfAbsent(id, () => [])
              .add(issue.cast<String, dynamic>());
        }
        folderRules = restoredFolderRules;
        projectFolderRulesEnabled = doc['project_folder_rules_enabled'] == true;
        layoutPresets = restoredLayoutPresets;
        cleanupPresets = restoredCleanupPresets;
        manuscript.recognitionPresets = restoredRecognitionPresets;
        manuscript.recognitionDrafts
          ..clear()
          ..addAll(recognition);
        production.histories
          ..clear()
          ..addAll(productionHistory);
        manuscript.structureHistories
          ..clear()
          ..addAll(structuralHistory);
        manuscript.structures
          ..clear()
          ..addAll(structures);
        manuscript.findingReviews
          ..clear()
          ..addAll(reviews);
        manuscript.effectiveHistories
          ..clear()
          ..addAll(effectiveHistory);
        manuscript.manualEditDrafts
          ..clear()
          ..addAll(manualDrafts);
        _bookCatalogs
          ..clear()
          ..addAll(catalogs);
        _catalogSources
          ..clear()
          ..addEntries(books.map((b) => MapEntry(b.id, b.source!.sourceId)));
        projectPath = path.trim();
        savedProjectIdentity = projectIdentity;
        projectStatus = clearing
            ? '当前工作区已清空，原文件和已保存项目保留。'
            : '项目已打开，原稿指纹全部一致。${openedIssues.isEmpty ? '' : '打开时发现 ${openedIssues.length} 项外部资源需要重新定位，可从项目菜单处理；资源准备暂不可用。'}${catalogs.isEmpty ? '' : '已离线恢复目录快照；使用前需重新确认。'}';
        importStatus = '';
      });
      return true;
    } catch (error) {
      change(
        () => projectStatus = error is FormatException
            ? error.message.toString()
            : '项目打开失败，请检查文件。',
      );
      return false;
    } finally {
      change(() => projectBusy = false);
    }
  }

  void cancelImport() => change(() {
    _cancelImport = true;
    importStatus = '正在取消，请稍候…';
  });
}
