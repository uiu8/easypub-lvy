import 'dart:convert';

import 'package:easypub_desktop/source_coordinates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'CJK, astral characters and combining marks retain exact boundaries',
    () {
      const text = 'A中😀𠮷e\u0301';
      final map = SourceCoordinates(text);
      const boundaries = {0: 0, 1: 1, 2: 4, 4: 8, 6: 12, 7: 13, 8: 15};
      for (final entry in boundaries.entries) {
        expect(map.toUtf8(entry.key), entry.value);
        expect(map.toUtf16(entry.value), entry.key);
        expect(
          utf8.decode(utf8.encode(text).sublist(entry.value)),
          text.substring(entry.key),
        );
      }
      for (final offset in [-1, 3, 5, 9]) {
        expect(() => map.toUtf8(offset), throwsRangeError);
      }
      for (final offset in [-1, 2, 3, 5, 6, 7, 9, 10, 11, 14, 16]) {
        expect(() => map.toUtf16(offset), throwsRangeError);
      }
    },
  );
  test('empty text and malformed UTF-16 have explicit behavior', () {
    expect(SourceCoordinates('').toUtf8(0), 0);
    expect(SourceCoordinates('').toUtf16(0), 0);
    expect(
      () => SourceCoordinates(String.fromCharCode(0xd800)),
      throwsFormatException,
    );
    expect(
      () => SourceCoordinates(String.fromCharCode(0xdc00)),
      throwsFormatException,
    );
  });
}
