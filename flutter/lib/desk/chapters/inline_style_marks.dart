// 章节页文字样式（V106，LAY-152）：工具条“文字样式…”、样式对话框（可跨行选择）、
// 排版视图里的样式显示与停用提示。数据与输出由 V105 的 InlineStyleSession 提供；
// 所有写入先预览、再确认，与本书其他制作修改共用一条变更记录。跨行选择拆成逐行条目，一次写入、一次撤销。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/inline_style_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 七种样式的名称，顺序即对话框里的顺序。
const inlineStyleLabels = {
  'bold': '加粗',
  'italic': '斜体',
  'em_dot': '着重号',
  'underline': '下划线',
  'wavy': '波浪线',
  'kai': '楷体',
  'fang_song': '仿宋',
};

/// 一次最多给多少行加样式：再多对话框放不下，也不好核对。
const inlineStyleMaxLines = 50;

String inlineStyleMessage(Object error) =>
    error is InlineStyleException ? error.toString() : '无法处理文字样式，请稍后重试。';

/// 行内的一段样式：本行原文里的 UTF-16 半开区间。
typedef InlineStyleRange = ({int from, int to, String style});

/// 几种样式叠在一起的近似显示。着重号画成点线下划线；下划线类同时有几种时只画最显眼的一种。
TextStyle inlineStyleLook(Iterable<String> styles) {
  final s = styles.toSet();
  final decoration = s.contains('wavy')
      ? TextDecorationStyle.wavy
      : s.contains('underline')
      ? TextDecorationStyle.solid
      : s.contains('em_dot')
      ? TextDecorationStyle.dotted
      : null;
  return TextStyle(
    fontWeight: s.contains('bold') ? FontWeight.w700 : null,
    fontStyle: s.contains('italic') ? FontStyle.italic : null,
    decoration: decoration == null ? null : TextDecoration.underline,
    decorationStyle: decoration,
    decorationThickness: decoration == TextDecorationStyle.dotted ? 2.5 : null,
    fontFamily: s.contains('kai')
        ? 'KaiTi'
        : s.contains('fang_song')
        ? 'FangSong'
        : null,
    fontFamilyFallback: s.contains('kai')
        ? const ['STKaiti']
        : s.contains('fang_song')
        ? const ['STFangsong']
        : null,
  );
}

/// 按样式区间画一行。[shown] 是实际显示的文字（排版视图可能去掉了首尾空白或括号）；
/// 在原文 [raw] 里找得到时把区间平移过去，找不到就不画样式。[boldEnd] 是要加粗的开头字数（系统提示关键词）。
InlineSpan inlineStyledSpan(
  String raw,
  String shown,
  List<InlineStyleRange> ranges, {
  int? boldEnd,
}) {
  final base = ranges.isEmpty ? -1 : raw.indexOf(shown);
  final shifted = base < 0
      ? const <InlineStyleRange>[]
      : [
          for (final r in ranges)
            if (r.to - base > 0 && r.from - base < shown.length)
              (
                from: (r.from - base).clamp(0, shown.length),
                to: (r.to - base).clamp(0, shown.length),
                style: r.style,
              ),
        ];
  if (shifted.isEmpty && boldEnd == null) return TextSpan(text: shown);
  final cuts = <int>{0, shown.length, ?boldEnd};
  for (final r in shifted) {
    cuts
      ..add(r.from)
      ..add(r.to);
  }
  final order = cuts.toList()..sort();
  return TextSpan(
    children: [
      for (var i = 0; i + 1 < order.length; i++)
        if (order[i] < order[i + 1])
          TextSpan(
            text: shown.substring(order[i], order[i + 1]),
            style:
                inlineStyleLook([
                  for (final r in shifted)
                    if (r.from <= order[i] && order[i + 1] <= r.to) r.style,
                ]).merge(
                  boldEnd != null && order[i + 1] <= boldEnd
                      ? const TextStyle(fontWeight: FontWeight.w700)
                      : null,
                ),
          ),
    ],
  );
}

