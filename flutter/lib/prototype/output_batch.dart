import 'dart:async';
import 'dart:convert';

import '../application/conversion_snapshot.dart';
import '../application/parallel_books.dart';

import '../src/rust/api.dart' as api;
import 'kindling_job.dart';
import 'conversion_error.dart';
import 'conversion_preflight.dart';
import 'conversion_preflight_runner.dart';
import 'prototype_state.dart';
import 'output_task.dart';

typedef ExportCall = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> request,
);

class BatchOutputItem {
  BatchOutputItem(this.bookId, this.title, this.path);
  final String bookId, title;
  String path;
  String status = '待预览';
  // A batch item has one outcome; cancellation is never a retryable failure.
  String phase = 'waiting';
  bool get failed => phase == 'failed';
  String? lastTaskId;
  String? guard, inputFingerprint;
  Map<String, dynamic>? request, preview;
}

/// One frozen book selection, using the same preview/commit API as single export.
class OutputBatch {
  OutputBatch(this.state, Iterable<String> bookIds, {ExportCall? epubCall})
    : epubCall = epubCall ?? _epub,
      _customEpubCall = epubCall != null,
      items = List.unmodifiable(
        bookIds.toSet().map((id) {
          final book = state.shelf.books.firstWhere((b) => b.id == id);
          if (book.source == null || book.isDemo) {
            throw const FormatException('请选择真实 TXT。');
          }
          final source = book.source!.path;
          final path = source.replaceFirst(
            RegExp(r'\.txt$', caseSensitive: false),
            '.epub',
          );
          return BatchOutputItem(
            id,
            state.displayTitle(book),
            path == source ? '$source.epub' : path,
          );
        }),
      ) {
    if (items.isEmpty || items.length > 128) {
      throw const FormatException('每批请选择 1–128 本书。');
    }
  }
  final PrototypeState state;
  final String batchId =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${_nextBatch++}';
  static int _nextBatch = 0;
  final DateTime createdAt = DateTime.now();
  final ExportCall epubCall;
  final bool _customEpubCall;
  final List<BatchOutputItem> items;
  bool busy = false, preflightBusy = false, stopped = false, consumed = false;

  /// 正在生成的任务（V38 起可以同时有几本）；停止批次时全部取消。
  final Set<OutputTask> _active = {};
  OutputTask? get active => _active.isEmpty ? null : _active.first;

  /// 批次记录写进全局设置，几本同时完成时排队保存，避免互相覆盖。
  final SerialQueue _records = SerialQueue();
  String? _savedRecord;

  /// 同时处理的本数（V38，SET-069）；测试可以直接指定。
  int? parallelOverride;
  int get parallel =>
      parallelOverride ?? parallelBooks(state.globalConfiguration);
  String format = 'EPUB', engine = '';
  Map<String, Object?> configuration = const {};
  String? retryOfBatchId;
  Map<String, Map<String, dynamic>> publicationOverrides = const {};

  /// 保持原格式的 EPUB 书（V27，OUT-079）。
  Set<String> keepOriginalEpub = const {};
  bool requiresPreflight = false;
  bool? checksEnabled;
  List<ConversionPreflightReport> preflightReports = const [];
  bool preflightAcknowledged = false;
  static Future<Map<String, dynamic>> _epub(
    Map<String, dynamic> request,
  ) async => (jsonDecode(
    await api.epubExportText(requestJson: jsonEncode(request)),
  ) as Map).cast<String, dynamic>();
  void invalidate({bool clearPreflight = true}) {
    if (clearPreflight) {
      preflightReports = const [];
      preflightAcknowledged = false;
    }
    for (final item in items) {
      item.preview = null;
      item.request = null;
      item.guard = null;
      item.status = '待预览';
      item.phase = 'waiting';
      item.lastTaskId = null;
    }
    consumed = false;
  }

