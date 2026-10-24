// 章节页排版视图（V104，LAY-149–151）：正文按成品的大致样子显示系统提示、诗词等识别结果，
// 行号旁色条区分自动识别与手工标注，悬停时出标签；拖选几行弹出与行号栏相同的标注工具条。
// 识别结果来自规则统计（与正文生成同一套判断）；样式取本书已保存的排版设置。只看和标注，不改文字。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/layout_service.dart';
import '../../application/library_service.dart';
import '../../application/rule_catalog_service.dart';
import '../layout/system_block_look.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'block_marks.dart';

/// 一行系统提示在所属块里的位置：单行提示或面板、是否块首块尾、是否面板标题。
typedef SystemRole = ({String role, bool start, bool end, bool heading});

/// 一本书的排版视图数据：逐行识别结果与本书的系统提示、诗词样式。章节页打开排版视图时创建。
class ChapterLayoutView extends ChangeNotifier {
  ChapterLayoutView({
    required RuleCatalogLibrary rules,
    required this.library,
    required this.bookId,
  }) : service = rules.openRuleCatalog(bookId) {
    service.state.addListener(_changed);
    _readSettings();
    unawaited(_request());
  }
  final LibraryService library;
  final String bookId;
  final RuleCatalogService service;
  bool _disposed = false;

  /// 本书已保存的设置：系统提示方式与分类样式、诗词方式。
  String systemBlock = 'off', verseBlock = 'off';
  Map? systemStyles;

  RuleStatisticsState get state => service.state.value;
  Map<String, List<LayoutLine>> get _lines =>
      state.result?.layoutLines ?? const {};

  void _readSettings() {
    try {
      final session = library.openLayout(bookId);
      try {
        final saved = session.saved;
        systemBlock = saved['system_block_style'] as String? ?? 'box';
        verseBlock = saved['verse_block_style'] as String? ?? 'center';
        systemStyles =
            (saved['system_styles'] as Map?) ?? defaultSystemStyles();
      } finally {
        session.dispose();
      }
    } catch (_) {
      // 读不出设置时按“加框”“居中”显示，识别结果照常标出。
      systemBlock = 'box';
      verseBlock = 'center';
    }
  }

  Future<void> _request() async {
    try {
      await service.request();
    } catch (_) {
      // 失败时状态里有原因，页眉显示“暂时识别不出”。
    }
  }

  void _changed() {
    if (_disposed) return;
    // 书稿、标注或设置变了：重新读设置并重新识别。
    if (state.phase == RuleStatisticsPhase.stale) {
      _readSettings();
      unawaited(_request());
    }
    notifyListeners();
  }

  /// 某分节每行（本节正文行号）的识别结果。
  Map<int, LayoutLine> linesFor(String entry) => {
    for (final l in _lines[entry] ?? const <LayoutLine>[]) l.line: l,
  };

  /// 某分节里连续的系统提示合成的块：一行为单行提示，多行为面板（手工标注指定了样式时照它）；
  /// 面板首行是“叮！”或够短且不含冒号时作标题。与正文生成的分组规则相同。
  Map<int, SystemRole> systemRoles(
    Map<int, LayoutLine> lines,
    Map<int, BlockMarkLine> manual,
    Map<int, String> text,
  ) {
    final result = <int, SystemRole>{};
    final order = lines.keys.toList()..sort();
    var i = 0;
    while (i < order.length) {
      final first = order[i];
      if (lines[first]!.kind != 'system') {
        i++;
        continue;
      }
      final owner = manual[first]?.view.id;
      var end = i;
      while (end + 1 < order.length &&
          order[end + 1] == order[end] + 1 &&
          lines[order[end + 1]]!.kind == 'system' &&
          manual[order[end + 1]]?.view.id == owner) {
        end++;
      }
      final variant = manual[first]?.view.variant;
      final role =
          variant ?? (systemBlock == 'styled' && end > i ? 'panel' : 'note');
      final values = systemStyles?[role];
      final titled =
          systemBlock == 'styled' &&
          role == 'panel' &&
          values is Map &&
          (values['title'] ?? 'none') != 'none' &&
          (isDingLine(text[first] ?? '') || isSystemTitle(text[first] ?? ''));
      for (var k = i; k <= end; k++) {
        result[order[k]] = (
          role: role,
          start: k == i,
          end: k == end,
          heading: titled && k == i,
        );
      }
      i = end + 1;
    }
    return result;
  }

