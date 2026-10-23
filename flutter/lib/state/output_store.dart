// 转换任务与输出记录（V20 从 PrototypeState 拆出，原 outputTasks、outputBatchRecords 等）。
// 只通过 PrototypeState 的公开接口读写书库与全局设置；行为与拆分前相同。
import 'dart:async';
import 'dart:convert';

import '../prototype/kindling_job.dart';
import '../prototype/conversion_error.dart';
import '../prototype/output_task.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class OutputStore {
  OutputStore(this._core);
  final PrototypeState _core;

  /// 本会话与历史中的转换任务，按开始时间排序。
  final List<OutputTask> tasks = [];

  /// 批量输出的批次记录（保存在全局设置的 output_batches 中）。
  final List<Map<String, dynamic>> batchRecords = [];
  bool batchBusy = false;
  String historyStatus = '';

  /// 已开始的任务记录保存全部完成；核验前等待它。
  /// V38 起几本可以同时完成，新的保存并入等待，不替换之前的（每个任务各写自己的文件）。
  Future<void> historySaved = Future.value();
  void _trackSave(Future<void> save) =>
      historySaved = Future.wait([historySaved, save]).then((_) {});
  Future<void>? _historyLoad;

  String? get _directory => _core.settingsDirectory == null
      ? null
      : '${_core.settingsDirectory}/output-history';

  void _change(void Function() action, {bool taskOnly = false}) =>
      _core.change(action, taskOnly: taskOnly);

  Future<Map<String, dynamic>> previewRecovery(OutputTask task) async =>
      (jsonDecode(
        await api.kindlingJobText(
          requestJson: jsonEncode({
            'op': 'history_recovery_preview',
            'directory': '${_core.settingsDirectory}/output-history',
            'task_id': task.taskId,
          }),
        ),
      ) as Map).cast<String, dynamic>();

  Future<void> recover(OutputTask task, String token) async {
    if (_directory == null || task.verifying) return;
    _change(() => task.verifying = true);
    try {
      final receipt = (jsonDecode(
        await api.kindlingJobText(
          requestJson: jsonEncode({
            'op': 'history_recover',
            'directory': _directory,
            'task_id': task.taskId,
            'token': token,
            'confirmed': true,
          }),
        ),
      ) as Map).cast<String, dynamic>();
      _change(() {
        task.restored = false;
        task.finishedAt = DateTime.now();
        task.phase = 'complete';
        task.receipt = receipt;
        task.detail = '已恢复事务，原稿未改动；尚未进行阅读器验收。';
        task.verification = '';
      });
      final saved = _persistFinished(task);
      _trackSave(saved);
      await saved;
    } catch (_) {
      _change(() => task.verification = '恢复未能确认完成，请重新核对事务；不会自动重试。');
    } finally {
      _change(() => task.verifying = false);
    }
  }

  Future<void> verify(OutputTask task) async {
    if (_directory == null || task.verifying) return;
    _change(() {
      task.verifying = true;
      task.verification = '';
      task.verificationCode = '';
    });
    try {
      await historySaved;
      final result = jsonDecode(
        await api.kindlingJobText(
          requestJson: jsonEncode({
            'op': 'history_verify',
            'directory': _directory,
            'task_id': task.taskId,
          }),
        ),
      ) as Map;
      _change(() {
        task.verificationCode = result['status'] as String? ?? 'unknown';
        task.verification =
            const {
              'matches': '核对时文件内容与导出回执一致；尚未进行阅读器验收。',
              'changed': '文件内容与导出回执不一致，请检查；未修改任何文件。',
              'missing': '原成品路径的文件不存在。',
              'no_receipt': '没有最终回执，需进一步核对事务；未自动恢复或重新生成。',
              'published_without_receipt': '成品、原稿、备份及事务证据核对一致，但缺少最终任务回执；未改写历史。',
              'staged_verified': '暂存成品、原稿、备份及事务证据核对一致；尚未发布最终文件。',
              'source_changed': '原稿与事务记录不一致，已停止核对；未恢复或修改文件。',
              'evidence_changed': '备份或事务证据已变化，已停止核对；未恢复或修改文件。',
            }[result['status']] ??
            '无法确定核对结果。';
      });
    } catch (_) {
      _change(() => task.verification = '核对失败，请检查历史回执和文件访问权限。');
    } finally {
      _change(() => task.verifying = false);
    }
  }

  Future<void> loadHistory() => _historyLoad ??= _loadHistory();
  Future<void> _loadHistory() async {
    if (_directory == null) return;
    try {
      final result = jsonDecode(
        await api.kindlingJobText(
          requestJson: jsonEncode({
            'op': 'history_load',
            'directory': _directory,
          }),
        ),
      ) as Map;
      final restored = (result['records'] as List)
          .map((r) => OutputTask.fromRecord((r as Map).cast<String, dynamic>()))
          .toList();
      _change(() {
        final existing = tasks.map((t) => t.taskId).toSet();
        tasks.addAll(restored.where((t) => !existing.contains(t.taskId)));
        tasks.sort((a, b) => a.startedAt.compareTo(b.startedAt));
        historyStatus = '已读取输出记录；历史成品尚未重新核验。';
      });
    } catch (_) {
      _change(
        () => historyStatus = '输出历史读取失败，已有文件保留；请检查设置目录中的 output-history。',
      );
    }
  }

  Future<void> persist(OutputTask task) async {
    if (_directory == null || task.restored) return;
    final saved = jsonDecode(
      await api.kindlingJobText(
        requestJson: jsonEncode({
          'op': 'history_save',
          'directory': _directory,
          'record': task.toRecord(),
          'clean_completed': task.phase == 'complete',
        }),
      ),
    ) as Map;
    if (saved['cleaned'] == false) {
      _change(() => historyStatus = '成品和历史已保存，但本次临时目录未能清理。请关闭占用文件的程序后重试。');
    }
  }

  Future<void> _persistFinished(OutputTask task) async {
    try {
      await persist(task);
    } catch (_) {
      _change(() => historyStatus = '任务结果未能保存到历史；本次结果仍可查看，请保留成品和事务记录。');
    }
  }

  Future<Map<String, dynamic>> runKindling(
    OutputTask task,
    Map<String, dynamic> request,
  ) async {
    String? lastPublishedState;
    final job = KindlingJob(
      startOperation: task.format == 'EPUB' ? 'start_epub' : 'start',
      onChanged: () {
        final job = task.job!;
        if (!job.terminal) {
          // The backend is polled frequently, but most polls repeat the same
          // visible state. Avoid rebuilding every listener (especially the
          // full tasks page) when phase/detail/availability did not change.
          final state = [
            job.phase,
            job.message,
            job.statusAvailable,
            job.cancellable,
            job.cancelRequested,
          ].join('\u0000');
          if (state == lastPublishedState) return;
          lastPublishedState = state;
          update(task, job.phase, detail: job.message);
        }
      },
    );
    task.job = job;
    try {
      final result = await job.run(request);
      update(
        task,
        'complete',
        receipt: result,
        detail: '${task.format} 已生成，原稿未改动。',
        terminal: true,
      );
      return result;
    } catch (error) {
      update(
        task,
        job.phase == 'cancelled' ? 'cancelled' : 'failed',
        detail: error is ExportStopped
            ? error.message
            : conversionApiErrorMessage(error),
        terminal: true,
      );
      rethrow;
    }
  }

  OutputTask begin(
    String bookId,
    String format,
    String path, {
    String? batchId,
    int? batchIndex,
    int? batchTotal,
    bool? checksEnabled,
  }) {
    final book = _core.shelf.books.firstWhere((b) => b.id == bookId);
    final source = book.source!;
    final task = OutputTask(
      bookId: bookId,
      title: _core.displayTitle(book),
      sourceId: source.sourceId,
      revision: source.revision,
      format: format,
      outputPath: path,
      batchId: batchId,
      batchIndex: batchIndex,
      batchTotal: batchTotal,
      checksEnabled: checksEnabled,
    );
    _change(() => tasks.add(task));
    return task;
  }

  void update(
    OutputTask task,
    String phase, {
    String detail = '',
    Map<String, dynamic>? receipt,
    bool terminal = false,
  }) {
    if (task.terminal) return;
    _change(() {
      task.phase = phase;
      task.detail = detail;
      task.receipt = receipt;
      if (terminal) task.finishedAt = DateTime.now();
    }, taskOnly: true);
    if (terminal) _trackSave(_persistFinished(task));
  }

  /// 读取全局设置后同步批次记录。
  void loadBatchRecords(Map<String, dynamic> configuration) {
    batchRecords
      ..clear()
      ..addAll(
        ((configuration['output_batches'] as List?) ?? const [])
            .whereType<Map>()
            .map((record) => record.cast<String, dynamic>()),
      );
  }

  Future<bool> saveBatchRecord(Map<String, dynamic> record) async {
    if (!await _core.loadGlobalSettings()) return false;
    final id = record['batch_id'];
    if (id is! String || id.isEmpty) return false;
    final next = batchRecords
        .where((item) => item['batch_id'] != id)
        .map((item) => jsonDecode(jsonEncode(item)) as Map<String, dynamic>)
        .toList();
    next.add(jsonDecode(jsonEncode(record)) as Map<String, dynamic>);
    next.sort(
      (a, b) => (a['created_at'] as String? ?? '').compareTo(
        b['created_at'] as String? ?? '',
      ),
    );
    while (next.length > 128) {
      next.removeAt(0);
    }
    final ok = await _core.saveGlobalConfigurationPatch({
      'output_batches': next,
    });
    if (ok) {
      _change(() {
        batchRecords
          ..clear()
          ..addAll(next);
      });
    }
    return ok;
  }

  /// 有任务正在运行。
  bool get running => tasks.any((task) => !task.terminal);

  /// 释放时停止仍在运行的转换。
  void cancelRunning() {
    for (final task in tasks) {
      if (!task.terminal && task.job != null) unawaited(task.job!.cancel());
    }
  }
}
