// 崩溃日志的只读接口（V22，SET-067），设置页用它显示份数与最近一份。

class CrashLogEntry {
  const CrashLogEntry(this.path, this.time, this.bytes);
  final String path;
  final DateTime time;
  final int bytes;
}

abstract interface class CrashLogService {
  /// 日志所在文件夹；没有设置目录时为 null。
  String? get crashLogDirectory;

  /// 已有的日志，新的在前。
  List<CrashLogEntry> crashLogs();

  /// 读取一份日志的全文；只读日志文件夹中的日志。
  Future<String> readCrashLog(CrashLogEntry entry);
}
