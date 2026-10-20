// 导入文件夹弹窗（D4-D，V8 按设计重写视图）：扫描、续扫、勾选与导入逻辑沿用原实现。
// V84（FOLD-083–087）：全选 / 取消全选 / 反选按钮、拖动连选与框选、按名称 / 类型 / 大小 / 修改时间
// 排序与类型筛选；可选“导入后加入收藏夹”。
import 'package:flutter/material.dart';

import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/chapter_rules_service.dart';
import '../../application/library_service.dart';
import '../../application/folder_import_batch.dart';
import '../../application/settings_service.dart';
import '../../application/book_collection_service.dart';
import '../collections/collection_flow.dart';
import '../controls/controls.dart';
import '../controls/drag_select.dart';
import 'folder_book_tools.dart';
import '../rules/rules_sheet.dart' show showChapterRulesDialog;
import 'folder_scan_failures.dart';

class FolderImportDialog extends StatefulWidget {
  const FolderImportDialog({
    super.key,
    required this.library,
    required this.picker,
    this.initialPath,
    this.initialCollection,
  });
  final LibraryService library;
  final BookFilePicker picker;
  final String? initialPath;

  /// 默认加入的收藏夹（从书库某个收藏夹里导入、或把文件夹拖到收藏夹上时）。
  final String? initialCollection;
  @override
  State<FolderImportDialog> createState() => _FolderImportDialogState();
}

class _FolderImportDialogState extends State<FolderImportDialog> {
  String path = '', message = '';
  bool recursive = false, scanning = false, importing = false;
  bool recursiveTouched = false;
  int generation = 0;
  bool cancelScan = false, cancelImport = false;
  FolderListing? listing;
  final selected = <String>{};
  final range = RangeSelection();
  final view = FolderListView();
  final scroll = ScrollController();
  late String? collection = widget.initialCollection;
  List<ImportOutcome>? outcomes;
  BookCollectionService? get collections =>
      widget.library is BookCollectionService
      ? widget.library as BookCollectionService
      : null;

  /// 表头全选 / 清空（G-067）：书库已有的书不可勾选。
  void setAll(List<FolderBook> books, bool value) =>
      setMany(books.map((b) => b.path), value);

  /// 一次勾选或取消多本（按钮、拖动、Shift 选一段共用）；书库已有的跳过。
  void setMany(Iterable<String> paths, bool value) {
    if (importing) return;
    final allowed = {
      for (final b in listing?.books ?? const <FolderBook>[])
        if (!b.alreadyImported) b.path,
    };
    final targets = paths.where(allowed.contains).toList();
    setState(
      () => value ? selected.addAll(targets) : selected.removeAll(targets),
    );
  }

  @override
  void initState() {
    super.initState();
    path = widget.initialPath ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (widget.library is SettingsService) {
      final settings = widget.library as SettingsService;
      await settings.load();
      if (!mounted) return;
      if (!recursiveTouched) {
        recursive =
            settings.snapshot.value.configuration['import_recursive'] == true;
      }
    }
    if (mounted && path.isNotEmpty) await scan();
  }

  @override
  void dispose() {
    generation++;
    listing?.close?.call();
    scroll.dispose();
    super.dispose();
  }

  Future<void> browse() async {
    final value = await widget.picker.chooseFolder();
    if (!mounted || value == null) return;
    path = value;
    await scan();
  }

  Future<void> scan({bool resume = false}) async {
    final previous = listing;
    final existing = resume
        ? previous!.books.map((b) => b.path).toSet()
        : <String>{};
    final ticket = ++generation;
    setState(() {
      scanning = true;
      cancelScan = false;
      if (!resume) {
        listing?.close?.call();
        listing = null;
        selected.clear();
      }
      outcomes = null;
      message = '';
    });
    try {
      final result = resume
          ? await previous!.resume!(
              () => !mounted || cancelScan || ticket != generation,
            )
          : await widget.library.scanFolder(
              path,
              recursive: recursive,
              cancelled: () => !mounted || cancelScan || ticket != generation,
            );
      if (!mounted || ticket != generation) {
        result.close?.call();
        return;
      }
      setState(() {
        listing = result;
        selected.addAll(
          result.books
              .where((b) => !b.alreadyImported && !existing.contains(b.path))
              .map((b) => b.path),
        );
        selected.removeAll(
          result.books.where((b) => b.alreadyImported).map((b) => b.path),
        );
        message = result.message;
      });
    } catch (error) {
      if (mounted && ticket == generation) {
        setState(() => message = '扫描未完成：$error');
      }
    } finally {
      if (mounted && ticket == generation) setState(() => scanning = false);
    }
  }

