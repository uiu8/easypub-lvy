import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/history/change_history_page.dart';

void main() {
  testWidgets('变更记录登记时间：编辑有时间、重启后保留、撤销不产生新时间、按日期分组', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late Directory root;
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      root = (await Directory('../artifacts').createTemp('history-times-'))
          .absolute;
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      final source = File('${root.path}/两章.txt')
        ..writeAsStringSync('第一章 开始\n第一段正文。\n\n第二章 后续\n第二段正文。\n');
      expect((await library.importFiles([source.path])).single.succeeded, true);
      id = state.currentId;
      final chapters = library.openChapters(id);
      final tree = await chapters.read(0);
      await chapters.confirm(
        await chapters.preview(
          tree,
          MoveChapter(tree.nodes[1].id, tree.nodes[0].id),
        ),
      );
    });
    final history = library.openChangeHistory();
    final edited = history.records(id).where((r) => r.domain == '章节').toList();
    expect(edited, isNotEmpty);
    final stamped = edited.first.time;
    expect(stamped, isNotNull);
    expect(DateTime.now().difference(stamped!).inMinutes, lessThan(5));

    // 撤销不会给任何版本记新时间。
    await t.runAsync(() async {
      final chapters = library.openChapters(id);
      await chapters.history(await chapters.read(0), undo: true);
    });
    final afterUndo = history.records(id).where((r) => r.domain == '章节');
    expect(afterUndo.where((r) => r.time != null).length, 1);
    expect(afterUndo.firstWhere((r) => r.time != null).time, stamped);

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChangeHistoryPage(
            library: library,
            history: history,
            bookId: id,
            openEditor: (_, _) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.text('今天').evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 30));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(find.text('今天'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());

    // 登记写入设置目录；重启后由新的适配层读回。
    final settings = '${root.path}/settings';
    final ledger = File('$settings/change-times.json');
    expect(ledger.existsSync(), true);
    expect(ledger.readAsStringSync(), contains(stamped.toIso8601String()));
    library.dispose();
    state.dispose();
    await t.runAsync(() async {
      state = PrototypeState(settingsDirectory: settings);
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    if (state.shelf.books.any((b) => b.id == id)) {
      final reopened = library
          .openChangeHistory()
          .records(id)
          .where((r) => r.time != null);
      expect(reopened.single.time, stamped);
    }
  });
}
