import 'package:easypub_desktop/desk/widgets.dart';

import 'dart:io';

import 'package:easypub_desktop/application/book_check_service.dart';

import 'package:flutter/material.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/desk/folders/metadata_mapping_page.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

class MappingPicker extends Fake implements BookFilePicker {}

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
  });
  Future<(PrototypeState, LegacyLibraryAdapter)> workspace(String path) async {
    final state = PrototypeState(settingsDirectory: path);
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    return (state, library);
  }

  test('empty library stores global rules; next import, restart, manual clear and project reopen agree', () async {
    final root = (await Directory.systemTemp.createTemp('mapping-import-'))
        .absolute;
    final (state, library) = await workspace('${root.path}/settings');
    await library.savePatch({'check_after_import': false});
    final rules = library.openMapping();
    await Future.sync(
      () => rules.saveRules([
        MappingRule(root.path, {
          'publisher': {'op': 'set', 'value': '映射出版社'},
          'language': {'op': 'fill_empty', 'value': 'zh-CN'},
          'author': {'op': 'set', 'value': '映射作者'},
        }),
      ]),
    );
    final (fresh, second) = await workspace('${root.path}/settings');
    expect(second.openMapping().rules.length, 1);
    expect(await second.savePatch({'check_after_import': true}), true);
    final source = File('${root.path}/初见.txt')
      ..writeAsStringSync('第一章 初见\n原稿保持不变。\n');
    final bytes = source.readAsBytesSync();
    expect((await second.importFiles([source.path])).single.succeeded, true);
    final id = second.books.value.single.id;
    expect(fresh.production.settings(id)['publisher'], '映射出版社');
    expect(fresh.production.settings(id)['author'], '映射作者');
    expect(fresh.production.settings(id)['language'], 'zh-CN');
    final checks = second.openChecks(id);
    final checkedMetadata = (checks as CachedBookCheckSession).latest!.domains
        .firstWhere((d) => d.id == 'metadata');
    expect(checkedMetadata.items, isNot(contains('作者尚未填写')));
    expect(checkedMetadata.items, isNot(contains('书籍语言尚未明确')));
    checks.dispose();
    expect(
      await fresh.production.confirm(
        await fresh.production.previewChanges({
          id: {'op': 'undo'},
        }),
      ),
      true,
    );
    expect(fresh.production.settings(id)['publisher'], '');
    expect(
      await fresh.production.confirm(
        await fresh.production.previewChanges({
          id: {'op': 'redo'},
        }),
      ),
      true,
    );
    expect(fresh.production.settings(id)['publisher'], '映射出版社');
    final layout = second.openLayout(id);
    await layout.apply(await layout.preview({'paragraph_indent': 1.25}));
    layout.dispose();
    final conversion = LegacyConversionSession(fresh);
    final outputPlan = await conversion.preview(
      ConversionRequest(
        books: [id],
        directory: '${root.path}/output',
        format: 'EPUB',
        runChecks: false,
      ),
    );
    final output = (await conversion.commit(
      outputPlan,
      acknowledgeWarnings: true,
    )).single;
    expect(output.complete, true, reason: output.detail);
    final actual = await readBook(output.path, () => false);
    final actualMetadata = actual.resourceReport!['metadata'] as Map;
    expect(actualMetadata['publisher'], '映射出版社');
    expect(actualMetadata['author'], '映射作者');
    expect(actualMetadata['language'], 'zh-CN');
    final cssCheck = await Process.run(
      Platform.environment['EASYPUB_TEST_PYTHON']!,
      [
        '-X',
        'utf8',
        '-c',
        "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert any(b'text-indent: 1.25em' in z.read(n) for n in z.namelist() if n.endswith('.css'))",
        output.path,
      ],
    );
    expect(cssCheck.exitCode, 0, reason: cssCheck.stderr.toString());
    conversion.dispose();

    final info = second.openBookInformation(id);
    await info.apply(await info.preview({'publisher': '', 'author': '手工作者'}));
    info.dispose();
    expect((await second.importFiles([source.path])).single.succeeded, true);
    expect(fresh.production.settings(id)['publisher'], '');
    expect(fresh.production.settings(id)['author'], '手工作者');
    final project = '${root.path}/book.easypub.json';
    expect((await second.saveProject(project)).succeeded, true);
    final (opened, third) = await workspace('${root.path}/settings');
    expect((await third.openProject(project)).succeeded, true);
    expect(third.openMapping().rules.length, 1);
    expect((await third.importFiles([source.path])).single.succeeded, true);
    expect(third.books.value.length, 1);
    expect(opened.production.settings(id)['publisher'], '');
    expect(opened.production.settings(id)['author'], '手工作者');
    expect(source.readAsBytesSync(), bytes);
    expect(state.shelf.books.where((b) => !b.isDemo), isEmpty);
  });
  test('offline unrelated mapping is retained and does not break import; invalid matching resource publishes no book', () async {
    final root = (await Directory.systemTemp.createTemp('mapping-offline-'))
        .absolute;
    final (state, library) = await workspace('${root.path}/settings');
    await library.savePatch({'check_after_import': false});
    await Future.sync(
      () => library.openMapping().saveRules([
        MappingRule('${root.path}/offline', {
          'cover_path': {'op': 'set', 'value': '${root.path}/missing.png'},
        }),
        MappingRule(root.path, {
          'publisher': {'op': 'set', 'value': '可用映射'},
        }),
      ]),
    );
    final first = File('${root.path}/甲.txt')
      ..writeAsStringSync('第一章 甲\n合成正文。\n');
    expect((await library.importFiles([first.path])).single.succeeded, true);
    expect(state.production.settings(state.currentId)['publisher'], '可用映射');
    expect(state.importStatus, contains('离线'));
    final mapSession = library.openMapping();
    final proof = await mapSession.preview(mapSession.rules, [state.currentId]);
    expect(proof.items.single.unavailableFolders, ['${root.path}/offline']);
    expect(library.openMapping().rules.length, 2);
    await Future.sync(
      () => library.openMapping().saveRules([
        MappingRule(root.path, {
          'cover_path': {'op': 'set', 'value': '${root.path}/missing.png'},
        }),
      ]),
    );
    final second = File('${root.path}/乙.txt')
      ..writeAsStringSync('第一章 乙\n合成正文。\n');
    final selected = state.currentId;
    final outcome = (await library.importFiles([second.path])).single;
    expect(outcome.succeeded, false);
    expect(outcome.message, contains('映射'));
    expect(library.books.value.length, 1);
    expect(state.currentId, selected);
    expect(state.production.settings(selected)['publisher'], '可用映射');
  });
  test(
    'stale settings writer cannot replace persisted mapping rules',
    () async {
      final root = (await Directory.systemTemp.createTemp('mapping-conflict-'))
          .absolute;
      final (_, a) = await workspace('${root.path}/settings');
      final (_, b) = await workspace('${root.path}/settings');
      await Future.sync(
        () => a.openMapping().saveRules([
          MappingRule(root.path, {
            'publisher': {'op': 'set', 'value': '先保存'},
          }),
        ]),
      );
      await expectLater(
        Future.sync(
          () => b.openMapping().saveRules([
            MappingRule(root.path, {
              'publisher': {'op': 'set', 'value': '过期覆盖'},
            }),
          ]),
        ),
        throwsA(isA<FormatException>()),
      );
      final (_, c) = await workspace('${root.path}/settings');
      expect(c.openMapping().rules.single.fields['publisher']!['value'], '先保存');
    },
  );
  testWidgets(
    'empty mapping page renders, disables empty preview and awaits durable save',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late LegacyLibraryAdapter library;
      await tester.runAsync(() async {
        final root = (await Directory.systemTemp.createTemp('mapping-ui-'))
            .absolute;
        final (_, value) = await workspace('${root.path}/settings');
        library = value;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MetadataMappingPage(
              library: library,
              picker: MappingPicker(),
              navigation: MappingNavigationGuard(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('0 条'), findsOneWidget);
      expect(
        tester
            .widget<DeskSegmented<bool>>(find.byType(DeskSegmented<bool>))
            .value,
        false,
      );
      final previewButton = find.ancestor(
        of: find.text('预览逐书差异'),
        matching: find.byType(TextButton),
      );
      expect(tester.widget<TextButton>(previewButton).onPressed, isNull);
      await tester.tap(find.text('保存规则配置'));
      final saved = find.text('规则已保存；之后导入自动匹配，已有书籍请先预览差异。');
      final clock = Stopwatch()..start();
      // 保存走真实磁盘 I/O；并发回归不能假设 400ms 后已结束。
      while (saved.evaluate().isEmpty &&
          clock.elapsed < const Duration(seconds: 30)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(saved, findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('规则已保存；之后导入自动匹配，已有书籍请先预览差异。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