  /// 本节的块数：系统提示、诗词各按连续的行算一处，手工标注按条算。
  ({int system, int verse, int manual}) counts(
    Map<int, LayoutLine> lines,
    Map<int, BlockMarkLine> manual,
  ) {
    var system = 0, verse = 0;
    for (final MapEntry(key: line, value: l) in lines.entries) {
      final previous = lines[line - 1];
      if (previous?.kind == l.kind) continue;
      if (l.kind == 'system') system++;
      if (l.kind == 'verse') verse++;
    }
    return (
      system: system,
      verse: verse,
      manual: {for (final m in manual.values) m.view.id}.length,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    service.state.removeListener(_changed);
    service.dispose();
    super.dispose();
  }
}

/// 自动识别结果的名称。
String layoutLineLabel(LayoutLine line, SystemRole? role) =>
    switch (line.kind) {
      'system' => switch (role?.role) {
        'panel' => '系统提示 · 面板',
        'note' => '系统提示 · 单行',
        _ => '系统提示',
      },
      'verse' => line.css == 'verse-by' ? '诗词 · 署名' : '诗词',
      'chat' => '聊天记录',
      'inset' => '场景',
      'letter' => '书信',
      'quote' => '引文',
      _ => line.kind,
    };

/// 按排版设置画一行：系统提示的提示条、面板，诗词居中或缩进，署名靠右，引文书信与场景缩进。
/// 只是近似，以实际生成预览和真机为准。
class LayoutLineText extends StatelessWidget {
  const LayoutLineText({
    super.key,
    required this.text,
    required this.line,
    required this.role,
    required this.view,
    required this.style,
  });
  final String text;
  final LayoutLine? line;
  final SystemRole? role;
  final ChapterLayoutView view;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final l = line;
    final em = style.fontSize ?? 16;
    if (l == null) return Text(text, style: style);
    switch (l.kind) {
      case 'system':
        return _system(d, em);
      case 'verse':
        final by = l.css == 'verse-by';
        final center = view.verseBlock != 'indent';
        return Padding(
          padding: EdgeInsets.only(left: center || by ? 0 : 2 * em),
          child: Text(
            text.trim(),
            textAlign: by
                ? TextAlign.right
                : center
                ? TextAlign.center
                : TextAlign.start,
            style: style,
          ),
        );
      default:
        return Container(
          margin: EdgeInsets.only(left: em),
          padding: EdgeInsets.symmetric(horizontal: em * .6),
          decoration: BoxDecoration(
            color: l.kind == 'chat' || l.kind == 'inset' ? d.sunken : null,
            border: Border(left: BorderSide(color: d.lineStrong, width: 2)),
          ),
          child: Text(text.trim(), style: style),
        );
    }
  }

  Widget _system(Desk d, double em) {
    final r = role;
    final values = r == null ? null : view.systemStyles?[r.role];
    if (view.systemBlock == 'indent') {
      return Padding(
        padding: EdgeInsets.only(left: 2 * em),
        child: Text(text.trim(), style: style),
      );
    }
    if (view.systemBlock != 'styled' || values is! Map || r == null) {
      // 加框：连续几行一个细框。
      final side = BorderSide(color: d.ink2);
      return Container(
        margin: EdgeInsets.only(
          top: r?.start ?? true ? 4 : 0,
          bottom: r?.end ?? true ? 4 : 0,
        ),
        padding: EdgeInsets.fromLTRB(8, r?.start ?? true ? 3 : 0, 8, 3),
        decoration: BoxDecoration(
          border: Border(
            left: side,
            right: side,
            top: r?.start ?? true ? side : BorderSide.none,
            bottom: r?.end ?? true ? side : BorderSide.none,
          ),
        ),
        child: Text(text.trim(), style: style),
      );
    }
    final look = SystemBlockLook(values, em, 1);
    final ink = style.color ?? d.ink;
    final shown = look.removeBrackets || r.heading
        ? stripSystemBrackets(text)
        : text.trim();
    final base = style.copyWith(
      fontSize: look.fontEm,
      fontWeight: look.bold || r.heading ? FontWeight.w700 : null,
    );
    final key = look.keyBold && !r.heading ? systemKeyEnd(shown) : null;
    // 双线在这里画成同宽的单线；小预览与成品里是双线。
    BorderSide rule(double w) =>
        w <= 0 ? BorderSide.none : BorderSide(color: ink, width: w);
    Widget body = Text.rich(
      key == null
          ? TextSpan(text: shown)
          : TextSpan(
              children: [
                TextSpan(
                  text: shown.substring(0, key),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: shown.substring(key)),
              ],
            ),
      textAlign: look.center ? TextAlign.center : TextAlign.start,
      style: base,
    );
    if (r.heading) {
      body = Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: look.titleGap),
        padding: EdgeInsets.symmetric(
          horizontal: look.side,
          vertical: look.titlePad,
        ),
        decoration: BoxDecoration(
          color: look.title == 'shaded' ? const Color(0xFFE4E4E4) : null,
          border: Border(bottom: rule(look.titleRule)),
        ),
        child: body,
      );
    } else {
      body = Padding(
        padding: EdgeInsets.symmetric(horizontal: look.side),
        child: body,
      );
    }
    final shadedTitle = r.heading && look.title == 'shaded';
    return Container(
      margin: EdgeInsets.only(
        top: r.start ? look.margin / 2 : 0,
        bottom: r.end ? look.margin / 2 : 0,
      ),
      padding: EdgeInsets.only(
        top: r.start && !shadedTitle ? look.pad : 0,
        bottom: r.end ? look.pad : 0,
      ),
      decoration: BoxDecoration(
        color: look.shade,
        border: Border(
          left: rule(look.left),
          right: rule(look.right),
          top: r.start ? rule(look.top) : BorderSide.none,
          bottom: r.end ? rule(look.bottom) : BorderSide.none,
        ),
      ),
      child: body,
    );
  }
}

/// 悬停时的自动识别标签：点一下选中这一块，弹出标注工具条（可改类型或“取消识别”）。
class LayoutAutoTag extends StatelessWidget {
  const LayoutAutoTag({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: Tooltip(
      message: '自动识别：点一下选中这一块，可改成别的类型或取消识别',
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: DeskTag('$label · 自动', Tone.info),
      ),
    ),
  );
}

/// 手工标注的颜色与自动识别的颜色（行号旁色条）。
Color layoutBarColor(Desk d, {required bool manual}) =>
    manual ? d.accent : d.info;
