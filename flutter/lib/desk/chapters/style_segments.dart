import 'package:flutter/material.dart';

import '../../application/block_annotation_service.dart';
import '../../application/inline_style_service.dart';
import '../../application/layout_service.dart';
import '../../application/rule_catalog_service.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'block_marks.dart';
import 'inline_style_marks.dart';
import 'layout_view.dart';
import 'note_marks.dart';

/// 样式片段（V120）：排版视图里被识别或标注、套了样式的每一处文字。
class StyleSegment {
  const StyleSegment({
    required this.group,
    required this.label,
    required this.first,
    required this.last,
    required this.excerpt,
    this.detail = '',
    this.manual = false,
  });

  /// 分组：system / verse / block / inset / style / note。
  final String group;

  /// 名称（例如“系统提示 · 面板”）与所用样式（例如“标题面板”“加粗”）。
  final String label, detail;

  /// 本节正文行号（从 1 开始）。
  final int first, last;
  final String excerpt;

  /// 手工标注的（不是自动识别的）。
  final bool manual;
}

/// 分组名称，顺序即侧栏筛选的顺序。
const styleSegmentGroups = {
  'system': '系统提示',
  'verse': '诗词',
  'block': '书信与引文',
  'inset': '场景',
  'style': '文字样式',
  'note': '注释',
};

Tone styleSegmentTone(String group) => switch (group) {
  'system' => Tone.accent,
  'verse' => Tone.ok,
  'block' => Tone.info,
  'inset' => Tone.warn,
  'style' => Tone.pen,
  _ => Tone.neutral,
};

String _groupOfKind(String kind) => switch (kind) {
  'system' => 'system',
  'verse' => 'verse',
  'letter' || 'quote' => 'block',
  _ => 'inset',
};

/// 本节的样式片段：手工标注按条，自动识别按连续同类的行，文字样式与注释按条；按行号排序。
List<StyleSegment> chapterStyleSegments({
  required Map<int, LayoutLine> layoutLines,
  required Map<int, SystemRole> roles,
  required Map<int, BlockMarkLine> markLines,
  required Map<int, List<InlineStyleView>> styleLines,
  required Map<int, List<NoteLineTag>> noteLines,
  required String Function(int line) text,
  Map? systemStyles,
}) {
  final result = <StyleSegment>[];
  // 手工标注：同一条标注的行合在一起。
  final marks = <String, (BlockAnnotationView, int, int)>{};
  for (final MapEntry(key: line, value: m) in markLines.entries) {
    final seen = marks[m.view.id];
    marks[m.view.id] = seen == null
        ? (m.view, line, line)
        : (
            m.view,
            seen.$2 < line ? seen.$2 : line,
            seen.$3 > line ? seen.$3 : line,
          );
  }
  for (final (view, first, last) in marks.values) {
    if (view.kind == BlockAnnotationKind.none) continue;
    result.add(
      StyleSegment(
        group: _groupOfKind(view.kind.name),
        label: blockAnnotationLabels[view.kind] ?? view.kind.name,
        detail: '手工标注',
        first: first,
        last: last,
        excerpt: view.excerpt,
        manual: true,
      ),
    );
  }
  // 自动识别：连续同类的行算一处（系统提示按单行 / 面板分块）。
  final order = layoutLines.keys.where((l) => markLines[l] == null).toList()
    ..sort();
  var i = 0;
  while (i < order.length) {
    final first = order[i];
    final line = layoutLines[first]!;
    var end = i;
    while (end + 1 < order.length &&
        order[end + 1] == order[end] + 1 &&
        layoutLines[order[end + 1]]!.kind == line.kind &&
        !(line.kind == 'system' && roles[order[end + 1]]?.start == true)) {
      end++;
    }
    final role = roles[first];
    final style = role == null ? null : systemStyles?[role.role];
    result.add(
      StyleSegment(
        group: _groupOfKind(line.kind),
        label: switch (line.kind) {
          'system' => role?.role == 'panel' ? '面板' : '单行提示',
          _ => layoutLineLabel(line, role).replaceAll(' · 署名', ''),
        },
        detail: line.kind == 'system' && style is Map
            ? _styleName(style, role!.role)
            : '',
        first: first,
        last: order[end],
        excerpt: text(first),
      ),
    );
    i = end + 1;
  }
  // 文字样式：同一条样式跨几行时合在一起。
  final styles = <String, (InlineStyleView, int, int)>{};
  for (final MapEntry(key: line, value: list) in styleLines.entries) {
    for (final view in list) {
      final seen = styles[view.id];
      styles[view.id] = seen == null
          ? (view, line, line)
          : (
              view,
              seen.$2 < line ? seen.$2 : line,
              seen.$3 > line ? seen.$3 : line,
            );
    }
  }
  for (final (view, first, last) in styles.values) {
    result.add(
      StyleSegment(
        group: 'style',
        label: '文字样式',
        detail: inlineStyleLabels[view.style] ?? view.style,
        first: first,
        last: last,
        excerpt: view.text,
        manual: true,
      ),
    );
  }
  // 注释：只列正文里的注释标记，不列注释内容所在的行。
  final notes = <String>{};
  for (final MapEntry(key: line, value: tags) in noteLines.entries) {
    for (final tag in tags) {
      if (tag.definition || !notes.add(tag.view.id)) continue;
      result.add(
        StyleSegment(
          group: 'note',
          label: '注释',
          detail: tag.view.marker,
          first: line,
          last: line,
          excerpt: tag.view.text,
          manual: true,
        ),
      );
    }
  }
  result.sort((a, b) {
    final c = a.first.compareTo(b.first);
    return c != 0 ? c : a.group.compareTo(b.group);
  });
  return result;
}

