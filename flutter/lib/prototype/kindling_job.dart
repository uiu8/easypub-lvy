import 'dart:convert';

import '../src/rust/api.dart' as api;
import 'conversion_error.dart';

typedef JobCall = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> request,
);

/// 订阅后端推送的任务状态（桥接第 1 批）。每条与 `{"op":"status"}` 的回答相同。
typedef JobWatch = Stream<Map<String, dynamic>> Function(int jobId);

class ExportStopped implements Exception {
  const ExportStopped(this.message);
  final String message;
}

/// Owns the backend handle independently of any dialog. Poll failures never
/// restart a task or infer termination; only a backend terminal response does.
///
/// 桥接第 1 批起，状态由后端主动推送（[watch]）；推送断开时退回原来的查询方式继续，
/// 不会重启任务。测试注入 [call] 而不给 [watch] 时只用查询。
class KindlingJob {
  KindlingJob({
    required this.onChanged,
    JobCall? call,
    JobWatch? watch,
    this.startOperation = 'start',
  }) : call = call ?? _call,
       watch = watch ?? (call == null ? _watch : null);
  final String startOperation;
  final void Function() onChanged;
  final JobCall call;
  final JobWatch? watch;
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

  /// 桥接第 2 批：推送的是有类型的状态，这里换成与查询相同的字段，后面的处理不变。
  static Stream<Map<String, dynamic>> _watch(int jobId) =>
      api.kindlingJobWatch(jobId: jobId).map(statusFields);

  static Map<String, dynamic> statusFields(api.KindlingJobStatus status) => {
    'phase': status.phase,
    'terminal': status.terminal,
    'cancellable': status.cancellable,
    'cancel_requested': status.cancelRequested,
    if (status.resultJson case final String result)
      'result': jsonDecode(result),
    if (status.failure case final api.JobFailure failure)
      'error': {
        'code': failure.code,
        'operation': failure.operation,
        'next_action': failure.nextAction,
      },
  };

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

  /// 跟随后端推送直到终态。推送不可用或中途断开时返回 null，由调用方改用查询。
  Future<Map<String, dynamic>?> _follow() async {
    final watch = this.watch;
    final jobId = id;
    if (watch == null || jobId == null) return null;
    try {
      await for (final status in watch(jobId)) {
        final result = await _apply(status);
        if (result != null) return result;
      }
    } on ExportStopped {
      rethrow;
    } catch (_) {
      // 已到终态（任务已释放）时不能退回查询。
      if (terminal) rethrow;
      // 推送出错：任务仍在后端运行，退回查询。
    }
    return null;
  }

  /// 查询状态的间隔（R6）：先密后疏。小书几毫秒就转完，固定 100ms 会让每本白等一轮；
  /// 长任务很快退到 100ms，查询次数与原来相当。
  static const pollDelays = [5, 10, 20, 40, 80];

  /// 收到一条状态。到终态时释放任务并返回结果（或抛出），否则返回 null。
  Future<Map<String, dynamic>?> _apply(Map<String, dynamic> status) async {
    statusAvailable = true;
    phase = status['phase'] as String? ?? 'preparing';
    cancellable = status['cancellable'] == true;
    message = '';
    terminal = status['terminal'] == true;
    _notifyIfChanged();
    if (!terminal) return null;
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

  Future<Map<String, dynamic>> run(Map<String, dynamic> request) async {
    final start = await call({'op': startOperation, 'request': request});
    id = start['job_id'] as int;
    if (_cancelOnStart) await cancel();
    final pushed = await _follow();
    if (pushed != null) return pushed;
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
      final result = await _apply(status);
      if (result != null) return result;
      await Future<void>.delayed(
        Duration(
          milliseconds: polls < pollDelays.length ? pollDelays[polls++] : 100,
        ),
      );
    }
  }
}
