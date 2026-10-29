// 识别与检查规则（V63 起，CH-278；V64 改版，CH-279/280；V66 接通开关，CH-282）：从检查页进入。
// 按执行顺序分页签，每组作用只说明一次；筛选与跨页签搜索。每行为开关、名称与一行说明、本书命中数，
// 展开看位置（点击跳到章节页）、细分项与“去设置”。开关改动先暂存，底部“预览影响…”调用 V65 的
// previewToggles，确认后 applyToggles 一次写入（本书可在变更记录撤销；新书默认只影响以后导入的书）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/rule_catalog_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../errors.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'rule_toggle_preview.dart';

/// 规则组（按执行顺序）：组键、类别、页签名、作用说明、“去设置”的目的页。
/// 手工组收全部 manual 类规则（手工标注、手工注释与失效记录）。
const ruleGroups = [
  ('cleanup', 'automatic', '文本清理', '会改正文；开关只保存配置，正文在清理页预览确认后才改。', 'cleanup'),
  ('chapter_recognition', 'automatic', '章节识别', '决定哪些行是卷、章、节标题。', 'chapters'),
  ('chapter_check', 'automatic', '章节检查', '只报告问题，不改正文。', 'checks'),
  (
    'catalog_check',
    'automatic',
    '目录对照',
    '有参考目录时，对照目录检查缺章、多章、标题和顺序。',
    'catalog',
  ),
  ('layout', 'automatic', '排版识别', '只影响成品外观，原稿不改。', 'layout'),
  ('preflight', 'automatic', '输出前检查', '转换前的提示；书名和转换器是必需项，不能关闭。', 'information'),
  ('layout', 'manual', '手工', '在章节页逐条添加，优先于自动识别；这里只统计。', 'chapters'),
];

/// 规则是否属于第 [i] 组。
bool ruleInGroup(int i, RuleDescriptor r) {
  final g = ruleGroups[i];
  return g.$2 == 'manual'
      ? r.category == 'manual'
      : r.group == g.$1 && r.category == g.$2;
}

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

/// 筛选：全部、有命中、已关闭、需配置。
const ruleFilters = {'all': '全部', 'hit': '有命中', 'off': '已关闭', 'config': '需配置'};

String ruleCount(RuleStatistic s) => '${s.count} ${ruleUnits[s.unit] ?? '处'}';

/// 规则所在的组序号；找不到时为 -1。
int ruleGroupOf(RuleDescriptor rule) {
  for (var i = 0; i < ruleGroups.length; i++) {
    if (ruleInGroup(i, rule)) return i;
  }
  return -1;
}

