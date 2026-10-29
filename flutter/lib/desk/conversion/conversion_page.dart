// 转换（D4-F，V8 按设计重写视图）：草稿、默认继承、预检、确认与启动逻辑沿用原实现。
import 'dart:async';

import 'package:flutter/material.dart';

import '../errors.dart';

import '../dialogs.dart' show DeskAlert;

import 'package:flutter/foundation.dart' show mapEquals;

import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/conversion_service.dart';
import '../../application/conversion_defaults.dart';
import '../../application/conversion_desktop.dart';
import '../../application/library_service.dart';
import '../../application/settings_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/controls.dart';
import '../controls/drag_select.dart';
import '../library/book_structure_counts.dart';
import '../library/book_summary_panel.dart'
    show LibraryCover, bookStatusLabel, bookStatusTip, chapterIssueCount;
import 'preflight_panel.dart';
import 'output_folder_dialog.dart';
import 'conversion_options_dialog.dart';
import 'conversion_form_draft.dart';

export 'conversion_form_draft.dart';

class ConversionPage extends StatefulWidget {
  const ConversionPage({
    super.key,
    required this.library,
    required this.picker,
    required this.openRepair,
    required this.desktop,
    required this.session,
    this.retryBooks,
    this.initialBooks,
    this.recheckOnOpen = false,
    required this.draft,
    this.showActions = true,
  });
  final LibraryService library;
  final BookFilePicker picker;
  final ConversionDesktop desktop;
  final ConversionSession session;
  final List<String>? retryBooks;
  final List<String>? initialBooks;
  final bool recheckOnOpen;
  final ConversionFormDraft draft;
  final bool showActions;
  final void Function(String bookId, String page) openRepair;
  @override
  State<ConversionPage> createState() => _ConversionPageState();
}

class _ConversionPageState extends State<ConversionPage> {
  ConversionSession get session => widget.session;
  late final selected = {...widget.library.selection.value.selected};
  final destination = TextEditingController(), engine = TextEditingController();
  String format = 'EPUB', message = '', language = '';
  bool generateCover = true;
  bool autoCheck = false;
  String? completedDirectory;
  bool loadingDefaults = false;
  ConversionPreview? preview;
  bool picking = false, openWhenDone = false;

