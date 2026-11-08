// 应用版本与本版更新（V22，SET-066）：读取发布包中的 version.json 与“先读我.txt”。
import 'dart:convert';
import 'dart:io';

class AppInfo {
  const AppInfo({
    required this.packaged,
    this.version = '',
    this.date = '',
    this.commit = '',
    this.uncommittedChanges = false,
    this.releaseNotes = const [],
    this.notesText = '',
    this.notesName = '',
  });

  /// 从发布包运行（找到了 version.json）。为 false 时是直接从源码运行的开发版本。
  final bool packaged;
  final String version, date, commit;

  /// 打包时工作区有未提交的改动。
  final bool uncommittedChanges;

  /// “本版新增 / 本版内容”一节的各行。
  final List<String> releaseNotes;

  /// 说明文件全文与文件名，供“查看完整说明”。
  final String notesText, notesName;
}

/// 从说明文本中取出“本版……”一节：从以“本版”开头的行起，到“所有修改仍然遵循”之前。
List<String> releaseNotesFrom(String text) {
  final lines = const LineSplitter().convert(text);
  final start = lines.indexWhere((l) => l.startsWith('本版'));
  if (start < 0) return const [];
  final result = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.startsWith('所有修改仍然遵循')) break;
    result.add(line);
  }
  while (result.isNotEmpty && result.last.trim().isEmpty) {
    result.removeLast();
  }
  while (result.isNotEmpty && result.first.trim().isEmpty) {
    result.removeAt(0);
  }
  return List.unmodifiable(result);
}

/// 读取 [directory]（默认是程序所在目录）中的版本信息；读不到时视为开发版本。
Future<AppInfo> loadAppInfo([String? directory]) async {
  final dir = directory ?? File(Platform.resolvedExecutable).parent.path;
  try {
    final file = File('$dir/version.json');
    if (!await file.exists()) return const AppInfo(packaged: false);
    final value = jsonDecode(await file.readAsString()) as Map;
    final notesName = value['notes'] as String? ?? '';
    var notesText = '';
    if (notesName.isNotEmpty && !notesName.contains(RegExp(r'[\\/]'))) {
      final notes = File('$dir/$notesName');
      if (await notes.exists() && await notes.length() < 262144) {
        notesText = await notes.readAsString();
      }
    }
    return AppInfo(
      packaged: true,
      version: value['version'] as String? ?? '',
      date: value['date'] as String? ?? '',
      commit: value['commit'] as String? ?? '',
      uncommittedChanges: value['uncommitted_changes'] == true,
      releaseNotes: releaseNotesFrom(notesText),
      notesText: notesText,
      notesName: notesName,
    );
  } catch (_) {
    // 版本文件损坏时按开发版本显示，不影响使用。
    return const AppInfo(packaged: false);
  }
}
