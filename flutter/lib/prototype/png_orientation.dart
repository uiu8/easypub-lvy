import 'dart:io';
import 'dart:typed_data';

/// Flutter's pinned PNG codec ignores eXIf. Read only the bounded TIFF orientation,
/// leaving JPEG/WebP orientation to their native codecs.
Future<int> pngOrientation(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final length = await file.length();
    if (length < 8 || length > 32 * 1024 * 1024) return 1;
    final signature = await file.read(8);
    if (signature.length != 8) return 1;
    const magic = [137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < 8; i++) {
      if (signature[i] != magic[i]) return 1;
    }
    var offset = 8;
    while (offset + 12 <= length) {
      await file.setPosition(offset);
      final header = await file.read(8);
      if (header.length != 8) return 1;
      final count = ByteData.sublistView(header).getUint32(0);
      if (count > length - offset - 12) return 1;
      final name = String.fromCharCodes(header.sublist(4));
      if (name == 'eXIf') {
        return await _readTiffOrientation(file, count);
      }
      if (name == 'IEND') return 1;
      offset += count + 12;
    }
  } on FileSystemException {
    return 1;
  } finally {
    await file?.close();
  }
  return 1;
}

Future<int> _readTiffOrientation(RandomAccessFile file, int length) async {
  if (length < 8) return 1;
  final start = await file.position();
  final header = await file.read(8);
  if (header.length != 8) return 1;
  final endian = header[0] == 73 && header[1] == 73
      ? Endian.little
      : header[0] == 77 && header[1] == 77
      ? Endian.big
      : null;
  if (endian == null) return 1;
  final data = ByteData.sublistView(header);
  if (data.getUint16(2, endian) != 42) return 1;
  final offset = data.getUint32(4, endian);
  if (offset < 8 || offset > length - 2) return 1;
  await file.setPosition(start + offset);
  final countBytes = await file.read(2);
  if (countBytes.length != 2) return 1;
  final count = ByteData.sublistView(countBytes).getUint16(0, endian);
  if (count > (length - offset - 2) ~/ 12) return 1;
  final entries = await file.read(count * 12);
  if (entries.length != count * 12) return 1;
  // Rebase the bounded first IFD; skip potentially large thumbnail/padding data.
  final compact = Uint8List(10 + entries.length)
    ..setRange(0, 8, header)
    ..setRange(8, 10, countBytes)
    ..setRange(10, 10 + entries.length, entries);
  ByteData.sublistView(compact).setUint32(4, 8, endian);
  return tiffOrientation(compact);
}

int tiffOrientation(Uint8List bytes) {
  if (bytes.length < 8) return 1;
  final endian = bytes[0] == 73 && bytes[1] == 73
      ? Endian.little
      : bytes[0] == 77 && bytes[1] == 77
      ? Endian.big
      : null;
  if (endian == null) return 1;
  final data = ByteData.sublistView(bytes);
  if (data.getUint16(2, endian) != 42) return 1;
  final offset = data.getUint32(4, endian);
  if (offset > bytes.length - 2) return 1;
  final count = data.getUint16(offset, endian);
  if (count > (bytes.length - offset - 2) ~/ 12) return 1;
  for (var i = 0; i < count; i++) {
    final entry = offset + 2 + i * 12;
    if (data.getUint16(entry, endian) != 0x112) continue;
    if (data.getUint16(entry + 2, endian) != 3 ||
        data.getUint32(entry + 4, endian) != 1) {
      return 1;
    }
    final value = data.getUint16(entry + 8, endian);
    return value >= 1 && value <= 8 ? value : 1;
  }
  return 1;
}

/// Same bounded TIFF parser, using the exact bytes sent to the image codec.
int pngOrientationBytes(Uint8List bytes) {
  const magic = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 8) return 1;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != magic[i]) return 1;
  }
  final data = ByteData.sublistView(bytes);
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final count = data.getUint32(offset);
    if (count > bytes.length - offset - 12) return 1;
    final name = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (name == 'eXIf') {
      return tiffOrientation(
        Uint8List.sublistView(bytes, offset + 8, offset + 8 + count),
      );
    }
    if (name == 'IEND') return 1;
    offset += count + 12;
  }
  return 1;
}
