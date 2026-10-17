import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/metadata_mapping_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/desk/folders/metadata_mapping_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class ProjectPicker extends Fake implements BookFilePicker {}

void main() {
  testWidgets(
    'project rule editor saves only project scope and drives next import',
    (t) async {
      t.view.physicalSize = const Size(1080, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late Directory root;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        root = (await Directory(
          '../artifacts',
        ).createTemp('project-mapping-ui-')).absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.setFavorite(root.path, true);
        await library.savePatch({'check_after_import': false});
        final session = library.openMapping();
        await session.saveRules([
          MappingRule(root.path, {
            'author': {'op': 'set', 'value': '全局作者'},
          }),
        ]);
        final scoped = session as ProjectMappingSession;
        scoped.selectProjectScope(true);
        await session.saveRules([
          MappingRule(root.path, {
            'author': {'op': 'set', 'value': '旧项目作者'},
          }),
        ]);
        scoped.setProjectEnabled(false);
      });
      addTearDown(library.dispose);
      addTearDown(state.dispose);
      final global = state.globalFolderRules;
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: MetadataMappingPage(
              library: library,
              picker: ProjectPicker(),
              navigation: MappingNavigationGuard(),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      // V8：全局/项目规则改为页头分段切换。
      await t.tap(find.text('项目规则'));
      await t.pumpAndSettle();
      expect(find.text('项目优先：关'), findsOneWidget);
      await t.tap(find.text('选收藏'));
      await t.pump();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pumpAndSettle();
      await t.tap(find.text(root.path).last);
      await t.pumpAndSettle();
      await t.tap(find.text('使用此目录'));
      await t.pumpAndSettle();
      expect(state.globalFolderRules, global);
      expect(state.projectFolderRulesEnabled, false);
      await t.enterText(
        find.byKey(const ValueKey('mapping-value-author')),
        '界面项目作者',
      );
      await t.tap(find.text('保存规则配置'));
      await t.pumpAndSettle();
      expect(state.projectFolderRulesEnabled, true);
      expect(state.globalFolderRules, global);
      expect(state.folderRules.single['fields']['author']['value'], '界面项目作者');
      expect(find.text('项目优先：开'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final file = File('${root.path}/sample.txt')
          ..writeAsStringSync('第一章 开始\n界面测试正文。\n');
        expect((await library.importFiles([file.path])).single.succeeded, true);
        expect(state.production.settings(state.currentId)['author'], '界面项目作者');
      });
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 200; i++) {
          await t.pump();
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
        fail('save impact UI did not settle');
      }

      await t.enterText(
        find.byKey(const ValueKey('mapping-value-author')),
        '更新项目作者',
      );
      await t.tap(find.text('保存规则配置'));
      await until(() => find.text('保存规则前核对').evaluate().isNotEmpty);
      expect(find.text('作者：界面项目作者 → 更新项目作者'), findsOneWidget);
      expect(state.folderRules.single['fields']['author']['value'], '界面项目作者');
      await t.tap(find.text('返回编辑'));
      await t.pumpAndSettle();
      expect(state.folderRules.single['fields']['author']['value'], '界面项目作者');
      await t.tap(find.text('保存规则配置'));
      await until(() => find.text('保存规则前核对').evaluate().isNotEmpty);
      await t.tap(find.text('仅保存规则'));
      await until(
        () => state.folderRules.single['fields']['author']['value'] == '更新项目作者',
      );
      expect(state.production.settings(state.currentId)['author'], '界面项目作者');
      expect(state.globalFolderRules, global);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
