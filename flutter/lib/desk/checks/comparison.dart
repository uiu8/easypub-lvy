// 左右对照工作区（CHK-042–047）：两张纸面卡片，带有效稿行号栏。
// 版本对照时按最长公共子序列匹配行，未匹配行以朱（左/删除）、苔（右/新增）浅底标出；
// “下一处变化”循环跳转；按已匹配段落同步滚动（不按百分比硬对齐）；窄于 540 时单栏切换。
// 滚到底部自动续读（onMore），两侧内容只读可选择复制。
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import '../tokens.dart';
import '../widgets.dart';

class ComparisonContent {
  const ComparisonContent({
    required this.label,
    required this.rows,
    this.title = '',
    this.focusLine,
    this.onLocate,
    this.nodes = const [],
    this.onMore,
    this.loading = false,
    this.header,
  });
  final String label, title;
  final List<ChapterContextRow> rows;
  final int? focusLine;
  final VoidCallback? onLocate;
  final List<ChapterNode> nodes;
  final VoidCallback? onMore;
  final bool loading;

  /// 替代默认标题行的头部（例如多处位置时的位置下拉）。
  final Widget? header;
}

/// 两个对照面：同一问题的两处位置，或同一位置的两个版本，二者不混用。
class ComparisonWorkspace extends StatefulWidget {
  const ComparisonWorkspace({
    super.key,
    required this.left,
    required this.right,
    this.versions = false,
    this.highlightDifferences = false,
  });
  final ComparisonContent left, right;
  final bool versions, highlightDifferences;

  static const narrowBreakpoint = 540.0;
  @override
  State<ComparisonWorkspace> createState() => _ComparisonWorkspaceState();
}

class _ComparisonWorkspaceState extends State<ComparisonWorkspace> {
  final controllers = [ScrollController(), ScrollController()];
  final rowKeys = [<int, GlobalKey>{}, <int, GlobalKey>{}];
  final paragraphKeys = [<int, GlobalKey>{}, <int, GlobalKey>{}];
  int changeCursor = -1;
  final viewportKeys = [GlobalKey(), GlobalKey()];
  bool syncing = false, linked = true;
  int narrowSide = 0;

  @override
  void initState() {
    super.initState();
    for (var side = 0; side < 2; side++) {
      controllers[side].addListener(() => synchronize(side));
    }
  }

