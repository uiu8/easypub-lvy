import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/application/cleanup_service.dart';

import 'library_removal_test.dart' as fixtures;

void main() {
  test('large cleanup pages reuse validation and history changes cannot revive an old preview', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final (state, library, root) = await fixtures.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final text = '第一章 起\n${('${'正文' * 170}  \n') * 8192}';
    final source = File('$root/长稿.txt')..writeAsStringSync(text);
    expect((await library.importFiles([source.path])).single.succeeded, true);
    final id = state.currentId;
    final session = library.openCleanup(id);
    addTearDown(session.dispose);
    final request = jsonEncode({
      'kind': 'cleanup',
      'pipeline': [
        {'kind': 'trim_trailing_spaces'},
      ],
    });
    final cold = Stopwatch()..start();
    var page = await session.preview(request);
    final coldMs = cold.elapsedMilliseconds;
    final planId = page.id;
    final timings = <int>[];
    for (final offset in [40, 80, 120, 160, 200]) {
      final watch = Stopwatch()..start();
      final previous = page;
      page = await session.preview(request, offset: offset);
      expect(page.id, planId);
      expect(page.actions.first.line, offset + 2);
      expect(session.isCurrent(previous), false);
      final context = await (session as PairedCleanupContextSession)
          .pairedContext(page, page.actions.first);
      expect(context['plan_id'], planId);
      timings.add(watch.elapsedMilliseconds);
    }
    final nativeSource = state.shelf.books
        .firstWhere((b) => b.id == id)
        .source!;
    final measuredRequest = jsonDecode(request) as Map<String, dynamic>;
    (measuredRequest['pipeline'] as List).add({'kind': 'collapse_blank_lines'});
    measuredRequest['protected_lines'] = state
        .cleanup.boundaryLines(id)
        .toList();
    final chain = <String, int>{};
    Future<void> measure(String name, Future<String> Function() work) async {
      final watch = Stopwatch()..start();
      await work();
      chain[name] = watch.elapsedMilliseconds;
    }

    await measure(
      'previewRepairPlanText',
      () => api.previewRepairPlanText(
        sourceId: nativeSource.sourceId,
        revision: nativeSource.revision,
        selectedJson: jsonEncode(measuredRequest),
      ),
    );
    await measure(
      'editCleanupDraft',
      () => api.editCleanupDraft(
        sourceId: nativeSource.sourceId,
        revision: nativeSource.revision,
        draftJson: jsonEncode({
          'source_id': nativeSource.sourceId,
          'source_revision': nativeSource.revision,
          'history': [null],
          'cursor': 0,
        }),
        commandJson: jsonEncode({'op': 'set', 'request': measuredRequest}),
      ),
    );
    final base = state.manuscript.effectiveBase(id);
    await measure(
      'effectiveStructureText',
      () => api.effectiveStructureText(
        sourceId: nativeSource.sourceId,
        revision: nativeSource.revision,
        settingsJson: base['structure'] == null
            ? ''
            : jsonEncode(base['structure']),
        selectedJson: jsonEncode({
          'kind': 'publication',
          'manual': base['manual'],
          'cleanup': measuredRequest,
          'post_edits': state.manuscript.effectiveSelection(id),
          'effective_check': {'offset': 0},
        }),
        offset: 0,
      ),
    );
    await session.apply(page);
    final held = await session.preview(request);
    final other = library.openCleanup(id);
    try {
      await other.undo();
      await other.redo();
    } finally {
      other.dispose();
    }
    expect(session.isCurrent(held), false);
    await expectLater(session.apply(held), throwsFormatException);
    final fresh = await session.preview(request, offset: 40);
    await session.apply(fresh);
    expect(
      (await library.saveProject('$root/cache.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/cache.easypub.json')).succeeded,
      true,
    );
    expect(source.readAsStringSync(), text);
    final evidence = {
      'bytes': utf8.encode(text).length,
      'cold_preview_ms': coldMs,
      'three_stage_two_rule_ms': chain,
      'warm_page_and_context_ms': timings,
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss,
    };
    // Timings are observations, not fixed thresholds on a shared machine.
    // ignore: avoid_print
    print('cleanup76 $evidence');
    File('../artifacts/completion-cleanup76-timing.json')
        .writeAsStringSync(jsonEncode(evidence));
  });
}
