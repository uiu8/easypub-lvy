// 启动分段计时：只有设了环境变量 EASYPUB_STARTUP_PROFILE 时才把结果写进那个文件；
// 平时只记几个整数，不影响启动。
import 'dart:convert';
import 'dart:io';

final startupWatch = Stopwatch()..start();
final startupMarks = <String, int>{};

/// 记录 [body] 的耗时（同名多次累加）。
Future<T> startupTimed<T>(String name, Future<T> Function() body) async {
  final from = startupWatch.elapsedMilliseconds;
  try {
    return await body();
  } finally {
    startupMarks[name] =
        (startupMarks[name] ?? 0) + startupWatch.elapsedMilliseconds - from;
  }
}

T startupTimedSync<T>(String name, T Function() body) {
  final from = startupWatch.elapsedMilliseconds;
  try {
    return body();
  } finally {
    startupMarks[name] =
        (startupMarks[name] ?? 0) + startupWatch.elapsedMilliseconds - from;
  }
}

void startupMark(String name) =>
    startupMarks[name] = startupWatch.elapsedMilliseconds;

void writeStartupProfile() {
  final path = Platform.environment['EASYPUB_STARTUP_PROFILE'];
  if (path == null || path.isEmpty) return;
  try {
    File(path).writeAsStringSync(jsonEncode(startupMarks));
  } catch (_) {}
}
