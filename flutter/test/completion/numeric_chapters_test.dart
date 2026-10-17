import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/repair/repair_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets('numeric chapters: batch preview, apply, undo, reopen and EPUB', (
    t,
  ) async {
    t.view.physicalSize = const Size(1200, 850);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late Directory root;
    late File source;
    final original =
        '番外：生日\n原有番外正文\n${List.generate(102, (i) => '${238 + i}：标题$i\n正文$i 第一段\n第二段\n第三段\n').join()}1 清单甲\n2 清单乙\n3 清单丙\n';
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      root = (await Directory('../artifacts').createTemp('numeric-chapters-'))
          .absolute;
      state = PrototypeState(settingsDirectory: '${root.path}/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'recognition_defaults': {
          ...await library.openRules(null).builtin(),
          'numeric_minimum_body_lines': 3,
        },
      });
      source = File('${root.path}/数字章节.txt')..writeAsStringSync(original);
      expect((await library.importFiles([source.path])).single.succeeded, true);
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    final id = state.currentId;
    var session = library.openChapters(id);
    var returned = false;
    Future<void> settle() async {
      for (var i = 0; i < 400; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (i > 10 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          return;
        }
      }
      fail('Numeric chapter operation did not settle');
    }

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterRepairPage(
            library: library,
            bookId: id,
            initialCategory: 'unrecognized-heading',
            onReturn: () => returned = true,
            onEdit: (_) {},
          ),
        ),
      ),
    );
    await settle();
    expect(find.text('找到 102 个待识别的数字标题'), findsOneWidget);
    await t.tap(find.text('勾选本批数字章节'));
    await t.pump();
    await t.tap(find.text('查看完整差异'));
    await settle();
    expect(find.text('修复差异 · 102 项'), findsOneWidget);
    await t.runAsync(() async => expect((await session.read(0)).total, 1));
    await t.tap(find.text('确认应用并复查'));
    await settle();
    expect(find.text('数字标题已收入目录'), findsOneWidget);
    await t.runAsync(() async {
      final tree = await (session as ChapterOutlineSession).readOutline();
      expect(tree.total, 103);
      expect(tree.nodes.last.title, '339：标题101');
      expect((session as ChapterCheckpointSession).pendingEditActions, 1);
      final options = await (session as TargetedChapterRepairSession)
          .repairsForIssue(await session.read(0), 'unrecognized-heading:');
      expect(options.total, 0);
    });
    await t.tap(find.text('撤销本次修复'));
    await settle();
    expect(returned, true);
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      expect((await session.read(0)).total, 1);
      await session.history(await session.read(0), undo: false);
      final project = '${root.path}/saved.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      expect((await library.openProject(project)).succeeded, true);
      session = library.openChapters(state.currentId);
      expect((await session.read(0)).total, 103);
      final convert = LegacyConversionSession(state);
      try {
        final plan = await convert.preview(
          ConversionRequest(
            books: [state.currentId],
            directory: root.path,
            format: 'EPUB',
            generateCover: true,
            runChecks: false,
          ),
        );
        expect(plan.previewed, true);
        final result = (await convert.commit(
          plan,
          acknowledgeWarnings: true,
        )).single;
        expect(result.complete, true, reason: result.detail);
        final inspect = await Process.run(
          Platform.environment['EASYPUB_TEST_PYTHON']!,
          [
            '-c',
            "import sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); ns={'h':'http://www.w3.org/1999/xhtml'}; nav=E.fromstring(z.read('EPUB/nav.xhtml')); titles=[e.text for e in nav.findall('.//h:a',ns)]; assert '238：标题0' in titles and '339：标题101' in titles; assert not any(t in titles for t in ['1 清单甲','2 清单乙','3 清单丙'])",
            result.path,
          ],
        );
        expect(
          inspect.exitCode,
          0,
          reason: '${inspect.stdout}\n${inspect.stderr}',
        );
      } finally {
        convert.dispose();
      }
      expect(source.readAsStringSync(), original);
    });
    expect(t.takeException(), isNull);
  });
}
