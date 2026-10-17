// 本地崩溃日志（V22，SET-067）：程序未捕获的错误写入设置目录 crash-logs/，不上传，
// 最多保留 [CrashLog.limit] 份。写日志本身出错时静默放弃，不能让记录错误再引发错误。
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../application/crash_log_service.dart';

class CrashLog {
  CrashLog(this.directory, {this.limit = 50});
  final String directory;
  final int limit;
  static final _name = RegExp(r'^crash-\d{8}-\d{6}-\d{3}(?:-\d+)?\.txt$');

  String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}-${t.millisecond.toString().padLeft(3, '0')}';
  }

  /// 同步写入：出错后进程可能很快退出，异步写可能来不及。
  void record(Object error, StackTrace? stack, {required String source}) {
    try {
      final dir = Directory(directory)..createSync(recursive: true);
      final now = DateTime.now();
      var file = File('${dir.path}/crash-${_stamp(now)}.txt');
      for (var i = 1; file.existsSync() && i < 100; i++) {
        file = File('${dir.path}/crash-${_stamp(now)}-$i.txt');
      }
      var version = '开发版本（未打包）';
      final info = File(
        '${File(Platform.resolvedExecutable).parent.path}/version.json',
      );
      if (info.existsSync()) version = info.readAsStringSync().trim();
      file.writeAsStringSync(
        [
          'EasyPub++ 崩溃日志（只保存在本机，不会上传）',
          '时间：${now.toIso8601String()}',
          '来源：$source',
          '程序：${Platform.resolvedExecutable}',
          '版本：$version',
          '错误：$error',
          '调用栈：',
          '${stack ?? '（没有调用栈）'}',
        ].join('\n'),
        flush: true,
      );
      _prune(dir);
    } catch (_) {
      // 记录失败时放弃，不再抛出。
    }
  }

  void _prune(Directory dir) {
    final entries = list();
    for (final entry in entries.skip(limit)) {
      try {
        File(entry.path).deleteSync();
      } catch (_) {}
    }
  }

  /// 已有的日志，新的在前。
  List<CrashLogEntry> list() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    final result = <CrashLogEntry>[];
    for (final item in dir.listSync(followLinks: false)) {
      if (item is! File) continue;
      final name = item.uri.pathSegments.last;
      if (!_name.hasMatch(name)) continue;
      final stat = item.statSync();
      result.add(CrashLogEntry(item.path, stat.modified, stat.size));
    }
    result.sort((a, b) => b.path.compareTo(a.path));
    return result;
  }

  /// 接管 Flutter 框架错误与未捕获的异步错误；原有的处理（打印到控制台）保留。
  void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(
        details.exception,
        details.stack,
        source: 'Flutter 框架（${details.library ?? '未知'}）',
      );
      if (previous != null) previous(details);
    };
    final platform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, source: '未捕获的异步错误');
      return platform?.call(error, stack) ?? false;
    };
  }
}
