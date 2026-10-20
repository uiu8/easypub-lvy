// 书库（LIB-001–040）：页头（导入、更多导入方式、撤销移除）、搜索与筛选、勾选工具条、书稿列表、
// 右侧当前书摘要与底部转换入口。导入、勾选、移除/撤销、批量检查、来源刷新的逻辑逐行沿用 V6 前的
// LibraryPage；视图按 design_review_v37/d4_library.dart（D4-A）重写。
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../errors.dart';

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

import 'book_summary_panel.dart';
import 'library_view_state.dart';
import 'book_structure_counts.dart';
import 'source_refresh_dialog.dart';
import '../shell/workspace_leave.dart';
import '../../application/source_refresh_service.dart';
import '../../application/library_check_batch.dart';

import '../../application/folder_auto_import.dart';
import '../../application/book_collection_service.dart';
import '../collections/collection_flow.dart';
import '../collections/collection_rail.dart';
import '../../application/library_service.dart';
import '../../application/output_history_service.dart';
import '../../application/folder_import_batch.dart';
import '../controls/controls.dart';
import '../controls/drag_select.dart';
import '../folders/folder_import_dialog.dart';
import '../folders/favorites_dialog.dart';
import '../layout/book_batch_dialog.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.library,
    required this.picker,
    this.onConvert,
    this.onConvertBook,
    this.viewState,
    this.conversionBusy = false,
    this.onRevealSource,
    this.outputs,
    this.onRevealOutput,
    this.onOutputHistory,
    this.showConversionActions = true,
  });
  final LibraryService library;
  final bool showConversionActions;
  final bool conversionBusy;
  final LibraryViewState? viewState;
  final BookFilePicker picker;
  final VoidCallback? onConvert;
  final void Function(String)? onConvertBook;
  final Future<void> Function(String)? onRevealSource;

  /// 转换历史；为 null 时详情栏不显示“最近输出”（LIB-113）。
  final OutputHistoryService? outputs;

  /// 打开某次输出所在的文件夹（LIB-113）。
  final Future<void> Function(OutputRecord)? onRevealOutput;

  /// 进入转换历史（LIB-113）。
  final VoidCallback? onOutputHistory;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  LibraryRemovalService? get removals => widget.library is LibraryRemovalService
      ? widget.library as LibraryRemovalService
      : null;
  LibraryBatchChecks? get batchChecks => widget.library is LibraryBatchChecks
      ? widget.library as LibraryBatchChecks
      : null;
  Future<void> inspectSelected() async {
    try {
      await batchChecks!.inspectBooks(Set.of(selected));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(deskErrorText(e, '无法开始检查，请稍后重试。'))),
        );
      }
    }
  }

  void showCheckResults() {
    final batch = batchChecks!.checkBatch;
    final results = batch.results;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => DeskAlert(
        title: Text('批量检查 · 已完成 ${results.length} / ${batch.total}'),
        content: SizedBox(
          width: 680,
          height: 420,
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (_, i) {
              final item = results[i];
              return ListTile(
                title: Text(item.title),
                subtitle: Text(item.message),
                leading: Icon(
                  item.failed ? Icons.error_outline : Icons.fact_check_outlined,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(dialogContext);
                  if (!widget.library.books.value.any((b) => b.id == item.id)) {
                    return;
                  }
                  widget.library.selectBook(item.id);
                  context.go('/books/${Uri.encodeComponent(item.id)}/checks');
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String query = '', filter = '全部书稿', format = '全部格式';

  /// 显示范围与排序（V84，LIB-118/125/127）。
  String scope = '', sort = 'default';
  bool descending = false;
  final collectionKeys = <String, GlobalKey>{};
  String? fileHoverCollection;
  BookCollectionService? get collectionService =>
      widget.library is BookCollectionService
      ? widget.library as BookCollectionService
      : null;
  bool compact = false, onlySelected = false;
  String? rangeAnchor;
  final scroll = ScrollController(keepScrollOffset: false);
  final searchFocus = FocusNode();
  late final searchInput = TextEditingController(
    text: widget.viewState?.search ?? '',
  );
  List<BookSummary> _visible = [];
  double _extent = 132;

  /// 书架视图每行几本（列表视图为 1）；滚动位置按“行”保存和恢复。
  int _columns = 1;
  bool _restore = true;
  bool _restoreScheduled = false;
  void rememberView() {
    final view = widget.viewState;
    if (view == null) return;
    view.search = searchInput.text;
    view.filter = filter;
    view.format = format;
    view.onlySelected = onlySelected;
    view.scope = scope;
    view.railCollapsed = railCollapsed;
    view.railWidth = railWidthValue;
    view.sort = sort;
    view.descending = descending;
    view.compact = compact;
    view.rangeAnchor = rangeAnchor;
    if (!_restore && scroll.hasClients && _visible.isNotEmpty) {
      final row = scroll.offset / _extent;
      final index = (row.floor() * _columns).clamp(0, _visible.length - 1);
      view.topBookId = _visible[index].id;
      view.topIndex = index;
      view.fraction = (row - row.floor()).clamp(0.0, 1.0);
    }
  }

  void restoreView() {
    if (!_restore || _restoreScheduled || _visible.isEmpty) return;
    _restoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreScheduled = false;
      if (!mounted || !scroll.hasClients || !_restore) return;
      final view = widget.viewState;
      final found = _visible.indexWhere((b) => b.id == view?.topBookId);
      final index = found >= 0
          ? found
          : (view?.topIndex ?? 0).clamp(0, _visible.length - 1);
      final offset = (index ~/ _columns + (view?.fraction ?? 0)) * _extent;
      scroll.jumpTo(offset.clamp(0.0, scroll.position.maxScrollExtent));
      _restore = false;
      rememberView();
    });
  }

  void changeFilter({
    String? search,
    String? category,
    String? sourceFormat,
    bool? checkedOnly,
    String? libraryScope,
  }) {
    setState(() {
      if (libraryScope != null) scope = libraryScope;
      if (search != null) query = search.trim().toLowerCase();
      if (category != null) filter = category;
      if (sourceFormat != null) format = sourceFormat;
      if (checkedOnly != null) onlySelected = checkedOnly;
      rangeAnchor = null;
      _restore = false;
      final view = widget.viewState;
      if (view != null) {
        view.topBookId = null;
        view.topIndex = 0;
        view.fraction = 0;
      }
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    rememberView();
  }

  /// 列表视图的行高（LIB-101：列表封面放大到 48×64）。
  double rowExtent(BuildContext context) =>
      76 * MediaQuery.textScalerOf(context).scale(1);

  void checkMany(Iterable<String> ids, bool checked) {
    final service = widget.library;
    if (service is LibraryBulkSelection) {
      (service as LibraryBulkSelection).checkBooks(ids, checked);
    } else {
      for (final id in ids.toList()) {
        service.checkBook(id, checked);
      }
    }
  }

  void checkRow(List<BookSummary> visible, String id, bool checked) {
    final anchor = visible.indexWhere((b) => b.id == rangeAnchor);
    final index = visible.indexWhere((b) => b.id == id);
    if (HardwareKeyboard.instance.isShiftPressed && anchor >= 0 && index >= 0) {
      final first = anchor < index ? anchor : index;
      final last = anchor > index ? anchor : index;
      checkMany(visible.sublist(first, last + 1).map((b) => b.id), checked);
    } else {
      widget.library.checkBook(id, checked);
      rangeAnchor = id;
    }
  }

  /// 书架 ↔ 列表：切换后仍停在原来最上面的那本书附近。
  void changeView() {
    final first = scroll.hasClients
        ? (scroll.offset / _extent).floor() * _columns
        : 0;
    setState(() => compact = !compact);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(
          ((first ~/ _columns) * _extent).clamp(
            0.0,
            scroll.position.maxScrollExtent,
          ),
        );
      }
    });
    rememberView();
  }

  String? get currentId => widget.library.selection.value.current;
  Set<String> get selected => widget.library.selection.value.selected;
  void selectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    final view = widget.viewState;
    query = (view?.search ?? '').trim().toLowerCase();
    filter = view?.filter ?? '全部书稿';
    format = view?.format ?? '全部格式';
    onlySelected = view?.onlySelected ?? false;
    scope = view?.scope ?? '';
    railCollapsed = view?.railCollapsed ?? false;
    railWidthValue = view?.railWidth ?? 184;
    sort = view?.sort ?? 'default';
    descending = view?.descending ?? false;
    if (filter == 'TXT' || filter == 'EPUB') {
      format = filter;
      filter = '全部书稿';
    }
    if (filter == '已勾选') {
      onlySelected = true;
      filter = '全部书稿';
    }
    compact = view?.compact ?? false;
    rangeAnchor = view?.rangeAnchor;
    scroll.addListener(rememberView);
    widget.library.selection.addListener(selectionChanged);
    // 读取转换历史供“最近输出”使用；只读一次，失败时历史服务自己记录状态。
    widget.outputs?.load();
    removals?.removedBatchCount.addListener(selectionChanged);
    batchChecks?.checkBatch.addListener(selectionChanged);
    collectionService?.collections.addListener(selectionChanged);
  }

  @override
  void dispose() {
    rememberView();
    searchInput.dispose();
    searchFocus.dispose();
    widget.library.selection.removeListener(selectionChanged);
    removals?.removedBatchCount.removeListener(selectionChanged);
    batchChecks?.checkBatch.removeListener(selectionChanged);
    collectionService?.collections.removeListener(selectionChanged);
    scroll.dispose();
    super.dispose();
  }

  bool picking = false, fileImporting = false, importCancelled = false;
  int? _undoBatchId;
  String? _undoMessage;
  void cancelImport() {
    importCancelled = true;
    widget.library.cancelImport();
  }

  Future<void> importFolder({bool favorite = false, String? collection}) async {
    if (picking || fileImporting || widget.library.importing.value) return;
    String? path;
    if (favorite) {
      setState(() => picking = true);
      try {
        path = await showDialog<String>(
          context: context,
          builder: (_) =>
              FavoritesDialog(library: widget.library, picker: widget.picker),
        );
      } finally {
        if (mounted) setState(() => picking = false);
      }
      if (!mounted || path == null) return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => FolderImportDialog(
        library: widget.library,
        picker: widget.picker,
        initialPath: path,
        initialCollection: collection ?? currentCollection,
      ),
    );
  }

  /// 当前显示范围是收藏夹时为其 id（导入时默认加入它）。
  String? get currentCollection =>
      scope.startsWith('c:') ? scope.substring(2) : null;

  /// 导入完成后把成功的书加入收藏夹（V84，LIB-122）。
  Future<void> joinImported(
    String collection,
    Iterable<ImportOutcome> results,
  ) async {
    final service = collectionService;
    if (service == null || !mounted) return;
    final ids = [
      for (final r in results)
        if (r.succeeded) ?service.bookIdForPath(r.path),
    ];
    if (ids.isNotEmpty) await joinCollection(context, service, collection, ids);
  }

  void remove(Set<String> ids, {bool undo = false, int? batchId}) {
    try {
      if (undo) {
        removals!.undoBookRemoval(batchId: batchId);
        if (mounted) {
          setState(() {
            _undoBatchId = null;
            _undoMessage = null;
          });
        }
      } else {
        removals!.removeBooks(ids);
        if (mounted && removals!.removedBatches.isNotEmpty) {
          final latest = removals!.removedBatches.first;
          setState(() {
            _undoBatchId = latest.id;
            _undoMessage = latest.titles.length == 1
                ? '已从书库移除“${latest.titles.single}”，原文件保留。'
                : '已从书库移除 ${latest.titles.length} 本书，原文件保留。';
          });
        }
      }
    } catch (error) {
      final blocked = error is LibraryRemovalBlocked ? error : null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            blocked?.message ?? (deskErrorText(error, '移除未完成：$error')),
          ),
          action: blocked?.openTasks == true
              ? SnackBarAction(
                  label: '查看任务',
                  onPressed: () => context.go('/tasks'),
                )
              : null,
        ),
      );
    }
  }

  Widget undoBanner() {
    final message = _undoMessage;
    final id = _undoBatchId;
    if (message == null || id == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: context.desk.ink,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                key: const ValueKey('library-undo-removal'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () => remove({}, undo: true, batchId: id),
                child: const Text('撤销'),
              ),
              IconButton(
                tooltip: '关闭提示',
                onPressed: () => setState(() {
                  _undoBatchId = null;
                  _undoMessage = null;
                }),
                icon: const Icon(Icons.close, color: Colors.white, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> restoreBooks() async {
    final records = removals!.removedBatches;
    if (records.isEmpty) return;
    final id = records.length == 1
        ? records.single.id
        : await showDialog<int>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('恢复移除的书籍'),
              children: [
                for (final record in records)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, record.id),
                    child: Text(
                      '记录 ${record.id} · ${record.titles.length} 本 · ${record.titles.take(3).join('、')}',
                    ),
                  ),
              ],
            ),
          );
    if (mounted && id != null) remove({}, undo: true, batchId: id);
  }

  Future<void> bookAction(BookSummary book, String action) async {
    if (action == 'restore_source') {
      final path = (widget.library as SourceRefreshService).sourceRecoveryPath(
        book.id,
      );
      if (path != null) {
        try {
          await restoreSource(path);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(e.toString())));
          }
        }
      }
      return;
    }
    if (action == 'refresh_source') {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SourceRefreshDialog(
          service: widget.library as SourceRefreshService,
          bookId: book.id,
          onRestore: restoreSource,
        ),
      );
      return;
    }
    if (action == 'remove') {
      remove({book.id});
      return;
    }
    if (action == 'collect') {
      await collect([book.id]);
      return;
    }
    if (action == 'source') {
      try {
        await widget.onRevealSource!(book.path);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(deskErrorText(error, '未能定位原文件：$error'))),
          );
        }
      }
      return;
    }
    widget.library.selectBook(book.id);
    if (mounted) context.go('/books/${Uri.encodeComponent(book.id)}/$action');
  }

  Future<bool> restoreSource(String path) async {
    if (!await confirmWorkspaceLeave(
      context,
      widget.library,
      widget.picker,
      action: '打开旧书稿恢复项目（仅本书）',
    )) {
      return false;
    }
    if (!mounted) return false;
    final result = await widget.library.openProject(path);
    if (!result.succeeded) throw FormatException(result.message);
    return true;
  }

  Widget bookMenu(BookSummary book) => DeskCommandMenu<String>(
    tooltip: '书籍操作：${book.title}',
    onSelected: (action) => bookAction(book, action),
    itemBuilder: (_) => [
      for (final item in const [
        ('overview', '书稿概览'),
        ('chapters', '编辑章节'),
        ('checks', '检查与修复'),
        ('cleanup', '文本清理'),
        ('information', '书籍信息与封面'),
      ])
        PopupMenuItem(height: 36, value: item.$1, child: Text(item.$2)),
      PopupMenuItem(
        height: 36,
        value: 'source',
        enabled: widget.onRevealSource != null,
        child: const Text('在资源管理器中显示原文件'),
      ),
      if (widget.library is SourceRefreshService)
        const PopupMenuItem(
          height: 36,
          value: 'refresh_source',
          child: Text('刷新来源…'),
        ),
      if (widget.library is SourceRefreshService &&
          (widget.library as SourceRefreshService).sourceRecoveryPath(
                book.id,
              ) !=
              null)
        const PopupMenuItem(
          height: 36,
          value: 'restore_source',
          child: Text('打开刷新前的书稿…'),
        ),
      if (collectionService != null)
        const PopupMenuItem(
          height: 36,
          value: 'collect',
          child: Text('加入收藏夹…'),
        ),
      if (removals != null)
        const PopupMenuItem(height: 36, value: 'remove', child: Text('从书库移除')),
    ],
    icon: const Icon(Icons.more_horiz),
  );

  /// 把这些书加入用户选的收藏夹（V84，LIB-120）。
  Future<void> collect(List<String> ids) async {
    final service = collectionService;
    if (service == null || ids.isEmpty) return;
    final id = await pickCollection(context, service, count: ids.length);
    if (id == null || !mounted) return;
    await joinCollection(context, service, id, ids);
  }

  Future<void> importBooks({
    List<String>? providedPaths,
    String? collection,
  }) async {
    if (picking || fileImporting || widget.library.importing.value) return;
    setState(() => picking = true);
    try {
      final paths = providedPaths ?? await widget.picker.chooseBooks();
      if (!mounted || paths.isEmpty) return;
      setState(() {
        fileImporting = true;
        picking = false;
        importCancelled = false;
      });
      final results = await importFolderSelection(
        widget.library,
        paths,
        cancelled: () => !mounted || importCancelled,
        skipExisting: false,
      );
      if (!mounted) return;
      final failed = results.where((r) => !r.succeeded).toList();
      final count = results.length - failed.length;
      final retained = results.where((r) => r.skipped).toList();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            importCancelled
                ? '导入已停止，已导入 $count 本书稿'
                : failed.isEmpty
                ? retained.isEmpty
                      ? '已导入 $count 本书稿'
                      : '新增 ${count - retained.length} 本，保留 ${retained.length} 本。${retained.first.message}'
                : '已导入 $count 本；${failed.first.message}',
          ),
        ),
      );
      if (collection != null) await joinImported(collection, results);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入未完成：$error')));
      }
    } finally {
      if (mounted) {
        setState(() {
          picking = false;
          fileImporting = false;
        });
      }
    }
  }

  bool dragging = false;

  /// 外部文件拖到了哪个收藏夹行上（按行的屏幕位置判断）。
  String? collectionAt(Offset global) {
    for (final entry in collectionKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final local = box.globalToLocal(global);
      if (box.paintBounds.contains(local)) return entry.key;
    }
    return null;
  }

  Future<void> importDrop(DropDoneDetails details) async {
    final collection =
        collectionAt(details.globalPosition) ?? currentCollection;
    setState(() {
      dragging = false;
      fileHoverCollection = null;
    });
    if (picking || fileImporting || widget.library.importing.value) return;
    final files = <String>[];
    for (final file in details.files) {
      if (await Directory(file.path).exists()) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => FolderImportDialog(
            library: widget.library,
            picker: widget.picker,
            initialPath: file.path,
            initialCollection: collection,
          ),
        );
      } else {
        files.add(file.path);
      }
    }
    if (mounted && files.isNotEmpty) {
      await importBooks(providedPaths: files, collection: collection);
    }
  }

  // ---------------------------------------------------------------- 视图（V6 起，设计 D4-A）

  @override
  Widget build(BuildContext context) => DeskSearchScope(
    focusNode: searchFocus,
    child: DropTarget(
      onDragEntered: (_) {
        if (!picking && !fileImporting && !widget.library.importing.value) {
          setState(() => dragging = true);
        }
      },
      onDragUpdated: (details) {
        final hover = collectionAt(details.globalPosition);
        if (hover != fileHoverCollection) {
          setState(() => fileHoverCollection = hover);
        }
      },
      onDragExited: (_) => setState(() {
        dragging = false;
        fileHoverCollection = null;
      }),
      onDragDone: importDrop,
      child: Stack(
        fit: StackFit.expand,
        children: [
          libraryContent(context),
          if (dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Builder(
                  builder: (context) {
                    final d = context.desk;
                    return Container(
                      margin: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: d.surface.withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: d.accent, width: 2),
                      ),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            size: 30,
                            color: d.ink2,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            switch (collectionService?.collections.value
                                .where(
                                  (c) =>
                                      c.id ==
                                      (fileHoverCollection ??
                                          currentCollection),
                                )
                                .firstOrNull) {
                              final c? => '松开以导入并加入“${c.name}”',
                              null => '松开以导入书籍或文件夹',
                            },
                            key: const ValueKey('library-drop-message'),
                            style: ui(18, w: 650, c: d.ink),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '文件直接导入；文件夹先扫描确认。原文件始终保留。'
                            '${collectionService == null ? '' : '\n拖到左侧某个收藏夹上松开，导入后加入该收藏夹。'}',
                            textAlign: TextAlign.center,
                            style: ui(12.5, c: d.ink2, h: 1.6),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    ),
  );

  void showCurrentDetails() {
    final book = widget.library.books.value
        .where((b) => b.id == currentId)
        .firstOrNull;
    if (book == null) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => DeskAlert(
        title: const Text('当前书'),
        content: SizedBox(
          width: 380,
          height: 480,
          child: BookSummaryPanel(
            library: widget.library,
            book: book,
            onReveal: widget.onRevealSource,
            outputs: widget.outputs,
            onRevealOutput: widget.onRevealOutput,
            onOutputHistory: widget.onOutputHistory == null
                ? null
                : () {
                    Navigator.pop(dialogContext);
                    widget.onOutputHistory!();
                  },
            open: (page) {
              Navigator.pop(dialogContext);
              bookAction(book, page);
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget header(
    bool importing, {
    required bool wide,
    List<BookSummary> books = const [],
  }) {
    final d = context.desk;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Text('书库', style: ui(16, w: 650, c: d.ink)),
          if (books.isNotEmpty) ...[
            const SizedBox(width: 8),
            Builder(
              builder: (context) {
                final shown = filtered(books).length;
                return Text(
                  shown == books.length
                      ? '${books.length} 本'
                      : '$shown / ${books.length} 本',
                  key: const ValueKey('library-count'),
                  style: ui(13, w: 600, c: d.ink2),
                );
              },
            ),
          ],
          // 文件夹自动入库（V26，FOLD-081/082）：新增与原稿缺失的小角标，没有时不占位置。
          if (widget.library case final FolderAutoImportService auto)
            ValueListenableBuilder<AutoImportState>(
              valueListenable: auto.autoImportState,
              builder: (_, state, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.added.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _AutoImportBadge(
                      key: const ValueKey('library-auto-import-added'),
                      icon: Icons.sync_rounded,
                      text: '新增 ${state.added.length}',
                      tooltip: [
                        '自动入库导入了：',
                        ...state.added.take(10),
                        if (state.added.length > 10)
                          '…共 ${state.added.length} 本',
                        '点击收起',
                      ].join('\n'),
                      onTap: auto.acknowledgeAutoImport,
                    ),
                  ],
                  if (state.missing.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _AutoImportBadge(
                      key: const ValueKey('library-auto-import-missing'),
                      icon: Icons.report_gmailerrorred_rounded,
                      text: '原稿缺失 ${state.missing.length}',
                      warn: true,
                      tooltip: [
                        '自动入库文件夹里找不到这些书的原稿（书仍在书库）：',
                        ...books
                            .where((b) => state.missing.contains(b.id))
                            .take(10)
                            .map((b) => b.title),
                      ].join('\n'),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              selected.isEmpty
                  ? '点击书名查看 · 勾选后批量操作'
                  : '在勾选列拖动可连选，拖动行可框选；Ctrl / Shift 点击多选',
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: d.ink3),
            ),
          ),
          // 已有右侧详情栏时不再重复这个入口（LIB-108）。
          if (!widget.showConversionActions && currentId != null && !wide)
            DeskButton(
              '当前书详情',
              icon: Icons.info_outline_rounded,
              quiet: true,
              onPressed: currentId == null ? null : showCurrentDetails,
            ),
          if ((removals?.removedBatchCount.value ?? 0) > 0)
            DeskButton(
              '撤销移除',
              icon: Icons.restore_rounded,
              quiet: true,
              onPressed: restoreBooks,
            ),
          DeskCommandMenu<String>(
            tooltip: '更多导入方式',
            enabled: !importing && !picking,
            onSelected: (kind) {
              if (kind == 'files') {
                importBooks();
              } else {
                importFolder(favorite: kind == 'favorites');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(height: 36, value: 'files', child: Text('导入文件')),
              PopupMenuItem(height: 36, value: 'folder', child: Text('导入文件夹')),
              PopupMenuItem(
                height: 36,
                value: 'favorites',
                child: Text('从收藏文件夹导入'),
              ),
            ],
            icon: Icon(Icons.expand_more_rounded, color: d.ink2),
          ),
          const SizedBox(width: 4),
          DeskButton(
            importing ? '取消导入' : '导入',
            icon: importing ? Icons.close_rounded : Icons.file_open_outlined,
            primary: true,
            onPressed: importing
                ? cancelImport
                : picking
                ? null
                : importBooks,
          ),
        ],
      ),
    );
  }

  /// 当前搜索与筛选下可见的书。
  List<BookSummary> filtered(List<BookSummary> books) => sortBooks(
    books
        .where(
          (b) => inLibraryScope(
            b,
            scope,
            collectionService?.collections.value ?? const [],
          ),
        )
        .where((b) => format == '全部格式' || b.format == format)
        .where(
          (b) => switch (filter) {
            '待处理' => b.status != '检查通过',
            '检查通过' => b.status == '检查通过',
            _ => true,
          },
        )
        .where((b) => !onlySelected || selected.contains(b.id))
        .where(
          (b) =>
              query.isEmpty ||
              '${b.title}\n${b.author}\n${b.path}\n${b.category}\n${b.series}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList(),
  );

  /// 排序方式（V84，LIB-127）；“默认顺序”为导入顺序（新导入的在前）。
  static const sortLabels = <String, String>{
    'default': '默认顺序（最近导入在前）',
    'title': '书名',
    'author': '作者',
    'category': '类别',
    'series': '系列',
    'format': '格式',
    'size': '大小',
    'status': '待处理多少',
  };

  List<BookSummary> sortBooks(List<BookSummary> books) {
    if (sort == 'default') return descending ? books.reversed.toList() : books;
    int text(String a, String b) {
      // 空值排在最后，不论升降序。
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    }

    final order = {for (var i = 0; i < books.length; i++) books[i].id: i};
    int compare(BookSummary a, BookSummary b) => switch (sort) {
      'title' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      'author' => a.author.toLowerCase().compareTo(b.author.toLowerCase()),
      'category' => a.category.toLowerCase().compareTo(
        b.category.toLowerCase(),
      ),
      'series' => a.series.toLowerCase().compareTo(b.series.toLowerCase()),
      'format' => a.format.compareTo(b.format),
      'size' => (a.bytes ?? -1).compareTo(b.bytes ?? -1),
      'status' => chapterIssueCount(a).compareTo(chapterIssueCount(b)),
      _ => 0,
    };
    final emptyLast = switch (sort) {
      'author' || 'category' || 'series' => true,
      _ => false,
    };
    String field(BookSummary b) => switch (sort) {
      'author' => b.author,
      'category' => b.category,
      _ => b.series,
    };
    return List.of(books)..sort((a, b) {
      if (emptyLast) {
        final blank = text(field(a), field(b));
        if (field(a).isEmpty != field(b).isEmpty) return blank;
      }
      final value = descending ? compare(b, a) : compare(a, b);
      return value != 0 ? value : order[a.id]!.compareTo(order[b.id]!);
    });
  }

  void changeSort(String value) {
    setState(() {
      if (value == sort) {
        descending = !descending;
      } else {
        sort = value;
        descending = value == 'size' || value == 'status';
      }
    });
    rememberView();
  }

  /// 筛选行高度：与详情栏顶部“当前书”一行相同，两栏封面顶端因此对齐（LIB-105）。
  double filterRowHeight(BuildContext context) =>
      40 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);

  Widget filters([List<BookSummary> visible = const []]) => LayoutBuilder(
    builder: (context, bounds) => _filters(bounds.maxWidth, visible),
  );

  Widget _filters(double width, List<BookSummary> visible) {
    final d = context.desk;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    final allVisible =
        visible.isNotEmpty && visible.every((b) => selected.contains(b.id));
    // 搜索框在放得下时为 300 宽；放不下时先缩短搜索框，让控件留在同一行（LIB-105 两栏封面对齐）。
    // 完整一行约需：搜索 200 + 格式、状态、仅看已勾选 + 全选、排序、视图（+ 左栏开关）。
    // 再窄时（V84b）格式、状态、仅看已勾选与显示范围收进一个“筛选”菜单。
    final railToggle = railAvailable ? 46 : 0;
    final full = 464 + railToggle + (scopeChoice ? 150 : 0);
    final compactFilters = width - 46 < (200 + full) * scale;
    filtersCompact = compactFilters;
    final search = SizedBox(
      width:
          (width - 40 - 6 - (compactFilters ? 184 + railToggle : full) * scale)
              .clamp(compactFilters ? 140.0 : 200.0, 300.0),
      height: filterRowHeight(context),
      child: TextField(
        controller: searchInput,
        focusNode: searchFocus,
        style: ui(13, c: d.ink),
        decoration: deskInput(context, hint: '搜索书名、作者或文件名').copyWith(
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: d.ink3),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
        ),
        onChanged: (v) => changeFilter(search: v),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          search,
          if (compactFilters) filterMenu(),
          if (!compactFilters)
            Tooltip(
              message: '筛选文件格式',
              child: DeskFilter<String>(
                value: format,
                onChanged: (value) => changeFilter(sourceFormat: value),
                onClear: format == '全部格式'
                    ? null
                    : () => changeFilter(sourceFormat: '全部格式'),
                items: [
                  for (final value in ['全部格式', 'TXT', 'EPUB'])
                    DropdownMenuItem(value: value, child: Text(value)),
                ],
              ),
            ),
          if (!compactFilters)
            Tooltip(
              message: '筛选书稿',
              child: DeskFilter<String>(
                value: filter,
                onChanged: (value) => changeFilter(category: value),
                onClear: filter == '全部书稿'
                    ? null
                    : () => changeFilter(category: '全部书稿'),
                items: [
                  // 值沿用“全部书稿”（视图状态里存的是它），显示为“全部状态”，与左栏的“全部书稿”区分。
                  for (final value in ['全部书稿', '待处理', '检查通过'])
                    DropdownMenuItem(
                      value: value,
                      child: Text(value == '全部书稿' ? '全部状态' : value),
                    ),
                ],
              ),
            ),
          if (!compactFilters)
            FilterChip(
              label: const Text('仅看已勾选'),
              selected: onlySelected,
              onSelected: (value) => changeFilter(checkedOnly: value),
            ),
          // 全选当前筛选结果（原在书架上方单独一行，移到这里后两栏封面顶端对齐）。
          IconButton(
            key: const ValueKey('library-select-visible'),
            tooltip: allVisible ? '取消筛选结果勾选' : '全选筛选结果',
            onPressed: visible.isEmpty
                ? null
                : () => checkMany(visible.map((b) => b.id), !allVisible),
            icon: Icon(
              allVisible ? Icons.deselect_rounded : Icons.select_all_rounded,
              color: d.ink2,
            ),
          ),
          if (scopeChoice && !compactFilters)
            Tooltip(
              message: '显示范围：全部、收藏夹或类别',
              child: DeskFilter<String>(
                key: const ValueKey('library-scope-filter'),
                value: scope,
                onChanged: (value) => changeFilter(libraryScope: value ?? ''),
                onClear: scope.isEmpty
                    ? null
                    : () => changeFilter(libraryScope: ''),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部书稿')),
                  for (final c in collectionService!.collections.value)
                    DropdownMenuItem(
                      value: collectionScope(c.id),
                      child: Text('收藏夹 · ${c.name}'),
                    ),
                  for (final (name, _) in libraryCategories(
                    widget.library.books.value,
                  ))
                    DropdownMenuItem(
                      value: categoryScope(name),
                      child: Text(name.isEmpty ? '未分类' : '类别 · $name'),
                    ),
                ],
              ),
            ),
          DeskCommandMenu<String>(
            key: const ValueKey('library-sort'),
            tooltip:
                '排序：${sortLabels[sort]}${sort == 'default' && !descending
                    ? ''
                    : descending
                    ? '，降序'
                    : '，升序'}',
            onSelected: changeSort,
            itemBuilder: (_) => [
              for (final e in sortLabels.entries)
                PopupMenuItem(
                  height: 36,
                  value: e.key,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: e.key == sort
                            ? Icon(
                                descending
                                    ? Icons.arrow_downward_rounded
                                    : Icons.arrow_upward_rounded,
                                size: 15,
                              )
                            : null,
                      ),
                      Text(e.value),
                    ],
                  ),
                ),
            ],
            icon: Icon(
              Icons.sort_rounded,
              color: sort == 'default' && !descending ? d.ink2 : d.ink,
            ),
          ),
          IconButton(
            key: const ValueKey('library-view-toggle'),
            tooltip: compact ? '切换书架视图' : '切换列表视图',
            onPressed: changeView,
            icon: Icon(
              compact ? Icons.grid_view_rounded : Icons.view_list_outlined,
              color: d.ink2,
            ),
          ),
          if (railAvailable)
            IconButton(
              key: const ValueKey('library-rail-toggle'),
              tooltip: !railCanExpand
                  ? '窗口较窄，收藏夹栏只显示图标'
                  : railCollapsedNow
                  ? '展开收藏夹与类别栏（也可拖动左栏边缘）'
                  : '收成图标条（也可拖动左栏边缘）',
              isSelected: !railCollapsedNow,
              onPressed: railCanExpand
                  ? () => setRail(collapsed: !railCollapsed)
                  : null,
              icon: Icon(
                railCollapsedNow
                    ? Icons.view_sidebar_outlined
                    : Icons.view_sidebar_rounded,
                color: d.ink2,
              ),
            ),
        ],
      ),
    );
  }

  /// 窄时的“筛选”菜单（V84b）：格式、状态、仅看已勾选；没有左栏时还有显示范围。
  Widget filterMenu() {
    final d = context.desk;
    final active = [
      if (format != '全部格式') format,
      if (filter != '全部书稿') filter,
      if (onlySelected) '仅看已勾选',
      if (scope.isNotEmpty && !railListsScope)
        scopeLabel(scope, collectionService?.collections.value ?? const []),
    ];
    PopupMenuEntry<String> heading(String text) => PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(text, style: ui(11.5, w: 650, c: d.ink3)),
    );
    PopupMenuEntry<String> option(String value, String label, bool on) =>
        CheckedPopupMenuItem<String>(
          height: 36,
          value: value,
          checked: on,
          child: Text(label),
        );
    return DeskCommandMenu<String>(
      key: const ValueKey('library-filter-menu'),
      tooltip: active.isEmpty ? '筛选' : '筛选：${active.join('、')}',
      onSelected: (value) {
        final (kind, rest) = (
          value.substring(0, value.indexOf(':')),
          value.substring(value.indexOf(':') + 1),
        );
        switch (kind) {
          case 'format':
            changeFilter(sourceFormat: rest);
          case 'status':
            changeFilter(category: rest);
          case 'checked':
            changeFilter(checkedOnly: !onlySelected);
          case 'scope':
            changeFilter(libraryScope: rest);
        }
      },
      itemBuilder: (_) => [
        heading('格式'),
        for (final v in ['全部格式', 'TXT', 'EPUB'])
          option('format:$v', v, format == v),
        const PopupMenuDivider(),
        heading('状态'),
        for (final v in ['全部书稿', '待处理', '检查通过'])
          option('status:$v', v == '全部书稿' ? '全部状态' : v, filter == v),
        const PopupMenuDivider(),
        option('checked:', '仅看已勾选', onlySelected),
        if (collectionService != null && !railListsScope) ...[
          const PopupMenuDivider(),
          heading('显示范围'),
          option('scope:', '全部书稿', scope.isEmpty),
          for (final c in collectionService!.collections.value)
            option(
              'scope:${collectionScope(c.id)}',
              '收藏夹 · ${c.name}',
              scope == collectionScope(c.id),
            ),
          for (final (name, _) in libraryCategories(widget.library.books.value))
            option(
              'scope:${categoryScope(name)}',
              name.isEmpty ? '未分类' : '类别 · $name',
              scope == categoryScope(name),
            ),
        ],
      ],
      icon: Badge(
        isLabelVisible: active.isNotEmpty,
        smallSize: 7,
        backgroundColor: d.ink,
        child: Icon(
          Icons.filter_list_rounded,
          color: active.isEmpty ? d.ink2 : d.ink,
        ),
      ),
    );
  }

  /// 勾选工具条：全选 / 清空 / 检查所选 / 应用到多本书 / 移除所选；有勾选时浅灰墨底。
  /// 有勾选，或有批量检查的进度与结果时显示批量操作条。
  bool get selectionBarShown {
    final checks = batchChecks;
    return selected.isNotEmpty ||
        (checks != null &&
            (checks.checkBatch.running || checks.checkBatch.total > 0));
  }

  Widget selectionBar(
    List<BookSummary> visible,
    BookSummary current,
    bool importing,
  ) {
    final d = context.desk;
    final checks = batchChecks;
    // 没有勾选、也没有批量检查记录时不显示。
    if (!selectionBarShown) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('library-selection-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          selected.isEmpty ? Colors.transparent : d.accentSoft,
          d.paper,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
        boxShadow: d.shadow2,
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (selected.isNotEmpty)
            Text(
              '已勾选 ${selected.length} 本 · 筛选外 ${selected.difference(visible.map((b) => b.id).toSet()).length} 本',
              style: ui(12, w: 600, c: d.ink),
            ),
          if (selected.isNotEmpty)
            DeskButton(
              '清空勾选',
              quiet: true,
              onPressed: selected.isEmpty
                  ? null
                  : () => checkMany(selected, false),
            ),
          if (checks != null) ...[
            if (selected.isNotEmpty)
              DeskButton(
                '检查所选',
                icon: Icons.fact_check_outlined,
                quiet: true,
                onPressed:
                    selected.isEmpty || importing || checks.checkBatch.running
                    ? null
                    : inspectSelected,
              ),
            if (checks.checkBatch.running)
              DeskButton(
                checks.checkBatch.stopping ? '正在停止' : '当前书完成后停止',
                quiet: true,
                onPressed: checks.checkBatch.stopping
                    ? null
                    : checks.checkBatch.stop,
              ),
            if (checks.checkBatch.total > 0)
              DeskButton(
                '${checks.checkBatch.running
                    ? '检查中 '
                    : checks.checkBatch.cancelled
                    ? '已停止 '
                    : '检查完成 '}${checks.checkBatch.results.length}/${checks.checkBatch.total}',
                quiet: true,
                onPressed: showCheckResults,
              ),
          ],
          if (selected.isNotEmpty)
            DeskButton(
              '应用到多本书',
              icon: Icons.library_add_check_outlined,
              quiet: true,
              onPressed: selected.isEmpty || importing || picking
                  ? null
                  : () => showDialog<bool>(
                      context: context,
                      builder: (_) => BookBatchDialog(
                        library: widget.library,
                        bookId: current.id,
                      ),
                    ),
            ),
          if (collectionService != null && selected.isNotEmpty) ...[
            DeskButton(
              '加入收藏夹…',
              key: const ValueKey('library-collect-selected'),
              icon: Icons.bookmark_add_outlined,
              quiet: true,
              tooltip: '也可以把勾选的书直接拖到左侧收藏夹',
              onPressed: importing ? null : () => collect(selected.toList()),
            ),
            DeskButton(
              '设类别…',
              key: const ValueKey('library-set-category'),
              icon: Icons.label_outline_rounded,
              quiet: true,
              onPressed: importing
                  ? null
                  : () => setCategory(
                      context,
                      collectionService!,
                      selected.toList(),
                    ),
            ),
            if (currentCollection != null)
              DeskButton(
                '移出此收藏夹',
                key: const ValueKey('library-uncollect-selected'),
                icon: Icons.bookmark_remove_outlined,
                quiet: true,
                onPressed: () {
                  try {
                    collectionService!.removeFromCollection(
                      currentCollection!,
                      selected,
                    );
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(deskErrorText(e, '未能移出。'))),
                    );
                  }
                },
              ),
          ],
          if (removals != null && selected.isNotEmpty)
            DeskButton(
              '移除所选',
              icon: Icons.remove_circle_outline_rounded,
              quiet: true,
              onPressed: selected.isEmpty
                  ? null
                  : () => remove(Set.of(selected)),
            ),
        ],
      ),
    );
  }

  static String formatBytes(int? bytes) => bytes == null
      ? '—'
      : bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';

  /// 左栏（收藏夹与类别，V84b）：书库区域宽 ≥520 就有；可拖右边缘伸缩（150–320），
  /// 拖到最窄或点开关收成 48 宽的图标条；书库区域不足 700 时只显示图标条。
  bool railShown = false, railAvailable = false;
  bool railCollapsed = false, railCanExpand = true;
  double railWidthValue = 184;
  bool get railCollapsedNow => railCollapsed || !railCanExpand;

  /// 左栏是否列出了类别与收藏夹（展开时）；图标条只有收藏夹，类别要用显示范围。
  bool get railListsScope => railShown && !railCollapsedNow;

  void setRail({bool? collapsed, double? width}) {
    setState(() {
      if (collapsed != null) railCollapsed = collapsed;
      if (width != null) railWidthValue = width;
    });
    rememberView();
  }

  /// 筛选行是否收成“筛选”菜单（由筛选行按宽度决定）。
  bool filtersCompact = false;

  /// 左栏不展开且有收藏夹或类别时，筛选行显示“显示范围”下拉（筛选收成菜单时放进菜单）。
  bool get scopeChoice =>
      collectionService != null &&
      !railListsScope &&
      (collectionService!.collections.value.isNotEmpty ||
          scope.isNotEmpty ||
          widget.library.books.value.any((b) => b.category.isNotEmpty));

  /// 拖动已勾选的书（V84，LIB-121）：按在已勾选的书上拖动时带上全部勾选的书。
  Widget bookDrag(BookSummary b, bool checked, Widget child) {
    if (collectionService == null) return child;
    final d = context.desk;
    final ids = checked ? selected.toList() : [b.id];
    return Draggable<LibraryBookDrag>(
      data: LibraryBookDrag(ids),
      maxSimultaneousDrags: checked ? 1 : 0,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: d.surface,
        elevation: 0,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: d.lineStrong),
            boxShadow: d.shadow2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark_add_outlined, size: 16, color: d.ink2),
              const SizedBox(width: 8),
              Text(
                ids.length == 1 ? b.title : '${ids.length} 本书',
                style: ui(12.5, w: 600, c: d.ink),
              ),
              const SizedBox(width: 8),
              Text('拖到左侧收藏夹', style: ui(11.5, c: d.ink3)),
            ],
          ),
        ),
      ),
      child: child,
    );
  }

  /// 列宽与表头共用（LIB-098）。
  static const _checkWidth = 40.0, _formatWidth = 56.0, _sizeWidth = 76.0;
  static const _statusWidth = 128.0, _menuWidth = 40.0;
  static bool _wide(double width) => width >= 620;

  /// 浅色表头：与行内各列对齐。
  Widget columnHeader() {
    final d = context.desk;
    final style = ui(11.5, w: 600, c: d.ink3);
    return Padding(
      key: const ValueKey('library-column-header'),
      padding: const EdgeInsets.fromLTRB(16 + 10, 2, 14 + 10, 4),
      child: LayoutBuilder(
        builder: (context, bounds) => Row(
          children: [
            const SizedBox(width: _checkWidth + 6),
            const SizedBox(width: 48 + 12),
            Expanded(child: Text('书名', style: style)),
            if (_wide(bounds.maxWidth)) ...[
              SizedBox(
                width: _formatWidth,
                child: Text('格式', style: style),
              ),
              SizedBox(
                width: _sizeWidth,
                child: Text('大小', style: style),
              ),
            ],
            SizedBox(
              width: _statusWidth,
              child: Text('状态', style: style),
            ),
            const SizedBox(width: _menuWidth),
          ],
        ),
      ),
    );
  }

  /// 状态列（LIB-099）：需要处理时小圆点 + 短词，处理完浅灰；数量取自检查报告。
  Widget statusCell(BookSummary b) {
    final d = context.desk;
    // 只算章节问题（LIB-106）；清理建议与书籍信息写在悬停提示里。转换页共用同一说法。
    final label = bookStatusLabel(b);
    final text = label.text;
    final Color? dot = label.attention ? d.warn : null;
    final color = label.attention
        ? d.ink
        : label.active
        ? d.ink2
        : d.ink3;
    return Tooltip(
      message: bookStatusTip(b),
      child: Row(
        key: ValueKey('library-status-${b.id}'),
        children: [
          if (dot != null) ...[Dot(dot, size: 6), const SizedBox(width: 6)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: color),
            ),
          ),
        ],
      ),
    );
  }

  /// 书架视图（LIB-101，默认）：按宽度排成固定列，几何信息同时用于拖动框选。
  Widget shelf(List<BookSummary> visible, BookSummary current) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      const pad = 20.0, gap = 18.0, minTile = 150.0, inner = 6.0;
      final columns = ((box.maxWidth - 2 * pad + gap) / (minTile + gap))
          .floor()
          .clamp(1, 12);
      final tile = (box.maxWidth - 2 * pad - gap * (columns - 1)) / columns;
      final tileHeight = (tile - 2 * inner) * 4 / 3 + 2 * inner + 60 * scale;
      _columns = columns;
      _extent = tileHeight + gap;
      Rect rectOf(int i) => Rect.fromLTWH(
        pad + (i % columns) * (tile + gap),
        8 + (i ~/ columns) * (tileHeight + gap),
        tile,
        tileHeight,
      );
      return DragSelectRegion(
        key: const ValueKey('library-drag-select'),
        scroll: scroll,
        itemExtent: _extent,
        ids: [for (final b in visible) b.id],
        isChecked: selected.contains,
        hitTiles: (rect) => {
          for (var i = 0; i < visible.length; i++)
            if (rectOf(i).overlaps(rect)) i,
        },
        passThrough: collectionService == null
            ? null
            : (at, _) {
                for (var i = 0; i < visible.length; i++) {
                  if (rectOf(i).contains(at)) {
                    return selected.contains(visible[i].id);
                  }
                }
                return false;
              },
        apply: (check, uncheck) {
          if (check.isNotEmpty) checkMany(check, true);
          if (uncheck.isNotEmpty) checkMany(uncheck, false);
        },
        onSelectAll: () => checkMany(visible.map((b) => b.id), true),
        onClear: () => checkMany(selected, false),
        child: GridView.builder(
          key: const ValueKey('library-shelf'),
          controller: scroll,
          padding: EdgeInsets.fromLTRB(
            pad,
            8,
            pad,
            selectionBarShown ? 76 : 20,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: gap,
            mainAxisExtent: tileHeight,
          ),
          itemCount: visible.length,
          itemBuilder: (context, i) =>
              bookTile(visible, visible[i], current, tile - 2 * inner),
        ),
      );
    },
  );

  /// 书架上的一本书：大封面，书名与作者 · 章数；待处理数量为封面角标，
  /// 勾选框在悬停、已勾选或正在多选时浮在封面左上角。
  Widget bookTile(
    List<BookSummary> visible,
    BookSummary b,
    BookSummary current,
    double coverWidth,
  ) {
    final d = context.desk;
    final on = b.id == current.id;
    final checked = selected.contains(b.id);
    final pending = chapterIssueCount(b);
    return Material(
      key: ValueKey('library-row-${b.id}'),
      type: MaterialType.transparency,
      child: _Hover(
        builder: (hovering) => bookDrag(
          b,
          checked,
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              final keys = HardwareKeyboard.instance;
              if (keys.isControlPressed) {
                checkRow(visible, b.id, !checked);
              } else if (keys.isShiftPressed && rangeAnchor != null) {
                checkRow(visible, b.id, true);
              } else {
                widget.library.selectBook(b.id);
              }
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: checked
                    ? d.accentSoft
                    : on
                    ? d.surface
                    : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          boxShadow: hovering || on ? d.shadow2 : d.shadow1,
                          border: on
                              ? Border.all(color: d.accent, width: 2)
                              : null,
                        ),
                        child: LibraryCover(b, width: coverWidth),
                      ),
                      if (bookNeedsAttention(b))
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Tooltip(
                            message: [
                              b.status,
                              if (b.pending != null && b.pending!.total > 0)
                                b.pending!.breakdown,
                            ].join('\n'),
                            child: Container(
                              key: ValueKey('library-badge-${b.id}'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: d.surface,
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(color: d.line),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Dot(d.warn, size: 6),
                                  if (pending > 0) ...[
                                    const SizedBox(width: 4),
                                    Text('$pending', style: mono(11, c: d.ink)),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (hovering || checked || selected.isNotEmpty)
                        Positioned(
                          top: 2,
                          left: 2,
                          child: Container(
                            decoration: BoxDecoration(
                              color: d.surface.withValues(alpha: .92),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Checkbox(
                              key: ValueKey('library-check-${b.id}'),
                              value: checked,
                              visualDensity: VisualDensity.compact,
                              onChanged: (v) =>
                                  checkRow(visible, b.id, v == true),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: b.title,
                          child: Text(
                            b.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(13, w: on ? 650 : 600, c: d.ink),
                          ),
                        ),
                      ),
                      // “…”与列表行同一菜单；悬停、选中或勾选时显示。
                      SizedBox(
                        width: 30,
                        height: 28,
                        child: AnimatedOpacity(
                          duration: DeskMotion.of(context, DeskMotion.fast),
                          curve: DeskMotion.easeOut,
                          opacity: hovering || on || checked ? 1 : 0,
                          child: FittedBox(child: bookMenu(b)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  BookStructureCounts(
                    library: widget.library,
                    book: b,
                    compact: true,
                    prefix: b.author.isEmpty ? '' : '${b.author} · ',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget bookRow(
    List<BookSummary> visible,
    BookSummary b,
    BookSummary current,
  ) {
    final d = context.desk;
    final on = b.id == current.id;
    final checked = selected.contains(b.id);
    return Material(
      key: ValueKey('library-row-${b.id}'),
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: _Hover(
          builder: (hovering) => InkWell(
            borderRadius: BorderRadius.circular(8),
            // Ctrl+点击：单独加选或取消；Shift+点击：从上次勾选处连续勾选（LIB-096）。
            onTap: () {
              final keys = HardwareKeyboard.instance;
              if (keys.isControlPressed) {
                checkRow(visible, b.id, !checked);
              } else if (keys.isShiftPressed && rangeAnchor != null) {
                checkRow(visible, b.id, true);
              } else {
                widget.library.selectBook(b.id);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: on
                    ? d.surface
                    : checked
                    ? d.accentSoft
                    : null,
                borderRadius: BorderRadius.circular(8),
                boxShadow: on ? d.shadow1 : null,
                border: Border(
                  left: BorderSide(
                    width: 2.5,
                    color: on ? d.accent : Colors.transparent,
                  ),
                ),
              ),
              child: LayoutBuilder(
                builder: (context, bounds) => Row(
                  children: [
                    SizedBox(
                      width: _checkWidth,
                      child: Checkbox(
                        value: checked,
                        key: ValueKey('library-check-${b.id}'),
                        onChanged: (v) => checkRow(visible, b.id, v == true),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: bookDrag(
                        b,
                        checked,
                        Row(
                          children: [
                            LibraryCover(b, width: 48),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Tooltip(
                                          message: b.title,
                                          child: Text(
                                            b.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: ui(13.5, w: 600, c: d.ink),
                                          ),
                                        ),
                                      ),
                                      if (on) ...[
                                        const SizedBox(width: 6),
                                        const DeskTag('当前', Tone.accent),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  BookStructureCounts(
                                    library: widget.library,
                                    book: b,
                                    compact: true,
                                    prefix: b.author.isEmpty
                                        ? ''
                                        : '${b.author} · ',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 宽行显示格式与原文件大小列（大小来自原文件属性，读不到显示“—”）。
                    if (_wide(bounds.maxWidth)) ...[
                      SizedBox(
                        width: _formatWidth,
                        child: Text(b.format, style: ui(12, c: d.ink2)),
                      ),
                      SizedBox(
                        width: _sizeWidth,
                        child: Text(
                          formatBytes(b.bytes),
                          style: mono(11, c: d.ink3),
                        ),
                      ),
                    ],
                    SizedBox(width: _statusWidth, child: statusCell(b)),
                    // “…”只在悬停、选中或勾选时出现；隐藏时仍可用键盘与读屏访问。
                    SizedBox(
                      width: _menuWidth,
                      child: AnimatedOpacity(
                        duration: DeskMotion.of(context, DeskMotion.fast),
                        curve: DeskMotion.easeOut,
                        opacity: hovering || on || checked ? 1 : 0,
                        child: bookMenu(b),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget emptyLibrary(bool importing) {
    final d = context.desk;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_stories_outlined, size: 48, color: d.ink3),
          const SizedBox(height: 18),
          Text('把第一本书放进书库', style: serif(22, w: 650, c: d.ink)),
          const SizedBox(height: 8),
          Text('选择 TXT、EPUB，或导入一个文件夹。原文件始终保留。', style: ui(13, c: d.ink2)),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            children: [
              DeskButton(
                '选择文件',
                primary: true,
                onPressed: importing || picking ? null : importBooks,
              ),
              DeskButton(
                '导入文件夹',
                onPressed: importing || picking ? null : () => importFolder(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget libraryContent(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.library.importing,
    builder: (context, backendImporting, _) {
      final d = context.desk;
      final importing = backendImporting || fileImporting;
      return Material(
        color: d.canvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: d.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, frame) {
            // 够宽时右侧有当前书详情栏（LIB-105）：标题行横跨整页，标题分隔线以下
            // 分成书架与详情两栏，详情从分隔线贯通到底。
            // 左栏优先于详情栏（V84b）：书库区域宽 ≥700 就有左栏（可收起）；
            // 扣掉左栏后仍 ≥820 才放详情栏，书架至少留约 530，筛选放不下一行时收成菜单。
            // 书库为空时只有导入引导，不出左栏和开关。
            railAvailable =
                collectionService != null &&
                frame.maxWidth >= 520 &&
                widget.library.books.value.isNotEmpty;
            railShown = railAvailable;
            railCanExpand = frame.maxWidth >= 700;
            // 展开时书架至少留约 420。
            final railMax = (frame.maxWidth - 420).clamp(
              ResizableRail.minWidth,
              ResizableRail.maxRailWidth,
            );
            final railSpace = !railShown
                ? 0.0
                : (railCollapsedNow
                          ? ResizableRail.stripWidth
                          : railWidthValue.clamp(
                              ResizableRail.minWidth,
                              railMax,
                            )) +
                      ResizableRail.handleWidth;
            final rest = frame.maxWidth - railSpace;
            final wide = rest >= 820;
            final detailWidth = rest >= 1060 ? 320.0 : 290.0;
            Widget withFilters(
              Widget body, [
              List<BookSummary> visible = const [],
            ]) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                filters(visible),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: undoBanner(),
                ),
                Expanded(child: body),
              ],
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ValueListenableBuilder<List<BookSummary>>(
                  valueListenable: widget.library.books,
                  builder: (context, books, _) =>
                      header(importing, wide: wide, books: books),
                ),
                Expanded(
                  child: ValueListenableBuilder<List<BookSummary>>(
                    valueListenable: widget.library.books,
                    builder: (context, books, _) {
                      if (books.isEmpty) {
                        return withFilters(emptyLibrary(importing));
                      }
                      final visible = filtered(books);
                      _visible = visible;
                      if (compact) {
                        _extent = rowExtent(context);
                        _columns = 1;
                      }
                      restoreView();
                      final current =
                          books.where((b) => b.id == currentId).firstOrNull ??
                          books.first;
                      final list = Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (visible.isNotEmpty && compact) columnHeader(),
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: visible.isEmpty
                                      ? Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                '没有匹配的书稿',
                                                style: ui(13, c: d.ink2),
                                              ),
                                              const SizedBox(height: 12),
                                              DeskButton(
                                                '清除搜索和筛选',
                                                onPressed: () {
                                                  searchInput.clear();
                                                  changeFilter(
                                                    search: '',
                                                    category: '全部书稿',
                                                    sourceFormat: '全部格式',
                                                    checkedOnly: false,
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        )
                                      : !compact
                                      ? shelf(visible, current)
                                      : DragSelectRegion(
                                          key: const ValueKey(
                                            'library-drag-select',
                                          ),
                                          scroll: scroll,
                                          itemExtent: rowExtent(context),
                                          ids: [for (final b in visible) b.id],
                                          isChecked: selected.contains,
                                          checkColumnWidth:
                                              16 + 10 + _checkWidth + 6,
                                          passThrough: collectionService == null
                                              ? null
                                              : (at, i) =>
                                                    at.dx >
                                                        16 +
                                                            10 +
                                                            _checkWidth +
                                                            6 &&
                                                    i < visible.length &&
                                                    selected.contains(
                                                      visible[i].id,
                                                    ),
                                          apply: (check, uncheck) {
                                            if (check.isNotEmpty) {
                                              checkMany(check, true);
                                            }
                                            if (uncheck.isNotEmpty) {
                                              checkMany(uncheck, false);
                                            }
                                          },
                                          onSelectAll: () => checkMany(
                                            visible.map((b) => b.id),
                                            true,
                                          ),
                                          onClear: () =>
                                              checkMany(selected, false),
                                          child: ListView.builder(
                                            controller: scroll,
                                            padding: EdgeInsets.fromLTRB(
                                              16,
                                              0,
                                              14,
                                              selectionBarShown ? 64 : 8,
                                            ),
                                            itemExtent: rowExtent(context),
                                            itemCount: visible.length,
                                            itemBuilder: (context, i) =>
                                                bookRow(
                                                  visible,
                                                  visible[i],
                                                  current,
                                                ),
                                          ),
                                        ),
                                ),
                                // 批量操作条浮在书架底部（LIB-105）：出现时不推动书架，
                                // 拖动连选途中不会错行，书架与详情栏的封面也保持对齐。
                                Positioned(
                                  left: 20,
                                  right: 20,
                                  bottom: 12,
                                  child: selectionBar(
                                    visible,
                                    current,
                                    importing,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (railShown)
                            ResizableRail(
                              key: const ValueKey('library-rail'),
                              width: railWidthValue,
                              collapsed: railCollapsedNow,
                              maxWidth: railMax,
                              onCommit: (width, collapsed) {
                                // 窄窗口只能是图标条，不记成用户收起。
                                setRail(
                                  width: width,
                                  collapsed: railCanExpand
                                      ? collapsed
                                      : railCollapsed,
                                );
                              },
                              builder: (collapsed) => CollectionRail(
                                service: collectionService!,
                                books: books,
                                scope: scope,
                                rowKeys: collectionKeys,
                                fileHover: fileHoverCollection,
                                collapsed: collapsed,
                                onScope: (value) =>
                                    changeFilter(libraryScope: value),
                              ),
                            ),
                          // 列表滚动条与右侧详情边框留出间隙。
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: withFilters(list, visible),
                            ),
                          ),
                          if (wide)
                            Container(
                              key: const ValueKey('library-detail-column'),
                              width: detailWidth,
                              decoration: BoxDecoration(
                                border: Border(left: BorderSide(color: d.line)),
                              ),
                              // 与书架同底色，只用左侧细线分开；透明 Material 承接按钮的点按反馈。
                              // 上边距与筛选行相同，封面顶部与搜索框顶部对齐。
                              child: Material(
                                type: MaterialType.transparency,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    12,
                                    20,
                                    16,
                                  ),
                                  child: BookSummaryPanel(
                                    // 筛选行下边距 8 + 书架上边距 8 + 格子内边距 6。
                                    headingHeight: filterRowHeight(context),
                                    headingGap: 22,
                                    library: widget.library,
                                    book: current,
                                    onReveal: widget.onRevealSource,
                                    outputs: widget.outputs,
                                    onRevealOutput: widget.onRevealOutput,
                                    onOutputHistory: widget.onOutputHistory,
                                    open: (page) {
                                      widget.library.selectBook(current.id);
                                      context.go(
                                        '/books/${Uri.encodeComponent(current.id)}/$page',
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                if (widget.showConversionActions &&
                    widget.library.books.value.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                    decoration: BoxDecoration(
                      color: d.surface,
                      border: Border(top: BorderSide(color: d.line)),
                    ),
                    child: Row(
                      children: [
                        // 已有右侧详情栏时不再重复这个入口（LIB-108）。
                        if (!wide)
                          DeskButton(
                            '当前书详情',
                            icon: Icons.info_outline_rounded,
                            quiet: true,
                            onPressed: currentId == null
                                ? null
                                : showCurrentDetails,
                          ),
                        const Spacer(),
                        DeskButton(
                          '转换当前书',
                          icon: Icons.arrow_forward_rounded,
                          primary: selected.isEmpty,
                          onPressed:
                              currentId == null ||
                                  widget.conversionBusy ||
                                  widget.onConvertBook == null
                              ? null
                              : () => widget.onConvertBook!(currentId!),
                        ),
                        if (selected.isNotEmpty) const SizedBox(width: 8),
                        if (selected.isNotEmpty)
                          DeskButton(
                            '转换所选 ${selected.length} 本',
                            icon: Icons.arrow_forward_rounded,
                            primary: true,
                            onPressed: selected.isEmpty || widget.conversionBusy
                                ? null
                                : widget.onConvert,
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      );
    },
  );
}

/// 行悬停状态（“…”按钮只在悬停时显示）。
class _Hover extends StatefulWidget {
  const _Hover({required this.builder});
  final Widget Function(bool hovering) builder;
  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool hovering = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hovering = true),
    onExit: (_) => setState(() => hovering = false),
    child: widget.builder(hovering),
  );
}

/// 检查时间：今天只写时分，其余写月日。
String formatCheckTime(DateTime when) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(when.hour)}:${two(when.minute)}';
  if (when.year == now.year && when.month == now.month && when.day == now.day) {
    return '今天 $time';
  }
  return '${when.month} 月 ${when.day} 日 $time';
}

/// 书库标题行的小角标（自动入库的新增 / 原稿缺失）。
class _AutoImportBadge extends StatelessWidget {
  const _AutoImportBadge({
    super.key,
    required this.icon,
    required this.text,
    required this.tooltip,
    this.onTap,
    this.warn = false,
  });
  final IconData icon;
  final String text, tooltip;
  final VoidCallback? onTap;
  final bool warn;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final color = warn ? d.warn : d.ink2;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: warn ? d.warnSoft : d.sunken,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 4),
                Text(text, style: ui(11.5, w: 600, c: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
