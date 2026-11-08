// 清理规则应用到多本书（CLEAN-081–090）：勾选目标书 → 逐书预览 → 核对后整批采用；部分失败只能
// “仅重新预览可处理书”，不会静默跳过失败书提交。逻辑沿用 V4 前的 CleanupBatchDialog。
// V17：有章节修改的书逐本换算；无法换算的书由用户逐本决定放弃修改或不清理（CLEAN-104）。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/cleanup_batch_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart'
    show DeskButton, RangeSelection, SelectAllHeader, SelectionKeys;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'batch_difference_dialog.dart';

class CleanupBatchDialog extends StatefulWidget {
  const CleanupBatchDialog({
    super.key,
    required this.library,
    required this.bookId,
    required this.template,
  });
  final LibraryService library;
  final String bookId, template;
  @override
  State<CleanupBatchDialog> createState() => _CleanupBatchDialogState();
}

class _CleanupBatchDialogState extends State<CleanupBatchDialog> {
  late final session = widget.library.openCleanupBatch(widget.bookId);
  late final books = List<BookSummary>.of(widget.library.books.value);
  // 默认目标（G-068）：书库里已勾选的书；书库没有勾选时全选。
  late final selected = () {
    final chosen = widget.library.selection.value.selected.toSet();
    return chosen.isNotEmpty ? chosen : books.map((b) => b.id).toSet();
  }();
  final range = RangeSelection();

  void setMany(Iterable<String> ids, bool value) => edit(() {
    value ? selected.addAll(ids) : selected.removeAll(ids);
  });
  CleanupBatchPreview? plan;
  bool append = true, busy = false, confirmed = false;
  final expanded = <String>{};

  /// 用户确认放弃无法换算的章节修改的书（CLEAN-104）。
  final dropEdits = <String>{};
  String error = '';
  @override
  void initState() {
    super.initState();
    session.changes.addListener(refresh);
  }

  void refresh() {
    setState(() {
      if (plan != null && !session.isCurrent(plan!)) confirmed = false;
    });
  }

  @override
  void dispose() {
    session.changes.removeListener(refresh);
    session.dispose();
    super.dispose();
  }

  void edit(VoidCallback action) {
    session.cancel();
    setState(() {
      action();
      plan = null;
      confirmed = false;
      dropEdits.clear();
      error = '';
    });
  }

  Future<void> previewReadyBooks() async {
    final previous = plan;
    if (previous == null || busy) return;
    final ready = previous.items
        .where(
          (item) =>
              item.error.isEmpty && session.canRead(previous, item.bookId),
        )
        .map((item) => item.bookId)
        .toSet();
    if (ready.isEmpty) return;
    edit(() {
      selected
        ..clear()
        ..addAll(ready);
    });
    await run(false);
  }

