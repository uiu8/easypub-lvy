import 'package:file_selector/file_selector.dart';

import 'css_file_reader.dart';

Future<({String text, String base})?> importCssFile() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(label: 'CSS', extensions: ['css']),
    ],
  );
  return file == null ? null : readCssFile(file.path);
}

const _presetType = XTypeGroup(label: 'EasyPub++ 排版预设', extensions: ['json']);
Future<String?> pickPresetFile() async =>
    (await openFile(acceptedTypeGroups: [_presetType]))?.path;
Future<String?> pickPresetDestination() async => (await getSaveLocation(
  suggestedName: '排版预设.json',
  acceptedTypeGroups: [_presetType],
))?.path;

// 章节样式包（V74，LAY-130）。
const _stylePackType = XTypeGroup(
  label: 'EasyPub++ 章节样式包',
  extensions: ['zip'],
);
Future<String?> pickStylePackFile() async =>
    (await openFile(acceptedTypeGroups: [_stylePackType]))?.path;

/// 样式包文件夹（V114）：含 style.json，或按文件名放章头图、装饰线与封面背景。
Future<String?> pickStylePackFolder() async =>
    getDirectoryPath(confirmButtonText: '导入这个文件夹');
Future<String?> pickStylePackDestination(String name) async =>
    (await getSaveLocation(
      suggestedName: '$name.zip',
      acceptedTypeGroups: [_stylePackType],
    ))?.path;
