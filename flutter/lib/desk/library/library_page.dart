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
import '../metadata/cover_drop.dart';
import '../tokens.dart';
import '../widgets.dart';

import 'book_summary_panel.dart';
import 'import_failures_dialog.dart';
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

part 'library_header.dart';
part 'library_filters.dart';
part 'library_folders.dart';
part 'library_selection.dart';
part 'library_shelf.dart';

/// 列宽与表头共用（LIB-098）。
const _checkWidth = 40.0, _formatWidth = 56.0, _sizeWidth = 76.0;
const _statusWidth = 128.0, _menuWidth = 40.0;
bool _wide(double width) => width >= 620;

String _formatBytes(int? bytes) => bytes == null
    ? '—'
    : bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).toStringAsFixed(1)} KB';

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
    this.pickImage,
  });
  final LibraryService library;

  /// 封面图片弹窗里“选择图片”用（拖入图片设封面时）；没有时只能用拖入的那张。
  final Future<String?> Function()? pickImage;
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
  /// part 文件里的扩展用它刷新（setState 只能在类里调用）。
  void update(VoidCallback action) => setState(action);

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
          deskSnackBar(content: Text(deskErrorText(e, '无法开始检查，请稍后重试。'))),
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

  /// 收藏夹模式（V104）：书库顶层是收藏夹文件夹，点进去看书；不在收藏夹里的书归入“未分类”。
  bool folders = false;
  String folderOrder = 'custom';
  final folderKeys = <String, GlobalKey>{};

  /// 正在拖动勾选的书：收藏夹模式里路径行据此列出可放入的收藏夹。
  bool bookDragging = false;
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

  /// 列表视图是否显示“格式、大小”两列：按整个列表的宽度统一决定，表头与各行用同一个结果
  /// （V110：以前表头和行各自按自己的宽度算，列表区域的内边距不同，宽度临界时表头有、行里没有）。
  bool _wideColumns = false;

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
    view.folders = folders;
    view.folderOrder = folderOrder;
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
    railCollapsed = view?.railCollapsed ?? true;
    railGone = railCollapsed;
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
    folders = view?.folders ?? false;
    folderOrder = view?.folderOrder ?? 'custom';
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

  /// 本次导入的文件数与开始时的书库本数（R2-01）：标题行按新加入的本数显示进度。
  int importTotal = 0, importBase = 0;
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
        deskSnackBar(
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
                  style: ui(13, c: context.desk.surface),
                ),
              ),
              TextButton(
                key: const ValueKey('library-undo-removal'),
                style: TextButton.styleFrom(
                  foregroundColor: context.desk.surface,
                ),
                onPressed: () => remove({}, undo: true, batchId: id),
                child: const Text('撤销'),
              ),
              IconButton(
                tooltip: '关闭提示',
                onPressed: () => setState(() {
                  _undoBatchId = null;
                  _undoMessage = null;
                }),
                icon: Icon(Icons.close, color: context.desk.surface, size: 18),
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
            builder: (context) => DeskAlert(
              title: const Text('恢复移除的书籍'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
              actions: [
                DeskButton(
                  '取消',
                  quiet: true,
                  onPressed: () => Navigator.pop(context),
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
            ScaffoldMessenger.of(context).showSnackBar(
              deskSnackBar(
                content: Text(
                  deskErrorText(e, '没有恢复原文件：请确认备份还在、原位置可以写入，再试一次。'),
                ),
              ),
            );
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
            deskSnackBar(
              content: Text(
                deskErrorText(error, '找不到原文件：它可能已被移动或删除，可以在书的菜单里用“刷新来源”重新指定。'),
              ),
            ),
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
        importTotal = paths.length;
        importBase = widget.library.books.value.length;
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
      // 有失败时只在提示里写数量，逐个原因放进清单（R2-02）。
      ScaffoldMessenger.of(context).showSnackBar(
        deskSnackBar(
          content: Text(
            importCancelled
                ? '导入已停止，已导入 $count 本书稿'
                : failed.isEmpty
                ? retained.isEmpty
                      ? '已导入 $count 本书稿'
                      : '新增 ${count - retained.length} 本，保留 ${retained.length} 本。${retained.first.message}'
                : failed.length == 1
                ? '已导入 $count 本；${ImportFailuresDialog.fileName(failed.single.path)}：${failed.single.message}'
                : '已导入 $count 本，${failed.length} 个文件没有导入',
          ),
          action: failed.isEmpty
              ? null
              : SnackBarAction(
                  key: const ValueKey('library-import-failures-open'),
                  label: failed.length == 1 ? '查看' : '查看 ${failed.length} 个',
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ImportFailuresDialog(failed),
                  ),
                ),
        ),
      );
      if (collection != null) await joinImported(collection, results);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          deskSnackBar(
            content: Text(
              deskErrorText(error, '导入没有完成：已导入的书保留在书库，可以再导入一次剩下的文件。'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          picking = false;
          fileImporting = false;
          importTotal = 0;
        });
      }
    }
  }

  bool dragging = false;

  /// 外部文件拖到了哪个收藏夹行上（按行的屏幕位置判断）。
  String? collectionAt(Offset global) {
    for (final entry in (folderMode ? folderKeys : collectionKeys).entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final local = box.globalToLocal(global);
      if (box.paintBounds.contains(local)) return entry.key;
    }
    return null;
  }

  /// 外部文件拖到了哪本书上（书架格子或列表行，按屏幕位置判断）。
  String? bookAt(Offset global) {
    String? hit;
    void visit(Element element) {
      if (hit != null) return;
      final key = element.widget.key;
      if (key is ValueKey<String> && key.value.startsWith('library-row-')) {
        final box = element.findRenderObject() as RenderBox?;
        if (box != null &&
            box.attached &&
            box.paintBounds.contains(box.globalToLocal(global))) {
          hit = key.value.substring('library-row-'.length);
          return;
        }
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return hit;
  }

  Future<void> importDrop(DropDoneDetails details) async {
    final collection =
        collectionAt(details.globalPosition) ?? currentCollection;
    setState(() {
      dragging = false;
      fileHoverCollection = null;
    });
    if (picking || fileImporting || widget.library.importing.value) return;
    // 拖入图片（R1 后，用户反馈）：拖到哪本书上就给哪本书设封面，没拖到书上时给当前书；
    // 先在“选择封面图片”里预览，确认后才写入。
    final images = details.files
        .map((f) => f.path)
        .where(isCoverImagePath)
        .toList();
    if (images.isNotEmpty) {
      final target = bookAt(details.globalPosition) ?? currentId;
      if (target == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          deskSnackBar(content: const Text('先选中一本书，或把图片直接拖到某本书上。')),
        );
      } else {
        final result = await adoptCoverImage(
          context,
          widget.library,
          target,
          images.first,
          pickImage: widget.pickImage,
        );
        if (result != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(deskSnackBar(content: Text(result)));
        }
      }
    }
    final files = <String>[];
    for (final file in details.files.where((f) => !isCoverImagePath(f.path))) {
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
                            '\n图片拖到某本书上松开，可设为它的封面（先预览再保存）。'
                            '${collectionService == null ? '' : '\n拖到${folderMode ? '' : '左侧'}某个收藏夹上松开，导入后加入该收藏夹。'}',
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

  /// 左栏（收藏夹与类别，V84b）：书库区域宽 ≥520 就有；可拖右边缘伸缩（150–320）。
  /// V94：点标题行的开关或拖到最窄时整栏滑出收起；书库区域不足 700 时只显示 48 宽的图标条。
  bool railShown = false, railAvailable = false;
  // V110：收藏夹栏默认收起，点标题行左侧的开关展开。
  bool railCollapsed = true, railCanExpand = true;
  double railWidthValue = 184;
  bool get railCollapsedNow => railCollapsed || !railCanExpand;

  /// 用户收起了左栏（只在够宽时生效；窄窗口是图标条）。
  bool get railHidden => railCollapsed && railCanExpand;

  /// 收起动画结束后不再构造左栏。
  bool railGone = true;

  /// 左栏是否列出了类别与收藏夹（展开时）；图标条只有收藏夹，类别要用显示范围。
  bool get railListsScope => railShown && !railCollapsedNow;

  void setRail({bool? collapsed, double? width}) {
    setState(() {
      if (collapsed != null) railCollapsed = collapsed;
      if (!railCollapsed) railGone = false;
      if (width != null) railWidthValue = width;
    });
    rememberView();
  }

  /// 筛选行是否收成“筛选”菜单（由筛选行按宽度决定）。
  bool filtersCompact = false;

  /// 左栏不展开且有收藏夹或类别时，筛选行显示“显示范围”下拉（筛选收成菜单时放进菜单）。
  bool get scopeChoice =>
      collectionService != null &&
      !folderMode &&
      !railListsScope &&
      (collectionService!.collections.value.isNotEmpty ||
          scope.isNotEmpty ||
          widget.library.books.value.any((b) => b.category.isNotEmpty));

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
            // 收藏夹模式不出左栏：收藏夹就在书架上（V104）。
            railAvailable =
                collectionService != null &&
                !folderMode &&
                frame.maxWidth >= 520 &&
                widget.library.books.value.isNotEmpty;
            railShown = railAvailable;
            railCanExpand = frame.maxWidth >= 700;
            // 展开时书架至少留约 420。
            final railMax = (frame.maxWidth - 420).clamp(
              ResizableRail.minWidth,
              ResizableRail.maxRailWidth,
            );
            final railSpace = !railShown || railHidden
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
                      final visible = folderTop
                          ? const <BookSummary>[]
                          : filtered(books);
                      _visible = visible;
                      if (compact) {
                        _extent = rowExtent(context);
                        _columns = 1;
                      }
                      restoreView();
                      final current =
                          books.where((b) => b.id == currentId).firstOrNull ??
                          books.first;
                      final list = LayoutBuilder(
                        builder: (context, box) {
                          _wideColumns = _wide(box.maxWidth - 50);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (folderMode && scope.isNotEmpty)
                                folderCrumb(visible.length),
                              if (visible.isNotEmpty && compact) columnHeader(),
                              Expanded(
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: folderTop
                                          ? folderGrid(filtered(books))
                                          : visible.isEmpty
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
                                              ids: [
                                                for (final b in visible) b.id,
                                              ],
                                              isChecked: selected.contains,
                                              checkColumnWidth:
                                                  16 + 10 + _checkWidth + 6,
                                              passThrough:
                                                  collectionService == null
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
                        },
                      );
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (railShown)
                            // V94：收起时整栏向左滑出（只动画宽度比例，拖边缘调宽仍即时跟手）。
                            ClipRect(
                              child: AnimatedAlign(
                                alignment: Alignment.centerRight,
                                widthFactor: railHidden ? 0 : 1,
                                duration: DeskMotion.of(
                                  context,
                                  DeskMotion.base,
                                ),
                                curve: DeskMotion.snapCurve,
                                onEnd: () {
                                  if (railHidden && !railGone) {
                                    setState(() => railGone = true);
                                  }
                                },
                                child: railHidden && railGone
                                    ? const SizedBox(height: double.infinity)
                                    : ResizableRail(
                                        key: const ValueKey('library-rail'),
                                        width: railWidthValue,
                                        collapsed: !railCanExpand,
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
