// 修复方案（CH-134–172）：四步流程“修复范围 → 方案内容 → 修复前后核对 → 复查结果”，另有逐项提示。
// 生成方案、预览、确认应用、复查、撤销的会话调用逐行沿用 V3 前的 ChapterRepairPage；本文件只重写视图。
// 设计：design_review_v37/d2_repair.dart（D2-G/H）。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart'
    show DeskButton, RangeSelection, SelectAllHeader;
import '../chapters/dialogs/body_compare_dialog.dart';
import '../chapters/dialogs/target_dialog.dart';
import '../chapters/issue_marks.dart' show severityTone;
import '../checks/evidence_view.dart';
import '../pending/pending_changes.dart';
import '../shell/page_menu.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'repair_impact.dart';
import 'repair_states.dart';

class ChapterRepairPage extends StatefulWidget {
  const ChapterRepairPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.onReturn,
    required this.onEdit,
    this.guided = false,
    this.initialIssueId,
    this.initialCategory,
    this.onCatalog,
  });
  final LibraryService library;
  final String bookId;
  final bool guided;
  final String? initialIssueId, initialCategory;
  final VoidCallback? onCatalog;
  final VoidCallback onReturn;
  final void Function(ChapterIssue) onEdit;
  @override
  State<ChapterRepairPage> createState() => _ChapterRepairPageState();
}

