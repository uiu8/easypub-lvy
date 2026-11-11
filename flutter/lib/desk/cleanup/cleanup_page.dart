// 文本清理：左栏有序规则，右栏检测结果（本页变更列表 + 选中项对照、
// 提示候选、逐步骤差异）与采用结果。检测、保留、候选、采用、撤销与复查的逻辑逐行沿用早先的 CleanupPage；
// 采用前必须进入“清理差异”并确认。
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, kDoubleTapTimeout;
import 'package:flutter/material.dart';

import '../checks/check_board.dart';
import '../errors.dart';

import '../../application/cleanup_service.dart';
import '../../application/library_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/controls.dart'
    show
        DeskButton,
        DeskCommandMenu,
        RangeSelection,
        SelectAllHeader,
        SelectionKeys;
import '../dialogs.dart';
import '../pending/pending_changes.dart';
import '../shell/page_menu.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'batch_dialog.dart';
import 'builtin_rules.dart';
import 'inspection_dialog.dart';
import 'dropped_edits_dialog.dart';
import 'inline_diff.dart';
import 'paired_context.dart';
import 'range_dialog.dart';
import 'region_dialog.dart';
import 'rule_dialog.dart';

class CleanupNavigationGuard {
  Future<bool> Function()? check;
  Future<bool> Function()? checkWorkspace;
  Future<bool> canLeaveWorkspace() async =>
      await checkWorkspace?.call() ?? true;
  Future<bool> canLeave() async => await check?.call() ?? true;
}

class CleanupPage extends StatefulWidget {
  const CleanupPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.onChecks,
    required this.navigation,
    this.inspectOnOpen = false,
    this.inspectLine,
    this.focusLine,
  });
  final LibraryService library;
  final String bookId;
  final VoidCallback onChecks;
  final CleanupNavigationGuard navigation;
  final bool inspectOnOpen;

  /// 打开检测详情时先定位的行（从检查页逐行定位进入）。
  final int? inspectLine;

  /// 打开后先定位到这一行的变更（从检查随行栏或检查页跳过来）。
  final int? focusLine;
  @override
  State<CleanupPage> createState() => _CleanupPageState();
}

