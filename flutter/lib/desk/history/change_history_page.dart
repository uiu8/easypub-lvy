// 变更记录（HIS-001–019）：全局页为“记录列表 + 详情”，章节工作区“变更记录”页签为紧凑列表。
// 撤销 / 重做先确认，只作用于该领域当前一步或紧接其后的已撤销记录；原文件与已导出成品不变。
// 逻辑沿用 V4 前的 ChangeHistoryPage；设计：design_review_v37/d2_history.dart。
import '../../application/cleanup_service.dart'
    show CleanupEditsNeedConfirmation;
import '../cleanup/dropped_edits_dialog.dart';

import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/change_history_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart' show DeskButton, DeskChoice, DeskFilter;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'tree_comparison.dart';

class ChangeHistoryPage extends StatefulWidget {
  const ChangeHistoryPage({
    super.key,
    required this.library,
    required this.history,
    required this.openEditor,
    this.bookId,
    this.compact = false,
    this.onChanged,
  });
  final String? bookId;
  final bool compact;
  final Future<void> Function()? onChanged;
  final LibraryService library;
  final ChangeHistoryService history;
  final void Function(String, String) openEditor;
  @override
  State<ChangeHistoryPage> createState() => _ChangeHistoryPageState();
}

class _ChangeHistoryPageState extends State<ChangeHistoryPage> {
  String? book, selected;
  String filter = '全部类型', error = '';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    book = widget.library.selection.value.current;
  }

  Future<void> undo(ChangeDetail detail, {bool redo = false}) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => DeskDialog(
        title: redo ? '重做此次修改' : '撤销此次修改',
        closeTooltip: '取消',
        width: 470,
        onClose: () => Navigator.pop(context, false),
        actions: [
          DeskButton(
            '取消',
            quiet: true,
            onPressed: () => Navigator.pop(context, false),
          ),
          DeskButton(
            redo ? '确认重做' : '确认撤销',
            primary: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        child: Text(
          redo
              ? '恢复该领域下一步已撤销的修改。提交前会检查与当前其他编辑的依赖，检查结果需要重新核对。'
              : '将该领域退回此条记录修改前的版本。原文件与已经导出的成品不变，依赖此版本的检查结果需要重新核对。',
          style: ui(13, c: context.desk.ink2, h: 1.6),
        ),
      ),
    );
    if (!mounted || accepted != true) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      try {
        if (redo) {
          await (widget.history as RedoChangeHistoryService).redo(detail);
        } else {
          await widget.history.undo(detail);
        }
      } on CleanupEditsNeedConfirmation catch (request) {
        // 撤销 / 重做清理时有章节修改无法换算：列出并请用户确认（CLEAN-103）。
        if (!mounted ||
            !await resolveCleanupEditConfirmation(context, request)) {
          return;
        }
      }
      await widget.onChanged?.call();
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '恢复未完成，请重新读取记录。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------------------------------------------------------------- 视图

  Widget comparison(ChangeDetail detail, bool after) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: d.paper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            after ? '修改后' : '修改前',
            style: ui(12, w: 620, c: after ? d.add : d.del),
          ),
          const SizedBox(height: 10),
          for (final field in detail.fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(field.label, style: ui(12, w: 600, c: d.ink2)),
                  const SizedBox(height: 2),
                  SelectableText(
                    after ? field.after : field.before,
                    style: ui(13, c: d.ink, h: 1.5),
                  ),
                ],
              ),
            ),
          if (detail.fields.length >= 80)
            Text('此处展示前80项字段差异；完整方案保存在项目历史中。', style: ui(11.5, c: d.ink3)),
        ],
      ),
    );
  }

  Future<void> showTrees(ChangeDetail change) => showDialog<void>(
    context: context,
    builder: (context) => DeskDialog(
      title: '章节变化',
      subtitle: change.record.title,
      closeTooltip: '关闭章节变化',
      width: 960,
      height: 660,
      child: HistoryTreeComparison(history: widget.history, detail: change),
    ),
  );

  Widget statusTag(ChangeRecord row) => DeskTag(
    row.applied ? '已应用' : '已撤销',
    row.applied ? Tone.ok : Tone.neutral,
  );

  Widget compactList(List<ChangeRecord> records) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error.isNotEmpty) DeskNote(error, title: '操作未完成', tone: Tone.pen),
        SizedBox(
          height: 2,
          child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        Expanded(
          child: records.isEmpty
              ? Center(
                  child: Text('此书暂无变更记录。', style: ui(13, c: d.ink2)),
                )
              : Material(
                  color: d.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: d.line),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListView.builder(
                    itemCount: records.length,
                    itemBuilder: (context, index) {
                      final row = records[index];
                      return ExpansionTile(
                        key: PageStorageKey(row.id),
                        expansionAnimationStyle: AnimationStyle(
                          duration: DeskMotion.of(context, DeskMotion.base),
                          curve: DeskMotion.snapCurve,
                        ),
                        shape: const Border(),
                        title: Text(row.title, style: ui(13, w: 600, c: d.ink)),
                        subtitle: Text(
                          '${row.category} · 版本 ${row.version} · ${row.applied ? '已采用' : '已撤销'}',
                          style: ui(11.5, c: d.ink3),
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: Builder(
                              builder: (context) {
                                final change = widget.history.detail(row);
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (final field in change.fields)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text(
                                              field.label,
                                              style: ui(12, w: 600, c: d.ink2),
                                            ),
                                            SelectableText(
                                              '修改前：${field.before}',
                                              key: PageStorageKey(
                                                '${row.id}-${change.fields.indexOf(field)}-before',
                                              ),
                                              style: ui(12.5, c: d.del),
                                            ),
                                            SelectableText(
                                              '修改后：${field.after}',
                                              key: PageStorageKey(
                                                '${row.id}-${change.fields.indexOf(field)}-after',
                                              ),
                                              style: ui(12.5, c: d.add),
                                            ),
                                          ],
                                        ),
                                      ),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        DeskButton(
                                          '撤销此次修改',
                                          icon: Icons.undo_rounded,
                                          disabledReason: '只能撤销该领域当前一步',
                                          onPressed: busy || !row.canUndo
                                              ? null
                                              : () => undo(change),
                                        ),
                                        if (row.domain == '章节')
                                          DeskButton(
                                            '查看章节变化',
                                            icon: Icons.account_tree_outlined,
                                            quiet: true,
                                            onPressed: busy
                                                ? null
                                                : () => showTrees(change),
                                          ),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  static String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String dayLabel(DateTime t) {
    final now = DateTime.now();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (days == 0) return '今天';
    if (days == 1) return '昨天';
    return t.year == now.year
        ? '${t.month}月${t.day}日'
        : '${t.year}年${t.month}月${t.day}日';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.history.changes, widget.library.books]),
    builder: (context, _) {
      final d = context.desk;
      final books = widget.library.books.value;
      final id = widget.bookId != null
          ? (books.any((b) => b.id == widget.bookId) ? widget.bookId : null)
          : books.any((b) => b.id == book)
          ? book
          : books.firstOrNull?.id;
      final filtered = id == null
          ? <ChangeRecord>[]
          : widget.history
                .records(id)
                .where((r) => filter == '全部类型' || r.category == filter)
                .toList();
      // 有时间的按时间倒序在前；登记开始前的旧版本保持原顺序，归入“时间未记录”。
      final timed = filtered.where((r) => r.time != null).toList()
        ..sort((a, b) => b.time!.compareTo(a.time!));
      final records = [...timed, ...filtered.where((r) => r.time == null)];
      final rows = <Object>[];
      String? lastGroup;
      for (final r in records) {
        final group = r.time == null ? '时间未记录' : dayLabel(r.time!);
        if (group != lastGroup) {
          rows.add(group);
          lastGroup = group;
        }
        rows.add(r);
      }
      final record =
          records.where((r) => r.id == selected).firstOrNull ??
          records.firstOrNull;
      final detail = record == null ? null : widget.history.detail(record);
      if (widget.compact) return compactList(records);
      final list = Material(
        color: d.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  Flexible(
                    child: DeskChoice<String>(
                      key: const ValueKey('history-book-choice'),
                      value: id,
                      compact: true,
                      searchable: true,
                      hint: const Text('选择记录书籍'),
                      items: [
                        for (final b in books)
                          DropdownMenuItem(value: b.id, child: Text(b.title)),
                      ],
                      onChanged: busy || books.isEmpty
                          ? null
                          : (value) => setState(() {
                              book = value;
                              selected = null;
                              error = '';
                            }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DeskFilter<String>(
                    value: filter,
                    onClear: busy || filter == '全部类型'
                        ? null
                        : () => setState(() {
                            filter = '全部类型';
                            selected = null;
                            error = '';
                          }),
                    items: [
                      for (final value in [
                        '全部类型',
                        '章节',
                        '人工编辑',
                        '结构',
                        '文本清理',
                        '排版',
                        '书籍信息',
                        '批量制作',
                      ])
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => setState(() {
                            filter = v!;
                            selected = null;
                            error = '';
                          }),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                '按时间分组；时间登记开始前的旧版本归入“时间未记录”。',
                style: ui(11.5, c: d.ink3),
              ),
            ),
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Text('此范围暂无变更记录。', style: ui(13, c: d.ink2)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final item = rows[index];
                        if (item is String) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                            child: Text(
                              item,
                              style: ui(11.5, w: 600, c: d.ink3),
                            ),
                          );
                        }
                        final row = item as ChangeRecord;
                        final on = row.id == record?.id;
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: busy
                              ? null
                              : () => setState(() {
                                  selected = row.id;
                                  error = '';
                                }),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 2),
                            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                            decoration: BoxDecoration(
                              color: on ? d.surface : null,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: on ? d.shadow1 : null,
                              border: Border(
                                left: BorderSide(
                                  color: on ? d.accent : Colors.transparent,
                                  width: 2.5,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Dot(row.applied ? d.add : d.ink3),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        row.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: ui(12.5, w: 600, c: d.ink),
                                      ),
                                      Text(
                                        '${row.time == null ? '' : '${clock(row.time!)} · '}${row.category} · 版本 ${row.version}',
                                        style: ui(11.5, c: d.ink2),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
      final panel = detail == null
          ? Center(
              child: Text('选择一条记录查看修改前后。', style: ui(13, c: d.ink3)),
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(record!.title, style: ui(16, w: 650, c: d.ink)),
                      statusTag(record),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${record.category} · 版本 ${record.version} · ${record.time == null ? '时间未记录' : '${dayLabel(record.time!)} ${clock(record.time!)}'} · ${detail.fields.length} 项字段变化',
                    style: ui(12, c: d.ink2),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      DeskButton(
                        '撤销此次修改',
                        icon: Icons.undo_rounded,
                        disabledReason: '只能撤销该领域当前一步',
                        onPressed: busy || !record.canUndo
                            ? null
                            : () => undo(detail),
                      ),
                      if (widget.history is RedoChangeHistoryService)
                        DeskButton(
                          '重做此次修改',
                          icon: Icons.redo_rounded,
                          disabledReason: '只能重做紧接当前一步之后的已撤销记录',
                          onPressed: busy || !record.canRedo
                              ? null
                              : () => undo(detail, redo: true),
                        ),
                      DeskButton(
                        '前往编辑',
                        quiet: true,
                        icon: Icons.open_in_new_rounded,
                        onPressed: busy
                            ? null
                            : () => widget.openEditor(
                                record.bookId,
                                record.destination,
                              ),
                      ),
                    ],
                  ),
                  if (!record.canUndo && !record.canRedo)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '只能撤销该领域当前一步，或重做紧接其后的已撤销记录。',
                        style: ui(11.5, c: d.ink3),
                      ),
                    ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DeskNote(error, tone: Tone.pen),
                  ],
                  SizedBox(
                    height: 12,
                    child: busy
                        ? const Center(
                            child: LinearProgressIndicator(minHeight: 2),
                          )
                        : null,
                  ),
                  Expanded(
                    child: record.domain == '章节'
                        ? HistoryTreeComparison(
                            history: widget.history,
                            detail: detail,
                          )
                        : LayoutBuilder(
                            builder: (context, c) => c.maxWidth >= 640
                                ? SingleChildScrollView(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: comparison(detail, false),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: comparison(detail, true),
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView(
                                    children: [
                                      comparison(detail, false),
                                      const SizedBox(height: 10),
                                      comparison(detail, true),
                                    ],
                                  ),
                          ),
                  ),
                ],
              ),
            );
      return Material(
        color: d.canvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: d.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: d.line)),
              ),
              child: Row(
                children: [
                  Text('变更记录', style: ui(16, w: 650, c: d.ink)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '查看每一步影响，再选择撤销。原文件始终保留。',
                      overflow: TextOverflow.ellipsis,
                      style: ui(12, c: d.ink3),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => c.maxWidth >= 860
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            width: (c.maxWidth * .38).clamp(300.0, 420.0),
                            decoration: BoxDecoration(
                              border: Border(right: BorderSide(color: d.line)),
                            ),
                            child: list,
                          ),
                          Expanded(
                            child: Material(color: d.surface, child: panel),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 2, child: list),
                          Divider(height: 1, color: d.line),
                          Expanded(
                            flex: 3,
                            child: Material(color: d.surface, child: panel),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
