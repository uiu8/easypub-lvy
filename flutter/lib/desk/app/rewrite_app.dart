import '../../application/workspace_leave_service.dart';
import '../../application/folder_auto_import.dart';
import '../shell/workspace_leave.dart';

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' as files;

import '../../application/conversion_defaults.dart';
import '../../application/workspace_autosave_service.dart';
import '../shell/book_picker.dart';
import '../shell/quick_layout_dialog.dart';
import '../layout/book_batch_dialog.dart';

import '../history/change_history_page.dart';
import '../metadata/book_information_page.dart';
import '../layout/layout_page.dart';
import '../layout/global_layout_presets_panel.dart';
import '../resources/resources_page.dart';
import '../../infrastructure/native_preset_picker.dart';
import '../../infrastructure/native_cover_picker.dart';
import '../metadata/cover_drop.dart' show bindSidecarCover;
import '../../infrastructure/native_conversion_desktop.dart';
import '../../application/conversion_desktop.dart';
import '../../application/conversion_service.dart';

import 'package:flutter/material.dart';

import '../errors.dart';

import '../dialogs.dart' show DeskAlert;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../conversion/conversion_page.dart';
import '../conversion/conversion_draft_persistence.dart';
import '../conversion/quick_conversion_dialog.dart';
import 'download_epub.dart';
import '../conversion/tasks_page.dart';
import '../conversion/output_history_page.dart';
import '../conversion/output_reveal.dart';
import '../conversion/output_acceptance_page.dart';

import 'package:go_router/go_router.dart';

import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../library/library_page.dart';
import '../library/source_refresh_dialog.dart';
import '../../application/source_refresh_service.dart';
import '../library/library_view_state.dart';
import '../library/book_overview_page.dart';
import '../library/project_menu.dart';
import '../folders/folders_page.dart';
import '../plugins/booksource_page.dart';
import '../plugins/plugins_page.dart';
import '../../application/plugin_host.dart';
import '../folders/metadata_mapping_page.dart';
import '../chapters/chapter_workspace.dart';
import '../chapters/chapter_view_state.dart';
import '../repair/repair_page.dart';
import '../catalog/catalog_page.dart';
import '../checks/checks_page.dart';
import '../checks/check_view_state.dart';
import '../cleanup/cleanup_page.dart';
import '../rules/rules_page.dart';
import '../../application/rule_catalog_service.dart';
import '../settings/settings_page.dart';
import '../settings/settings_index.dart';
import '../../application/chapter_service.dart' show ChapterNode;
import '../../application/settings_service.dart';
import '../../application/app_update_service.dart';
import 'update_prompt.dart';
import '../../infrastructure/native_catalog_picker.dart';
import '../shell/page_menu.dart';
import '../grain.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../shell/command_palette.dart';
import '../shell/rail.dart';
import '../shell/save_badge.dart';
import '../shell/title_bar.dart';
import '../pending/pending_changes.dart';

part 'commands.dart';
part 'routes.dart';
part 'output_tray.dart';
part 'workspace_frame.dart';

class RewriteApp extends StatefulWidget {
  const RewriteApp({
    super.key,
    required this.library,
    required this.picker,
    this.conversionDesktop,
    this.initialLocation = '/',
    this.performanceScrollController,
  });
  final String initialLocation;
  final ScrollController? performanceScrollController;
  final ConversionDesktop? conversionDesktop;
  final LibraryService library;
  final BookFilePicker picker;
  @override
  State<RewriteApp> createState() => _RewriteAppState();
}

class _RewriteAppState extends State<RewriteApp> with WidgetsBindingObserver {
  /// 跟随系统时的深浅色（V79）：系统切换时重建主题。
  bool systemDark =
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;
  @override
  void didChangePlatformBrightness() {
    final dark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    if (dark != systemDark && mounted) setState(() => systemDark = dark);
  }

