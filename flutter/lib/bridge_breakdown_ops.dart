// 桥接第 2 批测速：各热点调用的跨桥耗时、返回大小与 Dart 解码耗时。
import 'dart:convert';

import 'prototype/prototype_state.dart';
import 'src/rust/api.dart' as api;

typedef _Sample = ({int callUs, int decodeUs, int bytes});

Future<Map<String, Object?>> measureBridgeOperations(
  PrototypeState state,
  String bookId,
  String sourceId,
  int revision,
) async {
  final base = state.manuscript.effectiveBase(bookId);
  final settings = base['structure'] == null
      ? ''
      : jsonEncode(base['structure']);
  Map<String, Object?> full(Map<String, Object?> extra) => {
    'kind': 'publication',
    'manual': base['manual'],
    'cleanup': base['cleanup'],
    'post_edits': state.manuscript.effectiveSelection(bookId),
    ...extra,
  };
  final first = jsonDecode(
    await api.effectiveStructureText(
      sourceId: sourceId,
      revision: revision,
      settingsJson: settings,
      selectedJson: jsonEncode(full({})),
      offset: 0,
    ),
  ) as Map;
  final key = first['composition_key'] as String;
  final total = (first['total'] as num?)?.toInt() ?? 10000;
  Future<String> keyed(Map<String, Object?> extra, int offset) =>
      api.effectiveStructureText(
        sourceId: sourceId,
        revision: revision,
        settingsJson: '',
        selectedJson: jsonEncode({
          'kind': 'publication',
          'composition_key': key,
          ...extra,
        }),
        offset: offset,
      );

  final results = <String, Object?>{};
  Future<void> measure(
    String name,
    Future<_Sample> Function(int i) action,
  ) async {
    try {
      await action(0);
    } on api.ApiError catch (error) {
      results[name] = {'error': api.apiErrorInfo(error: error).nextAction};
      return;
    }
    final calls = <int>[], decodes = <int>[];
    var bytes = 0;
    for (var i = 0; i < 20; i++) {
      final sample = await action(i);
      calls.add(sample.callUs);
      decodes.add(sample.decodeUs);
      if (sample.bytes > bytes) bytes = sample.bytes;
    }
    double p(List<int> values, int index) =>
        ([...values]..sort())[index] / 1000;
    results[name] = {
      'call_p50_ms': p(calls, 9),
      'call_p95_ms': p(calls, 18),
      'decode_p50_ms': p(decodes, 9),
      'decode_p95_ms': p(decodes, 18),
      'max_response_bytes': bytes,
    };
  }

  Future<_Sample> json(Future<String> Function() call) async {
    final watch = Stopwatch()..start();
    final raw = await call();
    final callUs = watch.elapsedMicroseconds;
    watch.reset();
    jsonDecode(raw);
    return (
      callUs: callUs,
      decodeUs: watch.elapsedMicroseconds,
      bytes: utf8.encode(raw).length,
    );
  }

  int at(int i) => (i * 487) % total;
  await measure(
    'tree_page_full_request',
    (i) => json(
      () => api.effectiveStructureText(
        sourceId: sourceId,
        revision: revision,
        settingsJson: settings,
        selectedJson: jsonEncode(full({})),
        offset: at(i),
      ),
    ),
  );
  await measure('tree_page_keyed', (i) => json(() => keyed({}, at(i))));
  await measure(
    'tree_page_with_body',
    (i) => json(
      () => keyed({
        'body_preview': {
          'entry_id': null,
          'offset': 0,
          'select_page': true,
          'focus_page': true,
        },
      }, at(i)),
    ),
  );
  await measure('outline_full', (_) => json(() => keyed({'outline': true}, 0)));
  await measure('outline_typed', (_) async {
    final watch = Stopwatch()..start();
    final outline = await api.effectiveOutline(
      sourceId: sourceId,
      revision: revision,
      compositionKey: key,
    );
    if (outline.nodes.length != outline.total) throw StateError('outline');
    // 类型化结果在跨桥时已解码完毕，界面线程不再解析。
    return (callUs: watch.elapsedMicroseconds, decodeUs: 0, bytes: 0);
  });
  await measure(
    'statistics',
    (_) => json(() => keyed({'statistics': true}, 0)),
  );
  await measure(
    'check_report_page',
    (i) => json(
      () => keyed({
        'effective_check': {'offset': 0},
      }, 0),
    ),
  );
  await measure(
    'check_positions_summary',
    (_) => json(
      () => keyed({
        'response_scope': 'context',
        'effective_check': {
          'offset': 0,
          'positions': {'summary': true, 'entry_id': null},
        },
      }, 0),
    ),
  );
  await measure(
    'effective_draft_inspect',
    (_) => json(
      () => api.editEffectiveDraft(
        sourceId: sourceId,
        revision: revision,
        baseJson: jsonEncode(base),
        draftJson: '',
        commandJson: '{"op":"inspect"}',
      ),
    ),
  );
  await measure('source_lines_typed_200', (i) async {
    final watch = Stopwatch()..start();
    final page = await api.readSourceLines(
      sourceId: sourceId,
      revision: revision,
      lineIndex: i * 5000,
      utf8Column: 0,
      limit: 200,
    );
    if (page.lines.length != 200) throw StateError('source lines');
    return (callUs: watch.elapsedMicroseconds, decodeUs: 0, bytes: 0);
  });
  return results;
}
