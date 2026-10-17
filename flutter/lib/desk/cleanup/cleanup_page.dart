// 文本清理（CLEAN-001–041、CLEAN-068–072）：左栏有序规则，右栏检测结果（本页变更列表 + 选中项对照、
// 提示候选、逐步骤差异）与采用结果。检测、保留、候选、采用、撤销与复查的逻辑逐行沿用 V4 前的 CleanupPage；
// 采用前必须进入“清理差异”并确认。设计：design_review_v37/d3_cleanup.dart（D3-H~L）。
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

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
  });
  final LibraryService library;
  final String bookId;
  final VoidCallback onChecks;
  final CleanupNavigationGuard navigation;
  final bool inspectOnOpen;

  /// 打开检测详情时先定位的行（从检查页逐行定位进入）。
  final int? inspectLine;
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

  /// 后台核对：清理对章节修改与检查的影响（CLEAN-097/098）。
  CleanupImpact? impact;
  String impactError = '';
  bool impactBusy = false;
  String error = '', saved = '', draftIdentity = '';
  int selected = 0, change = 0, generation = 0;
  bool busy = false, diff = false, showCandidates = false;
  bool showWhitespace = false, showStages = false;

  /// 差异列表占结果区的比例（CLEAN-101）：默认约 60%，拖动分隔线调整；
  /// 本次运行期间在各书之间保持，重启后恢复默认。
  static double split = .6;
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
  void saveDraft() => workspace?.writeDraft('cleanup:${widget.bookId}', {
    'rules': jsonEncode(draft),
    'selected': selected,
    'undo': undoDraft,
    'redo': redoDraft,
    'showWhitespace': showWhitespace,
  });
  @override
  void initState() {
    super.initState();
    saved = jsonEncode(draft);
    draftIdentity = saved;
    final restored = workspace?.readDraft('cleanup:${widget.bookId}');
    if (restored != null) {
      draft = decodeCleanup(restored['rules'] as String);
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
      }
    });
  }

  @override
  void dispose() {
    widget.navigation.check = null;
    widget.navigation.checkWorkspace = null;
    session.dispose();
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
        template: jsonEncode(draft),
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
    undoDraft.add(jsonEncode(draft));
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
      run(() async {
        final next = await session.preview(
          jsonEncode(draft),
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
      }
    }
  }

  Future<void> detect({int offset = 0, bool asDiff = false}) => run(() async {
    final next = await session.preview(jsonEncode(draft), offset: offset);
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
    undoDraft.add(jsonEncode(draft));
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
        (redo ? undoDraft : redoDraft).add(jsonEncode(draft));
        draft = decodeCleanup(stack.removeLast());
        draftIdentity = jsonEncode(draft);
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
        // 有章节修改无法换算到撤销 / 重做后的文本：列出并请用户确认（CLEAN-103）。
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
    final frozen = jsonEncode(draft);
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

  // ---------------------------------------------------------------- 视图（V4 起，设计 D3-H~L）

  /// 窄窗时左右两栏改为分段切换：0 规则，1 预览。
  int pane = 1;

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
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '与章节识别规则无关',
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: d.ink3),
            ),
          ),
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
                  '有序规则 · ${rules.length} / 32',
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

  /// 一次启用或停用多条规则（表头全选、Shift 选一段；G-067）。
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

  /// 本页提示候选一次勾选或取消（勾选即排除该行；G-067）。
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
        onTap: busy ? null : () => setState(() => selected = i),
        onDoubleTap: busy ? null : () => ruleDialog(i),
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
      onTap: busy ? null : () => setState(() => change = index),
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
              DeskTag(
                '${value.step + 1} ${cleanupLabel(rules[math.min(value.step, rules.length - 1)])}',
                Tone.neutral,
              ),
            ],
            if (on && !diff) ...[
              const SizedBox(width: 6),
              DeskButton(
                showStages ? '保留本步原文' : '保留原文',
                quiet: true,
                onPressed: busy || !current ? null : () => keep(value),
              ),
            ],
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
      onTap: busy || !current || !c.selectable
          ? null
          : () => select(!c.selected),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
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

  /// 本页提示候选：表头三态勾选（勾选即排除该行，默认不勾选；G-067/068）。
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
                      ? '审阅提示候选'
                      : '审阅提示候选 ${plan!.candidateTotal}',
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
          DeskButton(
            showWhitespace ? '隐藏空白标记' : '显示空白标记',
            icon: Icons.space_bar_rounded,
            quiet: true,
            onPressed: () => setState(() => showWhitespace = !showWhitespace),
          ),
          DeskCommandMenu<String>(
            enabled: !busy,
            tooltip: '候选与保留管理',
            icon: Icon(Icons.more_horiz_rounded, color: d.ink2),
            itemBuilder: (_) => const [
              PopupMenuItem(
                height: 36,
                value: 'notices',
                child: Text('清空提示候选排除选择'),
              ),
              PopupMenuItem(
                height: 36,
                value: 'kept',
                child: Text('清空逐行与逐步骤保留选择'),
              ),
            ],
            onSelected: (value) => edit(() {
              if (value == 'notices') {
                draft['remove_lines'] = <int>[];
              } else {
                draft['skip_lines'] = <int>[];
                draft['step_exclusions'] = <Map<String, dynamic>>[];
              }
            }),
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
        child: Text(
          plan != null
              ? '所选规则未发现需要清理的内容。'
              : busy
              ? '正在按规则逐行检测，结果出来后先显示差异…'
              : error.isNotEmpty
              ? '检测没有完成，原因见上方。'
              : '尚未检测。修改规则后点“自动检测”。',
          style: ui(12.5, c: d.ink3),
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
                  itemCount: changes.length,
                  itemBuilder: (_, i) => pairRow(changes[i], i, current),
                ),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeRow,
                child: GestureDetector(
                  key: const ValueKey('cleanup-split-handle'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (drag) => setState(
                    () =>
                        split = ((top + drag.delta.dy) / room).clamp(.15, .85),
                  ),
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
          DeskButton(
            '上一处',
            icon: Icons.keyboard_arrow_up_rounded,
            quiet: true,
            onPressed: busy || !current || plan!.offset + change == 0
                ? null
                : () {
                    if (change > 0 && !showCandidates) {
                      setState(() => change--);
                    } else {
                      detect(
                        offset: math.max(0, plan!.offset - 40),
                        asDiff: diff,
                      );
                    }
                  },
          ),
          DeskButton(
            '下一处',
            icon: Icons.keyboard_arrow_down_rounded,
            quiet: true,
            onPressed:
                busy ||
                    !current ||
                    (showCandidates
                        ? plan!.offset + 40 >= plan!.candidateTotal
                        : plan!.offset + change + 1 >= changeTotal)
                ? null
                : () {
                    if (!showCandidates && change + 1 < changes.length) {
                      setState(() => change++);
                    } else {
                      detect(offset: plan!.offset + 40, asDiff: diff);
                    }
                  },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              position,
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: d.ink3),
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
                '清理所选项…',
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
    if (value.checkpoint) return const DeskTag('章节修改为检查点，无法换算', Tone.pen);
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

  Widget stat(String value, String label) {
    final d = context.desk;
    return Container(
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
        ],
      ),
    );
  }

  Widget result() {
    final d = context.desk;
    final inspectionText = inspection == null
        ? '基础清理尚未复查。'
        : !session.isInspectionCurrent(inspection!)
        ? '复查已过期，请重新检查。'
        : '有效稿基础复查：${inspection!.changes} 处空白变更 · ${inspection!.candidates} 条广告候选。';
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
                    Text('当前编辑稿已更新并自动保存，原稿保留。', style: ui(12, c: d.ink2)),
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
            stat('${receipt!.chapterIssues} 项', '有效章节结构待核对'),
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
              Text('复查当前有效稿', style: ui(13, w: 650, c: d.ink)),
              const SizedBox(height: 2),
              Text(
                '基础复查检查当前有效稿的行尾空白、连续空行与广告候选；不重放自定义替换规则。',
                style: ui(12, c: d.ink2),
              ),
              const SizedBox(height: 8),
              Text(inspectionText, style: ui(12.5, c: d.ink)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  DeskButton(
                    '复查当前有效稿',
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session.changes,
    builder: (_, _) {
      final d = context.desk;
      // G-061：进入“清理差异”后、确认采用前，登记为待应用。
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
                  if (c.maxWidth >= 900) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 340, child: rulesColumn()),
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