  /// 本次书稿列表只显示已勾选的书（OUT-064）。
  bool onlySelected = false;
  bool applyingDefaults = false,
      readingSettings = false,
      defaultsError = false,
      resolvingDefaults = false;
  int defaultsGeneration = 0, formRevision = 0;
  late bool recheckPending = widget.recheckOnOpen;
  bool recheckScheduled = false;
  Map<String, Object>? observedDefaults, latestDefaults, pendingDefaults;
  SettingsService? get settings => widget.library is SettingsService
      ? widget.library as SettingsService
      : null;
  Map<String, Object> get formDefaults => {
    'output_directory': destination.text,
    'output_format': format,
    'kindle_converter': engine.text,
    'generate_cover': generateCover,
    'check_before_conversion': autoCheck,
  };
  void invalidatePreview() {
    formRevision++;
    preview = null;
    widget.draft.reviewing.value = false;
  }

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    draft.bindActiveForm(
      this,
      onChangeFormat: selectFormat,
      onChangeDirectory: (value) =>
          editForm(() => destination.text = value, field: 'output_directory'),
      onCheckConversion: () => convert(),
      onStartConversion: () => preview == null
          ? convert(runChecks: autoCheck, startImmediately: true)
          : commitPreview(acknowledgeWarnings: preview!.needsAcknowledgement),
    );
    final reconfigure = widget.retryBooks != null && !session.busy;
    if (reconfigure) draft.reset();
    preview = draft.pendingPreview;
    draft.pendingPreview = null;
    final previous = reconfigure ? null : session.request;
    if (draft.initialized) {
      destination.text = draft.directory;
      engine.text = draft.engine;
      format = draft.format;
      language = draft.language;
      generateCover = draft.generateCover;
      autoCheck = draft.autoCheck;
      openWhenDone = draft.openWhenDone;
      if (draft.selectionInitialized) {
        selected
          ..clear()
          ..addAll(draft.selected);
      }
    }
    if (previous != null && !draft.initialized) {
      destination.text = previous.directory;
      engine.text = previous.engine;
      format = previous.format;
      language = previous.language;
      generateCover = previous.generateCover;
      autoCheck = previous.runChecks;
      draft.manualDefaults.addAll(ConversionFormDraft.defaultLabels.keys);
      selected
        ..clear()
        ..addAll(previous.books);
    }
    if (session.outputs.any((o) => o.complete)) {
      completedDirectory = previous?.directory;
    }
    if (widget.initialBooks != null && !session.busy) {
      preview = null;
      selected
        ..clear()
        ..addAll(widget.initialBooks!);
    }
    final selectedCount = selected.length;
    selected.retainAll(widget.library.books.value.map((b) => b.id));
    if (selected.length != selectedCount) preview = null;
    if (widget.retryBooks != null && !session.busy) {
      final available = widget.library.books.value.map((b) => b.id).toSet();
      selected
        ..clear()
        ..addAll(widget.retryBooks!.where((id) => available.contains(id)));
      message = selected.isEmpty
          ? '原书稿未载入，请打开原项目或重新导入。'
          : '已选择当前书稿；使用当前默认设置创建新批次，请核对后转换。';
    }
    draft.selected = {...selected};
    draft.selectionInitialized = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.draft.reviewing.value = preview != null;
        maybeRecheck();
      }
    });
    session.changes.addListener(refresh);
    widget.library.books.addListener(refresh);
    destination.addListener(pathChanged);
    engine.addListener(pathChanged);
    if (settings != null) {
      // Drafts from an old caller or an existing task have no provenance.
      // Preserve their values instead of guessing that they were inherited.
      if ((draft.initialized || previous != null) &&
          draft.defaultValues == null) {
        draft.manualDefaults.addAll(ConversionFormDraft.defaultLabels.keys);
        saveDraft();
      }
      settings!.snapshot.addListener(settingsChanged);
      loadingDefaults = !draft.initialized;
      // Loading settings notifies workspace listeners; wait until the route
      // has mounted so ancestors are not invalidated during their build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadDefaults();
      });
    } else {
      saveDraft();
      loadConverter();
      loadOutputDirectory();
    }
  }

  bool get readyForRecheck =>
      mounted &&
      !session.busy &&
      !readingSettings &&
      !loadingDefaults &&
      !resolvingDefaults &&
      !defaultsError &&
      widget.draft.initialized;
  void maybeRecheck() {
    if (!recheckPending || recheckScheduled || !readyForRecheck) return;
    recheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      recheckScheduled = false;
      if (!readyForRecheck) return;
      recheckPending = false;
      convert();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void settingsChanged() {
    final service = settings;
    if (!mounted || service == null || readingSettings || session.busy) return;
    final snapshot = service.snapshot.value;
    if (!snapshot.loaded || snapshot.busy) return;
    synchronizeDefaults(snapshot.configuration);
  }

  Map<String, Object> rawDefaults(Map<String, dynamic> config) =>
      readConversionDefaults(config);

  Future<void> synchronizeDefaults(Map<String, dynamic> config) async {
    final raw = rawDefaults(config);
    if (mapEquals(observedDefaults, raw)) return;
    final ticket = ++defaultsGeneration;
    observedDefaults = raw;
    setState(() => resolvingDefaults = true);
    try {
      final resolved = await resolveConversionDefaults(
        raw,
        widget.desktop,
        format: widget.draft.manualDefaults.contains('output_format')
            ? format
            : null,
      );
      if (!mounted || ticket != defaultsGeneration) return;
      if (session.busy) {
        observedDefaults = null;
        return;
      }
      final draft = widget.draft, before = draft.defaultValues;
      final changed = ConversionFormDraft.defaultLabels.keys
          .where(
            (key) =>
                !draft.manualDefaults.contains(key) &&
                (before == null || before[key] != resolved[key]),
          )
          .toList();
      setState(() {
        latestDefaults = resolved;
        defaultsError = false;
        if (before == null ||
            (draft.manualDefaults.isEmpty &&
                preview == null &&
                pendingDefaults == null)) {
          adoptDefaults(resolved);
          if (before != null && changed.isNotEmpty) {
            message = '已更新继承的默认设置，请按当前设置转换。';
          }
        } else if (changed.isEmpty) {
          draft.defaultValues = Map.unmodifiable(resolved);
          pendingDefaults = null;
        } else {
          pendingDefaults = resolved;
          invalidatePreview();
        }
      });
    } catch (_) {
      if (mounted && ticket == defaultsGeneration) {
        observedDefaults = null;
        setState(() {
          defaultsError = true;
          message = '默认设置读取失败，当前值已保留；请重新读取。';
        });
      }
    } finally {
      if (mounted && ticket == defaultsGeneration) {
        setState(() => resolvingDefaults = false);
        maybeRecheck();
      }
    }
  }

  void adoptDefaults(Map<String, Object> values, {bool reset = false}) {
    final draft = widget.draft;
    if (reset) draft.manualDefaults.clear();
    applyingDefaults = true;
    try {
      if (!draft.manualDefaults.contains('output_directory')) {
        destination.text = values['output_directory'] as String;
      }
      if (!draft.manualDefaults.contains('output_format')) {
        format = values['output_format'] as String;
      }
      if (!draft.manualDefaults.contains('kindle_converter')) {
        engine.text =
            (format == 'KFX'
                    ? values['kfx_converter']
                    : values['kindling_path'])
                as String? ??
            values['kindle_converter'] as String;
      }
      if (!draft.manualDefaults.contains('generate_cover')) {
        generateCover = values['generate_cover'] as bool;
      }
      if (!draft.manualDefaults.contains('check_before_conversion')) {
        autoCheck = values['check_before_conversion'] as bool;
      }
      draft.defaultValues = Map.unmodifiable(values);
      pendingDefaults = null;
      invalidatePreview();
      saveDraft();
    } finally {
      applyingDefaults = false;
    }
  }

  /// 保留当前设置：与新默认不同的继承项改记为手工设置，提示条随之关闭。
  void keepCurrentDefaults(
    Map<String, Object> shown,
    Map<String, Object> current,
  ) {
    for (final key in ConversionFormDraft.defaultLabels.keys) {
      if (widget.draft.defaultValues?[key] != shown[key] &&
          current[key] != shown[key]) {
        widget.draft.manualDefaults.add(key);
      }
    }
    widget.draft.defaultValues = Map.unmodifiable(shown);
    pendingDefaults = null;
    invalidatePreview();
    saveDraft();
  }

  /// 默认设置变更提示（OUT-066）：写明哪些继承项会更新、哪些手工设置保留。
  String defaultsChangeText(Map<String, Object> next) {
    final draft = widget.draft, current = formDefaults;
    final labels = ConversionFormDraft.defaultLabels;
    final inherit = [
      for (final key in labels.keys)
        if (!draft.manualDefaults.contains(key) &&
            draft.defaultValues?[key] != next[key])
          labels[key]!,
    ];
    final manual = [
      for (final key in labels.keys)
        if (draft.manualDefaults.contains(key) && current[key] != next[key])
          labels[key]!,
    ];
    final parts = [
      if (inherit.isNotEmpty) '${inherit.join('、')}可更新为新的默认值',
      if (manual.isNotEmpty) '${manual.join('、')}是手工设置，保留不变',
    ];
    return parts.isEmpty ? '默认设置已更新。' : '默认设置已更新：${parts.join('；')}。';
  }

  Future<void> reviewDefaults() async {
    final values = pendingDefaults ?? latestDefaults;
    if (values == null || session.busy) return;
    final shown = Map<String, Object>.from(values);
    final current = formDefaults;
    String display(Object? value) => value is bool
        ? (value ? '开启' : '关闭')
        : value == ''
        ? '未设置'
        : '$value';
    final decision = await showDialog<String>(
      context: context,
      builder: (context) => DeskAlert(
        title: const Text('默认设置与继承'),
        scrollable: true,
        content: SizedBox(
          width: 740,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('手工设置保留；更新继承项会作废旧预览。原批次和正在执行的任务不受影响。'),
              const SizedBox(height: 16),
              for (final entry in ConversionFormDraft.defaultLabels.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        entry.value,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '当前：${display(current[entry.key])}\n默认：${display(shown[entry.key])}',
                      ),
                      Text(
                        widget.draft.manualDefaults.contains(entry.key)
                            ? '手工设置 · 保留'
                            : current[entry.key] == shown[entry.key]
                            ? '继承 · 不变'
                            : '继承 · 更新',
                        style: TextStyle(color: context.desk.accent),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (pendingDefaults != null)
            TextButton(
              onPressed: () => Navigator.pop(context, 'keep'),
              child: const Text('保留当前设置'),
            ),
          if (widget.draft.manualDefaults.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, 'reset'),
              child: const Text('全部恢复默认继承'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'update'),
            child: const Text('更新继承项并重新预览'),
          ),
        ],
      ),
    );
    if (!mounted || decision == null || session.busy) return;
    if (resolvingDefaults || !mapEquals(latestDefaults, shown)) {
      setState(() => message = '默认设置再次变化，请重新查看差异。');
      return;
    }
    setState(() {
      if (decision == 'keep') {
        keepCurrentDefaults(shown, current);
      } else {
        adoptDefaults(shown, reset: decision == 'reset');
      }
    });
    if (decision == 'update' && selected.isNotEmpty) {
      await convert(runChecks: autoCheck);
    }
  }

  Future<void> loadOutputDirectory() async {
    final desktop = widget.desktop;
    if (widget.draft.manualDefaults.contains('output_directory') ||
        destination.text.trim().isNotEmpty ||
        desktop is! OutputDirectoryDesktop) {
      return;
    }
    setState(() => loadingDefaults = true);
    try {
      final path = await (desktop as OutputDirectoryDesktop)
          .defaultOutputDirectory();
      if (mounted &&
          !widget.draft.manualDefaults.contains('output_directory') &&
          destination.text.trim().isEmpty) {
        destination.text = path;
      }
      if (mounted) saveDraft();
    } catch (_) {
      if (mounted) message = '无法取得桌面位置，请选择输出文件夹。';
    } finally {
      if (mounted) setState(() => loadingDefaults = false);
    }
  }

  Future<void> loadDefaults() async {
    final service = settings;
    if (service == null || readingSettings) return;
    setState(() => readingSettings = true);
    try {
      if (!await service.load()) throw StateError('settings unavailable');
      if (!mounted) return;
      defaultsError = false;
      if (message.startsWith('默认设置读取失败')) message = '';
      await synchronizeDefaults(service.snapshot.value.configuration);
    } catch (_) {
      if (mounted) {
        setState(() {
          defaultsError = true;
          message = '默认设置读取失败，当前值已保留；请重新读取。';
        });
      }
    } finally {
      readingSettings = false;
      if (mounted) {
        setState(() => loadingDefaults = false);
        // A setting may have changed while desktop/engine resolution awaited.
        if (!defaultsError) settingsChanged();
        maybeRecheck();
      }
    }
  }

  void editForm(VoidCallback change, {String? field}) {
    setState(() {
      invalidatePreview();
      if (field != null) widget.draft.manualDefaults.add(field);
      change();
    });
    widget.draft.reviewing.value = false;
    saveDraft();
  }

  void refresh() {
    if (mounted) {
      final previousCount = selected.length;
      selected.retainAll(widget.library.books.value.map((book) => book.id));
      if (selected.length != previousCount) {
        invalidatePreview();
        saveDraft();
      }
      settingsChanged();
      maybeRecheck();
      setState(() {
        if (session.outputs.any((o) => o.complete)) {
          completedDirectory = session.request?.directory;
        }
      });
    }
  }

  @override
  void dispose() {
    widget.draft.unbindActiveForm(this);
    session.changes.removeListener(refresh);
    widget.library.books.removeListener(refresh);
    defaultsGeneration++;
    settings?.snapshot.removeListener(settingsChanged);
    destination.dispose();
    engine.dispose();
    super.dispose();
  }

  void pathChanged() {
    if (loadingDefaults || applyingDefaults) return;
    if (preview != null && mounted) {
      setState(() {
        preview = null;
      });
      widget.draft.reviewing.value = false;
    }
    saveDraft();
  }

  void saveDraft() {
    widget.draft
      ..initialized = true
      ..directory = destination.text
      ..engine = engine.text
      ..format = format
      ..language = language
      ..generateCover = generateCover
      ..autoCheck = autoCheck
      ..openWhenDone = openWhenDone
      ..selectionInitialized = true
      ..selected = {...selected};
    widget.draft.changed();
  }

  Future<void> browse() async {
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OutputFolderDialog(
        library: widget.library,
        picker: widget.picker,
        initialPath: destination.text.trim(),
      ),
    );
    if (mounted && path != null) {
      editForm(() => destination.text = path, field: 'output_directory');
    }
  }

  Future<void> selectFormat(String name) async {
    final changesEngine = (format == 'KFX') != (name == 'KFX');
    editForm(() => format = name, field: 'output_format');
    if (!changesEngine) return;
    widget.draft.manualDefaults.remove('kindle_converter');
    final ticket = ++defaultsGeneration;
    setState(() => resolvingDefaults = true);
    try {
      final values = await resolveConversionDefaults(
        observedDefaults ?? readConversionDefaults(const {}),
        widget.desktop,
        format: name,
      );
      if (!mounted || ticket != defaultsGeneration) return;
      applyingDefaults = true;
      engine.text =
          (format == 'KFX' ? values['kfx_converter'] : values['kindling_path'])
              as String? ??
          values['kindle_converter'] as String;
      applyingDefaults = false;
      latestDefaults = values;
      widget.draft.defaultValues = Map.unmodifiable(values);
      pendingDefaults = null;
      saveDraft();
    } catch (_) {
      if (mounted && ticket == defaultsGeneration) {
        setState(() {
          engine.clear();
          message = '无法定位转换器，请在高级设置中选择。';
        });
      }
    } finally {
      if (mounted && ticket == defaultsGeneration) {
        setState(() => resolvingDefaults = false);
      }
    }
  }

  Future<void> advancedOptions() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConversionOptionsDialog(
        autosave: widget.library is WorkspaceAutosaveService
            ? widget.library as WorkspaceAutosaveService
            : null,
        engine: engine.text,
        format: format,
        desktop: widget.desktop,
      ),
    );
    if (!mounted || result == null) return;
    editForm(() {
      if (result['engineEdited'] == true) {
        widget.draft.manualDefaults.add('kindle_converter');
      }
      engine.text = result['engine'] as String;
    });
  }

  Future<void> loadConverter() async {
    try {
      final selectedFormat = format;
      final desktop = widget.desktop;
      final path = selectedFormat == 'KFX'
          ? desktop is KfxConversionDesktop
                ? await (desktop as KfxConversionDesktop).bundledKfxConverter()
                : null
          : await desktop.bundledConverter();
      if (mounted &&
          !widget.draft.manualDefaults.contains('kindle_converter') &&
          path != null &&
          format == selectedFormat &&
          engine.text.isEmpty) {
        setState(() => engine.text = path);
      }
    } catch (_) {
      if (mounted) setState(() => message = '未能读取便携转换器，可通过浏览选择。');
    }
  }

  Future<void> openOutput(String path) async {
    try {
      await widget.desktop.openDirectory(path);
    } catch (e) {
      if (mounted) {
        setState(() => message = deskErrorText(e, '无法打开输出目录；已生成的文件保留。'));
      }
    }
  }

  Future<void> addBooks() async {
    setState(() => picking = true);
    try {
      final paths = await widget.picker.chooseBooks();
      if (!mounted || paths.isEmpty) return;
      final before = widget.library.books.value.map((b) => b.id).toSet();
      final results = await widget.library.importFiles(paths);
      if (mounted) {
        editForm(() {
          selected.addAll(
            widget.library.books.value
                .where((b) => !before.contains(b.id))
                .map((b) => b.id),
          );
          message = results.any((r) => !r.succeeded) ? '部分书稿导入失败，请在书库核对。' : '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = deskErrorText(
            e,
            '书稿没有导入：文件可能不是 TXT / EPUB，或正被其他程序占用。关闭占用后再导入。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> convert({
    bool runChecks = true,
    bool startImmediately = false,
  }) async {
    if (loadingDefaults ||
        readingSettings ||
        resolvingDefaults ||
        defaultsError ||
        !widget.draft.initialized) {
      setState(() => message = '请先完成默认设置读取后再转换。');
      return;
    }
    if (pendingDefaults != null) {
      await reviewDefaults();
      return;
    }
    final revision = formRevision;
    final outputDirectory = destination.text.trim();
    setState(() => message = runChecks ? '正在检查书稿和输出路径…' : '正在准备转换…');
    try {
      final plan = await session.preview(
        ConversionRequest(
          books: selected.toList(),
          directory: outputDirectory,
          format: format,
          engine: engine.text,
          language: language,
          generateCover: generateCover,
          runChecks: runChecks,
          keepOriginalEpub: keepOriginalEpubFor(
            widget.draft,
            widget.library,
            selected,
          ),
        ),
      );
      if (!mounted || revision != formRevision) return;
      if (!plan.previewed) {
        setState(() => message = '当前输出无法执行，请查看具体原因。');
        final retry = await showDialog<bool>(
          context: context,
          builder: (context) => PreflightBlockedDialog(
            plan: plan,
            openRepair: (id, page) {
              Navigator.pop(context, false);
              widget.openRepair(id, page);
            },
          ),
        );
        if (mounted && retry == true) {
          await convert(
            runChecks: runChecks,
            startImmediately: startImmediately,
          );
        }
        return;
      }
      setState(() {
        preview = plan;
        message = '';
      });
      widget.draft.reviewing.value = true;
      if (startImmediately) {
        final conflicts = plan.findings
            .where((f) => f.title == '同名文件需要确认')
            .toList();
        if (conflicts.isNotEmpty) {
          final approved = await showDialog<bool>(
            context: context,
            builder: (context) => DeskAlert(
              title: const Text('保留已有文件并生成新文件？'),
              content: SingleChildScrollView(
                child: Text(conflicts.map((f) => f.detail).join('\n')),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('保留并转换'),
                ),
              ],
            ),
          );
          if (approved != true || !mounted) return;
        }
        await commitPreview(acknowledgeWarnings: conflicts.isNotEmpty);
      }
    } catch (e) {
      if (mounted) {
        setState(() => message = deskErrorText(e, '检查未完成，请检查书稿、资源或输出路径后重试。'));
      }
    }
  }

  Future<void> commitPreview({required bool acknowledgeWarnings}) async {
    final plan = preview;
    if (plan == null || !plan.previewed || !session.isCurrent(plan)) {
      return;
    }
    final outputDirectory = destination.text.trim();
    final openAfter = openWhenDone;
    setState(() => preview = null);
    widget.draft.reviewing.value = false;
    try {
      final result = await session.commit(
        plan,
        acknowledgeWarnings: acknowledgeWarnings,
      );
      if (mounted) {
        if (result.any((r) => r.status == '已完成')) {
          completedDirectory = outputDirectory;
        }
        setState(
          () => message =
              '已完成 ${result.where((r) => r.status == '已完成').length}/${result.length} 本，请核对成品。',
        );
      }
      if (openAfter && result.isNotEmpty && result.every((r) => r.complete)) {
        await openOutput(outputDirectory);
      }
    } catch (e) {
      if (mounted) {
        setState(() => message = deskErrorText(e, '转换未完成，请检查书稿、资源或输出路径后重试。'));
      }
    }
  }

  Widget formatCard(String name, String detail, bool busy) {
    final d = context.desk;
    final on = format == name;
    return Material(
      color: d.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(color: on ? d.ink2 : d.line, width: on ? 1.6 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : () => selectFormat(name),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(name, style: ui(15, w: 650, c: d.ink)),
                  if (name == 'MOBI') const DeskTag('兼容模式', Tone.neutral),
                ],
              ),
              const SizedBox(height: 4),
              Tooltip(
                message: detail,
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(11.5, c: d.ink2, h: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget switchRow(
    String title,
    bool value,
    ValueChanged<bool>? onChanged, {
    String? note,
  }) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: ui(13, c: d.ink)),
                if (note != null)
                  Text(note, style: ui(11.5, c: d.ink3, h: 1.4)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget booksCard(
    List<BookSummary> all,
    bool busy, {
    required double listHeight,
  }) {
    final d = context.desk;
    final books = onlySelected
        ? all.where((b) => selected.contains(b.id)).toList()
        : all;
    final allIds = {for (final b in all) b.id};
    final chosenCount = selected.where(allIds.contains).length;
    return DeskCard(
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // 全选勾选框（OUT-072）：部分勾选时为半选；全部已选时再点清空。
              Tooltip(
                message: chosenCount == all.length && all.isNotEmpty
                    ? '全不选'
                    : '全选',
                child: Checkbox(
                  key: const ValueKey('conversion-select-all'),
                  tristate: true,
                  value: chosenCount == 0
                      ? false
                      : chosenCount == all.length
                      ? true
                      : null,
                  visualDensity: VisualDensity.compact,
                  onChanged: busy || all.isEmpty
                      ? null
                      : (_) => editForm(
                          () => chosenCount == all.length
                              ? selected.removeAll(allIds)
                              : selected.addAll(allIds),
                        ),
                ),
              ),
              Text('本次书稿', style: ui(14, w: 650, c: d.ink)),
              const DeskHelp('转换使用各书已保存的草稿：最终章节、文本清理、书籍信息和排版都以草稿为准，原稿不变。'),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '已选 $chosenCount / 共 ${all.length}',
                  key: const ValueKey('conversion-selected-count'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(12, c: d.ink3),
                ),
              ),
              const Spacer(),
              FilterChip(
                key: const ValueKey('conversion-only-selected'),
                label: const Text('只看已选'),
                selected: onlySelected,
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() => onlySelected = v),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('conversion-add-books'),
                tooltip: '添加书稿',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.add_rounded, color: d.ink2),
                onPressed: busy ? null : addBooks,
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: listHeight,
            child: books.isEmpty
                ? Center(
                    child: Text(
                      onlySelected ? '还没有勾选书稿' : '书库还没有书稿',
                      style: ui(12.5, c: d.ink3),
                    ),
                  )
                : DeskScrollArea(
                    builder: (controller) => DragSelectRegion(
                      key: const ValueKey('conversion-drag-select'),
                      scroll: controller,
                      itemExtent: 44,
                      ids: [for (final b in books) b.id],
                      isChecked: selected.contains,
                      checkColumnWidth: 44,
                      apply: busy
                          ? (_, _) {}
                          : (check, uncheck) => editForm(() {
                              selected
                                ..addAll(check)
                                ..removeAll(uncheck);
                            }),
                      onSelectAll: busy
                          ? null
                          : () => editForm(() => selected.addAll(allIds)),
                      onClear: busy
                          ? null
                          : () => editForm(() => selected.removeAll(allIds)),
                      child: ListView.builder(
                        controller: controller,
                        itemExtent: 44,
                        itemCount: books.length,
                        itemBuilder: (_, index) {
                          final book = books[index];
                          final on = selected.contains(book.id);
                          void toggle(bool value) => editForm(() {
                            if (value) {
                              selected.add(book.id);
                            } else {
                              selected.remove(book.id);
                            }
                          });
                          return InkWell(
                            onTap: busy ? null : () => toggle(!on),
                            child: Row(
                              children: [
                                Checkbox(
                                  value: on,
                                  visualDensity: VisualDensity.compact,
                                  onChanged: busy
                                      ? null
                                      : (value) => toggle(value == true),
                                ),
                                const SizedBox(width: 4),
                                LibraryCover(book, width: 24),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    book.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ui(13, c: d.ink),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 卷章数与书库同一统计（原来写识别出的标题数）。
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 120,
                                  ),
                                  child: BookStructureCounts(
                                    library: widget.library,
                                    book: book,
                                    compact: true,
                                    style: ui(11.5, c: d.ink3),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                SizedBox(
                                  width: 32,
                                  child: isEpubBook(book)
                                      ? epubModeButton(book, busy)
                                      : null,
                                ),
                                const SizedBox(width: 4),
                                SizedBox(
                                  width: 108,
                                  child: Tooltip(
                                    message: bookStatusTip(book),
                                    child: statusText(book),
                                  ),
                                ),
                                const SizedBox(width: 4),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// EPUB 的两条转换路径（V27，OUT-079）：只有图标，悬停说明，点击切换。
  Widget epubModeButton(BookSummary book, bool busy) {
    final d = context.desk;
    final original =
        widget.draft.epubOriginal[book.id] ??
        epubOriginalDefault(widget.library);
    return IconButton(
      key: ValueKey('conversion-epub-mode-${book.id}'),
      tooltip: original
          ? 'EPUB：保持原格式\n用原 EPUB 的排版，只转换图片、写入书目；点击改为使用软件排版'
          : 'EPUB：使用软件排版\n按本软件的章节、清理与排版重新生成；点击改为保持原格式',
      isSelected: original,
      visualDensity: VisualDensity.compact,
      iconSize: 17,
      icon: Icon(
        original ? Icons.menu_book_outlined : Icons.text_fields_rounded,
        color: original ? d.ink : d.ink3,
      ),
      onPressed: busy
          ? null
          : () =>
                editForm(() => widget.draft.epubOriginal[book.id] = !original),
    );
  }

  Widget formatsCard(bool busy) {
    final d = context.desk;
    const formats = {
      'EPUB': '通用阅读器 / Send to Kindle',
      'AZW3': 'Kindle USB · 更完整的样式',
      'MOBI': '旧 Kindle USB · 兼容输出',
      'KFX': 'Kindle USB · 封面保持比例',
    };
    return DeskCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeskSectionTitle(
            '格式与选项',
            trailing: Tooltip(
              message: '转换高级设置',
              child: DeskButton(
                '转换器',
                icon: Icons.build_outlined,
                quiet: true,
                onPressed: busy ? null : advancedOptions,
              ),
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, bounds) {
              final columns = bounds.maxWidth >= 820 ? 4 : 2;
              final width = (bounds.maxWidth - (columns - 1) * 8) / columns;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in formats.entries)
                    SizedBox(
                      width: width,
                      child: formatCard(entry.key, entry.value, busy),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('书籍语言', style: ui(12.5, c: d.ink2)),
              const SizedBox(width: 10),
              SizedBox(
                width: 200,
                child: DeskChoice<String>(
                  key: ValueKey(language),
                  initialValue: language,
                  style: ui(13, c: d.ink),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('沿用各书设置')),
                    DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
                    DropdownMenuItem(value: 'zh-TW', child: Text('繁體中文')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(value: 'ja', child: Text('日本語')),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => editForm(() => language = value ?? ''),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'MOBI 不用于 Send to Kindle。兼容输出会限制部分样式，检查结果将列出需要调整的项目。可先转换，之后再处理检查中的建议。',
            style: ui(11.5, c: d.ink3, h: 1.5),
          ),
        ],
      ),
    );
  }

  Widget outputCard(bool busy) {
    final d = context.desk;
    return DeskCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DeskSectionTitle('输出位置'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: destination,
                  onChanged: (_) => editForm(() {}, field: 'output_directory'),
                  style: ui(13, c: d.ink),
                  enabled: !busy,
                  decoration: const InputDecoration(hintText: '输出文件夹'),
                ),
              ),
              const SizedBox(width: 8),
              DeskButton(
                '浏览',
                icon: Icons.folder_open_outlined,
                onPressed: busy ? null : browse,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('同名文件', style: ui(12, c: d.ink3)),
              const SizedBox(width: 10),
              Expanded(
                child: Text('自动添加序号，不覆盖（全局设置）', style: ui(12.5, c: d.ink2)),
              ),
              if (session.outputs.any((o) => o.status == '已完成'))
                DeskButton(
                  '打开输出文件夹',
                  icon: Icons.folder_open_outlined,
                  quiet: true,
                  onPressed: busy || completedDirectory == null
                      ? null
                      : () => openOutput(completedDirectory!),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 书稿状态：与书库同一说法，有章节问题时加提醒圆点（OUT-071）。
  Widget statusText(BookSummary book) {
    final d = context.desk;
    final label = bookStatusLabel(book);
    return Row(
      key: ValueKey('conversion-status-${book.id}'),
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (label.attention) ...[
          Dot(d.warn, size: 6),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            label.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: ui(11.5, c: label.attention ? d.ink : d.ink3),
          ),
        ),
      ],
    );
  }

  /// 本次输出汇总（OUT-065、OUT-073）：列出将生成的文件名，全部按当前选择计算，不估算。
  Widget summaryCard(List<BookSummary> all) {
    final d = context.desk;
    final chosen = all.where((b) => selected.contains(b.id)).toList();
    final converter = switch (format) {
      'EPUB' => '程序内置生成',
      'KFX' => 'Bokai',
      _ => 'Kindling',
    };
    final enginePath = engine.text.trim();
    final engineName = enginePath.isEmpty
        ? ''
        : enginePath.split(RegExp(r'[\\/]')).last;
    final languageLabel = switch (language) {
      'zh-CN' => '简体中文',
      'zh-TW' => '繁體中文',
      'en' => 'English',
      'ja' => '日本語',
      _ => '沿用各书设置',
    };
    Widget row(String k, String v, {Key? key}) => Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(k, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: Text(
              v,
              key: key,
              style: ui(12.5, c: d.ink, h: 1.45),
            ),
          ),
        ],
      ),
    );
    final naming = session is ConversionNaming
        ? session as ConversionNaming
        : null;
    // 只列出会话按实际命名规则给出的文件名；给不出时只写数量，不猜测。
    final names = naming == null
        ? const <String>[]
        : [for (final b in chosen) naming.plannedFileName(b.id, format)];
    final issues = chosen.where((b) => chapterIssueCount(b) > 0).toList();
    const shown = 8;
    return DeskCard(
      key: const ValueKey('conversion-summary'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            chosen.isEmpty
                ? '本次输出'
                : '本次将生成 ${chosen.length} 个 .${format.toLowerCase()} 文件',
            key: const ValueKey('conversion-summary-files'),
            style: ui(13, w: 650, c: d.ink),
          ),
          if (chosen.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('勾选左侧的书稿后，这里列出将生成的文件。', style: ui(12.5, c: d.ink2)),
            )
          else ...[
            const SizedBox(height: 6),
            for (final name in names.take(shown))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(12, c: d.ink),
                ),
              ),
            if (names.length > shown)
              Text('另有 ${names.length - shown} 个文件', style: ui(12, c: d.ink3)),
            const SizedBox(height: 4),
            Text('同名文件已存在时自动加序号，不覆盖。', style: ui(11.5, c: d.ink3)),
          ],
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              issues.length == 1
                  ? '《${issues.single.title}》有 ${chapterIssueCount(issues.single)} 个章节问题，不影响转换；可以先在“检查与修复”中核对。'
                  : '${issues.length} 本书有章节问题，不影响转换；可以先在“检查与修复”中核对。',
              key: const ValueKey('conversion-summary-issues'),
              style: ui(12, c: d.ink2, h: 1.45),
            ),
          ],
          const SizedBox(height: 8),
          row(
            '转换器',
            format == 'EPUB' || engineName.isEmpty
                ? '$format · $converter'
                : '$format · $converter（$engineName）',
          ),
          row('书籍语言', languageLabel),
        ],
      ),
    );
  }

  Widget checksCard(bool busy) => DeskCard(
    padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DeskSectionTitle('转换前检查'),
        const SizedBox(height: 4),
        switchRow(
          '转换前自动检查',
          autoCheck,
          busy
              ? null
              : (value) => editForm(() {
                  autoCheck = value;
                  widget.draft.autoCheck = value;
                }, field: 'check_before_conversion'),
          note: '可选；记录检查结果，发现质量问题也继续转换。',
        ),
        switchRow(
          '缺少封面时生成',
          generateCover,
          busy
              ? null
              : (value) => editForm(
                  () => generateCover = value,
                  field: 'generate_cover',
                ),
          note: '使用当前书名与作者生成文字封面',
        ),
        switchRow(
          '完成后打开输出文件夹',
          openWhenDone,
          busy ? null : (value) => editForm(() => openWhenDone = value),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    if (loadingDefaults || !widget.draft.initialized) {
      return Center(
        child: loadingDefaults
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message, style: ui(13, c: d.ink2)),
                  const SizedBox(height: 10),
                  DeskButton(
                    '重新读取默认设置',
                    onPressed: () {
                      setState(() => loadingDefaults = true);
                      loadDefaults();
                    },
                  ),
                ],
              ),
      );
    }
    final books = widget.library.books.value;
    final busy =
        session.busy || picking || resolvingDefaults || readingSettings;
    final waitingForFile = session.outputs.any(
      (item) => item.waitingForCurrentFile,
    );
    final stopPending =
        waitingForFile ||
        session.outputs.any((item) => item.running && item.cancelRequested);
    widget.draft.actionEnabled =
        !busy &&
        selected.isNotEmpty &&
        (preview == null ||
            (preview!.previewed && session.isCurrent(preview!)));
    widget.draft.confirming = preview != null;
    widget.draft.changed();
    final preflight = preview == null
        ? null
        : PreflightPanel(
            plan: preview!,
            current: session.isCurrent(preview!),
            onBack: () {
              setState(() => preview = null);
              widget.draft.reviewing.value = false;
            },
            openRepair: (id, page) {
              widget.draft.pendingPreview = preview;
              widget.openRepair(id, page);
            },
          );
    return DeskPageFrame(
      header: DeskPageHeader(
        title: '转换',
        subtitle: preview == null
            ? null
            : '本次转换检查 · ${selected.length} 本 / $format',
        actions: [
          if (pendingDefaults != null)
            DeskButton(
              '查看默认变更',
              icon: Icons.history_rounded,
              quiet: true,
              onPressed: busy ? null : reviewDefaults,
            ),
          if (settings != null)
            Tooltip(
              message: '默认设置与继承',
              child: DeskButton(
                '默认设置',
                icon: Icons.tune_rounded,
                quiet: true,
                onPressed: busy || latestDefaults == null
                    ? null
                    : reviewDefaults,
              ),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (message.isNotEmpty || pendingDefaults != null || defaultsError)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (message.isNotEmpty) DeskInfoBar.selectable(message),
                  if (pendingDefaults != null) ...[
                    const SizedBox(height: 6),
                    DeskInfoBar(
                      defaultsChangeText(pendingDefaults!),
                      key: const ValueKey('conversion-defaults-changed'),
                      tone: Tone.warn,
                      action: Wrap(
                        spacing: 6,
                        children: [
                          DeskButton(
                            '查看并更新',
                            quiet: true,
                            onPressed: busy ? null : reviewDefaults,
                          ),
                          DeskButton(
                            '保留当前设置',
                            quiet: true,
                            onPressed: busy
                                ? null
                                : () => setState(
                                    () => keepCurrentDefaults(
                                      Map<String, Object>.from(
                                        pendingDefaults!,
                                      ),
                                      formDefaults,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (defaultsError) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: DeskButton(
                        '重新读取默认设置',
                        onPressed: busy ? null : loadDefaults,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final scale = MediaQuery.textScalerOf(context)
                    .scale(1)
                    .clamp(1.0, 2.0);
                final wide = bounds.maxWidth / scale >= 900;
                final rows = onlySelected
                    ? books.where((b) => selected.contains(b.id)).length
                    : books.length;
                final natural = (rows * 44.0).clamp(44.0, double.infinity);
                // 宽屏：列表占去格式卡片后剩余的高度（至少 4 行）；窄屏保持原高度上限。
                final listHeight = wide
                    ? natural.clamp(
                        44.0,
                        (bounds.maxHeight - 28 - 120 - 12 - 330 * scale).clamp(
                          176.0,
                          double.infinity,
                        ),
                      )
                    : natural.clamp(44.0, 232.0);
                final left = [
                  booksCard(books, busy, listHeight: listHeight),
                  const SizedBox(height: 12),
                  formatsCard(busy),
                ];
                final right = [
                  summaryCard(books),
                  const SizedBox(height: 12),
                  outputCard(busy),
                  const SizedBox(height: 12),
                  checksCard(busy),
                ];
                if (wide) {
                  return Padding(
                    padding: EdgeInsets.fromLTRB(
                      20 + ((bounds.maxWidth - 1560) / 2).clamp(0.0, 600.0),
                      14,
                      20 + ((bounds.maxWidth - 1560) / 2).clamp(0.0, 600.0),
                      14,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 5,
                          child: DeskScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: left,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 6,
                          child:
                              preflight ??
                              DeskScrollView(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: right,
                                ),
                              ),
                        ),
                      ],
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child:
                      preflight ??
                      DeskScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...left,
                            const SizedBox(height: 12),
                            ...right,
                          ],
                        ),
                      ),
                );
              },
            ),
          ),
          if (widget.showActions)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: d.line)),
              ),
              child: Row(
                children: [
                  if (session.busy)
                    DeskButton(
                      waitingForFile
                          ? '当前文件完成后停止'
                          : stopPending
                          ? '等待停止完成'
                          : '停止',
                      quiet: true,
                      onPressed: stopPending ? null : session.cancel,
                    ),
                  const Spacer(),
                  DeskButton(
                    '检查书稿',
                    quiet: true,
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => convert(),
                  ),
                  const SizedBox(width: 8),
                  DeskButton(
                    preview == null ? '开始转换' : '确认转换',
                    primary: true,
                    icon: Icons.arrow_forward_rounded,
                    onPressed: busy || selected.isEmpty
                        ? null
                        : preview == null
                        ? () => convert(
                            runChecks: autoCheck,
                            startImmediately: true,
                          )
                        : preview!.previewed && session.isCurrent(preview!)
                        ? () => commitPreview(
                            acknowledgeWarnings: preview!.needsAcknowledgement,
                          )
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