/// 一本书的文字样式状态。章节页创建并释放；正文组件监听它重绘。
class InlineStyleController extends ChangeNotifier {
  InlineStyleController(this.session) {
    session.changes.addListener(_onChanged);
    unawaited(refresh());
  }
  final InlineStyleSession session;
  InlineStyleSnapshot? snapshot;
  String error = '';
  Timer? _debounce;
  int _generation = 0;
  bool _disposed = false;

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed) unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    try {
      final next = await session.list();
      if (_disposed || generation != _generation) return;
      snapshot = next;
      error = '';
    } on InlineStyleException catch (e) {
      if (_disposed || generation != _generation) return;
      if (e.reason != 'inline_style_stale') error = e.toString();
    }
    if (!_disposed) notifyListeners();
  }

  List<InlineStyleView> get invalid =>
      (snapshot?.items ?? const <InlineStyleView>[])
          .where((v) => !v.valid)
          .toList(growable: false);

  /// 某分节内每行（正文行号，从 1 开始）的有效样式。
  Map<int, List<InlineStyleView>> stylesFor(String entry) {
    final result = <int, List<InlineStyleView>>{};
    for (final view in snapshot?.items ?? const <InlineStyleView>[]) {
      final at = view.location;
      if (view.valid && at != null && at.entryId == entry) {
        (result[at.line] ??= []).add(view);
      }
    }
    return result;
  }

  Future<void> confirm(InlineStylePreview preview) async {
    await session.confirm(preview);
    await refresh();
  }

  void report(String message) {
    error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    session.changes.removeListener(_onChanged);
    session.dispose();
    super.dispose();
  }
}

/// 某行的样式区间（给 [inlineStyledSpan] 用）。
List<InlineStyleRange> inlineStyleRanges(Iterable<InlineStyleView> views) => [
  for (final v in views)
    if (v.location case final at?)
      (from: at.utf16Start, to: at.utf16End, style: v.style),
];

/// 打开样式对话框所需的本章上下文：所选几行（本节正文行号、原文）。
class InlineStyleContext {
  const InlineStyleContext({
    required this.entryId,
    required this.lines,
    required this.lineLabel,
    required this.title,
  });
  final String entryId;
  final List<(int, String)> lines;

  /// 正文行号对应的显示行号，例如“第 13 行”；[title] 是所选范围，例如“第 13–15 行”。
  final String Function(int line) lineLabel;
  final String title;
}

Future<bool> showInlineStyleDialog(
  BuildContext context,
  InlineStyleController controller,
  InlineStyleContext at,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InlineStyleDialog(controller: controller, at: at),
    ) ==
    true;

/// 所选几行的原文；已有样式按样式画出来。
class _StyledLines extends TextEditingController {
  _StyledLines(this.at, this.controller)
    : super(text: at.lines.map((l) => l.$2).join('\n'));
  final InlineStyleContext at;
  final InlineStyleController controller;

  /// 每行在合并文字里的起点。
  late final starts = () {
    final result = <int>[];
    var offset = 0;
    for (final (_, text) in at.lines) {
      result.add(offset);
      offset += text.length + 1;
    }
    return result;
  }();

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final styles = controller.stylesFor(at.entryId);
    return TextSpan(
      style: style,
      children: [
        for (var i = 0; i < at.lines.length; i++) ...[
          if (i > 0) const TextSpan(text: '\n'),
          inlineStyledSpan(
            at.lines[i].$2,
            at.lines[i].$2,
            inlineStyleRanges(styles[at.lines[i].$1] ?? const []),
          ),
        ],
      ],
    );
  }

  /// 选区拆成逐行的（行号、行内起点、行内终点）；换行本身不算，空段跳过。
  List<(int, int, int)> pieces(TextSelection s) {
    if (!s.isValid || s.isCollapsed) return const [];
    final result = <(int, int, int)>[];
    for (var i = 0; i < at.lines.length; i++) {
      final length = at.lines[i].$2.length;
      final from = (s.start - starts[i]).clamp(0, length);
      final to = (s.end - starts[i]).clamp(0, length);
      if (from < to) result.add((at.lines[i].$1, from, to));
    }
    return result;
  }
}

/// 给所选文字加样式，或修改、删除所选行已有的样式：选文字与样式 → 预览变更 → 确认。
class InlineStyleDialog extends StatefulWidget {
  const InlineStyleDialog({
    super.key,
    required this.controller,
    required this.at,
  });
  final InlineStyleController controller;
  final InlineStyleContext at;
  @override
  State<InlineStyleDialog> createState() => _InlineStyleDialogState();
}

class _InlineStyleDialogState extends State<InlineStyleDialog> {
  late final field = _StyledLines(widget.at, widget.controller);
  final chosen = <String>{};
  InlineStylePreview? preview;

