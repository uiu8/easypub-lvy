import 'dart:io';

/// 开发探针的累计计时；不开启环境变量时不创建计时器，也不记录路径或正文。
class ImportProfile {
  static final enabled = Platform.environment['EASYPUB_IMPORT_PROFILE'] == '1';
  static final _micros = <String, int>{};
  static final _calls = <String, int>{};
  static final rows = <Map<String, Object>>[];

  static T measure<T>(String name, T Function() operation) {
    if (!enabled) return operation();
    final watch = Stopwatch()..start();
    try {
      return operation();
    } finally {
      _record(name, watch.elapsedMicroseconds);
    }
  }

  static Future<T> measureAsync<T>(
    String name,
    Future<T> Function() operation,
  ) async {
    if (!enabled) return operation();
    final watch = Stopwatch()..start();
    try {
      return await operation();
    } finally {
      _record(name, watch.elapsedMicroseconds);
    }
  }

  static void _record(String name, int micros) {
    _micros.update(name, (value) => value + micros, ifAbsent: () => micros);
    _calls.update(name, (value) => value + 1, ifAbsent: () => 1);
  }

  static Map<String, Object> snapshot() => {
    'microseconds': Map<String, int>.of(_micros),
    'calls': Map<String, int>.of(_calls),
  };

  static void book(int count) {
    if (enabled) rows.add({'books': count, ...snapshot()});
  }
}
