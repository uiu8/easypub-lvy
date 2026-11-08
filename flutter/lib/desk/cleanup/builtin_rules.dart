// 内置清理规则清单（V134）：所有内置规则分组列出，每条一个开关，旁边显示在这本书里会改几处。
// 开关对应有序规则里的一条：打开时已有就启用、没有就按默认设置加进去；关闭时停用（设置保留）。
// 自定义替换与执行顺序在“执行顺序”页里照旧编辑。
import 'package:flutter/material.dart';

import '../../application/cleanup_service.dart';
import '../tokens.dart';

/// 一条内置规则：[rule] 是加入时的默认设置（rule 部分）。
class BuiltinCleanupRule {
  const BuiltinCleanupRule(this.id, this.label, this.detail, this.rule);
  final String id, label, detail;
  final Map<String, dynamic> rule;
  String get kind => rule['kind'] as String;

  /// 有序规则里的某一步是否就是这条（简繁按方向区分）。
  bool matches(Map<String, dynamic> step) {
    final base = cleanupBase(step);
    if (base['kind'] != kind) return false;
    if (kind == 'chinese_variant') {
      return (base['direction'] ?? 't2s') == rule['direction'];
    }
    return true;
  }

  /// 加进有序规则时的完整一步。
  Map<String, dynamic> step() => {
    'kind': 'configured',
    'enabled': true,
    'name': label,
    'scope': 'all',
    'rule': Map<String, dynamic>.of(rule),
  };
}

const builtinCleanupGroups = <(String, List<BuiltinCleanupRule>)>[
  (
    '常用',
    [
      BuiltinCleanupRule('trim', '行尾空白', '去掉每行末尾的空格', {
        'kind': 'trim_trailing_spaces',
      }),
      BuiltinCleanupRule('blank', '合并连续空行', '多个空行合成一个', {
        'kind': 'collapse_blank_lines',
      }),
      BuiltinCleanupRule('ads', '广告与页眉候选', '网址、推广语、页眉页脚等候选行', {
        'kind': 'remove_ad_lines',
      }),
      BuiltinCleanupRule('invisible', '不可见字符', '零宽字符、控制字符', {
        'kind': 'remove_invisible',
      }),
    ],
  ),
  (
    '标点与字符',
    [
      BuiltinCleanupRule('width', '全角字母与数字', '全角 ＡＢＣ１２３ 改为半角', {
        'kind': 'normalize_width',
      }),
      BuiltinCleanupRule('compat', '兼容标点', '统一形近、兼容区的标点', {
        'kind': 'normalize_punctuation',
      }),
      BuiltinCleanupRule('cnpunct', '中文标点', '中文语境里的英文标点、省略号、破折号、重复引号', {
        'kind': 'chinese_punctuation',
        'options': {
          'marks': true,
          'ellipsis': true,
          'dashes': true,
          'quotes': true,
        },
      }),
    ],
  ),
  (
    '扫描版（OCR）',
    [
      BuiltinCleanupRule('ocrspace', 'OCR 汉字间空格', '去掉汉字之间多余的空格', {
        'kind': 'ocr_han_spaces',
      }),
      BuiltinCleanupRule('ocrdots', 'OCR 省略号', '把“。。。”“...”改成省略号', {
        'kind': 'ocr_ellipsis',
      }),
      BuiltinCleanupRule('wraps', '合并句中换行', '一句话被硬换行拆开时接回去', {
        'kind': 'join_hard_wraps',
        'mode': 'chinese',
        'min_chars': 12,
      }),
    ],
  ),
  (
    '转换',
    [
      BuiltinCleanupRule('t2s', '繁体转简体', '按开放中文转换字典', {
        'kind': 'chinese_variant',
        'direction': 't2s',
        'dictionary_version': 'ferrous-opencc-0.4.0',
      }),
      BuiltinCleanupRule('s2t', '简体转繁体', '按开放中文转换字典', {
        'kind': 'chinese_variant',
        'direction': 's2t',
        'dictionary_version': 'ferrous-opencc-0.4.0',
      }),
      BuiltinCleanupRule('numbers', '章节编号统一为汉字', '“第12章”改为“第十二章”', {
        'kind': 'chapter_numbers',
        'style': 'chinese',
        'bare_titles': false,
      }),
    ],
  ),
  (
    '去除',
    [
      BuiltinCleanupRule('dups', '连续重复标题', '同一标题连着出现两次时去掉一个', {
        'kind': 'remove_duplicate_titles',
      }),
      BuiltinCleanupRule('notices', '公告与求票行', '按内置关键词找“求月票”“更新公告”等行', {
        'kind': 'notice_lines',
        'options': {
          'include_defaults': true,
          'include_headers': true,
          'ignore_case': true,
          'keywords': <String>[],
          'preserve_keywords': <String>[],
          'pattern': null,
          'preserve_pattern': null,
        },
      }),
    ],
  ),
];

/// 分组开关列表。[counts]：规则 id → 单独执行时会改几处（null 为还在计算或算不出）。
class CleanupBuiltinRules extends StatelessWidget {
  const CleanupBuiltinRules({
    super.key,
    required this.rules,
    required this.counts,
    required this.counting,
    required this.enabled,
    required this.onToggle,
    required this.onEdit,
  });
  final List<Map<String, dynamic>> rules;
  final Map<String, int?> counts;
  final bool counting, enabled;
  final void Function(BuiltinCleanupRule rule, bool on) onToggle;
  final void Function(int index) onEdit;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return ListView(
      key: const ValueKey('cleanup-builtin-rules'),
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final (group, items) in builtinCleanupGroups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
            child: Text(group, style: ui(11.5, w: 650, c: d.ink3)),
          ),
          for (final item in items) row(context, item),
        ],
      ],
    );
  }

  Widget row(BuildContext context, BuiltinCleanupRule item) {
    final d = context.desk;
    final index = rules.indexWhere(item.matches);
    final on = index >= 0 && rules[index]['enabled'] != false;
    final count = counts[item.id];
    final countText = count == null
        ? (counting ? '计算中' : '')
        : count == 0
        ? '无改动'
        : '$count 处';
    return InkWell(
      key: ValueKey('cleanup-builtin-${item.id}'),
      borderRadius: BorderRadius.circular(6),
      onTap: enabled ? () => onToggle(item, !on) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              height: 22,
              child: FittedBox(
                child: Switch(
                  value: on,
                  onChanged: enabled ? (v) => onToggle(item, v) : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(13, w: on ? 600 : 450, c: d.ink),
                  ),
                  Text(
                    item.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(11, c: d.ink3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              countText,
              style: ui(
                11.5,
                w: (count ?? 0) > 0 ? 600 : 400,
                c: (count ?? 0) > 0 ? d.ink2 : d.ink3,
              ),
            ),
            if (index >= 0)
              IconButton(
                tooltip: '规则设置',
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? () => onEdit(index) : null,
                icon: Icon(Icons.tune_rounded, size: 16, color: d.ink3),
              )
            else
              const SizedBox(width: 40),
          ],
        ),
      ),
    );
  }
}
