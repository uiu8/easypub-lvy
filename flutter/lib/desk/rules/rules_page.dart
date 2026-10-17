// 识别与检查规则中心（V63，CH-278，R2）：按执行顺序列出文本清理、章节识别、章节检查、排版识别与手工
// 五组规则，显示本书命中数、开关状态、未配置 / 失败 / 过期；点位置跳到章节页，“去设置”回到原有页面。
// 本批只读：目录与统计来自 V59 的 RuleCatalogService，不保存、不改书稿；逐项开关留给 R3。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/rule_catalog_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 规则组（按执行顺序）与“去设置”的目的页。
const ruleGroups = [
  ('cleanup', 'automatic', '文本清理', '会改正文的规则先执行；预览确认后才写入。', 'cleanup'),
  ('chapter_recognition', 'automatic', '章节识别', '决定哪些行是卷、章、节标题。', 'chapters'),
  ('chapter_check', 'automatic', '章节检查', '只报告问题，不改正文。', 'checks'),
  ('layout', 'automatic', '排版识别', '只影响成品外观，原稿不改。', 'layout'),
  ('layout', 'manual', '手工标注与注释', '在章节页逐条添加，优先于自动识别。', 'chapters'),
];

const ruleUnits = {
  'titles': '个标题',
  'issues': '个问题',
  'lines': '行',
  'blocks': '处',
  'pairs': '对',
  'candidates': '条候选',
  'excluded_lines': '行',
};

const ruleEffects = {
  'modify': '改正文',
  'structure': '定标题',
  'report': '只报问题',
  'render': '只影响成品',
};

String ruleCount(RuleStatistic s) => '${s.count} ${ruleUnits[s.unit] ?? '处'}';

