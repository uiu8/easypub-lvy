import 'package:file_selector/file_selector.dart';

Future<String?> pickCatalogFile() async => (await openFile(
  acceptedTypeGroups: [
    const XTypeGroup(label: '参考目录', extensions: ['txt', 'html', 'htm']),
  ],
))?.path;

/// V45（CH-271）：“阅读”App 书源 JSON。
Future<String?> pickBookSourceFile() async => (await openFile(
  acceptedTypeGroups: [
    const XTypeGroup(label: '阅读书源', extensions: ['json', 'txt']),
  ],
))?.path;
