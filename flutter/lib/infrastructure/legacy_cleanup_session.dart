import '../application/cleanup_rule_resolution.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../application/cleanup_service.dart';
import '../prototype/prototype_state.dart';
import '../prototype/txt_import.dart';
import '../src/rust/api.dart' as api;

class LegacyCleanupSession extends ChangeNotifier
    implements
        CleanupSession,
        CleanupContextSession,
        PairedCleanupContextSession {
  LegacyCleanupSession(this.backend, this.bookId) {
    _guard = _context();
    backend.addListener(_refresh);
  }
  final PrototypeState backend;
  final String bookId;
  ResolvedCleanupRules get resolvedRules => resolveCleanupRules(
    backend.globalConfiguration,
    bookDraft: backend.cleanup.drafts[bookId],
    pendingPipeline:
        backend.production.drafts[bookId]?.ruleOptions['cleanup_pipeline']
            as List?,
  );
  late String _guard;
  int _generation = 0;
  bool _disposed = false;
  _Pending? _pending;
  String _context() =>
      backend.shelf.books.any((b) => b.id == bookId && !b.isDemo)
      ? jsonEncode([
          backend.publicationContext(bookId),
          resolvedRules.fingerprint,
          backend.cleanup.histories[bookId],
        ])
      : '';
  void _refresh() {
    final next = _context();
    if (next == _guard) return;
    _guard = next;
    _pending = null;
    notifyListeners();
  }

  @override
  Listenable get changes => this;

  @override
  bool isInspectionCurrent(CleanupInspection inspection) =>
      !_disposed && inspection.guard == _context();

  @override
  Future<CleanupInspection> recheck({int offset = 0}) async {
    final generation = _generation;
    final guard = _context(), source = _source;
    _validate(guard, generation);
    final base = backend.manuscript.effectiveBase(bookId);
    final raw = jsonDecode(
      await api.effectiveStructureText(
        sourceId: source.sourceId,
        revision: source.revision,
        settingsJson: base['structure'] == null
            ? ''
            : jsonEncode(base['structure']),
        selectedJson: jsonEncode({
          'kind': 'publication',
          'manual': base['manual'],
          'cleanup': base['cleanup'],
          'post_edits': backend.manuscript.effectiveSelection(bookId),
          'cleanup_check': {
            'pipeline': resolvedRules.pipeline,
            'offset': offset,
          },
        }),
        offset: 0,
      ),
    ) as Map;
    _validate(guard, generation);
    final check = raw['cleanup_check'] as Map;
    final report = check['report'] as Map;
    final checkedRules = (check['checks'] as List).cast<String>();
    return CleanupInspection(
      guard,
      check['composition_id'] as String,
      offset,
      report['change_count'] as int,
      report['candidate_count'] as int,
      List.unmodifiable([
        for (final row in (report['actions'] as List).cast<Map>())
          '有效稿第 ${row['source_line']} 行 · 基础清理变更\n前：${jsonEncode(row['before'])}\n后：${row['after'] == null ? '排除此行' : jsonEncode(row['after'])}${row['truncated'] == true ? '\n长文本仅显示节选' : ''}',
        for (final row in (report['candidates'] as List).cast<Map>())
          '有效稿第 ${row['source_line']} 行 · 广告候选，需人工判断\n${row['text']}${row['truncated'] == true ? '\n长文本仅显示节选' : ''}',
      ]),
      findings: List.unmodifiable([
        for (final row in (report['actions'] as List).cast<Map>())
          CleanupInspectionFinding(
            row['source_line'] as int,
            row['original_source_line'] as int?,
            checkedRules[row['step_index'] as int],
            row['before'] as String,
            row['after'] as String?,
            row['truncated'] == true,
            false,
          ),
        for (final row in (report['candidates'] as List).cast<Map>())
          CleanupInspectionFinding(
            row['source_line'] as int,
            row['original_source_line'] as int?,
            'remove_ad_lines',
            row['text'] as String,
            null,
            row['truncated'] == true,
            row['selectable'] == true,
          ),
      ]),
    );
  }

  void _finding(
    CleanupInspection inspection,
    CleanupInspectionFinding finding,
  ) {
    if (!isInspectionCurrent(inspection) ||
        !inspection.findings.contains(finding) ||
        finding.originalLine == null) {
      throw const FormatException('复查已过期或该位置不能唯一映射到原稿，请重新复查。');
    }
  }

  @override
  Future<String> previewSource(
    CleanupPreview preview,
    CleanupChange change,
  ) async {
    if (!isCurrent(preview)) throw const FormatException('清理结果已过期');
    final source = _source;
    final text = await api.readSourcePageText(
      sourceId: source.sourceId,
      revision: source.revision,
      lineIndex: (change.line - 4).clamp(0, 0x7fffffff),
      utf8Column: 0,
      limit: 9,
    );
    if (!isCurrent(preview)) throw const FormatException('清理结果已过期');
    return text.split('\n').skip(1).join('\n');
  }

  @override
  Future<Map<String, dynamic>> pairedContext(
    CleanupPreview preview,
    CleanupChange change, {
    int offset = 0,
    int? regionLine,
    bool stage = false,
    int charOffset = 0,
  }) async {
    if (!isCurrent(preview) ||
        !(stage ? preview.stages : preview.actions).contains(change)) {
      throw const FormatException('清理结果已过期，请重新预览。');
    }
    final source = _source;
    final raw = await api.previewRepairPlanText(
      sourceId: source.sourceId,
      revision: source.revision,
      selectedJson: jsonEncode({
        'kind': 'cleanup_context',
        'region_line': ?regionLine,
        if (stage) 'step_index': change.step,
        'char_offset': charOffset,
        'request': jsonDecode(preview.request),
        'first': change.line,
        'last': change.end,
        'offset': offset,
      }),
    );
    final result = (jsonDecode(raw) as Map).cast<String, dynamic>();
    if (!isCurrent(preview) || result['plan_id'] != preview.id) {
      throw const FormatException('清理结果已过期，请重新预览。');
    }
    return result;
  }

  @override
  Future<String> inspectionSource(
    CleanupInspection inspection,
    CleanupInspectionFinding finding,
  ) async {
    _finding(inspection, finding);
    final generation = _generation, source = _source;
    final text = await api.readSourcePageText(
      sourceId: source.sourceId,
      revision: source.revision,
      lineIndex: (finding.originalLine! - 3).clamp(0, 0x7fffffff),
      utf8Column: 0,
      limit: 12,
    );
    _validate(inspection.guard, generation);
    _finding(inspection, finding);
    return text.split('\n').skip(1).join('\n');
  }

  @override
  Future<CleanupPreview> previewInspectionRemoval(
    CleanupInspection inspection,
    CleanupInspectionFinding finding,
  ) async {
    _finding(inspection, finding);
    if (finding.kind != 'remove_ad_lines' || !finding.selectable) {
      throw const FormatException('此项不是可排除的广告候选。');
    }
    final request = decodeCleanup(settings);
    final line = finding.originalLine!;
    if ((request['skip_lines'] as List? ?? []).contains(line)) {
      throw const FormatException('此原稿行已明确保留，请先在清理面板调整保留选择。');
    }
    final pipeline = (request['pipeline'] as List).cast<Map>();
    if (!pipeline.any(
      (step) =>
          cleanupBase(step.cast<String, dynamic>())['kind'] ==
              'remove_ad_lines' &&
          step['enabled'] != false,
    )) {
      request['pipeline'] = [
        ...pipeline,
        {'kind': 'remove_ad_lines'},
      ];
    }
    request['remove_lines'] = {
      ...(request['remove_lines'] as List? ?? []).cast<int>(),
      line,
    }.toList();
    return preview(jsonEncode(request));
  }

  @override
  String get settings {
    final value = Map<String, dynamic>.from(
      backend.cleanup.drafts[bookId] ?? {'kind': 'cleanup'},
    );
    value['pipeline'] = resolvedRules.pipeline;
    value.remove('rules');
    return jsonEncode(value);
  }

  Map<String, dynamic> get _history =>
      backend.cleanup.histories[bookId] ??
      {
        'source_id': _source.sourceId,
        'source_revision': _source.revision,
        'history': [
          null,
          if (backend.cleanup.drafts[bookId] != null)
            backend.cleanup.drafts[bookId],
        ],
        'cursor': backend.cleanup.drafts[bookId] == null ? 0 : 1,
      };
  ImportedTxt get _source => backend.shelf.books
      .firstWhere((b) => b.id == bookId && !b.isDemo)
      .source!;
  @override
  bool get canUndo => (_history['cursor'] as int) > 0;
  @override
  bool get canRedo =>
      (_history['cursor'] as int) + 1 < (_history['history'] as List).length;
  @override
  bool isCurrent(CleanupPreview preview) =>
      !_disposed &&
      identical(_pending?.preview, preview) &&
      preview.guard == _context();
  void _validate(String guard, int generation) {
    if (_disposed ||
        generation != _generation ||
        guard != _context() ||
        guard.isEmpty) {
      throw const FormatException('书稿或清理设置已变化，请重新检测。');
    }
  }

  @override
  Future<CleanupPreview> preview(String request, {int offset = 0}) async {
    final previous = _pending;
    final generation = ++_generation;
    _pending = null;
    final guard = _context(), source = _source;
    final selected = decodeCleanup(request);
    selected['protected_lines'] = <int>{
      ...backend.cleanup.boundaryLines(bookId),
      ...((selected['protected_lines'] as List?) ?? []).cast<int>(),
    }.toList();
    selected['preview_offset'] = offset;
    final raw = jsonDecode(
      await api.previewRepairPlanText(
        sourceId: source.sourceId,
        revision: source.revision,
        selectedJson: jsonEncode(selected),
      ),
    ) as Map;
    _validate(guard, generation);
    selected['preview_offset'] = 0;
    final frozen = jsonEncode(selected);
    late Map history;
    _Pending? reuse;
    if (previous != null &&
        previous.preview.guard == guard &&
        previous.preview.request == frozen) {
      history = previous.history;
      reuse = previous;
    } else {
      history = jsonDecode(
        await api.editCleanupDraft(
          sourceId: source.sourceId,
          revision: source.revision,
          draftJson: jsonEncode(_history),
          commandJson: jsonEncode({'op': 'set', 'request': selected}),
        ),
      ) as Map;
      _validate(guard, generation);
    }
    final plan = CleanupPreview(
      frozen,
      guard,
      raw['plan_id'] as String,
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
      stepCounts: {
        for (final e in (raw['step_counts'] as Map? ?? {}).entries)
          int.parse(e.key.toString()): e.value as int,
      },
      stageTotal: raw['stage_count'] as int,
      stages: List.unmodifiable(
        (raw['stage_actions'] as List).cast<Map>().map(
          (v) => CleanupChange(
            v['source_line'] as int,
            v['source_end_line'] as int,
            v['step_index'] as int,
            v['before'] as String,
            v['after'] as String?,
            v['reason'] as String? ?? 'rule_step',
            v['truncated'] == true,
          ),
        ),
      ),
    );
    _pending = _Pending(plan, history.cast<String, dynamic>())
      ..impact = reuse?.impact;
    return plan;
  }

  /// Composes the cleaned book once: chapter edits are rebased from the
  /// cleanup they were made on, and the effective check counts the issues.
  /// Kept out of [preview] so the diff shows without waiting for it.
  @override
  Future<CleanupImpact> impact(CleanupPreview preview) async {
    final pending = _pending;
    if (pending == null || !isCurrent(preview)) {
      throw const FormatException('方案已过期，请重新检测。');
    }
    if (pending.impact != null) return pending.impact!;
    final generation = _generation;
    final guard = preview.guard, source = _source;
    final base = backend.manuscript.effectiveBase(bookId);
    final edits = backend.manuscript.effectiveSelection(bookId);
    final history = backend.manuscript.effectiveHistories[bookId];
    final total = (edits?['actions'] as List?)?.length ?? 0;
    CleanupImpact result;
    try {
      final composition = jsonDecode(
        await api.effectiveStructureText(
          sourceId: source.sourceId,
          revision: source.revision,
          settingsJson: base['structure'] == null
              ? ''
              : jsonEncode(base['structure']),
          selectedJson: jsonEncode({
            'kind': 'publication',
            'manual': base['manual'],
            'cleanup': decodeCleanup(preview.request),
            'post_edits': edits,
            if (edits != null && history != null)
              'rebase_from': {
                'cleanup':
                    history['history'][history['cursor']]['base']['cleanup'],
                // 章节修改基于检查点时带上原始操作，才能分两段换算（CLEAN-105）。
                'checkpoint_root': ?backend.manuscript.effectiveCheckpointRoot(
                  bookId,
                ),
              },
            'effective_check': {'offset': 0},
          }),
          offset: 0,
        ),
      ) as Map;
      final rebase = composition['post_edit_rebase'] as Map?;
      result = CleanupImpact(
        chapterIssues:
            composition['effective_check']['report']['diagnostic']['review_total']
                as int,
        edits: total,
        skipped: List.unmodifiable([
          for (final s in (rebase?['skipped'] as List? ?? const []).cast<Map>())
            CleanupSkippedEdit(
              s['index'] as int,
              describeEffectiveAction(s['action'] as Map),
              describeRebaseReason(s['reason'] as String),
            ),
        ]),
      );
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      if (detail['next_action'] == 'rebase_checkpoint') {
        result = CleanupImpact(edits: total, checkpoint: true);
      } else if (detail['next_action'] ==
          'cleanup_would_remove_structural_heading') {
        throw const FormatException('这次清理会删除章节标题所在的行。请在该行上保留原文，或调整规则后重新检测。');
      } else {
        rethrow;
      }
    }
    _validate(guard, generation);
    if (identical(_pending, pending)) pending.impact = result;
    return result;
  }

  @override
  Future<CleanupReceipt> apply(
    CleanupPreview preview, {
    bool dropSkipped = false,
  }) async {
    void guard() {
      if (!isCurrent(preview) ||
          backend.projectBusy ||
          backend.importing ||
          backend.cleanup.historyBusy) {
        throw const FormatException('方案已过期或项目正在处理，请重新预览。');
      }
    }

    guard();
    final candidate = _pending!;
    final impact = candidate.impact ?? await this.impact(preview);
    if (impact.checkpoint) {
      throw const FormatException(cleanupCheckpointMessage);
    }
    if (impact.skipped.isNotEmpty && !dropSkipped) {
      throw FormatException(
        '有 ${impact.skipped.length} 处章节修改无法换算到清理后的文本，请先确认是否放弃这些修改。',
      );
    }
    guard();
    final cleanup = decodeCleanup(preview.request);
    final rebased = await backend.manuscript.rebaseEffectiveHistory(bookId, {
      ...backend.manuscript.effectiveBase(bookId),
      'cleanup': cleanup,
    });
    // 只会比检测时放弃得更少（清理变回上一步依据时直接退回原来那一步）。
    if (rebased != null && rebased.skipped > impact.skipped.length) {
      throw const FormatException('章节修改的换算结果与检测时不一致，请重新检测。');
    }
    PreparedStateChange? preparedRules;
    final options = backend.production.drafts[bookId]?.ruleOptions;
    if (options?['cleanup_pipeline'] != null) {
      final nextOptions = Map<String, dynamic>.from(options!)
        ..remove('cleanup_pipeline');
      final plan = await backend.production.previewChanges({
        bookId: {
          'op': 'patch',
          'fields': {
            'rule_options': {'op': 'set', 'value': nextOptions},
          },
        },
      });
      preparedRules = await backend.production.prepareCommit(plan);
    }
    // No await between the guard and publication of the validated candidate.
    guard();
    preparedRules?.validate();
    _pending = null;
    backend.change(() {
      backend.cleanup.histories[bookId] = candidate.history;
      backend.cleanup.drafts[bookId] = cleanup;
      preparedRules?.publish();
      if (rebased != null) {
        backend.manuscript.effectiveHistories[bookId] = rebased.history;
      }
      backend.cleanup.historyStatus[bookId] = rebased == null
          ? '清理方案已采用，可撤销；另存项目后保留历史。'
          : '清理方案已采用；${rebased.kept} 处章节修改已换算到清理后的文本'
                '${rebased.skipped > 0 ? '，放弃 ${rebased.skipped} 处' : ''}。可撤销。';
    });
    return CleanupReceipt(
      preview.total,
      preview.candidateTotal,
      impact.chapterIssues ?? 0,
      editsKept: rebased?.kept ?? 0,
      editsDropped: rebased?.skipped ?? 0,
    );
  }

  Future<void> _historyCommand(String op) async {
    cancel();
    if (!await backend.cleanup.editSettings(bookId, {'op': op})) {
      throw FormatException(
        backend.cleanup.historyStatus[bookId] ?? '无法更改清理历史，原设置保留。',
      );
    }
  }

  @override
  Future<void> undo() => _historyCommand('undo');
  @override
  Future<void> redo() => _historyCommand('redo');
  @override
  Future<List<Map<String, dynamic>>> presets() async =>
      (jsonDecode(await api.cleanupPresetsText()) as List)
          .cast<Map>()
          .map((v) => v.cast<String, dynamic>())
          .toList();
  @override
  void cancel() {
    _generation++;
    _pending = null;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    backend.removeListener(_refresh);
    super.dispose();
  }
}

class _Pending {
  _Pending(this.preview, this.history);
  final CleanupPreview preview;
  final Map<String, dynamic> history;
  CleanupImpact? impact;
}
