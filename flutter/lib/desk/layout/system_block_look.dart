// 系统提示分类样式在小预览里的画法（V104，LAY-146）：数值与 Rust `block_styles` 生成的 CSS 相同，
// 括号、键名、面板标题的判断与 Rust `strip_brackets`、`mark_key`、`is_title`、`is_ding_line` 一致。
import 'package:flutter/painting.dart';

/// 一类系统提示（单行 note / 面板 panel）的样式参数换算成预览像素。
class SystemBlockLook {
  SystemBlockLook(Map style, this.em, this.px)
    : border = '${style['border'] ?? 'none'}',
      doubleLine = style['line'] == 'double',
      thick = style['line'] == 'double' || style['weight'] == 'thick',
      shade = switch (style['shade']) {
        'light' => const Color(0xFFECECEC),
        'medium' => const Color(0xFFDCDCDC),
        _ => null,
      },
      center = style['align'] == 'center',
      bold = style['bold'] == true,
      keyBold = style['key_bold'] == true,
      removeBrackets = style['brackets'] == 'remove',
      title = '${style['title'] ?? 'none'}',
      size = ((style['size'] as num?) ?? 100) / 100,
      spacing = '${style['spacing'] ?? 'medium'}',
      gray = style['tone'] == 'gray',
      kai = style['font'] == 'kai',
      inset = '${style['inset'] ?? 'none'}',
      radius = style['radius'] == true;

  /// 正文字号（1em）与 1 个 CSS 像素在预览里的大小。
  final double em, px;
  final String border, title, spacing;
  final bool doubleLine, thick, center, bold, keyBold, removeBrackets;

  /// V119：灰色线、楷体、块缩进（none / small / large / narrow）、圆角。
  final bool gray, kai, radius;
  final String inset;

  /// 线的颜色：灰色时与成品 CSS 的 #888888 相同；否则随正文。
  Color lineColor(Color ink) => gray ? const Color(0xFF888888) : ink;

  /// 块左右的缩进（预览像素）：左缩按块的字号算 em，“左右各收”按版心宽的 12%。
  double insetLeft(double width) => switch (inset) {
    'small' => fontEm,
    'large' => 2 * fontEm,
    'narrow' => .12 * width,
    _ => 0,
  };
  double insetRight(double width) => inset == 'narrow' ? .12 * width : 0;
  final Color? shade;
  final double size;

  bool get boxed => border != 'none' || shade != null;

  /// 边框线宽（CSS 1px 或 3px，至少 1 个预览像素）。
  double get rule => (thick ? 3 : 1) * px < 1 ? 1 : (thick ? 3 : 1) * px;
  double get left => border == 'left' || border == 'full' ? rule : 0;
  double get right => border == 'full' ? rule : 0;
  double get top => border == 'full' || border == 'top_bottom' ? rule : 0;
  double get bottom => top;

  /// 字号按本类的百分比缩放后的 1em。
  double get fontEm => em * size;

  /// 块的上下外边距、上下内边距、行的左右内边距（CSS 里按块的字号算 em）。
  double get margin =>
      switch (spacing) {
        'tight' => .4,
        'loose' => 1.2,
        _ => .8,
      } *
      fontEm;
  double get pad => boxed ? .3 * fontEm : 0;
  double get side => boxed ? .6 * fontEm : 0;

  /// 面板标题行的上下内边距与下方间距。
  double get titlePad => title == 'shaded' ? .15 * fontEm : 0;
  double get titleGap =>
      title == 'shaded' || title == 'underline' ? .2 * fontEm : 0;

  /// 标题行下的线：标题下划线为 1px；全框的底色标题沿用边框线。
  double get titleRule => title == 'underline'
      ? (px < 1 ? 1 : px)
      : title == 'shaded' && border == 'full'
      ? rule
      : 0;
}

/// 去掉整行外层的【】（多段时换成全角空格）；不是整行【】时原样返回。
String stripSystemBrackets(String text) {
  final t = text.trim();
  if (!t.startsWith('【') || !t.endsWith('】')) return text;
  final body = t.substring(1, t.length - 1);
  return [
    for (final part in body.split('】'))
      part.trimLeft().replaceFirst(RegExp('^【+'), ''),
  ].join('　');
}

/// “键：值”里冒号的位置：冒号在前 12 个字以内、键名里没有标签与标点；不是键值时为空。
int? systemKeyEnd(String text) {
  final runes = text.runes.take(13).toList();
  final at = runes.indexWhere((r) => r == 0xFF1A || r == 0x3A);
  if (at <= 0) return null;
  final key = String.fromCharCodes(runes.take(at));
  if (key.trim().isEmpty || RegExp('[<>&，。！？“”]').hasMatch(key)) return null;
  return key.length;
}

/// 面板首行能否作标题：去括号后不超过 16 字且不含冒号。
bool isSystemTitle(String text) {
  final t = stripSystemBrackets(text);
  return t.runes.length <= 16 && !t.contains(RegExp('[：:]'));
}

/// 单独一行的“叮！”“叮~”“叮咚！”：分类样式下并入紧跟的系统提示。
bool isDingLine(String line) {
  final t = line.trim();
  final rest = t.startsWith('叮咚')
      ? t.substring(2)
      : t.startsWith('叮')
      ? t.substring(1)
      : null;
  return rest != null &&
      rest.runes.length <= 2 &&
      rest.runes.every((r) => '！!～~，,。…'.runes.contains(r));
}