  Future<void> run(bool apply) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (apply) {
        await session.apply(plan!, dropEdits: Set.of(dropEdits));
        if (mounted) Navigator.pop(context, selected.toSet());
      } else {
        final next = await session.preview(
          widget.template,
          books.where((b) => selected.contains(b.id)).map((b) => b.id).toList(),
          append: append,
        );
        if (mounted) {
          setState(() {
            plan = next;
            confirmed = false;
            dropEdits.clear();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = deskErrorText(e, '批量处理未采用，请核对规则及目标书。');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Widget bookRow(int index) {
    final d = context.desk;
    final book = books[index];
    final row = plan?.items.where((r) => r.bookId == book.id).firstOrNull;
    final on = selected.contains(book.id);
    final undecided =
        row != null && row.needsDecision && !dropEdits.contains(book.id);
    final (status, tone) = row == null
        ? (on ? '待预览' : '未选', Tone.neutral)
        : undecided
        ? ('需要你决定', Tone.warn)
        : row.error.isEmpty
        ? ('可采用', Tone.ok)
        : (row.error, Tone.pen);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: on,
                onChanged: busy
                    ? null
                    : (value) => setMany([
                        for (final i in range.span(index)) books[i].id,
                      ], value == true),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(13, w: 600, c: on ? d.ink : d.ink3),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  row == null
                      ? (on ? '清理规则' : '不在本批次')
                      : '${row.changes} 处变更 · ${row.candidates} 条候选',
                  style: ui(12, c: d.ink2),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: DeskTag(status, tone),
                  ),
                ),
              ),
            ],
          ),
          if (row != null && row.error.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 6),
              child: Wrap(
                spacing: 6,
                children: [
                  DeskButton(
                    '浏览全部差异',
                    quiet: true,
                    onPressed: busy || !session.canRead(plan!, book.id)
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            builder: (_) => CleanupBatchDifferenceDialog(
                              session: session,
                              plan: plan!,
                              bookId: book.id,
                              title: book.title,
                            ),
                          ),
                  ),
                  if (row.samples.isNotEmpty)
                    DeskButton(
                      expanded.contains(book.id) ? '收起差异样例' : '查看差异样例（最多 3 条）',
                      quiet: true,
                      onPressed: () => setState(() {
                        if (!expanded.add(book.id)) expanded.remove(book.id);
                      }),
                    ),
                ],
              ),
            ),
          if (row != null && row.error.isEmpty && row.editsKept > 0)
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 6),
              child: Text(
                '${row.editsKept} 处章节修改会换算到清理后的文本并保留。',
                key: ValueKey('batch-edits-kept-${book.id}'),
                style: ui(12, c: d.ink2),
              ),
            ),
          if (row != null && row.needsDecision)
            Container(
              key: ValueKey('batch-edits-decision-${book.id}'),
              margin: const EdgeInsets.fromLTRB(40, 0, 8, 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: d.sunken,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${row.skippedEdits.length} 处章节修改对应的行在清理后不存在或已改变，无法保留：',
                    style: ui(12.5, c: d.ink),
                  ),
                  const SizedBox(height: 4),
                  for (final s in row.skippedEdits.take(3))
                    Text(
                      '第 ${s.index + 1} 处 · ${s.action}：${s.reason}',
                      style: ui(12, c: d.ink2),
                    ),
                  if (row.skippedEdits.length > 3)
                    Text(
                      '另有 ${row.skippedEdits.length - 3} 处。',
                      style: ui(12, c: d.ink3),
                    ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (dropEdits.contains(book.id)) ...[
                        Text('已选择：放弃这些修改并清理', style: ui(12, c: d.ink2)),
                        DeskButton(
                          '改变决定',
                          quiet: true,
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  dropEdits.remove(book.id);
                                  confirmed = false;
                                }),
                        ),
                      ] else ...[
                        DeskButton(
                          '放弃这些修改并清理',
                          key: ValueKey('batch-drop-edits-${book.id}'),
                          onPressed: busy
                              ? null
                              : () => setState(() => dropEdits.add(book.id)),
                        ),
                        DeskButton(
                          '不清理这本书',
                          key: ValueKey('batch-skip-book-${book.id}'),
                          quiet: true,
                          onPressed: busy
                              ? null
                              : () => edit(() => selected.remove(book.id)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          if (row != null && expanded.contains(book.id))
            for (final sample in row.samples)
              Container(
                margin: const EdgeInsets.fromLTRB(40, 0, 8, 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: d.sunken,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: SelectableText(
                  sample,
                  style: serif(13, c: d.ink2, h: 1.6),
                ),
              ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '应用到多本书',
      subtitle: '将当前清理规则应用到其他书。每本书独立预览，保留各自的源行范围、候选选择和保留项。',
      closeTooltip: '关闭',
      width: 780,
      busy: busy,
      footerLeft: Text('整批通过后才应用，可逐书撤销；历史随工作区保存。', style: ui(11.5, c: d.ink3)),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        DeskButton(
          '逐书预览',
          disabledReason: '至少选择一本书',
          onPressed: busy || selected.isEmpty ? null : () => run(false),
        ),
        DeskButton(
          '确认采用',
          primary: true,
          disabledReason: '先逐书预览并勾选核对',
          onPressed:
              !busy && confirmed && plan != null && session.isCurrent(plan!)
              ? () => run(true)
              : null,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectAllHeader(
            selected: selected.length,
            total: books.length,
            compact: false,
            padding: const EdgeInsets.fromLTRB(1, 0, 8, 2),
            onChanged: busy ? null : (v) => setMany(books.map((b) => b.id), v),
            body: Row(
              children: [
                const SizedBox(width: 4),
                Expanded(
                  flex: 4,
                  child: Text('目标书稿', style: ui(11.5, w: 600, c: d.ink3)),
                ),
                Expanded(
                  flex: 4,
                  child: Text('内容', style: ui(11.5, w: 600, c: d.ink3)),
                ),
                Expanded(
                  flex: 3,
                  child: Text('状态', style: ui(11.5, w: 600, c: d.ink3)),
                ),
              ],
            ),
          ),
          SelectionKeys(
            hasSelection: selected.isNotEmpty,
            onSelectAll: busy
                ? null
                : () => setMany(books.map((b) => b.id), true),
            onClear: busy ? null : () => setMany(books.map((b) => b.id), false),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 300),
              decoration: BoxDecoration(
                color: d.surface,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: d.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  shrinkWrap: true,
                  children: [for (var i = 0; i < books.length; i++) bookRow(i)],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const DeskLabel('清理规则处理'),
          Align(
            alignment: Alignment.centerLeft,
            child: DeskSegmented<bool>(
              value: append,
              options: const {true: '追加到现有规则末尾', false: '替换现有规则'},
              onChanged: busy
                  ? null
                  : (value) => edit(() {
                      append = value;
                    }),
            ),
          ),
          if (plan != null && plan!.items.any((item) => item.error.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DeskButton(
                  '仅重新预览可处理书（${plan!.items.where((item) => item.error.isEmpty).length} 本）',
                  onPressed:
                      busy ||
                          !plan!.items.any(
                            (item) => session.canRead(plan!, item.bookId),
                          )
                      ? null
                      : previewReadyBooks,
                ),
              ),
            ),
          if (plan != null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('已核对逐书预览，确认采用本批清理规则', style: ui(13, c: d.ink)),
              value: confirmed,
              // 有书的章节修改无法换算且尚未决定时，不能确认采用。
              onChanged:
                  !busy &&
                      plan!.ready &&
                      plan!.items.every(
                        (item) =>
                            !item.needsDecision ||
                            dropEdits.contains(item.bookId),
                      )
                  ? (v) => setState(() {
                      confirmed = v!;
                    })
                  : null,
            ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 8),
            DeskNote(error, tone: Tone.pen),
          ],
        ],
      ),
    );
  }
}
