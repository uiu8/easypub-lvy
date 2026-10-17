// 导入文件夹弹窗（D4-D，V8 按设计重写视图）：扫描、续扫、勾选与导入逻辑沿用原实现。
import 'package:flutter/material.dart';

import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/chapter_rules_service.dart';
import '../../application/library_service.dart';
import '../../application/folder_import_batch.dart';
import '../../application/settings_service.dart';
import '../controls/controls.dart';
import '../rules/rules_sheet.dart' show showChapterRulesDialog;
import 'folder_scan_failures.dart';

class FolderImportDialog extends StatefulWidget {
  const FolderImportDialog({
    super.key,
    required this.library,
    required this.picker,
    this.initialPath,
  });
  final LibraryService library;
  final BookFilePicker picker;
  final String? initialPath;
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
  List<ImportOutcome>? outcomes;

  /// 表头全选 / 清空（G-067）：书库已有的书不可勾选。
  void setAll(List<FolderBook> books, bool value) => setState(() {
    final paths = books.where((b) => !b.alreadyImported).map((b) => b.path);
    value ? selected.addAll(paths) : selected.removeAll(paths);
  });
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
    } catch (error) {
      if (mounted) setState(() => message = '导入未完成：$error');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : bytes >= 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '$bytes B';

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final books = listing?.books ?? const <FolderBook>[];
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
          if (listing != null)
            SelectionKeys(
              hasSelection: selected.isNotEmpty,
              onSelectAll: importing ? null : () => setAll(books, true),
              onClear: importing ? null : () => setAll(books, false),
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
                        onChanged: importing ? null : (v) => setAll(books, v),
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
                        : ListView.builder(
                            itemCount: books.length,
                            itemBuilder: (context, index) =>
                                bookRow(context, books, index),
                          ),
                  ),
                ],
              ),
            ),
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
    void toggle(bool value) => setState(() {
      for (final i in range.span(index)) {
        final b = books[i];
        if (b.alreadyImported) continue;
        value ? selected.add(b.path) : selected.remove(b.path);
      }
    });
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
            Text(_size(book.bytes), style: mono(10.5, c: d.ink3)),
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
