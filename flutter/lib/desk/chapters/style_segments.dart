import 'package:flutter/material.dart';

import '../../application/block_annotation_service.dart';
import '../../application/inline_style_service.dart';
import '../../application/layout_service.dart';
import '../../application/rule_catalog_service.dart';
import '../../application/system_scope.dart';
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

  /// 分组：system / verse / chat / inset / block / style / note。
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
  'chat': '聊天记录',
  'inset': '场景',
  'block': '书信与引文',
  'style': '文字样式',
  'note': '注释',
};

/// 识别与样式（V121，LAY-173）：侧栏里可开关的识别项——分组、设置字段、名称、选项、开启时默认值、图标。
final _recognitions =
    <(String, String, String, Map<String, String>, String, IconData)>[
      (
        'system',
        'system_block_style',
        '系统提示',
        systemBlockStyles,
        'styled',
        Icons.campaign_outlined,
      ),
      (
        'verse',
        'verse_block_style',
        '诗词',
        verseBlockStyles,
        'center',
        Icons.auto_stories_outlined,
      ),
      (
        'chat',
        'chat_block_style',
        '聊天记录',
        chatBlockStyles,
        'window',
        Icons.forum_outlined,
      ),
      (
        'inset',
        'inset_detect',
        '场景',
        insetDetectModes,
        'on',
        Icons.theater_comedy_outlined,
      ),
      (
        'scene',
        'scene_break_style',
        '场景分隔',
        sceneBreakStyles,
        'keep',
        Icons.more_horiz_rounded,
      ),
      (
        'rare',
        'rare_char_ruby',
        '生僻字注音',
        rareCharRubyModes,
        'chapter',
        Icons.translate_rounded,
      ),
    ];

/// 只有手工标注的分组：侧栏里只作筛选。
const _manualGroups = ['block', 'style', 'note'];

Tone styleSegmentTone(String group) => switch (group) {
  'system' => Tone.accent,
  'verse' => Tone.ok,
  'chat' => Tone.info,
  'block' => Tone.info,
  'inset' => Tone.warn,
  'style' => Tone.pen,
  _ => Tone.neutral,
};

String _groupOfKind(String kind) => switch (kind) {
  'system' => 'system',
  'verse' => 'verse',
  'letter' || 'quote' => 'block',
  'chat' => 'chat',
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
          'system' => switch (role?.role) {
            'panel' => '面板',
            'note' => '单行提示',
            _ => '系统提示',
          },
          _ => layoutLineLabel(line, role).replaceAll(' · 署名', ''),
        },
        detail: line.kind != 'system'
            ? ''
            : style is Map
            ? _styleName(style, role!.role)
            : switch (role?.role) {
                'box' => '加框',
                'indent' => '缩进',
                _ => '',
              },
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
    this.settings = const {},
    this.brackets,
    this.onSetting,
  });
  final List<StyleSegment> segments;

  /// 本书的排版设置（V121）：识别项的开关与方式。
  final Map<String, Object?> settings;

  /// 整行【】的判断说明（V121，LAY-169）。
  final String? brackets;

  /// 改本书排版设置（进变更记录）；返回失败原因。为空时不显示开关。
  final Future<String?> Function(Map<String, Object?> patch)? onSetting;

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

/// 只看某一组（点识别项或手工分组）；为空时全部列出。
final _focus = <String?>[null];

/// 展开的识别项，以及各识别项关掉前用的方式（再打开时沿用）。
final _expanded = <String?>[null];
final _lastOn = <String, String>{};
final _selectedMemory = <String?, (String, int)>{};

class _StyleSegmentsPanelState extends State<StyleSegmentsPanel> {
  Future<List<StyleSegmentChapter>>? book;
  String get scope =>
      widget.bookChapters == null ? 'chapter' : _scopeMemory.first;

  List<StyleSegment> get shown => [
    for (final s in widget.segments)
      if (_focus.first == null || s.group == _focus.first) s,
  ];

  /// 正在写入的设置字段与上次失败的原因。
  String? busy, error;

  Future<void> set(String field, Map<String, Object?> patch) async {
    final write = widget.onSetting;
    if (write == null || busy != null) return;
    setState(() {
      busy = field;
      error = null;
    });
    final failed = await write(patch);
    if (!mounted) return;
    setState(() {
      busy = null;
      error = failed;
    });
  }

