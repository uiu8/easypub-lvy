// 章节页排版视图（V104，LAY-149–151；V120 起按真机规则画，LAY-167）：正文按成品的样子显示系统提示、诗词等识别结果，
// 行号旁色条区分自动识别与手工标注，悬停时出标签；拖选几行弹出与行号栏相同的标注工具条。
// 识别结果来自规则统计（与正文生成同一套判断）；样式取本书已保存的排版设置。只看和标注，不改文字。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/layout_service.dart';
import '../../application/library_service.dart';
import '../../application/rule_catalog_service.dart';
import '../layout/device_preview.dart';
import '../layout/system_block_look.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'block_marks.dart';
import 'inline_style_marks.dart';

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
    unawaited(_readDevice());
    unawaited(_request());
  }
  final LibraryService library;
  final String bookId;
  final RuleCatalogService service;
  bool _disposed = false;

  /// 本书已保存的设置：系统提示方式与分类样式、诗词方式。
  String systemBlock = 'off', verseBlock = 'off';
  Map? systemStyles;

  /// 排版视图按真机画（V120，LAY-167）：机型与阅读器设置取真机预览里的选择，书内设置取本书。
  PreviewDeviceChoice device = const PreviewDeviceChoice();
  Map<String, Object?> book = const {};

  Future<void> _readDevice() async {
    try {
      final session = library.openLayout(bookId);
      try {
        if (session is LayoutPreviewDeviceStore) {
          final raw = await (session as LayoutPreviewDeviceStore)
              .readPreviewDevice();
          if (raw != null) device = PreviewDeviceChoice.decode(raw);
        }
      } finally {
        session.dispose();
      }
    } catch (_) {
      // 读不出时按默认机型画。
    }
    if (!_disposed) notifyListeners();
  }

  /// 书页参数：与排版页小预览同一套真机规则（字号、行距、版心、两端对齐），页边距以外的部分。
  KindleColumn column() {
    const page = Desk.light;
    double n(String key, double fallback) =>
        (book[key] as num?)?.toDouble() ?? fallback;
    final metrics = readerMetrics(
      device,
      bookScale:
          ((book['font_size_unit'] ?? 'px') == '%'
                  ? n('font_size', 110) / 110
                  : n('font_size', 18) / 17.6)
              .clamp(.3, 4.0),
      bookLineHeight: n('line_height', 1.2).clamp(1, 2.3),
    );
    final size = metrics.fontPx.clamp(6.0, 96.0);
    final face =
        (device.serif
                ? serif(size, c: page.ink, h: metrics.lineRatio)
                : ui(size, c: page.ink, h: metrics.lineRatio))
            .copyWith(letterSpacing: metrics.tracking * size);
    double margin(String side) =>
        (n('margin_$side', 0) *
                (book['margin_${side}_unit'] == 'em' ? size : 1))
            .clamp(0.0, 120.0);
    final fullwidth = n('fullwidth_indent', 0).clamp(0, 8).toInt();
    final align = book['text_alignment'] as String? ?? 'start';
    final style = PreviewStyle(
      title: face,
      body: face,
      align: switch (align) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        // 真机正文两端对齐（V118 实测）。
        _ => metrics.justify ? TextAlign.justify : TextAlign.start,
      },
      indent: (n('paragraph_indent', 0).clamp(0, 6) + fullwidth) * size,
      paragraphSpacing: n('paragraph_spacing', .6).clamp(0, 6) * size,
      titleSpacing: 20,
      padding: EdgeInsets.zero,
      sceneBreak: book['scene_break_style'] as String? ?? 'off',
      systemBlock: systemBlock,
      systemStyles: systemBlock == 'styled'
          ? (systemStyles ?? defaultSystemStyles())
          : null,
      verseBlock: verseBlock,
      ruleScale: size / 17.6,
    );
    return KindleColumn(
      style: style,
      viewport: device.device.viewportWidth.toDouble(),
      left: metrics.padding.left + margin('left'),
      right: metrics.padding.right + margin('right'),
      keepIndent: fullwidth == 0,
      removeBlank: book['remove_blank_lines'] != false,
      paper: page.paper,
    );
  }

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
        book = Map.of(saved);
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

/// 排版视图的书页（V120，LAY-167）：按所选机型的视口宽与真机规则排（视口像素），章节页再整体缩放到纸面宽；
/// 每行字数、分行与诗句位置同真机。[left]、[right] 为真机页边距加本书页边距；[style] 的页边距为零。
class KindleColumn {
  const KindleColumn({
    required this.style,
    required this.viewport,
    required this.left,
    required this.right,
    required this.keepIndent,
    required this.removeBlank,
    required this.paper,
  });
  final PreviewStyle style;
  final double viewport, left, right;

  /// 版心宽（视口像素）。
  double get width =>
      viewport - left - right < 40 ? 40 : viewport - left - right;

  /// 段首全角空格为 0 时保留原文段首空白；否则去掉后按缩进排。
  final bool keepIndent;

  /// 生成时去掉空行。
  final bool removeBlank;
  final Color paper;

  /// 一行正文在书里的样子：系统提示照分类样式分块，诗句居中或缩进，署名靠右；
  /// 书信、引文、场景等暂按不缩进的段落画。空行在生成时去掉的返回空。
  PreviewPiece? piece(
    String text, {
    LayoutLine? line,
    SystemRole? role,
    List<InlineStyleRange> styles = const [],
  }) {
    if (removeBlank && text.trim().isEmpty) return null;
    InlineSpan spans(String shown) => inlineStyledSpan(text, shown, styles);
    switch (line?.kind) {
      case null:
        return PreviewPiece(keepIndent ? text : text.trimLeft(), spans: spans);
      case 'system':
        final values = role == null ? null : style.systemStyles?[role.role];
        if (values is! Map) {
          return PreviewPiece(
            text.trimLeft(),
            indent: false,
            kind: 'system',
            spans: spans,
          );
        }
        final look = SystemBlockLook(
          values,
          style.body.fontSize ?? 16,
          style.ruleScale,
        );
        return PreviewPiece(
          look.removeBrackets || role!.heading
              ? stripSystemBrackets(text.trim())
              : text.trim(),
          indent: false,
          kind: 'system',
          role: role!.role,
          runStart: role.start,
          runEnd: role.end,
          heading: role.heading,
          spans: spans,
        );
      case 'verse':
        return PreviewPiece(
          text.trim(),
          indent: false,
          kind: line!.css == 'verse-by' ? 'by' : 'verse',
          spans: spans,
        );
      default:
        return PreviewPiece(text.trim(), indent: false, spans: spans);
    }
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
