// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/book_batch_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../cleanup/batch_difference_dialog.dart';

import 'batch_field_dialog.dart';
import '../tokens.dart';

class BookBatchDialog extends StatefulWidget {
  const BookBatchDialog({
    super.key,
    required this.library,
    required this.bookId,
    this.initialTargets,
  });
  final LibraryService library;
  final String bookId;
  final Set<String>? initialTargets;
  @override
  State<BookBatchDialog> createState() => _BookBatchDialogState();
}

class _BookBatchDialogState extends State<BookBatchDialog> {
  late final BookBatchSession session = widget.library.openBookBatch(
    widget.bookId,
  );
  late final books = widget.library.books.value.toList();
  late final targets = {
    ...(widget.initialTargets ?? widget.library.selection.value.selected),
  };
  final range = RangeSelection();

  /// 表头全选 / 清空与 Shift 选一段（G-067）。
  void setMany(Iterable<String> ids, bool value) => setState(() {
    value ? targets.addAll(ids) : targets.removeAll(ids);
  });
  final fields = <String>{};
  final expandedBooks = <String>{};
  BookBatchPreview? plan;
  String error = '';
  bool busy = false, cleanup = false, append = true;
  @override
  void initState() {
    super.initState();
    session;
    targets.removeWhere((id) => !books.any((b) => b.id == id));
    // 没有指定目标、书库也没有勾选时默认全选（G-068）。
    if (targets.isEmpty && widget.initialTargets == null) {
      targets.addAll(books.map((b) => b.id));
    }
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = deskErrorText(e, '批量检查失败，本批未应用。请核对书稿与资源。');
          plan = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseFields() async {
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => BatchFieldDialog(selected: fields),
    );
    if (mounted && selected != null) {
      setState(() {
        fields.clear();
        fields.addAll(selected);
        plan = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      backgroundColor: context.desk.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 760,
        height: 612,
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: DeskText('应用到多本书', size: 22, bold: true),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: busy
                        ? null
                        : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: context.desk.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: context.desk.accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DeskText(
                            '来源：${books.firstWhere((book) => book.id == widget.bookId).title}（已保存设置）',
                            bold: true,
                            color: context.desk.accent,
                          ),
                          DeskText(
                            '仅复制明确勾选的字段，每本书先生成独立预览。',
                            size: 12,
                            color: context.desk.accent,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DeskText('封面与元信息 · 排版', color: context.desk.accent),
                  DeskButton(
                    '选择字段（${fields.length}）',
                    quiet: true,
                    onPressed: busy || plan != null ? null : chooseFields,
                  ),
                  FilterChip(
                    label: const Text('清理规则'),
                    selected: cleanup,
                    onSelected: busy || plan != null
                        ? null
                        : (value) => setState(() => cleanup = value),
                  ),
                  if (plan != null)
                    DeskButton(
                      '返回选择',
                      quiet: true,
                      onPressed: busy
                          ? null
                          : () => setState(() => plan = null),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                color: context.desk.canvas,
                padding: const EdgeInsets.fromLTRB(0, 2, 12, 2),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: SelectAllHeader(
                        selected: targets.length,
                        total: books.length,
                        compact: false,
                        height: 40,
                        padding: EdgeInsets.zero,
                        onChanged: busy || plan != null
                            ? null
                            : (v) => setMany(books.map((b) => b.id), v),
                        body: DeskText(
                          '目标书稿 · ${targets.length} / ${books.length}',
                          size: 12,
                          color: context.desk.ink2,
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: DeskText('内容', size: 12, color: context.desk.ink2),
                    ),
                    Expanded(
                      flex: 2,
                      child: DeskText('状态', size: 12, color: context.desk.ink2),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SelectionKeys(
                  hasSelection: targets.isNotEmpty && plan == null,
                  onSelectAll: busy || plan != null
                      ? null
                      : () => setMany(books.map((b) => b.id), true),
                  onClear: busy || plan != null
                      ? null
                      : () => setMany(books.map((b) => b.id), false),
                  child: ListView.builder(
                    itemCount: books.length,
                    itemBuilder: (_, i) {
                      final book = books[i];
                      final item = plan?.production[book.id];
                      final clean = plan?.cleanup?.items
                          .where((v) => v.bookId == book.id)
                          .firstOrNull;
                      return Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: context.desk.line),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: Row(
                                    children: [
                                      Checkbox(
                                        value: targets.contains(book.id),
                                        onChanged: busy || plan != null
                                            ? null
                                            : (value) => setMany([
                                                for (final j in range.span(i))
                                                  books[j].id,
                                              ], value == true),
                                      ),
                                      Expanded(
                                        child: DeskText(
                                          book.title,
                                          bold: true,
                                          lines: 1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: DeskText(
                                    !targets.contains(book.id)
                                        ? '不在本批次'
                                        : item == null
                                        ? '${fields.length} 项字段${cleanup ? ' + 清理规则' : ''}'
                                        : '${item.changed.length} 项变化',
                                    size: 12,
                                    color: context.desk.ink2,
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: DeskText(
                                    !targets.contains(book.id)
                                        ? '未选'
                                        : plan == null
                                        ? '待检查'
                                        : plan!.errors.containsKey(book.id)
                                        ? '未通过'
                                        : !plan!.ready
                                        ? '已检查 · 整批未应用'
                                        : '可应用',
                                    size: 12,
                                    color: context.desk.ink2,
                                  ),
                                ),
                                if (plan != null && targets.contains(book.id))
                                  IconButton(
                                    tooltip: '查看变更详情',
                                    icon: Icon(
                                      expandedBooks.contains(book.id)
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 18,
                                    ),
                                    onPressed: () => setState(() {
                                      if (!expandedBooks.add(book.id)) {
                                        expandedBooks.remove(book.id);
                                      }
                                    }),
                                  ),
                              ],
                            ),
                            if (expandedBooks.contains(book.id))
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (plan?.errors[book.id] != null)
                                    Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: DeskText(
                                        plan!.errors[book.id]!,
                                        size: 12,
                                        color: Color(0xffA04B3B),
                                      ),
                                    ),

                                  if (clean != null)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          DeskText(
                                            '清理：${clean.changes} 处变化，${clean.candidates} 个候选',
                                            size: 12,
                                            color: context.desk.ink2,
                                          ),
                                          for (final sample in clean.samples)
                                            DeskText(
                                              sample,
                                              size: 12,
                                              color: context.desk.ink2,
                                            ),
                                          DeskButton(
                                            '查看全部清理差异',
                                            quiet: true,
                                            onPressed: busy
                                                ? null
                                                : () {
                                                    final frozen = plan!;
                                                    showDialog<void>(
                                                      context: context,
                                                      builder: (_) =>
                                                          CleanupBatchDifferenceDialog.reader(
                                                            bookId: book.id,
                                                            title: book.title,
                                                            listenable:
                                                                session.changes,
                                                            isCurrent: () =>
                                                                session.canRead(
                                                                  frozen,
                                                                  book.id,
                                                                ),
                                                            read: (offset) =>
                                                                session
                                                                    .differences(
                                                                      frozen,
                                                                      book.id,
                                                                      offset:
                                                                          offset,
                                                                    ),
                                                          ),
                                                    );
                                                  },
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (item != null)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        12,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          for (final field in fields.expand(
                                            (key) => key == 'cover'
                                                ? batchCoverLabels.keys
                                                : [key],
                                          ))
                                            DeskText(
                                              '${batchCoverLabels[field] ?? batchFieldLabels[field]}：${describeBatchValue(field, item.before[field])} → ${describeBatchValue(field, item.after[field])}',
                                              size: 12,
                                              color: context.desk.ink2,
                                            ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (cleanup)
                DeskChoice<bool>(
                  initialValue: append,
                  decoration: const InputDecoration(labelText: '清理规则处理'),
                  items: const [
                    DropdownMenuItem(value: true, child: Text('追加到现有规则末尾')),
                    DropdownMenuItem(value: false, child: Text('替换现有规则')),
                  ],
                  onChanged: busy || plan != null
                      ? null
                      : (value) => setState(() => append = value!),
                ),
              const SizedBox(height: 12),
              DeskText(
                '整批通过后才应用，修改随工作区保存。',
                size: 12,
                color: context.desk.ink2,
              ),
              if (plan != null && !plan!.ready)
                DeskText(
                  plan!.batchError.isNotEmpty
                      ? plan!.batchError
                      : '部分书稿未通过检查，本批不会应用。请返回选择并处理问题。',
                  size: 12,
                ),
              if (error.isNotEmpty) DeskText(error, size: 12),
              const Divider(height: 32),
              Row(
                children: [
                  DeskButton(
                    '取消',
                    quiet: true,
                    onPressed: busy
                        ? null
                        : () => Navigator.pop(context, false),
                  ),
                  const Spacer(),
                  DeskButton(
                    plan == null ? '预览并确认' : '确认应用',
                    primary: true,
                    onPressed:
                        busy ||
                            (fields.isEmpty && !cleanup) ||
                            targets.isEmpty ||
                            (plan != null && !plan!.ready)
                        ? null
                        : () => run(() async {
                            if (plan == null) {
                              final result = await session.preview(
                                fields,
                                targets.toList(),
                                cleanup: cleanup,
                                append: append,
                              );
                              if (mounted) setState(() => plan = result);
                            } else {
                              await session.apply(plan!);
                              if (context.mounted) Navigator.pop(context, true);
                            }
                          }),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
