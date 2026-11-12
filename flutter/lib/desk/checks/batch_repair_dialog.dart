// 批量修复：不给类别时是全书的“一键修复”，给类别时只修这一类。
// 批量修复同类问题：读取同一类别的全部可直接应用方案 → 勾选 → 合并预览 → 确认应用。
// 仍走“预览 → 确认 → 复查”：应用前展示合并后的修改清单，应用后由调用方重新检查。
// 漏识别的标题还可把所选项批量标记为“不是标题”：只写审阅结论，不改正文，可逐项撤销。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../chapters/dialogs/candidate_dialog.dart';

import '../../application/chapter_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import 'repair_copy.dart';
import 'repair_impact.dart';

/// 返回实际应用的修改数与标记为正常的项数；取消时返回 null。
class BatchRepairDialog extends StatefulWidget {
  const BatchRepairDialog({
    super.key,
    required this.session,
    this.page,
    this.category,
    this.focus,
    this.label = '',
    this.markNormal,
  });

  /// 按成片的原因取方案（[ChapterIssueCause.focus]）；给了它就不再按 [category] 取。
  final String? focus;
  final ChapterSession session;

  /// 读取方案用的结构；不给时弹窗自己读。
  final ChapterPage? page;

  /// 只修这一类；为空时修全书（一键修复）。
  final String? category;
  final String label;

  /// 把所选项写为“本项已核实正常”；为空时不提供该操作。
  final Future<void> Function(List<String> ids)? markNormal;
  @override
  State<BatchRepairDialog> createState() => _BatchRepairDialogState();
}

class _BatchRepairDialogState extends State<BatchRepairDialog> {
  ChapterRepairOptions? options;
  ChapterPage? tree;
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
      final category = widget.category;
      final prefix = '$category:';
      final session = widget.session;
      final page = widget.page ?? await session.read(0);
      final focus = widget.focus;
      final result =
          (focus != null || category != null) &&
              session is TargetedChapterRepairSession
          ? await (session as TargetedChapterRepairSession).repairsForIssue(
              page,
              focus ?? prefix,
            )
          : await session.repairs(page);
      if (!mounted) return;
      final list =
          result.changes
              .where(
                (c) =>
                    focus != null ||
                    category == null ||
                    c.id.startsWith(prefix),
              )
              .toList()
            ..sort((a, b) => a.line.compareTo(b.line));
      setState(() {
        tree = page;
        options = result;
        changes = list;
        // 修一类时全选；修全书时只选安全的，要判断的留给用户勾。
        selected
          ..clear()
          ..addAll(
            list
                .where(
                  (c) => focus != null || category != null || c.recommended,
                )
                .map((c) => c.id),
          );
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

  /// 不改当前稿，把修改或当前稿另存成一份 TXT。
  Future<void> saveCopy(ChapterEditPreview preview) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await saveRepairCopy(context, widget.session, preview);
    } catch (e) {
      if (mounted) setState(() => error = deskErrorText(e, '另存没有完成，请重试。'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveCurrentCopy() async {
    final page = tree;
    if (page == null || widget.session is! ChapterCopySession) return;
    await saveCopy(
      await (widget.session as ChapterCopySession).previewCurrentCopy(page),
    );
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
          error = deskErrorText(e, '未能写入核对结论，请重新检查后再试。');
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
    final whole = widget.category == null && widget.focus == null;
    final canCopy = widget.session is ChapterCopySession;
    // 全书修复时，其余问题没有自动方案，要到“问题”里逐条看。
    final manual = whole ? (options?.report.total ?? 0) - changes.length : 0;
    // 读完了但没有可用的方案：不留点不了的预览按钮。
    final nothing = !loading && error.isEmpty && changes.isEmpty && !reviewing;
    return DeskDialog(
      title: whole ? '一键修复' : '批量修复：${widget.label}',
      subtitle: reviewing
          ? '已合并为一次修改。确认后应用到草稿（不改原稿），可在变更记录中撤销。'
          : whole
          ? '列出全书可以直接应用的方案。安全的已勾选，需要你判断的默认不选。'
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
            : nothing
            ? ''
            : capped
            ? '已选 ${selected.length} / 本次 ${changes.length} 项（共 $total 项，应用后可再次批量处理剩余部分）'
            : '已选 ${selected.length} / ${changes.length} 项',
        style: ui(12, c: d.ink3),
      ),
      actions: [
        if (!nothing)
          DeskButton(
            reviewing ? '返回调整' : '取消',
            key: const ValueKey('batch-close'),
            quiet: true,
            onPressed: busy
                ? null
                : reviewing
                ? () => setState(() => plan = null)
                : () => Navigator.pop(context),
          ),
        if (reviewing && canCopy)
          DeskButton(
            '另存修订 TXT',
            key: const ValueKey('batch-save-copy'),
            icon: Icons.save_alt_rounded,
            quiet: true,
            onPressed: busy ? null : () => saveCopy(plan!.preview),
          ),
        if (!reviewing && whole && canCopy)
          DeskButton(
            '另存当前稿 TXT',
            key: const ValueKey('batch-save-current'),
            icon: Icons.save_alt_rounded,
            quiet: true,
            onPressed: busy || tree == null ? null : saveCurrentCopy,
          ),
        if (!reviewing &&
            widget.markNormal != null &&
            widget.category == 'unrecognized-heading')
          DeskButton(
            '标记所选 ${selected.length} 项为不是标题',
            key: const ValueKey('batch-mark-normal'),
            icon: Icons.do_not_disturb_on_outlined,
            tooltip: '只写核对结论“本项核对无误”，不改正文；可在“标记结论”中逐项撤销',
            disabledReason: '至少选择一项',
            onPressed: busy || loading || selected.isEmpty
                ? null
                : markSelected,
          ),
        if (nothing)
          DeskButton(
            '知道了',
            key: const ValueKey('batch-close'),
            primary: true,
            onPressed: () => Navigator.pop(context),
          )
        else if (reviewing)
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
            Row(
              children: [
                Expanded(
                  child: RepairImpactLine(session: widget.session, plan: plan!),
                ),
                DeskButton(
                  '浏览完整结构与正文',
                  key: const ValueKey('batch-browse'),
                  icon: Icons.account_tree_outlined,
                  quiet: true,
                  onPressed: busy || tree == null
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => ChapterCandidateDialog(
                            session: widget.session,
                            preview: plan!.preview,
                            originalPage: tree!,
                            title: '修复前后核对',
                            readOnly: true,
                          ),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (!reviewing && manual > 0 && changes.isNotEmpty) ...[
            Text(
              '另有 $manual 个问题没有自动方案，要在“问题”里逐条核对。',
              key: const ValueKey('batch-manual-note'),
              style: ui(12, c: d.ink2),
            ),
            const SizedBox(height: 8),
          ],
          // 原“全部选择 / 全部取消”按钮改为表头三态勾选。
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
                        whole
                            ? manual > 0
                                  ? '没有可以自动修复的问题。\n另有 $manual 个问题要在“问题”里逐条核对。'
                                  : '没有可以自动修复的问题。'
                            : '这一类问题暂无可直接应用的方案；请逐项核对正文或调整识别规则。',
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
    // Shift+点击：上次点击到本行之间统一设成同一状态。
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              change.title,
                              style: ui(12.5, w: 600, c: d.ink),
                            ),
                          ),
                          if (!change.recommended) ...[
                            const SizedBox(width: 8),
                            Text('需要你判断', style: ui(11, c: d.warn)),
                          ],
                        ],
                      ),
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
