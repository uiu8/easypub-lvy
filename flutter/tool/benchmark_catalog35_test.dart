import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_catalog_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

import '../test/completion/catalog_search_test.dart' show SearchCatalog;

String text(int n) =>
    List.generate(n, (i) => '第${i + 1}章 测量目录标题${i + 1}').join('\n');
void main() {
  final measurements = <Map<String, Object>>[];
  tearDownAll(() async {
    final path = Platform.environment['EASYPUB_CATALOG_BENCHMARK']!;
    await File(
      path,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(measurements));
  });
  test('measure real catalog acquisition and event loop gaps', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory.systemTemp.createTemp('catalog35-benchmark-');
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    final file = File('${root.path}/book.txt');
    await file.writeAsString('第一章 测试\n正文');
    expect((await library.importFiles([file.path])).single.succeeded, true);
    final session = LegacyCatalogSession(state, library.books.value.single.id);
    for (final size in [3666, 10000, 30000]) {
      final input = text(size);
      final watch = Stopwatch()..start();
      var last = 0, maximum = 0, ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = watch.elapsedMicroseconds;
        final gap = now - last;
        if (gap > maximum) maximum = gap;
        last = now;
        ticks++;
      });
      final result = await session.acquire('paste', input, declaredTotal: size);
      final elapsed = watch.elapsedMicroseconds;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      timer.cancel();
      expect(result.entries, hasLength(size));
      measurements.add({
        'phase': 'acquire',
        'entries': size,
        'elapsed_us': elapsed,
        'max_event_gap_us': maximum,
        'ticks': ticks,
      });
    }
  });
  testWidgets('measure paste field layout', (t) async {
    t.view.physicalSize = const Size(1400, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CatalogSourceDialog(
            session: SearchCatalog(),
            pickFile: () async => null,
          ),
        ),
      ),
    );
    await t.tap(find.text('粘贴目录'));
    await t.pumpAndSettle();
    final field = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '粘贴目录文本',
    );
    for (final size in [3666, 10000, 30000]) {
      if (find.text('清空目录').evaluate().isNotEmpty) {
        await t.tap(find.text('清空目录'));
        await t.pump();
      }
      final input = text(size);
      final watch = Stopwatch()..start();
      await t.enterText(field, input);
      await t.pump();
      measurements.add({
        'phase': 'paste_layout',
        'entries': size,
        'elapsed_us': watch.elapsedMicroseconds,
      });
      expect(t.takeException(), isNull);
    }
  });
}
