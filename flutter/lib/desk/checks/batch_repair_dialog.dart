// 批量修复同类问题（V9）：读取同一类别的全部可直接应用方案 → 勾选 → 合并预览 → 确认应用。
// 仍走“预览 → 确认 → 复查”：应用前展示合并后的修改清单，应用后由调用方重新检查。
// 漏识别的标题还可把所选项批量标记为“不是标题”（CHK-052）：只写审阅结论，不改正文，可逐项撤销。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../repair/repair_impact.dart';
import '../tokens.dart';

/// 返回实际应用的修改数与标记为正常的项数；取消时返回 null。
class BatchRepairDialog extends StatefulWidget {
  const BatchRepairDialog({
    super.key,
    required this.session,
    required this.page,
    required this.category,
    required this.label,
    this.markNormal,
  });
  final ChapterSession session;
  final ChapterPage page;
  final String category, label;

  /// 把所选项写为“本项已核实正常”；为空时不提供该操作。
  final Future<void> Function(List<String> ids)? markNormal;
  @override
  State<BatchRepairDialog> createState() => _BatchRepairDialogState();
}

class _BatchRepairDialogState extends State<BatchRepairDialog> {
  ChapterRepairOptions? options;
  List<ChapterRepairChange> changes = const [];
  final selected = <String>{};
  ChapterRepairPlan? plan;
  bool loading = true, busy = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final prefix = '${widget.category}:';
      final session = widget.session;
      final result = session is TargetedChapterRepairSession
          ? await (session as TargetedChapterRepairSession).repairsForIssue(
              widget.page,
              prefix,
            )
          : await session.repairs(widget.page);
      if (!mounted) return;
      final list = result.changes.where((c) => c.id.startsWith(prefix)).toList()
        ..sort((a, b) => a.line.compareTo(b.line));
      setState(() {
        options = result;
        changes = list;
        selected
          ..clear()
          ..addAll(list.map((c) => c.id));
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '方案读取失败，请重新检查后再试。'));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> preview() async {
    final source = options;
    if (source == null || selected.isEmpty || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final next = await widget.session.previewRepairs(
        source,
        Set.of(selected),
      );
      if (mounted) setState(() => plan = next);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '无法生成合并预览，请重新检查后再试。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    final current = plan;
    if (current == null || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.session.confirm(current.preview);
      if (mounted) {
        Navigator.pop(context, (applied: current.changes.length, marked: 0));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = deskErrorText(e, '修改未应用，书稿可能已变化，请重新预览。');
          plan = null;
          busy = false;
        });
      }
    }
  }

  Future<void> markSelected() async {
    final mark = widget.markNormal;
    if (mark == null || selected.isEmpty || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final ids = [
        for (final c in changes)
          if (selected.contains(c.id)) c.id,
      ];
      await mark(ids);
      if (mounted) Navigator.pop(context, (applied: 0, marked: ids.length));
    } catch (e) {
      if (mounted) {
        setState(() {
          error = deskErrorText(e, '未能写入审阅结论，请重新检查后再试。');
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final total = options?.total ?? 0;
    final capped = total > changes.length;
    final reviewing = plan != null;
    return DeskDialog(
      title: '批量修复：${widget.label}',
      subtitle: reviewing
          ? '已合并为一次修改。确认后应用到编辑稿（不改原稿），可在变更记录中撤销。'
          : '列出这一类问题中可以直接应用的方案。默认全选，可取消个别项；先预览再应用。',
      closeTooltip: '取消',
      width: 760,
      height: 600,
      busy: busy,
      footerLeft: Text(
        reviewing
            ? '将应用 ${plan!.changes.length} 项修改'
            : loading
            ? '正在读取方案…'
            : capped
            ? '已选 ${selected.length} / 本次 ${changes.length} 项（共 $total 项，应用后可再次批量处理剩余部分）'
            : '已选 ${selected.length} / ${changes.length} 项',
        style: ui(12, c: d.ink3),
      ),
      actions: [
        DeskButton(
          reviewing ? '返回调整' : '取消',
          quiet: true,
          onPressed: busy
              ? null
              : reviewing
              ? () => setState(() => plan = null)
              : () => Navigator.pop(context),
        ),
        if (!reviewing &&
            widget.markNormal != null &&
            widget.category == 'unrecognized-heading')
          DeskButton(
            '标记所选 ${selected.length} 项为不是标题',
            key: const ValueKey('batch-mark-normal'),
            icon: Icons.do_not_disturb_on_outlined,
            tooltip: '只写审阅结论“本项已核实正常”，不改正文；可在“审阅此项”中逐项撤销',
            disabledReason: '至少选择一项',
            onPressed: busy || loading || selected.isEmpty
                ? null
                : markSelected,
          ),
        if (reviewing)
          DeskButton(
            '应用 ${plan!.changes.length} 项修改',
            primary: true,
            icon: Icons.check_rounded,
            onPressed: busy ? null : apply,
          )
        else
          DeskButton(
            '预览 ${selected.length} 项修改',
            primary: true,
            icon: Icons.preview_outlined,
            disabledReason: '至少选择一项',
            onPressed: busy || loading || selected.isEmpty ? null : preview,
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error.isNotEmpty) ...[
            DeskNote(error, tone: Tone.pen),
            const SizedBox(height: 8),
          ],
          if (reviewing) ...[
            RepairImpactLine(session: widget.session, plan: plan!),
            const SizedBox(height: 10),
          ],
          // 原“全部选择 / 全部取消”按钮改为表头三态勾选（G-067）。
          if (!reviewing && changes.isNotEmpty)
            SelectAllHeader(
              selected: selected.length,
              total: changes.length,
              padding: const EdgeInsets.only(left: 6),
              onChanged: busy ? null : (v) => setMany(changes, v),
              trailing: [Text('按书稿行号排列', style: ui(11.5, c: d.ink3))],
            ),
          Expanded(
            child: SelectionKeys(
              hasSelection: !reviewing && selected.isNotEmpty,
              onSelectAll: reviewing || busy
                  ? null
                  : () => setMany(changes, true),
              onClear: reviewing || busy ? null : () => setMany(changes, false),
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : changes.isEmpty
                  ? Center(
                      child: Text(
                        '这一类问题暂无可直接应用的方案；请逐项核对正文或调整识别规则。',
                        textAlign: TextAlign.center,
                        style: ui(12.5, c: d.ink2),
                      ),
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: d.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: d.line),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ListView.builder(
                          itemCount: reviewing
                              ? plan!.changes.length
                              : changes.length,
                          itemBuilder: (_, i) => row(
                            reviewing ? plan!.changes[i] : changes[i],
                            reviewing,
                            i,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  final range = RangeSelection();
  void setMany(Iterable<ChapterRepairChange> values, bool value) =>
      setState(() {
        final ids = values.map((c) => c.id);
        value ? selected.addAll(ids) : selected.removeAll(ids);
      });

  Widget row(ChapterRepairChange change, bool reviewing, int index) {
    final d = context.desk;
    final on = selected.contains(change.id);
    // Shift+点击：上次点击到本行之间统一设成同一状态（G-067）。
    void toggle() =>
        setMany([for (final i in range.span(index)) changes[i]], !on);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: reviewing || busy ? null : toggle,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: d.line)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!reviewing)
                Checkbox(
                  value: on,
                  visualDensity: VisualDensity.compact,
                  onChanged: busy ? null : (_) => toggle(),
                )
              else
                const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '第 ${change.line} 行',
                    style: mono(10.5, c: d.ink3),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(change.title, style: ui(12.5, w: 600, c: d.ink)),
                      const SizedBox(height: 2),
                      Text(
                        change.before,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ui(12, c: d.ink3),
                      ),
                      Text(
                        '→ ${change.after.split('\n').first}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ui(12, c: d.tone(Tone.ok).$1),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