  bool get ready =>
      !busy &&
      !consumed &&
      (!requiresPreflight ||
          (preflightReports.isNotEmpty &&
              preflightReports.every((report) => !report.blocking) &&
              (!preflightReports.any(
                    (report) => report.requiresAcknowledgement,
                  ) ||
                  preflightAcknowledged))) &&
      items.every(
        (i) =>
            i.preview != null && i.guard == state.conversionContext(i.bookId),
      );
  Future<void> previewAll(
    void Function() changed, {
    Map<String, BatchOutputItem> reusable = const {},
  }) async {
    if (busy || state.queueActive) return;
    invalidate(clearPreflight: false);
    final paths = items
        .map((i) => i.path.trim().replaceAll('/', '\\').toLowerCase())
        .toSet();
    if (paths.length != items.length) {
      throw const FormatException('批次中有重复输出路径，请修改后重试。');
    }
    busy = true;
    stopped = false;
    state.change(() => state.outputs.batchBusy = true);
    try {
      await runLimited(items, parallel, (item, _) async {
        if (stopped) {
          item.phase = 'cancelled';
          item.status = '未预览：批次已停止';
          changed();
          return;
        }
        item.status = '正在预览';
        changed();
        try {
          final book = state.shelf.books.firstWhere((b) => b.id == item.bookId);
          final guard = state.conversionContext(item.bookId);
          final publication = state.publicationRequest(item.bookId);
          item.inputFingerprint = publicationFingerprint(publication);
          publication['settings'] = conversionSettings(
            publication['settings'] as Map,
            publicationOverrides[item.bookId],
          );
          final language =
              ((publication['settings'] as Map)['language'] as String? ?? '')
                  .trim();
          if (language.isEmpty || language == 'und') {
            throw const FormatException('请先填写本书语言。');
          }
          final request = (jsonDecode(
            jsonEncode({
              'op': 'preview',
              'publication': publication,
              'source_path': book.source!.path,
              'output_path': item.path.trim(),
              'confirmed': false,
              if (keepOriginalEpub.contains(item.bookId) &&
                  originalEpubPath(book) != null)
                'original_epub': originalEpubPath(book),
              if (format != 'EPUB') 'engine_path': engine.trim(),
              if (format != 'EPUB') 'format': format.toLowerCase(),
            }),
          ) as Map).cast<String, dynamic>();
          final previous = reusable[item.bookId];
          final canReuse =
              previous?.preview != null &&
              previous!.guard == guard &&
              previous.request != null &&
              publicationFingerprint(previous.request!) ==
                  publicationFingerprint(request);
          final result = canReuse
              ? previous.preview!
              : format != 'EPUB'
              ? await KindlingJob(onChanged: () {}).run(request)
              : await epubCall(request);
          if (guard != state.conversionContext(item.bookId)) {
            throw const FormatException('书稿已变化，请重新预览。');
          }
          item.guard = guard;
          item.request = request;
          item.preview = result;
          item.status = '预览通过';
        } catch (e) {
          item.status = _error(e);
        }
        changed();
      });
    } finally {
      busy = false;
      state.change(() => state.outputs.batchBusy = false);
      changed();
    }
  }

  Future<List<ConversionPreflightReport>> runPreflight(
    void Function() changed, {
    bool generateCover = true,
  }) async {
    if (busy || preflightBusy || state.queueActive) return preflightReports;
    requiresPreflight = true;
    preflightBusy = true;
    busy = true;
    state.change(() => state.outputs.batchBusy = true);
    preflightAcknowledged = false;
    preflightReports = const [];
    changed();
    final chosen = items
        .map(
          (item) =>
              state.shelf.books.firstWhere((book) => book.id == item.bookId),
        )
        .toList(growable: false);
    final runner = ConversionPreflightRunner(
      state: state,
      format: format,
      enginePath: engine,
      generateCover: generateCover,
      parallel: parallel,
    );
    try {
      final reports = await runner.run(
        chosen,
        onProgress: (value) {
          preflightReports = value;
          changed();
        },
      );
      preflightReports = reports;
      await persistPreflight(
        reports,
        acknowledged: false,
        stateName: reports.any((report) => report.blocking)
            ? 'preflight_blocked'
            : 'preflight_ready',
      );
      changed();
      return reports;
    } finally {
      preflightBusy = false;
      busy = false;
      state.change(() => state.outputs.batchBusy = false);
      changed();
    }
  }

  Future<void> acknowledgePreflight(bool value) async {
    preflightAcknowledged = value;
    if (preflightReports.isNotEmpty) {
      await persistPreflight(
        preflightReports,
        acknowledged: value,
        stateName: 'preflight_ready',
      );
    }
  }

  Future<bool> persistPreflight(
    List<ConversionPreflightReport> reports, {
    required bool acknowledged,
    required String stateName,
  }) async {
    preflightReports = List.unmodifiable(reports);
    preflightAcknowledged = acknowledged;
    return _saveBatchRecord(stateName);
  }

