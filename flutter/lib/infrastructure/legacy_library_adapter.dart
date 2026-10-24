import '../application/storage_locations.dart';
import '../application/storage_settings_service.dart';
import '../application/plugin_host.dart';
import '../infrastructure/import_profile.dart';
import '../application/library_check_batch.dart';
import '../application/parallel_books.dart';
import '../application/workspace_leave_service.dart';
import '../application/workspace_autosave_service.dart';
import '../application/check_cache_service.dart';
import '../application/crash_log_service.dart';
import '../application/folder_auto_import.dart';
import '../application/book_collection_service.dart';
import 'legacy_collections.dart';
import 'crash_log.dart';
import 'check_report_cache.dart';
import '../application/source_refresh_service.dart';

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import '../src/rust/api.dart' as api;

import 'package:path/path.dart' as paths;

import '../application/folder_count_service.dart';
import '../application/settings_service.dart';
import 'local_workspace_autosave.dart';
import 'native_folder_count.dart';
import '../application/change_history_service.dart';
import 'legacy_change_history_service.dart';
import '../application/book_information_service.dart';
import 'legacy_book_information_session.dart';
import '../application/layout_service.dart';
import '../application/block_annotation_service.dart';
import 'legacy_block_annotation_session.dart';
import '../application/manual_note_service.dart';
import 'legacy_manual_note_session.dart';
import '../application/app_update_service.dart';
import '../application/rule_catalog_service.dart';
import 'legacy_app_update_service.dart';
import 'legacy_rule_catalog_service.dart';
import '../application/supplemental_page_service.dart';
import 'legacy_supplemental_page_session.dart';
import 'legacy_layout_session.dart';
import '../application/layout_batch_service.dart';
import 'legacy_layout_batch_session.dart';
import '../application/book_batch_service.dart';
import 'legacy_book_batch_session.dart';
import '../application/conversion_service.dart';
import '../application/output_history_service.dart';
import 'legacy_output_history_service.dart';
import 'legacy_conversion_session.dart';
import '../application/resource_service.dart';
import 'legacy_resource_session.dart';

import 'package:flutter/foundation.dart';

import '../application/library_service.dart';
import '../application/metadata_mapping_service.dart';
import 'legacy_mapping_session.dart';
import '../application/chapter_service.dart';
import '../application/chapter_rules_service.dart';
import 'legacy_chapter_rules_session.dart';
import 'legacy_chapter_session.dart';
import '../application/catalog_service.dart';
import 'legacy_catalog_session.dart';
import '../application/book_check_service.dart';
import '../application/cleanup_service.dart';
import 'legacy_cleanup_session.dart';
import '../application/cleanup_batch_service.dart';
import 'legacy_cleanup_batch_session.dart';
import 'legacy_book_check_session.dart';
import '../prototype/prototype_state.dart';
import '../prototype/folder_scan.dart';

