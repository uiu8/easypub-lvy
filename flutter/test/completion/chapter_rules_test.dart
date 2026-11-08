import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/rules/rules_sheet.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'rule drafts, book/default separation, history, reopen and export',
    (t) async {
      t.view.physicalSize = const Size(1250, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late Directory root;
      late File source;
      const original = '第1话 起点\n正文甲\n第3话 后续\n正文乙\n两章合一章，更比两章强！\n';
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        root = (await Directory('../artifacts').createTemp('chapter-rules-'))
            .absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        source = File('${root.path}/规则.txt')..writeAsStringSync(original);
        expect(
          (await library.importFiles([source.path])).single.succeeded,
          true,
        );
      });
      addTearDown(() async {
        await t.runAsync(library.closeWorkspaceStorage);
        library.dispose();
        state.dispose();
      });
      Future<void> settle() async {
        for (var i = 0; i < 250; i++) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (i > 8 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            return;
          }
        }
        fail('Rules did not settle');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showChapterRulesDialog(
                  context,
                  service: library,
                  bookId: state.currentId,
                ),
                child: const Text('打开规则'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开规则'));
      await settle();
      // V3：规则字段标签移到输入框上方，改用稳定 key 定位（CH-104）。
      final field = find.byKey(const ValueKey('rules-chapter_pattern'));
      // V9：底栏显示已应用规则的标识；编辑后另显示编辑中的标识。
      String footer() =>
          t.widget<Text>(find.byKey(const ValueKey('rules-fingerprint'))).data!;
      expect(footer(), startsWith('已应用规则 #'));
      expect(footer(), isNot(contains('编辑中')));
      const expression = r'^第(?<number>\d+)话\s*(?<title>.+)$';
      await t.enterText(field, expression);
      await t.pump();
      expect(footer(), contains('编辑中 #'));
      // No clock advance: the last keystroke must survive immediate Escape.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('本书识别规则'), findsNothing);
      await t.tap(find.text('打开规则'));
      await settle();
      expect(t.widget<TextField>(field).controller!.text, expression);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        expect(await library.initializeWorkspace(), true);
        final rules = library.openRules(state.currentId);
        final builtin = await rules.builtin();
        final custom = {
          ...builtin,
          'chapter_pattern': expression,
          'origin': 'book',
        };
        expect((await rules.sample(custom, '第12话 风起'))['match']['number'], 12);
        expect((await rules.sample(builtin, '两章合一章，更比两章强！'))['match'], isNull);
        for (final title in [
          '第二章 两章合一章，更比两章强！',
          '第137章 更新了世界',
          '八百三十八章 梦醒',
          '八百三十八章梦醒',
          '第壹佰贰拾章 远行',
          '序章',
          '番外：重逢',
        ]) {
          expect(
            (await rules.sample(builtin, title))['match'],
            isNotNull,
            reason: title,
          );
        }
        for (final title in ['两章 加起来5400多字', '（两章加起来5400多字，已经三更了！）']) {
          expect(
            (await rules.sample(builtin, title))['match'],
            isNull,
            reason: title,
          );
        }
        await expectLater(
          rules.sample({...custom, 'chapter_pattern': '('}, '第12话 风起'),
          throwsFormatException,
        );
        final preview = await rules.preview(custom, preserveDecisions: true);
        expect(preview.data['summary']['added'], 2);
        await rules.apply(preview);
        await expectLater(rules.apply(preview), throwsFormatException);
        var chapters = library.openChapters(state.currentId);
        expect((await chapters.read(0)).total, 2);
        await chapters.history(await chapters.read(0), undo: true);
        expect((await chapters.read(0)).total, 0);
        await chapters.history(await chapters.read(0), undo: false);
        expect((await chapters.read(0)).total, 2);
        await library.openRules(null).saveDefault(builtin);
        expect((await chapters.read(0)).total, 2);
        final page = await chapters.read(0);
        await chapters.properties(page, page.nodes.first, inToc: false);
        final keepToc = await rules.preview(custom, preserveDecisions: true);
        expect(keepToc.data['summary']['changed'], 0);
        await rules.apply(keepToc);
        expect((await chapters.read(0)).nodes.first.inToc, false);
        final replaceToc = await rules.preview(
          custom,
          preserveDecisions: false,
        );
        expect(replaceToc.data['summary']['changed'], 1);
        final tocChange = (replaceToc.data['changes'] as List).single;
        expect(tocChange['before_include_toc'], false);
        expect(tocChange['include_toc'], true);
        await rules.apply(replaceToc);
        expect((await chapters.read(0)).nodes.first.inToc, true);
        await rules.savePresets([
          {'name': '话标题', 'rules': custom},
        ]);
        await rules.savePresets([
          {'name': '重命名规则', 'rules': custom},
        ]);
        expect(
          ((await rules.load())['presets'] as List).single['name'],
          '重命名规则',
        );
        await rules.savePresets([]);
        expect((await rules.load())['presets'], isEmpty);
        await rules.savePresets([
          {'name': '话标题', 'rules': custom},
        ]);
        rules.saveDraft({
          'rules': {...custom, 'chapter_pattern': '('},
          'preserve_decisions': true,
        });
        library.openRules(null).saveDraft({
          'rules': builtin,
          'preserve_decisions': true,
        });
        final project = '${root.path}/rules.easypub.json';
        expect((await library.saveProject(project)).succeeded, true);
        expect((await library.openProject(project)).succeeded, true);
        chapters = library.openChapters(state.currentId);
        expect((await chapters.read(0)).total, 2);
        final restored = await library.openRules(state.currentId).load();
        expect(restored['rules']['chapter_pattern'], expression);
        expect(restored['draft']['rules']['chapter_pattern'], '(');
        expect((restored['presets'] as List).single['name'], '话标题');
        expect((await library.openRules(null).load())['draft'], isNotNull);

        final firstId = state.currentId;
        final otherSource = File('${root.path}/另一本.txt')
          ..writeAsStringSync('第一章 另一份规则\n另一份正文。\n');
        expect(
          (await library.importFiles([otherSource.path])).single.succeeded,
          true,
        );
        final otherId = state.currentId;
        expect(otherId, isNot(firstId));
        library.selectBook(otherId);
        final otherRules = library.openRules(otherId);
        expect(
          (await otherRules.load())['rules']['chapter_pattern'],
          builtin['chapter_pattern'],
        );
        otherRules.saveDraft({
          'rules': {...builtin, 'chapter_pattern': r'^另(?<number>\d+)章$'},
          'preserve_decisions': false,
        });
        library.selectBook(firstId);
        expect(library.selection.value.current, firstId);
        final firstAgain = await library.openRules(firstId).load();
        expect(firstAgain['rules']['chapter_pattern'], expression);
        expect(firstAgain['draft']['rules']['chapter_pattern'], '(');
        expect(await library.flushWorkspace(), true);
        await library.closeWorkspaceStorage();
        library.dispose();
        state.dispose();

        // Recreate both owners, then restore through workspace storage rather
        // than re-opening a project into the state that already owns the data.
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.initializeWorkspace(), true);
        expect(library.books.value, hasLength(2));
        expect(library.selection.value.current, firstId);
        expect(state.currentId, firstId);
        final recoveredRules = await library.openRules(firstId).load();
        expect(recoveredRules['rules']['chapter_pattern'], expression);
        expect(recoveredRules['draft']['rules']['chapter_pattern'], '(');
        expect(
          (await library
              .openRules(otherId)
              .load())['draft']['rules']['chapter_pattern'],
          r'^另(?<number>\d+)章$',
        );
        chapters = library.openChapters(firstId);
        expect((await chapters.read(0)).total, 2);
        expect(chapters.canUndo, true);
        await chapters.history(await chapters.read(0), undo: true);
        expect((await chapters.read(0)).nodes.first.inToc, false);
        expect(chapters.canRedo, true);
        await chapters.history(await chapters.read(0), undo: false);
        expect((await chapters.read(0)).nodes.first.inToc, true);
        expect((await library.openChapters(otherId).read(0)).total, 1);
        final conversion = LegacyConversionSession(state);
        try {
          final plan = await conversion.preview(
            ConversionRequest(
              books: [state.currentId],
              directory: root.path,
              format: 'EPUB',
              generateCover: true,
              runChecks: false,
            ),
          );
          final result = (await conversion.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: result.detail);
          final inspected = await Process.run(
            Platform.environment['EASYPUB_TEST_PYTHON']!,
            [
              '-c',
              "import sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); nav=E.fromstring(z.read('EPUB/nav.xhtml')); titles=[e.text for e in nav.findall('.//{http://www.w3.org/1999/xhtml}a')]; assert '第1话 起点' in titles and '第3话 后续' in titles; assert not any('两章合一章' in (t or '') for t in titles)",
              result.path,
            ],
          );
          expect(
            inspected.exitCode,
            0,
            reason: '${inspected.stdout}\n${inspected.stderr}',
          );
          const numericOriginal =
              '1：风起\r\n甲\r\n乙\r\n丙\r\n2：归来\r\n丁\r\n戊\r\n己\r\n';
          final numericSource = File('${root.path}/规范数字.txt')
            ..writeAsStringSync(numericOriginal);
          expect(
            (await library.importFiles([numericSource.path])).single.succeeded,
            true,
          );
          final numericRules = library.openRules(state.currentId);
          final numericPreview = await numericRules.preview({
            ...builtin,
            'numeric': true,
            'numeric_minimum_body_lines': 3,
            'normalize_numeric_titles': true,
          }, preserveDecisions: true);
          await numericRules.apply(numericPreview);
          final numericPlan = await conversion.preview(
            ConversionRequest(
              books: [state.currentId],
              directory: root.path,
              format: 'EPUB',
              generateCover: true,
              runChecks: false,
            ),
          );
          final numericResult = (await conversion.commit(
            numericPlan,
            acknowledgeWarnings: true,
          )).single;
          expect(numericResult.complete, true, reason: numericResult.detail);
          final normalized = await Process.run(
            Platform.environment['EASYPUB_TEST_PYTHON']!,
            [
              '-c',
              "import sys,zipfile,xml.etree.ElementTree as E; z=zipfile.ZipFile(sys.argv[1]); nav=E.fromstring(z.read('EPUB/nav.xhtml')); titles=[e.text for e in nav.findall('.//{http://www.w3.org/1999/xhtml}a')]; assert '第一章 风起' in titles and '第二章 归来' in titles",
              numericResult.path,
            ],
          );
          expect(
            normalized.exitCode,
            0,
            reason: '${normalized.stdout}\n${normalized.stderr}',
          );
          expect(numericSource.readAsStringSync(), numericOriginal);
        } finally {
          conversion.dispose();
        }
        expect(source.readAsStringSync(), original);
      });
      expect(t.takeException(), isNull);
    },
  );
}