  String _error(Object e) => e is FormatException
      ? e.message
      : e is ExportStopped
      ? e.message
      : conversionApiErrorMessage(e);
  Future<void> stop() async {
    stopped = true;
    await Future.wait([
      for (final task in _active.toList())
        if (task.job != null) task.job!.cancel(),
    ]);
  }

  Future<void> commitAll(void Function() changed) async {
    if (!ready || state.queueActive) return;
    await _commitItems(items, changed);
  }

  /// Re-run only items whose previous attempt ended in failure. Successful
  /// items remain terminal and are never submitted a second time.
  Future<void> retryFailed(void Function() changed) async {
    if (busy || state.queueActive || consumed && !items.any((i) => i.failed)) {
      return;
    }
    final retry = items.where((item) => item.failed).toList();
    if (retry.isEmpty ||
        retry.any(
          (item) =>
              item.preview == null ||
              item.request == null ||
              item.guard != state.conversionContext(item.bookId),
        )) {
      throw const FormatException('失败项的预览已过期，请重新预览整批。');
    }
    await _commitItems(retry, changed);
  }

  Future<void> _commitItems(
    Iterable<BatchOutputItem> selected,
    void Function() changed,
  ) async {
    busy = true;
    stopped = false;
    consumed = true;
    _runningRecordError = null;
    state.change(() => state.outputs.batchBusy = true);
    try {
      await _saveBatchRecord('running');
      await runLimited(selected, parallel, (item, _) async {
        if (stopped) {
          item.phase = 'cancelled';
          item.lastTaskId = null;
          item.status = '未执行：批次已停止';
          changed();
          return;
        }
        if (item.guard != state.conversionContext(item.bookId)) {
          item.phase = 'blocked';
          item.lastTaskId = null;
          item.status = '未执行：书稿变化，需重新预览';
          changed();
          return;
        }
        final task = state.outputs.begin(
          item.bookId,
          format,
          item.path.trim(),
          batchId: batchId,
          batchIndex: items.indexOf(item),
          batchTotal: items.length,
          checksEnabled: checksEnabled,
        );
        _active.add(task);
        item.lastTaskId = task.taskId;
        item.phase = task.phase;
        item.status = '正在生成';
        changed();
        try {
          final settings =
              (item.request?['publication'] as Map?)?['settings'] as Map?;
          final cover = settings?['cover_path'] as String?;
          if (cover != null && cover.trim().isNotEmpty) {
            try {
              final display = jsonDecode(
                await api.kindlingJobText(
                  requestJson: jsonEncode({
                    'op': 'history_cover_thumbnail',
                    'path': cover,
                    'crop': settings?['cover_crop'],
                  }),
                ),
              ) as Map;
              task.coverThumbnail = base64Decode(
                display['cover_thumbnail'] as String,
              );
            } catch (_) {
              // Display snapshots never relax export validation or block conversion.
              // Missing snapshots remain explicit in historical task presentation.
            }
          }
          await state.outputs.persist(task);
          if (!stopped && format == 'EPUB') {
            state.outputs.update(task, 'converting', detail: '正在生成 EPUB');
            item.phase = task.phase;
            changed();
          }
          if (stopped) {
            state.outputs.update(
              task,
              'cancelled',
              detail: '开始转换前已停止批次。',
              terminal: true,
            );
          } else {
            final request = {
              ...item.request!,
              'op': 'commit',
              'confirmed': true,
              'plan_id': item.preview!['plan_id'],
            };
            final result = format != 'EPUB' || !_customEpubCall
                ? await state.outputs.runKindling(task, request)
                : await epubCall(request);
            state.outputs.update(
              task,
              'complete',
              receipt: result,
              detail: '$format 已生成，原稿未改动。',
              terminal: true,
            );
          }
          item.phase = task.phase;
          item.status = task.label;
        } catch (e) {
          // Native execution may already have recorded cancellation or failure.
          // Preserve that terminal result instead of classifying every exception
          // as failure. ExportStopped also carries genuine engine errors.
          if (!task.terminal) {
            state.outputs.update(
              task,
              'failed',
              detail: _error(e),
              terminal: true,
            );
          }
          item.phase = task.phase;
          item.status = '${task.label}：${task.detail}';
        }
        await state.outputs.historySaved;
        _saveRunningSoon();
        _active.remove(task);
        changed();
      });
      // 最终保存会写最新状态：取消还在等间隔的“进行中”保存，只等正在写的那次。
      _runningRecordDirty = false;
      if (_runningWake case final wake? when !wake.isCompleted) wake.complete();
      await _runningRecord;
      if (_runningRecordError case final error?) throw error;
      await _saveBatchRecord(
        items.every((item) => item.phase == 'complete')
            ? 'complete'
            : stopped
            ? 'stopped'
            : 'partial',
      );
    } finally {
      _active.clear();
      busy = false;
      state.change(() => state.outputs.batchBusy = false);
      changed();
    }
  }

