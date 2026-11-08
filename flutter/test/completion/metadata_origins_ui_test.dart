import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/desk/metadata/book_information_page.dart';
import 'package:easypub_desktop/desk/folders/metadata_mapping_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class OriginPicker extends Fake implements BookFilePicker {}

void main() {
  testWidgets(
    'actual information page only marks edited fields and mapping override requires repreview and apply',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String id;
      late Directory root;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        root = (await Directory('../artifacts').createTemp('metadata-ui-'))
            .absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        final file = File('${root.path}/样书.txt')
          ..writeAsStringSync('第一章 开始\n合成正文。\n');
        expect((await library.importFiles([file.path])).single.succeeded, true);
        id = state.currentId;
        await library.openMapping().saveRules([
          MappingRule(root.path, {
            'author': {'op': 'set', 'value': '规则作者'},
            'publisher': {'op': 'fill_empty', 'value': '规则出版社'},
          }),
        ]);
      });
      addTearDown(() => library.dispose());
      addTearDown(() => state.dispose());
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 200; i++) {
          await t.pump();
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
        fail('Native UI operation did not settle');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: BookInformationPage(
              library: library,
              bookId: id,
              navigation: InformationNavigationGuard(),
              pickImage: () async => null,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('information-author')),
        '手工作者',
      );
      await t.pump(const Duration(milliseconds: 500));
      await until(
        () =>
            state.production.settings(id)['author'] == '手工作者' &&
            find.text('已应用到本书').evaluate().isNotEmpty,
      );
      expect(find.text('确认书籍信息变更'), findsNothing);
      expect(find.text('已应用到本书'), findsOneWidget);
      var origins = state.production.settings(id)['metadata_origins'] as Map;
      expect(origins['author']['source'], 'manual');
      expect(origins['publisher']['source'], 'imported');
      expect(origins['title']['source'], 'imported');
      await t.pumpWidget(const SizedBox());
      library.checkBook(id, true);
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: MetadataMappingPage(
              library: library,
              picker: OriginPicker(),
              navigation: MappingNavigationGuard(),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('预览逐书差异'));
      await until(() => find.text('选择要覆盖的保护字段').evaluate().isNotEmpty);
      expect(state.production.settings(id)['author'], '手工作者');
      await t.tap(find.text('选择要覆盖的保护字段'));
      await t.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(
        t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await t.tap(find.byType(CheckboxListTile));
      await t.tap(find.text('重新预览'));
      await until(() => find.text('已选择覆盖保护值').evaluate().isNotEmpty);
      expect(state.production.settings(id)['author'], '手工作者');
      await t.tap(find.text('恢复字段继承'));
      await t.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(
        t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await t.tap(find.byType(CheckboxListTile));
      await t.tap(find.text('重新预览'));
      await until(() => find.text('已选择恢复继承').evaluate().isNotEmpty);
      expect(
        find.text('已选择覆盖保护值'),
        findsNothing,
        reason: 'restore replaces conflicting override selection',
      );
      expect(state.production.settings(id)['author'], '手工作者');
      await t.tap(find.text('确认应用到 1 本书'));
      await until(() => state.production.settings(id)['author'] == '规则作者');
      expect(state.production.settings(id)['publisher'], '规则出版社');
      origins = state.production.settings(id)['metadata_origins'] as Map;
      expect(origins['author']['source'], 'folder_rule');
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