  /// 预览的是新加样式（确认后关闭对话框）还是改、删已有样式（确认后回到对话框）。
  bool adding = false;
  String error = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    field.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    field.removeListener(_changed);
    field.dispose();
    super.dispose();
  }

  List<(int, int, int)> get pieces => field.pieces(field.selection);

  String? get missing {
    if (pieces.isEmpty) return '先在上面选中要加样式的文字';
    if (chosen.isEmpty) return '再选一种或几种样式';
    return null;
  }

  void toggle(String style, bool on) => setState(() {
    if (!on) {
      chosen.remove(style);
      return;
    }
    // 楷体与仿宋是两种字体，同一段文字只能选一种。
    if (style == 'kai') chosen.remove('fang_song');
    if (style == 'fang_song') chosen.remove('kai');
    chosen.add(style);
  });

  /// 所选行里已有的有效样式。
  List<InlineStyleView> get existing {
    final styles = widget.controller.stylesFor(widget.at.entryId);
    return [for (final (line, _) in widget.at.lines) ...?styles[line]];
  }

  Future<void> run(
    Future<InlineStylePreview> Function(InlineStyleSession session) make, {
    required bool add,
  }) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final next = await make(widget.controller.session);
      if (mounted) {
        setState(() {
          preview = next;
          adding = add;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = inlineStyleMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> previewAdd() => run((session) async {
    final snap = await session.list();
    final drafts = <InlineStyleDraft>[];
    for (final (line, from, to) in pieces) {
      final anchor = await session.resolvePosition(
        snap,
        entryId: widget.at.entryId,
        line: line,
        utf16Start: from,
        utf16End: to,
      );
      for (final style in inlineStyleLabels.keys.where(chosen.contains)) {
        drafts.add(InlineStyleDraft(anchor, style));
      }
    }
    return drafts.length == 1
        ? session.previewAdd(snap, drafts.single)
        : session.previewAddAll(snap, drafts);
  }, add: true);

  Future<void> previewChange(InlineStyleView view, String style) =>
      run((session) async {
        final snap = await session.list();
        return session.previewUpdate(
          snap,
          view.id,
          InlineStyleDraft(view.anchor, style),
        );
      }, add: false);

  Future<void> previewDelete(InlineStyleView view) =>
      run((session) => session.previewDelete(view.id), add: false);

  Future<void> confirm() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.controller.confirm(preview!);
      if (!mounted) return;
      if (adding) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          preview = null;
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = inlineStyleMessage(e);
          busy = false;
        });
      }
    }
  }

  Widget styleChip(String style) {
    final d = context.desk;
    return FilterChip(
      key: ValueKey(('inline-style-choose', style)),
      label: Text(
        inlineStyleLabels[style]!,
        style: ui(12.5, c: d.ink).merge(inlineStyleLook([style])),
      ),
      selected: chosen.contains(style),
      showCheckmark: false,
      selectedColor: d.accentSoft,
      side: BorderSide(color: chosen.contains(style) ? d.accent : d.line),
      visualDensity: VisualDensity.compact,
      onSelected: busy ? null : (on) => toggle(style, on),
    );
  }

  Widget notes(Iterable<String> codes) {
    final d = context.desk;
    final shown = codes.toSet();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final code in shown)
            Text(
              '· ${inlineStyleFormatNotes[code] ?? code}',
              key: ValueKey(('inline-style-format-note', code)),
              style: ui(11.5, c: d.tone(Tone.warn).$1, h: 1.5),
            ),
        ],
      ),
    );
  }

  Widget form() {
    final d = context.desk;
    final parts = pieces;
    final selectedText = parts.isEmpty
        ? ''
        : [
            for (final (line, from, to) in parts)
              widget.at.lines
                  .firstWhere((l) => l.$1 == line)
                  .$2
                  .substring(from, to),
          ].join(' / ');
    final styles = inlineStyleLabels.keys.where(chosen.contains);
    final current = existing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DeskLabel(
          widget.at.lines.length == 1
              ? '1. 在这一行里选中要加样式的文字'
              : '1. 选中要加样式的文字（可以跨行，换行本身不加样式）',
        ),
        TextField(
          key: const ValueKey('inline-style-text'),
          controller: field,
          readOnly: true,
          showCursor: true,
          minLines: 1,
          maxLines: 8,
          style: serif(15, c: d.ink, h: 1.7),
          decoration: deskInput(context),
        ),
        const SizedBox(height: 4),
        Text(
          parts.isEmpty
              ? '还没有选中文字'
              : parts.length == 1
              ? '已选中“$selectedText”'
              : '已选中 ${parts.length} 行，将拆成 ${parts.length} 段分别加样式，记为一步',
          key: const ValueKey('inline-style-selection'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: ui(11.5, c: d.ink3),
        ),
        const DeskLabel('2. 选择样式（可多选，楷体与仿宋只能选一种）'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final s in inlineStyleLabels.keys) styleChip(s)],
        ),
        if (parts.isNotEmpty && chosen.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('inline-style-effect'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: d.paper,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: d.line),
            ),
            child: Text(
              selectedText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: serif(15, c: d.ink, h: 1.7).merge(inlineStyleLook(styles)),
            ),
          ),
          Text('效果只是近似，以生成预览和真机为准。', style: ui(11, c: d.ink3)),
        ],
        notes([
          for (final s in styles)
            ...switch (s) {
              'wavy' => const ['kfx_underline_fallback'],
              'kai' || 'fang_song' => const [
                'azw3_mobi_font_fallback',
                'reader_font_required',
              ],
              _ => const <String>[],
            },
        ]),
        if (current.isNotEmpty) ...[
          DeskLabel(widget.at.lines.length == 1 ? '本行已有的样式' : '所选行已有的样式'),
          for (final view in current) existingRow(view),
        ],
      ],
    );
  }

  Widget existingRow(InlineStyleView view) {
    final d = context.desk;
    return Padding(
      key: ValueKey(('inline-style-existing', view.id)),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          DeskTag(inlineStyleLabels[view.style] ?? view.style, Tone.info),
          const SizedBox(width: 8),
          if (widget.at.lines.length > 1 && view.location != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                widget.at.lineLabel(view.location!.line),
                style: mono(11, c: d.ink3),
              ),
            ),
          Expanded(
            child: Text(
              view.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: serif(14, c: d.ink).merge(inlineStyleLook([view.style])),
            ),
          ),
          MenuAnchor(
            menuChildren: [
              for (final MapEntry(key: style, value: label)
                  in inlineStyleLabels.entries)
                if (style != view.style)
                  MenuItemButton(
                    key: ValueKey(('inline-style-change-to', view.id, style)),
                    onPressed: () => previewChange(view, style),
                    child: Text(label),
                  ),
            ],
            builder: (context, menu, _) => DeskButton(
              '改为…',
              key: ValueKey(('inline-style-change', view.id)),
              quiet: true,
              onPressed: busy
                  ? null
                  : () => menu.isOpen ? menu.close() : menu.open(),
            ),
          ),
          DeskButton(
            '删除',
            key: ValueKey(('inline-style-delete', view.id)),
            quiet: true,
            dangerous: true,
            onPressed: busy ? null : () => previewDelete(view),
          ),
        ],
      ),
    );
  }

  Widget previewBody() {
    final d = context.desk;
    final p = preview!;
    final before = {for (final v in p.before.items) v.id: v};
    final after = {for (final v in p.after.items) v.id: v};
    final added = [
      for (final v in p.after.items)
        if (!before.containsKey(v.id)) v,
    ];
    final removed = [
      for (final v in p.before.items)
        if (!after.containsKey(v.id)) v,
    ];
    final changed = [
      for (final v in p.after.items)
        if (before[v.id] case final old? when old.style != v.style) (old, v),
    ];
    String where(InlineStyleView v) =>
        v.location == null ? '' : '${widget.at.lineLabel(v.location!.line)} ';
    Widget row(String tag, Tone tone, InlineStyleView v, {String? note}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              DeskTag(tag, tone),
              const SizedBox(width: 8),
              Text(where(v), style: mono(11, c: d.ink3)),
              Expanded(
                child: Text(
                  v.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: serif(
                    14,
                    c: d.ink,
                  ).merge(inlineStyleLook(tone == Tone.pen ? [] : [v.style])),
                ),
              ),
              if (note != null) Text(note, style: ui(11.5, c: d.ink2)),
            ],
          ),
        );
    return Column(
      key: const ValueKey('inline-style-preview-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          added.isNotEmpty
              ? added.length == 1
                    ? '将添加 1 处文字样式。'
                    : '将添加 ${added.length} 处文字样式，记为一步，撤销一次即可全部撤回。'
              : changed.isNotEmpty
              ? '将修改 ${changed.length} 处文字样式。'
              : removed.isNotEmpty
              ? '将删除 ${removed.length} 处文字样式。'
              : '预览中没有变化，请返回修改。',
          style: ui(
            13,
            c: added.isEmpty && changed.isEmpty && removed.isEmpty
                ? d.pen
                : d.ink,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: d.paper,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: d.line),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final v in added)
                  row(inlineStyleLabels[v.style] ?? v.style, Tone.ok, v),
                for (final (old, v) in changed)
                  row(
                    inlineStyleLabels[v.style] ?? v.style,
                    Tone.info,
                    v,
                    note: '原为${inlineStyleLabels[old.style] ?? old.style}',
                  ),
                for (final v in removed)
                  row(
                    '删除${inlineStyleLabels[v.style] ?? v.style}',
                    Tone.pen,
                    v,
                  ),
              ],
            ),
          ),
        ),
        notes([
          for (final v in [...added, for (final c in changed) c.$2])
            ...v.formatNotes,
        ]),
        const SizedBox(height: 8),
        Text('确认前不会写入本书；原稿不改。确认后可在“记录”中撤销。', style: ui(11.5, c: d.ink3)),
      ],
    );
  }

  bool get previewChanges {
    final p = preview;
    if (p == null) return false;
    final before = {for (final v in p.before.items) v.id: v.style};
    final after = {for (final v in p.after.items) v.id: v.style};
    return before.length != after.length ||
        after.entries.any((e) => before[e.key] != e.value);
  }

  @override
  Widget build(BuildContext context) {
    final reason = missing;
    return DeskDialog(
      title: '文字样式 · ${widget.at.title}',
      subtitle: preview == null ? null : '预览：确认后写入本书',
      closeTooltip: '取消',
      width: 600,
      busy: busy,
      onClose: () => Navigator.pop(context, false),
      footerLeft: error.isEmpty
          ? null
          : Text(
              error,
              key: const ValueKey('inline-style-error'),
              style: ui(12, c: context.desk.pen),
            ),
      actions: preview == null
          ? [
              DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
              DeskButton(
                '预览变更',
                key: const ValueKey('inline-style-preview'),
                primary: true,
                disabledReason: reason,
                onPressed: busy || reason != null ? null : previewAdd,
              ),
            ]
          : [
              DeskButton(
                '返回修改',
                key: const ValueKey('inline-style-back'),
                onPressed: busy ? null : () => setState(() => preview = null),
              ),
              DeskButton(
                '确认',
                key: const ValueKey('inline-style-confirm'),
                primary: true,
                onPressed: busy || !previewChanges ? null : confirm,
              ),
            ],
      child: preview == null ? form() : previewBody(),
    );
  }
}