class _CleanupPageState extends State<CleanupPage>
    with PendingReporter<CleanupPage> {
  late final session = widget.library.openCleanup(widget.bookId);
  late Map<String, dynamic> draft = decodeCleanup(session.settings);
  CleanupPreview? plan;
  CleanupReceipt? receipt;
  CleanupInspection? inspection;

  /// 后台核对：清理对章节修改与检查的影响。
  CleanupImpact? impact;
  String impactError = '';
  bool impactBusy = false;
  String error = '', saved = '', draftIdentity = '';
  int selected = 0, change = 0, generation = 0;
  bool busy = false, diff = false, showCandidates = false;
  bool showWhitespace = false, showStages = false;

  /// 差异列表占结果区的比例：默认约 60%，拖动分隔线调整；
  /// 本次运行期间在各书之间保持，重启后恢复默认。
  static double split = .6;

  /// 拖动分隔线时按按下时的高度加鼠标总位移计算（同早先的分隔条）：
  /// 以前每个移动事件都从上一帧的高度加增量，一帧内多个事件只算最后一个，分隔线跟不上鼠标。
  double? dragTop, dragOrigin;
  String contextKey = '';
  Future<String>? contextFuture;
  final undoDraft = <String>[], redoDraft = <String>[];
  List<Map<String, dynamic>> get rules => (draft['pipeline'] as List)
      .cast<Map>()
      .map((v) => v.cast<String, dynamic>())
      .toList();
  bool get dirty => draftIdentity != saved;
  WorkspaceAutosaveService? get workspace =>
      widget.library is WorkspaceAutosaveService
      ? widget.library as WorkspaceAutosaveService
      : null;
  void saveDraft() {
    workspace?.writeDraft('cleanup:${widget.bookId}', {
      'rules': draftIdentity,
      'selected': selected,
      'undo': undoDraft,
      'redo': redoDraft,
      'showWhitespace': showWhitespace,
    });
    board?.cleanupChanged();
  }

  @override
  void initState() {
    super.initState();
    saved = jsonEncode(draft);
    draftIdentity = saved;
    // 内置规则各会改几处：页面出来后在后台试算。
    WidgetsBinding.instance.addPostFrameCallback((_) => countBuiltins());
    final restored = workspace?.readDraft('cleanup:${widget.bookId}');
    if (restored != null) {
      final restoredRules = restored['rules'] as String;
      draft = decodeCleanup(restoredRules);
      draftIdentity = jsonEncode(draft);
      selected = (restored['selected'] as int? ?? 0).clamp(
        0,
        math.max(0, rules.length - 1),
      );
      undoDraft.addAll((restored['undo'] as List? ?? []).cast<String>());
      redoDraft.addAll((restored['redo'] as List? ?? []).cast<String>());
      showWhitespace = restored['showWhitespace'] == true;
    }
    widget.navigation.check = canLeave;
    widget.navigation.checkWorkspace = () => canLeave(cancelPending: false);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (widget.inspectOnOpen) {
        await recheck();
        if (mounted &&
            inspection != null &&
            session.isInspectionCurrent(inspection!)) {
          await inspectDetails();
        }
      } else {
        await detect();
        if (widget.focusLine case final line?) await focusLine(line);
      }
      if (!mounted) return;
      board = CheckBoardScope.maybeOf(context)
        ?..attachCleanup(boardShow, boardKeep);
    });
  }

  CheckBoard? board;

  /// 页面忙时进度条又点了下一处：等忙完再去，不用重开页面。
  int? pendingFocus;
  bool boardShow(int line) {
    if (busy) {
      pendingFocus = line;
      return true;
    }
    focusLine(line);
    return true;
  }

  /// 进度条的“保留原文”：保留包含这一行的那处修改。
  bool boardKeep(int line) {
    final current = plan;
    if (current == null || busy || !session.isCurrent(current)) return false;
    final hit = current.actions.where((a) => a.line <= line && line <= a.end);
    if (hit.isEmpty) return false;
    keep(hit.first);
    return true;
  }

  /// 进度条显示时它就是导航，这里的上一处、下一处收起来。
  Widget unlessBoard(Widget child) {
    final value = CheckBoardScope.maybeOf(context);
    if (value == null) return child;
    return ListenableBuilder(
      listenable: value,
      builder: (_, _) => value.visibleOn(value.bookId, value.page)
          ? const SizedBox.shrink()
          : child,
    );
  }

  /// 高亮的提示候选行。
  int? focusedCandidate;
  final candidateScroll = ScrollController();

  /// 定位到包含这一行的变更：每页 40 条，不在当前页时翻过去。先按行号二分找页，
  /// 走到下一处通常就在当前页或隔壁页，不用从第一页翻起；顺序对不上时才逐页找。
  /// 没有对应的变更时再找提示候选，找到就切到“审阅提示候选”。
  Future<void> focusLine(int line) async {
    final current = plan;
    if (current == null || !session.isCurrent(current)) return;
    // 就在当前页：不用读，也不进忙碌状态，走到下一处不闪。
    final here = current.actions.indexWhere(
      (a) => a.line <= line && line <= a.end,
    );
    if (here >= 0) {
      setState(() {
        showStages = false;
        showCandidates = false;
        focusedCandidate = null;
        diff = false;
        change = here;
      });
      revealChange();
      return;
    }
    await run(() async {
      final seen = <int, CleanupPreview>{current.offset: current};
      Future<CleanupPreview> pageAt(int offset) async =>
          seen[offset] ??= await session.preview(draftIdentity, offset: offset);
      bool showChange(CleanupPreview next, int index) {
        setState(() {
          plan = next;
          showStages = false;
          showCandidates = false;
          focusedCandidate = null;
          diff = false;
          change = index;
        });
        revealChange();
        return true;
      }

      bool showHint(CleanupPreview next, int hint) {
        setState(() {
          plan = next;
          showStages = false;
          showCandidates = true;
          focusedCandidate = line;
          diff = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !candidateScroll.hasClients) return;
          candidateScroll.jumpTo(
            (hint * 48.0).clamp(0.0, candidateScroll.position.maxScrollExtent),
          );
        });
        return true;
      }

      var index = -1;
      var low = 0, high = (current.total - 1) ~/ 40;
      while (low <= high) {
        final middle = (low + high) >> 1;
        final next = await pageAt(middle * 40);
        if (!mounted) return;
        if (next.actions.isEmpty) break;
        index = next.actions.indexWhere((a) => a.line <= line && line <= a.end);
        if (index >= 0) {
          showChange(next, index);
          return;
        }
        if (line < next.actions.first.line) {
          high = middle - 1;
        } else {
          low = middle + 1;
        }
      }
      final total = math.max(current.total, current.candidateTotal);
      for (var offset = 0; offset < total; offset += 40) {
        final next = await pageAt(offset);
        if (!mounted) return;
        index = next.actions.indexWhere((a) => a.line <= line && line <= a.end);
        if (index >= 0) {
          showChange(next, index);
          return;
        }
        final hint = next.candidates.indexWhere((c) => c.line == line);
        if (hint >= 0) {
          showHint(next, hint);
          return;
        }
      }
    });
  }

  @override
  void dispose() {
    board?.detachCleanup(boardShow);
    widget.navigation.check = null;
    widget.navigation.checkWorkspace = null;
    session.dispose();
    changeList.dispose();
    candidateScroll.dispose();
    generation++;
    super.dispose();
  }

  Future<bool> canLeave({bool cancelPending = true}) async {
    if (!cancelPending && busy) return false;
    saveDraft();
    if (cancelPending) {
      session.cancel();
      generation++;
    }
    return true;
  }

  Future<void> batch() async {
    final targets = await showDialog<Set<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CleanupBatchDialog(
        library: widget.library,
        bookId: widget.bookId,
        template: draftIdentity,
      ),
    );
    if (!mounted || targets == null) return;
    session.cancel();
    setState(() {
      plan = null;
      receipt = null;
      diff = false;
      error = '';
      if (targets.contains(widget.bookId)) {
        draft = decodeCleanup(session.settings);
        saved = jsonEncode(draft);
        draftIdentity = saved;
        undoDraft.clear();
        redoDraft.clear();
      }
    });
    saveDraft();
  }

  void edit(void Function() action, {bool preserveResults = false}) {
    final oldPlan = plan, oldChange = change, oldDiff = diff;
    undoDraft.add(draftIdentity);
    if (undoDraft.length > 50) undoDraft.removeAt(0);
    redoDraft.clear();
    session.cancel();
    setState(() {
      action();
      draftIdentity = jsonEncode(draft);
      plan = null;
      receipt = null;
      diff = false;
      change = 0;
      error = '';
      if (preserveResults) {
        plan = oldPlan;
        change = oldChange;
        diff = oldDiff;
      }
    });
    saveDraft();
    if (preserveResults) {
      final requestJson = draftIdentity;
      run(() async {
        final next = await session.preview(
          requestJson,
          offset: oldPlan?.offset ?? 0,
        );
        if (!mounted) return;
        setState(() {
          plan = next;
          final count = showStages ? next.stages.length : next.actions.length;
          change = count == 0 ? 0 : oldChange.clamp(0, count - 1);
        });
        checkImpact(next);
      });
    }
  }

  Future<void> run(Future<void> Function() action) async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted && generation == ticket) {
        setState(() {
          error = deskErrorText(e, '无法完成操作，请核对规则、源范围及章节编辑冲突。');
        });
      }
    } finally {
      if (mounted && generation == ticket) {
        setState(() => busy = false);
        saveDraft();
        final line = pendingFocus;
        pendingFocus = null;
        if (line != null) focusLine(line);
      }
    }
  }

  Future<void> detect({int offset = 0, bool asDiff = false}) => run(() async {
    final next = await session.preview(draftIdentity, offset: offset);
    if (!mounted) return;
    setState(() {
      plan = next;
      change = 0;
      diff = asDiff;
      receipt = null;
    });
    checkImpact(next);
  });

  /// 差异先显示；与章节修改的关系、清理后问题数在后台核对，不占用 busy。
  Future<void> checkImpact(CleanupPreview target) async {
    setState(() {
      impact = null;
      impactError = '';
      impactBusy = true;
    });
    try {
      final value = await session.impact(target);
      if (mounted && identical(plan, target)) setState(() => impact = value);
    } catch (e) {
      if (mounted && identical(plan, target)) {
        setState(() => impactError = deskErrorText(e, '无法核对清理对章节的影响，请重新检测。'));
      }
    } finally {
      if (mounted && identical(plan, target)) {
        setState(() => impactBusy = false);
      }
    }
  }

  /// 有无法换算的章节修改时先问用户；返回 null 表示取消。
  Future<bool?> confirmDroppedEdits() async {
    final skipped = impact?.skipped ?? const <CleanupSkippedEdit>[];
    if (skipped.isEmpty) return false;
    final confirmed = await confirmDroppedChapterEdits(
      context,
      title: '放弃 ${skipped.length} 处章节修改并清理？',
      confirm: '放弃这些修改并清理',
      lead:
          '其余 ${impact!.edits - skipped.length} 处章节修改会换算到清理后的文本并保留。'
          '下面这些修改对应的行在清理后不存在或已改变，无法保留；'
          '采用后仍可在变更记录中撤销。',
      skipped: skipped,
    );
    return confirmed ? true : null;
  }

  Future<void> apply() async {
    final drop = await confirmDroppedEdits();
    if (drop == null || !mounted) return;
    await applyPlan(drop);
  }

  Future<void> applyPlan(bool dropSkipped) => run(() async {
    final next = await session.apply(plan!, dropSkipped: dropSkipped);
    if (!mounted) return;
    setState(() {
      receipt = next;
      inspection = null;
      draft = decodeCleanup(session.settings);
      saved = jsonEncode(draft);
      draftIdentity = saved;
      plan = null;
      diff = false;
      undoDraft.clear();
      redoDraft.clear();
    });
    // 正文变了，重新试算内置规则的改动数。
    countBuiltins();
  });
  Future<void> recheck() => run(() async {
    final next = await session.recheck();
    if (mounted) setState(() => inspection = next);
  });
  Future<void> inspectDetails() async {
    final result = await showDialog<CleanupInspectionResult>(
      context: context,
      builder: (_) => CleanupInspectionDialog(
        session: session,
        inspection: inspection!,
        initialLine: widget.inspectLine,
      ),
    );
    if (!mounted || result == null) return;
    if (result is CleanupRuleLocation) {
      if (inspection == null || !session.isInspectionCurrent(inspection!)) {
        setState(() {
          error = '复查已过期，请重新检查。';
        });
        return;
      }
      final index = rules.indexWhere(
        (rule) => cleanupBase(rule)['kind'] == result.kind,
      );
      setState(() {
        receipt = null;
        diff = false;
        if (index >= 0) selected = index;
      });
      await ruleDialog(index < 0 ? null : index, result.kind);
      return;
    }
    final preview = (result as CleanupRemovalPreview).preview;
    if (!session.isCurrent(preview)) {
      setState(() {
        error = '定位生成的方案已过期，请重新检测。';
      });
      return;
    }
    undoDraft.add(draftIdentity);
    if (undoDraft.length > 50) undoDraft.removeAt(0);
    redoDraft.clear();
    setState(() {
      draft = decodeCleanup(preview.request);
      draftIdentity = jsonEncode(draft);
      plan = preview;
      receipt = null;
      diff = true;
      change = 0;
      showCandidates = false;
      showStages = false;
      error = '';
    });
    saveDraft();
    checkImpact(preview);
  }

  Future<void> history(bool redo) async {
    final stack = redo ? redoDraft : undoDraft;
    if (stack.isNotEmpty) {
      session.cancel();
      setState(() {
        (redo ? undoDraft : redoDraft).add(draftIdentity);
        final nextRaw = stack.removeLast();
        draft = decodeCleanup(nextRaw);
        draftIdentity = nextRaw;
        plan = null;
        receipt = null;
        diff = false;
        selected = math.min(selected, math.max(0, rules.length - 1));
      });
      saveDraft();
      return;
    }
    await run(() async {
      try {
        redo ? await session.redo() : await session.undo();
      } on CleanupEditsNeedConfirmation catch (request) {
        // 有章节修改无法换算到撤销 / 重做后的文本：列出并请用户确认。
        if (!mounted ||
            !await resolveCleanupEditConfirmation(context, request)) {
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        draft = decodeCleanup(session.settings);
        saved = jsonEncode(draft);
        draftIdentity = saved;
        plan = null;
        receipt = null;
        diff = false;
      });
    });
  }

  void reorder(int old, int next) {
    if (next == old) return;
    edit(() {
      final entries = rules, order = List.generate(rules.length, (i) => i);
      entries.insert(next, entries.removeAt(old));
      order.insert(next, order.removeAt(old));
      draft['pipeline'] = entries;
      draft['step_exclusions'] = [
        for (final value in (draft['step_exclusions'] as List? ?? []))
          {
            ...value as Map,
            'step_index': order.indexOf(value['step_index'] as int),
          },
      ];
      selected = next;
    });
  }

  Future<void> ruleDialog([int? index, String? suggestedKind]) async {
    if (index == null && rules.length >= 32) {
      setState(() => error = '最多 32 条规则，请先删除不需要的规则。');
      return;
    }
    final probe = widget.library.openCleanup(widget.bookId);
    final frozen = draftIdentity;
    // Rule order can change while an unfinished editor draft is retained.
    final ruleIdentity = index == null
        ? 'new'
        : sha256.convert(utf8.encode(jsonEncode(rules[index]))).toString();
    final draftKey = 'cleanup-rule:${widget.bookId}:$ruleIdentity';
    Map<String, dynamic>? rule;
    try {
      rule = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => CleanupRuleDialog(
          draft: workspace?.readDraft(draftKey),
          onDraft: (value) => workspace?.writeDraft(draftKey, value),
          onDiscard: () => workspace?.writeDraft(draftKey, null),
          initial: index == null
              ? (suggestedKind == null ? null : {'kind': suggestedKind})
              : rules[index],
          changes: probe.changes,
          isCurrent: probe.isCurrent,
          previewRule: (value) {
            final request = decodeCleanup(frozen);
            final steps = (request['pipeline'] as List).toList();
            index == null ? steps.add(value) : steps[index] = value;
            request['pipeline'] = steps;
            return probe.preview(jsonEncode(request));
          },
        ),
      );
    } finally {
      probe.dispose();
    }
    if (!mounted || rule == null) return;
    workspace?.writeDraft(draftKey, null);
    final accepted = rule;
    edit(() {
      final next = rules;
      index == null ? next.add(accepted) : next[index] = accepted;
      draft['pipeline'] = next;
      selected = index ?? next.length - 1;
    });
  }

  Future<void> rangeDialog() async {
    final range = await showDialog<CleanupRange>(
      context: context,
      builder: (_) => CleanupRangeDialog(
        start: draft['start_line'] as int?,
        end: draft['end_line'] as int?,
      ),
    );
    if (!mounted || range == null) return;
    edit(() {
      draft['start_line'] = range.start;
      draft['end_line'] = range.end;
    });
  }

  Future<void> presets() => run(() async {
    final values = await session.presets();
    if (!mounted) return;
    final choice = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => DeskDialog(
        title: '规则库与预设',
        subtitle: '选择一组规则追加到当前规则之后；追加后仍需自动检测并确认。',
        closeTooltip: '取消',
        width: 560,
        height: 480,
        actions: [
          DeskButton(
            '取消',
            quiet: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        child: ListView.builder(
          itemCount: values.length,
          itemBuilder: (_, i) => DeskChoiceRow(
            radio: false,
            title:
                '${values[i]['name'] ?? values[i]['title'] ?? values[i]['id']}',
            detail: '${(values[i]['rules'] as List).length} 条规则 · 追加到当前规则后',
            onTap: () => Navigator.pop(context, values[i]),
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (rules.length + (choice['rules'] as List).length > 32) {
      throw const FormatException('添加后超过 32 条规则。');
    }
    edit(() => draft['pipeline'] = [...rules, ...choice['rules'] as List]);
  });
  void keep(CleanupChange value) {
    if (!showStages && value.end - value.line >= 10000) {
      setState(() => error = '该差异跨越超过 10000 源行，请切换逐步骤差异保留对应步骤，或缩小清理范围。');
      return;
    }
    edit(() {
      if (showStages) {
        draft['step_exclusions'] = [
          ...(draft['step_exclusions'] as List? ?? []),
          {
            'step_index': value.step,
            'source_line': value.line,
            'source_end_line': value.end,
          },
        ];
      } else {
        draft['skip_lines'] = <int>{
          ...((draft['skip_lines'] as List?) ?? []).cast<int>(),
          for (var line = value.line; line <= value.end; line++) line,
        }.toList();
        draft['remove_lines'] = [
          for (final line
              in ((draft['remove_lines'] as List?) ?? []).cast<int>())
            if (line < value.line || line > value.end) line,
        ];
      }
    }, preserveResults: true);
  }

  // ---------------------------------------------------------------- 视图（设计~L）

  /// 窄窗时左右两栏改为分段切换：0 规则，1 预览。
  int pane = 1;

  /// 用户展开逐行查看的连续空行组（按组首行号）。
  final expandedBlanks = <int>{};

  Widget header() {
    final d = context.desk;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: d.canvas,
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Text('文本清理', style: ui(16, w: 650, c: d.ink)),
          const Spacer(),
          DeskButton(
            draft['start_line'] == null && draft['end_line'] == null
                ? '范围：全部源行'
                : '源行 ${draft['start_line'] ?? 1}–${draft['end_line'] ?? '末尾'}',
            icon: Icons.straighten_rounded,
            quiet: true,
            onPressed: busy ? null : rangeDialog,
          ),
          DeskButton(
            '应用到多本书',
            icon: Icons.library_add_check_outlined,
            quiet: true,
            onPressed: busy ? null : batch,
          ),
          DeskButton(
            '本书检查',
            icon: Icons.fact_check_outlined,
            quiet: true,
            onPressed: busy ? null : widget.onChecks,
          ),
        ],
      ),
    );
  }

  Widget rulesColumn() {
    final d = context.desk;
    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: d.line)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  showOrder
                      ? '有序规则 · ${rules.length} / 32'
                      : '清理规则 · 已开 ${rules.where((s) => s['enabled'] != false).length} 条',
                  style: ui(13, w: 650, c: d.ink),
                ),
              ),
              IconButton(
                tooltip: '撤销',
                onPressed:
                    !busy &&
                        (undoDraft.isNotEmpty || (!dirty && session.canUndo))
                    ? () => history(false)
                    : null,
                icon: const Icon(Icons.undo_rounded, size: 18),
              ),
              IconButton(
                tooltip: '重做',
                onPressed:
                    !busy &&
                        (redoDraft.isNotEmpty || (!dirty && session.canRedo))
                    ? () => history(true)
                    : null,
                icon: const Icon(Icons.redo_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          DeskSegmented<bool>(
            key: const ValueKey('cleanup-rules-tab'),
            value: showOrder,
            options: const {false: '内置规则', true: '执行顺序'},
            onChanged: (v) => setState(() => showOrder = v),
          ),
          const SizedBox(height: 6),
          if (!showOrder) ...[
            Expanded(
              child: CleanupBuiltinRules(
                rules: rules,
                counts: builtinCounts,
                counting: countingBuiltins,
                enabled: !busy,
                onToggle: toggleBuiltin,
                onEdit: (i) => ruleDialog(i),
              ),
            ),
            const SizedBox(height: 8),
            DeskButton(
              '添加自定义替换…',
              icon: Icons.add_rounded,
              onPressed: busy
                  ? null
                  : () => ruleDialog(null, 'literal_replace'),
            ),
          ] else ...[
            SelectAllHeader(
              selected: rules.where((s) => s['enabled'] != false).length,
              total: rules.length,
              compact: false,
              padding: const EdgeInsets.only(left: 21),
              onChanged: busy
                  ? null
                  : (v) => toggleRules([
                      for (var i = 0; i < rules.length; i++) i,
                    ], v),
              body: Text(
                '从上到下执行，可拖动调整顺序；双击编辑。',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(11.5, c: d.ink3),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: rules.length,
                  onReorderItem: busy ? (_, _) {} : reorder,
                  itemBuilder: (context, i) => ruleRow(i),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DeskButton(
                    '规则库与预设',
                    icon: Icons.library_books_outlined,
                    onPressed: busy ? null : presets,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: DeskButton(
                    '添加规则',
                    icon: Icons.add_rounded,
                    onPressed: busy ? null : () => ruleDialog(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: DeskButton(
                    '编辑规则',
                    icon: Icons.edit_outlined,
                    onPressed: busy || rules.isEmpty
                        ? null
                        : () => ruleDialog(selected),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: DeskButton(
                    '删除规则',
                    icon: Icons.delete_outline_rounded,
                    disabledReason: '至少保留一条规则',
                    onPressed: busy || rules.length < 2 ? null : deleteSelected,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(statusText, style: ui(11.5, c: d.ink3, h: 1.5)),
          const SizedBox(height: 8),
          DeskButton(
            '自动检测',
            icon: Icons.play_arrow_rounded,
            onPressed: busy ? null : detect,
          ),
        ],
      ),
    );
  }

  String get statusText => receipt != null
      ? '清理已采用 · 原稿保留'
      : plan == null
      ? '修改规则后请点自动检测；检测不会自动采用。'
      : plan != null && session.isCurrent(plan!)
      ? '检测完成 · ${plan!.total} 处变更 · ${plan!.candidateTotal} 条提示候选'
      : '结果已过期，请重新检测。';

  void deleteSelected() => edit(() {
    final next = rules..removeAt(selected);
    draft['pipeline'] = next;
    draft['step_exclusions'] = [
      for (final v in (draft['step_exclusions'] as List? ?? []))
        if (v['step_index'] != selected)
          {
            ...v as Map,
            'step_index': (v['step_index'] as int) > selected
                ? (v['step_index'] as int) - 1
                : v['step_index'],
          },
    ];
    selected = math.min(selected, next.length - 1);
  });

  void toggleRule(int i, bool? enabled) => toggleRules([i], enabled);

  /// 左栏页签：false 内置规则清单，true 有序规则（执行顺序、预设与自定义）。
  bool showOrder = false;
  final builtinCounts = <String, int?>{};
  bool countingBuiltins = false;

  /// 内置规则开关：已有就启用或停用；没有就按默认设置插到同类内置规则的相对位置。
  /// 简体转繁体与繁体转简体只开一个。
  void toggleBuiltin(BuiltinCleanupRule item, bool on) {
    final order = [for (final (_, items) in builtinCleanupGroups) ...items];
    final current = rules;
    final index = current.indexWhere(item.matches);
    if (index < 0 && on && current.length >= 32) {
      setState(() => error = '最多 32 条规则，请先删除不需要的规则。');
      return;
    }
    edit(() {
      final next = rules;
      void set(int i, bool enabled) {
        final step = next[i];
        next[i] = step['kind'] == 'configured'
            ? {...step, 'enabled': enabled}
            : {
                'kind': 'configured',
                'enabled': enabled,
                'scope': 'all',
                'rule': step,
              };
      }

      final at = next.indexWhere(item.matches);
      if (at >= 0) {
        set(at, on);
      } else if (on) {
        final pos = order.indexOf(item);
        var insertAt = next.length;
        for (var k = 0; k < next.length; k++) {
          final other = order.indexWhere((b) => b.matches(next[k]));
          if (other > pos) {
            insertAt = k;
            break;
          }
        }
        next.insert(insertAt, item.step());
      }
      if (on && item.kind == 'chinese_variant') {
        for (var k = 0; k < next.length; k++) {
          final base = cleanupBase(next[k]);
          if (base['kind'] == 'chinese_variant' &&
              !item.matches(next[k]) &&
              next[k]['enabled'] != false) {
            set(k, false);
          }
        }
      }
      draft['pipeline'] = next;
    });
  }

  /// 每条内置规则单独执行时会改几处：在后台逐条试算，只读不改书稿。
  Future<void> countBuiltins() async {
    if (countingBuiltins || !mounted) return;
    final probe = widget.library.openCleanup(widget.bookId);
    setState(() => countingBuiltins = true);
    try {
      final base = decodeCleanup(draftIdentity)
        ..['remove_lines'] = <int>[]
        ..['skip_lines'] = <int>[]
        ..['step_exclusions'] = <Map>[];
      for (final (_, items) in builtinCleanupGroups) {
        for (final item in items) {
          if (!mounted) return;
          int? total;
          try {
            final result = await probe.preview(
              jsonEncode({
                ...base,
                'pipeline': [item.step()],
              }),
            );
            total = result.total;
          } catch (_) {
            total = null;
          }
          if (!mounted) return;
          setState(() => builtinCounts[item.id] = total);
        }
      }
    } finally {
      probe.dispose();
      if (mounted) setState(() => countingBuiltins = false);
    }
  }

  /// 一次启用或停用多条规则（表头全选、Shift 选一段）。
  void toggleRules(Iterable<int> indexes, bool? enabled) => edit(() {
    final next = rules;
    for (final i in indexes) {
      final step = next[i];
      next[i] = step['kind'] == 'configured'
          ? {...step, 'enabled': enabled}
          : {
              'kind': 'configured',
              'enabled': enabled,
              'scope': 'all',
              'rule': step,
            };
    }
    draft['pipeline'] = next;
  });
  final ruleRange = RangeSelection(), candidateRange = RangeSelection();

  /// 本页提示候选一次勾选或取消（勾选即排除该行）。
  void selectCandidates(Iterable<CleanupCandidate> values, bool selected) =>
      edit(() {
        final lines = ((draft['remove_lines'] as List?) ?? [])
            .cast<int>()
            .toSet();
        for (final value in values.where((c) => c.selectable)) {
          selected ? lines.add(value.line) : lines.remove(value.line);
        }
        draft['remove_lines'] = lines.toList();
      }, preserveResults: true);

  /// 规则行的单击与双击：单击立即选中并跳到这条规则的变更，0.3 秒内再点同一行打开编辑。
  DateTime? lastRuleTap;
  int? lastRuleTapIndex;
  void tapRule(int i) {
    final now = DateTime.now();
    final again =
        lastRuleTapIndex == i &&
        lastRuleTap != null &&
        now.difference(lastRuleTap!) < kDoubleTapTimeout;
    lastRuleTap = again ? null : now;
    lastRuleTapIndex = i;
    if (again) {
      ruleDialog(i);
      return;
    }
    setState(() => selected = i);
    jumpToRule(i);
  }

  /// 变更列表的滚动与当前项：点规则跳到它的第一处时，把这一项滚到列表上方可见处。
  final changeList = ScrollController();
  final currentChangeKey = GlobalKey();
  void revealChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !changeList.hasClients) return;
      final target = currentChangeKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.05);
        return;
      }
      // 还没建出来（在可见区以外）：先按估计行高滚过去，下一帧再精确对齐。
      final estimate = (change * 84.0).clamp(
        0.0,
        changeList.position.maxScrollExtent,
      );
      changeList.jumpTo(estimate);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final again = currentChangeKey.currentContext;
        if (mounted && again != null) {
          Scrollable.ensureVisible(again, alignment: 0.05);
        }
      });
    });
  }

  /// 已检测且这条规则有变更时，切到“逐步骤差异”并定位到它的第一处。逐步骤记录按规则顺序排列，
  /// 第一处的位置是前面各条规则变更数之和；每页 40 条，不在当前页时读那一页。
  void jumpToRule(int i) {
    final p = plan;
    if (p == null || !session.isCurrent(p) || (p.stepCounts[i] ?? 0) == 0) {
      return;
    }
    var start = 0;
    for (var j = 0; j < i; j++) {
      start += p.stepCounts[j] ?? 0;
    }
    final page = start - start % 40;
    if (showStages && page == p.offset) {
      setState(() => change = start - page);
      revealChange();
      return;
    }
    run(() async {
      final next = page == p.offset
          ? p
          : await session.preview(draftIdentity, offset: page);
      if (!mounted) return;
      setState(() {
        plan = next;
        showStages = true;
        diff = false;
        change = (start - page).clamp(
          0,
          next.stages.isEmpty ? 0 : next.stages.length - 1,
        );
      });
      revealChange();
    });
  }

  Widget ruleRow(int i) {
    final d = context.desk;
    final step = rules[i];
    final on = selected == i;
    final enabled = step['enabled'] != false;
    return Container(
      key: ValueKey('rule-$i-${cleanupBase(step)['kind']}'),
      margin: const EdgeInsets.only(bottom: 4),
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
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        // 不用 onDoubleTap：同时设了双击时，单击要等双击判定超时（约 0.3 秒）才生效。
        onTap: busy ? null : () => tapRule(i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: i,
                enabled: !busy,
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 17,
                  color: d.ink3,
                ),
              ),
              Checkbox(
                value: enabled,
                onChanged: busy
                    ? null
                    : (v) => toggleRules(ruleRange.span(i), v),
              ),
              // 执行顺序号胶囊（视觉语言）；停用的步骤一起变淡。
              DeskPill(
                Text(
                  '${i + 1}',
                  style: mono(10.5, w: 600, c: enabled ? d.ink2 : d.ink3),
                ),
                color: enabled ? d.sunken : d.canvas,
                outlined: !enabled,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cleanupLabel(step),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(12.5, w: 600, c: enabled ? d.ink : d.ink3),
                    ),
                    Text(
                      '${{'all': '全文', 'body': '正文', 'headings': '标题'}[step['scope'] ?? 'all']} · ${plan == null ? '待检测' : '${plan!.stepCounts[i] ?? 0} 处变更'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(11.5, c: d.ink3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String visible(String content) => showWhitespace
      ? content
            .replaceAll(' ', '·')
            .replaceAll('\t', '⇥')
            .replaceAll('\n', '↵\n')
      : content;

  /// 本页变更列表中的一对“修改前 / 修改后”；选中行加灰墨左条并给出保留按钮。
  Widget pairRow(CleanupChange value, int index, bool current) {
    final d = context.desk;
    final on =
        index ==
        math.min(
          change,
          math.max(0, (showStages ? plan!.stages : plan!.actions).length - 1),
        );
    final deleted = value.after == null;
    final after = value.after ?? '';
    return InkWell(
      key: on ? currentChangeKey : ValueKey('cleanup-change-${value.line}'),
      onTap: busy
          ? null
          : () {
              setState(() => change = index);
              board?.noteLine(value.line, value.end);
            },
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: on ? d.surface : null,
          border: Border(
            bottom: BorderSide(color: d.line),
            left: BorderSide(
              color: on ? d.accent : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 66,
              child: Text(
                value.line == value.end
                    ? '${value.line}'
                    : '${value.line}–${value.end}',
                style: mono(10.5, c: d.ink3),
              ),
            ),
            Expanded(
              child: Text.rich(
                key: ValueKey('cleanup-before-$index'),
                value.before.trim().isEmpty && !showWhitespace
                    ? TextSpan(
                        text: '（空行）',
                        style: serif(
                          13.5,
                          c: d.del,
                          h: 1.6,
                        ).copyWith(backgroundColor: d.delSoft),
                      )
                    : inlineDiffSpan(
                        value.before,
                        after,
                        base: serif(13.5, c: d.ink2, h: 1.6),
                        changed: serif(
                          13.5,
                          c: d.del,
                          h: 1.6,
                        ).copyWith(backgroundColor: d.delSoft),
                        marks: showWhitespace,
                      ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: deleted
                  ? Text('（删除此行）', style: serif(13.5, c: d.ink3, h: 1.6))
                  : Text.rich(
                      key: ValueKey('cleanup-after-$index'),
                      inlineDiffSpan(
                        after,
                        value.before,
                        base: serif(13.5, c: d.ink2, h: 1.6),
                        changed: serif(
                          13.5,
                          c: d.add,
                          h: 1.6,
                        ).copyWith(backgroundColor: d.addSoft),
                        marks: showWhitespace,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            if (showStages) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 132 * textScale,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: DeskTag(
                      '${value.step + 1} ${cleanupLabel(rules[math.min(value.step, rules.length - 1)])}',
                      Tone.neutral,
                    ),
                  ),
                ),
              ),
            ],
            ...actionSlot(on && !diff, [
              if (!showStages && expandedBlanks.contains(value.line))
                DeskButton(
                  '收起',
                  quiet: true,
                  onPressed: () =>
                      setState(() => expandedBlanks.remove(value.line)),
                ),
              DeskButton(
                showStages ? '保留本步原文' : '保留原文',
                quiet: true,
                onPressed: busy || !current ? null : () => keep(value),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  double get textScale => MediaQuery.textScalerOf(context).scale(10) / 10;

  /// 差异行右侧固定留出操作区，选中行多出按钮时其他行的右栏不再错位。
  List<Widget> actionSlot(bool show, List<Widget> buttons) => diff
      ? const []
      : [
          const SizedBox(width: 6),
          SizedBox(
            // 最终差异里连续空行一组有两个按钮，各行统一按两个按钮留宽。
            width: (showStages ? 112 : 170) * textScale,
            child: show
                ? Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 2,
                    children: buttons,
                  )
                : null,
          ),
        ];

  /// 最终差异里相邻的整行空行删除合并成一组；逐步骤差异照旧逐条列出。
  List<List<int>> changeGroups(List<CleanupChange> changes) {
    bool blank(CleanupChange c) => c.after == null && c.before.trim().isEmpty;
    final groups = <List<int>>[];
    var run = -1; // 当前这串连续空行的首行；展开按它记，整串都逐行列出。
    for (var i = 0; i < changes.length; i++) {
      final c = changes[i];
      final continues =
          i > 0 &&
          blank(c) &&
          blank(changes[i - 1]) &&
          changes[i - 1].end + 1 == c.line;
      if (!continues) run = c.line;
      if (!showStages && continues && !expandedBlanks.contains(run)) {
        groups.last.add(i);
      } else {
        groups.add([i]);
      }
    }
    return groups;
  }

  /// 后端把一段连续空行记成一处变更（跨多行的整行空行删除），最终差异里同样按一组显示。
  bool blankRun(CleanupChange c) =>
      !showStages &&
      c.after == null &&
      c.before.trim().isEmpty &&
      c.end > c.line;

  /// 一组连续空行：一行显示，可整组保留；前端合并的组还可展开后逐行处理。
  Widget blankGroupRow(
    List<int> group,
    List<CleanupChange> changes,
    bool current,
  ) {
    final d = context.desk;
    final first = changes[group.first], last = changes[group.last];
    final on = group.contains(math.min(change, changes.length - 1));
    return InkWell(
      key: ValueKey('cleanup-blank-group-${first.line}'),
      onTap: busy
          ? null
          : () {
              setState(() => change = group.first);
              board?.noteLine(first.line, last.end);
            },
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: on ? d.surface : null,
          border: Border(
            bottom: BorderSide(color: d.line),
            left: BorderSide(
              color: on ? d.accent : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 66,
              child: Text(
                '${first.line}–${last.end}',
                style: mono(10.5, c: d.ink3),
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: '（${last.end - first.line + 1} 个连续空行）',
                  style: serif(
                    13.5,
                    c: d.del,
                    h: 1.6,
                  ).copyWith(backgroundColor: d.delSoft),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('（删除这些行）', style: serif(13.5, c: d.ink3, h: 1.6)),
            ),
            ...actionSlot(on && !diff, [
              if (group.length > 1)
                DeskButton(
                  '逐行',
                  quiet: true,
                  onPressed: busy
                      ? null
                      : () => setState(() => expandedBlanks.add(first.line)),
                ),
              DeskButton(
                '保留这些行',
                quiet: true,
                onPressed: busy || !current
                    ? null
                    : () => keep(
                        CleanupChange(
                          first.line,
                          last.end,
                          first.step,
                          '',
                          null,
                          first.reason,
                          false,
                        ),
                      ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget candidateRow(int index, bool current) {
    final d = context.desk;
    final c = plan!.candidates[index];
    void select(bool value) => selectCandidates([
      for (final i in candidateRange.span(index)) plan!.candidates[i],
    ], value);
    return InkWell(
      key: ValueKey('cleanup-candidate-${c.line}'),
      onTap: busy || !current || !c.selectable
          ? null
          : () {
              board?.noteLine(c.line, c.line);
              setState(() => focusedCandidate = c.line);
              select(!c.selected);
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: focusedCandidate == c.line ? d.sunken : null,
          border: Border(bottom: BorderSide(color: d.line)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: c.selected,
              onChanged: busy || !current || !c.selectable
                  ? null
                  : (v) => select(v!),
            ),
            SizedBox(
              width: 70,
              child: Text('原稿第 ${c.line} 行', style: mono(10.5, c: d.ink3)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${c.text}${c.truncated ? '…（节选）' : ''}',
                    style: serif(13.5, c: d.ink, h: 1.5),
                  ),
                  if (!c.selectable) Text('受保护，不可排除', style: ui(11, c: d.ink3)),
                ],
              ),
            ),
            Text(
              c.selected ? '排除此行' : '保留',
              style: ui(11.5, c: c.selected ? d.del : d.ink3),
            ),
          ],
        ),
      ),
    );
  }

  /// 本页提示候选：表头三态勾选（勾选即排除该行，默认不勾选）。
  Widget candidateList(bool current) {
    final d = context.desk;
    final page = plan!.candidates;
    final selectable = page.where((c) => c.selectable).toList();
    final enabled = !busy && current;
    return SelectionKeys(
      hasSelection: selectable.any((c) => c.selected),
      onSelectAll: enabled ? () => selectCandidates(selectable, true) : null,
      onClear: enabled ? () => selectCandidates(selectable, false) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: SelectAllHeader(
              selected: selectable.where((c) => c.selected).length,
              total: selectable.length,
              compact: false,
              padding: const EdgeInsets.only(left: 10, right: 10),
              note: '本页 · 勾选即排除此行',
              onChanged: enabled
                  ? (v) => selectCandidates(selectable, v)
                  : null,
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: candidateScroll,
              itemCount: page.length,
              itemBuilder: (_, i) => candidateRow(i, current),
            ),
          ),
        ],
      ),
    );
  }

  Widget textPane(
    String label,
    String content,
    bool after, {
    Future<String>? sourceContext,
    VoidCallback? completeView,
    String? other,
  }) {
    final d = context.desk;
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: d.paper,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: d.line),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: ui(11.5, w: 600, c: after ? d.add : d.del),
                ),
              ),
              if (completeView != null)
                DeskButton('查看完整步骤', quiet: true, onPressed: completeView),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (other == null)
                    SelectableText(
                      visible(content),
                      style: serif(15, c: d.ink, h: 1.75),
                    )
                  else
                    SelectableText.rich(
                      inlineDiffSpan(
                        content,
                        other,
                        base: serif(15, c: d.ink, h: 1.75),
                        changed: serif(15, c: after ? d.add : d.del, h: 1.75)
                            .copyWith(
                              backgroundColor: after ? d.addSoft : d.delSoft,
                            ),
                        marks: showWhitespace,
                      ),
                    ),
                  if (sourceContext != null) ...[
                    Divider(color: d.line),
                    Text('原稿上下文', style: ui(11.5, c: d.ink3)),
                    FutureBuilder<String>(
                      future: sourceContext,
                      builder: (context, snapshot) => SelectableText(
                        snapshot.hasError
                            ? '上下文已过期，请重新检测。'
                            : snapshot.data ?? '正在读取上下文…',
                        style: serif(13, c: d.ink2, h: 1.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget detail(CleanupChange entry, bool current) {
    if (!showStages && session is PairedCleanupContextSession) {
      return CleanupPairedContext(
        key: ValueKey('$current:${plan!.id}:${entry.line}:${entry.end}'),
        session: session as PairedCleanupContextSession,
        preview: plan!,
        change: entry,
        showWhitespace: showWhitespace,
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: textPane(
            '${showStages ? '步骤前 · 对应原稿' : '原文'} · 第 ${entry.line}–${entry.end} 行${entry.truncated ? ' · 节选' : ''}',
            entry.before,
            false,
            other: entry.after ?? '',
            sourceContext: contextFuture,
            completeView: showStages && session is PairedCleanupContextSession
                ? () => showDialog<void>(
                    context: context,
                    builder: (_) => CleanupRegionDialog(
                      session: session as PairedCleanupContextSession,
                      preview: plan!,
                      change: entry,
                      regionLine: entry.line,
                      showWhitespace: showWhitespace,
                      stage: true,
                    ),
                  )
                : null,
          ),
        ),
        Expanded(
          child: textPane(
            '${showStages ? '步骤后' : '清理后'}${entry.truncated ? ' · 节选' : ''}',
            entry.after ?? '（排除此行）',
            true,
            other: entry.after == null ? null : entry.before,
          ),
        ),
      ],
    );
  }

  Widget previewColumn() {
    final d = context.desk;
    final current = plan != null && session.isCurrent(plan!);
    final changes =
        (showStages ? plan?.stages : plan?.actions) ?? const <CleanupChange>[];
    final changeTotal = (showStages ? plan?.stageTotal : plan?.total) ?? 0;
    final entry = changes.isEmpty
        ? null
        : changes[math.min(change, changes.length - 1)];
    final groups = changeGroups(changes);
    final at = groups.indexWhere(
      (g) => g.contains(math.min(change, math.max(0, changes.length - 1))),
    );
    final key = '$current:$showStages:${plan?.id}:${entry?.line}:${entry?.end}';
    if (key != contextKey) {
      contextKey = key;
      contextFuture =
          current &&
              entry != null &&
              session is CleanupContextSession &&
              (showStages || session is! PairedCleanupContextSession)
          ? (session as CleanupContextSession).previewSource(plan!, entry)
          : null;
    }
    final toolbar = Container(
      constraints: const BoxConstraints(minHeight: 50),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (diff) ...[
            Text('清理差异 · 尚未应用', style: ui(13.5, w: 650, c: d.ink)),
            Text('确认应用前，正文不会改变。', style: ui(12, c: d.ink3)),
          ] else ...[
            KeyedSubtree(
              key: const ValueKey('cleanup-diff-kind'),
              child: DeskSegmented<bool>(
                value: showStages,
                options: const {false: '最终差异', true: '逐步骤差异'},
                onChanged: busy
                    ? null
                    : (v) {
                        setState(() {
                          showStages = v;
                          showCandidates = false;
                          change = 0;
                        });
                        if (plan != null && plan!.offset != 0) {
                          detect(asDiff: diff);
                        }
                      },
              ),
            ),
            KeyedSubtree(
              key: const ValueKey('cleanup-view'),
              child: DeskSegmented<bool>(
                value: showCandidates,
                options: {
                  false: '查看变更',
                  true: plan == null
                      ? '核对提示候选'
                      : '核对提示候选 ${plan!.candidateTotal}',
                },
                onChanged: plan == null || busy
                    ? null
                    : (v) {
                        setState(() {
                          showCandidates = v;
                          change = 0;
                        });
                        if (plan!.offset != 0) {
                          detect(asDiff: diff);
                        }
                      },
              ),
            ),
          ],
          // 空白标记开关并入“⋯”，窄窗时工具栏不再把它单独挤到第二行。
          DeskCommandMenu<String>(
            key: const ValueKey('cleanup-view-menu'),
            enabled: !busy,
            tooltip: '显示与保留管理',
            icon: Icon(Icons.more_horiz_rounded, color: d.ink2),
            itemBuilder: (_) => [
              PopupMenuItem(
                height: 36,
                value: 'whitespace',
                child: Text(showWhitespace ? '隐藏空白标记' : '显示空白标记'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                height: 36,
                value: 'notices',
                child: Text('清空提示候选排除选择'),
              ),
              const PopupMenuItem(
                height: 36,
                value: 'kept',
                child: Text('清空逐行与逐步骤保留选择'),
              ),
            ],
            onSelected: (value) {
              if (value == 'whitespace') {
                setState(() => showWhitespace = !showWhitespace);
                return;
              }
              edit(() {
                if (value == 'notices') {
                  draft['remove_lines'] = <int>[];
                } else {
                  draft['skip_lines'] = <int>[];
                  draft['step_exclusions'] = <Map<String, dynamic>>[];
                }
              });
            },
          ),
        ],
      ),
    );
    final kept =
        ((draft['skip_lines'] as List?)?.length ?? 0) +
        ((draft['step_exclusions'] as List?)?.length ?? 0);
    final summary = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('本次结果', style: ui(12, w: 600, c: d.ink2)),
          if (plan == null)
            Text(busy ? '检测中…' : '尚未检测', style: ui(12, c: d.ink3))
          else ...[
            DeskTag(
              '$changeTotal ${showStages ? '条步骤记录' : '处可预览'}',
              Tone.neutral,
            ),
            DeskTag('提示候选 ${plan!.candidateTotal}', Tone.warn),
            if (kept > 0) DeskTag('已保留 $kept', Tone.neutral),
            if (!current) const DeskTag('结果已过期，请重新检测', Tone.pen),
            ?impactTag(),
          ],
        ],
      ),
    );
    final Widget body;
    if (showCandidates) {
      body = (plan?.candidates.isEmpty ?? true)
          ? Center(
              child: Text('本页没有提示候选。', style: ui(12.5, c: d.ink3)),
            )
          : candidateList(current);
    } else if (entry == null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              plan != null
                  ? '所选规则未发现需要清理的内容。'
                  : busy
                  ? '正在按规则逐行检测，结果出来后先显示差异…'
                  : error.isNotEmpty
                  ? '检测没有完成，原因见上方。'
                  : '尚未检测。修改规则后点“自动检测”。',
              style: ui(12.5, c: d.ink3),
            ),
            if (plan != null) ...[
              const SizedBox(height: 4),
              Text('可以“添加规则”，或从“规则库与预设”选一组预设后重新检测。', style: ui(12, c: d.ink3)),
            ],
          ],
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, box) {
          const handle = 10.0, minTop = 90.0, minBottom = 140.0;
          final room = box.maxHeight - handle;
          final top = room <= minTop + minBottom
              ? room / 2
              : (room * split).clamp(minTop, room - minBottom);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: top,
                child: ListView.builder(
                  controller: changeList,
                  itemCount: groups.length,
                  itemBuilder: (_, i) =>
                      groups[i].length == 1 &&
                          !blankRun(changes[groups[i].first])
                      ? pairRow(
                          changes[groups[i].first],
                          groups[i].first,
                          current,
                        )
                      : blankGroupRow(groups[i], changes, current),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                child: GestureDetector(
                  key: const ValueKey('cleanup-split-handle'),
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onVerticalDragStart: (drag) {
                    dragTop = top;
                    dragOrigin = drag.globalPosition.dy;
                  },
                  onVerticalDragUpdate: (drag) => setState(
                    () => split =
                        (((dragTop ?? top) +
                                    drag.globalPosition.dy -
                                    (dragOrigin ?? drag.globalPosition.dy)) /
                                room)
                            .clamp(.15, .85),
                  ),
                  onVerticalDragEnd: (_) => dragTop = dragOrigin = null,
                  onVerticalDragCancel: () => dragTop = dragOrigin = null,
                  onDoubleTap: () => setState(() => split = .6),
                  child: Tooltip(
                    message: '拖动调整上下比例，双击恢复默认',
                    waitDuration: const Duration(milliseconds: 600),
                    child: SizedBox(
                      height: handle,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Divider(height: 1, color: d.line),
                          Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: d.lineStrong,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: detail(entry, current),
                ),
              ),
            ],
          );
        },
      );
    }
    final position = plan == null
        ? ''
        : showCandidates
        ? '提示候选 ${plan!.candidates.isEmpty ? 0 : plan!.offset + 1}–${plan!.offset + plan!.candidates.length} / ${plan!.candidateTotal}'
        : '${changeTotal == 0 ? 0 : plan!.offset + change + 1} / $changeTotal${showStages && entry != null ? ' · 规则 ${entry.step + 1}' : ' · 原稿范围'}';
    final footer = Container(
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: d.surface,
        border: Border(top: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          unlessBoard(
            DeskButton(
              '上一处',
              icon: Icons.keyboard_arrow_up_rounded,
              quiet: true,
              onPressed: busy || !current || plan!.offset + change == 0
                  ? null
                  : () {
                      if (!showCandidates && at > 0) {
                        setState(() => change = groups[at - 1].first);
                      } else if (change > 0 && !showCandidates) {
                        setState(() => change = 0);
                      } else {
                        detect(
                          offset: math.max(0, plan!.offset - 40),
                          asDiff: diff,
                        );
                      }
                    },
            ),
          ),
          unlessBoard(
            DeskButton(
              '下一处',
              icon: Icons.keyboard_arrow_down_rounded,
              quiet: true,
              onPressed:
                  busy ||
                      !current ||
                      (showCandidates
                          ? plan!.offset + 40 >= plan!.candidateTotal
                          : plan!.offset +
                                    (at < 0 ? change : groups[at].last) +
                                    1 >=
                                changeTotal)
                  ? null
                  : () {
                      if (!showCandidates &&
                          at >= 0 &&
                          at + 1 < groups.length) {
                        setState(() => change = groups[at + 1].first);
                      } else {
                        detect(offset: plan!.offset + 40, asDiff: diff);
                      }
                    },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: unlessBoard(
              Text(
                position,
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: d.ink3),
              ),
            ),
          ),
          if (diff) ...[
            DeskButton(
              '返回调整',
              quiet: true,
              onPressed: busy ? null : () => setState(() => diff = false),
            ),
            const SizedBox(width: 8),
            DeskButton(
              '确认采用清理方案',
              key: const Key('cleanup-apply'),
              primary: true,
              icon: Icons.check_rounded,
              disabledReason: impactBlocker ?? '结果已过期或没有变更，请重新检测',
              onPressed:
                  busy ||
                      !current ||
                      (plan?.total ?? 0) == 0 ||
                      impactBlocker != null
                  ? null
                  : apply,
            ),
          ] else
            Tooltip(
              message: '查看清理差异；确认采用前正文不会改变',
              child: DeskButton(
                '查看清理差异…',
                primary: true,
                icon: Icons.arrow_forward_rounded,
                disabledReason: '先自动检测，且至少有一处变更',
                onPressed: busy || !current || (plan?.total ?? 0) == 0
                    ? null
                    : () => setState(() => diff = true),
              ),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar,
        summary,
        ?impactNote(),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            decoration: BoxDecoration(
              color: d.paper,
              borderRadius: BorderRadius.circular(10),
              boxShadow: d.shadow1,
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(type: MaterialType.transparency, child: body),
          ),
        ),
        footer,
      ],
    );
  }

  /// 不能采用的原因；可以采用（含需确认放弃的情况）时为 null。
  String? get impactBlocker {
    if (plan == null) return null;
    if (impactError.isNotEmpty) return impactError;
    if (impact == null) return '正在核对与章节修改的关系，请稍候';
    if (impact!.checkpoint) return cleanupCheckpointMessage;
    return null;
  }

  Widget? impactTag() {
    if (impactBusy) {
      return const DeskTag('正在核对与章节修改的关系…', Tone.neutral);
    }
    final value = impact;
    if (impactError.isNotEmpty) return const DeskTag('核对未完成', Tone.pen);
    if (value == null || value.edits == 0) return null;
    if (value.checkpoint) return const DeskTag('章节修改是旧版快照，无法换算', Tone.pen);
    if (value.skipped.isNotEmpty) {
      return DeskTag('${value.skipped.length} 处章节修改无法保留', Tone.pen);
    }
    return DeskTag('${value.edits} 处章节修改会随清理保留', Tone.neutral);
  }

  Widget? impactNote() {
    final value = impact;
    final String text;
    if (impactError.isNotEmpty) {
      text = impactError;
    } else if (value != null && value.checkpoint) {
      text = cleanupCheckpointMessage;
    } else if (value != null && value.skipped.isNotEmpty) {
      final shown = value.skipped
          .take(3)
          .map((s) => '第 ${s.index + 1} 处 · ${s.action}：${s.reason}')
          .join('\n');
      final more = value.skipped.length > 3
          ? '\n……另有 ${value.skipped.length - 3} 处'
          : '';
      text =
          '你在章节页做过 ${value.edits} 处修改。清理会改动原文，'
          '其中 ${value.edits - value.skipped.length} 处可以换算到清理后的文本并保留，'
          '${value.skipped.length} 处无法保留：\n$shown$more\n'
          '采用时会先请你确认是否放弃这些修改。';
    } else {
      return null;
    }
    return Padding(
      key: const Key('cleanup-impact-note'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: DeskNote(text, title: '清理与章节修改', tone: Tone.warn),
    );
  }

  Widget stat(
    String value,
    String label, {
    VoidCallback? onTap,
    String? tooltip,
    Key? key,
  }) {
    final d = context.desk;
    final box = Container(
      width: 170,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: d.sunken,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: ui(18, w: 680, c: d.ink)),
          Text(label, style: ui(11.5, c: d.ink2)),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('到检查页查看 →', style: ui(11.5, c: d.accent)),
            ),
        ],
      ),
    );
    if (onTap == null) return box;
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        key: key,
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: box,
        ),
      ),
    );
  }

  Widget result() {
    final d = context.desk;
    final inspectionText = inspection == null
        ? '基础清理尚未复查。'
        : !session.isInspectionCurrent(inspection!)
        ? '复查已过期，请重新检查。'
        : '草稿基础复查：${inspection!.changes} 处空白变更 · ${inspection!.candidates} 条广告候选。';
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: d.surface,
            borderRadius: BorderRadius.circular(12),
            boxShadow: d.shadow1,
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: d.addSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.check_rounded, size: 18, color: d.add),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已采用 ${receipt!.changes} 处清理',
                      style: ui(15, w: 650, c: d.ink),
                    ),
                    Text('当前草稿已更新并自动保存，原稿保留。', style: ui(12, c: d.ink2)),
                  ],
                ),
              ),
              DeskButton(
                '撤销本次清理',
                icon: Icons.undo_rounded,
                onPressed: busy || !session.canUndo
                    ? null
                    : () => history(false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            stat('${receipt!.changes} 处', '规则变更已纳入草稿'),
            stat('${receipt!.candidates} 条', '提示候选；未选择的原文保留'),
            // 有待核对项时这一格可点，直接到检查页。
            stat(
              '${receipt!.chapterIssues} 项',
              '有效章节结构待核对',
              key: const ValueKey('cleanup-result-chapter-issues'),
              tooltip: '清理后草稿的章节结构有 ${receipt!.chapterIssues} 项需要核对，点此到检查页查看',
              onTap: receipt!.chapterIssues > 0 && !busy
                  ? widget.onChecks
                  : null,
            ),
            if (receipt!.editsKept > 0)
              stat('${receipt!.editsKept} 处', '章节修改已随清理保留'),
            if (receipt!.editsDropped > 0)
              stat('${receipt!.editsDropped} 处', '章节修改已按确认放弃'),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: d.surface,
            borderRadius: BorderRadius.circular(12),
            boxShadow: d.shadow1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('复查当前草稿', style: ui(13, w: 650, c: d.ink)),
              const SizedBox(height: 2),
              Text(
                '基础复查检查当前草稿的行尾空白、连续空行与广告候选；不重放自定义替换规则。',
                style: ui(12, c: d.ink2),
              ),
              const SizedBox(height: 8),
              Text(inspectionText, style: ui(12.5, c: d.ink)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  DeskButton(
                    '复查当前草稿',
                    icon: Icons.refresh_rounded,
                    onPressed: busy ? null : recheck,
                  ),
                  DeskButton(
                    '定位复查问题',
                    quiet: true,
                    onPressed:
                        busy ||
                            inspection == null ||
                            !session.isInspectionCurrent(inspection!)
                        ? null
                        : inspectDetails,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            DeskButton(
              '返回清理面板',
              primary: true,
              icon: Icons.arrow_back_rounded,
              onPressed: busy ? null : () => setState(() => receipt = null),
            ),
            const Spacer(),
            DeskButton(
              '本书检查',
              quiet: true,
              icon: Icons.fact_check_outlined,
              onPressed: busy ? null : widget.onChecks,
            ),
          ],
        ),
      ],
    );
  }

  /// 书稿变了，检测结果或复查过期时自动重做：同一份旧结果只重做一次，
  /// 连续最多三次，失败照常显示错误。
  Object? autoRedoneFrom;
  int autoRedos = 0;
  void autoRefreshStale() {
    if (busy || error.isNotEmpty || autoRedos >= 3) return;
    final stalePlan = plan != null && !session.isCurrent(plan!);
    final staleInspection =
        inspection != null && !session.isInspectionCurrent(inspection!);
    if (!stalePlan && !staleInspection) {
      autoRedos = 0;
      return;
    }
    final from = stalePlan ? plan : inspection;
    if (identical(from, autoRedoneFrom)) return;
    autoRedoneFrom = from;
    autoRedos++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || busy) return;
      stalePlan ? detect(asDiff: diff) : recheck();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session.changes,
    builder: (_, _) {
      final d = context.desk;
      autoRefreshStale();
      // 进入“清理差异”后、确认采用前，登记为待应用。
      reportPending(
        plan != null && diff
            ? PendingChange(
                token: plan!,
                domain: '文本清理方案',
                summary: '${plan!.total} 处变更',
                location: bookPageLocation(widget.bookId, 'cleanup'),
                bookId: widget.bookId,
                stale: !session.isCurrent(plan!),
                discard: () {
                  if (mounted) setState(() => diff = false);
                },
                regenerate: () {
                  if (mounted && !busy) detect(asDiff: true);
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header(),
            SizedBox(
              height: 2,
              child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: DeskNote(error, title: '操作没有完成', tone: Tone.pen),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final right = receipt != null ? result() : previewColumn();
                  // 字号放大时两栏需要的宽度和规则栏的宽度一起放大，放不下就改成切换。
                  final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
                  if (c.maxWidth >= 900 * scale) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: (340 * scale).clamp(340.0, 440.0),
                          child: rulesColumn(),
                        ),
                        Expanded(child: right),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: DeskSegmented<int>(
                            value: pane,
                            options: const {0: '清理规则', 1: '预览与候选'},
                            onChanged: (v) => setState(() => pane = v),
                          ),
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: pane,
                          children: [rulesColumn(), right],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
