import 'dart:convert';

import '../src/rust/api.dart' as api;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../application/output_history_service.dart';
import '../prototype/prototype_state.dart';
import '../prototype/output_task.dart';

class LegacyOutputHistoryService implements OutputHistoryService {
  LegacyOutputHistoryService(this.backend);
  final PrototypeState backend;
  final Map<int, List<OutputRecord>> _pageCache = {};
  int _cacheRevision = -1;
  OutputRecoveryPreview? pending;
  String? token;
  @override
  Listenable get changes => backend;
  @override
  String get status => backend.outputs.historyStatus;
  @override
  int get count => backend.outputs.tasks.length;
  @override
  Future<void> load() => backend.outputs.loadHistory();
  @override
  List<OutputRecord> page(int offset, {int limit = 50}) {
    if (offset < 0 || limit < 1 || limit > 50) throw ArgumentError('无效历史分页');
    if (_cacheRevision != backend.stateRevision) {
      _pageCache.clear();
      _cacheRevision = backend.stateRevision;
    }
    final key = offset * 100 + limit;
    return _pageCache.putIfAbsent(
      key,
      () => List.unmodifiable(
        backend.outputs.tasks.reversed.skip(offset).take(limit).map(snapshot),
      ),
    );
  }

  OutputRecord snapshot(OutputTask t) {
    final book = backend.shelf.books
        .where((b) => b.id == t.bookId && !b.isDemo)
        .firstOrNull;
    return OutputRecord(
      id: t.taskId,
      title: t.title,
      format: t.format,
      path: t.outputPath,
      directory: File(t.outputPath).parent.path,
      status: t.label,
      detail: t.detail,
      verification: t.verification,
      startedAt: t.startedAt,
      restored: t.restored,
      busy: t.verifying,
      terminal: t.terminal,
      interrupted: t.phase == 'interrupted',
      bytes: t.receipt?['byte_length'] as int?,
      sourcePreserved:
          (t.receipt?['transaction'] as Map?)?['source_unchanged'] == true,
      verificationCode: t.verificationCode,
      bookId: t.bookId,
      bookTitle: book == null ? '' : backend.displayTitle(book),
      bookMatch: book == null
          ? OutputBookMatch.missing
          : book.source?.sourceId == t.sourceId
          ? OutputBookMatch.current
          : OutputBookMatch.olderSource,
    );
  }

  @override
  OutputRecord? find(String id) {
    final task = backend.outputs.tasks.where((t) => t.taskId == id).firstOrNull;
    return task == null ? null : snapshot(task);
  }

  @override
  Future<void> verify(String id) async {
    final task = backend.outputs.tasks.where((t) => t.taskId == id).firstOrNull;
    if (task == null ||
        !task.terminal ||
        task.verifying ||
        backend.settingsDirectory == null) {
      throw const FormatException('此任务当前无法核验，请等待任务完成并确认历史目录可用。');
    }
    await backend.outputs.verify(task);
  }

  @override
  Future<OutputPackageInspection> inspectPackage(String id) async {
    final record = find(id);
    if (record == null ||
        !record.terminal ||
        backend.settingsDirectory == null) {
      throw const FormatException('成品记录尚不可检查。');
    }
    final result = (jsonDecode(
      await api.kindlingJobText(
        requestJson: jsonEncode({
          'op': 'history_inspect',
          'directory': '${backend.settingsDirectory}/output-history',
          'task_id': id,
        }),
      ),
    ) as Map).cast<String, dynamic>();
    final encoded = result['cover_png'] as String?;
    return OutputPackageInspection(
      status: result['status'] as String,
      detail: result['detail'] as String? ?? '',
      title: result['title'] as String? ?? '',
      author: result['author'] as String? ?? '',
      language: result['language'] as String? ?? '',
      metadataStatus: result['metadata_status'] as String? ?? 'unavailable',
      expectedMetadata: Map<String, String>.unmodifiable(
        (result['expected_metadata'] as Map? ?? const {})
            .cast<String, String>(),
      ),
      metadataMismatches: List<String>.unmodifiable(
        (result['metadata_mismatches'] as List? ?? const []).cast<String>(),
      ),
      spineDocuments: result['spine_documents'] as int? ?? 0,
      checkedLinks: result['checked_links'] as int? ?? 0,
      bodyBytes: result['body_bytes'] as int? ?? 0,
      headingCount: result['heading_count'] as int? ?? 0,
      imageReferences: result['image_references'] as int? ?? 0,
      imageResources: result['image_resources'] as int? ?? 0,
      coverInSpine: result['cover_in_spine'] as bool? ?? false,
      coverMetadataPresent: result['cover_metadata_present'] as bool? ?? false,
      cover: encoded == null ? null : base64Decode(encoded),
    );
  }

  @override
  Future<OutputRecoveryPreview> previewRecovery(String id) async {
    pending = null;
    token = null;
    final task = backend.outputs.tasks.where((t) => t.taskId == id).firstOrNull;
    if (task == null ||
        task.phase != 'interrupted' ||
        task.verifying ||
        task.recoveryPreviewOpen ||
        backend.settingsDirectory == null) {
      throw const FormatException('此记录当前无法恢复，请先核验事务。');
    }
    backend.change(() => task.recoveryPreviewOpen = true);
    try {
      final result = await backend.outputs.previewRecovery(task);
      final status = result['status'];
      if (!{'staged_verified', 'published_without_receipt'}.contains(status) ||
          result['token'] is! String) {
        throw const FormatException('没有通过校验的恢复计划。');
      }
      final preview = OutputRecoveryPreview(
        id,
        result['output_path'] as String,
        result['transaction_dir'] as String,
        status == 'staged_verified',
      );
      pending = preview;
      token = result['token'] as String;
      return preview;
    } finally {
      backend.change(() => task.recoveryPreviewOpen = false);
    }
  }

  @override
  void cancelRecovery(OutputRecoveryPreview preview) {
    if (identical(preview, pending)) {
      pending = null;
      token = null;
    }
  }

  @override
  Future<void> recover(OutputRecoveryPreview preview) async {
    final task = backend.outputs.tasks
        .where((t) => t.taskId == preview.taskId)
        .firstOrNull;
    if (!identical(preview, pending) ||
        token == null ||
        task == null ||
        task.phase != 'interrupted' ||
        task.verifying) {
      throw const FormatException('恢复预览已失效，请重新预览。');
    }
    final confirmation = token!;
    cancelRecovery(preview);
    await backend.outputs.recover(task, confirmation);
    if (task.phase != 'complete') throw FormatException(task.verification);
  }
}
