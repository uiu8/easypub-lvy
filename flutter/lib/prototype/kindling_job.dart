import 'dart:convert';

import '../src/rust/api.dart' as api;
import 'conversion_error.dart';

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

  /// 查询状态的间隔（R6）：先密后疏。小书几毫秒就转完，固定 100ms 会让每本白等一轮；
  /// 长任务很快退到 100ms，查询次数与原来相当。
  static const pollDelays = [5, 10, 20, 40, 80];

  Future<Map<String, dynamic>> run(Map<String, dynamic> request) async {
    final start = await call({'op': startOperation, 'request': request});
    id = start['job_id'] as int;
    if (_cancelOnStart) await cancel();
    var polls = 0;
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
          final detail = conversionFailureMessage(status['error'] as Map);
          throw ExportStopped(
            '$detail${status['conversion_directory'] == null ? '' : '\n转换记录：${status['conversion_directory']}'}',
          );
        }
        return (status['result'] as Map).cast<String, dynamic>();
      }
      await Future<void>.delayed(
        Duration(
          milliseconds: polls < pollDelays.length ? pollDelays[polls++] : 100,
        ),
      );
    }
  }
}
