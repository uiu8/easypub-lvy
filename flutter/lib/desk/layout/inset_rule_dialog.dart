import 'package:flutter/material.dart';

import '../../application/layout_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 场景识别规则（V82，LAY-137）：与 Rust `rule_options::InsetRule` 同形，开头锚定行首、结尾锚定行尾。
String insetRuleLabel(Map rule) {
  String plain(String p) => p.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
  final scene = insetTypes[rule['scene']] ?? '${rule['scene']}';
  final end = (rule['end'] as String? ?? '');
  return end.isEmpty
      ? '$scene：${plain(rule['start'] as String)}（单行）'
      : '$scene：${plain(rule['start'] as String)} … ${plain(end)}';
}

/// 按与 Rust 相同的规则，在示例文字里找第一段会被标出的行（1 起），没有时为 null。
(int, int)? insetRuleMatch(Map rule, String sample) {
  RegExp? build(String p) {
    try {
      return RegExp(p);
    } on FormatException {
      return null;
    }
  }

  final start = build('^(?:${rule['start']})');
  final endText = rule['end'] as String? ?? '';
  final end = endText.isEmpty ? null : build('(?:$endText)\$');
  if (start == null || (endText.isNotEmpty && end == null)) return null;
  final lines = sample
      .split(RegExp(r'\r\n|\r|\n'))
      .map((l) => l.trim())
      .toList();
  final max = rule['max_lines'] as int;
  for (var i = 0; i < lines.length; i++) {
    if (!start.hasMatch(lines[i])) continue;
    if (end == null) return (i + 1, i + 1);
    for (var k = i; k < lines.length && k < i + max; k++) {
      if (end.hasMatch(lines[k])) return (i + 1, k + 1);
    }
  }
  return null;
}

Future<Map<String, dynamic>?> showInsetRuleDialog(BuildContext context) =>
    showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _RuleDialog(),
    );

class _RuleDialog extends StatefulWidget {
  const _RuleDialog();
  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  String scene = 'scroll';
  bool regex = false;
  final start = TextEditingController(text: '【契约】');
  final end = TextEditingController(text: '之印');
  final max = TextEditingController(text: '20');
  final sample = TextEditingController(
    text: '他展开羊皮纸。\n【契约】\n立约人以血为誓。\n——灰塔之印\n众人沉默。',
  );

  @override
  void dispose() {
    for (final c in [start, end, max, sample]) {
      c.dispose();
    }
    super.dispose();
  }

  String pattern(String text) =>
      regex ? text.trim() : RegExp.escape(text.trim());

  Map<String, dynamic>? get rule {
    final lines = int.tryParse(max.text.trim());
    if (start.text.trim().isEmpty || lines == null || lines < 1 || lines > 60) {
      return null;
    }
    return {
      'scene': scene,
      'start': pattern(start.text),
      'end': end.text.trim().isEmpty ? '' : pattern(end.text),
      'max_lines': lines,
    };
  }

  String? get error {
    if (start.text.trim().isEmpty) return '请填写开头';
    final lines = int.tryParse(max.text.trim());
    if (lines == null || lines < 1 || lines > 60) return '最多行数为 1–60';
    if (regex) {
      for (final p in [start.text, end.text]) {
        if (p.trim().isEmpty) continue;
        try {
          RegExp(p.trim());
        } on FormatException {
          return '正则表达式写法有误';
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final current = rule;
    final found = current == null || error != null
        ? null
        : insetRuleMatch(current, sample.text);
    final result = current == null || error != null
        ? (error ?? '')
        : found == null
        ? '示例里没有会被标出的段落。'
        : '会把第 ${found.$1}–${found.$2} 行标为“${insetTypes[scene]}”。';
    return DeskDialog(
      title: '添加场景识别规则',
      closeTooltip: '关闭',
      width: 640,
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        DeskButton(
          '添加',
          key: const ValueKey('inset-rule-add'),
          primary: true,
          onPressed: current == null || error != null
              ? null
              : () => Navigator.of(context).pop(current),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            key: const ValueKey('inset-rule-scene'),
            children: [
              for (final e in insetTypes.entries)
                ChoiceChip(
                  key: ValueKey(('inset-rule-scene', e.key)),
                  label: Text(e.value, style: ui(12, c: d.ink)),
                  selected: scene == e.key,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => scene = e.key),
                ),
            ],
          ),
          const SizedBox(height: 8),
          KeyedSubtree(
            key: const ValueKey('inset-rule-mode'),
            child: DeskSegmented<bool>(
              value: regex,
              options: const {false: '按文字', true: '正则表达式'},
              onChanged: (v) => setState(() => regex = v),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('inset-rule-start'),
                  controller: start,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '开头（行首）',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const ValueKey('inset-rule-end'),
                  controller: end,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '结尾（行尾，空则只标一行）',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: TextField(
                  key: const ValueKey('inset-rule-max'),
                  controller: max,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '最多行数',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('试一试：贴一段原文', style: ui(12, c: d.ink2)),
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('inset-rule-sample'),
            controller: sample,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(isDense: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Text(
            result,
            key: const ValueKey('inset-rule-result'),
            style: ui(12, c: error != null ? d.pen : d.ink),
          ),
          const SizedBox(height: 6),
          Text(
            '从开头这一行起，到第一次遇到结尾的那一行止（不超过最多行数），整段标为所选场景；'
            '找不到结尾就不标。手工标注优先于规则；标题行不会被标进去。',
            style: ui(11.5, c: d.ink3),
          ),
        ],
      ),
    );
  }
}
