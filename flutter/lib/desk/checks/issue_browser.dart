// 问题浏览器（CHK-012–036、CHK-050）：左侧问题队列 + 右侧问题详情与对照 + 底部决策栏。
// 读取、定位、审阅、单项方案预览与应用、撤销的流程沿用 V2c 前实现，只重写视图。
// 宽度 ≥ 760 时队列常驻（可收起），以下为单栏：列表与详情切换（“返回问题列表”）。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_service.dart';
import '../../application/rule_catalog_service.dart';
import '../controls/controls.dart';
import 'batch_repair_dialog.dart';
import '../chapters/dialogs/body_compare_dialog.dart';
import 'check_view_state.dart';
import 'comparison.dart';
import 'evidence_view.dart';
import 'repair_comparison.dart';
import '../dialogs.dart';
import '../tokens.dart';
import 'issue_queue.dart';

class CheckIssueBrowser extends StatefulWidget {
  const CheckIssueBrowser({
    super.key,
    required this.session,
    required this.enabled,
    required this.onChapter,
    this.onRepair,
    this.onRepairIssue,
    this.revision,
    this.viewState,
    this.onChanged,
    this.onAddNonHeading,
    this.onRule,
  });
  final ChapterSession session;
  final bool enabled;
  final void Function(ChapterIssue) onChapter;
  final void Function(bool)? onRepair;
  final void Function(ChapterIssue)? onRepairIssue;
  final Object? revision;
  final IssueViewState? viewState;
  final Future<void> Function()? onChanged;

  /// 把一行文字加入本书非标题词库（打开识别规则面板核对后应用）。
  final Future<void> Function(String phrase)? onAddNonHeading;

  /// 点问题类型名：打开规则页并定位到这类问题的规则（V64，CH-279）。
  final void Function(String ruleId)? onRule;

  /// 队列常驻所需宽度。
  static const queueBreakpoint = 760.0;
  @override
  State<CheckIssueBrowser> createState() => _CheckIssueBrowserState();
}

class _CheckIssueBrowserState extends State<CheckIssueBrowser> {
  ChapterPage? structure;
  ChapterIssuePage? page;
  ChapterIssue? selected;
  String excerpt = '', error = '';
  ChapterIssueContext? contextPair;
  int selectedAnchor = 0;
  String? category, severity;
  Map<String, int> categories = {}, severities = {};
  bool busy = false, locating = false, effective = true, detailOpen = false;
  int generation = 0, selectionGeneration = 0;
  String comparison = 'evidence';
  bool listOpen = true, previewBusy = false, editedHere = false;
  bool comparisonReady = false;
  ChapterRepairOptions? repairOptions;
  ChapterRepairPlan? repairPlan;
  String? changeId;
  String previewError = '';

  int resumeOffset = 0, resumeAnchor = 0;
  String? resumeIssueId;

  @override
  void initState() {
    super.initState();
    restoreView();
    detailOpen =
        widget.session is ChapterIssueContextSession || resumeIssueId != null;
    if (widget.enabled) {
      load(resumeOffset, preferredId: resumeIssueId, anchor: resumeAnchor);
    }
  }

  void restoreView() {
    final view = widget.viewState;
    category = view?.category;
    severity = view?.severity;
    effective = true;
    comparison = view?.comparison ?? 'evidence';
    listOpen = view?.listOpen ?? true;
    resumeOffset = view?.offset ?? 0;
    resumeIssueId = view?.issueId;
    resumeAnchor = view?.anchor ?? 0;
  }

  void rememberView() {
    final view = widget.viewState;
    if (view == null) return;
    view.category = category;
    view.severity = severity;
    view.effective = effective;
    view.comparison = comparison;
    view.listOpen = listOpen;
    view.offset = resumeOffset;
    view.issueId = resumeIssueId;
    view.anchor = resumeAnchor;
  }