  WorkspaceLifecycleService? lifecycle;
  int workspaceGeneration = 0;
  void workspaceReplaced() {
    final next = lifecycle!.workspaceGeneration.value;
    if (next == workspaceGeneration) return;
    workspaceGeneration = next;
    // Replace the whole navigator, including modal routes and book-bound forms.
    // A normal go('/') would ask the old form again after data was replaced.
    scheduleMicrotask(() {
      if (!mounted) return;
      final oldRouter = router;
      oldRouter.routerDelegate.removeListener(routeAccepted);
      final oldConversion = _conversion;
      final oldDraft = conversionDraft;
      oldDraft.removeListener(saveOutputDraft);
      setState(() {
        _conversion = null;
        conversionDraft = ConversionFormDraft();
        restoreOutputDraft();
        conversionDraft.addListener(saveOutputDraft);
        libraryView = LibraryViewState();
        checkViews.clear();
        chapterViews.clear();
        restoreWorkspaceView();
        router = createRouter(restoredRoute ?? '/');
        router.routerDelegate.addListener(routeAccepted);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldRouter.dispose();
        oldConversion?.dispose();
        oldDraft.dispose();
      });
    });
  }

  SettingsService? appearanceSettings;
  SettingsSnapshot? appearance;
  void appearanceChanged() {
    final next = appearanceSettings!.snapshot.value;
    if (next.reducedMotion == appearance?.reducedMotion &&
        next.configuration['ui_scale'] ==
            appearance?.configuration['ui_scale'] &&
        next.configuration['ui_accent'] ==
            appearance?.configuration['ui_accent'] &&
        // 主题与密度（V79）：变化时重建主题。
        next.configuration['ui_theme'] ==
            appearance?.configuration['ui_theme'] &&
        next.configuration['ui_density'] ==
            appearance?.configuration['ui_density']) {
      return;
    }
    appearance = next;
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    restoreOutputDraft();
    restoreWorkspaceView();
    conversionDraft.addListener(saveOutputDraft);
    router.routerDelegate.addListener(routeAccepted);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) routeAccepted();
    });
    final service = widget.library;
    if (service is WorkspaceLifecycleService) {
      lifecycle = service as WorkspaceLifecycleService;
      workspaceGeneration = lifecycle!.workspaceGeneration.value;
      lifecycle!.workspaceGeneration.addListener(workspaceReplaced);
    }
    final settings = widget.library;
    if (settings is SettingsService) {
      appearanceSettings = settings as SettingsService;
      appearance = appearanceSettings!.snapshot.value;
      appearanceSettings!.snapshot.addListener(appearanceChanged);
      appearanceSettings!.snapshot.addListener(outputDefaultsChanged);
      appearanceSettings!.load();
    }
    if (widget.library case final AppUpdateLibrary u
        when appearanceSettings != null) {
      final settings = appearanceSettings!;
      updates = AppUpdateController(
        service: u.appUpdates,
        readConfig: () => settings.snapshot.value.configuration,
        saveConfig: settings.savePatch,
        blockedByTasks: () => u.updateBlockedByTasks,
      );
      unawaited(updates!.start());
    }
    // 文件夹自动入库（V26，FOLD-080）：窗口回到前台时同步一次。
    if (widget.library case final FolderAutoImportService auto) {
      autoImportResume = AppLifecycleListener(
        onResume: () => unawaited(auto.syncAutoImport()),
      );
    }
  }

  AppLifecycleListener? autoImportResume;

  /// 自动更新（V68）：整个程序一个；顶栏提示与设置页共用。
  AppUpdateController? updates;

  final quickActivity = ValueNotifier<bool>(false);
  String? restoredRoute;
  Map<String, dynamic> issueViewJson(IssueViewState value) => {
    'category': value.category,
    'severity': value.severity,
    'issueId': value.issueId,
    'effective': value.effective,
    'offset': value.offset,
    'anchor': value.anchor,
  };
  void restoreIssueView(IssueViewState target, Map value) {
    target
      ..category = value['category'] as String?
      ..severity = value['severity'] as String?
      ..issueId = value['issueId'] as String?
      ..effective = value['effective'] != false
      ..offset = value['offset'] as int? ?? 0
      ..anchor = value['anchor'] as int? ?? 0;
  }

  void restoreWorkspaceView() {
    final library = widget.library;
    if (library is! WorkspaceAutosaveService) return;
    final raw = (library as WorkspaceAutosaveService).readDraft('workspace/UI');
    if (raw == null) {
      restoredRoute = null;
      return;
    }
    final ids = library.books.value.map((b) => b.id).toSet();
    final path = raw['route'] as String?;
    if (path != null) {
      final uri = Uri.tryParse(path);
      if (uri != null &&
          uri.path.startsWith('/') &&
          (uri.pathSegments.firstOrNull != 'books' ||
              (uri.pathSegments.length > 1 &&
                  ids.contains(uri.pathSegments[1])))) {
        restoredRoute = path;
      }
    }
    for (final entry in (raw['chapters'] as Map? ?? {}).entries) {
      if (!ids.contains(entry.key) || entry.value is! Map) continue;
      final data = entry.value as Map, view = ChapterViewState();
      view
        ..nodeId = data['nodeId'] as String?
        ..offset = data['offset'] as int? ?? 0
        ..bodyOffset = data['bodyOffset'] as int? ?? 0
        ..tab = data['tab'] as int? ?? 0;
      view.tree
        ..query = data['query'] as String? ?? ''
        ..scrollOffset = (data['scrollOffset'] as num?)?.toDouble() ?? 0
        ..loadedNodes = data['loadedNodes'] as int? ?? 0;
      view.tree.collapsed.addAll(
        (data['collapsed'] as List? ?? []).cast<String>(),
      );
      if (data['issues'] case final Map issues) {
        restoreIssueView(view.issues, issues);
      }
      chapterViews[entry.key as String] = view;
    }
    for (final entry in (raw['checks'] as Map? ?? {}).entries) {
      if (!ids.contains(entry.key) || entry.value is! Map) continue;
      final data = entry.value as Map, view = CheckViewState();
      view.domain = data['domain'] as String? ?? 'chapters';
      if (data['issues'] case final Map issues) {
        restoreIssueView(view.issues, issues);
      }
      checkViews[entry.key as String] = view;
    }
    if (raw['library'] case final Map value) {
      libraryView
        ..search = value['search'] as String? ?? ''
        ..filter = value['filter'] as String? ?? '全部书稿'
        ..format = value['format'] as String? ?? '全部格式'
        ..onlySelected = value['onlySelected'] == true
        ..compact = value['compact'] == true
        ..topBookId = value['topBookId'] as String?
        ..topIndex = value['topIndex'] as int? ?? 0
        ..fraction = (value['fraction'] as num?)?.toDouble() ?? 0;
    }
  }

  void saveWorkspaceView() {
    final library = widget.library;
    if (library is! WorkspaceAutosaveService) return;
    (library as WorkspaceAutosaveService).writeDraft('workspace/UI', {
      'route': router.routerDelegate.currentConfiguration.uri.toString(),
      'chapters': {
        for (final e in chapterViews.entries)
          e.key: {
            'nodeId': e.value.nodeId,
            'offset': e.value.offset,
            'bodyOffset': e.value.bodyOffset,
            'tab': e.value.tab,
            'query': e.value.tree.query,
            'collapsed': e.value.tree.collapsed.toList(),
            'scrollOffset': e.value.tree.scrollOffset,
            'loadedNodes': e.value.tree.loadedNodes,
            'issues': issueViewJson(e.value.issues),
          },
      },
      'checks': {
        for (final e in checkViews.entries)
          e.key: {
            'domain': e.value.domain,
            'issues': issueViewJson(e.value.issues),
          },
      },
      'library': {
        'search': libraryView.search,
        'filter': libraryView.filter,
        'format': libraryView.format,
        'onlySelected': libraryView.onlySelected,
        'compact': libraryView.compact,
        'topBookId': libraryView.topBookId,
        'topIndex': libraryView.topIndex,
        'fraction': libraryView.fraction,
      },
    });
  }

  void routeAccepted() {
    rememberPage(router.routerDelegate.currentConfiguration.uri);
    final segments =
        router.routerDelegate.currentConfiguration.uri.pathSegments;
    if (segments.length > 1 &&
        segments.first == 'books' &&
        widget.library.selection.value.current != segments[1]) {
      widget.library.selectBook(segments[1]);
    }
    saveWorkspaceView();
  }

  void restoreOutputDraft() {
    ConversionDraftPersistence.restore(widget.library, conversionDraft);
  }

  void saveOutputDraft() {
    ConversionDraftPersistence.save(widget.library, conversionDraft);
  }

  bool convertChecked = false;

  /// 书库页：有勾选时右下角默认转换已勾选的书；可在范围菜单改回“当前书”（LIB-094）。
  bool libraryConvertChecked = true;
  bool preparingOutput = false;
  String outputMessage = '';
  final presetLabels = <String, ({String label, String version})>{};
  int outputDefaultsRevision = 0;
  Future<void> outputDefaultsChanged() async {
    final settings = appearanceSettings;
    final draft = conversionDraft;
    if (settings == null ||
        !settings.snapshot.value.loaded ||
        settings.snapshot.value.busy ||
        !draft.initialized ||
        draft.changeFormat != null ||
        _conversion?.busy == true) {
      return;
    }
    final ticket = ++outputDefaultsRevision;
    try {
      final values = await resolveConversionDefaults(
        readConversionDefaults(settings.snapshot.value.configuration),
        conversionDesktop,
        format: draft.manualDefaults.contains('output_format')
            ? draft.format
            : null,
      );
      if (!mounted ||
          ticket != outputDefaultsRevision ||
          !identical(draft, conversionDraft) ||
          draft.changeFormat != null) {
        return;
      }
      if (mapEquals(draft.defaultValues, values)) return;
      if (!draft.manualDefaults.contains('output_format')) {
        draft.format = values['output_format'] as String;
      }
      if (!draft.manualDefaults.contains('output_directory')) {
        draft.directory = values['output_directory'] as String;
      }
      if (!draft.manualDefaults.contains('kindle_converter')) {
        draft.engine = values['kindle_converter'] as String;
      }
      if (!draft.manualDefaults.contains('generate_cover')) {
        draft.generateCover = values['generate_cover'] as bool;
      }
      if (!draft.manualDefaults.contains('check_before_conversion')) {
        draft.autoCheck = values['check_before_conversion'] as bool;
      }
      draft.defaultValues = Map.unmodifiable(values);
      draft.pendingPreview = null;
      draft.changed();
    } catch (e) {
      outputMessage = deskErrorText(e, '默认输出设置读取失败。');
    }
  }

  Future<void> ensureOutputDraft() async {
    final draft = conversionDraft;
    if (draft.initialized) return;
    final service = widget.library;
    Map<String, dynamic> config = {};
    if (service is SettingsService) {
      final settings = service as SettingsService;
      if (!await settings.load()) throw const FormatException('无法读取输出设置，请重试。');
      config = settings.snapshot.value.configuration;
    }
    final values = await resolveConversionDefaults(
      readConversionDefaults(config),
      conversionDesktop,
    );
    if (!mounted || !identical(draft, conversionDraft) || draft.initialized) {
      return;
    }
    draft
      ..initialized = true
      ..directory = values['output_directory'] as String
      ..format = values['output_format'] as String
      ..engine = values['kindle_converter'] as String
      ..generateCover = values['generate_cover'] as bool
      ..autoCheck = values['check_before_conversion'] as bool
      ..defaultValues = Map.unmodifiable(values);
    draft.changed();
  }

  Future<void> updateOutputFormat(String format) async {
    if (conversion.busy || preparingOutput) return;
    if (conversionDraft.changeFormat case final change?) {
      await change(format);
      return;
    }
    preparingOutput = true;
    conversionDraft.changed();
    try {
      await ensureOutputDraft();
      final config = widget.library is SettingsService
          ? (widget.library as SettingsService).snapshot.value.configuration
          : <String, dynamic>{};
      final values = await resolveConversionDefaults(
        readConversionDefaults(config),
        conversionDesktop,
        format: format,
      );
      conversionDraft
        ..format = format
        ..engine = values['kindle_converter'] as String
        ..pendingPreview = null;
      conversionDraft.manualDefaults.add('output_format');
      conversionDraft.manualDefaults.remove('kindle_converter');
      conversionDraft.reviewing.value = false;
      outputMessage = '';
    } catch (e) {
      outputMessage = deskErrorText(
        e,
        '没能读取转换默认设置，输出格式仍是原来的。可以再点一次，或到“转换”页的默认设置里查看。',
      );
    } finally {
      preparingOutput = false;
      conversionDraft.changed();
    }
  }

  Future<void> chooseOutputDirectory() async {
    if (conversion.busy || preparingOutput) return;
    final path = await widget.picker.chooseFolder();
    if (!mounted || path == null) return;
    try {
      await ensureOutputDraft();
      if (!mounted) return;
      if (conversionDraft.changeDirectory case final change?) {
        change(path);
      } else {
        conversionDraft
          ..directory = path
          ..pendingPreview = null;
        conversionDraft.manualDefaults.add('output_directory');
        conversionDraft.reviewing.value = false;
      }
      outputMessage = '';
    } catch (e) {
      outputMessage = deskErrorText(
        e,
        '没能改用这个输出位置，仍按原来的位置输出。可以再选一次，或到“转换”页的输出位置里设置。',
      );
    }
    conversionDraft.changed();
  }

  Future<void> openOutputDirectory() async {
    try {
      await conversionDesktop.openDirectory(conversionDraft.directory);
      outputMessage = '';
    } catch (e) {
      outputMessage = deskErrorText(e, '无法打开输出文件夹。');
    }
    conversionDraft.changed();
  }

  Future<void> chooseBook(BuildContext context) async {
    final id = await chooseWorkspaceBook(context, widget.library);
    if (!mounted || id == null || !context.mounted) return;
    final uri = GoRouterState.of(context).uri;
    final page = uri.pathSegments.firstOrNull == 'tools'
        ? uri.pathSegments.last
        : uri.pathSegments.firstOrNull == 'books'
        ? uri.pathSegments.last
        : 'overview';
    await workspaceDraftGuard.run(() async {
      if (!mounted) return false;
      router.go(bookPageLocation(id, page, origin: uri));
      return true;
    });
  }

  Future<void> chooseLayout(BuildContext context, {Set<String>? books}) async {
    final current = widget.library.selection.value.current;
    final targets = books ?? {?current};
    final source = targets.contains(current) ? current : targets.firstOrNull;
    final book = widget.library.books.value
        .where((b) => b.id == source)
        .firstOrNull;
    if (book == null) {
      await chooseBook(context);
      return;
    }
    await workspaceDraftGuard.run(() async {
      if (!mounted || !context.mounted) return false;
      if (targets.length > 1) {
        await showDialog<bool>(
          context: context,
          builder: (_) => BookBatchDialog(
            library: widget.library,
            bookId: book.id,
            initialTargets: targets,
          ),
        );
        conversionDraft.pendingPreview = null;
        conversionDraft.changed();
        return true;
      }
      final result = await showDialog<String>(
        context: context,
        builder: (_) => QuickLayoutDialog(library: widget.library, book: book),
      );
      if (!mounted || result == null) return false;
      final version =
          widget.library.books.value
              .where((b) => b.id == book.id)
              .firstOrNull
              ?.contentVersion ??
          '';
      presetLabels[book.id] = (label: result, version: version);
      conversionDraft.pendingPreview = null;
      conversionDraft.changed();
      if (context.mounted &&
          GoRouterState.of(context).uri.path.endsWith('/layout')) {
        router.go(
          bookPageLocation(
            book.id,
            'layout',
            query: {'refresh': '${DateTime.now().microsecondsSinceEpoch}'},
          ),
        );
      }
      return true;
    });
  }

  /// 书源下载为 EPUB（LIB-215），见 download_epub.dart。
  Future<DownloadEpubResult> exportDownloadedEpub(String path) =>
      exportDownloadAsEpub(
        library: widget.library,
        session: conversion,
        path: path,
        conversionBusy: quickActivity.value,
        onImported: (out) => noteDownloadImport(path, out),
      );

  /// 书源下载加入书库后，书库里已有这本书、下载内容却变了（追更、重新整理）的路径（V111）：
  /// 草稿保留没动，下载队列据此提示“书库里是旧版本”并给出“刷新来源”。
  final outdatedDownloads = <String>{};
  String _downloadKey(String path) => path.replaceAll('/', r'\').toLowerCase();

  void noteDownloadImport(String path, List<ImportOutcome> out) {
    if (out.any((o) => o.sourceChanged)) {
      outdatedDownloads.add(_downloadKey(path));
    } else if (out.any((o) => o.succeeded)) {
      outdatedDownloads.remove(_downloadKey(path));
    }
  }

  /// 对下载的这本书打开“刷新来源”对比确认窗口；关闭后重新核对，返回书库里是否已是新版本。
  Future<bool> refreshDownloadInLibrary(String path) async {
    final key = _downloadKey(path);
    final book = widget.library.books.value
        .where((b) => _downloadKey(b.path) == key)
        .firstOrNull;
    final context = router.routerDelegate.navigatorKey.currentContext;
    if (book == null ||
        widget.library is! SourceRefreshService ||
        context == null) {
      return !outdatedDownloads.contains(key);
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SourceRefreshDialog(
        service: widget.library as SourceRefreshService,
        bookId: book.id,
      ),
    );
    noteDownloadImport(path, await widget.library.importFiles([path]));
    return !outdatedDownloads.contains(key);
  }

  Future<void> quickConvert(BuildContext context, {String? bookId}) async {
    if (quickActivity.value || conversion.busy) return;
    final ids = List<String>.unmodifiable(
      bookId == null ? widget.library.selection.value.selected : [bookId],
    );
    if (ids.isEmpty) return;
    quickActivity.value = true;
    final epoch = workspaceGeneration;
    final session = conversion;
    try {
      if (!await workspaceDraftGuard.run(() async => true)) return;
      await ensureOutputDraft();
      if (!mounted || !context.mounted) return;
      final choice = await showDialog<QuickConversionChoice>(
        context: context,
        barrierDismissible: false,
        builder: (_) => QuickConversionDialog(
          library: widget.library,
          desktop: conversionDesktop,
          session: session,
          books: ids,
          outputRequest: conversionDraft.requestFor(
            ids,
            keepOriginalEpub: keepOriginalEpubFor(
              conversionDraft,
              widget.library,
              ids,
            ),
          ),
        ),
      );
      if (!mounted || epoch != workspaceGeneration || choice == null) return;
      if (choice.request != null) {
        conversionDraft.adoptRequest(
          choice.request!,
          choice.plan,
          preserveDefaults: true,
        );
      }
      if (choice.action == 'start') {
        if (choice.plan == null || !session.isCurrent(choice.plan!)) {
          throw const FormatException('书稿或计划已变化，请重新检查。');
        }
        conversionDraft.pendingPreview = null;
        conversionDraft.reviewing.value = false;
        final submitted = session.commit(
          choice.plan!,
          acknowledgeWarnings: choice.plan!.needsAcknowledgement,
        );
        router.go('/tasks');
        await submitted;
        if (mounted &&
            epoch == workspaceGeneration &&
            conversionDraft.openWhenDone &&
            session.outputs.any((output) => output.complete)) {
          await openOutputDirectory();
        }
      } else if (choice.action == 'repair') {
        openConversionRepair(choice.bookId!, choice.page);
      } else {
        router.go(
          choice.request != null
              ? '/conversion'
              : Uri(
                  path: '/conversion',
                  queryParameters: {'books': ids},
                ).toString(),
        );
      }
    } catch (e) {
      if (mounted && epoch == workspaceGeneration) {
        final currentContext =
            router.routerDelegate.navigatorKey.currentContext;
        if (currentContext != null && currentContext.mounted) {
          showDialog<void>(
            context: currentContext,
            builder: (c) => DeskAlert(
              title: const Text('转换未完成'),
              content: Text(deskErrorText(e, '请到任务或转换设置查看具体结果。')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        }
      }
    } finally {
      if (mounted) quickActivity.value = false;
    }
  }

  void openConversionRepair(String bookId, String? action) {
    final page = switch (action) {
      'metadata' || 'cover-select' || 'cover-generate' => 'information',
      'chapters' => 'chapters',
      'cleanup' => 'cleanup',
      'resources' => 'resources',
      _ => 'checks',
    };
    router.go(
      Uri(
        path: '/books/${Uri.encodeComponent(bookId)}/$page',
        queryParameters: {
          'from': 'conversion',
          if (action == 'cover-select') 'cover': 'select',
          if (action == 'cover-generate') 'cover': 'generate',
        },
      ).toString(),
    );
  }

  String bookDestination(
    GoRouterState state,
    String page, {
    Map<String, String> query = const {},
  }) => bookPageLocation(
    state.pathParameters['bookId']!,
    page,
    origin: state.uri,
    query: query,
  );

  var libraryView = LibraryViewState();

  /// 左侧导航栏是否展开（G-084）：默认窄栏，本次运行内记住。
  final navExpanded = ValueNotifier<bool>(false);
  final checkViews = <String, CheckViewState>{};
  final chapterViews = <String, ChapterViewState>{};
  ChapterViewState chaptersView(String bookId) {
    final ids = widget.library.books.value.map((book) => book.id).toSet();
    chapterViews.removeWhere((id, _) => !ids.contains(id));
    return chapterViews.putIfAbsent(bookId, ChapterViewState.new);
  }

  CheckViewState checksView(String bookId) {
    final ids = widget.library.books.value.map((book) => book.id).toSet();
    checkViews.removeWhere((id, _) => !ids.contains(id));
    return checkViews.putIfAbsent(bookId, CheckViewState.new);
  }

  var conversionDraft = ConversionFormDraft();
  ConversionSession? _conversion;
  ConversionSession get conversion =>
      _conversion ??= widget.library.openConversion();
  late final conversionDesktop =
      widget.conversionDesktop ?? NativeConversionDesktop();
  final informationNavigation = InformationNavigationGuard();
  final layoutNavigation = LayoutNavigationGuard();
  final mappingNavigation = MappingNavigationGuard();
  final cleanupNavigation = CleanupNavigationGuard();
  late final workspaceDraftGuard = WorkspaceDraftGuard(() async {
    for (final check in [
      informationNavigation.canLeave,
      layoutNavigation.canLeave,
      cleanupNavigation.canLeaveWorkspace,
      mappingNavigation.canLeave,
    ]) {
      if (!mounted || !await check()) return false;
    }
    if (mounted) {
      saveWorkspaceView();
      saveOutputDraft();
    }
    return mounted;
  });
  final settingsPageTitle = ValueNotifier<String>('外观与交互');

  /// 待应用登记（G-061）：页面报告未确认的预览，托盘只读展示。
  late final pendingChanges = PendingChangeRegistry(
    version: (id) => widget.library.books.value
        .where((b) => b.id == id)
        .firstOrNull
        ?.contentVersion,
    bookTitle: (id) =>
        widget.library.books.value.where((b) => b.id == id).firstOrNull?.title,
    versions: widget.library.books,
  );
  late GoRouter router = createRouter(
    widget.initialLocation == '/'
        ? restoredRoute ?? '/'
        : widget.initialLocation,
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    autoImportResume?.dispose();
    navExpanded.dispose();
    updates?.dispose();
    lifecycle?.workspaceGeneration.removeListener(workspaceReplaced);
    appearanceSettings?.snapshot.removeListener(appearanceChanged);
    appearanceSettings?.snapshot.removeListener(outputDefaultsChanged);
    router.routerDelegate.removeListener(routeAccepted);
    router.dispose();
    _conversion?.dispose();
    settingsPageTitle.dispose();
    pendingChanges.dispose();
    quickActivity.dispose();
    conversionDraft.removeListener(saveOutputDraft);
    conversionDraft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => application(appearance);

  Widget application(SettingsSnapshot? prefs) => MaterialApp.router(
    key: ValueKey(workspaceGeneration),
    title: 'EasyPub++',
    theme: deskTheme(
      compact: prefs?.configuration['ui_density'] == 'compact',
      accent: prefs?.configuration['ui_accent'] as String?,
      mode: deskThemeMode(
        prefs?.configuration['ui_theme'],
        systemDark: systemDark,
      ),
    ),
    scrollBehavior: const DeskScrollBehavior(),
    debugShowCheckedModeBanner: false,
    routerConfig: router,
    themeAnimationDuration:
        prefs?.reducedMotion == true ||
            WidgetsBinding
                .instance
                .platformDispatcher
                .accessibilityFeatures
                .disableAnimations
        ? Duration.zero
        : DeskMotion.slow,
    themeAnimationCurve: DeskMotion.easeOut,
    builder: (context, child) => _withUpdates(
      PendingScope(
        registry: pendingChanges,
        child: WorkspaceDraftScope(
          guard: workspaceDraftGuard,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations:
                  MediaQuery.of(context).disableAnimations ||
                  prefs?.reducedMotion == true,
              textScaler: TextScaler.linear(
                ((prefs?.configuration['ui_scale'] as num?)?.toDouble() ?? 1) *
                    (prefs?.configuration['ui_follow_system_scale'] != false
                        ? MediaQuery.textScalerOf(context).scale(1)
                        : 1),
              ),
            ),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.digit1,
                  alt: true,
                ): () =>
                    router.go('/'),
                const SingleActivator(
                  LogicalKeyboardKey.digit2,
                  alt: true,
                ): () =>
                    router.go('/folders'),
                const SingleActivator(
                  LogicalKeyboardKey.digit3,
                  alt: true,
                ): () => router.go(
                  bookPageLocation(
                    widget.library.selection.value.current,
                    'checks',
                  ),
                ),
                const SingleActivator(
                  LogicalKeyboardKey.digit4,
                  alt: true,
                ): () => router.go(
                  bookPageLocation(
                    widget.library.selection.value.current,
                    'chapters',
                  ),
                ),
                const SingleActivator(
                  LogicalKeyboardKey.digit5,
                  alt: true,
                ): () =>
                    router.go('/conversion'),
                const SingleActivator(
                  LogicalKeyboardKey.digit6,
                  alt: true,
                ): () =>
                    router.go('/tasks'),
                const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                    openCommandPalette,
              },
              child: DeskSearchHost(
                child: _WorkspaceControls(owner: this, child: child!),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _withUpdates(Widget child) => switch (updates) {
    final c? => AppUpdateScope(controller: c, child: child),
    null => child,
  };
}