  Future<void> submit() async {
    final candidates = listing;
    if (importing || scanning || candidates == null || selected.isEmpty) {
      return;
    }
    final paths = candidates.books
        .where((b) => selected.contains(b.path))
        .map((b) => b.path)
        .toList();
    setState(() {
      importing = true;
      cancelImport = false;
    });
    try {
      final results = await importFolderSelection(
        widget.library,
        paths,
        cancelled: () => !mounted || cancelImport,
      );
      if (!mounted) return;
      setState(() {
        outcomes = results;
        message =
            '导入 ${results.where((r) => r.succeeded && !r.skipped).length} 本，'
            '保留已有 ${results.where((r) => r.skipped).length} 本，'
            '失败 ${results.where((r) => !r.succeeded).length} 本，'
            '未处理 ${paths.length - results.length} 本。';
        listing = markFolderBooksHandled(candidates, results);
        // Successful and skipped entries cannot be submitted again implicitly.
        selected.removeAll(
          results.where((r) => r.succeeded).map((r) => r.path),
        );
      });
      // 导入后加入收藏夹（V84，FOLD-087）：成功的与书库已有的都加入。
      final target = collection, service = collections;
      if (target != null && service != null && mounted) {
        final ids = [
          for (final r in results)
            if (r.succeeded) ?service.bookIdForPath(r.path),
        ];
        if (ids.isNotEmpty) await joinCollection(context, service, target, ids);
      }
    } catch (error) {
      if (mounted) setState(() => message = '导入未完成：$error');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final books = listing?.books ?? const <FolderBook>[];
    final shown = view.apply(books);
    final results = outcomes ?? const <ImportOutcome>[];
    final added = results.where((r) => r.succeeded && !r.skipped).length;
    final summary = listing == null
        ? '扫描只找书，确认后才导入'
        : '可导入 ${books.where((b) => !b.alreadyImported).length} 本 · '
              '书库已有 ${books.where((b) => b.alreadyImported).length} 本 · '
              '不支持 ${listing!.unsupported} 个';
    return DeskDialog(
      title: '导入文件夹',
      subtitle: '选择文件夹后先扫描，再确认导入',
      closeTooltip: '关闭',
      width: 680,
      busy: importing,
      scrollBody: false,
      footerLeft: Text(
        outcomes == null ? summary : '新增 $added · $summary',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: ui(12, c: d.ink3),
      ),
      actions: [
        DeskButton(
          importing || scanning ? '取消操作' : '关闭',
          quiet: true,
          onPressed: () {
            if (importing) {
              cancelImport = true;
              widget.library.cancelImport();
            } else if (scanning) {
              setState(() {
                cancelScan = true;
                message = '正在停止扫描并保留已找到的书稿…';
              });
            } else {
              Navigator.pop(context);
            }
          },
        ),
        DeskButton(
          '导入所选 ${selected.length} 本',
          primary: true,
          onPressed:
              scanning || importing || listing == null || selected.isEmpty
              ? null
              : submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: d.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: d.lineStrong),
                  ),
                  child: Tooltip(
                    message: '来源文件夹',
                    child: SelectableText(
                      path.isEmpty ? '尚未选择文件夹' : path,
                      maxLines: 1,
                      style: ui(12.5, c: path.isEmpty ? d.ink3 : d.ink),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DeskButton(
                '浏览文件夹',
                icon: Icons.folder_open_outlined,
                onPressed: importing || scanning ? null : browse,
              ),
              const SizedBox(width: 8),
              Switch(
                value: recursive,
                onChanged: importing || scanning
                    ? null
                    : (v) {
                        setState(() {
                          recursiveTouched = true;
                          recursive = v;
                        });
                        if (path.isNotEmpty) scan();
                      },
              ),
              const SizedBox(width: 4),
              Text('包含子文件夹', style: ui(12.5, c: d.ink)),
              // 导入默认识别规则（V23，CH-262）：导入前先设好；只加图标。
              if (widget.library is ChapterRulesService) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('folder-import-rules'),
                  tooltip: '导入默认识别规则',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  icon: Icon(Icons.tune_rounded, color: d.ink2),
                  onPressed: importing
                      ? null
                      : () => showChapterRulesDialog(
                          context,
                          service: widget.library as ChapterRulesService,
                        ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (scanning) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 8),
          ],
          if (listing != null && books.isNotEmpty) ...[
            FolderListToolbar(
              books: books,
              shown: shown,
              selected: selected,
              view: view,
              enabled: !importing,
              onViewChanged: () => setState(range.reset),
              onSet: setMany,
            ),
            const SizedBox(height: 6),
          ],
          if (listing != null)
            SelectionKeys(
              hasSelection: selected.isNotEmpty,
              onSelectAll: importing ? null : () => setAll(shown, true),
              onClear: importing ? null : () => setAll(shown, false),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (books.isNotEmpty)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: d.line)),
                      ),
                      child: SelectAllHeader(
                        selected: selected.length,
                        total: books.where((b) => !b.alreadyImported).length,
                        note: books.any((b) => b.alreadyImported)
                            ? '书库已有 ${books.where((b) => b.alreadyImported).length} 本不可勾选'
                            : null,
                        onChanged: importing ? null : (v) => setAll(shown, v),
                      ),
                    ),
                  SizedBox(
                    height: books.isEmpty ? 240 : 210,
                    child: books.isEmpty
                        ? Center(
                            child: Text(
                              '此文件夹没有可导入的 TXT 或 EPUB',
                              style: ui(12.5, c: d.ink3),
                            ),
                          )
                        : DragSelectRegion(
                            key: const ValueKey('folder-import-drag-select'),
                            scroll: scroll,
                            itemExtent: 42,
                            checkColumnWidth: 44,
                            ids: [for (final b in shown) b.path],
                            isChecked: selected.contains,
                            apply: (check, uncheck) {
                              if (check.isNotEmpty) setMany(check, true);
                              if (uncheck.isNotEmpty) setMany(uncheck, false);
                            },
                            child: ListView.builder(
                              controller: scroll,
                              itemExtent: 42,
                              itemCount: shown.length,
                              itemBuilder: (context, index) =>
                                  bookRow(context, shown, index),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          if (collections != null &&
              collections!.collections.value.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text('导入后加入收藏夹', style: ui(12.5, c: d.ink)),
                const SizedBox(width: 8),
                DeskFilter<String>(
                  key: const ValueKey('folder-import-collection'),
                  value: collection ?? '',
                  onChanged: importing
                      ? null
                      : (v) => setState(
                          () => collection = v == null || v.isEmpty ? null : v,
                        ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不加入')),
                    for (final c in collections!.collections.value)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                ),
              ],
            ),
          ],
          if (message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(message, style: ui(12, c: d.ink2, h: 1.5)),
          ],
          if (listing?.failures.isNotEmpty == true ||
              listing?.resume != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (listing?.failures.isNotEmpty == true)
                  FolderScanFailures(paths: listing!.failures),
                if (listing?.resume != null)
                  DeskButton(
                    '继续扫描 / 重试失败项',
                    quiet: true,
                    onPressed: scanning || importing
                        ? null
                        : () => scan(resume: true),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget bookRow(BuildContext context, List<FolderBook> books, int index) {
    final d = context.desk;
    final book = books[index];
    final result = outcomes?.where((r) => r.path == book.path).firstOrNull;
    final (state, tone) = result != null
        ? result.succeeded
              ? result.skipped
                    ? ('已在书库，保留现有草稿', Tone.neutral)
                    : ('已导入', Tone.ok)
              : ('导入失败', Tone.pen)
        : book.alreadyImported
        ? ('已在书库，保留现有草稿', Tone.neutral)
        : ('新增', Tone.ok);
    final enabled = !importing && !book.alreadyImported;
    final checked = selected.contains(book.path);
    void toggle(bool value) =>
        setMany([for (final i in range.span(index)) books[i].path], value);
    return InkWell(
      onTap: enabled ? () => toggle(!checked) : null,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: d.line)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: checked,
              visualDensity: VisualDensity.compact,
              onChanged: enabled ? (v) => toggle(v ?? false) : null,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                book.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(12.5, c: d.ink),
              ),
            ),
            Text(folderBookTime(book.modified), style: mono(10.5, c: d.ink3)),
            const SizedBox(width: 10),
            SizedBox(
              width: 64,
              child: Text(
                folderBookSize(book.bytes),
                textAlign: TextAlign.right,
                style: mono(10.5, c: d.ink3),
              ),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: result?.message ?? '',
              child: DeskTag(state, tone),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
