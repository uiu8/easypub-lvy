import 'dart:convert';
import 'dart:io';

Future<({String text, String base})> readCssFile(String path) async {
  final file = await File(path).open();
  try {
    final bytes = await file.read(262148);
    final offset =
        bytes.length >= 3 &&
            bytes[0] == 239 &&
            bytes[1] == 187 &&
            bytes[2] == 191
        ? 3
        : 0;
    if (bytes.length - offset > 262144) {
      throw const FormatException('CSS 文件超过 256 KiB。');
    }
    final text = utf8.decode(bytes.sublist(offset));
    if (text.contains('\u0000')) {
      throw const FormatException('CSS 文件不能含空字符。');
    }
    return (text: text, base: File(path).absolute.parent.path);
  } finally {
    await file.close();
  }
}
