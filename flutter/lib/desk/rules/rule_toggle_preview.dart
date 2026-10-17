// 规则开关的预览对话框（V66，CH-282）：展示 previewToggles 返回的改动、本书影响与联动，
// 用户点“确认应用”才调用 applyToggles。不改原稿和正文；清理开关只保存配置。
import 'package:flutter/material.dart';

import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';

/// 规则名称（没有时显示编号）与单位，供预览说明使用。
typedef RuleLabel = String Function(String id);

/// 预览一批开关改动；返回 true 表示用户确认应用。
Future<bool> showRuleTogglePreview(
  BuildContext context, {
  required Map<String, dynamic> plan,
  required RuleLabel label,
  required String Function(String id) unit,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RuleTogglePreview(plan: plan, label: label, unit: unit),
    ) ==
    true;

class RuleTogglePreview extends StatelessWidget {
  const RuleTogglePreview({
    super.key,
    required this.plan,
    required this.label,
    required this.unit,
  });
  final Map<String, dynamic> plan;
  final RuleLabel label;
  final String Function(String id) unit;

  static Map<String, int> _counts(Object? statistics) {
    final rules = (statistics as Map?)?['rules'] as List? ?? const [];
    return {
      for (final r in rules.cast<Map>())
        if (r['count'] case final int count) r['id'] as String: count,
    };
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final global = plan['scope'] == 'global';
    final changes = (plan['changes'] as List? ?? const []).cast<Map>();
    final impact = (plan['impact'] as Map?) ?? const {};
    final before = _counts(impact['before']);
    final after = _counts(impact['after']);
    final moved = [
      for (final e in before.entries)
        if (after[e.key] case final int a when a != e.value)
          (e.key, e.value, a),
    ];
    final chapterTotal = impact['chapter_changes_total'] as int? ?? 0;
    final chapters = (impact['chapter_changes'] as List? ?? const [])
        .cast<Map>();
    final conflicts = (plan['conflicts'] as List? ?? const []).cast<Map>();

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(text, style: ui(13, w: 650, c: d.ink)),
    );
    Widget line(String text, {Color? color, Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text, style: ui(12.5, c: color ?? d.ink2, h: 1.5)),
    );
    String chapterLine(Map c) => switch (c['kind']) {
      'added' => '第 ${c['line']} 行 成为标题：${c['title']}',
      'removed' => '第 ${c['line']} 行 不再是标题：${c['title']}',
      _ =>
        c['before'] == c['after']
            ? '第 ${c['line']} 行 层级改变：${c['after']}'
            : '第 ${c['line']} 行 ${c['before']} → ${c['after']}',
    };

    return DeskDialog(
      title: '预览规则改动',
      subtitle: global ? '新书默认：只影响以后导入的书' : '本书：确认后写入，可在变更记录里撤销',
      closeTooltip: '返回修改',
      width: 560,
      actions: [
        DeskButton(
          '返回修改',
          key: const ValueKey('rule-preview-back'),
          onPressed: () => Navigator.pop(context, false),
        ),
        DeskButton(
          '确认应用',
          key: const ValueKey('rule-preview-apply'),
          primary: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading('改动（${changes.length} 项）'),
          for (final c in changes)
            line(
              '${label(c['id'] as String)}：'
              '${c['before'] == true ? '开启' : '关闭'} → ${c['after'] == true ? '开启' : '关闭'}',
              color: d.ink,
            ),
          if (!global) ...[
            heading('章节结构'),
            if (chapterTotal == 0)
              line('标题没有变化。', key: const ValueKey('rule-preview-no-chapter'))
            else ...[
              line(
                '$chapterTotal 处变化${chapters.length < chapterTotal ? '（列出前 ${chapters.length} 处）' : ''}：',
                color: d.ink,
              ),
              for (final c in chapters) line(chapterLine(c)),
            ],
            heading('本书命中变化'),
            if (moved.isEmpty)
              line('各规则命中数不变。')
            else
              for (final (id, b, a) in moved.take(30))
                line('${label(id)}：$b → $a ${unit(id)}'),
            if (moved.length > 30) line('……另有 ${moved.length - 30} 条'),
          ],
          if (conflicts.isNotEmpty) ...[
            heading('联动提示'),
            for (final c in conflicts)
              line(
                '「${label(c['rule'] as String)}」会让「${label((c['affects'] as Map)['rule'] as String)}」'
                '少命中 ${(c['affects'] as Map)['count']} ${unit((c['affects'] as Map)['rule'] as String)}',
                color: d.warn,
              ),
          ],
          const SizedBox(height: 12),
          DeskNote(
            global
                ? '只保存为新书默认，本书和已经导入的书都不变。'
                : '不会改动原稿和正文。文本清理的开关只保存配置，正文仍要在文本清理页预览、确认后才修改。',
          ),
        ],
      ),
    );
  }
}