/// 停用的文字样式提示条与列表：停用项不进成品，可删除后重新添加。
class InlineStyleInvalidBanner extends StatelessWidget {
  const InlineStyleInvalidBanner({super.key, required this.controller});
  final InlineStyleController controller;

  Future<void> _show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final d = context.desk;
        final invalid = controller.invalid;
        return DeskDialog(
          title: '已停用的文字样式',
          subtitle: '书稿改动后对不上原位置的样式，不再进入成品，也不会自动挪到别处',
          closeTooltip: '关闭',
          width: 520,
          actions: [
            DeskButton(
              '关闭',
              primary: true,
              onPressed: () => Navigator.pop(context),
            ),
          ],
          child: invalid.isEmpty
              ? Text('没有停用的文字样式。', style: ui(13, c: d.ink2))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final view in invalid)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            DeskTag(
                              inlineStyleLabels[view.style] ?? view.style,
                              Tone.warn,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                inlineStyleReasons[view.reason] ?? '原位置已改变。',
                                style: ui(12.5, c: d.ink),
                              ),
                            ),
                            DeskButton(
                              '删除',
                              key: ValueKey((
                                'inline-style-invalid-delete',
                                view.id,
                              )),
                              dangerous: true,
                              quiet: true,
                              onPressed: () async {
                                try {
                                  await controller.confirm(
                                    await controller.session.previewDelete(
                                      view.id,
                                    ),
                                  );
                                } catch (e) {
                                  controller.report(inlineStyleMessage(e));
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    Text(
                      '删除后，选中那几行，用“文字样式…”重新添加。删除记入变更记录。',
                      style: ui(12, c: d.ink2),
                    ),
                  ],
                ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _bar(context),
  );

  Widget _bar(BuildContext context) {
    final d = context.desk;
    final count = controller.invalid.length;
    if (count == 0 && controller.error.isEmpty) return const SizedBox.shrink();
    final (fg, bg) = d.tone(Tone.warn);
    return Container(
      key: const ValueKey('inline-style-invalid-banner'),
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              count == 0
                  ? controller.error
                  : '本书有 $count 处文字样式因书稿改动已停用，成品中不再生效。',
              style: ui(12.5, c: d.ink),
            ),
          ),
          if (count > 0)
            TextButton(
              key: const ValueKey('inline-style-invalid-show'),
              onPressed: () => _show(context),
              child: const Text('查看'),
            ),
        ],
      ),
    );
  }
}