/// Temporary non-visual boundary around the existing tested import use case.
/// No legacy navigation or sample books are exposed to the new UI.
class LegacyLibraryAdapter
    implements
        LibraryService,
        BlockAnnotationLibrary,
        ManualNoteLibrary,
        RuleCatalogLibrary,
        AppUpdateLibrary,
        SupplementalPageLibrary,
        ChapterRulesService,
        LibraryBulkSelection,
        LibraryBatchChecks,
        LibraryRemovalService,
        WorkspaceLeaveService,
        WorkspaceLifecycleService,
        WorkspaceAutosaveService,
        WorkspaceResetService,
        SourceRefreshService,
        BookOverviewService,
        BookStatisticsService,
        CleanupPresetCatalog,
        FolderCountService,
        SettingsService,
        SettingsBackupService,
        CheckCacheService,
        CrashLogService,
        BookCollectionService,
        FolderAutoImportService,
        StorageSettingsService {
  // ---------------------------------------------------------------- 书库收藏夹（V84，LIB-118–126）
  // 第一次用到时才建（订阅后端通知）；dispose 只释放已建的，不在释放时新建。
  LegacyCollections? _collections;
  LegacyCollections get _collectionStore =>
      _collections ??= LegacyCollections(_backend);
  @override
  ValueListenable<List<BookCollection>> get collections =>
      _collectionStore.collections;
  @override
  BookCollection createCollection(
    String name, {
    Map<String, Map<String, String>> template = const {},
    bool autoApply = false,
  }) => _collectionStore.createCollection(
    name,
    template: template,
    autoApply: autoApply,
  );
  @override
  void updateCollection(BookCollection collection) =>
      _collectionStore.updateCollection(collection);
  @override
  void deleteCollection(String id) => _collectionStore.deleteCollection(id);
  @override
  List<String> addToCollection(String id, Iterable<String> bookIds) =>
      _collectionStore.addToCollection(id, bookIds);
  @override
  void removeFromCollection(String id, Iterable<String> bookIds) =>
      _collectionStore.removeFromCollection(id, bookIds);
  @override
  String? bookIdForPath(String path) => _collectionStore.bookIdForPath(path);
  @override
  List<String> knownCategories() => _collectionStore.knownCategories();
  @override
  Future<BookFieldPreview> previewFields(
    Map<String, Map<String, String>> fields,
    List<String> bookIds, {
    String label = '',
  }) => _collectionStore.previewFields(fields, bookIds, label: label);
  @override
  Future<BookFieldApplied> applyFields(BookFieldPreview preview) =>
      _collectionStore.applyFields(preview);
  @override
  Future<String> undoFields(BookFieldApplied applied) =>
      _collectionStore.undoFields(applied);

  // ---------------------------------------------------------------- 文件夹自动入库（V26，FOLD-080–082）
  List<String> _configList(String key) => [
    for (final v in (_backend.globalConfiguration[key] as List? ?? const []))
      if (v is String) v,
  ];
  late final _autoFolders = ValueNotifier<List<String>>(
    _configList('auto_import_folders'),
  );
  late final FolderAutoImporter _autoImport = FolderAutoImporter(
    library: this,
    folders: () => _configList('auto_import_folders'),
    ignored: () => _configList('auto_import_ignored').toSet(),
    recursive: () => _backend.globalConfiguration['import_recursive'] == true,
    busy: () => hasPendingWork || _projectBusy.value,
  );
  @override
  ValueListenable<List<String>> get autoImportFolders => _autoFolders;
  @override
  ValueListenable<AutoImportState> get autoImportState => _autoImport.state;
  @override
  Future<bool> setAutoImport(String folder, bool enabled) async {
    final current = _configList('auto_import_folders');
    final next = [
      for (final f in current)
        if (!paths.equals(f, folder)) f,
      if (enabled) folder,
    ];
    final saved = await savePatch({'auto_import_folders': next});
    _autoFolders.value = _configList('auto_import_folders');
    if (saved) unawaited(_autoImport.foldersChanged());
    return saved;
  }

  @override
  Future<void> syncAutoImport() => _autoImport.sync();
  @override
  void acknowledgeAutoImport() => _autoImport.acknowledge();

  /// 从书库移除自动入库文件夹里的书时记入忽略列表，避免下次同步又导入；撤销移除时去掉。
  void _rememberRemoved(Iterable<String> sourcePaths, {required bool removed}) {
    final folders = _configList('auto_import_folders');
    final inside = [
      for (final path in sourcePaths)
        if (folders.any((f) => pathInside(path, f))) path,
    ];
    if (inside.isEmpty) return;
    final ignored = _configList('auto_import_ignored');
    final next = removed
        ? {...ignored, ...inside}.toList()
        : [
            for (final p in ignored)
              if (!inside.any((q) => paths.equals(p, q))) p,
          ];
    unawaited(
      savePatch({'auto_import_ignored': next}).catchError((_) => false),
    );
  }

  @override
  String? get crashLogDirectory => _backend.settingsDirectory == null
      ? null
      : paths.join(_backend.settingsDirectory!, 'crash-logs');

  @override
  Future<String> readCrashLog(CrashLogEntry entry) async {
    final directory = crashLogDirectory;
    if (directory == null ||
        !paths.equals(paths.dirname(entry.path), directory)) {
      throw const FormatException('只能读取崩溃日志文件夹中的日志。');
    }
    return File(entry.path).readAsString();
  }

  @override
  List<CrashLogEntry> crashLogs() {
    final directory = crashLogDirectory;
    return directory == null ? const [] : CrashLog(directory).list();
  }

  Directory? get _checkReports => _backend.settingsDirectory == null
      ? null
      : Directory(paths.join(_backend.settingsDirectory!, 'check-reports'));

  /// 书库中每本书当前稿的检查指纹（CHK-061 保留规则）。
  Map<String, String> _currentCheckGuards() => {
    for (final b in _backend.shelf.books.where((b) => !b.isDemo))
      b.id: LegacyBookCheckSession.contextFor(_backend, b.id),
  };

  @override
  Future<CheckCachePreview> previewCheckCacheCleanup() async {
    final directory = _checkReports;
    if (directory == null) {
      throw const FormatException('没有设置目录，无法统计检查缓存。');
    }
    return previewCheckReportCleanup(directory, _currentCheckGuards());
  }

  @override
  Future<CheckCacheCleanupResult> cleanCheckCache(
    CheckCachePreview preview,
  ) async {
    final directory = _checkReports;
    if (directory == null) {
      throw const FormatException('没有设置目录，无法清理检查缓存。');
    }
    return cleanCheckReports(directory, preview, _currentCheckGuards());
  }

  @override
  ChapterRulesSession openRules(String? bookId) =>
      LegacyChapterRulesSession(_backend, bookId);
  @override
  bool get hasUnsavedChanges => _autosaveStarted
      ? workspaceSave.value.phase != WorkspaceSavePhase.saved
      : (_books.value.isNotEmpty || _backend.savedProjectIdentity != null) &&
            (_backend.savedProjectIdentity == null ||
                _backend.savedProjectIdentity != _backend.projectIdentity);
  @override
  String get workspaceIdentity => _backend.projectIdentity;
  @override
  bool get hasPendingWork =>
      _batchBusy ||
      checkBatch.running ||
      _backend.importing ||
      _backend.projectBusy ||
      _backend.queueActive ||
      _backend.production.busy ||
      _backend.cleanup.historyBusy;

  @override
  Future<List<Map<String, dynamic>>> cleanupPresets() async =>
      (jsonDecode(await api.cleanupPresetsText()) as List)
          .map((v) => (v as Map).cast<String, dynamic>())
          .toList();

  @override
  Future<SourceRefreshPreview> previewSourceRefresh(String bookId) {
    if (_disposed || hasPendingWork) {
      throw const FormatException('请等待当前操作结束后刷新来源。');
    }
    return _backend.previewSourceRefresh(bookId);
  }

  @override
  String? sourceRecoveryPath(String bookId) {
    final source = _backend.shelf.books
        .where((b) => b.id == bookId)
        .firstOrNull
        ?.source;
    if (source == null ||
        paths.basename(paths.dirname(source.path)).toLowerCase() !=
            'after.easypub.json.sources') {
      return null;
    }
    return paths.join(
      paths.dirname(paths.dirname(source.path)),
      'before.easypub.json',
    );
  }

  @override
  Future<SourceRefreshResult> applySourceRefresh(
    SourceRefreshPreview preview, {
    required Set<String> fields,
    required bool replaceBody,
    bool replaceImages = false,
  }) async {
    if (_disposed || hasPendingWork) {
      throw const FormatException('请等待当前操作结束后刷新来源。');
    }
    final result = await _backend.applySourceRefresh(
      preview,
      fields: fields,
      replaceBody: replaceBody,
      replaceImages: replaceImages,
    );
    if (!_disposed &&
        result.recoveryPath != null &&
        _backend.globalConfiguration['check_after_import'] != false) {
      final id = preview.bookId;
      _checking.add(id);
      _refresh();
      final checks = openChecks(id);
      try {
        await checks.inspect();
      } catch (_) {
        /* Source refresh has committed; checking can be retried. */
      } finally {
        checks.dispose();
        _checking.remove(id);
        if (!_disposed) _refresh();
      }
    }
    return result;
  }

  final _statistics = <String, (String, Future<Map<String, dynamic>>)>{};
  @override
  Future<Map<String, dynamic>> statistics(String bookId) {
    if (_disposed) return Future.error(StateError('工作区已关闭。'));
    final guard = _backend.publicationContext(bookId);
    final previous = _statistics[bookId];
    if (previous?.$1 == guard) return previous!.$2;
    final pending = _readStatistics(bookId, guard);
    _statistics.remove(bookId);
    _statistics[bookId] = (guard, pending);
    while (_statistics.length > 128) {
      _statistics.remove(_statistics.keys.first);
    }
    return pending;
  }

  Future<Map<String, dynamic>> _readStatistics(String id, String guard) async {
    try {
      final tree = await _backend.manuscript.effectiveTree(
        id,
        0,
        statistics: true,
      );
      if (_disposed || guard != _backend.publicationContext(id)) {
        throw const FormatException('书稿已变化，请重新读取统计。');
      }
      return Map.unmodifiable(
        (tree['statistics'] as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      if (_statistics[id]?.$1 == guard) _statistics.remove(id);
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> overview(String bookId) async {
    final counts = await statistics(bookId);
    return {
      ...counts,
      'project_path': _backend.projectPath,
      'project_state': _autosaveStarted
          ? workspaceSave.value.message
          : _backend.projectPath.isEmpty
          ? '尚未保存项目'
          : _backend.savedProjectIdentity == _backend.projectIdentity
          ? '更改已保存'
          : '有未保存更改',
      'cleanup': _backend.cleanup.drafts.containsKey(bookId)
          ? '已采用清理方案'
          : '尚未采用清理方案',
      'layout':
          '字号 ${_backend.production.settings(bookId)['font_size']} · 行距 ${_backend.production.settings(bookId)['line_height']}',
    };
  }

  @override
  Future<FolderCount> countFolder(
    String path, {
    required bool Function() cancelled,
  }) => const NativeFolderCount().countFolder(path, cancelled: cancelled);

  // Shared read/history service is owned by the library, not individual pages.
  LegacyChangeHistoryService? _changeHistory;
  @override
  ChangeHistoryService openChangeHistory() =>
      _changeHistory ??= LegacyChangeHistoryService(_backend);
  @override
  OutputHistoryService openOutputHistory() =>
      LegacyOutputHistoryService(_backend);
  @override
  ConversionSession openConversion() => LegacyConversionSession(_backend);
  @override
  BookBatchSession openBookBatch(String bookId) =>
      LegacyBookBatchSession(_backend, bookId);
  @override
  LayoutBatchSession openLayoutBatch(String bookId) =>
      LegacyLayoutBatchSession(_backend, bookId);
  @override
  ResourceSession openResources(String bookId) =>
      LegacyResourceSession(_backend, bookId);
  LegacyLibraryAdapter({PrototypeState? backend, String? settingsDirectory})
    : _backend =
          backend ?? PrototypeState(settingsDirectory: settingsDirectory),
      _ownsBackend = backend == null {
    if (_ownsBackend) {
      _backend.shelf.books.clear();
      _backend.shelf.selected.clear();
      _backend.currentId = '';
    }
    final settingsPath = settingsDirectory ?? _backend.settingsDirectory;
    _autosave = settingsPath == null
        ? null
        : LocalWorkspaceAutosave(
            directory: paths.join(settingsPath, 'workspace'),
            project: _workspaceProjectDocument,
            restore: _backend.openProjectOutcome,
            projectPath: () => _backend.projectPath,
            restoreProjectPath: (path) => _backend.projectPath = path,
            busy: () => hasPendingWork,
            saved: (payload) => _backend.savedProjectIdentity = jsonEncode(
              Map<String, dynamic>.from(payload)..remove('current_path'),
            ),
          );
    _backend.addListener(_refresh);
    _refresh();
  }
  final PrototypeState _backend;
  final bool _ownsBackend;
  late final LocalWorkspaceAutosave? _autosave;
  bool _autosaveStarted = false;
  final _memoryDrafts = <String, Map<String, dynamic>>{};
  final _memorySaveStatus = ValueNotifier(
    const WorkspaceSaveStatus(WorkspaceSavePhase.saved, '当前会话'),
  );
  @override
  ValueListenable<WorkspaceSaveStatus> get workspaceSave =>
      _autosave?.status ?? _memorySaveStatus;
  @override
  Map<String, dynamic>? readDraft(String key) =>
      _autosave?.readDraft(key) ?? _memoryDrafts[key];
  @override
  void writeDraft(String key, Map<String, dynamic>? value) {
    final autosave = _autosave;
    if (autosave != null) {
      autosave.writeDraft(key, value);
    } else if (value == null) {
      _memoryDrafts.remove(key);
    } else {
      _memoryDrafts[key] = (jsonDecode(jsonEncode(value)) as Map)
          .cast<String, dynamic>();
    }
  }

  @override
  Future<bool> flushWorkspace() async {
    await _backend.outputs.historySaved;
    return !_autosaveStarted ? true : _autosave!.flush();
  }

  String? _storageMoveJob;

  /// V104：UI 在此调用搬家，不能直接向 native 伪报插件已停。
  // ---------------------------------------------------------------- 存储位置界面（V104，SET-108–112）
  @override
  bool get storageAvailable => StorageLocations.initialized;
  @override
  Future<Map<String, dynamic>> storageStatus() =>
      StorageLocations.request({'op': 'status'});
  @override
  Future<Map<String, dynamic>> storageStats() =>
      StorageLocations.request({'op': 'stats'});
  @override
  Future<void> setCacheRoot(String path) =>
      StorageLocations.configure({'op': 'cache.set', 'path': path});
  @override
  Future<void> setImageMode(String mode) =>
      StorageLocations.configure({'op': 'image.set', 'mode': mode});
  @override
  Future<Map<String, dynamic>> cleanCache(List<String> kinds) =>
      StorageLocations.request({'op': 'cache.clean', 'kinds': kinds});

  @override
  Future<Map<String, dynamic>> moveStorage(String target) async {
    final plugins = PluginRegistry.instance;
    if (hasPendingWork || plugins.storageSuspended) {
      throw const StorageException('storage_busy');
    }
    plugins.storageSuspended = true;
    _storageMoveJob = null;
    try {
      if (!await flushWorkspace()) {
        throw const StorageException('storage_flush_failed');
      }
      await plugins.stopForStorage();
      if (hasPendingWork) throw const StorageException('storage_busy');
      final result = await StorageLocations.request({
        'op': 'move.start',
        'path': target,
        'plugins_stopped': true,
      });
      _storageMoveJob = result['job_id'] as String;
      return result;
    } catch (_) {
      plugins.storageSuspended = false;
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> storageMoveProgress(
    String jobId, {
    bool cancel = false,
  }) async {
    final result = await StorageLocations.request({
      'op': cancel ? 'move.cancel' : 'move.poll',
      'job_id': jobId,
    });
    if (_storageMoveJob == jobId &&
        (result['phase'] == 'failed' || result['phase'] == 'cancelled')) {
      _storageMoveJob = null;
      PluginRegistry.instance.storageSuspended = false;
    }
    return result;
  }

  /// 复制成功的图片进入一次制作计划；缺失项保留原路径并逐项返回。
  @override
  Future<Map<String, dynamic>> copyReferencedImages() async {
    if (hasPendingWork) throw const StorageException('storage_busy');
    final identity = _backend.projectIdentity;
    final changes = <String, Map<String, dynamic>>{};
    final missing = <Map<String, dynamic>>[];
    var copied = 0;
    for (final book in _backend.shelf.books.where((b) => !b.isDemo)) {
      final values = _backend.production.settings(book.id);
      final fields = <String, dynamic>{};
      Future<String> copy(String original, int index) async {
        try {
          final path = await StorageLocations.copyImage(original, force: true);
          if (path != original) copied++;
          return path;
        } catch (_) {
          missing.add({
            'book_id': book.id,
            'index': index,
            'path': original,
            'reason': await File(original).exists()
                ? 'unreadable_or_invalid'
                : 'missing',
          });
          return original;
        }
      }

      final cover = values['cover_path'];
      if (cover is String && cover.isNotEmpty) {
        final next = await copy(cover, -1);
        if (next != cover) fields['cover_path'] = {'op': 'set', 'value': next};
      }
      final images =
          (jsonDecode(jsonEncode(values['illustrations'] ?? [])) as List);
      var changed = false;
      for (var i = 0; i < images.length; i++) {
        final item = images[i] as Map;
        final original = item['path'] as String;
        item['path'] = await copy(original, i);
        changed |= item['path'] != original;
      }
      if (changed) fields['illustrations'] = {'op': 'set', 'value': images};
      if (fields.isNotEmpty) {
        changes[book.id] = {'op': 'patch', 'fields': fields};
      }
    }
    if (hasPendingWork || identity != _backend.projectIdentity) {
      throw const StorageException('storage_source_changed');
    }
    if (changes.isNotEmpty) {
      final preview = await _backend.production.previewChanges(changes);
      if (!await _backend.production.confirm(preview)) {
        throw const StorageException('storage_source_changed');
      }
      if (!await flushWorkspace()) {
        throw const StorageException('storage_flush_failed');
      }
    }
    return {'copied': copied, 'missing': missing};
  }

  Future<bool> initializeWorkspace() async {
    if (_autosave == null) return true;
    _autosaveStarted = true;
    _changeHistory?.observing = false;
    final result = await _autosave.initialize();
    _restoreSelection();
    _startChangeTimes();
    return result;
  }

  /// 工作区载入或替换后（重新）建立变更时间登记的基线：已有历史都按“时间未记录”。
  void _startChangeTimes() {
    if (_disposed) return;
    final service = _changeHistory ??= LegacyChangeHistoryService(_backend);
    service
      ..resetTimeObservation()
      ..observing = true;
  }

  void _restoreSelection() {
    final ids = _books.value.map((book) => book.id).toSet();
    _selection.value = BookSelection(
      ids.contains(_backend.currentId) ? _backend.currentId : null,
      _backend.shelf.selected.intersection(ids),
    );
  }

  Map<String, dynamic> _workspaceProjectDocument() {
    final payload = _backend.projectDocument();
    final byPath = {
      for (final book in _backend.shelf.books) book.path: book.id,
    };
    final selection = _selection.value;
    for (final book in (payload['books'] as List).cast<Map>()) {
      final id = byPath[book['path']];
      book['selected'] = selection.selected.contains(id);
      if (selection.current == id) payload['current_path'] = book['path'];
    }
    return payload;
  }

  /// Used by controlled shutdown and integration harnesses after flushing.
  Future<void> closeWorkspaceStorage() async => _autosave?.close();
  final _checking = <String>{};
  @override
  final checkBatch = LibraryCheckBatch();
  @override
  Future<void> inspectBooks(Set<String> ids) async {
    if (_disposed || hasPendingWork || _checking.isNotEmpty) {
      throw const FormatException('请等待当前操作完成后再检查。');
    }
    final targets = _books.value.where((b) => ids.contains(b.id)).toList();
    if (targets.length != ids.length || targets.isEmpty) {
      throw const FormatException('请重新选择要检查的书籍。');
    }
    await checkBatch.run(
      [for (final b in targets) (b.id, b.title)],
      openChecks,
      parallel: parallelBooks(_backend.globalConfiguration),
    );
  }

  bool _disposed = false, _batchBusy = false, _cancelled = false;
  final _settings = ValueNotifier<SettingsSnapshot>(
    const SettingsSnapshot(
      configuration: {},
      status: '',
      busy: false,
      loaded: false,
      theme: 'paper',
      reducedMotion: false,
    ),
  );
  final _books = ValueNotifier<List<BookSummary>>(const []);
  final _selection = ValueNotifier(BookSelection(null, {}));
  final _removedCount = ValueNotifier<int>(0);
  final _removed = <(DetachedBooks, BookSelection, RemovedBookBatch)>[];
  int _nextRemoval = 0;
  @override
  List<RemovedBookBatch> get removedBatches =>
      List.unmodifiable(_removed.reversed.map((e) => e.$3));
  int _removalEpoch = 0;
  @override
  ValueListenable<int> get removedBatchCount => _removedCount;

  void _removalAvailable(Set<String> ids) {
    if (_disposed) throw StateError('Library service disposed');
    if (_backend.outputs.batchBusy ||
        _backend.outputs.tasks.any(
          (t) => ids.contains(t.bookId) && !t.terminal,
        )) {
      throw const LibraryRemovalBlocked(
        '书籍仍被转换任务使用，请先完成或取消任务。',
        openTasks: true,
      );
    }
    if (hasPendingWork || _checking.any(ids.contains)) {
      throw const LibraryRemovalBlocked('书稿正在处理，请等待当前操作完成后再移除。');
    }
  }

  @override
  void removeBooks(Set<String> ids) {
    _removalAvailable(ids);
    final selection = _selection.value;
    final info = RemovedBookBatch(
      ++_nextRemoval,
      List.unmodifiable(
        _books.value.where((b) => ids.contains(b.id)).map((b) => b.title),
      ),
    );
    final removedPaths = [
      for (final b in _books.value)
        if (ids.contains(b.id)) b.path,
    ];
    final snapshot = _backend.detachBooks(Set.of(ids));
    _removed.add((snapshot, selection, info));
    _rememberRemoved(removedPaths, removed: true);
    _removedCount.value = _removed.length;
  }

  @override
  void undoBookRemoval({int? batchId}) {
    if (_removed.isEmpty) {
      if (batchId != null) throw const FormatException('恢复记录已失效。');
      return;
    }
    final index = batchId == null
        ? _removed.length - 1
        : _removed.indexWhere((e) => e.$3.id == batchId);
    if (index < 0) throw const FormatException('恢复记录已失效。');
    final entry = _removed[index];
    _removalAvailable(entry.$1.ids);
    _backend.restoreDetachedBooks(entry.$1);
    _removed.removeAt(index);
    _rememberRemoved([
      for (final b in _books.value)
        if (entry.$1.ids.contains(b.id)) b.path,
    ], removed: false);
    final selected = {
      ..._selection.value.selected,
      ...entry.$2.selected.intersection(entry.$1.ids),
    };
    final current = entry.$1.ids.contains(entry.$2.current)
        ? entry.$2.current
        : _selection.value.current;
    _selection.value = BookSelection(current, selected);
    _removedCount.value = _removed.length;
  }

  @override
  ValueListenable<SettingsSnapshot> get snapshot => _settings;
  void _refreshSettings() {
    _settings.value = SettingsSnapshot(
      configuration: Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(_backend.globalConfiguration),
      ),
      status: _backend.globalSettingsStatus,
      busy: _backend.globalSettingsBusy,
      loaded: _backend.globalSettingsLoaded,
      theme: _backend.theme,
      reducedMotion: _backend.reducedMotion,
    );
  }

  @override
  Future<bool> load() async {
    final result = await _backend.loadGlobalSettings();
    _refreshSettings();
    _startChangeTimes();
    if (result) await _syncWindowPreference();
    _autoFolders.value = _configList('auto_import_folders');
    if (result && _autoFolders.value.isNotEmpty) unawaited(_autoImport.start());
    return result;
  }

  @override
  Future<bool> savePatch(Map<String, dynamic> patch) async {
    if (_backend.globalConfiguration['backup_before_change'] == true) {
      final destination =
          (_backend.globalConfiguration['backup_directory'] as String?)?.trim();
      final base = _backend.settingsDirectory;
      if (base != null) {
        final backup = await createBackup(
          destination == null || destination.isEmpty
              ? '${Directory(base).parent.path}/settings-backups'
              : destination,
        );
        if (backup == null) throw const FormatException('设置备份失败，未保存变更。');
      }
    }
    final result = await _backend.saveGlobalConfigurationPatch(patch);
    _refreshSettings();
    if (result) await _syncWindowPreference();
    return result;
  }

  Future<void> _syncWindowPreference() async {
    if (_backend.settingsDirectory != null) {
      final marker = File(
        '${_backend.settingsDirectory}/window-restore-disabled',
      );
      if (_backend.globalConfiguration['restore_window'] == false) {
        await marker.parent.create(recursive: true);
        await marker.writeAsString('disabled', flush: true);
      } else if (await marker.exists()) {
        await marker.delete();
      }
    }
  }

  @override
  Future<String?> createBackup(String destination) async {
    final sourcePath = _backend.settingsDirectory;
    if (sourcePath == null || destination.trim().isEmpty) return null;
    final source = Directory(sourcePath);
    if (!await source.exists()) return null;
    final root = Directory(destination);
    final sourceRoot = paths
        .normalize(source.absolute.path)
        .replaceAll('\\', '/')
        .toLowerCase();
    final targetRoot = paths
        .normalize(root.absolute.path)
        .replaceAll('\\', '/')
        .toLowerCase();
    if (targetRoot == sourceRoot || targetRoot.startsWith('$sourceRoot/')) {
      throw const FormatException('备份目录不能位于当前设置目录内。');
    }
    await root.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final target = Directory('${root.path}/EasyPubPlusPlus-settings-$stamp');
    await _copyDirectory(source, target);
    return target.path;
  }

  @override
  Future<Map<String, dynamic>?> inspectBackup(String path) async {
    final candidate = PrototypeState(settingsDirectory: path);
    try {
      if (!await candidate.loadGlobalSettings()) return null;
      return {
        'path': path,
        'fields': candidate.globalConfiguration.keys.toList()..sort(),
        'has_output_history':
            (candidate.globalConfiguration['output_batches'] as List?)
                ?.isNotEmpty ??
            false,
      };
    } finally {
      candidate.dispose();
    }
  }

  @override
  Future<bool> restoreBackup(String path) async {
    final candidate = PrototypeState(settingsDirectory: path);
    try {
      if (!await candidate.loadGlobalSettings()) return false;
      return await savePatch(
        Map<String, dynamic>.from(candidate.globalConfiguration),
      );
    } finally {
      candidate.dispose();
    }
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entry in source.list(followLinks: false)) {
      final child = FileSystemEntity.isDirectorySync(entry.path)
          ? Directory('${target.path}/${paths.basename(entry.path)}')
          : File('${target.path}/${paths.basename(entry.path)}');
      if (entry is Directory) {
        await _copyDirectory(entry, child as Directory);
      } else if (entry is File) {
        await entry.copy(child.path);
      }
    }
  }

  @override
  Future<Map<String, dynamic>> inspectLegacy(String path) =>
      _backend.inspectLegacySettings(path);
  @override
  ValueListenable<BookSelection> get selection => _selection;
  @override
  void selectBook(String id) {
    if (_books.value.any((b) => b.id == id)) {
      _selection.value = BookSelection(id, _selection.value.selected);
      _autosave?.changed();
    }
  }

  @override
  void checkBook(String id, bool checked) {
    checkBooks([id], checked);
  }

  @override
  void checkBooks(Iterable<String> ids, bool checked) {
    final valid = _books.value.map((b) => b.id).toSet();
    final targets = ids.toSet().intersection(valid);
    final next = {..._selection.value.selected};
    checked ? next.addAll(targets) : next.removeAll(targets);
    if (!setEquals(next, _selection.value.selected)) {
      _selection.value = BookSelection(_selection.value.current, next);
      _autosave?.changed();
    }
  }

  @override
  BookInformationSession openBookInformation(String bookId) =>
      LegacyBookInformationSession(_backend, bookId);
  @override
  LayoutSession openLayout(String bookId) =>
      LegacyLayoutSession(_backend, bookId);
  @override
  MappingSession openMapping() => LegacyMappingSession(_backend);
  @override
  CatalogSession openCatalog(String bookId) =>
      LegacyCatalogSession(_backend, bookId);
  @override
  BookCheckSession openChecks(String bookId) =>
      LegacyBookCheckSession(_backend, bookId);
  @override
  CleanupSession openCleanup(String bookId) =>
      LegacyCleanupSession(_backend, bookId);

  @override
  CleanupBatchSession openCleanupBatch(String bookId) =>
      LegacyCleanupBatchSession(_backend, bookId);
  @override
  ChapterSession openChapters(String bookId) =>
      LegacyChapterSession(_backend, bookId);
  @override
  BlockAnnotationSession openBlockAnnotations(String bookId) =>
      LegacyBlockAnnotationSession(_backend, bookId);

  @override
  ManualNoteSession openManualNotes(String bookId) =>
      LegacyManualNoteSession(_backend, bookId);

  @override
  RuleCatalogService openRuleCatalog(String bookId) =>
      LegacyRuleCatalogService(_backend, bookId);

  /// 自动更新（V68）：与书库无关，整个程序一个。
  @override
  late final AppUpdateService appUpdates = LegacyAppUpdateService();

  @override
  bool get updateBlockedByTasks => _backend.queueActive;

  @override
  SupplementalPageSession openSupplementalPages(String bookId) =>
      LegacySupplementalPageSession(_backend, bookId);
  @override
  SupplementalTemplateService get supplementalTemplates =>
      LegacySupplementalTemplateService(_backend);
  final _importing = ValueNotifier(false);
  final _projectBusy = ValueNotifier(false);
  final _workspaceGeneration = ValueNotifier(0);
  @override
  ValueListenable<int> get workspaceGeneration => _workspaceGeneration;
  final _favorites = ValueNotifier<List<String>>(const []);
  final _favoriteNames = ValueNotifier<Map<String, String>>(const {});
  @override
  ValueListenable<Map<String, String>> get favoriteNames => _favoriteNames;
  @override
  String favoriteName(String path) =>
      _favoriteNames.value[folderImportPathKey(path)] ??
      path.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty).last;
  Future<bool> _favoriteOperation(Future<bool> Function() action) async {
    if (_disposed || _savingFavorite) return false;
    _savingFavorite = true;
    try {
      if (!await _backend.loadGlobalSettings()) return false;
      return await action();
    } finally {
      _savingFavorite = false;
    }
  }

  @override
  Future<bool> renameFavorite(String path, String name) =>
      _favoriteOperation(() => _backend.shelf.renameFavoriteFolder(path, name));
  @override
  Future<bool> relocateFavorite(String path, String newPath) =>
      _favoriteOperation(
        () => _backend.shelf.relocateFavoriteFolder(path, newPath),
      );
  bool _savingFavorite = false;
  @override
  ValueListenable<List<String>> get favoriteFolders => _favorites;
  @override
  Future<bool> loadFavorites() => _backend.loadGlobalSettings();
  @override
  Future<bool> setFavorite(String path, bool favorite) async {
    return _favoriteOperation(
      () => favorite
          ? _backend.shelf.addFavoriteFolder(path)
          : _backend.shelf.removeFavoriteFolder(path),
    );
  }

  @override
  ValueListenable<bool> get projectBusy => _projectBusy;
  @override
  ValueListenable<List<BookSummary>> get books => _books;
  @override
  ValueListenable<bool> get importing => _importing;

  /// 原文件大小缓存：按路径只读一次文件属性，避免每次刷新书库都访问磁盘。
  final _sourceBytes = <String, int?>{};
  int? _bytesOf(String path) => _sourceBytes.putIfAbsent(path, () {
    try {
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : null;
    } on FileSystemException {
      return null;
    }
  });

  BookSummary _summary(SampleBook b) {
    final settings = _backend.production.settings(b.id);
    Map<String, dynamic>? snapshot(String key) {
      final value = settings[key] as Map?;
      return value == null
          ? null
          : Map<String, dynamic>.unmodifiable(value.cast<String, dynamic>());
    }

    final checking = _checking.contains(b.id);
    // 稿件版本只算一次，检查指纹按它缓存（LIB-114）。
    final version = _backend.publicationContext(b.id);
    final check = checking
        ? null
        : LegacyBookCheckSession.summaryFor(_backend, b.id, version: version);
    return BookSummary(
      id: b.id,
      title: _backend.displayTitle(b),
      author: _backend.authorOf(b),
      path: b.source!.originPath ?? b.path,
      bytes: _bytesOf(b.source!.originPath ?? b.path),
      format: b.format,
      chapters: b.chapters,
      contentVersion: version,
      status: checking ? '检查中…' : check?.status ?? b.status,
      pending: check?.pending,
      coverPath: _backend.production.coverPathFor(b),
      category: '${settings['category'] ?? ''}'.trim(),
      series: '${settings['series'] ?? ''}'.trim(),
      coverFit: settings['cover_fit'] as String? ?? 'contain',
      coverCrop: snapshot('cover_crop'),
      coverDesign: snapshot('cover_design'),
    );
  }

  final _summaries = <String, BookSummary>{};

  void _refresh({Set<String>? bookIds}) => ImportProfile.measure(
    'library_refresh',
    () => _refreshMeasured(bookIds ?? _backend.changedBookIds),
  );

  void _refreshMeasured(Set<String>? bookIds) {
    // Progress has its own task/history listeners and never changes a book or
    // workspace draft. Avoid rebuilding every book and scheduling a save.
    if (_backend.taskNotification) return;
    _refreshSettings();
    if (_disposed) return;
    _autosave?.changed();
    if (_removalEpoch != _backend.removalEpoch) {
      _removalEpoch = _backend.removalEpoch;
      _statistics.clear();
      checkBatch.reset();
      _removed.clear();
      _removedCount.value = 0;
    }
    if (!mapEquals(_favoriteNames.value, _backend.shelf.favoriteFolderNames)) {
      _favoriteNames.value = Map.unmodifiable(
        _backend.shelf.favoriteFolderNames,
      );
    }
    if (!listEquals(_favorites.value, _backend.shelf.favoriteFolders)) {
      _favorites.value = List.unmodifiable(_backend.shelf.favoriteFolders);
    }
    final next = [
      for (final b in _backend.shelf.books.where((b) => !b.isDemo))
        if (bookIds != null &&
            !bookIds.contains(b.id) &&
            _summaries.containsKey(b.id))
          _summaries[b.id]!
        else
          _summaries[b.id] = _summary(b),
    ];
    final liveIds = next.map((b) => b.id).toSet();
    _summaries.removeWhere((id, _) => !liveIds.contains(id));
    final before = _books.value;
    if (next.length != before.length ||
        Iterable.generate(next.length).any((i) {
          final a = next[i], b = before[i];
          return a.id != b.id ||
              a.title != b.title ||
              a.author != b.author ||
              a.status != b.status ||
              a.chapters != b.chapters ||
              a.contentVersion != b.contentVersion ||
              a.coverPath != b.coverPath ||
              a.coverFit != b.coverFit ||
              !mapEquals(a.coverCrop, b.coverCrop) ||
              !mapEquals(a.coverDesign, b.coverDesign) ||
              a.path != b.path ||
              a.category != b.category ||
              a.series != b.series ||
              a.format != b.format;
        })) {
      _books.value = List.unmodifiable(next);
      final ids = next.map((b) => b.id).toSet();
      final current = ids.contains(_selection.value.current)
          ? _selection.value.current
          : next.firstOrNull?.id;
      final selected = _selection.value.selected.intersection(ids);
      if (current != _selection.value.current ||
          !setEquals(selected, _selection.value.selected)) {
        _selection.value = BookSelection(current, selected);
      }
    }
  }

  @override
  Future<List<ImportOutcome>> importFiles(
    List<String> paths, {
    bool skipExisting = false,
  }) async {
    if (_disposed) throw StateError('Library service disposed');
    if (_batchBusy || _projectBusy.value) throw StateError('已有项目操作正在执行');
    if (paths.length > 128) throw const FormatException('单次最多导入 128 本书稿。');
    _batchBusy = true;
    _cancelled = false;
    _importing.value = true;
    final results = <ImportOutcome>[];
    // 批次期间不能移除/替换书库；路径只规范化一次，成功导入后更新集合。
    final knownPaths = _books.value
        .map((b) => folderImportPathKey(b.path))
        .toSet();
    // 同时处理的书（V38，LIB-115）：前面几本解析的同时，后面的已开始读取；导入后的检查也几本同时进行。
    final parallel = parallelBooks(_backend.globalConfiguration);
    final checks = ConcurrencyLimit(parallel);
    final pendingChecks = <Future<void>>[];
    var prefetched = 0;
    void prefetchAhead(int from) {
      while (prefetched < paths.length && prefetched < from + parallel) {
        final path = paths[prefetched++];
        final known = knownPaths.contains(folderImportPathKey(path));
        if (!known) _backend.prefetchImport(path);
      }
    }

    try {
      for (final (index, path) in paths.indexed) {
        if (_cancelled || _disposed) break;
        if (parallel > 1) prefetchAhead(index);
        final pathKey = folderImportPathKey(path);
        final existed = knownPaths.contains(pathKey);
        if (skipExisting && existed) {
          results.add(ImportOutcome(path, true, '已在书库，保留现有草稿', skipped: true));
          continue;
        }
        final succeeded = await ImportProfile.measureAsync(
          'backend_import',
          () => _backend.importBookOutcome(path),
        );
        ImportProfile.book(_books.value.length);
        if (_disposed) break;
        if (succeeded) knownPaths.add(pathKey);
        results.add(
          ImportOutcome(
            path,
            succeeded,
            _backend.importStatus,
            skipped: succeeded && existed,
          ),
        );
        if (succeeded &&
            _backend.globalConfiguration['check_after_import'] != false) {
          final id = _backend.currentId;
          _checking.add(id);
          _refresh(bookIds: {id});
          Future<void> inspect() async {
            final session = openChecks(id);
            try {
              await ImportProfile.measureAsync('check', session.inspect);
            } catch (_) {
              // Import success is independent of analysis; the user can retry checks.
            } finally {
              session.dispose();
              _checking.remove(id);
              if (!_disposed) _refresh(bookIds: {id});
            }
          }

          // 1 本时与原来相同：检查完再导入下一本。
          if (parallel == 1) {
            await inspect();
          } else {
            pendingChecks.add(checks.run(inspect));
          }
        }
      }
      await Future.wait(pendingChecks);
      return List.unmodifiable(results);
    } finally {
      _backend.dropPrefetchedImports();
      _batchBusy = false;
      if (!_disposed) _importing.value = false;
    }
  }

  @override
  Future<FolderListing> scanFolder(
    String path, {
    required bool recursive,
    required bool Function() cancelled,
  }) async {
    final result = await scanBookFolder(
      path,
      recursive: recursive,
      cancelled: () => _disposed || cancelled(),
      importedPaths: _books.value.map((b) => b.path).toSet(),
      retainCursor: true,
    );
    FolderListing convert(FolderScanResult result) {
      final known = _books.value
          .map((b) => folderImportPathKey(b.path))
          .toSet();
      return FolderListing(
        List.unmodifiable(
          result.entries.map(
            (e) => FolderBook(
              e.path,
              e.bytes,
              known.contains(folderImportPathKey(e.path)),
              modified: e.modified,
            ),
          ),
        ),
        result.skipped,
        result.complete,
        result.message,
        close: result.close,
        failures: result.failures,
        resume: result.resume == null
            ? null
            : (cancelled) async =>
                  convert(await result.resume!(() => _disposed || cancelled())),
      );
    }

    return convert(result);
  }

  Future<ProjectOutcome> _project(String path, {required bool save}) async {
    if (_disposed) throw StateError('Library service disposed');
    if (_batchBusy || _projectBusy.value || checkBatch.running) {
      return const ProjectOutcome(false, '请等待当前操作完成。');
    }
    _projectBusy.value = true;
    if (!save) _changeHistory?.observing = false;
    try {
      final ok = save
          ? await _backend.saveProjectOutcome(path)
          : await _backend.openProjectOutcome(path);
      if (ok && !save && !_disposed) {
        _autosave?.clearDrafts();
        _memoryDrafts.clear();
        _restoreSelection();
        _workspaceGeneration.value++;
      }
      return ProjectOutcome(ok, _backend.projectStatus);
    } finally {
      if (!save) _startChangeTimes();
      if (!_disposed) _projectBusy.value = false;
    }
  }

  @override
  Future<ProjectOutcome> saveProject(String path) => _project(path, save: true);
  @override
  Future<ProjectOutcome> clearWorkspace() async {
    if (_disposed || hasPendingWork) {
      return const ProjectOutcome(false, '请等待当前操作完成。');
    }
    _projectBusy.value = true;
    _changeHistory?.observing = false;
    try {
      final ok = await _backend.clearWorkspace();
      if (ok && !_disposed) {
        _autosave?.clearDrafts();
        _memoryDrafts.clear();
        _restoreSelection();
        _workspaceGeneration.value++;
      }
      return ProjectOutcome(ok, _backend.projectStatus);
    } finally {
      _startChangeTimes();
      if (!_disposed) _projectBusy.value = false;
    }
  }

  @override
  Future<ProjectOutcome> openProject(String path) =>
      _project(path, save: false);

  @override
  void cancelImport() {
    _cancelled = true;
    _backend.cancelImport();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _autoImport.dispose();
    _autoFolders.dispose();
    _collections?.dispose();
    checkBatch.dispose();
    _cancelled = true;
    _backend.removeListener(_refresh);
    if (_autosave != null) unawaited(_autosave.close());
    _memorySaveStatus.dispose();
    _changeHistory?.dispose();
    _changeHistory = null;
    if (_ownsBackend) _backend.dispose();
    _books.dispose();
    _selection.dispose();
    _removed.clear();
    _statistics.clear();
    _removedCount.dispose();
    _importing.dispose();
    _projectBusy.dispose();
    _workspaceGeneration.dispose();
    _favorites.dispose();
    _favoriteNames.dispose();
    _settings.dispose();
  }
}
