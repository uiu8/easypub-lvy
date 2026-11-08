// 识别规则摘要（V23，CH-261）：章节目录标题行右侧的小标签，按本书实际生效的规则生成，
// 点一下打开“本书识别规则”。规则只读，不做任何修改；读取失败时只显示图标入口。
import 'package:flutter/material.dart';

import '../../application/chapter_rules_service.dart';
import '../tokens.dart';

int _lines(Object? text) =>
    '${text ?? ''}'.split('\n').where((l) => l.trim().isNotEmpty).length;

/// 例外条数：允许重复的标题、标题后缀按行计；允许的编号跳跃按逗号、顿号或空白分隔计。
int ruleExceptionCount(Map<String, dynamic> rules) =>
    _lines(rules['allowed_duplicate_titles']) +
    _lines(rules['title_suffixes']) +
    '${rules['allowed_number_gaps'] ?? ''}'
        .split(RegExp(r'[,，、\s]+'))
        .where((s) => s.isNotEmpty)
        .length;

/// 摘要文字，如“内置 · 纯数字 · 例外 2”。
String rulesSummary(Map<String, dynamic> rules) {
  String text(String key) => '${rules[key] ?? ''}'.trim();
  final parts = <String>[
    if (text('chapter_pattern').isNotEmpty)
      '自定义正则'
    else if ([
      'volume_pattern',
      'level_chapter_pattern',
      'section_pattern',
    ].any((k) => text(k).isNotEmpty))
      '内置 · 自定义层级'
    else
      '内置',
    if (rules['numeric'] == true) '纯数字',
  ];
  final exceptions = ruleExceptionCount(rules);
  if (exceptions > 0) parts.add('例外 $exceptions');
  final words = _lines(rules['non_heading']) + _lines(rules['force_heading']);
  if (words > 0) parts.add('词库 $words');
  return parts.join(' · ');
}

class RulesSummaryChip extends StatefulWidget {
  const RulesSummaryChip({
    super.key,
    required this.service,
    required this.bookId,
    required this.headings,
    required this.onOpen,
    this.revision = 0,
  });

  final ChapterRulesService service;
  final String? bookId;

  /// 当前识别出的标题数；为 0 时显示提示圆点。
  final int headings;
  final VoidCallback? onOpen;

  /// 规则面板关闭后递增，重新读取摘要。
  final int revision;

  @override
  State<RulesSummaryChip> createState() => _RulesSummaryChipState();
}

class _RulesSummaryChipState extends State<RulesSummaryChip> {
  String summary = '';
  bool draft = false;
  int ticket = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(RulesSummaryChip old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision || old.bookId != widget.bookId) load();
  }

  Future<void> load() async {
    final mine = ++ticket;
    try {
      final data = await widget.service.openRules(widget.bookId).load();
      if (!mounted || mine != ticket) return;
      setState(() {
        summary = rulesSummary(Map<String, dynamic>.from(data['rules'] as Map));
        draft = data['draft'] is Map;
      });
    } catch (_) {
      if (mounted && mine == ticket) setState(() => summary = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final hints = [
      if (widget.headings == 0) '没有识别出章节，可以调整识别规则',
      if (draft) '有尚未应用的规则草稿',
    ];
    final tip = [
      summary.isEmpty ? '识别规则' : '本书识别规则：$summary',
      ...hints,
      '点击打开',
    ].join('\n');
    return LayoutBuilder(
      builder: (context, box) {
        // 窄栏只留图标，入口不收进菜单。
        final iconOnly = box.maxWidth < 110 || summary.isEmpty;
        return Tooltip(
          message: tip,
          child: Material(
            color: d.surface,
            shape: StadiumBorder(side: BorderSide(color: d.lineStrong)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('chapter-rules-summary'),
              onTap: widget.onOpen,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: iconOnly ? 6 : 8,
                  vertical: 2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hints.isNotEmpty) ...[
                      Container(
                        key: const ValueKey('chapter-rules-hint'),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: d.warn,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Icon(Icons.tune_rounded, size: 13, color: d.ink2),
                    if (!iconOnly) ...[
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(11.5, c: d.ink2),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
