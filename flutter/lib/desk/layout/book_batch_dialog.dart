// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/book_batch_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../cleanup/batch_difference_dialog.dart';

import 'batch_field_dialog.dart';
import '../dialogs.dart' show DeskDialog;
import '../tokens.dart';
import '../widgets.dart' show DeskTag;

class BookBatchDialog extends StatefulWidget {
  const BookBatchDialog({
    super.key,
    required this.library,
    required this.bookId,
    this.initialTargets,
    this.initialFields,
  });
  final LibraryService library;
  final String bookId;
  final Set<String>? initialTargets;

  /// 打开时已勾选的字段；排版页传全部排版字段（R5-02）。
  final Set<String>? initialFields;
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
    final usable = ids.where((id) => id != widget.bookId);
    value ? targets.addAll(usable) : targets.removeAll(usable);
  });

  /// 可作为目标的书（除来源书外）。
  Iterable<String> get others =>
      books.map((b) => b.id).where((id) => id != widget.bookId);
  late final fields = <String>{...?widget.initialFields};
  final expandedBooks = <String>{};
  BookBatchPreview? plan;
  String error = '';
  bool busy = false, cleanup = false, append = true;
  @override
  void initState() {
    super.initState();
    session;
    // 来源书不作为目标：列出来标“来源”，不可勾选（R5-02）。
    targets.removeWhere(
      (id) => id == widget.bookId || !books.any((b) => b.id == id),
    );
    // 没有指定目标、书库也没有勾选时默认全选（G-068）。
    if (targets.isEmpty && widget.initialTargets == null) {
      targets.addAll(others);
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

  // 编辑台弹窗（R5-03）：统一标题与关闭按钮，Esc 关闭；内容与行为不变。
  @override
  Widget build(BuildContext context) => DeskDialog(
    title: '应用到多本书',
    closeTooltip: '关闭',
    width: 760,
    height: 612,
    busy: busy,
    escapeCloses: true,
    onClose: () => Navigator.pop(context, false),
    footerLeft: Align(
      alignment: Alignment.centerLeft,
      child: DeskButton(
        '取消',
        quiet: true,
        onPressed: busy ? null : () => Navigator.pop(context, false),
      ),
    ),
    actions: [
      DeskButton(
        plan == null ? '预览并确认' : '确认应用',
        primary: true,
        disabledReason: fields.isEmpty && !cleanup
            ? '先选择要复制的设置'
            : targets.isEmpty
            ? '先勾选目标书稿'
            : plan != null && !plan!.ready
            ? '本批未通过检查，返回选择处理问题'
            : null,
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
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: context.desk.accentSoft,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: context.desk.accent),
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
            // 工具行（R5-10）：标题用普通文字，清理规则用编辑台勾选框。
            DeskText('要复制的设置', size: 13, color: context.desk.ink2),
            DeskButton(
              fields.isEmpty ? '选择字段…' : '已选 ${fields.length} 项字段…',
              quiet: true,
              onPressed: busy || plan != null ? null : chooseFields,
            ),
            InkWell(
              key: const ValueKey('book-batch-cleanup'),
              borderRadius: BorderRadius.circular(6),
              onTap: busy || plan != null
                  ? null
                  : () => setState(() => cleanup = !cleanup),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: cleanup,
                    onChanged: busy || plan != null
                        ? null
                        : (value) => setState(() => cleanup = value == true),
                  ),
                  const DeskText('同时应用清理规则', size: 13),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            if (plan != null)
              DeskButton(
                '返回选择',
                quiet: true,
                onPressed: busy ? null : () => setState(() => plan = null),
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
                  total: others.length,
                  compact: false,
                  height: 40,
                  padding: EdgeInsets.zero,
                  onChanged: busy || plan != null
                      ? null
                      : (v) => setMany(others, v),
                  body: DeskText(
                    '目标书稿 · ${targets.length} / ${others.length}',
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
                : () => setMany(others, true),
            onClear: busy || plan != null ? null : () => setMany(others, false),
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
                                  onChanged:
                                      busy ||
                                          plan != null ||
                                          book.id == widget.bookId
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
                                    color: book.id == widget.bookId
                                        ? context.desk.ink3
                                        : null,
                                  ),
                                ),
                                if (book.id == widget.bookId)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 6),
                                    child: DeskTag('来源', Tone.neutral),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: DeskText(
                              book.id == widget.bookId
                                  ? '复制的来源'
                                  : !targets.contains(book.id)
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
                              book.id == widget.bookId
                                  ? '—'
                                  : !targets.contains(book.id)
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
                                  color: context.desk.pen,
                                ),
                              ),

                            if (clean != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                                          session.differences(
                                                            frozen,
                                                            book.id,
                                                            offset: offset,
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
        DeskText('整批通过后才应用，修改随工作区保存。', size: 12, color: context.desk.ink2),
        if (plan != null && !plan!.ready)
          DeskText(
            plan!.batchError.isNotEmpty
                ? plan!.batchError
                : '部分书稿未通过检查，本批不会应用。请返回选择并处理问题。',
            size: 12,
          ),
        if (error.isNotEmpty) DeskText(error, size: 12),
      ],
    ),
  );
}
