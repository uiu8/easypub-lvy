import 'kindling_job.dart';

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

/// An actual export attempt, identified by the source snapshot at confirmation.
/// Preview requests are not output tasks; completion is recorded only on receipt.
class OutputTask {
  OutputTask({
    required this.bookId,
    required this.title,
    required this.sourceId,
    required this.revision,
    required this.format,
    required this.outputPath,
    String? taskId,
    DateTime? startedAt,
    this.batchId,
    this.batchIndex,
    this.batchTotal,
    this.checksEnabled,
  }) : taskId =
           taskId ??
           '${pid.toRadixString(16)}-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${_next++}',
       startedAt = startedAt ?? DateTime.now();
  static int _next = 0;
  final String taskId;
  final String bookId, title, sourceId, format, outputPath;
  final int revision;
  final String? batchId;
  final int? batchIndex, batchTotal;
  final bool? checksEnabled;
  Uint8List? coverThumbnail;
  final DateTime startedAt;
  bool restored = false;
  bool verifying = false;
  bool recoveryPreviewOpen = false;
  String verification = '';
  String verificationCode = '';
  DateTime? finishedAt;
  String phase = 'preparing';
  String detail = '';
  Map<String, dynamic>? receipt;
  KindlingJob? job;
  bool get terminal => restored || finishedAt != null;
  Map<String, dynamic> toRecord() => {
    'schema': 1,
    'task_id': taskId,
    'sequence': terminal ? 2 : 1,
    'book_id': bookId,
    'title': title,
    'source_id': sourceId,
    'source_revision': revision,
    'format': format,
    'output_path': outputPath,
    'started_at': startedAt.toUtc().toIso8601String(),
    'finished_at': finishedAt?.toUtc().toIso8601String(),
    'phase': phase,
    'detail': detail,
    'receipt': receipt,
    if (batchId != null) 'batch_id': batchId,
    if (batchIndex != null) 'batch_index': batchIndex,
    if (batchTotal != null) 'batch_total': batchTotal,
    if (checksEnabled != null) 'checks_enabled': checksEnabled,
    if (coverThumbnail != null)
      'cover_thumbnail': base64Encode(coverThumbnail!),
  };
  factory OutputTask.fromRecord(Map<String, dynamic> record) {
    final task = OutputTask(
      bookId: record['book_id'] as String,
      title: record['title'] as String,
      sourceId: record['source_id'] as String,
      revision: record['source_revision'] as int,
      format: record['format'] as String,
      outputPath: record['output_path'] as String,
      taskId: record['task_id'] as String,
      startedAt: DateTime.parse(record['started_at'] as String),
      batchId: record['batch_id'] as String?,
      batchIndex: record['batch_index'] as int?,
      batchTotal: record['batch_total'] as int?,
      checksEnabled: record['checks_enabled'] as bool?,
    );
    final thumbnail = record['cover_thumbnail'] as String?;
    task.coverThumbnail = thumbnail == null ? null : base64Decode(thumbnail);
    task.restored = true;
    task.finishedAt = record['finished_at'] == null
        ? null
        : DateTime.parse(record['finished_at'] as String);
    task.phase = task.finishedAt == null
        ? 'interrupted'
        : record['phase'] as String;
    task.detail = task.finishedAt == null
        ? '上次运行未记录最终结果，请核对成品及事务记录；不会自动重启或覆盖输出。'
        : '上次运行记录：${record['detail']}\n本次启动尚未重新核验成品。';
    task.receipt = (record['receipt'] as Map?)?.cast<String, dynamic>();
    return task;
  }
  String get label =>
      const {
        'preparing': '准备中',
        'prepared': '已准备',
        'converting': '转换中',
        'checking': '核对结果',
        'publishing': '保存中',
        'complete': '已完成',
        'cancelled': '已取消',
        'failed': '失败',
        'interrupted': '中断待核对',
      }[phase] ??
      '处理中';
}
