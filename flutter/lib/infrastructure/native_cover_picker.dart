import 'package:file_selector/file_selector.dart';

Future<String?> pickCoverImage() async => (await openFile(
  acceptedTypeGroups: [
    const XTypeGroup(
      label: '封面图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    ),
  ],
))?.path;

/// 嵌入字体的字体文件（V123，LAY-179）。
Future<String?> pickFontFile() async => (await openFile(
  acceptedTypeGroups: [
    const XTypeGroup(label: '字体文件', extensions: ['ttf', 'otf', 'ttc']),
  ],
))?.path;
