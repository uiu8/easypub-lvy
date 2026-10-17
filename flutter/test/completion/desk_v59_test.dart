import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/manual_note_service.dart';
import 'package:easypub_desktop/application/rule_catalog_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('CH-277：真实 DLL 规则目录、只读统计、取消、缓存和失效', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v59-rules-'))
        .absolute
        .path;
    final backend = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: backend);
    final evidence = <String, Object?>{};
    try {
      await library.load();
      expect(await library.savePatch({'check_after_import': false}), true);
      final source = File('$root/规则混合样书.txt')
        ..writeAsStringSync(
          '第一章 开始\r\n正文①和[2]。\r\n***\r\n【系统提示一】\r\n【系统提示二】\r\n'
          '床前明月光，疑是地上霜。\r\n春风又绿江南岸，明月何时照我还。\r\n——作者\r\n'
          '①第一条注释。\r\n注2：第二条注释。\r\n广告：样书\r\n'
          '${List.filled(66, '行尾有空白。  \r\n').join()}'
          '第三章 后来\n第三章 后来\n尾段正文。\n第五章 结尾\n结尾正文。\n',
        );
      final bytes = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = backend.currentId;
      final layout = library.openLayout(id);
      await layout.apply(
        await layout.preview({
          'scene_break_style': 'off',
          'system_block_style': 'off',
          'verse_block_style': 'off',
          'note_style': 'off',
        }),
      );
      final notes = library.openManualNotes(id);
      final chapters = library.openChapters(id);
      final tree = await chapters.read(0);
      final noteSnapshot = await notes.list();
      final position = await notes.resolvePosition(
        noteSnapshot,
        entryId: tree.nodes.last.id,
        line: 1,
        utf16Start: 2,
        utf16End: 2,
      );
      await notes.confirm(
        await notes.previewAdd(
          noteSnapshot,
          ManualNoteDraft.newText(position, '自拟注释，用于只读统计。'),
        ),
      );
      notes.dispose();
      final service = library.openRuleCatalog(id);
      final states = <String>[];
      service.state.addListener(
        () => states.add(service.state.value.phase.name),
      );
      final catalog = await service.catalog();
      expect(catalog, hasLength(94));
      expect(catalog.map((r) => r.id).toSet(), hasLength(catalog.length));
      expect(
        catalog.singleWhere((r) => r.id == 'layout.manual_note').category,
        'manual',
      );
      final project = File('$root/只读验证.easypub.json');
      expect(await backend.saveProjectOutcome(project.path), true);
      final projectBytes = project.readAsBytesSync();
      final inputBefore = jsonEncode(backend.publicationRequest(id));
      final historyBefore = jsonEncode(backend.production.histories);
      final cancelled = service.request();
      await service.cancel();
      expect(await cancelled, isNull);
      expect(service.state.value.phase, RuleStatisticsPhase.cancelled);
      final result = (await service.request())!;
      for (final pair in <String, int>{
        'layout.scene': 1,
        'layout.system': 1,
        'layout.verse': 1,
        'layout.verse.five': 1,
        'layout.verse.seven': 1,
        'layout.verse.attribution': 1,
        'layout.note': 2,
        'layout.note.circled': 1,
        'layout.note.bracket': 1,
        'layout.manual_note': 1,
        'layout.manual_note.new': 1,
        'cleanup.trim_trailing_spaces': 66,
        'cleanup.site_notices': 1,
        'check.duplicate_title': 1,
        'check.number_gap': 2,
      }.entries) {
        expect(result.rules[pair.key]!.status, 'complete', reason: pair.key);
        expect(result.rules[pair.key]!.count, pair.value, reason: pair.key);
      }
      expect(result.rules['layout.system']!.enabled, false);
      expect(
        result.rules['layout.system']!.locations.single.entryId,
        tree.nodes.first.id,
      );
      expect(result.rules['layout.system']!.locations.single.firstLine, 3);
      expect(
        result.rules['check.number_gap']!.locations.every(
          (l) => l.heading && l.firstLine == 0,
        ),
        true,
      );
      final trailing = result.rules['cleanup.trim_trailing_spaces']!;
      expect(trailing.locations, hasLength(50));
      expect(trailing.changedRanges.single.first, 12);
      expect(trailing.changedRanges.single.last, 77);
      final cached = (await service.request())!;
      expect(cached.cacheHit, true);
      expect(cached.configFingerprint, result.configFingerprint);
      expect(project.readAsBytesSync(), projectBytes);
      expect(source.readAsBytesSync(), bytes);
      expect(jsonEncode(backend.publicationRequest(id)), inputBefore);
      expect(jsonEncode(backend.production.histories), historyBefore);
      evidence['mixed'] = {
        'rules': catalog.length,
        'readonly': true,
        'states': states,
        'cache_hit': cached.cacheHit,
        'counts': {for (final r in result.rules.values) r.id: r.count},
        'first_ms': result.elapsedMilliseconds,
      };
      // The manual-note edit advanced the shared production history; refresh the layout editor.
      expect(layout.saved['verse_block_style'], 'off');
      await layout.apply(await layout.preview({'verse_block_style': 'center'}));
      expect(service.state.value.phase, RuleStatisticsPhase.stale);
      final changed = (await service.request())!;
      expect(changed.cacheHit, false);
      expect(changed.configFingerprint, isNot(result.configFingerprint));
      expect(changed.rules['layout.verse']!.enabled, true);
      service.dispose();
      layout.dispose();

      final performance = <Object?>[];
      for (final env in [
        'EASYPUB_RULES_PERF_SOURCE',
        'EASYPUB_RULES_PERF_CHAPTERS_SOURCE',
      ]) {
        final path = Platform.environment[env];
        if (path == null) continue;
        expect((await library.importFiles([path])).single.succeeded, true);
        final stats = library.openRuleCatalog(backend.currentId);
        final probe = stats.request();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final cancelWatch = Stopwatch()..start();
        await stats.cancel();
        expect(await probe, isNull);
        expect(stats.state.value.phase, RuleStatisticsPhase.cancelled);
        final cancelMs = cancelWatch.elapsedMicroseconds / 1000;
        var ticks = 0;
        final timer = Timer.periodic(
          const Duration(milliseconds: 10),
          (_) => ticks++,
        );
        final watch = Stopwatch()..start();
        final first = await stats.request();
        final firstMs = watch.elapsedMicroseconds / 1000;
        timer.cancel();
        expect(first, isNotNull, reason: stats.state.value.reason);
        expect(first!.cacheHit, false, reason: '被取消的计算不能写入缓存');
        expect(first.rules.values.where((r) => r.status == 'failed'), isEmpty);
        final cachedMs = <double>[];
        for (var i = 0; i < 3; i++) {
          watch.reset();
          expect((await stats.request())!.cacheHit, true);
          cachedMs.add(watch.elapsedMicroseconds / 1000);
        }
        expect(ticks, greaterThan(0), reason: '等待后台时 Dart 计时器仍可运行');
        performance.add({
          'source': path,
          'bytes': first.byteLength,
          'chapters': first.chapterCount,
          'lines': first.lineCount,
          'worker_ms': first.elapsedMilliseconds,
          'first_wall_ms': firstMs,
          'cached_wall_ms': cachedMs,
          'timer_ticks': ticks,
          'cancel_ms': cancelMs,
        });
        stats.dispose();
      }
      evidence['performance'] = performance;
      File(
        '$root/verification.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
      // ignore: avoid_print
      print('V59 验收证据：$root/verification.json');
    } finally {
      library.dispose();
      backend.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
