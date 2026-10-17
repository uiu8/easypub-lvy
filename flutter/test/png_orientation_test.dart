import 'dart:typed_data';

import 'package:easypub_desktop/prototype/png_orientation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TIFF orientation validates endian types offsets and values', () {
    for (final endian in [Endian.little, Endian.big]) {
      for (var orientation = 1; orientation <= 8; orientation++) {
        final bytes = Uint8List(26), data = ByteData(26);
        bytes[0] = bytes[1] = endian == Endian.little ? 73 : 77;
        data.setUint16(2, 42, endian);
        data.setUint32(4, 8, endian);
        data.setUint16(8, 1, endian);
        data.setUint16(10, 0x112, endian);
        data.setUint16(12, 3, endian);
        data.setUint32(14, 1, endian);
        data.setUint16(18, orientation, endian);
        bytes.setRange(2, 26, data.buffer.asUint8List().sublist(2));
        expect(tiffOrientation(bytes), orientation);
        for (var n = 0; n < 22; n++) {
          expect(tiffOrientation(Uint8List.sublistView(bytes, 0, n)), 1);
        }
        final invalidType = Uint8List.fromList(bytes);
        ByteData.sublistView(invalidType).setUint16(12, 2, endian);
        expect(tiffOrientation(invalidType), 1);
        final invalidValue = Uint8List.fromList(bytes);
        ByteData.sublistView(invalidValue).setUint16(18, 9, endian);
        expect(tiffOrientation(invalidValue), 1);
        ByteData.sublistView(bytes).setUint32(4, 0xffffffff, endian);
        expect(tiffOrientation(bytes), 1);
      }
    }
  });
}
