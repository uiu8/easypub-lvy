/// Scalar-boundary mapping for one decoded source line/page fragment.
/// Offsets are local to [text], never original-file bytes or grapheme indices.
class SourceCoordinates {
  SourceCoordinates(this.text) {
    var bytes = 0;
    var units = 0;
    _utf16ToUtf8[0] = 0;
    _utf8ToUtf16[0] = 0;
    while (units < text.length) {
      final first = text.codeUnitAt(units);
      var scalar = first;
      var width = 1;
      if (first >= 0xd800 && first <= 0xdbff) {
        if (units + 1 >= text.length) {
          throw const FormatException('Unpaired surrogate');
        }
        final second = text.codeUnitAt(units + 1);
        if (second < 0xdc00 || second > 0xdfff) {
          throw const FormatException('Unpaired surrogate');
        }
        scalar = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00;
        width = 2;
      } else if (first >= 0xdc00 && first <= 0xdfff) {
        throw const FormatException('Unpaired surrogate');
      }
      bytes += scalar < 0x80
          ? 1
          : scalar < 0x800
          ? 2
          : scalar < 0x10000
          ? 3
          : 4;
      units += width;
      _utf16ToUtf8[units] = bytes;
      _utf8ToUtf16[bytes] = units;
    }
  }

  final String text;
  final Map<int, int> _utf16ToUtf8 = {};
  final Map<int, int> _utf8ToUtf16 = {};

  int toUtf8(int utf16Offset) =>
      _utf16ToUtf8[utf16Offset] ??
      (throw RangeError(
        'UTF-16 offset is outside text or splits a surrogate pair',
      ));

  int toUtf16(int utf8Offset) =>
      _utf8ToUtf16[utf8Offset] ??
      (throw RangeError('UTF-8 offset is outside text or splits a scalar'));
}
