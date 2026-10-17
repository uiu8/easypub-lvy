// 清理前后只标出改动的那一段（CLEAN-100）：共同的开头和结尾不着色；
// 改动的那一段全是空白（例如行尾空格）时自动加空白标记，否则前后两栏看起来完全一样。
// 段首的全角缩进等没有改动的空白不加标记，除非用户打开了“显示空白标记”。
import 'package:flutter/painting.dart';

/// 前后两段文字共同开头与共同结尾的长度（UTF-16 单位，不拆开代理对）。
({int prefix, int suffix}) commonEnds(String a, String b) {
  final limit = a.length < b.length ? a.length : b.length;
  var prefix = 0;
  while (prefix < limit && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
    prefix++;
  }
  if (prefix > 0 && prefix < limit && _high(a.codeUnitAt(prefix - 1))) {
    prefix--;
  }
  var suffix = 0;
  while (suffix < limit - prefix &&
      a.codeUnitAt(a.length - 1 - suffix) ==
          b.codeUnitAt(b.length - 1 - suffix)) {
    suffix++;
  }
  if (suffix > 0 &&
      suffix < limit - prefix &&
      _low(a.codeUnitAt(a.length - suffix))) {
    suffix--;
  }
  return (prefix: prefix, suffix: suffix);
}

bool _high(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _low(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// 空白标记：空格 ·，全角空格 □，制表符 ⇥，换行 ↵。
String markWhitespace(String text) => text
    .replaceAll(' ', '·')
    .replaceAll('　', '□')
    .replaceAll('\t', '⇥')
    .replaceAll('\n', '↵\n');

/// [text] 相对 [other] 的行内差异：相同部分用 [base]，不同部分用 [changed]。
/// [marks] 为 true 时显示空白标记。
TextSpan inlineDiffSpan(
  String text,
  String other, {
  required TextStyle base,
  required TextStyle changed,
  bool marks = false,
}) {
  String show(String s) => marks ? markWhitespace(s) : s;
  final ends = commonEnds(text, other);
  final middleEnd = text.length - ends.suffix;
  final head = text.substring(0, ends.prefix);
  final middle = text.substring(ends.prefix, middleEnd);
  final tail = text.substring(middleEnd);
  return TextSpan(
    style: base,
    children: [
      if (head.isNotEmpty) TextSpan(text: show(head)),
      // 删去的是行尾空白这类看不见的字符时，标记出来才能看出改了什么。
      if (middle.isNotEmpty)
        TextSpan(
          text: middle.trim().isEmpty ? markWhitespace(middle) : show(middle),
          style: changed,
        ),
      if (tail.isNotEmpty) TextSpan(text: show(tail)),
    ],
  );
}
