import 'dart:convert';

import '../src/rust/api.dart' as api;

typedef JobCall = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> request,
);

class ExportStopped implements Exception {
  const ExportStopped(this.message);
  final String message;
}

/// Owns the backend handle independently of any dialog. Poll failures never
/// restart a task or infer termination; only a backend terminal response does.
class KindlingJob {
  KindlingJob({
    required this.onChanged,
    JobCall? call,
    this.startOperation = 'start',
  }) : call = call ?? _call;
  final String startOperation;
  final void Function() onChanged;
  final JobCall call;
  int? id;
  bool _cancelOnStart = false;
  String? _lastNotificationKey;
  bool cancellable = false, cancelRequested = false, terminal = false;
  String phase = 'preparing', message = '';
  bool statusAvailable = true;
  static Future<Map<String, dynamic>> _call(
    Map<String, dynamic> request,
  ) async => (jsonDecode(
    await api.kindlingJobText(requestJson: jsonEncode(request)),
  ) as Map).cast<String, dynamic>();

  void _notifyIfChanged() {
    final key = [
      phase,
      message,
      statusAvailable,
      cancellable,
      cancelRequested,
      terminal,
    ].join('\u0000');
    if (key == _lastNotificationKey) return;
    _lastNotificationKey = key;
    onChanged();
  }

  Future<void> cancel() async {
    if (terminal || cancelRequested) return;
    if (id == null) {
      _cancelOnStart = true;
      return;
    }
    try {
      final result = await call({'op': 'cancel', 'job_id': id});
      cancelRequested = result['accepted'] == true;
      message = cancelRequested ? '正在取消，等待当前处理停止…' : '正在完成保存，请等待结果。';
    } catch (_) {
      message = '取消请求未送达，请重试。';
    }
    _notifyIfChanged();
  }

  Future<Map<String, dynamic>> run(Map<String, dynamic> request) async {
    final start = await call({'op': startOperation, 'request': request});
    id = start['job_id'] as int;
    if (_cancelOnStart) await cancel();
    while (true) {
      Map<String, dynamic> status;
      try {
        status = await call({'op': 'status', 'job_id': id});
      } catch (_) {
        statusAvailable = false;
        message = '任务状态暂时无法获取，正在重新连接…';
        _notifyIfChanged();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      statusAvailable = true;
      phase = status['phase'] as String? ?? 'preparing';
      cancellable = status['cancellable'] == true;
      message = '';
      terminal = status['terminal'] == true;
      _notifyIfChanged();
      if (terminal) {
        final finishedId = id;
        id = null;
        try {
          await call({'op': 'forget', 'job_id': finishedId});
        } catch (_) {}
        if (phase == 'cancelled') throw const ExportStopped('已取消，没有生成最终文件。');
        if (status['error'] != null) {
          final action = (status['error'] as Map)['next_action'];
          final detail = switch (action) {
            'choose_cover_before_kindling_export' => '请先为本书选择封面。',
            'choose_publication_language' =>
              '请先在本书制作信息中填写语言（如 zh、zh-CN 或 en），再重新预览。',
            'engine_failed_review_log' => '转换器未能完成，请查看转换目录中的日志。',
            'kfx_validation_failed_review_log' =>
              'KFX 与原 EPUB 的内容或排版校验未通过，未提交成品。请查看转换目录中的 validation.log。',
            'engine_metadata_mismatch' =>
              '转换结果丢失或改变了书目信息，已停止保存。请使用配套修订版转换器后重试。',
            'reopen_preview' => '书稿、资源或转换器已变化，请重新预览。',
            _ => '导出失败，请检查原稿、资源、转换器及输出路径。',
          };
          throw ExportStopped(
            '$detail${status['conversion_directory'] == null ? '' : '\n转换记录：${status['conversion_directory']}'}',
          );
        }
        return (status['result'] as Map).cast<String, dynamic>();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
