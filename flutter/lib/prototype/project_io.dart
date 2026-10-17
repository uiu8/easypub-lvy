import 'dart:convert';

import '../src/rust/api.dart';

typedef SaveProject = Future<void> Function(
  String path,
  Map<String, dynamic> project,
);
typedef OpenProject = Future<Map<String, dynamic>> Function(String path);

Map<String, dynamic> _decode(String raw) {
  final value = jsonDecode(raw) as Map<String, dynamic>;
  if (value.containsKey('error')) {
    throw FormatException(switch (value['error']) {
      'SourceChanged' => '原稿已在外部修改，项目未打开。请重新导入变化后的书稿。',
      'NotFound' => '找不到项目引用的原稿，当前书库保持不变。',
      'OutputConflict' => '此项目文件已存在，请另选新文件名。',
      'InvalidRule' => '项目格式或字段不受支持，请选择本版本保存的项目。',
      'UnsupportedRule' => '项目中的规则或词典版本不受支持，当前书库保持不变。',
      'TooLarge' => '项目超出当前会话容量，请减少书稿数量。',
      'Busy' => '还有任务正在运行，请稍后再试。',
      _ => '无法读写项目，请检查路径、目录权限和磁盘文件系统。',
    });
  }
  return value;
}

Future<void> saveProject(String path, Map<String, dynamic> project) async {
  _decode(await saveProjectText(path: path, payload: jsonEncode(project)));
}

/// Recovery saves include resident source bytes, even when the external file
/// has already changed. They do not change the active project's save identity.
Future<void> saveRecoveryProject(
  String path,
  Map<String, dynamic> project,
) async {
  _decode(
    await saveRecoveryProjectText(path: path, payload: jsonEncode(project)),
  );
}

Future<Map<String, dynamic>> openProject(String path) async =>
    _decode(await openProjectText(path: path));