  @override
  void didUpdateWidget(CheckIssueBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.session != widget.session ||
        oldWidget.revision != widget.revision ||
        oldWidget.viewState != widget.viewState) {
      if (oldWidget.session != widget.session ||
          oldWidget.viewState != widget.viewState) {
        restoreView();
      } else if (page != null) {
        resumeOffset = page!.offset;
        resumeIssueId = selected?.id;
        resumeAnchor = selectedAnchor;
      }
      generation++;
      selectionGeneration++;
      busy = false;
      locating = false;
      excerpt = '';
      contextPair = null;
      selected = null;
      page = null;
      if (widget.enabled) {
        load(resumeOffset, preferredId: resumeIssueId, anchor: resumeAnchor);
      }
    }
  }

  @override
  void dispose() {
    generation++;
    selectionGeneration++;
    super.dispose();
  }

  Future<void> load(int offset, {String? preferredId, int anchor = 0}) async {
    final ticket = ++generation;
    final requestedComparison = comparison;
    selectionGeneration++;
    resumeOffset = offset;
    resumeIssueId = preferredId;
    resumeAnchor = anchor;
    rememberView();
    setState(() {
      busy = true;
      locating = false;
      error = '';
      page = null;
      selected = null;
      excerpt = '';
      contextPair = null;
    });
    try {
      final tree = await widget.session.read(0);
      if (!mounted || ticket != generation || !widget.enabled) return;
      Future<ChapterIssuePage> readIssues(int start) =>
          widget.session is FilteredChapterSession
          ? (widget.session as FilteredChapterSession).filteredIssues(
              tree,
              start,
              effective: effective,
              category: category,
              severity: severity,
            )
          : widget.session.issues(tree, start, effective: effective);
      var next = await readIssues(offset);
      if (!mounted || ticket != generation || !widget.enabled) return;
      // 修复可能删掉最后一页：退到最近的有效页，而不是停在越界的空页。
      if (offset > 0 && offset >= next.total) {
        next = await readIssues(
          next.total == 0 ? 0 : ((next.total - 1) ~/ 50) * 50,
        );
      }
      if (!mounted || ticket != generation || !widget.enabled) return;
      setState(() {
        structure = tree;
        page = next;
        categories = next.categoryCounts;
        severities = next.severityCounts;
        resumeOffset = next.offset;
        busy = false;
      });
      final target =
          next.items.where((issue) => issue.id == preferredId).firstOrNull ??
          next.items.firstOrNull;
      if (target != null) {
        await locate(
          target,
          anchor: target.id == preferredId && anchor < target.lines.length
              ? anchor
              : 0,
        );
        if (mounted &&
            ticket == generation &&
            target.id == preferredId &&
            requestedComparison == 'original') {
          setState(() => comparison = 'original');
          rememberView();
        }
      } else {
        resumeIssueId = null;
        resumeAnchor = 0;
        rememberView();
      }
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          error = deskErrorText(e, '问题读取失败，请重试。');
        });
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> locate(ChapterIssue issue, {int anchor = 0}) async {
    final ticket = ++selectionGeneration;
    final snapshot = page!;
    setState(() {
      selected = issue;
      selectedAnchor = anchor;
      resumeIssueId = issue.id;
      resumeAnchor = anchor;
      excerpt = '';
      contextPair = null;
      repairOptions = null;
      repairPlan = null;
      previewError = '';
      changeId = null;
      comparison = 'evidence';
      locating = true;
      error = '';
    });
    rememberView();
    try {
      if (effective && issue.anchors.isNotEmpty) {
        if (const {
              'prose-heading',
              'unrecognized-heading',
              'heading-number-typo',
              'missing-heading-prefix',
            }.contains(issue.category) &&
            widget.session is TargetedChapterRepairSession) {
          await previewIssue();
        }
        return;
      }
      final pair =
          issue.lines.isNotEmpty && widget.session is ChapterIssueContextSession
          ? await (widget.session as ChapterIssueContextSession).issueContext(
              snapshot,
              issue,
              anchor: anchor,
            )
          : null;
      final text = pair != null
          ? (effective ? pair.effectiveText : pair.originalText) ?? ''
          : issue.lines.isEmpty
          ? '此项没有可定位的文本行。'
          : await widget.session.issueSource(snapshot, issue);
      if (mounted && widget.enabled && ticket == selectionGeneration) {
        setState(() {
          excerpt = text;
          contextPair = pair;
        });
      }
    } catch (e) {
      if (mounted && ticket == selectionGeneration) {
        setState(() {
          error = deskErrorText(e, '上下文读取失败，请重新选择或检查。');
        });
      }
    } finally {
      if (mounted && ticket == selectionGeneration) {
        setState(() => locating = false);
      }
    }
  }

  int get issueIndex => page == null || selected == null
      ? 0
      : page!.offset +
            page!.items.indexWhere((item) => item.id == selected!.id);
  double? scrubIndex;

  Future<void> goToIssue(int index) async {
    final snapshot = page;
    if (!widget.enabled ||
        busy ||
        snapshot == null ||
        index < 0 ||
        index >= snapshot.total) {
      return;
    }
    setState(() {
      detailOpen = true;
      scrubIndex = null;
    });
    final local = index - snapshot.offset;
    if (local >= 0 && local < snapshot.items.length) {
      await locate(snapshot.items[local]);
    } else {
      await load(index);
    }
  }

  String decision(ChapterIssue issue) => switch (issue.decision) {
    'confirmed_normal' => '已核实正常',
    'ignored' => '暂时忽略',
    _ => issue.categoryReviewed ? '整类已有结论' : '待核对',
  };

  /// 审阅菜单入口：“加入非标题词库”先确认要加入的文字，再交给上层打开识别规则面板。
  Future<void> review(String value) async {
    if (value == 'non_heading') {
      final issue = selected;
      if (issue == null || widget.onAddNonHeading == null) return;
      final title = issue.title;
      final cut = title.indexOf('：');
      final phrase = await showDialog<String>(
        context: context,
        builder: (_) => _PhraseDialog(
          initial: (cut >= 0 ? title.substring(cut + 1) : title).trim(),
        ),
      );
      if (phrase == null || phrase.trim().isEmpty || !mounted) return;
      await widget.onAddNonHeading!(phrase.trim());
      return;
    }
    await _review(value);
  }

  Future<void> _review(String value) async {
    if (!widget.enabled || busy || page == null || selected == null) {
      return;
    }
    final snapshot = page!;
    final id = selected!.id;
    final ticket = ++generation;
    selectionGeneration++;
    setState(() {
      busy = true;
      locating = false;
      error = '';
    });
    try {
      final next = await widget.session.reviewIssue(
        snapshot,
        id,
        value == 'reset' ? null : value,
      );
      if (!mounted || ticket != generation || !widget.enabled) return;
      final current =
          next.items.where((i) => i.id == id).firstOrNull ??
          next.items.firstOrNull;
      setState(() {
        page = next;
        categories = next.categoryCounts;
        severities = next.severityCounts;
        selected = current;
        busy = false;
        excerpt = '';
        contextPair = null;
      });
      if (current != null) {
        await locate(current);
      } else {
        resumeIssueId = null;
        resumeAnchor = 0;
        rememberView();
      }
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          error = deskErrorText(e, '审阅未完成，请重新检查。');
        });
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> previewIssue({String? selectedChange}) async {
    final issue = selected, tree = structure;
    if (issue == null || tree == null) return;
    final ticket = selectionGeneration;
    setState(() {
      comparison = 'preview';
      previewBusy = true;
      comparisonReady = false;
      previewError = '';
      repairPlan = null;
    });
    rememberView();
    try {
      final options =
          repairOptions ??
          (widget.session is TargetedChapterRepairSession
              ? await (widget.session as TargetedChapterRepairSession)
                    .repairsForIssue(tree, issue.id)
              : await widget.session.repairs(tree));
      if (!mounted || ticket != selectionGeneration) return;
      final candidates = options.changes
          .where(
            (c) =>
                widget.session is TargetedChapterRepairSession ||
                issue.lines.contains(c.line) ||
                issue.entryId == c.entryId,
          )
          .toList();
      final change =
          candidates.where((c) => c.id == selectedChange).firstOrNull ??
          candidates.firstOrNull;
      if (change == null) {
        setState(() => previewError = '此项需要先核对正文或调整识别规则，暂无可直接应用的方案。');
        return;
      }
      final plan = await widget.session.previewRepairs(options, {change.id});
      if (!mounted || ticket != selectionGeneration) return;
      setState(() {
        repairOptions = options;
        repairPlan = plan;
        changeId = change.id;
      });
    } catch (e) {
      if (mounted && ticket == selectionGeneration) {
        setState(() => previewError = deskErrorText(e, '方案读取失败，请重试。'));
      }
    } finally {
      if (mounted && ticket == selectionGeneration) {
        setState(() => previewBusy = false);
      }
    }
  }

  Future<void> applyPreview() async {
    final plan = repairPlan;
    if (plan == null || busy || previewBusy) return;
    final offset = page!.offset, id = selected!.id;
    setState(() => busy = true);
    try {
      await widget.session.confirm(plan.preview);
      editedHere = true;
      if (widget.onChanged != null) {
        await widget.onChanged!();
      } else if (mounted) {
        await load(offset, preferredId: id);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '修改未应用，请重新检查。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// 批量修复同类问题：弹窗内完成勾选、合并预览与确认；应用后重新检查。
  Future<void> batchRepair() async {
    final issue = selected, tree = structure;
    if (issue == null || tree == null || busy) return;
    final issues = page;
    final reviewer =
        widget.session is BatchIssueReviewSession &&
            issues != null &&
            issues.effective
        ? widget.session as BatchIssueReviewSession
        : null;
    final result = await showDialog<({int applied, int marked})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BatchRepairDialog(
        session: widget.session,
        page: tree,
        category: issue.category,
        label: issue.categoryLabel,
        markNormal: reviewer == null
            ? null
            : (ids) async {
                await reviewer.reviewIssues(issues!, ids, 'confirmed_normal');
              },
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      busy = true;
      repairOptions = null;
      repairPlan = null;
      comparison = 'evidence';
    });
    try {
      editedHere = true;
      if (widget.onChanged != null) {
        await widget.onChanged!();
      } else if (mounted) {
        await load(0);
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              result.marked > 0
                  ? '已把 ${result.marked} 项标记为“不是标题”，可在“审阅此项”中逐项撤销。'
                  : '已应用 ${result.applied} 项修改，并已重新检查。',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> undo() async {
    if (structure == null || busy) return;
    setState(() => busy = true);
    try {
      await widget.session.history(structure!, undo: true);
      if (widget.onChanged != null) {
        await widget.onChanged!();
      } else if (mounted) {
        await load(page?.offset ?? 0);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '撤销未完成，请重试。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void reload() => load(
    page?.offset ?? resumeOffset,
    preferredId: selected?.id ?? resumeIssueId,
    anchor: selectedAnchor,
  );

  // ---------------------------------------------------------------- 视图

  List<Widget> filters() => [
    if (widget.session is FilteredChapterSession) ...[
      Expanded(
        flex: 3,
        child: DeskChoice<String>(
          compact: true,
          value: category ?? '',
          key: const ValueKey('check-category'),
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('全部类型')),
            for (final item in chapterIssueCategories.entries)
              DropdownMenuItem(
                value: item.key,
                child: Text('${item.value} (${categories[item.key] ?? 0})'),
              ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  setState(() => category = value == '' ? null : value);
                  load(0);
                },
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        flex: 2,
        child: DeskChoice<String>(
          compact: true,
          value: severity ?? '',
          key: const ValueKey('check-severity'),
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('全部级别')),
            for (final item in chapterIssueSeverities.entries)
              DropdownMenuItem(
                value: item.key,
                child: Text('${item.value} (${severities[item.key] ?? 0})'),
              ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  setState(() => severity = value == '' ? null : value);
                  load(0);
                },
        ),
      ),
    ],
  ];

  Widget queue(Desk d, {required bool docked}) {
    final total = page?.total;
    // 顶部进度（CHK-054）：不另占一行。数字跟在标题后，进度条代替标题区底部分隔线。
    final reviewed = page?.reviewed, all = page?.unfilteredTotal;
    final progress = reviewed != null && all != null && all > 0
        ? (reviewed / all).clamp(0.0, 1.0)
        : null;
    return Material(
      color: d.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
            decoration: progress == null
                ? BoxDecoration(
                    border: Border(bottom: BorderSide(color: d.line)),
                  )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    // 标题与进度占用按钮以外的全部宽度：进度只在确实放不下时才省略
                    // （原来与 Spacer 平分剩余宽度，总被截断，V15）。
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            total == null ? '章节问题' : '章节问题 $total',
                            style: ui(13, w: 650, c: d.ink),
                          ),
                          if (progress != null) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '已核对 $reviewed / $all',
                                key: const ValueKey('check-issue-progress'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ui(11.5, c: d.ink3),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 列较窄时只留图标，让“已核对”完整显示（V15）。
                    Builder(
                      builder: (context) => docked
                          ? IconButton(
                              tooltip: '重新检查',
                              visualDensity: VisualDensity.compact,
                              color: d.ink2,
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              onPressed: !widget.enabled || busy
                                  ? null
                                  : reload,
                            )
                          : TextButton.icon(
                              onPressed: !widget.enabled || busy
                                  ? null
                                  : reload,
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('重新检查'),
                              style: TextButton.styleFrom(
                                foregroundColor: d.ink2,
                                minimumSize: const Size(0, 30),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                            ),
                    ),
                    if (docked)
                      IconButton(
                        tooltip: '收起问题列表',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() {
                          listOpen = false;
                          rememberView();
                        }),
                        icon: Icon(
                          Icons.view_sidebar_outlined,
                          size: 18,
                          color: d.ink2,
                        ),
                      ),
                  ],
                ),
                if (widget.session is FilteredChapterSession) ...[
                  const SizedBox(height: 6),
                  Row(children: filters()),
                ],
                if (category != null || severity != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              setState(() {
                                category = null;
                                severity = null;
                              });
                              load(0);
                            },
                      child: const Text('清除筛选'),
                    ),
                  ),
              ],
            ),
          ),
          // 静态色条（不用 LinearProgressIndicator：那是“正在读取”的含义）。
          if (progress != null)
            Container(
              key: const ValueKey('check-issue-progress-bar'),
              height: 2,
              color: d.line,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: progress,
                child: ColoredBox(color: d.accent),
              ),
            ),
          Expanded(
            child: page == null || page!.total == 0
                ? const SizedBox.shrink()
                : IssueResultList(
                    key: ValueKey((
                      'issue-results',
                      structure?.guard,
                      category,
                      severity,
                      generation,
                    )),
                    initial: page!,
                    selectedId: selected?.id,
                    enabled: !busy,
                    read: (offset) => widget.session is FilteredChapterSession
                        ? (widget.session as FilteredChapterSession)
                              .filteredIssues(
                                structure!,
                                offset,
                                effective: true,
                                category: category,
                                severity: severity,
                              )
                        : widget.session.issues(
                            structure!,
                            offset,
                            effective: true,
                          ),
                    onSelect: (owner, issue) {
                      setState(() {
                        page = owner;
                        resumeOffset = owner.offset;
                        detailOpen = true;
                      });
                      locate(issue);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget preview(Desk d) {
    if (previewBusy) return const Center(child: CircularProgressIndicator());
    if (previewError.isNotEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DeskNote(previewError),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => previewIssue(),
                child: const Text('重新读取方案'),
              ),
            ],
          ),
        ),
      );
    }
    final change = repairPlan?.changes.firstOrNull;
    if (change == null) {
      return Center(
        child: Text('选择方案后查看修改前后。', style: ui(12.5, c: d.ink3)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: widget.session is ChapterRepairComparisonSession
              ? RepairComparisonView(
                  key: ValueKey(('candidate-comparison', repairPlan)),
                  session: widget.session as ChapterRepairComparisonSession,
                  plan: repairPlan!,
                  change: change,
                  onReady: () {
                    if (mounted && !comparisonReady) {
                      setState(() => comparisonReady = true);
                    }
                  },
                )
              : ComparisonWorkspace(
                  key: ValueKey(('preview', selected!.id, change.id)),
                  versions: true,
                  left: ComparisonContent(
                    label: '修改前',
                    rows: change.before
                        .split('\n')
                        .map((v) => ChapterContextRow(v))
                        .toList(),
                  ),
                  right: ComparisonContent(
                    label: '修改后',
                    rows: change.after
                        .split('\n')
                        .map((v) => ChapterContextRow(v))
                        .toList(),
                  ),
                ),
        ),
        if (change.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('显示关键变更；应用前可打开完整修复方案核对。', style: ui(11.5, c: d.ink3)),
          ),
      ],
    );
  }

  Widget detail(Desk d, {required bool showQueueButton, required bool narrow}) {
    final issue = selected;
    if (issue == null) return const SizedBox.shrink();
    final (tone, toneSoft) = d.tone(issueTone(issue.severity));
    final multipleChanges = (repairOptions?.changes.length ?? 0) > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (showQueueButton)
                    IconButton(
                      tooltip: narrow ? '返回问题列表' : '问题列表',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        if (narrow) {
                          detailOpen = false;
                        } else {
                          listOpen = true;
                        }
                        rememberView();
                      }),
                      icon: Icon(
                        narrow
                            ? Icons.arrow_back_rounded
                            : Icons.format_list_bulleted_rounded,
                        size: 18,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: toneSoft,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      chapterIssueSeverities[issue.severity] ?? '提示',
                      style: ui(11.5, w: 620, c: tone),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      issue.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ui(15.5, w: 650, c: d.ink),
                    ),
                  ),
                  IconButton(
                    tooltip: '${issue.categoryLabel}：${issue.evidence}',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.info_outline_rounded,
                      size: 17,
                      color: d.ink3,
                    ),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => DeskDialog(
                        title: issue.categoryLabel,
                        closeTooltip: '关闭问题说明',
                        width: 460,
                        actions: [
                          DeskButton(
                            '知道了',
                            primary: true,
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                        child: Text(
                          issue.evidence,
                          style: ui(13, c: d.ink2, h: 1.6),
                        ),
                      ),
                    ),
                  ),
                  Text(decision(issue), style: ui(12, c: d.ink3)),
                ],
              ),
              const SizedBox(height: 2),
              if (widget.onRule case final open?)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: '查看这类检查的规则',
                    child: InkWell(
                      key: const ValueKey('issue-rule-link'),
                      borderRadius: BorderRadius.circular(4),
                      onTap: () =>
                          open(chapterIssueRule(issue.category, issue.subtype)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              issue.categoryLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ui(12, c: d.ink2),
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(Icons.tune_rounded, size: 13, color: d.ink3),
                        ],
                      ),
                    ),
                  ),
                )
              else
                Text(
                  issue.categoryLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(12, c: d.ink2),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
          decoration: BoxDecoration(
            border: Border.symmetric(horizontal: BorderSide(color: d.line)),
          ),
          child: Row(
            children: [
              DeskCommandMenu<String>(
                tooltip: '对照方式',
                initialValue: comparison,
                onSelected: busy
                    ? null
                    : (value) {
                        if (value == 'preview') {
                          previewIssue();
                        } else {
                          setState(() => comparison = value);
                          rememberView();
                        }
                      },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'evidence', child: Text('核对问题')),
                  PopupMenuItem(value: 'preview', child: Text('预览修改')),
                  PopupMenuItem(value: 'original', child: Text('追溯原稿')),
                ],
                child: _Chip(
                  icon: Icons.compare_arrows_rounded,
                  text: switch (comparison) {
                    'preview' => '预览修改',
                    'original' => '追溯原稿',
                    _ => '核对问题',
                  },
                ),
              ),
              if (comparison == 'preview' && multipleChanges) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: DeskChoice<String>(
                    compact: true,
                    isExpanded: true,
                    value: changeId,
                    items: [
                      for (final c in repairOptions!.changes)
                        DropdownMenuItem(
                          value: c.id,
                          child: Text('方案：${c.title}'),
                        ),
                    ],
                    onChanged: (id) => previewIssue(selectedChange: id),
                  ),
                ),
              ],
              const Spacer(),
              // 队列收起或单栏时，“重新检查”随详情显示（CHK-016）。
              if (showQueueButton)
                IconButton(
                  tooltip: '重新检查',
                  visualDensity: VisualDensity.compact,
                  onPressed: !widget.enabled || busy ? null : reload,
                  icon: Icon(Icons.refresh_rounded, size: 18, color: d.ink2),
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: locating && issue.anchors.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : comparison == 'preview'
                ? preview(d)
                : IssueEvidenceView(
                    key: ValueKey((issue.id, page!.effective)),
                    session: widget.session,
                    page: page!,
                    issue: issue,
                    onLocate: widget.onChapter,
                    original: comparison == 'original',
                    fallback:
                        contextPair ??
                        ChapterIssueContext(effectiveText: excerpt),
                  ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: d.surface,
            border: Border(top: BorderSide(color: d.line)),
          ),
          // 按用途分三组（V12）：查看 | 处理 | 当前修改；组间细竖线，窄窗时整组换行。
          child: Wrap(
            key: const ValueKey('issue-actions'),
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              _ActionGroup(
                children: [
                  if (editedHere && widget.session.canUndo)
                    DeskButton(
                      '撤销修改',
                      icon: Icons.undo_rounded,
                      quiet: true,
                      onPressed: busy ? null : undo,
                    ),
                  DeskButton(
                    '定位章节',
                    icon: Icons.my_location_rounded,
                    onPressed: busy || locating
                        ? null
                        : () =>
                              widget.onChapter(issue.atAnchor(selectedAnchor)),
                  ),
                  DeskCommandMenu<String>(
                    key: ValueKey('review-${issue.id}'),
                    tooltip: '审阅此项',
                    enabled: !busy && !locating,
                    onSelected: review,
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'confirmed_normal',
                        child: Text('本项已核实正常'),
                      ),
                      const PopupMenuItem(
                        value: 'ignored',
                        child: Text('本项暂时忽略'),
                      ),
                      const PopupMenuItem(
                        value: 'reset',
                        child: Text('撤销本项结论'),
                      ),
                      if (widget.onAddNonHeading != null &&
                          (issue.category == 'unrecognized-heading' ||
                              issue.category == 'prose-heading'))
                        const PopupMenuItem(
                          value: 'non_heading',
                          child: Text('不是标题，加入非标题词库…'),
                        ),
                    ],
                    child: const _Chip(text: '审阅此项', trailing: true),
                  ),
                ],
              ),
              _ActionGroup(
                divider: true,
                children: [
                  // 重复类问题：直接打开两处所在章节的正文对照（CH-247）。
                  if (issue.category.startsWith('duplicate') ||
                      issue.category == 'number-reset')
                    DeskButton(
                      '对比两章正文',
                      key: const ValueKey('issue-compare-bodies'),
                      icon: Icons.compare_outlined,
                      onPressed: busy || locating
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (_) => ChapterBodyCompareDialog(
                                session: widget.session,
                                lines: [
                                  for (final a in issue.anchors) a.line,
                                  if (issue.anchors.isEmpty) ...issue.lines,
                                ],
                              ),
                            ),
                    ),
                  DeskButton(
                    '批量修复同类（${categories[issue.category] ?? 1}）…',
                    key: const ValueKey('batch-repair'),
                    icon: Icons.done_all_rounded,
                    tooltip: '一次处理全部“${issue.categoryLabel}”：勾选、合并预览、确认应用',
                    onPressed: busy || locating ? null : batchRepair,
                  ),
                  if (widget.onRepairIssue != null || widget.onRepair != null)
                    DeskButton(
                      '完整方案',
                      icon: Icons.auto_fix_high_outlined,
                      quiet: true,
                      onPressed: busy
                          ? null
                          : () => widget.onRepairIssue != null
                                ? widget.onRepairIssue!(issue)
                                : widget.onRepair!(false),
                    ),
                ],
              ),
              _ActionGroup(
                divider: true,
                children: [
                  if (comparison == 'preview') ...[
                    DeskButton(
                      '取消预览',
                      quiet: true,
                      onPressed: busy
                          ? null
                          : () {
                              setState(() => comparison = 'evidence');
                              rememberView();
                            },
                    ),
                    DeskButton(
                      '应用修改',
                      primary: true,
                      icon: Icons.check_rounded,
                      disabledReason: repairPlan == null
                          ? '暂无可应用的方案'
                          : '等待修改前后对照读取完成',
                      onPressed:
                          busy ||
                              previewBusy ||
                              repairPlan == null ||
                              (widget.session
                                      is ChapterRepairComparisonSession &&
                                  !comparisonReady)
                          ? null
                          : applyPreview,
                    ),
                  ] else
                    DeskButton(
                      '预览处理',
                      primary: true,
                      onPressed: busy || locating ? null : () => previewIssue(),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget navigation(Desk d) => Semantics(
    key: const ValueKey('issue-navigation'),
    container: true,
    explicitChildNodes: true,
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: issueIndex == 0 ? '已是第一个问题' : '上一个问题',
            visualDensity: VisualDensity.compact,
            onPressed: busy || issueIndex == 0
                ? null
                : () => goToIssue(issueIndex - 1),
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
          ),
          Text(
            '问题 ${issueIndex + 1} / ${page!.total}',
            style: ui(12, c: d.ink2),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: d.accent,
                inactiveTrackColor: d.sunken,
                thumbColor: d.surface,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 6,
                  elevation: 1,
                ),
              ),
              child: Slider(
                key: const ValueKey('issue-position'),
                min: 0,
                max: (page!.total - 1).clamp(1, 0x7fffffff).toDouble(),
                value: (scrubIndex ?? issueIndex.toDouble()).clamp(
                  0,
                  (page!.total - 1).clamp(1, 0x7fffffff).toDouble(),
                ),
                label:
                    '问题 ${(scrubIndex ?? issueIndex.toDouble()).round() + 1}',
                onChanged: busy || page!.total < 2
                    ? null
                    : (value) => setState(() => scrubIndex = value),
                onChangeEnd: (value) => goToIssue(value.round()),
              ),
            ),
          ),
          IconButton(
            tooltip: issueIndex >= page!.total - 1 ? '已是最后一个问题' : '下一个问题',
            visualDensity: VisualDensity.compact,
            onPressed: busy || issueIndex >= page!.total - 1
                ? null
                : () => goToIssue(issueIndex + 1),
            icon: const Icon(Icons.chevron_right_rounded, size: 20),
          ),
        ],
      ),
    ),
  );

  Widget centered(Desk d, Widget child) => Material(
    color: d.canvas,
    child: Center(child: child),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final d = context.desk;
      final narrow = bounds.maxWidth < CheckIssueBrowser.queueBreakpoint;
      final queueWidth = bounds.maxWidth >= 1250 ? 336.0 : 296.0;
      final Widget body;
      if (!widget.enabled) {
        body = centered(d, Text('重新检查后显示当前问题', style: ui(13, c: d.ink3)));
      } else if (page == null) {
        body = centered(
          d,
          DeskButton(
            busy ? '读取中…' : '重试读取',
            onPressed: busy ? null : () => load(0),
          ),
        );
      } else if (page!.total == 0) {
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!narrow)
              SizedBox(width: queueWidth, child: queue(d, docked: true)),
            Expanded(
              child: centered(
                d,
                Text(
                  category != null || severity != null
                      ? '当前筛选没有匹配问题'
                      : '当前规则未发现章节问题',
                  style: ui(13, c: d.ink2),
                ),
              ),
            ),
          ],
        );
      } else if (narrow) {
        body = detailOpen && selected != null
            ? detail(d, showQueueButton: true, narrow: true)
            : queue(d, docked: false);
      } else {
        final showQueue = listOpen;
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showQueue) ...[
              SizedBox(width: queueWidth, child: queue(d, docked: true)),
              Container(width: 1, color: d.line),
            ],
            Expanded(
              child: detail(d, showQueueButton: !showQueue, narrow: false),
            ),
          ],
        );
      }
      return Material(
        color: d.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 2,
              child: busy || locating || previewBusy
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null,
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: DeskNote(error, title: '未能读取', tone: Tone.pen),
              ),
            Expanded(child: body),
            if (page != null && page!.total > 0) navigation(d),
          ],
        ),
      );
    },
  );
}