/// 系统提示所用样式的名称：内置预设显示预设名，改过参数的显示“自定义”。
String _styleName(Map style, String role) {
  final id = presetOf(
    style,
    role == 'panel' ? panelPresetNames : notePresetNames,
  );
  return (role == 'panel' ? panelPresetNames : notePresetNames)[id] ?? '自定义';
}

/// 全书一行：章节与各组的处数。
typedef StyleSegmentChapter = ({
  String id,
  String title,
  Map<String, int> counts,
});

/// 排版视图右侧的“样式片段”侧栏：本章逐处列出，点一处跳过去；全书按章列出处数，点一章打开。
class StyleSegmentsPanel extends StatefulWidget {
  const StyleSegmentsPanel({
    super.key,
    required this.segments,
    required this.lineLabel,
    required this.onLocate,
    required this.bookChapters,
    required this.onChapter,
    this.currentChapter,
  });
  final List<StyleSegment> segments;

  /// 本节正文行号范围的显示文字，例如“第 9–11 行”。
  final String Function(int first, int last) lineLabel;
  final ValueChanged<StyleSegment> onLocate;

  /// 全书各章的处数；切到“全书”时才读取。为空时不显示“全书”。
  final Future<List<StyleSegmentChapter>> Function()? bookChapters;
  final ValueChanged<String> onChapter;
  final String? currentChapter;

  @override
  State<StyleSegmentsPanel> createState() => _StyleSegmentsPanelState();
}

/// 侧栏的显示状态在各章之间、跳转后重建时保持（本次运行期间）。
final _scopeMemory = <String>['chapter'];
final _hiddenGroups = <String>{};
final _selectedMemory = <String?, (String, int)>{};

class _StyleSegmentsPanelState extends State<StyleSegmentsPanel> {
  Future<List<StyleSegmentChapter>>? book;
  String get scope =>
      widget.bookChapters == null ? 'chapter' : _scopeMemory.first;

  List<StyleSegment> get shown => [
    for (final s in widget.segments)
      if (!_hiddenGroups.contains(s.group)) s,
  ];

  int? get selected {
    final key = _selectedMemory[widget.currentChapter];
    if (key == null) return null;
    final i = shown.indexWhere((s) => s.group == key.$1 && s.first == key.$2);
    return i < 0 ? null : i;
  }

