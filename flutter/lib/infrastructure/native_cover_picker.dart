import 'package:file_selector/file_selector.dart';

Future<String?> pickCoverImage() async => (await openFile(
  acceptedTypeGroups: [
    const XTypeGroup(
      label: '封面图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    ),
  ],
))?.path;
