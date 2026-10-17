import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/library_check_batch.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import '../test/completion/library_removal_test.dart' as setup;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';

class GateCheck extends Fake implements BookCheckSession {
  GateCheck(this.gate);
  final Completer<BookCheckReport> gate;
  bool released = false;
  @override
  Future<BookCheckReport> inspect() => gate.future;
  @override
  bool isCurrent(BookCheckReport report) => true;
  @override
  void dispose() {
    released = true;
  }

  @override
  void cancel() {}
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test(
    'batch snapshot, failure continuation, no overlap and stop after current',
    () async {
      final batch = LibraryCheckBatch();
      final gate = Completer<BookCheckReport>();
      final session = GateCheck(gate);
      final targets = [('a', '甲'), ('b', '乙')];
      final opened = <String>[];
      final work = batch.run(targets, (id) {
        opened.add(id);
        return session;
      });
      targets.clear();
      expect(batch.total, 2);
      await expectLater(batch.run([], (_) => session), throwsStateError);
      batch.stop();
      expect(batch.running, true);
      gate.complete(constReport());
      await work;
      expect(opened, ['a']);
      expect(batch.results, hasLength(1));
      expect(batch.cancelled, true);
      expect(session.released, true);
      await batch.run([('a', '甲'), ('b', '乙')], (id) {
        if (id == 'a') throw const FormatException('失败证据');
        return GateCheck(Completer<BookCheckReport>()..complete(constReport()));
      });
      expect(batch.results.map((r) => r.failed), [true, false]);
      expect(batch.cancelled, false);
      batch.dispose();
    },
  );
  test('real batch preserves manual draft and shared selection, project boundary clears results', () async {
    final (state, library, root) = await setup.fixture();
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final ids = library.books.value.map((b) => b.id).toSet();
    final id = ids.first;
    library.selectBook(id);
    library.checkBooks(ids, true);
    final info = library.openBookInformation(id);
    await info.apply(await info.preview({'author': '手工作者'}));
    info.dispose();
    final before = jsonEncode(state.projectDocument());
    final work = library.inspectBooks(ids);
    expect(library.hasPendingWork, true);
    expect((await library.openProject('$root/absent.json')).succeeded, false);
    library.checkBooks([ids.last], false);
    await work;
    expect(library.checkBatch.results, hasLength(2));
    expect(
      library.checkBatch.results.every((r) => !r.failed),
      true,
      reason: library.checkBatch.results.map((r) => r.message).join('\n'),
    );
    expect(jsonEncode(state.projectDocument()), before);
    expect(library.selection.value.current, id);
    expect(library.selection.value.selected, {id});
    expect(library.hasPendingWork, false);
    final checks = library.openChecks(id);
    expect((checks as CachedBookCheckSession).latest, isNotNull);
    checks.dispose();
    expect(
      (await library.saveProject('$root/books.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/books.easypub.json')).succeeded,
      true,
    );
    expect(library.checkBatch.total, 0);
  });
  testWidgets(
    'library batch action shows real results and remains usable at 130 percent',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final captureKey = GlobalKey();
      await t.runAsync(() async {
        await (FontLoader('Microsoft YaHei')..addFont(File('C:/Windows/Fonts/msyh.ttc').readAsBytes().then((b) => b.buffer.asByteData()))).load();
        await (FontLoader('MaterialIcons')..addFont(File('D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytes().then((b) => b.buffer.asByteData()))).load();
      });
      Future<void> capture(String name) async {
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final picture = await (captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
          final file = File('../design/review-20261005-v2.13/screens/' + name + '.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes((await picture.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
          picture.dispose();
        });
      }
      final tuple = await t.runAsync(setup.fixture);
      final (state, library, _) = tuple!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      library.checkBooks(library.books.value.map((b) => b.id), true);
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (_, child) => RepaintBoundary(key: captureKey, child: child!),
          theme: deskTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(1440, 960),
              textScaler: TextScaler.linear(1),
            ),
            child: Scaffold(
              body: LibraryPage(library: library, picker: setup.NoPicker()),
            ),
          ),
        ),
      );
      await t.runAsync(() async {
        await t.tap(find.text('检查所选'));
        while (library.checkBatch.running) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await t.pumpAndSettle();
      expect(find.text('检查完成 2/2'), findsOneWidget);
      await capture('library-check-completed');
      await t.tap(find.text('检查完成 2/2'));
      await t.pumpAndSettle();
      expect(find.text('批量检查 · 已完成 2 / 2'), findsOneWidget);
      await capture('library-check-results');
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(ListTile),
        ),
        findsNWidgets(2),
      );
      expect(t.takeException(), isNull);
    },
  );
}

BookCheckReport constReport() =>
    const BookCheckReport('guard', [], null, '', 0);
