import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_book_check_session.dart';
import 'package:easypub_desktop/application/cleanup_rule_resolution.dart';
import 'package:easypub_desktop/application/conversion_snapshot.dart';

/// V19 基线：300 本书的书库刷新一次要多久（docs/38 V19）。
/// 只测量并输出耗时，不设门槛；结果写进证据。默认跳过，运行方法：
/// `$env:EASYPUB_BENCHMARK=1; tools/test_flutter.ps1 -TestPaths test/completion/library_refresh_benchmark_test.dart`
void main() {
  test('300 本书库刷新耗时', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('library-refresh300-')).absolute.path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    final paths = <String>[];
    for (var i = 0; i < 300; i++) {
      final file = File('$root/书$i.txt')
        ..writeAsStringSync(
          '第一章 开始\n${'正文$i。' * 40}\n第二章 后续\n${'后文$i。' * 40}\n',
        );
      paths.add(file.path);
    }
    final imported = Stopwatch()..start();
    // 单次最多导入 128 本，分批导入。
    final outcomes = [
      for (var i = 0; i < paths.length; i += 100)
        ...await library.importFiles(paths.sublist(i, i + 100)),
    ];
    imported.stop();
    expect(outcomes.where((o) => o.succeeded).length, 300);
    final ids = state.shelf.books
        .where((b) => !b.isDemo)
        .map((b) => b.id)
        .toList();
    expect(ids.length, 300);

    int median(List<int> values) => (values..sort())[values.length ~/ 2];
    List<int> repeat(int times, void Function() body) => [
      for (var i = 0; i < times; i++)
        (() {
          final watch = Stopwatch()..start();
          body();
          return watch.elapsedMicroseconds;
        })(),
    ];

    // 书库刷新：任何状态变化都会触发，逐本重算稿件指纹并查找检查报告。
    final refresh = repeat(15, () => state.change(() {}));
    final guards = repeat(15, () {
      for (final id in ids) {
        LegacyBookCheckSession.contextFor(state, id);
      }
    });
    final publication = repeat(15, () {
      for (final id in ids) {
        state.publicationContext(id);
      }
    });
    final summaries = repeat(15, () {
      for (final id in ids) {
        LegacyBookCheckSession.summaryFor(state, id);
      }
    });
    // 指纹各组成部分（定位耗时）。
    final settings = repeat(15, () {
      for (final id in ids) {
        state.production.settings(id);
      }
    });
    final rules = repeat(15, () {
      for (final id in ids) {
        resolveCleanupRules(
          state.globalConfiguration,
          bookDraft: state.cleanup.drafts[id],
        ).fingerprint;
      }
    });
    final hashing = repeat(15, () {
      for (final id in ids) {
        publicationFingerprint({
          'check': [
            id,
            state.production.settings(id),
            state.manuscript.effectiveBase(id),
            state.manuscript.effectiveSelection(id),
          ],
        });
      }
    });
    final sample = ids.first;
    final sizes = {
      'publication_context_chars': state.publicationContext(sample).length,
      'production_settings_chars': jsonEncode(
        state.production.settings(sample),
      ).length,
      'structure_chars': jsonEncode(state.manuscript.structures[sample]).length,
      'structure_history_chars': jsonEncode(
        state.manuscript.structureHistories[sample],
      ).length,
      'effective_history_chars': jsonEncode(
        state.manuscript.effectiveHistories[sample],
      ).length,
      'reference_catalog_chars': jsonEncode(state.savedReferenceCatalog(state.currentId)).length,
    };
    final result = {
      ...sizes,
      'production_settings_median_ms': median(settings) / 1000,
      'cleanup_rules_fingerprint_median_ms': median(rules) / 1000,
      'fingerprint_without_rules_median_ms': median(hashing) / 1000,
      'books': 300,
      'import_ms': imported.elapsedMilliseconds,
      'refresh_median_ms': median(refresh) / 1000,
      'check_guard_median_ms': median(guards) / 1000,
      'publication_context_median_ms': median(publication) / 1000,
      'check_summary_median_ms': median(summaries) / 1000,
    };
    // ignore: avoid_print
    print('refresh300 ${jsonEncode(result)}');
    await File(
      '$root/result.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
  },
    timeout: const Timeout(Duration(minutes: 10)),
    // 测量工具，不是回归用例：默认跳过，设 EASYPUB_BENCHMARK=1 时运行（V21）。
    skip: Platform.environment['EASYPUB_BENCHMARK'] == '1'
        ? false
        : '只在 EASYPUB_BENCHMARK=1 时测量',
  );
}
