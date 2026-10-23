import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';

import '../application/cleanup_rule_resolution.dart';
import '../application/rule_catalog_service.dart';
import '../prototype/prototype_state.dart';
import '../src/rust/api.dart' as api;

class LegacyRuleCatalogService implements RuleCatalogService {
  LegacyRuleCatalogService(this.backend, this.bookId) {
    backend.addListener(_changed);
  }
  final PrototypeState backend;
  final String bookId;
  final _state = ValueNotifier(
    const RuleStatisticsState(RuleStatisticsPhase.idle),
  );
  bool _disposed = false, _running = false, _cancelled = false, _stale = false;
  int? _jobId;
  String? _guard;
  final _plans = <String, Map<String, dynamic>>{};
  @override
  ValueListenable<RuleStatisticsState> get state => _state;

  Map<String, dynamic> _input() => {
    'publication': backend.publicationRequest(bookId),
    'cleanup_pipeline': resolveCleanupRules(
      backend.globalConfiguration,
      bookDraft: backend.cleanup.drafts[bookId],
      pendingPipeline:
          backend.production.drafts[bookId]?.ruleOptions['cleanup_pipeline']
              as List?,
    ).pipeline,
    'reference_catalog': backend.savedReferenceCatalog(bookId),
    'preflight': _preflightCounts(),
  };

  Map<String, int> _preflightCounts() {
    final settings = backend.production.settings(bookId);
    final language = settings['language'] as String? ?? '';
    final cover = settings['cover_path'] as String? ?? '';
    final format = backend.globalConfiguration['output_format'];
    final engine =
        backend.globalConfiguration[format == 'KFX'
                ? 'kfx_converter'
                : 'kindle_converter']
            as String?;
    return {
      'title': (settings['title'] as String).trim().isEmpty ? 1 : 0,
      'language': language.isEmpty || language == 'und' ? 1 : 0,
      'cover': cover.isEmpty || !File(cover).existsSync() ? 1 : 0,
      'imported_images':
          (backend.production.importedResourcesFor(bookId)?['pending_images']
                      as List? ??
                  [])
              .length,
      if (format == 'EPUB') 'converter': 0,
      if (format != null && format != 'EPUB' && engine != null)
        'converter': File(engine).existsSync() ? 0 : 1,
    };
  }

  Map<String, dynamic> _toggleInput(String scope) => {
    ..._input(),
    'book_id': bookId,
    'scope': scope,
    'base': backend.manuscript.effectiveBase(bookId),
    'effective_history': backend.manuscript.effectiveHistories[bookId],
    'production_history': backend.production.histories[bookId],
    'cleanup_draft': backend.cleanup.drafts[bookId],
    'configuration': backend.globalConfiguration,
    'history': backend.production.drafts[bookId]?.ruleToggleHistory,
    'membership': backend.bookMembership[bookId],
    'removal_epoch': backend.removalEpoch,
  };

  @override
  Future<Map<String, dynamic>> settings({String scope = 'book'}) async =>
      Map<String, dynamic>.from(await _call('settings', _toggleInput(scope)));

  @override
  Future<Map<String, dynamic>> previewToggles(
    List<Map<String, dynamic>> changes, {
    String scope = 'book',
  }) async {
    if (_disposed || !_available) throw const FormatException('当前无法预览规则');
    final input = (jsonDecode(jsonEncode(_toggleInput(scope))) as Map)
        .cast<String, dynamic>();
    final result = Map<String, dynamic>.from(
      await _call('preview_toggles', {...input, 'changes': changes}),
    );
    if (!const DeepCollectionEquality().equals(input, _toggleInput(scope))) {
      throw const FormatException('书稿或设置已变化，请重新预览。');
    }
    _plans.clear();
    _plans[result['plan_id'] as String] = {
      'input': input,
      'changes': jsonDecode(jsonEncode(changes)),
    };
    return result;
  }

  @override
  Future<void> applyToggles(String planId) async {
    final plan = _plans[planId];
    if (plan == null || _disposed || !_available) {
      throw const FormatException('计划已过期，请重新预览。');
    }
    final input = plan['input'] as Map<String, dynamic>;
    final scope = input['scope'] as String;
    void validate() {
      if (!const DeepCollectionEquality().equals(input, _toggleInput(scope))) {
        throw const FormatException('书稿或设置已变化，请重新预览。');
      }
    }

    validate();
    final result = await _call('apply_toggles', {
      ..._toggleInput(scope),
      'changes': plan['changes'],
      'plan_id': planId,
    });
    validate();
    if (scope == 'global') {
      if (!await backend.saveGlobalConfigurationPatch({
        'rule_defaults': result['defaults'],
      })) {
        throw const FormatException('新书默认保存失败，未应用。');
      }
    } else {
      final snapshot = Map<String, dynamic>.from(result['snapshot'] as Map);
      final book = backend.shelf.books.firstWhere((b) => b.id == bookId);
      final draft = backend.production.draftFromProduction(
        book,
        snapshot['settings'] as Map,
        backend.production.drafts[bookId]?.epubResources,
      );
      final history = Map<String, dynamic>.from(result['history'] as Map);
      snapshot['settings'] = backend.production.valuesOf(draft);
      (history['states'] as List).last['after'] = snapshot;
      draft.ruleToggleHistory = history;
      final effective = (snapshot['effective_history'] as Map?)
          ?.cast<String, dynamic>();
      final production = (snapshot['production_history'] as Map?)
          ?.cast<String, dynamic>();
      validate();
      backend.change(() {
        backend.production.drafts[bookId] = draft;
        if (effective == null) {
          backend.manuscript.effectiveHistories.remove(bookId);
        } else {
          backend.manuscript.effectiveHistories[bookId] = effective;
        }
        if (production == null) {
          backend.production.histories.remove(bookId);
        } else {
          backend.production.histories[bookId] = production;
        }
      });
    }
    _plans.remove(planId);
  }

