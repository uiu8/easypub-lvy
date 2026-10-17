// 两章正文对照（CH-096–099、CH-247）：只读。默认两章依次取问题记录的两处位置、同标题、同编号、
// 所在章与下一章；左右两侧都可从全书章节中任选；
// 窄于 700 时一次显示一侧并可切换，各侧选择保留。
import 'package:flutter/material.dart';

import '../../errors.dart';

import '../../../application/chapter_service.dart';
import '../../controls/controls.dart';
import '../../dialogs.dart';
import '../../tokens.dart';
import '../../widgets.dart';
import '../manuscript.dart';

class ChapterBodyCompareDialog extends StatefulWidget {
  const ChapterBodyCompareDialog({
    super.key,
    required this.session,
    this.structure,
    required this.lines,
  });
  final ChapterSession session;

  /// 发起对照时的章节结构；为空时由弹窗读取当前结构（问题详情入口）。
  final ChapterPage? structure;

  /// 问题记录的位置（标题行或正文行）；用于选出默认的两章。
  final List<int> lines;

  @override
  State<ChapterBodyCompareDialog> createState() => _CompareState();
}

/// 标题中的章节编号与单位，如“第456章 2k”→ (456, 章)；没有编号时为 null。
(int, String)? chapterNumber(String title) {
  final m = RegExp(r'^\s*第\s*([0-9０-９零〇一二两三四五六七八九十百千万]+)\s*([章回节卷部篇集])')
      .firstMatch(title);
  if (m == null) return null;
  final raw = m
      .group(1)!
      .replaceAllMapped(
        RegExp('[０-９]'),
        (d) => String.fromCharCode(d.group(0)!.codeUnitAt(0) - 0xFEE0),
      );
  final arabic = int.tryParse(raw);
  if (arabic != null) return (arabic, m.group(2)!);
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000, '万': 10000};
  var total = 0, section = 0, digit = 0;
  for (final ch in raw.split('')) {
    if (digits.containsKey(ch)) {
      digit = digits[ch]!;
    } else if (ch == '万') {
      total += (section + digit) * 10000;
      section = 0;
      digit = 0;
    } else {
      section += (digit == 0 ? 1 : digit) * units[ch]!;
      digit = 0;
    }
  }
  return (total + section + digit, m.group(2)!);
}

/// 选出默认对照的两章（下标）：问题记录的两处位置 → 同标题 → 同编号 → 所在章与下一章。
/// [nodes] 按行号升序；位置可以是标题行，也可以落在章内正文。
(int, int)? defaultComparePair(List<ChapterNode> nodes, List<int> lines) {
  if (nodes.length < 2) return null;
  int? owner(int line) {
    int? found;
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].line <= line) {
        found = i;
      } else {
        break;
      }
    }
    return found;
  }

  final owners = <int>{for (final line in lines) ?owner(line)}.toList()..sort();
  if (owners.length >= 2) return (owners[0], owners[1]);
  if (owners.isEmpty) return (0, 1);
  final first = owners.single;
  final title = nodes[first].title.trim();
  int? other(bool Function(ChapterNode) same) {
    for (var i = 0; i < nodes.length; i++) {
      if (i != first && same(nodes[i])) return i;
    }
    return null;
  }

  final number = chapterNumber(title);
  final match =
      other((n) => n.title.trim() == title) ??
      (number == null ? null : other((n) => chapterNumber(n.title) == number));
  if (match != null) {
    return match < first ? (match, first) : (first, match);
  }
  return first + 1 < nodes.length ? (first, first + 1) : (first - 1, first);
}

class _CompareState extends State<ChapterBodyCompareDialog> {
  List<ChapterNode>? nodes;
  ChapterPage? structure;
  (int, int) pair = (0, 1);
  String error = '';
  int narrowSide = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final all = <ChapterNode>[];
      final session = widget.session;
      var page =
          session is ChapterOutlineSession &&
              (widget.structure?.total ?? 0) <= maxChapterOutlineNodes
          ? await (session as ChapterOutlineSession).readOutline()
          : await session.read(0);
      final guard = widget.structure?.guard ?? page.guard;
      final first = page;
      while (true) {
        if (page.guard != guard) {
          throw const ChapterStateChanged('书稿已变化，请重新检查后对照。');
        }
        all.addAll(page.nodes);
        final next = page.offset + page.nodes.length;
        if (next >= page.total || page.nodes.isEmpty) break;
        page = await session.read(next);
      }
      all.sort((a, b) => a.line.compareTo(b.line));
      final chosen = defaultComparePair(all, widget.lines);
      if (chosen == null) {
        throw const FormatException('本书少于两个章节，无法对照。');
      }
      if (mounted) {
        setState(() {
          nodes = all;
          structure = widget.structure ?? first;
          pair = chosen;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '操作没有完成。'));
      }
    }
  }

  @override
  Widget build(BuildContext context) => DeskDialog(
    title: '两章正文对照',
    subtitle: '分别选择要比较的两章。这里只供核对，不会修改正文。',
    closeTooltip: '关闭正文对照',
    width: 1200,
    height: 760,
    child: error.isNotEmpty
        ? Center(child: DeskNote(error, tone: Tone.pen))
        : nodes == null
        ? const Center(child: CircularProgressIndicator())
        : LayoutBuilder(
            builder: (_, box) {
              Widget pane(int side) => _BodyPane(
                session: widget.session,
                structure: structure!,
                nodes: nodes!,
                initial: side == 0 ? pair.$1 : pair.$2,
                label: side == 0 ? '左侧章节' : '右侧章节',
              );
              if (box.maxWidth >= 700) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: pane(0)),
                    const SizedBox(width: 14),
                    Expanded(child: pane(1)),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DeskSegmented<int>(
                      value: narrowSide,
                      options: const {0: '左侧章节', 1: '右侧章节'},
                      onChanged: (side) => setState(() => narrowSide = side),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: IndexedStack(
                      index: narrowSide,
                      children: [pane(0), pane(1)],
                    ),
                  ),
                ],
              );
            },
          ),
  );
}

class _BodyPane extends StatefulWidget {
  const _BodyPane({
    required this.session,
    required this.structure,
    required this.nodes,
    required this.initial,
    required this.label,
  });
  final ChapterSession session;
  final ChapterPage structure;
  final List<ChapterNode> nodes;
  final int initial;
  final String label;
  @override
  State<_BodyPane> createState() => _BodyPaneState();
}

class _BodyPaneState extends State<_BodyPane> {
  late ChapterNode selected = widget.nodes[widget.initial];
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DeskLabel(widget.label),
      DeskChoice<String>(
        value: selected.id,
        isDense: true,
        isExpanded: true,
        items: [
          for (final node in widget.nodes)
            DropdownMenuItem(
              value: node.id,
              child: Text(
                '${node.title} · 第 ${node.line} 行',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (id) {
          if (id != null) {
            setState(
              () => selected = widget.nodes.firstWhere((n) => n.id == id),
            );
          }
        },
      ),
      const SizedBox(height: 8),
      Expanded(
        child: DeskListBox(
          child: ChapterManuscript(
            key: ValueKey(selected.id),
            session: widget.session,
            page: widget.structure,
            node: selected,
          ),
        ),
      ),
    ],
  );
}