class RulesPage extends StatefulWidget {
  const RulesPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.onOpenLocation,
    required this.onOpenSettings,
    this.focusRule,
    this.onBack,
  });
  final RuleCatalogLibrary library;
  final String bookId;
  final void Function(RuleLocation location) onOpenLocation;

  /// 打开原有设置页：cleanup、chapters、checks、layout。
  final void Function(String page) onOpenSettings;

  /// 打开时定位的规则（可以是细分项）：切到所在页签、展开并滚动到它（CH-279）。
  final String? focusRule;

  /// 回到检查页（CH-279）。
  final VoidCallback? onBack;
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
  int tab = 0;
  String filter = 'all';
  final search = TextEditingController();
  String? focusRoot;
  final _focusKey = GlobalKey();

  /// 开关范围：book（本书）或 global（新书默认）。
  String scope = 'book';

  /// settings() 返回的每条规则：enabled、factory_default、new_book_default、origin。
  Map<String, Map>? settingsRows;
  String settingsError = '';

  /// 暂存的开关改动（规则编号 → 目标状态），预览确认后才写入。
  final pending = <String, bool>{};
  bool applying = false;
  String notice = '';

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
      setState(() {
        catalog = rules;
        _applyFocus(rules);
        final seen = <(String, String, String)>{};
        for (final r in rules.where((r) => r.parent == null)) {
          final key = (r.group, r.category, r.description);
          if (!seen.add(key)) _sharedDescriptions.add(r.description);
        }
      });
      if (focusRoot != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _focusKey.currentContext;
          if (target != null && target.mounted) {
            unawaited(Scrollable.ensureVisible(target, alignment: 0.2));
          }
        });
      }
      await Future.wait([recount(), loadSettings()]);
    } catch (_) {
      if (mounted) setState(() => catalogError = '规则目录读取失败，请重新打开本页。');
    }
  }

  Future<void> loadSettings() async {
    final want = scope;
    try {
      final data = await service.settings(scope: want);
      if (!mounted || want != scope) return;
      setState(() {
        settingsError = '';
        settingsRows = {
          for (final r in (data['rules'] as List).cast<Map>())
            r['id'] as String: r,
        };
      });
    } catch (e) {
      if (mounted && want == scope) {
        setState(() {
          settingsRows = null;
          settingsError = deskErrorText(e, '开关状态读取失败，请重新打开本页。');
        });
      }
    }
  }

  void setScope(String next) {
    if (next == scope || applying) return;
    setState(() {
      scope = next;
      pending.clear();
      notice = '';
      settingsRows = null;
    });
    unawaited(loadSettings());
  }

  RuleDescriptor? ruleById(String id) =>
      catalog?.where((r) => r.id == id).firstOrNull;
  String labelOf(String id) {
    final r = ruleById(id);
    if (r == null) return id;
    final parent = r.parent == null ? null : ruleById(r.parent!);
    return parent == null ? r.label : '${parent.label} · ${r.label}';
  }

  String unitOf(String id) => ruleUnits[result?.rules[id]?.unit] ?? '处';

  /// 预览并应用暂存的改动。
  Future<void> previewPending() async {
    if (pending.isEmpty || applying) return;
    setState(() {
      applying = true;
      notice = '';
    });
    try {
      final plan = await service.previewToggles([
        for (final e in pending.entries) {'id': e.key, 'enabled': e.value},
      ], scope: scope);
      if (!mounted) return;
      final ok = await showRuleTogglePreview(
        context,
        plan: plan,
        label: labelOf,
        unit: unitOf,
      );
      if (!ok || !mounted) return;
      await service.applyToggles(plan['plan_id'] as String);
      if (!mounted) return;
      final n = pending.length;
      setState(() {
        pending.clear();
        notice = scope == 'global'
            ? '已保存 $n 项为新书默认，以后导入的书按此设置。'
            : '已应用 $n 项改动，可在变更记录里撤销。';
      });
      await loadSettings();
    } catch (e) {
      if (mounted) setState(() => notice = deskErrorText(e, '规则改动没有应用，请重新预览。'));
    } finally {
      if (mounted) setState(() => applying = false);
    }
  }

  void _applyFocus(List<RuleDescriptor> rules) {
    final id = widget.focusRule;
    if (id == null) return;
    final rule = rules.where((r) => r.id == id).firstOrNull;
    if (rule == null) return;
    final root = rules.where((r) => r.id == (rule.parent ?? rule.id)).first;
    final group = ruleGroupOf(root);
    if (group < 0) return;
    tab = group;
    focusRoot = root.id;
    expanded.add(root.id);
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
    search.dispose();
    super.dispose();
  }

  RuleStatisticsState get state => service.state.value;
  RuleStatisticsSnapshot? get result => state.result;
  String get query => search.text.trim().toLowerCase();

  Widget statusBar() {
    final phase = state.phase;
    final r = result;
    final (text, tone) = switch (phase) {
      RuleStatisticsPhase.running => ('正在统计本书…', Tone.neutral),
      RuleStatisticsPhase.cancelling => ('正在取消…', Tone.neutral),
      RuleStatisticsPhase.cancelled => ('统计已取消', Tone.warn),
      RuleStatisticsPhase.stale => ('书稿或设置已变化，正在重新统计…', Tone.neutral),
      // 后端给的是下一步代码，换成对照表里的说明（V66 修正：原来直接显示代码）。
      RuleStatisticsPhase.failed => (
        '统计失败：${deskErrorReason(state.reason ?? '') ?? '请稍后重试'}',
        Tone.pen,
      ),
      // R3-06：只写本书多少行、多少节；耗时与是否用了缓存放进悬停提示。
      RuleStatisticsPhase.completed when r != null => (
        '已统计本书 ${r.lineCount} 行、${r.chapterCount} 节',
        Tone.ok,
      ),
      _ => ('尚未统计', Tone.neutral),
    };
    final running =
        phase == RuleStatisticsPhase.running ||
        phase == RuleStatisticsPhase.cancelling;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: KeyedSubtree(
            key: const ValueKey('rules-status'),
            child: phase == RuleStatisticsPhase.completed && r != null
                ? Tooltip(
                    message:
                        '用时 ${r.elapsedMilliseconds.round()} 毫秒${r.cacheHit ? '，用的是上次的统计结果（书稿和设置都没变）' : ''}',
                    child: DeskTag(text, tone),
                  )
                : DeskTag(text, tone),
          ),
        ),
        const SizedBox(width: 6),
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
      ],
    );
  }

  /// 一条规则右侧的命中数：有命中加粗，0 处淡显，关闭的显示“开启会命中 N”。
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
      'unavailable' => Tooltip(
        message: s.reason ?? '缺少检查前提，例如没有参考目录',
        child: DeskTag('不可用', Tone.neutral),
      ),
      _ when !s.countAvailable => Text('—', style: ui(12, c: d.ink3)),
      'failed' => Tooltip(
        message: s.reason ?? '统计失败',
        child: DeskTag('统计失败', Tone.pen),
      ),
      // 新书默认：开关是新书的，数字仍是本书的，标明“本书”以免混淆。
      _ when scope == 'global' => Text(
        s.enabled ? '本书 ${ruleCount(s)}' : '本书已关闭',
        style: ui(12, c: d.ink3),
      ),
      _ =>
        s.enabled
            ? s.count == 0
                  ? Text(ruleCount(s), style: ui(12, c: d.ink3))
                  // 有命中：计数胶囊（V105 视觉语言）。
                  : DeskPill(
                      Text(ruleCount(s), style: ui(12, w: 600, c: d.ink)),
                      color: d.surface,
                      outlined: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1.5,
                      ),
                      radius: 5,
                    )
            : s.hypothetical
            ? Text('开启会命中 ${ruleCount(s)}', style: ui(12, c: d.ink3))
            : Tooltip(
                message: '关闭后暂不统计“如果开启会命中多少”',
                child: Text('已关闭', style: ui(12, c: d.ink3)),
              ),
    };
  }

  /// 当前保存的开关状态（按所选范围）；设置未读到时退回统计结果和出厂默认。
  bool savedOn(RuleDescriptor rule) {
    final row = settingsRows?[rule.id];
    if (row != null) return row['enabled'] == true;
    return result?.rules[rule.id]?.enabled ?? rule.defaultEnabled;
  }

  bool switchOn(RuleDescriptor rule) => pending[rule.id] ?? savedOn(rule);

  /// 与默认不同：本书对照新书默认，新书默认对照出厂默认。
  bool differs(RuleDescriptor rule) {
    final row = settingsRows?[rule.id];
    if (row == null || rule.locked) return false;
    final base = scope == 'global'
        ? row['factory_default']
        : row['new_book_default'];
    return base is bool && base != row['enabled'];
  }

  void toggle(RuleDescriptor rule) => setState(() {
    notice = '';
    final next = !switchOn(rule);
    if (next == savedOn(rule)) {
      pending.remove(rule.id);
    } else {
      pending[rule.id] = next;
    }
  });

  /// 开关：锁定项（基础识别、手工记录、必需的输出前检查）不能拨；需配置的先去设置。
  Widget switchOf(RuleDescriptor rule, {bool small = false}) {
    final s = result?.rules[rule.id];
    final unconfigured = s?.status == 'unconfigured';
    final on = switchOn(rule);
    final ready = settingsRows != null && !applying;
    final note = rule.locked
        ? rule.lockedReason ?? '不能关闭'
        : unconfigured
        ? '需先配置：点“去设置”填写表达式或词库'
        : !ready
        ? '正在读取开关状态…'
        : pending.containsKey(rule.id)
        ? '待应用：${on ? '开启' : '关闭'}（再点一次取消）'
        : on
        ? '点击关闭'
        : '点击开启';
    final canToggle = ready && !rule.locked && !unconfigured;
    return Tooltip(
      message: note,
      child: InkWell(
        key: ValueKey(('rule-toggle', rule.id)),
        borderRadius: BorderRadius.circular(9),
        onTap: canToggle ? () => toggle(rule) : null,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: RuleSwitch(
            key: ValueKey(('rule-switch', rule.id)),
            on: on && !unconfigured,
            locked: rule.locked,
            pending: pending.containsKey(rule.id),
            small: small,
          ),
        ),
      ),
    );
  }

  /// 行内标记：待应用、与默认不同。
  List<InlineSpan> marks(RuleDescriptor rule) {
    final d = context.desk;
    return [
      if (pending.containsKey(rule.id))
        TextSpan(
          text: '  待应用',
          style: ui(11.5, w: 600, c: d.info),
        )
      else if (differs(rule))
        TextSpan(
          text: scope == 'global' ? '  ● 与出厂默认不同' : '  ● 与新书默认不同',
          style: ui(11, c: d.ink3),
        ),
    ];
  }

  bool _matches(RuleDescriptor rule, List<RuleDescriptor> children) {
    final q = query;
    if (q.isNotEmpty &&
        ![
          rule,
          ...children,
        ].any((r) => '${r.label} ${r.description}'.toLowerCase().contains(q))) {
      return false;
    }
    final s = result?.rules[rule.id];
    return switch (filter) {
      'hit' => s != null && s.enabled && s.count > 0,
      'off' => !switchOn(rule) && s?.status != 'unconfigured',
      'config' => s?.status == 'unconfigured',
      _ => true,
    };
  }

  /// 组内多条规则共用的说明（如章节检查的通用说明）：行里不重复显示，展开后再看。
  final _sharedDescriptions = <String>{};

  Widget ruleRow(
    RuleDescriptor rule,
    List<RuleDescriptor> children,
    String page,
  ) {
    final d = context.desk;
    final open = expanded.contains(rule.id);
    final inline = !_sharedDescriptions.contains(rule.description);
    final s = result?.rules[rule.id];
    final enabled = s?.enabled ?? rule.defaultEnabled;
    final focused = rule.id == focusRoot;
    return Column(
      key: focused ? _focusKey : null,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: focused ? d.accentSoft : d.surface,
          child: InkWell(
            key: ValueKey(('rule-row', rule.id)),
            onTap: () => setState(
              () => open ? expanded.remove(rule.id) : expanded.add(rule.id),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
              child: Row(
                children: [
                  switchOf(rule),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: rule.label,
                                style: ui(
                                  13,
                                  w: 600,
                                  c: enabled ? d.ink : d.ink2,
                                ),
                              ),
                              if (children.isNotEmpty)
                                TextSpan(
                                  text: '  细分 ${children.length} 项',
                                  style: ui(11.5, c: d.ink3),
                                ),
                              ...marks(rule),
                            ],
                          ),
                        ),
                        if (inline) ...[
                          const SizedBox(height: 2),
                          Text(
                            rule.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(11.5, c: d.ink3),
                          ),
                        ],
                        for (final a in s?.affects ?? const <Map>[])
                          Padding(
                            key: ValueKey(('rule-affects', rule.id, a['rule'])),
                            padding: const EdgeInsets.only(top: 4),
                            child: Tooltip(
                              message:
                                  '执行这条规则后，「${labelOf(a['rule'] as String)}」会少命中 ${a['count']} ${unitOf(a['rule'] as String)}（按本书实际模拟）',
                              child: DeskTag(
                                '会影响「${labelOf(a['rule'] as String)}」${a['count']} ${unitOf(a['rule'] as String)}',
                                Tone.warn,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: countOf(rule),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    open
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: d.ink3,
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
    return Container(
      key: ValueKey(('rule-details', rule.id)),
      color: d.surface,
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _sharedDescriptions.contains(rule.description)
                ? '${ruleEffects[rule.effect] ?? rule.effect} · ${rule.description}'
                : ruleEffects[rule.effect] ?? rule.effect,
            style: ui(12, c: d.ink2, h: 1.5),
          ),
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
            const SizedBox(height: 8),
            for (final child in children)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  key: ValueKey(('rule-child', child.id)),
                  children: [
                    switchOf(child, small: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Tooltip(
                        message: child.description,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: child.label,
                                style: ui(12.5, c: d.ink),
                              ),
                              ...marks(child),
                            ],
                          ),
                        ),
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

  /// 一组规则（过滤后）；空组返回 null。
  Widget? group(
    int index,
    List<RuleDescriptor> rules,
    Map<String, List<RuleDescriptor>> children, {
    bool header = false,
  }) {
    final d = context.desk;
    final (_, _, title, note, page) = ruleGroups[index];
    final roots = [
      for (final r in rules)
        if (r.parent == null &&
            ruleInGroup(index, r) &&
            _matches(r, children[r.id] ?? const []))
          r,
    ];
    if (roots.isEmpty) return null;
    return Column(
      key: ValueKey(('rule-group', title)),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(title, style: ui(13, w: 650, c: d.ink)),
                Text(note, style: ui(11.5, c: d.ink3)),
              ],
            ),
          ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: d.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: d.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final rule in roots)
                ruleRow(rule, children[rule.id] ?? const [], page),
            ],
          ),
        ),
      ],
    );
  }

  /// 页签：组名 + 有命中的规则数。
  Widget tabOf(int index, List<RuleDescriptor> rules) {
    final d = context.desk;
    final on = index == tab && query.isEmpty;
    final (_, _, title, _, _) = ruleGroups[index];
    final hits = rules.where((r) {
      final s = result?.rules[r.id];
      return r.parent == null &&
          ruleInGroup(index, r) &&
          s != null &&
          s.enabled &&
          s.count > 0;
    }).length;
    final waiting = rules.any(
      (r) => ruleInGroup(index, r) && pending.containsKey(r.id),
    );
    return Material(
      key: ValueKey('rules-tab-$index'),
      color: on ? d.sunken : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          tab = index;
          search.clear();
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: ui(13, w: on ? 620 : 450, c: on ? d.ink : d.ink2),
              ),
              if (waiting) ...[const SizedBox(width: 5), Dot(d.info, size: 6)],
              if (hits > 0) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: '$hits 条规则有命中',
                  child: Text(
                    '$hits',
                    style: mono(11, c: on ? d.ink2 : d.ink3),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget filterChip(String id) {
    final d = context.desk;
    final on = filter == id;
    return Material(
      key: ValueKey('rules-filter-$id'),
      color: on ? d.sunken : Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: on ? d.lineStrong : d.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => setState(() => filter = id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            ruleFilters[id]!,
            style: ui(12, w: on ? 600 : 400, c: on ? d.ink : d.ink2),
          ),
        ),
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
    final searching = query.isNotEmpty;
    final body = rules == null
        ? null
        : [
            if (searching)
              for (var i = 0; i < ruleGroups.length; i++)
                ?group(i, rules, children, header: true)
            else
              ?group(tab, rules, children),
          ];
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Row(
              children: [
                if (widget.onBack case final back?) ...[
                  DeskButton(
                    '回到检查',
                    key: const ValueKey('rules-back'),
                    quiet: true,
                    icon: Icons.arrow_back_rounded,
                    onPressed: back,
                  ),
                  const SizedBox(width: 8),
                ],
                Text('识别与检查规则', style: ui(16, w: 650, c: d.ink)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '执行顺序：文本清理 → 章节识别 → 章节检查 → 排版识别 → 手工（手工优先）',
                    overflow: TextOverflow.ellipsis,
                    style: ui(11.5, c: d.ink3),
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: '本书：开关只改这本书；新书默认：只影响以后导入的书',
                  child: DeskSegmented<String>(
                    key: const ValueKey('rules-scope'),
                    value: scope,
                    options: const {'book': '本书', 'global': '新书默认'},
                    onChanged: applying ? null : setScope,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(child: statusBar()),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < ruleGroups.length; i++) ...[
                          tabOf(i, rules ?? const []),
                          const SizedBox(width: 2),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 200,
                  child: TextField(
                    key: const ValueKey('rules-search'),
                    controller: search,
                    style: ui(13, c: d.ink),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索全部规则',
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: d.ink3,
                      ),
                      prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    searching
                        ? '在全部规则中搜索“${search.text.trim()}”'
                        : ruleGroups[tab].$4,
                    key: const ValueKey('rules-group-note'),
                    overflow: TextOverflow.ellipsis,
                    style: ui(12, c: d.ink2),
                  ),
                ),
                for (final id in ruleFilters.keys) ...[
                  const SizedBox(width: 6),
                  filterChip(id),
                ],
              ],
            ),
          ),
          Expanded(
            child: body == null
                ? Center(
                    child: catalogError.isEmpty
                        ? const CircularProgressIndicator()
                        : Text(catalogError, style: ui(13, c: d.pen)),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (body.isEmpty)
                          Padding(
                            key: const ValueKey('rules-empty'),
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Text(
                              '没有符合条件的规则',
                              textAlign: TextAlign.center,
                              style: ui(13, c: d.ink3),
                            ),
                          ),
                        ...body,
                        const SizedBox(height: 14),
                        const DeskNote(
                          '数字是对当前书稿的实时统计：关闭的规则显示“开启会命中多少”；'
                          '“需先配置”表示要先填写表达式或词库；黄色标签表示这条规则会让另一条规则少命中。'
                          '开关改动先暂存，点“预览影响…”确认后才写入。',
                        ),
                      ],
                    ),
                  ),
          ),
          if (pending.isNotEmpty ||
              notice.isNotEmpty ||
              settingsError.isNotEmpty)
            pendingBar(),
        ],
      ),
    );
  }

  Widget pendingBar() {
    final d = context.desk;
    final message = settingsError.isNotEmpty
        ? settingsError
        : pending.isNotEmpty
        ? '${pending.length} 项改动待应用 · ${scope == 'global' ? '新书默认' : '本书'}'
        : notice;
    return Container(
      key: const ValueKey('rules-pending'),
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
      decoration: BoxDecoration(
        color: d.surface,
        border: Border(top: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              key: const ValueKey('rules-pending-text'),
              style: ui(
                12.5,
                w: pending.isNotEmpty ? 600 : 400,
                c: settingsError.isNotEmpty ? d.pen : d.ink,
              ),
            ),
          ),
          if (pending.isNotEmpty) ...[
            DeskButton(
              '放弃改动',
              key: const ValueKey('rules-discard'),
              quiet: true,
              onPressed: applying ? null : () => setState(pending.clear),
            ),
            const SizedBox(width: 8),
            DeskButton(
              '预览影响…',
              key: const ValueKey('rules-preview'),
              primary: true,
              busy: applying,
              onPressed: applying ? null : () => unawaited(previewPending()),
            ),
          ],
        ],
      ),
    );
  }
}

/// 规则开关外观（V64 只显示状态；V65 接统一后端后可拨动）。locked 表示始终启用。
class RuleSwitch extends StatelessWidget {
  const RuleSwitch({
    super.key,
    required this.on,
    this.locked = false,
    this.pending = false,
    this.small = false,
  });
  final bool on, locked, pending, small;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final w = small ? 24.0 : 30.0, h = small ? 14.0 : 18.0;
    final knob = h - 4;
    return Semantics(
      toggled: on,
      label: locked ? '始终启用' : (on ? '已开启' : '已关闭'),
      child: Container(
        width: w,
        height: h,
        padding: const EdgeInsets.all(2),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: on ? (locked ? d.ink3 : d.accent) : d.lineStrong,
          borderRadius: BorderRadius.circular(h / 2),
          border: pending ? Border.all(color: d.info, width: 1.5) : null,
        ),
        child: Container(
          width: knob,
          height: knob,
          decoration: BoxDecoration(color: d.surface, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