class _ChapterRepairPageState extends State<ChapterRepairPage>
    with PendingReporter<ChapterRepairPage> {
  late final session = widget.library.openChapters(widget.bookId);
  late bool guided = widget.guided;
  ChapterPage? structure;
  ChapterRepairOptions? options;
  ChapterIssuePage? report;
  ChapterRepairPlan? plan;
  ChapterRepairPlan? committedPlan;
  ChapterIssuePage? completedReport;
  Set<String> selected = {};
  ChapterIssue? current;
  String excerpt = '', error = '';
  late String? focusedIssue = widget.initialIssueId;
  late String? scopeCategory = widget.initialCategory;
  bool busy = false, reviewing = false, applied = false;
  int appliedCount = 0;
  bool stale = false;
  bool submissionFailed = false;
  String submissionPhase = '';

  @override
  void initState() {
    super.initState();
    refresh();
  }

  // ---------------------------------------------------------------- 流程（逐行沿用）

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await operation();
    } catch (e) {
      if (mounted && e is ChapterStateChanged && !applied) {
        setState(() => stale = true);
      }
      if (mounted) {
        setState(() => error = deskErrorText(e, '操作没有完成。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() => run(() async {
    // Never leave a successful old check visible while a new check can fail.
    setState(() {
      options = null;
      report = null;
      submissionFailed = false;
      submissionPhase = '';
    });
    final page = await session.read(0);
    final next = focusedIssue != null && session is TargetedChapterRepairSession
        ? await (session as TargetedChapterRepairSession).repairsForIssue(
            page,
            focusedIssue!,
          )
        : scopeCategory != null && session is TargetedChapterRepairSession
        ? await (session as TargetedChapterRepairSession).repairsForIssue(
            page,
            '$scopeCategory:',
          )
        : await session.repairs(page);
    var checked = next.report;
    if (focusedIssue != null || scopeCategory != null) {
      var offset = 0;
      do {
        checked = session is FilteredChapterSession
            ? await (session as FilteredChapterSession).filteredIssues(
                page,
                offset,
                effective: true,
                category: scopeCategory,
              )
            : await session.issues(page, offset, effective: true);
        if (focusedIssue == null ||
            checked.items.any((i) => i.id == focusedIssue)) {
          break;
        }
        offset += 50;
      } while (offset < checked.total);
    }
    if (!mounted) return;
    setState(() {
      structure = page;
      options = next;
      report = checked;
      selected = next.changes
          .where(
            (c) => focusedIssue == null ? c.recommended : c.id == focusedIssue,
          )
          .map((c) => c.id)
          .toSet();
      plan = null;
      committedPlan = null;
      completedReport = null;
      reviewing = false;
      applied = false;
      stale = false;
      current = null;
      excerpt = '';
    });
    if (guided && checked.items.isNotEmpty) {
      final target = focusedIssue == null
          ? checked.items.first
          : checked.items.where((i) => i.id == focusedIssue).firstOrNull;
      if (target != null) {
        await locate(target);
      } else {
        setState(() => error = '原问题已不在当前检查结果中，请返回问题列表查看最新结果。');
      }
    }
  });

  Future<void> locate(ChapterIssue issue) async {
    setState(() {
      current = issue;
      excerpt = '';
    });
    if (session is TargetedChapterRepairSession &&
        options?.changes.any((c) => c.id == issue.id) != true) {
      final focused = await (session as TargetedChapterRepairSession)
          .repairsForIssue(structure!, issue.id);
      if (mounted) setState(() => options = focused);
    }
    final text = issue.lines.isEmpty
        ? '此项没有可定位的文本行。'
        : await session.issueSource(report!, issue);
    if (mounted) setState(() => excerpt = text);
  }

  Future<void> nextIssue(int delta) => run(() async {
    if (report == null || report!.total == 0) return;
    final index = current == null ? 0 : report!.items.indexOf(current!);
    var target = index + delta;
    if (target >= report!.items.length || target < 0) {
      final offset = report!.offset + (delta > 0 ? 50 : -50);
      final next = session is FilteredChapterSession
          ? await (session as FilteredChapterSession).filteredIssues(
              structure!,
              offset,
              effective: true,
              category: report!.categoryFilter,
              severity: report!.severityFilter,
            )
          : await session.issues(structure!, offset, effective: true);
      if (!mounted) return;
      setState(() => report = next);
      target = delta > 0 ? 0 : next.items.length - 1;
    }
    await locate(report!.items[target]);
  });

  Future<void> prepare({String? issueId}) => run(() async {
    final next =
        issueId == null && selected.isEmpty && session is ChapterCopySession
        ? ChapterRepairPlan(
            await (session as ChapterCopySession).previewCurrentCopy(
              structure!,
            ),
            const [],
          )
        : await session.previewRepairs(
            options!,
            issueId == null ? selected : {issueId},
          );
    if (mounted) {
      setState(() {
        plan = next;
        reviewing = true;
      });
    }
  });

  Future<void> commit() => run(() async {
    try {
      await session.confirm(plan!.preview);
    } catch (e) {
      if (mounted && e is! ChapterStateChanged) {
        setState(() {
          submissionFailed = true;
          submissionPhase = '应用方案';
        });
      }
      rethrow;
    }
    if (!mounted) return;
    setState(() {
      applied = true;
      committedPlan = plan;
      appliedCount = plan!.changes.length;
      reviewing = false;
      report = null;
      completedReport = null;
    });
    // A failed recheck must never offer to submit the consumed candidate again.
    await checkCommitted();
  });

  Future<void> retryCheck() => run(checkCommitted);

  Future<void> checkCommitted() async {
    try {
      final page = await session.read(0);
      final checked = await session.issues(page, 0, effective: true);
      if (mounted) {
        setState(() {
          structure = page;
          report = checked;
          completedReport = checked;
          submissionFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          submissionFailed = true;
          submissionPhase = '提交后的复查';
        });
      }
      rethrow;
    }
  }

  Future<void> inspectResult(ChapterIssuePage page, ChapterIssue issue) =>
      run(() async {
        final next = await session.repairs(structure!);
        if (!mounted) return;
        setState(() {
          options = next;
          report = page;
          guided = true;
          applied = false;
        });
        await locate(issue);
      });

  /// “未纳入自动修复”中的单项“逐项处理”：与“逐项提示修复”相同，只是直接定位到该项。
  Future<void> guide(ChapterIssue? issue) => run(() async {
    setState(() {
      guided = true;
      report = options!.report;
    });
    await locate(issue ?? report!.items.first);
  });

  Future<void> saveCurrentCopy() => run(() async {
    final preview = await (session as ChapterCopySession).previewCurrentCopy(
      structure!,
    );
    if (!mounted) return;
    setState(() {
      plan = ChapterRepairPlan(preview, const []);
      reviewing = true;
      applied = false;
    });
  });

  // ---------------------------------------------------------------- 外框

  int get step => applied
      ? 3
      : reviewing
      ? 2
      : 1;

  Widget header(BoxConstraints c) {
    final d = context.desk;
    Widget stepDot(int i, String text) {
      final done = i < step, on = i == step;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? d.accent : null,
              border: done
                  ? null
                  : Border.all(
                      color: on ? d.accent : d.lineStrong,
                      width: on ? 2 : 1.4,
                    ),
            ),
            child: done
                ? Icon(Icons.check_rounded, size: 13, color: d.accentInk)
                : Text(
                    '${i + 1}',
                    style: ui(11, w: 600, c: on ? d.ink : d.ink3),
                  ),
          ),
          const SizedBox(width: 7),
          Text(
            text,
            style: ui(
              12.5,
              w: on ? 620 : 480,
              c: on ? d.ink : (done ? d.ink2 : d.ink3),
            ),
          ),
        ],
      );
    }

    Widget bar(bool done) => Container(
      width: 28,
      height: 1.5,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: done ? d.accent : d.lineStrong,
    );
    final scope = <bool, String>{
      false: '全书',
      if (current != null || scopeCategory != null) true: '同类问题',
    };
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: d.canvas,
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('修复范围', style: ui(12, c: d.ink3)),
          KeyedSubtree(
            key: const ValueKey('repair-scope'),
            child: DeskSegmented<bool>(
              value: scopeCategory != null,
              options: scope,
              onChanged: busy
                  ? null
                  : (sameKind) {
                      if (sameKind && current == null) return;
                      setState(() {
                        scopeCategory = sameKind ? current!.category : null;
                        focusedIssue = null;
                        guided = false;
                      });
                      refresh();
                    },
            ),
          ),
          if (c.maxWidth >= 1100) ...[
            const SizedBox(width: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                stepDot(0, '修复范围'),
                bar(step > 0),
                stepDot(1, guided && !applied && !reviewing ? '逐项提示' : '方案内容'),
                bar(step > 1),
                stepDot(2, '修复前后核对'),
                bar(step > 2),
                stepDot(3, '复查结果'),
              ],
            ),
            const SizedBox(width: 14),
          ],
          if (session is ChapterCopySession)
            DeskButton(
              '另存当前稿 TXT',
              quiet: true,
              icon: Icons.save_alt_rounded,
              onPressed: busy || structure == null ? null : saveCurrentCopy,
            ),
          if (committedPlan != null && !applied)
            DeskButton(
              '返回复查结果',
              quiet: true,
              onPressed: busy
                  ? null
                  : () {
                      setState(() {
                        applied = true;
                        reviewing = false;
                        report = completedReport;
                      });
                    },
            ),
          DeskButton(
            '返回章节',
            icon: Icons.arrow_back_rounded,
            onPressed: busy ? null : widget.onReturn,
          ),
        ],
      ),
    );
  }

  Widget footer(List<Widget> left, List<Widget> right, {String? note}) {
    final d = context.desk;
    return Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: d.surface,
        border: Border(top: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: left,
            ),
          ),
          if (note != null) ...[
            Flexible(
              child: Text(
                note,
                maxLines: 2,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: d.ink3),
              ),
            ),
            const SizedBox(width: 12),
          ],
          for (var i = 0; i < right.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            right[i],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    // G-061：已生成、尚未应用的修复方案登记为待应用。
    reportPending(
      plan != null && !applied && plan!.changes.isNotEmpty
          ? PendingChange(
              token: plan!,
              domain: '章节修复方案',
              summary: '${plan!.changes.length} 项修复',
              location: bookPageLocation(
                widget.bookId,
                'repairs',
                query: {'mode': guided ? 'guided' : 'auto'},
              ),
              bookId: widget.bookId,
              stale: stale,
              discard: () {
                if (mounted && !busy) setState(() => plan = null);
              },
              regenerate: stale
                  ? null
                  : () {
                      if (mounted && !busy) prepare();
                    },
            )
          : null,
    );
    return Material(
      color: d.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: d.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, c) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header(c),
            SizedBox(
              height: 2,
              child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
            ),
            if (error.isNotEmpty && !stale && !submissionFailed)
              Container(
                margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: d.penSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline_rounded, size: 16, color: d.pen),
                    const SizedBox(width: 8),
                    Text(
                      applied ? '修复已应用，复查未完成' : '操作未完成',
                      style: ui(12.5, w: 620, c: d.pen),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(error, style: ui(12.5, c: d.ink)),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: stale
                  ? ChapterRepairStale(
                      changes: plan?.changes ?? options?.changes ?? const [],
                      issueCount: options?.report.total ?? 0,
                      onRefresh: busy ? null : refresh,
                      onReturn: busy ? null : widget.onReturn,
                    )
                  : submissionFailed
                  ? ChapterRepairFailure(
                      applied: applied,
                      phase: submissionPhase,
                      detail: error,
                      changeCount: plan?.changes.length ?? 0,
                      onRetry: busy
                          ? null
                          : applied
                          ? retryCheck
                          : refresh,
                      onReturn: busy ? null : widget.onReturn,
                    )
                  : options == null
                  ? Center(
                      child: busy
                          ? Text('正在检查当前草稿…', style: ui(13, c: d.ink2))
                          : DeskButton('重新检查', onPressed: refresh),
                    )
                  : applied
                  ? resultView(c)
                  : reviewing
                  ? differenceView()
                  : options!.report.total == 0 && structure!.total > 0
                  ? ChapterCheckClean(
                      nodeCount: structure!.total,
                      onReturn: busy ? null : widget.onReturn,
                      onRefresh: busy ? null : refresh,
                    )
                  : guided
                  ? guidedView(c)
                  : automaticView(c),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 方案内容

  Widget stat(String value, String label, Color color, {double width = 138}) {
    final d = context.desk;
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: d.sunken,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: ui(17, w: 680, c: color)),
          Text(label, style: ui(11.5, c: d.ink2)),
        ],
      ),
    );
  }

  Widget box(Widget head, List<Widget> rows) {
    final d = context.desk;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [head, ...rows],
        ),
      ),
    );
  }

  Widget boxHead(
    Widget lead,
    String title,
    Widget tag,
    String note, {
    String? right,
  }) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          lead,
          const SizedBox(width: 10),
          Text(title, style: ui(13.5, w: 650, c: d.ink)),
          const SizedBox(width: 8),
          tag,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: d.ink3),
            ),
          ),
          if (right != null) Text(right, style: ui(12, c: d.ink2)),
        ],
      ),
    );
  }

  /// 分类标题；给出 [items] 时左侧是本类的三态勾选框（G-067）。
  Widget category(
    String text,
    int count, {
    Widget? action,
    List<ChapterRepairChange>? items,
  }) {
    final d = context.desk;
    final label = Text(text, style: ui(12.5, w: 600, c: d.ink2));
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: EdgeInsets.fromLTRB(items == null ? 16 : 8, 4, 16, 4),
      color: d.sunken,
      child: Row(
        children: [
          Expanded(
            child: items == null
                ? label
                : SelectAllHeader(
                    selected: items
                        .where((c) => selected.contains(c.id))
                        .length,
                    total: items.length,
                    compact: false,
                    height: 36,
                    padding: EdgeInsets.zero,
                    onChanged: busy ? null : (v) => setMany(items, v),
                    body: label,
                  ),
          ),
          if (action != null) ...[action, const SizedBox(width: 10)],
          Text('$count', style: ui(12, c: d.ink3)),
        ],
      ),
    );
  }

  void toggle(ChapterRepairChange change, bool? value) => setState(() {
    if (value == true) {
      selected.add(change.id);
    } else {
      selected.remove(change.id);
    }
    plan = null;
  });

  final range = RangeSelection();

  /// 一次勾选或取消多项（分类全选、Shift 选一段、Ctrl+A；G-067）。
  void setMany(Iterable<ChapterRepairChange> items, bool value) => setState(() {
    final ids = items.map((c) => c.id);
    selected = value ? {...selected, ...ids} : selected.difference(ids.toSet());
    plan = null;
  });

  /// [order] 为页面上的显示顺序，Shift+点击按它取一段。
  Widget changeRow(
    ChapterRepairChange change,
    List<ChapterRepairChange> order,
    int index,
  ) {
    final d = context.desk;
    final on = selected.contains(change.id);
    void toggleSpan(bool value) =>
        setMany([for (final i in range.span(index)) order[i]], value);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: busy ? null : () => toggleSpan(!on),
            child: Row(
              children: [
                Checkbox(
                  key: ValueKey('repair-change-${change.id}'),
                  value: on,
                  onChanged: busy ? null : (v) => toggleSpan(v == true),
                ),
                SizedBox(
                  width: 66,
                  child: Text('${change.line}', style: mono(11, c: d.ink3)),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(change.title, style: ui(12.5, w: 600, c: d.ink)),
                      const SizedBox(height: 2),
                      Text(
                        change.recommended ? '可直接判断，已默认勾选' : '需要你核对后选择',
                        style: ui(11.5, c: d.ink3),
                      ),
                    ],
                  ),
                ),
                if (!on && change.recommended)
                  const DeskTag('已排除', Tone.neutral),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 40, top: 6),
            child: comparison(change),
          ),
        ],
      ),
    );
  }

  Widget comparison(ChapterRepairChange change) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: excerptBox('修改前', change.before, d.delSoft, d.del)),
            const SizedBox(width: 10),
            Expanded(child: excerptBox('修改后', change.after, d.addSoft, d.add)),
          ],
        ),
        if (change.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '此处为节选；通过“浏览完整结构与正文”核对全部内容。',
              style: ui(11.5, c: d.ink3),
            ),
          ),
      ],
    );
  }

  Widget excerptBox(String label, String text, Color bg, Color fg) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: ui(11, w: 620, c: fg)),
          const SizedBox(height: 4),
          SelectableText(text, style: serif(13.5, c: d.ink, h: 1.7)),
        ],
      ),
    );
  }

  Widget automaticView(BoxConstraints c) {
    final d = context.desk;
    final numeric = scopeCategory == 'unrecognized-heading';
    final changes = options!.changes;
    final groups = <String, List<ChapterRepairChange>>{};
    for (final change in changes) {
      (groups[change.id.split(':').first] ??= []).add(change);
    }
    // 页面上的显示顺序（按分类），Shift+点击按它取一段。
    final shown = [for (final items in groups.values) ...items];
    final pendingIssues = options!.report.items
        .where((i) => !selected.contains(i.id))
        .toList();
    final remaining = options!.report.total - selected.length;
    final wide = c.maxWidth >= 1000;
    // R3-04：没有可自动处理的项、只剩要逐项决定的问题时，引导去逐项处理，
    // 不再显示“0 / 0”和看起来能点的“预览”主按钮。
    final manualOnly = !numeric && changes.isEmpty && pendingIssues.isNotEmpty;
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('本次所选修改', style: ui(12, w: 600, c: d.ink2)),
        const SizedBox(height: 8),
        if (manualOnly)
          Text(
            '没有可自动处理的项；${pendingIssues.length} 项需要你逐项决定。',
            key: const ValueKey('repair-manual-only-summary'),
            style: ui(12.5, c: d.ink2, h: 1.5),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              stat('${selected.length} / ${changes.length}', '已选方案', d.ink),
              stat('$remaining', '保留待核对', remaining > 0 ? d.warn : d.ink),
            ],
          ),
        const SizedBox(height: 16),
        Text('保证', style: ui(12, w: 600, c: d.ink2)),
        const SizedBox(height: 6),
        for (final t in const [
          '原稿不覆盖，只写入编辑稿',
          '整批作为一次修改，可撤销',
          '应用后自动复查；复查失败不重复提交',
          '书稿变化后方案失效，需要重新生成',
          '不会自动补章、改号或删除疑似重复正文。',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_rounded, size: 14, color: d.add),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(t, style: ui(12, c: d.ink2)),
                ),
              ],
            ),
          ),
      ],
    );
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      children: [
        Text(
          numeric
              ? '找到 ${options!.total} 个待识别的数字标题'
              : manualOnly
              ? '没有可以自动处理的项'
              : '找到 ${options!.total} 项可选处理方案',
          style: ui(15, w: 650, c: d.ink),
        ),
        const SizedBox(height: 4),
        Text(
          numeric
              ? '把“238：以命换伤！”这样的标题收入章节目录。保留标题写法和正文；勾选后预览，再应用。'
              : manualOnly
              ? '下面的问题需要你逐项决定：每项先看前后对照，再选怎么改。点“逐项处理第一项”开始，处理完一项会带到下一项。'
              : '已勾选可直接判断的项目；需要你决定的项目不默认勾选。查看差异后，可应用到编辑稿或另存修订 TXT。',
          style: ui(12, c: d.ink2, h: 1.5),
        ),
        if (options!.total > changes.length)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '本批列出 ${changes.length} 项；应用后可继续处理剩余候选。',
              style: ui(12, c: d.ink3),
            ),
          ),
        if (!wide) ...[const SizedBox(height: 12), summary],
        const SizedBox(height: 12),
        if (!manualOnly)
          box(
            boxHead(
              Icon(Icons.checklist_rounded, size: 17, color: d.ink2),
              '方案内容',
              DeskTag('${changes.length} 项', Tone.ok),
              '',
              right: '已选 ${selected.length} / ${changes.length}',
            ),
            changes.isEmpty
                ? [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('没有可安全自动处理的章节问题', style: ui(12.5, c: d.ink2)),
                    ),
                  ]
                : [
                    for (final MapEntry(key: kind, value: items)
                        in groups.entries) ...[
                      category(
                        chapterIssueCategories[kind] ?? '章节结构',
                        items.length,
                        items: items,
                        action: numeric && kind == 'unrecognized-heading'
                            ? DeskButton(
                                selected.length == changes.length &&
                                        selected.isNotEmpty
                                    ? '取消勾选本批'
                                    : '勾选本批数字章节',
                                quiet: true,
                                onPressed: busy || changes.isEmpty
                                    ? null
                                    : () => setState(() {
                                        selected =
                                            selected.length == changes.length
                                            ? <String>{}
                                            : changes.map((c) => c.id).toSet();
                                        plan = null;
                                      }),
                              )
                            : null,
                      ),
                      for (final change in items)
                        changeRow(change, shown, shown.indexOf(change)),
                    ],
                  ],
          ),
        box(
          boxHead(
            Icon(Icons.help_outline_rounded, size: 16, color: d.warn),
            '需要你核对后选择',
            DeskTag('未纳入自动修复 $remaining 项', Tone.warn),
            '不会自动补章、改号或删除疑似重复正文。',
          ),
          [
            if (pendingIssues.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('本页没有保留待核对的问题。', style: ui(12, c: d.ink3)),
              ),
            for (final issue in pendingIssues)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: d.line)),
                ),
                child: Row(
                  children: [
                    Dot(severityTone(d, issue.severity).$1),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(issue.title, style: ui(12.5, c: d.ink)),
                          Text(issue.categoryLabel, style: ui(11.5, c: d.ink3)),
                        ],
                      ),
                    ),
                    DeskButton(
                      '逐项处理',
                      quiet: true,
                      onPressed: busy ? null : () => guide(issue),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: list),
                    Container(
                      width: 330,
                      decoration: BoxDecoration(
                        color: d.surface,
                        border: Border(left: BorderSide(color: d.line)),
                      ),
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                      child: SingleChildScrollView(child: summary),
                    ),
                  ],
                )
              : list,
        ),
        if (manualOnly)
          footer(
            [
              if (session is ChapterCopySession)
                DeskButton(
                  '预览当前稿／另存 TXT',
                  quiet: true,
                  onPressed: busy ? null : () => prepare(),
                ),
            ],
            [
              DeskButton(
                '逐项处理第一项',
                key: const ValueKey('repair-guide-first'),
                primary: true,
                icon: Icons.arrow_forward_rounded,
                onPressed: busy ? null : () => guide(null),
              ),
            ],
            note: '逐项处理时每一步都先预览，确认后才写入',
          )
        else
          footer(
            [
              DeskButton(
                '逐项提示修复',
                quiet: true,
                icon: Icons.checklist_rounded,
                onPressed: busy || options!.report.total == 0
                    ? null
                    : () => guide(null),
              ),
            ],
            [
              Text('已选 ${selected.length} 项', style: ui(12, c: d.ink2)),
              DeskButton(
                selected.isEmpty ? '预览当前稿／另存 TXT' : '查看完整差异',
                primary: true,
                icon: Icons.arrow_forward_rounded,
                onPressed:
                    busy || (selected.isEmpty && session is! ChapterCopySession)
                    ? null
                    : () => prepare(),
              ),
            ],
            note: '下一步只读预览，不写入',
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- 修复前后核对

  Widget differenceView() {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '修复差异 · ${plan!.changes.length} 项',
                    style: ui(15, w: 650, c: d.ink),
                  ),
                  const DeskTag('未应用', Tone.neutral),
                  DeskButton(
                    '浏览完整结构与正文',
                    icon: Icons.account_tree_outlined,
                    onPressed: busy
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            builder: (_) => ChapterCandidateDialog(
                              session: session,
                              preview: plan!.preview,
                              originalPage: structure!,
                              title: '修复前后核对',
                              readOnly: true,
                            ),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              RepairImpactLine(session: session, plan: plan!),
              const SizedBox(height: 6),
              Text(
                '核对本次所选修改：标题、结构和正文影响逐项列在下方。还原正文保留整句；排除完整重复章会移除明确列出的范围。原始文件保留。',
                style: ui(12, c: d.ink2, h: 1.5),
              ),
              const SizedBox(height: 12),
              if (plan!.changes.isEmpty)
                Text(
                  '本次不增加修改。可以另存当前编辑稿及配套项目，已有问题仍会保留。',
                  style: ui(12.5, c: d.ink2),
                )
              else
                for (final change in plan!.changes)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: d.surface,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: d.shadow1,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                change.title,
                                style: ui(13, w: 620, c: d.ink),
                              ),
                            ),
                            Text(
                              '第 ${change.line} 行',
                              style: mono(11, c: d.ink3),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        comparison(change),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        footer(
          [
            DeskButton(
              '返回调整',
              quiet: true,
              icon: Icons.arrow_back_rounded,
              onPressed: busy
                  ? null
                  : () => setState(() {
                      reviewing = false;
                      plan = null;
                    }),
            ),
          ],
          [
            if (session is ChapterCopySession)
              DeskButton(
                '另存修订 TXT',
                icon: Icons.save_alt_rounded,
                onPressed: busy
                    ? null
                    : () => run(() async {
                        await saveRepairCopy(context, session, plan!.preview);
                      }),
              ),
            DeskButton(
              '确认应用并复查',
              primary: true,
              icon: Icons.check_rounded,
              disabledReason: '本次没有可应用的修改',
              onPressed: busy || plan!.changes.isEmpty ? null : commit,
            ),
          ],
          note: '应用后可撤销',
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 逐项提示

  Widget guidedView(BoxConstraints c) {
    final d = context.desk;
    final canApply =
        current != null && options!.changes.any((ch) => ch.id == current!.id);
    final index = current == null
        ? 0
        : report!.offset + report!.items.indexOf(current!);
    final change = canApply
        ? options!.changes.firstWhere((ch) => ch.id == current!.id)
        : null;
    final queue = Container(
      width: 300,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              '提示与处理 · 第 ${report!.total == 0 ? 0 : index + 1} / ${report!.total} 项',
              style: ui(12, w: 600, c: d.ink2),
            ),
          ),
          Expanded(
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                itemCount: report!.items.length,
                itemBuilder: (_, i) {
                  final issue = report!.items[i];
                  final on = issue == current;
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: busy || on ? null : () => run(() => locate(issue)),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 2),
                      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                      decoration: on
                          ? BoxDecoration(
                              color: d.surface,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: d.shadow1,
                              border: Border(
                                left: BorderSide(color: d.accent, width: 2.5),
                              ),
                            )
                          : null,
                      child: Row(
                        children: [
                          Dot(severityTone(d, issue.severity).$1),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  issue.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ui(12.5, w: 600, c: d.ink),
                                ),
                                Text(
                                  '${issue.categoryLabel} · ${issue.decision == null ? '待核对' : '已审阅'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
          ),
        ],
      ),
    );
    final detail = ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      children: [
        Row(
          children: [
            if (current != null) ...[
              DeskTag(
                chapterIssueSeverities[current!.severity] ?? '提示',
                switch (current!.severity) {
                  'error' => Tone.pen,
                  'warning' => Tone.warn,
                  _ => Tone.neutral,
                },
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                current?.title ?? '没有待核对问题',
                style: ui(16, w: 650, c: d.ink),
              ),
            ),
            Text(
              '第 ${report!.total == 0 ? 0 : index + 1} / ${report!.total} 项',
              style: ui(12, c: d.ink3),
            ),
          ],
        ),
        if (current != null) ...[
          const SizedBox(height: 6),
          Text(current!.evidence, style: ui(12.5, c: d.ink2, h: 1.5)),
          const SizedBox(height: 12),
          Text('前后内容与问题位置', style: ui(12, w: 600, c: d.ink3)),
          const SizedBox(height: 8),
          IssueEvidenceView(
            session: session,
            page: report!,
            issue: current!,
            onLocate: widget.onEdit,
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: d.sunken,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_outline_rounded, size: 15, color: d.ink2),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        change?.title ?? '下一步：核对正文或参考目录',
                        style: ui(12.5, w: 620, c: d.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        change?.after ?? '编号异常不代表正文缺失。核对正文和参考目录后，再决定是否修改标题或结构。',
                        style: ui(12, c: d.ink2, h: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: c.maxWidth >= 900
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    queue,
                    Expanded(child: detail),
                  ],
                )
              : detail,
        ),
        footer(
          [
            DeskButton(
              '上一项',
              quiet: true,
              icon: Icons.chevron_left_rounded,
              onPressed: busy || index <= 0 ? null : () => nextIssue(-1),
            ),
            DeskButton(
              '暂不处理',
              quiet: true,
              onPressed: busy || index + 1 >= report!.total
                  ? null
                  : () => nextIssue(1),
            ),
            if ((current?.category == 'duplicate-content' ||
                    current?.category == 'duplicate-title' ||
                    current?.category == 'number-reset') &&
                current!.lines.isNotEmpty)
              DeskButton(
                '正文对照',
                icon: Icons.compare_outlined,
                onPressed: busy
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) => ChapterBodyCompareDialog(
                          session: session,
                          structure: structure!,
                          lines: current!.lines,
                        ),
                      ),
              ),
            if (widget.onCatalog != null)
              DeskButton(
                '依据参考目录核对',
                icon: Icons.list_alt_rounded,
                onPressed: busy ? null : widget.onCatalog,
              ),
            if (current?.entryId != null)
              DeskButton(
                '打开章节核对',
                icon: Icons.my_location_rounded,
                onPressed: busy ? null : () => widget.onEdit(current!),
              ),
          ],
          [
            DeskButton(
              '采用建议 · 查看差异',
              primary: true,
              icon: Icons.arrow_forward_rounded,
              disabledReason: '此项没有可安全自动采用的建议',
              onPressed: busy || !canApply
                  ? null
                  : () => prepare(issueId: current!.id),
            ),
          ],
          note: '采用建议仅生成待确认方案；跳过保留此问题。',
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 复查结果

  Widget resultView(BoxConstraints c) {
    final d = context.desk;
    final numeric = scopeCategory == 'unrecognized-heading';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: d.surface,
              borderRadius: BorderRadius.circular(12),
              boxShadow: d.shadow1,
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: report == null ? d.sunken : d.addSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    report == null
                        ? Icons.pending_outlined
                        : Icons.check_rounded,
                    size: 18,
                    color: report == null ? d.ink2 : d.add,
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (c.maxWidth - 360).clamp(240.0, 900.0),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已应用 $appliedCount 项修复${report == null ? '，等待复查' : '，并完成复查'}',
                        style: ui(15, w: 650, c: d.ink),
                      ),
                      const SizedBox(height: 2),
                      Text('原稿未覆盖；本次变更已写入会话草稿，可撤销。', style: ui(12, c: d.ink2)),
                    ],
                  ),
                ),
                DeskButton(
                  '撤销本次修复',
                  icon: Icons.undo_rounded,
                  onPressed: busy || committedPlan == null
                      ? null
                      : () => run(() async {
                          await session.undoConfirmed(committedPlan!.preview);
                          if (mounted) widget.onReturn();
                        }),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              stat(
                '$appliedCount',
                numeric ? '数字标题已收入目录' : '所选修改已应用',
                d.add,
                width: 160,
              ),
              stat(
                report == null ? '—' : '${report!.total}',
                report == null ? '剩余问题 · 等待复查' : '剩余问题',
                report != null && report!.total > 0 ? d.warn : d.ink,
                width: 160,
              ),
              if (numeric &&
                  (report?.categoryCounts['unrecognized-heading'] ?? 0) > 0)
                DeskButton(
                  '继续识别剩余数字章节',
                  icon: Icons.format_list_numbered_rounded,
                  onPressed: busy ? null : refresh,
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Container(
              decoration: BoxDecoration(
                color: d.surface,
                borderRadius: BorderRadius.circular(12),
                boxShadow: d.shadow1,
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                      child: Text(
                        report == null
                            ? '复查结果'
                            : '复查结果 · 仍有 ${report!.total} 项待核对',
                        style: ui(13, w: 650, c: d.ink),
                      ),
                    ),
                    Expanded(
                      child: report == null
                          ? Center(
                              child: Text('复查尚未完成', style: ui(12.5, c: d.ink2)),
                            )
                          : RepairIssueList(
                              key: ValueKey(structure!.guard),
                              session: session,
                              structure: structure!,
                              initial: report!,
                              enabled: !busy,
                              onInspect: inspectResult,
                              onEdit: widget.onEdit,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        footer(
          [
            DeskButton(
              '重新检查',
              quiet: true,
              icon: Icons.refresh_rounded,
              onPressed: busy ? null : refresh,
            ),
          ],
          [
            DeskButton(
              report == null ? '重试复查' : '继续提示修复',
              primary: true,
              icon: Icons.tips_and_updates_outlined,
              onPressed: busy
                  ? null
                  : report == null
                  ? retryCheck
                  : report!.items.isEmpty
                  ? null
                  : () => inspectResult(report!, report!.items.first),
            ),
          ],
          note: '编号异常仍需核对正文；未自动补章或改号。',
        ),
      ],
    );
  }
}