  void focus(String group) => setState(() {
    _focus[0] = _focus.first == group ? null : group;
  });

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
                Text('识别与样式', style: ui(13, w: 600, c: d.ink)),
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
          recognitions(d, counts),
          manualFilters(d, counts),
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
                          Expanded(
                            child: Row(
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
                              ],
                            ),
                          ),
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
          (e) => e.value > 0 && (_focus.first == null || e.key == _focus.first),
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
                          (_focus.first == null || group == _focus.first))
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

  // ---- 识别项（V121，LAY-173）：图标、名称、本章处数、当前方式、开关；点名称只看这一组，点箭头展开方式。
  Widget recognitions(Desk d, Map<String, int> counts) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in _recognitions) recognitionRow(d, r, counts),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text(
              error!,
              key: const ValueKey('recognition-error'),
              style: ui(11.5, c: d.pen),
            ),
          ),
      ],
    ),
  );

  Widget recognitionRow(
    Desk d,
    (String, String, String, Map<String, String>, String, IconData) r,
    Map<String, int> counts,
  ) {
    final (group, field, name, options, fallback, icon) = r;
    final value = widget.settings[field] as String? ?? 'off';
    final on = value != 'off';
    final open = _expanded.first == group;
    final focused = _focus.first == group;
    final (fg, bg) = d.tone(styleSegmentTone(group));
    final countable = styleSegmentGroups.containsKey(group);
    final expandable = group == 'system' || options.length > 2;
    final writable = widget.onSetting != null;
    return Container(
      key: ValueKey(('recognition', group)),
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: open || focused ? d.sunken : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey(('style-segments-group', group)),
            borderRadius: BorderRadius.circular(8),
            onTap: countable ? () => focus(group) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 3, 2, 3),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: on ? bg : d.sunken,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(icon, size: 15, color: on ? fg : d.ink3),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    name,
                    style: ui(
                      12.5,
                      w: focused ? 600 : 400,
                      c: on ? d.ink : d.ink3,
                    ),
                  ),
                  if (countable) ...[
                    const SizedBox(width: 6),
                    Text(
                      on ? '${counts[group] ?? 0} 处' : '',
                      style: ui(11, c: d.ink3),
                    ),
                  ],
                  const Spacer(),
                  if (on && options.length > 2)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 84),
                      child: Text(
                        options[value] ?? value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: ui(11, c: d.ink2),
                      ),
                    ),
                  if (expandable && writable)
                    IconButton(
                      key: ValueKey(('recognition-expand', group)),
                      tooltip: open ? '收起' : '更多方式',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 28,
                      ),
                      iconSize: 18,
                      onPressed: () =>
                          setState(() => _expanded[0] = open ? null : group),
                      icon: Icon(
                        open
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: d.ink3,
                      ),
                    )
                  else
                    const SizedBox(width: 30),
                  if (writable)
                    SizedBox(
                      width: 40,
                      height: 24,
                      child: busy == field
                          ? const Center(
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : FittedBox(
                              child: Switch(
                                key: ValueKey(('recognition-switch', group)),
                                value: on,
                                onChanged: busy != null
                                    ? null
                                    : (v) {
                                        if (!v) _lastOn[field] = value;
                                        set(field, {
                                          field: v
                                              ? (_lastOn[field] ?? fallback)
                                              : 'off',
                                        });
                                      },
                              ),
                            ),
                    ),
                ],
              ),
            ),
          ),
          if (open) recognitionDetail(d, group, field, options, value),
        ],
      ),
    );
  }

  /// 展开后：系统提示用缩略图选方式、选识别范围、看本书判断；其他项选方式。
  Widget recognitionDetail(
    Desk d,
    String group,
    String field,
    Map<String, String> options,
    String value,
  ) {
    final choices = {
      for (final e in options.entries)
        if (e.key != 'off') e.key: e.value,
    };
    if (group != 'system') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(38, 0, 8, 8),
        child: DeskSegmented<String>(
          key: ValueKey(('recognition-style', group)),
          value: choices.containsKey(value) ? value : choices.keys.first,
          options: choices,
          onChanged: busy != null ? null : (v) => set(field, {field: v}),
        ),
      );
    }
    final ruleOptions = Map<String, Object?>.from(
      (widget.settings['rule_options'] as Map?) ?? const {},
    );
    final scope = ruleOptions['system_scope'] as String? ?? 'auto';
    Widget thumb(String id, String label, Widget sample) {
      final picked = value == id;
      return Expanded(
        child: InkWell(
          key: ValueKey(('recognition-style', 'system', id)),
          borderRadius: BorderRadius.circular(7),
          onTap: busy != null || picked ? null : () => set(field, {field: id}),
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
            decoration: BoxDecoration(
              color: d.surface,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: picked ? d.accent : d.line,
                width: picked ? 1.5 : 1,
              ),
            ),
            child: Column(
              children: [
                SizedBox(height: 14, child: sample),
                const SizedBox(height: 3),
                Text(label, style: ui(10.5, c: picked ? d.accent : d.ink2)),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(38, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              thumb(
                'styled',
                '提示条与面板',
                Container(
                  decoration: BoxDecoration(
                    color: d.sunken,
                    border: Border(left: BorderSide(color: d.ink2, width: 2)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              thumb(
                'box',
                '加框',
                Container(
                  decoration: BoxDecoration(border: Border.all(color: d.ink2)),
                ),
              ),
              const SizedBox(width: 6),
              thumb(
                'indent',
                '缩进',
                Container(
                  margin: const EdgeInsets.only(left: 10, top: 5, bottom: 5),
                  color: d.ink3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DeskSegmented<String>(
            key: const ValueKey('recognition-scope'),
            value: systemScopes.containsKey(scope) ? scope : 'auto',
            options: systemScopes,
            onChanged: busy != null
                ? null
                : (v) => set('rule_options', {
                    'rule_options': {...ruleOptions, 'system_scope': v}
                      ..removeWhere(
                        (k, x) => k == 'system_scope' && x == 'auto',
                      ),
                  }),
          ),
          if (widget.brackets != null) ...[
            const SizedBox(height: 6),
            Text(
              widget.brackets!,
              key: const ValueKey('recognition-brackets'),
              style: ui(11, c: d.ink2),
            ),
          ],
        ],
      ),
    );
  }

  /// 只有手工标注的分组：一行筛选。
  Widget manualFilters(Desk d, Map<String, int> counts) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
    child: Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('手工', style: ui(11, c: d.ink3)),
        for (final group in _manualGroups)
          _ManualChip(
            key: ValueKey(('style-segments-group', group)),
            label: styleSegmentGroups[group]!,
            count: counts[group] ?? 0,
            tone: styleSegmentTone(group),
            on: _focus.first == group,
            onTap: () => focus(group),
          ),
      ],
    ),
  );
}

class _ManualChip extends StatelessWidget {
  const _ManualChip({
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: on ? bg : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? fg.withValues(alpha: .35) : d.line),
        ),
        child: Text('$label $count', style: ui(11, c: on ? fg : d.ink3)),
      ),
    );
  }
}