/// 确认加入非标题词库的文字：默认取这一行，可缩短为共同的关键字。
class _PhraseDialog extends StatefulWidget {
  const _PhraseDialog({required this.initial});
  final String initial;
  @override
  State<_PhraseDialog> createState() => _PhraseDialogState();
}

class _PhraseDialogState extends State<_PhraseDialog> {
  late final text = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '加入非标题词库',
      subtitle: '包含这段文字的行今后都不算标题。可以删短为共同的关键字，例如“两章合一章”。',
      closeTooltip: '取消',
      width: 520,
      actions: [
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '加入并打开识别规则',
          key: const ValueKey('phrase-confirm'),
          primary: true,
          onPressed: () => Navigator.pop(context, text.text),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('phrase-text'),
            controller: text,
            autofocus: true,
            style: ui(13, c: d.ink),
            decoration: deskInput(context),
          ),
          const SizedBox(height: 8),
          Text('加入后会打开识别规则面板：先核对全书差异，确认后才应用；原稿不变。', style: ui(11.5, c: d.ink3)),
        ],
      ),
    );
  }
}

/// 一组底部按钮；[divider] 时左侧有细竖线与上一组分开。
class _ActionGroup extends StatelessWidget {
  const _ActionGroup({required this.children, this.divider = false});
  final List<Widget> children;
  final bool divider;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (divider) ...[
          Container(width: 1, height: 22, color: d.line),
          const SizedBox(width: 6),
        ],
        for (final (i, child) in children.indexed) ...[
          if (i > 0) const SizedBox(width: 6),
          child,
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.icon, this.trailing = true});
  final String text;
  final IconData? icon;
  final bool trailing;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Container(
      height: 36 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: d.lineStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: d.ink2),
            const SizedBox(width: 6),
          ],
          Text(text, style: ui(13, w: 520, c: d.ink)),
          if (trailing) ...[
            const SizedBox(width: 4),
            Icon(Icons.expand_more_rounded, size: 16, color: d.ink2),
          ],
        ],
      ),
    );
  }
}
