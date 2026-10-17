import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
  @override
  ValueListenable<RuleStatisticsState> get state => _state;

  Map<String, dynamic> _input() => {
    'publication': backend.publicationRequest(bookId),
    'cleanup_pipeline': resolveCleanupRules(
      backend.globalConfiguration,
      bookDraft: backend.cleanup.drafts[bookId],
    ).pipeline,
  };

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