  /// 历史页调用；三领域一起恢复，后续编辑不匹配时拒绝覆盖。
  Future<void> moveHistory({required bool undo}) async {
    final guard = jsonEncode(_toggleInput('book'));
    final draft = backend.production.drafts[bookId]!;
    final history = (jsonDecode(jsonEncode(draft.ruleToggleHistory)) as Map)
        .cast<String, dynamic>();
    final cursor = history['cursor'] as int;
    final states = history['states'] as List;
    final index = undo ? cursor : cursor + 1;
    if (index < 1 || index >= states.length) {
      throw const FormatException('没有可恢复的规则记录。');
    }
    // Rust 校验已应用历史；撤销后留下的重做分支不能误判为仍有修改。
    final result = await _call('restore_toggles', {
      ..._toggleInput('book'),
      'undo': undo,
    });
    if (guard != jsonEncode(_toggleInput('book'))) {
      throw const FormatException('书稿已变化，请重新选择记录。');
    }
    final next = result['snapshot'] as Map;
    final book = backend.shelf.books.firstWhere((b) => b.id == bookId);
    final restored = backend.production.draftFromProduction(
      book,
      next['settings'] as Map,
      draft.epubResources,
    );
    restored.ruleToggleHistory = (result['history'] as Map)
        .cast<String, dynamic>();
    backend.change(() {
      backend.production.drafts[bookId] = restored;
      final effective = next['effective_history'] as Map?;
      if (effective == null) {
        backend.manuscript.effectiveHistories.remove(bookId);
      } else {
        backend.manuscript.effectiveHistories[bookId] = effective
            .cast<String, dynamic>();
      }
      final production = next['production_history'] as Map?;
      if (production == null) {
        backend.production.histories.remove(bookId);
      } else {
        backend.production.histories[bookId] = production
            .cast<String, dynamic>();
      }
    });
  }

  void _publish(
    RuleStatisticsPhase phase, {
    RuleStatisticsSnapshot? result,
    String? reason,
  }) {
    if (!_disposed) {
      _state.value = RuleStatisticsState(phase, result: result, reason: reason);
    }
  }

  Future<Map> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    return jsonDecode(
      await api.productionBatchText(
        requestJson: jsonEncode({
          'op': 'rule_catalog',
          'action': action,
          ...fields,
        }),
        apply: false,
        planId: '',
        confirmed: false,
      ),
    ) as Map;
  }

  bool get _available =>
      !backend.projectBusy &&
      backend.shelf.books.any((b) => b.id == bookId && !b.isDemo);
  void _changed() {
    if (_disposed || _guard == null) return;
    if (!_available || jsonEncode(_input()) != _guard) {
      _stale = true;
      if (_running) {
        unawaited(cancel());
      } else {
        _publish(RuleStatisticsPhase.stale);
      }
    }
  }

  @override
  Future<List<RuleDescriptor>> catalog() async {
    final data = await _call('catalog');
    return List.unmodifiable(
      (data['rules'] as List).cast<Map>().map(RuleDescriptor.fromJson),
    );
  }

  @override
  Future<RuleStatisticsSnapshot?> request() async {
    if (_disposed || _running || !_available) throw StateError('当前无法开始规则统计');
    _running = true;
    _cancelled = false;
    _stale = false;
    final input = _input();
    _guard = jsonEncode(input);
    _publish(RuleStatisticsPhase.running);
    try {
      var job = await _call('start', input);
      _jobId = job['job_id'] as int;
      var cancellationSent = false;
      while (job['phase'] == 'running' || job['phase'] == 'cancelling') {
        if (_cancelled && !cancellationSent) {
          await _call('cancel', {'job_id': _jobId});
          cancellationSent = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        job = await _call('poll', {'job_id': _jobId});
      }
      _changed();
      if (_cancelled || job['phase'] == 'cancelled') {
        _publish(
          _stale ? RuleStatisticsPhase.stale : RuleStatisticsPhase.cancelled,
        );
        return null;
      }
      if (job['phase'] == 'failed') {
        _publish(
          RuleStatisticsPhase.failed,
          reason: (job['error'] as Map)['reason'] as String,
        );
        return null;
      }
      final result = RuleStatisticsSnapshot.fromJson(job['result'] as Map);
      _publish(RuleStatisticsPhase.completed, result: result);
      return result;
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      _publish(
        RuleStatisticsPhase.failed,
        reason: detail['next_action'] as String,
      );
      return null;
    } finally {
      final id = _jobId;
      _jobId = null;
      if (id != null) await _call('release', {'job_id': id});
      _running = false;
      // 释放句柄期间书稿或设置变了（V63 修正）：cancel() 已把状态设为“取消中”，
      // 但计算其实已经结束，这里补发最终状态，否则会一直停在“取消中”。
      if (_state.value.phase == RuleStatisticsPhase.cancelling) {
        _publish(
          _stale ? RuleStatisticsPhase.stale : RuleStatisticsPhase.cancelled,
        );
      }
    }
  }

  @override
  Future<void> cancel() async {
    if (!_running) return;
    _cancelled = true;
    _publish(RuleStatisticsPhase.cancelling);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    backend.removeListener(_changed);
    unawaited(cancel());
    _state.dispose();
  }
}
