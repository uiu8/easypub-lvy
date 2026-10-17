// 检查页“文本清理”结果（CHK-055）：按规则汇总与分组，逐行显示“修改前 → 修改后”。
// 空行、行尾空白等看不见的改动用标记显示，不再出现 "\n" 这类转义文字；
// 广告候选标“需人工判断”。只读；处理仍在清理页按“预览 → 确认 → 复查”进行。
import 'package:flutter/material.dart';

import '../../application/book_check_service.dart';
import '../../application/cleanup_service.dart';
import '../tokens.dart';
import '../widgets.dart';

class CleanupFindingsView extends StatefulWidget {
  const CleanupFindingsView({super.key, required this.items, this.onLocate});
  final List<CleanupCheckItem> items;

  /// 在清理页打开检测详情并定位到这一行；为空时不显示定位按钮。
  final void Function(int line)? onLocate;
  @override
  State<CleanupFindingsView> createState() => _CleanupFindingsViewState();
}

class _CleanupFindingsViewState extends State<CleanupFindingsView> {
  String? kind;

  static String label(CleanupCheckItem item) =>
      item.candidate ? '广告候选' : cleanupLabels[item.kind] ?? item.kind;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final groups = <String, List<CleanupCheckItem>>{};
    for (final item in widget.items) {
      groups.putIfAbsent(label(item), () => []).add(item);
    }
    final shown = kind == null ? groups.keys.toList() : [kind!];
    Widget chip(String? key, String text, int count) {
      final on = kind == key;
      return InkWell(
        key: ValueKey('cleanup-filter-${key ?? 'all'}'),
        borderRadius: BorderRadius.circular(7),
        onTap: () => setState(() => kind = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: on ? d.surface : d.sunken,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: on ? d.ink2 : Colors.transparent),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text,
                style: ui(12.5, w: on ? 620 : 500, c: d.ink),
              ),
              const SizedBox(width: 6),
              Text('$count', style: mono(11.5, c: d.ink3)),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            chip(null, '全部', widget.items.length),
            for (final e in groups.entries) chip(e.key, e.key, e.value.length),
          ],
        ),
        const SizedBox(height: 12),
        for (final name in shown) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Row(
              children: [
                Text(name, style: ui(13, w: 650, c: d.ink)),
                const SizedBox(width: 8),
                Text('${groups[name]!.length} 处', style: ui(12, c: d.ink3)),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: d.surface,
              borderRadius: BorderRadius.circular(9),
              boxShadow: d.shadow1,
            ),
            child: Column(
              children: [
                for (final (i, item) in groups[name]!.indexed)
                  _FindingRow(
                    key: ValueKey('cleanup-finding-${item.line}-${item.kind}'),
                    item: item,
                    divider: i > 0,
                    onLocate: widget.onLocate == null
                        ? null
                        : () => widget.onLocate!(item.line),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({
    super.key,
    required this.item,
    required this.divider,
    this.onLocate,
  });
  final CleanupCheckItem item;
  final bool divider;
  final VoidCallback? onLocate;

  /// 把看不见的字符变成可见标记：空格 ·、全角空格 □、制表符 →。
  static String visible(String text) =>
      text.replaceAll(' ', '·').replaceAll('　', '□').replaceAll('\t', '→');

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final Widget body;
    if (item.candidate) {
      body = Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(item.before, style: ui(13, c: d.ink, h: 1.5)),
          const DeskTag('需人工判断', Tone.warn),
        ],
      );
    } else if (item.after == null) {
      body = item.before.trim().isEmpty
          ? Align(
              alignment: Alignment.centerLeft,
              child: _Mark(
                text: item.before.isEmpty ? '空行' : '空白行',
                removed: true,
              ),
            )
          : Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  item.before,
                  style: ui(
                    13,
                    c: d.pen,
                    h: 1.5,
                  ).copyWith(decoration: TextDecoration.lineThrough),
                ),
                Text('删除此行', style: ui(11.5, c: d.ink3)),
              ],
            );
    } else {
      body = _Diff(before: item.before, after: item.after!);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        border: divider ? Border(top: BorderSide(color: d.line)) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: Text('第 ${item.line} 行', style: mono(11, c: d.ink3)),
          ),
          const SizedBox(width: 8),
          Expanded(child: body),
          if (item.truncated)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text('节选', style: ui(11, c: d.ink3)),
            ),
          if (onLocate != null)
            IconButton(
              tooltip: '在清理页定位此行',
              visualDensity: VisualDensity.compact,
              onPressed: onLocate,
              icon: Icon(Icons.my_location_rounded, size: 16, color: d.ink2),
            ),
        ],
      ),
    );
  }
}

/// 一行内的改写：共同前后缀保持原样，被删除的部分标红划线，新增部分标绿。
class _Diff extends StatelessWidget {
  const _Diff({required this.before, required this.after});
  final String before, after;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    var start = 0;
    while (start < before.length &&
        start < after.length &&
        before[start] == after[start]) {
      start++;
    }
    var end = 0;
    while (end < before.length - start &&
        end < after.length - start &&
        before[before.length - 1 - end] == after[after.length - 1 - end]) {
      end++;
    }
    final removed = before.substring(start, before.length - end);
    final added = after.substring(start, after.length - end);
    final prefix = before.substring(0, start);
    final suffix = before.substring(before.length - end);
    final base = ui(13, c: d.ink, h: 1.5);
    TextSpan side(String middle, bool isBefore) => TextSpan(
      style: base,
      children: [
        TextSpan(
          text: prefix.length > 24
              ? '…${prefix.substring(prefix.length - 24)}'
              : prefix,
        ),
        if (middle.isNotEmpty)
          TextSpan(
            text: _FindingRow.visible(middle),
            style: isBefore
                ? TextStyle(
                    color: d.pen,
                    backgroundColor: d.tone(Tone.pen).$2,
                    decoration: TextDecoration.lineThrough,
                  )
                : TextStyle(color: d.add, backgroundColor: d.addSoft),
          ),
        TextSpan(
          text: suffix.length > 24 ? '${suffix.substring(0, 24)}…' : suffix,
        ),
      ],
    );
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text.rich(side(removed, true)),
        Icon(Icons.arrow_forward_rounded, size: 14, color: d.ink3),
        if (after.isEmpty)
          const _Mark(text: '空', removed: false)
        else
          Text.rich(side(added, false)),
      ],
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({required this.text, required this.removed});
  final String text;
  final bool removed;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: d.sunken,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: d.line),
      ),
      child: Text(
        text,
        style: ui(
          11.5,
          c: d.ink2,
        ).copyWith(decoration: removed ? TextDecoration.lineThrough : null),
      ),
    );
  }
}