class RulesPage extends StatefulWidget {
  const RulesPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.onOpenLocation,
    required this.onOpenSettings,
  });
  final RuleCatalogLibrary library;
  final String bookId;
  final void Function(RuleLocation location) onOpenLocation;

  /// 打开原有设置页：cleanup、chapters、checks、layout。
  final void Function(String page) onOpenSettings;
  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  late final RuleCatalogService service = widget.library.openRuleCatalog(
    widget.bookId,
  );
  List<RuleDescriptor>? catalog;
  String catalogError = '';
  final expanded = <String>{};
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    service.state.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // 书稿或设置变了：旧结果作废，自动重新统计。
    if (service.state.value.phase == RuleStatisticsPhase.stale) {
      unawaited(recount());
    }
  }

  Future<void> _load() async {
    try {
      final rules = await service.catalog();
      if (!mounted) return;
      setState(() => catalog = rules);
      await recount();
    } catch (_) {
      if (mounted) setState(() => catalogError = '规则目录读取失败，请重新打开本页。');
    }
  }

  Future<void> recount() async {
    if (_requesting) return;
    _requesting = true;
    try {
      await service.request();
    } catch (_) {
      // 失败原因已在 state 中。
    } finally {
      _requesting = false;
      if (mounted) {
        setState(() {});
        // 统计途中书稿变了：本次结果作废，再统计一次。
        if (service.state.value.phase == RuleStatisticsPhase.stale) {
          unawaited(recount());
        }
      }
    }
  }

  @override
  void dispose() {
    service.state.removeListener(_changed);
    service.dispose();
    super.dispose();
  }

  RuleStatisticsState get state => service.state.value;
  RuleStatisticsSnapshot? get result => state.result;

  Widget statusBar() {
    final d = context.desk;
    final phase = state.phase;
    final r = result;
    final (text, tone) = switch (phase) {
      RuleStatisticsPhase.running => ('正在统计本书…', Tone.neutral),
      RuleStatisticsPhase.cancelling => ('正在取消…', Tone.neutral),
      RuleStatisticsPhase.cancelled => ('统计已取消', Tone.warn),
      RuleStatisticsPhase.stale => ('书稿或设置已变化，正在重新统计…', Tone.neutral),
      RuleStatisticsPhase.failed => (
        '统计失败：${state.reason ?? '请稍后重试'}',
        Tone.pen,
      ),
      RuleStatisticsPhase.completed when r != null => (
        '已统计：${r.lineCount} 行 · ${r.chapterCount} 个分节 · '
            '用时 ${r.elapsedMilliseconds.round()} 毫秒${r.cacheHit ? '（缓存）' : ''}',
        Tone.ok,
      ),
      _ => ('尚未统计', Tone.neutral),
    };
    final running =
        phase == RuleStatisticsPhase.running ||
        phase == RuleStatisticsPhase.cancelling;
    return Row(
      children: [
        Flexible(
          child: KeyedSubtree(
            key: const ValueKey('rules-status'),
            child: DeskTag(text, tone),
          ),
        ),
        const SizedBox(width: 8),
        if (running)
          DeskButton(
            '取消',
            key: const ValueKey('rules-cancel'),
            quiet: true,
            onPressed: phase == RuleStatisticsPhase.cancelling
                ? null
                : () => unawaited(service.cancel()),
          )
        else
          DeskButton(
            '重新统计',
            key: const ValueKey('rules-recount'),
            quiet: true,
            icon: Icons.refresh_rounded,
            onPressed: catalog == null ? null : () => unawaited(recount()),
          ),
        const Spacer(),
        Text('只读：在这里查看效果，开关仍在各自页面', style: ui(11.5, c: d.ink3)),
      ],
    );
  }

  /// 一条规则右侧的状态文字。
  Widget countOf(RuleDescriptor rule) {
    final d = context.desk;
    final s = result?.rules[rule.id];
    if (s == null) {
      return Text(
        state.phase == RuleStatisticsPhase.running ? '统计中…' : '—',
        style: ui(12, c: d.ink3),
      );
    }
    return switch (s.status) {
      'unconfigured' => DeskTag('需先配置', Tone.neutral),
      'failed' => Tooltip(
        message: s.reason ?? '统计失败',
        child: DeskTag('统计失败', Tone.pen),
      ),
      _ =>
        s.enabled
            ? Text(
                ruleCount(s),
                style: ui(12.5, w: 600, c: s.count == 0 ? d.ink3 : d.ink),
              )
            : Text('关闭 · 如果开启：${ruleCount(s)}', style: ui(12, c: d.ink3)),
    };
  }

  Widget ruleRow(
    RuleDescriptor rule,
    List<RuleDescriptor> children,
    String page,
  ) {
    final d = context.desk;
    final open = expanded.contains(rule.id);
    final s = result?.rules[rule.id];
    final enabled = s?.enabled ?? rule.defaultEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: d.surface,
          child: InkWell(
            key: ValueKey(('rule-row', rule.id)),
            onTap: () => setState(
              () => open ? expanded.remove(rule.id) : expanded.add(rule.id),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    open
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: d.ink3,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: rule.label,
                            style: ui(13, w: 600, c: enabled ? d.ink : d.ink2),
                          ),
                          if (children.isNotEmpty)
                            TextSpan(
                              text: '  细分 ${children.length} 项',
                              style: ui(11.5, c: d.ink3),
                            ),
                        ],
                      ),
                    ),
                  ),
                  DeskTag(
                    ruleEffects[rule.effect] ?? rule.effect,
                    Tone.neutral,
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 190,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: countOf(rule),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open) details(rule, children, page),
        Divider(height: 1, color: d.line),
      ],
    );
  }

  Widget details(
    RuleDescriptor rule,
    List<RuleDescriptor> children,
    String page,
  ) {
    final d = context.desk;
    final s = result?.rules[rule.id];
    final locations = s?.locations ?? const <RuleLocation>[];
    return Padding(
      key: ValueKey(('rule-details', rule.id)),
      padding: const EdgeInsets.fromLTRB(26, 0, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(rule.description, style: ui(12, c: d.ink2, h: 1.5)),
          if (s != null && s.invalidCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '另有 ${s.invalidCount} 条因书稿改动已失效，不参与输出。',
                style: ui(12, c: d.warn),
              ),
            ),
          if (locations.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  s!.count > locations.length
                      ? '前 ${locations.length} 处：'
                      : '位置：',
                  style: ui(11.5, c: d.ink3),
                ),
                for (final (i, at) in locations.take(20).indexed)
                  ActionChip(
                    key: ValueKey(('rule-location', rule.id, i)),
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      at.heading
                          ? '第 ${at.sourceLine} 行（标题）'
                          : '第 ${at.sourceLine} 行',
                      style: mono(11, c: d.ink2),
                    ),
                    onPressed: () => widget.onOpenLocation(at),
                  ),
                if (locations.length > 20)
                  Text('……', style: ui(11.5, c: d.ink3)),
              ],
            ),
          ],
          if (children.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final child in children)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  key: ValueKey(('rule-child', child.id)),
                  children: [
                    Text('·', style: ui(12, c: d.ink3)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Tooltip(
                        message: child.description,
                        child: Text(child.label, style: ui(12.5, c: d.ink)),
                      ),
                    ),
                    countOf(child),
                  ],
                ),
              ),
            Text('细分项之间可能重叠（同一行同时属于两项），不能直接相加。', style: ui(11, c: d.ink3)),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: DeskButton(
              '去设置',
              key: ValueKey(('rule-settings', rule.id)),
              quiet: true,
              icon: Icons.open_in_new_rounded,
              onPressed: () => widget.onOpenSettings(page),
            ),
          ),
        ],
      ),
    );
  }

  Widget group(
    String title,
    String note,
    String page,
    List<RuleDescriptor> roots,
    Map<String, List<RuleDescriptor>> children,
  ) {
    final d = context.desk;
    return Container(
      key: ValueKey(('rule-group', title)),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(title, style: ui(13.5, w: 650, c: d.ink)),
              Text(note, style: ui(11.5, c: d.ink3)),
            ],
          ),
          const SizedBox(height: 6),
          for (final rule in roots)
            ruleRow(rule, children[rule.id] ?? const [], page),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final rules = catalog;
    final children = <String, List<RuleDescriptor>>{};
    for (final r in rules ?? const <RuleDescriptor>[]) {
      if (r.parent != null) (children[r.parent!] ??= []).add(r);
    }
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('识别与检查规则', style: ui(16, w: 650, c: d.ink)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '执行顺序：文本清理 → 章节识别 → 章节检查 → 排版识别 → 手工（手工优先）',
                        overflow: TextOverflow.ellipsis,
                        style: ui(11.5, c: d.ink3),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                statusBar(),
              ],
            ),
          ),
          Expanded(
            child: rules == null
                ? Center(
                    child: catalogError.isEmpty
                        ? const CircularProgressIndicator()
                        : Text(catalogError, style: ui(13, c: d.pen)),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
                    children: [
                      for (final (key, category, title, note, page)
                          in ruleGroups)
                        if (rules.any(
                          (r) =>
                              r.parent == null &&
                              r.group == key &&
                              r.category == category,
                        ))
                          group(
                            title,
                            note,
                            page,
                            rules
                                .where(
                                  (r) =>
                                      r.parent == null &&
                                      r.group == key &&
                                      r.category == category,
                                )
                                .toList(),
                            children,
                          ),
                      const DeskNote(
                        '数字是对当前书稿的实时统计：关闭的规则显示“如果开启会命中多少”；'
                        '“需先配置”表示要先填写表达式或词库；细分项的逐项开关将在后续版本提供。',
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
