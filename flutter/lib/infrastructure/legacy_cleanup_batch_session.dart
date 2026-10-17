import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/cleanup_batch_service.dart';
import '../application/cleanup_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;
import 'legacy_cleanup_session.dart';

/// Batch preparation stays detached from live settings until every target's
/// cleanup and effective publication have passed validation.
class LegacyCleanupBatchSession extends ChangeNotifier
    implements CleanupBatchSession {
  LegacyCleanupBatchSession(this.backend, this.templateBookId) {
    backend.addListener(_refresh);
  }
  @override
  Listenable get changes => this;
  void _refresh() {
    if (_disposed) return;
    if (_pending != null && !_valid(_generation)) {
      _pending = null;
      _targets.clear();
    }
    notifyListeners();
  }

  final PrototypeState backend;
  final String templateBookId;
  int _generation = 0;
  bool _disposed = false;
  CleanupBatchPreview? _pending;
  Map<String, String> _guards = {};
  String _request = '', _planId = '';
  final _targets = <String, _TargetPreview>{};

  /// 预览时检测到的章节修改换算结果（CLEAN-104），采用时核对一致。
  final _impacts = <String, CleanupImpact>{};

  String _context(String id) => jsonEncode([
    backend.shelf.books.any((b) => b.id == id && !b.isDemo),
    backend.publicationContext(id),
    backend.cleanup.histories[id],
  ]);
  bool get _idle =>
      !backend.projectBusy && !backend.importing && !backend.cleanup.historyBusy;
  bool _valid(int generation) =>
      !_disposed &&
      generation == _generation &&
      _guards.entries.every((e) => _context(e.key) == e.value);
  void _check(int generation) {
    if (!_valid(generation) || !_idle) {
      throw const FormatException('书稿或项目状态已改变，本批未采用，请重新预览。');
    }
  }

  @override
  Future<CleanupBatchPreview> preview(
    String template,
    List<String> targets, {
    required bool append,
  }) async {
    cancel();
    final generation = _generation;
    if (_disposed || !_idle) throw const FormatException('请等待当前操作完成。');
    _request = jsonEncode(
      backend.cleanup.batchRequest(
        templateBookId,
        targets,
        append,
        templateOverride: (jsonDecode(template) as Map).cast<String, dynamic>(),
      ),
    );
    _guards = {for (final id in targets) id: _context(id)};
    final request = _request;
    final raw = jsonDecode(
      await api.cleanupBatchText(
        requestJson: request,
        apply: false,
        planId: '',
        confirmed: false,
      ),
    ) as Map;
    _check(generation);
    final items = <CleanupBatchItem>[];
    for (final row in (raw['items'] as List).cast<Map>()) {
      final id = row['book_id'] as String;
      var error = row['ready'] == true ? '' : '${row['error']}';
      CleanupImpact? impact;
      if (error.isEmpty) {
        final probe = LegacyCleanupSession(backend, id);
        try {
          final plan = await probe.preview(jsonEncode(row['next_request']));
          // 逐本换算章节修改（CLEAN-104）：能换算的保留；无法换算的列出，由用户决定。
          impact = await probe.impact(plan);
          if (impact.checkpoint) {
            error = cleanupCheckpointMessage;
          } else if (impact.edits > 0) {
            _impacts[id] = impact;
          }
        } catch (_) {
          error = '清理规则与现有章节编辑或保留选择冲突，请先在本书检查。';
        } finally {
          probe.dispose();
        }
      }
      _check(generation);
      if (error.isEmpty) {
        _targets[id] = _TargetPreview(
          row['source_id'] as String,
          row['revision'] as int,
          jsonEncode(row['next_request']),
          row['cleanup_plan_id'] as String,
        );
      }
      items.add(
        CleanupBatchItem(
          id,
          row['change_count'] as int? ?? 0,
          row['candidate_count'] as int? ?? 0,
          error,
          List.unmodifiable([
            for (final sample in (row['samples'] as List? ?? []).cast<Map>())
              '源行 ${sample['source_line']}：${sample['before']} → ${sample['after'] ?? '删除'}',
          ]),
          editsKept: error.isEmpty && impact != null
              ? impact.edits - impact.skipped.length
              : 0,
          skippedEdits: error.isEmpty && impact != null
              ? impact.skipped
              : const [],
        ),
      );
    }
    _planId = raw['plan_id'] as String;
    final plan = CleanupBatchPreview(List.unmodifiable(items));
    _pending = plan;
    return plan;
  }

  @override
  bool isCurrent(CleanupBatchPreview plan) =>
      identical(plan, _pending) && plan.ready && _valid(_generation) && _idle;

  @override
  bool canRead(CleanupBatchPreview plan, String bookId) =>
      identical(plan, _pending) &&
      _targets.containsKey(bookId) &&
      _valid(_generation) &&
      _idle;

  @override
  Future<CleanupBatchDifferencePage> differences(
    CleanupBatchPreview plan,
    String bookId, {
    int offset = 0,
  }) async {
    final generation = _generation;
    _check(generation);
    final target = _targets[bookId];
    if (!identical(plan, _pending) || target == null || offset < 0) {
      throw const FormatException('差异已过期或该书预览失败，请重新预览。');
    }
    final request = decodeCleanup(target.request)..['preview_offset'] = offset;
    final raw = jsonDecode(
      await api.previewRepairPlanText(
        sourceId: target.sourceId,
        revision: target.revision,
        selectedJson: jsonEncode(request),
      ),
    ) as Map;
    _check(generation);
    if (!identical(plan, _pending) || raw['plan_id'] != target.planId) {
      throw const FormatException('差异已过期，请重新预览。');
    }
    return CleanupBatchDifferencePage(
      offset,
      raw['change_count'] as int,
      raw['candidate_count'] as int,
      List.unmodifiable(
        (raw['actions'] as List).cast<Map>().map(
          (v) => CleanupChange(
            v['source_line'] as int,
            v['source_end_line'] as int,
            v['step_index'] as int,
            v['before'] as String,
            v['after'] as String?,
            v['reason'] as String,
            v['truncated'] == true,
          ),
        ),
      ),
      List.unmodifiable(
        (raw['candidates'] as List).cast<Map>().map(
          (v) => CleanupCandidate(
            v['source_line'] as int,
            v['text'] as String,
            v['selectable'] == true,
            v['selected'] == true,
            v['truncated'] == true,
          ),
        ),
      ),
    );
  }

  @override
  Future<void> apply(
    CleanupBatchPreview plan, {
    Set<String> dropEdits = const {},
  }) async {
    final prepared = await prepareCommit(plan, dropEdits: dropEdits);
    prepared.validate();
    backend.change(prepared.publish);
  }

  Future<PreparedStateChange> prepareCommit(
    CleanupBatchPreview plan, {
    Set<String> dropEdits = const {},
  }) async {
    if (!isCurrent(plan)) throw const FormatException('请重新预览全部目标书。');
    final undecided = plan.items.where(
      (item) => item.needsDecision && !dropEdits.contains(item.bookId),
    );
    if (undecided.isNotEmpty) {
      throw FormatException(
        '有 ${undecided.length} 本书的章节修改无法换算到清理后的文本。'
        '请逐本选择“放弃这些修改并清理”或“不清理这本书”。',
      );
    }
    final impacts = Map.of(_impacts);
    final generation = _generation;
    _pending = null;
    final raw = jsonDecode(
      await api.cleanupBatchText(
        requestJson: _request,
        apply: true,
        planId: _planId,
        confirmed: true,
      ),
    ) as Map;
    _check(generation);
    final histories = <String, Map<String, dynamic>>{};
    final settings = <String, Map<String, dynamic>>{};
    for (final row in (raw['drafts'] as List).cast<Map>()) {
      final id = row['book_id'] as String;
      final history = (row['history'] as Map).cast<String, dynamic>();
      histories[id] = history;
      settings[id] =
          ((history['history'] as List)[history['cursor'] as int] as Map)
              .cast<String, dynamic>();
    }
    if (raw['applied'] != true ||
        histories.length != _guards.length ||
        !_guards.keys.every(histories.containsKey)) {
      throw const FormatException('批量结果不完整，本批未采用。');
    }
    // 有章节修改的书：逐本换算到新的清理结果上，结果须与预览时一致。
    final rebased =
        <String, ({int kept, int skipped, Map<String, dynamic> history})>{};
    for (final entry in impacts.entries) {
      final id = entry.key;
      final moved = await backend.manuscript.rebaseEffectiveHistory(id, {
        ...backend.manuscript.effectiveBase(id),
        'cleanup': settings[id],
      });
      _check(generation);
      // 只会比预览放弃得更少（清理变回上一步依据时直接退回原来那一步）。
      if (moved == null || moved.skipped > entry.value.skipped.length) {
        throw const FormatException('章节修改的换算结果与预览时不一致，本批未采用，请重新预览。');
      }
      rebased[id] = (
        kept: moved.kept,
        skipped: moved.skipped,
        history: moved.history,
      );
    }
    var consumed = false;
    return PreparedStateChange(
      () {
        _check(generation);
        if (consumed) throw const FormatException('清理计划已采用，请重新预览。');
      },
      () {
        consumed = true;
        backend.cleanup.histories.addAll(histories);
        backend.cleanup.drafts.addAll(settings);
        for (final id in histories.keys) {
          final moved = rebased[id];
          if (moved != null) backend.manuscript.effectiveHistories[id] = moved.history;
          backend.cleanup.historyStatus[id] =
              '已采用批量清理规则，可逐书撤销；另存项目保留。'
              '${moved == null ? '' : '${moved.kept} 处章节修改已换算到清理后的文本${moved.skipped > 0 ? '，放弃 ${moved.skipped} 处' : ''}。'}';
        }
      },
    );
  }

  @override
  void cancel() {
    _generation++;
    _pending = null;
    _targets.clear();
    _impacts.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    backend.removeListener(_refresh);
    super.dispose();
  }
}

class _TargetPreview {
  const _TargetPreview(this.sourceId, this.revision, this.request, this.planId);
  final String sourceId, request, planId;
  final int revision;
}