  Map<String, dynamic> _record(String stateName) => {
    'batch_id': batchId,
    'snapshot_schema': 1,
    'configuration': configuration,
    if (retryOfBatchId != null) 'retry_of_batch_id': retryOfBatchId,
    'format': format,
    'created_at': createdAt.toUtc().toIso8601String(),
    'state': stateName,
    'preflight': {
      'acknowledged': preflightAcknowledged,
      'reports': preflightReports.map((report) => report.toJson()).toList(),
    },
    'items': [
      for (var index = 0; index < items.length; index++)
        {
          ..._sourceIdentity(items[index].bookId),
          'index': index,
          'book_id': items[index].bookId,
          'title': items[index].title,
          'output_path': items[index].path.trim(),
          'status': items[index].status,
          'failed': items[index].failed,
          'phase': items[index].phase,
          'task_id': items[index].lastTaskId,
          'input_fingerprint': items[index].inputFingerprint,
          'request': items[index].request,
          'preview_plan_id': items[index].preview?['plan_id'],
        },
    ],
  };

  /// 每本完成后的“进行中”记录合并保存（R6）：一次保存约 200ms（读全局设置、整表改写、
  /// 落一个设置版本和一份约 6KB×本数的记录），原来每本都排队等它，批量时成了瓶颈，
  /// 设置目录也每本多一份记录（设置版本上限 1024，用完后设置无法保存）。现在不等，并且最多每 10 秒存一次
  /// 最新快照；重启后各书状态按任务历史重新核对（loadTaskFeed），单本回执仍由
  /// 任务历史即时保存。批次结束时不再补存“进行中”，直接由最终保存代替。
  Future<void>? _runningRecord;
  bool _runningRecordDirty = false;
  Object? _runningRecordError;
  DateTime? _lastRunningSave;
  Completer<void>? _runningWake;
  static const runningRecordInterval = Duration(seconds: 10);
  void _saveRunningSoon() {
    _runningRecordDirty = true;
    _runningRecord ??= () async {
      try {
        while (_runningRecordDirty && _runningRecordError == null) {
          final last = _lastRunningSave;
          final wait = last == null
              ? Duration.zero
              : runningRecordInterval - DateTime.now().difference(last);
          if (wait > Duration.zero) {
            final wake = _runningWake = Completer<void>();
            await Future.any([Future<void>.delayed(wait), wake.future]);
            _runningWake = null;
            if (!_runningRecordDirty) break;
          }
          _runningRecordDirty = false;
          _lastRunningSave = DateTime.now();
          try {
            await _saveBatchRecord('running');
          } catch (e) {
            // _saveBatchRecord 失败时已置 stopped，后续书不再开始；错误在批次结束时抛出。
            _runningRecordError = e;
          }
        }
      } finally {
        _runningRecord = null;
      }
    }();
  }

  Future<bool> _saveBatchRecord(String stateName) => _records.run(() async {
    if (state.settingsDirectory == null) return true;
    final record = _record(stateName);
    final identity = jsonEncode(record);
    // 并发完成的回调排队后可能看到同一份最新快照；成功保存过的相同
    // 快照不再重复生成设置版本。失败不记缓存，单本成品回执仍独立保存。
    if (identity == _savedRecord) return true;
    if (!await state.outputs.saveBatchRecord(record)) {
      stopped = true;
      throw const FormatException('批次记录未能保存，已停止后续输出。请检查设置目录后重新核对任务记录。');
    }
    _savedRecord = identity;
    return true;
  });

  Map<String, dynamic> _sourceIdentity(String bookId) {
    final book = state.shelf.books.firstWhere((b) => b.id == bookId);
    final source = book.source;
    return {'source_id': source?.sourceId, 'source_revision': source?.revision};
  }

  bool get hasFailedItems => items.any((item) => item.failed);
}

/// 书的原 EPUB 路径；不是从 EPUB 导入的书为 null（V27）。
String? originalEpubPath(SampleBook book) {
  final origin = book.source?.originPath;
  return origin != null && origin.toLowerCase().endsWith('.epub')
      ? origin
      : null;
}
