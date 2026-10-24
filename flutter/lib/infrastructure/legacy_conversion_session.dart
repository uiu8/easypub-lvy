import '../application/storage_locations.dart';

import 'dart:async';

import '../src/rust/api.dart' as api;

import 'package:crypto/crypto.dart';

import 'dart:convert';

import '../application/conversion_snapshot.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../application/conversion_service.dart';
import '../application/output_defaults.dart';
import '../prototype/prototype_state.dart';
import '../prototype/output_batch.dart';
import '../prototype/output_task.dart';
// 生成封面与书库共用同一画法（OUT-070）。
import '../desk/library/generated_cover.dart' show renderGeneratedCover;
import '../prototype/conversion_preflight_runner.dart';
import '../prototype/conversion_preflight.dart';

class _BookPreviewCache {
  _BookPreviewCache(
    this.key,
    this.files,
    this.overrides,
    this.cover,
    this.report,
    this.item,
  );
  final String key, files;
  final Map<String, dynamic> overrides;
  final String? cover;
  final ConversionPreflightReport? report;
  final BatchOutputItem item;
}

class LegacyConversionSession extends ChangeNotifier
    implements
        ConversionSession,
        ConversionTaskFeed,
        ConversionRetryService,
        ConversionNaming {
  LegacyConversionSession(this.backend, {this.epubCall}) {
    backend.addListener(changed);
  }
  final PrototypeState backend;
  final ExportCall? epubCall;
  bool disposed = false;
  Timer? _changeTimer;
  @override
  bool busy = false;
  @override
  ConversionRequest? request;
  int generation = 0;
  OutputBatch? batch;
  ConversionPreview? exposed;
  Map<String, String> guards = {};
  final _previewCache = <String, _BookPreviewCache>{};

  String _cacheKey(String id, ConversionRequest value) => jsonEncode([
    backend.conversionContext(id),
    value.books,
    value.directory,
    value.format,
    value.engine,
    value.language,
    value.generateCover,
    value.runChecks,
    backend.manuscript.findingReviews[id],
    {
      for (final entry in backend.globalConfiguration.entries)
        if (entry.key != 'output_batches') entry.key: entry.value,
    },
  ]);

  Future<String?> _fileIdentity(
    String id,
    ConversionRequest value,
    Map<String, dynamic> overrides,
    Map<String, Future<String>> digests,
  ) async {
    final book = backend.shelf.books.firstWhere((b) => b.id == id);
    final paths = <String>{
      book.source!.path,
      if (book.source!.originPath != null) book.source!.originPath!,
    };
    if (value.format != 'EPUB') paths.add(value.engine);
    void collect(Object? node) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString();
          if ((key == 'path' || key.endsWith('_path')) &&
              entry.value is String &&
              (entry.value as String).isNotEmpty) {
            paths.add(entry.value as String);
          } else {
            collect(entry.value);
          }
        }
      } else if (node is List) {
        for (final child in node) {
          collect(child);
        }
      }
    }

    final settings = conversionSettings(
      backend.production.settings(id),
      overrides,
    );
    collect(settings);
    final identities = <String, String>{};
    if ((settings['additional_css'] as String? ?? '').isNotEmpty ||
        settings['additional_css_bundle'] != null) {
      try {
        final result = await api.productionBatchText(
          requestJson: jsonEncode({
            'op': 'conversion_dependencies',
            'settings': settings,
          }),
          apply: false,
          planId: '',
          confirmed: false,
        );
        final report = jsonDecode(result) as Map;
        if ((report['issues'] as List).isNotEmpty) return null;
        identities['css_dependencies'] = result;
      } catch (_) {
        return null;
      }
    }
    try {
      for (final path in paths.toList()..sort()) {
        final file = File(path);
        if (!file.isAbsolute) return null;
        final type = await FileSystemEntity.type(path);
        if (type == FileSystemEntityType.notFound) {
          identities[path] = 'missing';
          continue;
        }
        if (type != FileSystemEntityType.file) return null;
        identities[path] = await digests.putIfAbsent(
          path,
          () async => (await sha256.bind(file.openRead()).first).toString(),
        );
      }
      return jsonEncode(identities);
    } on FileSystemException {
      return null;
    }
  }

  @override
  Listenable get changes => this;
  void changed() {
    if (disposed || _changeTimer != null) return;
    // Preflight and converter status can report several backend changes in a
    // short burst. Publish at most once per frame window so pages do not
    // rebuild for every intermediate task mutation.
    _changeTimer = Timer(const Duration(milliseconds: 50), () {
      _changeTimer = null;
      if (!disposed) notifyListeners();
    });
  }

  void current(int ticket) {
    if (disposed ||
        ticket != generation ||
        !guards.entries.every(
          (e) => backend.conversionContext(e.key) == e.value,
        )) {
      throw const FormatException('书稿已变化或操作已取消，请重新检查。');
    }
  }

  void available() {
    if (disposed ||
        busy ||
        backend.projectBusy ||
        backend.importing ||
        backend.queueActive) {
      throw const FormatException('请等待当前操作完成。');
    }
  }

  @override
  List<ConversionOutput> get outputs {
    final items = batch?.items ?? <BatchOutputItem>[];
    final ids = items
        .map((item) => item.lastTaskId)
        .whereType<String>()
        .toSet();
    final tasks = <String, OutputTask>{
      if (ids.isNotEmpty)
        for (final task in backend.outputs.tasks)
          if (ids.contains(task.taskId)) task.taskId: task,
    };
    return List.unmodifiable([
      for (final item in items) snapshot(item, tasks[item.lastTaskId]),
    ]);
  }

  @override
  Future<void> loadTaskFeed() async {
    await backend.outputs.loadHistory();
    if (!await backend.loadGlobalSettings()) return;
    final terminal = {
      for (final task in backend.outputs.tasks)
        if (task.terminal &&
            {'complete', 'failed', 'cancelled'}.contains(task.phase))
          task.taskId: task.phase,
    };
    final records =
        jsonDecode(jsonEncode(backend.outputs.batchRecords)) as List;
    var reconciled = false;
    for (final record in records.whereType<Map>()) {
      for (final item
          in (record['items'] as List? ?? const []).whereType<Map>()) {
        final phase = terminal[item['task_id']];
        if (phase != null &&
            (item['phase'] != phase || item['failed'] != (phase == 'failed'))) {
          item['phase'] = phase;
          item['failed'] = phase == 'failed';
          reconciled = true;
        }
      }
    }
    if (reconciled) {
      backend.change(() {
        backend.outputs.batchRecords
          ..clear()
          ..addAll(records.map((r) => Map<String, dynamic>.from(r as Map)));
        backend.globalConfiguration['output_batches'] =
            backend.outputs.batchRecords;
      });
    }
    // Old immutable settings generations stay intact. A later settings save
    // persists the reconciled projection using the existing token check.
  }

  @override
  String get taskFeedStatus => backend.outputs.historyStatus;
  @override
  List<ConversionOutput> get taskFeed {
    final current = outputs;
    final ids = current.map((item) => item.taskId).whereType<String>().toSet();
    return List.unmodifiable([
      ...current,
      for (final task
          in backend.outputs.tasks.reversed
              .where((t) => !ids.contains(t.taskId))
              .take(50))
        ConversionOutput(
          task.bookId,
          task.title,
          task.outputPath,
          task.label,
          phase: task.phase,
          format: task.format,
          detail: task.detail,
          taskId: task.taskId,
          batchId: task.batchId,
          historical: true,
          checksEnabled: task.checksEnabled,
          coverThumbnail: task.coverThumbnail,
          statusAvailable: task.job?.statusAvailable ?? true,
          cancelRequested: task.job?.cancelRequested ?? false,
        ),
    ]);
  }

  ConversionOutput snapshot(BatchOutputItem item, OutputTask? task) {
    final publication = item.request?['publication'] as Map?;
    final settings = publication?['settings'] as Map?;
    final coverPath = settings?['cover_path'] as String?;
    return ConversionOutput(
      item.bookId,
      item.title,
      item.path,
      item.status,
      phase: task?.phase ?? item.phase,
      format: batch!.format,
      detail: task?.detail ?? '',
      taskId: task?.taskId,
      batchId: batch!.batchId,
      checksEnabled: request?.runChecks,
      coverThumbnail: task?.coverThumbnail,
      statusAvailable: task?.job?.statusAvailable ?? true,
      cancelRequested: task?.job?.cancelRequested ?? false,
      stopRequested: batch!.stopped,
      coverPath: coverPath == null || coverPath.trim().isEmpty
          ? null
          : coverPath,
      coverCrop: settings?['cover_crop'] is Map
          ? Map<String, dynamic>.unmodifiable(
              (settings!['cover_crop'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }

  @override
  bool isCurrent(ConversionPreview preview) {
    try {
      current(generation);
      return identical(preview, exposed) && preview.previewed;
    } catch (_) {
      return false;
    }
  }

  /// 成品文件名（不含扩展名与同名序号）：按全局设置的命名方式，
  /// 转换与转换页的“本次将生成”共用（OUT-073）。
  String outputStem(SampleBook book, String title) {
    final author = backend.authorOf(book);
    final naming = backend.globalConfiguration['output_naming'] ?? 'title';
    final sourceName = book.path
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.[^.]+$'), '');
    return filename(
      naming == 'filename'
          ? sourceName
          : naming == 'title_author' && author.isNotEmpty
          ? '$title - $author'
          : title,
    );
  }

  @override
  String plannedFileName(String bookId, String format) {
    final book = backend.shelf.books.firstWhere((b) => b.id == bookId);
    return '${outputStem(book, backend.displayTitle(book))}.${format.toLowerCase()}';
  }

  static String filename(String title) {
    var text = title
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (text.isEmpty) text = '书稿';
    if (RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])($|\.)',
      caseSensitive: false,
    ).hasMatch(text)) {
      text = '_$text';
    }
    return String.fromCharCodes(text.runes.take(80));
  }

  @override
  Future<ConversionPreview> previewRetry(List<String> taskIds) async {
    available();
    if (taskIds.isEmpty ||
        taskIds.length > 128 ||
        taskIds.toSet().length != taskIds.length) {
      throw const FormatException('请选择同一批次中的具体失败任务。');
    }
    await loadTaskFeed();
    if (!backend.globalSettingsLoaded && backend.settingsDirectory != null) {
      throw const FormatException('原批次设置读取失败，请检查设置目录。');
    }
    available();
    final tasks = <OutputTask>[];
    for (final id in taskIds) {
      final task = backend.outputs.tasks
          .where((t) => t.taskId == id)
          .firstOrNull;
      if (task == null ||
          !task.terminal ||
          !{'failed', 'cancelled'}.contains(task.phase)) {
        throw const FormatException('任务不存在或不是已结束的失败/取消任务；中断任务请先核对成品。');
      }
      tasks.add(task);
    }
    final batchIds = tasks.map((t) => t.batchId).toSet();
    if (batchIds.length != 1 || batchIds.single == null) {
      throw const FormatException('只能恢复同一批次；旧任务未记录批次，请重新配置转换。');
    }
    final origin = backend.outputs.batchRecords
        .where((r) => r['batch_id'] == batchIds.single)
        .firstOrNull;
    if (origin == null ||
        origin['snapshot_schema'] != 1 ||
        origin['configuration'] is! Map) {
      throw const FormatException('旧批次缺少原配置快照，不能按原配置重试；请重新配置转换。');
    }
    final config = origin['configuration'] as Map;
    if (![
          'directory',
          'format',
          'engine',
          'language',
        ].every((k) => config[k] is String) ||
        !['generate_cover', 'run_checks'].every((k) => config[k] is bool)) {
      throw const FormatException('旧批次缺少完整原配置，请重新配置转换。');
    }
    final rows = (origin['items'] as List).cast<Map>();
    final frozen = <String, Map<String, dynamic>>{};
    for (final task in tasks) {
      final row = rows.where((r) => r['task_id'] == task.taskId).firstOrNull;
      if (row == null ||
          row['request'] is! Map ||
          row['input_fingerprint'] is! String ||
          row['preview_plan_id'] is! String) {
        throw const FormatException('该任务缺少完整快照或已有更新尝试，请选择最新任务或重新配置。');
      }
      if (!backend.shelf.books.any((b) => b.id == task.bookId && !b.isDemo)) {
        throw const FormatException('原书稿尚未载入，请先打开原项目或重新导入。');
      }
      frozen[task.bookId] = jsonDecode(jsonEncode(row)) as Map<String, dynamic>;
    }
    if (frozen.length != tasks.length) {
      throw const FormatException('同一本书请选择一个任务。');
    }
    final restored = ConversionRequest(
      books: tasks.map((t) => t.bookId).toList(),
      directory: config['directory'] as String,
      format: config['format'] as String,
      engine: config['engine'] as String,
      language: config['language'] as String,
      generateCover: config['generate_cover'] == true,
      runChecks: config['run_checks'] == true,
      keepOriginalEpub: {
        for (final id in (config['keep_original_epub'] as List? ?? const []))
          if (id is String) id,
      },
    );
    return _preview(
      restored,
      retryItems: frozen,
      retryOfBatchId: batchIds.single,
    );
  }

  @override
  Future<ConversionPreview> preview(ConversionRequest request) =>
      _preview(request);

  Future<ConversionPreview> _preview(
    ConversionRequest request, {
    Map<String, Map<String, dynamic>>? retryItems,
    String? retryOfBatchId,
  }) async {
    available();
    final previousCache = retryItems == null
        ? Map<String, _BookPreviewCache>.of(_previewCache)
        : <String, _BookPreviewCache>{};
    _previewCache.clear();
    final ticket = ++generation;
    exposed = null;
    batch = null;
    guards = {};
    final ids = request.books;
    if (ids.isEmpty ||
        ids.length > 128 ||
        ids.toSet().length != ids.length ||
        !{'EPUB', 'AZW3', 'MOBI', 'KFX'}.contains(request.format) ||
        !{'', 'zh-CN', 'zh-TW', 'en', 'ja'}.contains(request.language)) {
      throw const FormatException('请选择 1–128 本不同书稿及有效输出格式。');
    }
    final destination = Directory(request.directory.trim());
    if (request.directory.trim().isEmpty || !destination.isAbsolute) {
      throw const FormatException('请选择完整输出文件夹路径。');
    }
    final books = ids
        .map(
          (id) =>
              backend.shelf.books.firstWhere((b) => b.id == id && !b.isDemo),
        )
        .toList();
    this.request = request;
    guards = {for (final id in ids) id: backend.conversionContext(id)};
    busy = true;
    changed();
    try {
      final beforeDigests = <String, Future<String>>{};
      final afterDigests = <String, Future<String>>{};
      final overrides = <String, Map<String, dynamic>>{};
      final covers = <String, String>{};
      final reusable = <String, _BookPreviewCache>{};
      final keys = {
        for (final book in books) book.id: _cacheKey(book.id, request),
      };
      final fileIdentities = <String, String?>{};
      for (final book in books) {
        final previous = previousCache[book.id];
        if (previous != null &&
            previous.key == keys[book.id] &&
            await _fileIdentity(
                  book.id,
                  request,
                  previous.overrides,
                  beforeDigests,
                ) ==
                previous.files) {
          current(ticket);
          reusable[book.id] = previous;
          overrides[book.id] = previous.overrides;
          if (previous.cover != null) covers[book.id] = previous.cover!;
          fileIdentities[book.id] = previous.files;
          continue;
        }
        final frozen = retryItems?[book.id];
        if (frozen != null) {
          final input = backend.publicationRequest(book.id);
          if (publicationFingerprint(input) != frozen['input_fingerprint']) {
            throw const FormatException('书稿或编辑内容已改变，不能复用原方案；请重新配置并预览。');
          }
          final publication = (frozen['request'] as Map)['publication'] as Map;
          final settings = Map<String, dynamic>.from(
            publication['settings'] as Map,
          );
          overrides[book.id] = settings;
          final path = settings['cover_path'] as String?;
          if (path != null && path.isNotEmpty) covers[book.id] = path;
          continue;
        }
        final settings = backend.production.settings(book.id);
        final cover =
            (settings['cover_path'] as String? ??
                    backend.production.coverPathFor(book) ??
                    '')
                .trim();
        final fields = <String, dynamic>{
          'language': resolveOutputLanguage(
            override: request.language,
            book: settings['language'] as String?,
            fallback:
                backend.globalConfiguration['default_language'] as String?,
          ),
        };
        if (cover.isEmpty && request.generateCover) {
          final generated = await renderGeneratedCover(
            backend.displayTitle(book),
            backend.authorOf(book),
            Directory(
              await StorageLocations.retain(
                'conversion_covers',
                settingsDirectory: backend.settingsDirectory,
              ),
            ),
          );
          current(ticket);
          fields.addAll({
            'cover_path': generated,
            'cover_crop': null,
            'cover_design': null,
          });
          covers[book.id] = generated;
        }
        overrides[book.id] = Map.unmodifiable(fields);
      }
      for (final book in books.where((b) => !reusable.containsKey(b.id))) {
        fileIdentities[book.id] = await _fileIdentity(
          book.id,
          request,
          overrides[book.id]!,
          beforeDigests,
        );
        current(ticket);
      }
      final runner = ConversionPreflightRunner(
        state: backend,
        format: request.format,
        enginePath: request.engine,
        generateCover: false,
        languages: {
          for (final book in books)
            book.id: overrides[book.id]!['language'] as String,
        },
        covers: covers,
        publicationOverrides: overrides,
      );
      final freshReports = request.runChecks
          ? await runner.run(
              books.where((b) => !reusable.containsKey(b.id)),
              isCancelled: () => disposed || generation != ticket,
              onProgress: (_) => changed(),
            )
          : <ConversionPreflightReport>[];
      final reports = <ConversionPreflightReport>[
        for (final book in books)
          ...freshReports.where((r) => r.bookId == book.id),
        for (final book in books)
          if (reusable[book.id]?.report != null) reusable[book.id]!.report!,
      ]..sort((a, b) => ids.indexOf(a.bookId).compareTo(ids.indexOf(b.bookId)));
      current(ticket);
      final output = OutputBatch(backend, ids, epubCall: epubCall)
        ..configuration = {
          'directory': request.directory,
          'format': request.format,
          'engine': request.engine,
          'language': request.language,
          'generate_cover': request.generateCover,
          'run_checks': request.runChecks,
          if (request.keepOriginalEpub.isNotEmpty)
            'keep_original_epub': request.keepOriginalEpub.toList(),
        }
        ..keepOriginalEpub = request.keepOriginalEpub
        ..retryOfBatchId = retryOfBatchId
        ..format = request.format
        ..engine = request.engine
        ..requiresPreflight = false
        ..checksEnabled = request.runChecks
        ..publicationOverrides = Map.unmodifiable(overrides);
      batch = output;
      final used = <String>{};
      final collisions = <ConversionFinding>[];
      for (final item in output.items) {
        final frozen = retryItems?[item.bookId];
        if (frozen != null) {
          item.path = frozen['output_path'] as String;
          continue;
        }
        final book = books.firstWhere((b) => b.id == item.bookId);
        final stem = outputStem(book, item.title),
            extension = request.format.toLowerCase();
        var serial = 1;
        var name = '$stem.$extension';
        while (used.contains(name.toLowerCase()) ||
            await File('${destination.path}/$name').exists() ||
            await Directory('${destination.path}/.$name.easypub-txn')
                .exists()) {
          name = '$stem (${++serial}).$extension';
          current(ticket);
        }
        if (serial > 1 &&
            backend.globalConfiguration['output_collision_policy'] == 'ask') {
          collisions.add(
            ConversionFinding(
              item.bookId,
              '同名文件需要确认',
              'warning',
              '已有同名文件将保留，新成品保存为 $name',
              null,
              category: 'destination',
            ),
          );
        }
        used.add(name.toLowerCase());
        item.path = '${destination.path}/$name';
      }
      current(ticket);
      final acknowledged = !reports.any((r) => r.requiresAcknowledgement);
      await output.persistPreflight(
        reports,
        acknowledged: acknowledged,
        stateName: reports.any((r) => r.blocking)
            ? 'preflight_blocked'
            : 'preflight_ready',
      );
      current(ticket);
      final findings = [
        ...collisions,
        for (final report in reports)
          for (final issue in report.issues)
            ConversionFinding(
              report.bookId,
              issue.title,
              issue.level == ConversionPreflightLevel.blocking &&
                      {'chapters', 'cleanup'}.contains(issue.category)
                  ? 'warning'
                  : issue.level.name,
              issue.detail,
              issue.canOpenRepair ? issue.action.name : null,
              category: issue.category,
              isCoverIssue: issue.isCoverIssue,
            ),
      ];
      {
        await destination.create(recursive: true);
        await output.previewAll(
          changed,
          reusable: {
            for (final entry in reusable.entries) entry.key: entry.value.item,
          },
        );
        current(ticket);
        for (final item in output.items) {
          if (item.preview == null) {
            findings.add(
              ConversionFinding(
                item.bookId,
                '成品预览未通过',
                'blocking',
                item.status,
                null,
                category: 'destination',
              ),
            );
          } else {
            if (retryItems != null &&
                item.preview!['plan_id'] !=
                    retryItems[item.bookId]!['preview_plan_id']) {
              throw const FormatException('原稿、资源或转换器与原任务不一致，不能按原配置重试；请重新配置转换。');
            }
            final passthrough = item.preview!['passthrough'];
            if (passthrough is Map) {
              findings.add(
                ConversionFinding(
                  item.bookId,
                  '保持原格式',
                  'info',
                  passthroughSummary(passthrough),
                  null,
                  category: 'converter',
                ),
              );
            }
            findings.add(
              ConversionFinding(
                item.bookId,
                '输出预览通过',
                'pass',
                '${request.format} · ${item.path}\n已预览目标文件；提交时仍会检查同名文件，不覆盖已有文件。',
                null,
                category: 'destination',
              ),
            );
          }
        }
      }
      for (final entry in covers.entries) {
        findings.add(
          ConversionFinding(
            entry.key,
            '本次生成文字封面',
            'info',
            '仅用于本次成品，书籍信息与原稿保持不变。',
            null,
            category: 'resources',
          ),
        );
      }
      final plan = ConversionPreview(
        findings,
        outputs,
        bookTitles: {
          for (final book in backend.shelf.books.where(
            (b) => ids.contains(b.id),
          ))
            book.id: backend.displayTitle(book),
        },
        previewed: output.items.every((i) => i.preview != null),
      );
      for (final item in output.items) {
        final files = fileIdentities[item.bookId];
        final report = reports
            .where((r) => r.bookId == item.bookId)
            .firstOrNull;
        final checkFailed =
            report?.issues.any((i) => i.title.contains('失败')) ?? false;
        if (retryItems == null &&
            !checkFailed &&
            item.preview != null &&
            files != null &&
            files ==
                await _fileIdentity(
                  item.bookId,
                  request,
                  overrides[item.bookId]!,
                  afterDigests,
                )) {
          current(ticket);
          _previewCache[item.bookId] = _BookPreviewCache(
            keys[item.bookId]!,
            files,
            overrides[item.bookId]!,
            covers[item.bookId],
            reports.where((r) => r.bookId == item.bookId).firstOrNull,
            item,
          );
        }
      }
      current(ticket);
      exposed = plan;
      return plan;
    } finally {
      busy = false;
      changed();
    }
  }

  @override
  Future<List<ConversionOutput>> commit(
    ConversionPreview preview, {
    required bool acknowledgeWarnings,
  }) async {
    available();
    if (!isCurrent(preview)) {
      throw const FormatException('输出计划已过期或无法执行，请重新生成。');
    }
    if (!acknowledgeWarnings &&
        preview.findings.any((f) => f.title == '同名文件需要确认')) {
      throw const FormatException('请先确认保留已有文件并使用新文件名。');
    }
    _previewCache.clear();
    busy = true;
    changed();
    try {
      final ticket = generation, output = batch!;
      await output.acknowledgePreflight(
        acknowledgeWarnings || !preview.needsAcknowledgement,
      );
      current(ticket);
      if (!output.ready) throw const FormatException('输出预览已过期，请重新检查。');
      exposed = null;
      await output.commitAll(changed);
      return outputs;
    } finally {
      busy = false;
      changed();
    }
  }

  @override
  Future<void> cancel() async {
    _previewCache.clear();
    generation++;
    exposed = null;
    await batch?.stop();
    changed();
  }

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    _changeTimer?.cancel();
    _changeTimer = null;
    generation++;
    exposed = null;
    backend.removeListener(changed);
    unawaited(batch?.stop() ?? Future<void>.value());
    super.dispose();
  }
}

/// 保持原格式时对原 EPUB 做了哪些修补（OUT-079）。
String passthroughSummary(Map report) {
  final images = (report['images'] as List? ?? const []).length;
  final unreadable = (report['unreadable_images'] as List? ?? const []).length;
  const labels = {'title': '书名', 'author': '作者', 'language': '语言'};
  final metadata = [
    for (final m in (report['metadata'] as List? ?? const []))
      labels['$m'] ?? '$m',
  ];
  return [
    '使用原 EPUB 的排版，不重排正文；原文件不变。',
    images == 0 ? '图片不需要转换。' : '为 Kindle 转换 $images 张图片。',
    if (unreadable > 0) '$unreadable 张图片读不出，原样保留。',
    if (metadata.isNotEmpty) '按书籍信息写入：${metadata.join('、')}。',
    if (report['cover_added'] == true) '原 EPUB 没有封面，已加入本书封面。',
  ].join('\n');
}