  void go(int index) {
    final list = shown;
    if (list.isEmpty) return;
    final s = list[index.clamp(0, list.length - 1)];
    setState(() => _selectedMemory[widget.currentChapter] = (s.group, s.first));
    widget.onLocate(s);
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final counts = <String, int>{};
    for (final s in widget.segments) {
      counts[s.group] = (counts[s.group] ?? 0) + 1;
    }
    return Container(
      key: const ValueKey('style-segments'),
      decoration: BoxDecoration(
        color: d.surface,
        border: Border(left: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 6),
            child: Row(
              children: [
                Text('样式片段', style: ui(13, w: 600, c: d.ink)),
                const SizedBox(width: 6),
                Text(
                  scope == 'chapter' ? '${shown.length} 处' : '',
                  style: ui(11.5, c: d.ink3),
                ),
                const Spacer(),
                if (widget.bookChapters != null)
                  DeskSegmented<String>(
                    key: const ValueKey('style-segments-scope'),
                    value: scope,
                    options: const {'chapter': '本章', 'book': '全书'},
                    onChanged: (v) => setState(() {
                      _scopeMemory[0] = v;
                      if (v == 'book') book = null;
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final MapEntry(key: group, value: name)
                    in styleSegmentGroups.entries)
                  _GroupChip(
                    key: ValueKey(('style-segments-group', group)),
                    label: name,
                    count: counts[group] ?? 0,
                    tone: styleSegmentTone(group),
                    on: !_hiddenGroups.contains(group),
                    onTap: () => setState(() {
                      _hiddenGroups.contains(group)
                          ? _hiddenGroups.remove(group)
                          : _hiddenGroups.add(group);
                    }),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: d.line),
          Expanded(child: scope == 'chapter' ? chapterList(d) : bookList(d)),
          if (scope == 'chapter') ...[
            Divider(height: 1, color: d.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    key: const ValueKey('style-segments-previous'),
                    onPressed: shown.isEmpty
                        ? null
                        : () => go((selected ?? shown.length) - 1),
                    icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
                    label: const Text('上一处'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    key: const ValueKey('style-segments-next'),
                    onPressed: shown.isEmpty
                        ? null
                        : () => go((selected ?? -1) + 1),
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                    ),
                    label: const Text('下一处'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget chapterList(Desk d) {
    final list = shown;
    if (list.isEmpty) {
      return Center(
        child: Text(
          widget.segments.isEmpty ? '本章没有套样式的文字' : '没有符合筛选的片段',
          style: ui(12.5, c: d.ink3),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('style-segments-list'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final s = list[i];
        final (fg, bg) = d.tone(styleSegmentTone(s.group));
        final on = selected == i;
        return InkWell(
          key: ValueKey(('style-segment', s.group, s.first)),
          onTap: () => go(i),
          child: Container(
            color: on ? bg : null,
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 36,
                  margin: const EdgeInsets.only(right: 9, top: 1),
                  decoration: BoxDecoration(
                    color: fg,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              s.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ui(12, w: 600, c: d.ink),
                            ),
                          ),
                          if (s.detail.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            DeskPill(
                              Text(s.detail, style: ui(10.5, c: fg)),
                              color: bg,
                            ),
                          ],
                          const Spacer(),
                          Text(
                            widget.lineLabel(s.first, s.last),
                            style: ui(10.5, c: d.ink3),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        s.excerpt.trim().isEmpty ? '（读入后显示）' : s.excerpt.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: serif(12.5, c: d.ink2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget bookList(Desk d) => FutureBuilder<List<StyleSegmentChapter>>(
    future: book ??= widget.bookChapters!(),
    builder: (context, snap) {
      if (snap.hasError) {
        return Center(
          child: Text('读不出全书的样式片段，请稍后重试。', style: ui(12.5, c: d.ink3)),
        );
      }
      if (!snap.hasData) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      return bookRows(d, snap.data!);
    },
  );

  Widget bookRows(Desk d, List<StyleSegmentChapter> all) {
    final chapters = [
      for (final c in all)
        if (c.counts.entries.any(
          (e) => e.value > 0 && !_hiddenGroups.contains(e.key),
        ))
          c,
    ];
    if (chapters.isEmpty) {
      return Center(
        child: Text('全书没有套样式的文字', style: ui(12.5, c: d.ink3)),
      );
    }
    return ListView.builder(
      key: const ValueKey('style-segments-book'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: chapters.length,
      itemBuilder: (_, i) {
        final c = chapters[i];
        final current = c.id == widget.currentChapter;
        return InkWell(
          key: ValueKey(('style-segments-chapter', c.id)),
          onTap: () {
            setState(() => _scopeMemory[0] = 'chapter');
            widget.onChapter(c.id);
          },
          child: Container(
            color: current ? d.sunken : null,
            padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(12.5, w: 600, c: d.ink),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final MapEntry(key: group, value: name)
                        in styleSegmentGroups.entries)
                      if ((c.counts[group] ?? 0) > 0 &&
                          !_hiddenGroups.contains(group))
                        DeskPill(
                          Text(
                            '$name ${c.counts[group]}',
                            style: ui(
                              10.5,
                              c: d.tone(styleSegmentTone(group)).$1,
                            ),
                          ),
                          color: d.tone(styleSegmentTone(group)).$2,
                        ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    super.key,
    required this.label,
    required this.count,
    required this.tone,
    required this.on,
    required this.onTap,
  });
  final String label;
  final int count;
  final Tone tone;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (fg, bg) = d.tone(tone);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: on ? bg : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? fg.withValues(alpha: .35) : d.line),
        ),
        child: Text(
          count > 0 ? '$label $count' : label,
          style: ui(11, c: on ? fg : d.ink3),
        ),
      ),
    );
  }
}