  void synchronize(int side) {
    if (!widget.versions || !linked || syncing) return;
    final other = 1 - side;
    if (!controllers[other].hasClients) return;
    final viewport = viewportKeys[side].currentContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    final y = viewport.localToGlobal(Offset.zero).dy;
    int? anchor;
    double distance = double.infinity, displacement = 0;
    for (final entry in rowKeys[side].entries) {
      if (!rowKeys[other].containsKey(entry.key)) continue;
      final row = entry.value.currentContext?.findRenderObject();
      if (row is! RenderBox || !row.attached) continue;
      final delta = row.localToGlobal(Offset.zero).dy - y;
      if (delta.abs() < distance) {
        distance = delta.abs();
        displacement = delta;
        anchor = entry.key;
      }
    }
    if (anchor == null) return;
    final target = rowKeys[other][anchor]?.currentContext?.findRenderObject();
    final targetViewport = viewportKeys[other].currentContext
        ?.findRenderObject();
    if (target is! RenderBox || targetViewport is! RenderBox) return;
    final delta =
        target.localToGlobal(Offset.zero).dy -
        targetViewport.localToGlobal(Offset.zero).dy;
    syncing = true;
    final controller = controllers[other];
    controller.jumpTo(
      (controller.offset + delta - displacement).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      ),
    );
    syncing = false;
  }

  List<Set<int>> matchingRows() {
    final a = widget.left.rows, b = widget.right.rows;
    final matched = [<int>{}, <int>{}];
    if (a.length * b.length > 160000) {
      var prefix = 0, suffix = 0;
      while (prefix < a.length &&
          prefix < b.length &&
          a[prefix].text == b[prefix].text) {
        matched[0].add(prefix);
        matched[1].add(prefix++);
      }
      while (suffix < a.length - prefix &&
          suffix < b.length - prefix &&
          a[a.length - suffix - 1].text == b[b.length - suffix - 1].text) {
        matched[0].add(a.length - suffix - 1);
        matched[1].add(b.length - suffix - 1);
        suffix++;
      }
      return matched;
    }
    final lengths = List.generate(
      a.length + 1,
      (_) => List.filled(b.length + 1, 0),
    );
    for (var i = a.length - 1; i >= 0; i--) {
      for (var j = b.length - 1; j >= 0; j--) {
        lengths[i][j] = a[i].text == b[j].text
            ? lengths[i + 1][j + 1] + 1
            : (lengths[i + 1][j] > lengths[i][j + 1]
                  ? lengths[i + 1][j]
                  : lengths[i][j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < a.length && j < b.length) {
      if (a[i].text == b[j].text) {
        matched[0].add(i++);
        matched[1].add(j++);
      } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
        i++;
      } else {
        j++;
      }
    }
    return matched;
  }

  InlineSpan changedTitle(Desk d, String text, String other, int side) {
    final chars = text.characters.toList(), old = other.characters.toList();
    var first = 0, last = 0;
    while (first < chars.length &&
        first < old.length &&
        chars[first] == old[first]) {
      first++;
    }
    while (last < chars.length - first &&
        last < old.length - first &&
        chars[chars.length - last - 1] == old[old.length - last - 1]) {
      last++;
    }
    final mark = side == 0 ? d.del : d.add;
    return TextSpan(
      children: [
        TextSpan(text: chars.take(first).join()),
        TextSpan(
          text: chars.sublist(first, chars.length - last).join(),
          style: TextStyle(
            backgroundColor: mark.withValues(alpha: .18),
            decoration: side == 0 ? TextDecoration.lineThrough : null,
            decorationColor: mark,
          ),
        ),
        TextSpan(text: chars.skip(chars.length - last).join()),
      ],
    );
  }

  void nextChange() {
    final matched = matchingRows();
    final changed = <(int, int)>[
      for (var side = 0; side < 2; side++)
        for (final entry
            in (side == 0 ? widget.left.rows : widget.right.rows).indexed)
          if (!matched[side].contains(entry.$1)) (side, entry.$1),
    ];
    if (changed.isEmpty) return;
    changeCursor = (changeCursor + 1) % changed.length;
    final (side, index) = changed[changeCursor];
    if (narrowSide != side) setState(() => narrowSide = side);
    final row = paragraphKeys[side][index]?.currentContext;
    if (row != null) {
      Scrollable.ensureVisible(row, alignment: .15, duration: Duration.zero);
    }
  }

  Widget pane(
    Desk d,
    ComparisonContent content,
    int side,
    List<Set<int>> matched,
  ) {
    rowKeys[side].clear();
    final seen = <int>{};
    final diff = widget.versions || widget.highlightDifferences;
    final other = side == 0 ? widget.right : widget.left;
    final singleLine =
        diff && widget.left.rows.length == 1 && widget.right.rows.length == 1;
    GlobalKey rowKey(int index, ChapterContextRow row) {
      final key = paragraphKeys[side].putIfAbsent(index, GlobalKey.new);
      if (row.originalLine != null && seen.add(row.originalLine!)) {
        rowKeys[side][row.originalLine!] = key;
      }
      return key;
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: d.paper,
        borderRadius: BorderRadius.circular(9),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child:
                      content.header ??
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(content.label, style: ui(11.5, c: d.ink3)),
                          if (content.title.isNotEmpty)
                            Text.rich(
                              widget.versions
                                  ? changedTitle(
                                      d,
                                      content.title,
                                      other.title,
                                      side,
                                    )
                                  : TextSpan(text: content.title),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: serif(14, w: 650, c: d.ink, h: 1.45),
                            ),
                          if (content.nodes.isNotEmpty)
                            Tooltip(
                              message: content.nodes
                                  .map((n) => n.title)
                                  .join('\n'),
                              child: Text(
                                content.nodes.map((n) => n.title).join(' → '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: ui(11.5, c: d.ink3),
                              ),
                            ),
                        ],
                      ),
                ),
                if (content.onLocate != null)
                  IconButton(
                    tooltip: '定位${content.label}',
                    visualDensity: VisualDensity.compact,
                    onPressed: content.onLocate,
                    icon: Icon(
                      Icons.my_location_rounded,
                      size: 17,
                      color: d.ink2,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              key: viewportKeys[side],
              child: NotificationListener<ScrollNotification>(
                onNotification: (event) {
                  if (event.metrics.extentAfter < 160 && !content.loading) {
                    content.onMore?.call();
                  }
                  return false;
                },
                child: Scrollbar(
                  controller: controllers[side],
                  child: SingleChildScrollView(
                    controller: controllers[side],
                    padding: const EdgeInsets.fromLTRB(0, 8, 10, 10),
                    child: SelectionArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: content.rows.isEmpty
                            ? [
                                Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Text(
                                    '此处没有可对应的内容',
                                    style: ui(12.5, c: d.ink3),
                                  ),
                                ),
                              ]
                            : [
                                for (final (index, row) in content.rows.indexed)
                                  _Row(
                                    key: rowKey(index, row),
                                    row: row,
                                    focused: row.line == content.focusLine,
                                    tone: !diff || matched[side].contains(index)
                                        ? null
                                        : (side == 0 ? d.del : d.add),
                                    text: singleLine
                                        ? changedTitle(
                                            d,
                                            row.text,
                                            other.rows.first.text,
                                            side,
                                          )
                                        : TextSpan(
                                            text:
                                                '${row.text}${row.truncated ? '…' : ''}',
                                          ),
                                  ),
                                if (content.loading)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      8,
                                      14,
                                      8,
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.6,
                                            color: d.ink3,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '继续读取对照内容…',
                                          style: ui(11.5, c: d.ink3),
                                        ),
                                      ],
                                    ),
                                  )
                                else if (content.onMore != null)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 52),
                                      child: TextButton(
                                        onPressed: content.onMore,
                                        child: const Text('继续阅读'),
                                      ),
                                    ),
                                  ),
                              ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final d = context.desk;
      final matched = matchingRows();
      final hasCorrespondence = widget.left.rows.any(
        (a) =>
            a.originalLine != null &&
            widget.right.rows.any((b) => b.originalLine == a.originalLine),
      );
      final hasChanges =
          matched[0].length < widget.left.rows.length ||
          matched[1].length < widget.right.rows.length;
      final narrow = bounds.maxWidth < ComparisonWorkspace.narrowBreakpoint;
      final showChanges =
          (widget.versions || widget.highlightDifferences) && hasChanges;
      final showLink = widget.versions && hasCorrespondence;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showChanges || showLink || narrow)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (narrow)
                    DeskSegmented<int>(
                      value: narrowSide,
                      options: {0: widget.left.label, 1: widget.right.label},
                      onChanged: (v) => setState(() => narrowSide = v),
                    ),
                  if (showChanges)
                    TextButton.icon(
                      onPressed: nextChange,
                      icon: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 17,
                      ),
                      label: const Text('下一处变化'),
                      style: TextButton.styleFrom(foregroundColor: d.ink2),
                    ),
                  if (showLink)
                    DeskSegmented<bool>(
                      value: linked,
                      options: const {true: '按对应段落同步', false: '独立滚动'},
                      onChanged: (v) => setState(() => linked = v),
                    ),
                ],
              ),
            ),
          Expanded(
            child: narrow
                ? IndexedStack(
                    index: narrowSide,
                    children: [
                      pane(d, widget.left, 0, matched),
                      pane(d, widget.right, 1, matched),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: pane(d, widget.left, 0, matched)),
                      const SizedBox(width: 10),
                      Expanded(child: pane(d, widget.right, 1, matched)),
                    ],
                  ),
          ),
        ],
      );
    },
  );

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// 对照行：左侧有效稿行号（不进入复制内容），正文宋体；聚焦行灰墨浅底，差异行语义色浅底。
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.row,
    required this.focused,
    required this.tone,
    required this.text,
  });
  final ChapterContextRow row;
  final bool focused;
  final Color? tone;
  final InlineSpan text;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Container(
      color: focused
          ? d.accentSoft
          : tone?.withValues(alpha: d.dark ? .16 : .09),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: SelectionContainer.disabled(
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Text(
                  row.line == null ? '' : '${row.line}',
                  textAlign: TextAlign.right,
                  style: mono(10, c: focused ? d.ink : d.ink3),
                ),
              ),
            ),
          ),
          if (tone != null)
            Container(
              width: 2,
              margin: const EdgeInsets.only(right: 6, top: 3, bottom: 3),
              height: 18,
              color: tone,
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              text,
              style: serif(13.5, c: d.ink, w: focused ? 600 : 400, h: 1.7),
            ),
          ),
        ],
      ),
    );
  }
}
