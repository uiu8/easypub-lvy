import 'dart:io';

import 'package:easypub_desktop/application/conversion_desktop.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class Picker extends Fake implements BookFilePicker {
  String? next;
  @override
  Future<String?> chooseFolder() async => next;
}

class ConverterDesktop extends Fake
    implements ConversionDesktop, KfxConversionDesktop {
  @override
  Future<String?> bundledConverter() async => 'D:/tools/kindling.exe';
  @override
  Future<String?> bundledKfxConverter() async => 'D:/tools/bokai.exe';
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  testWidgets(
    'favorite row rename relocate cancel and remove persist without touching files',
    (t) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final root = await t.runAsync(
        () => Directory('../artifacts').createTemp('favorites58-'),
      );
      final state = PrototypeState(
        settingsDirectory: '${root!.absolute.path}/settings',
      );
      final library = LegacyLibraryAdapter(backend: state);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final a = Directory('${root.absolute.path}/original')..createSync();
      final b = Directory('${root.absolute.path}/relocated')..createSync();
      final source = File('${a.path}/keep.txt')..writeAsStringSync('keep');
      await t.runAsync(() async {
        await library.load();
        expect(await library.setFavorite(a.path, true), true);
      });
      final picker = Picker();
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: SettingsPage(
              settings: library,
              desktop: ConverterDesktop(),
              library: library,
              picker: picker,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('导入与收藏').first);
      await t.pumpAndSettle();
      Future<void> menu(String item) async {
        await t.tap(find.byTooltip('收藏操作'));
        await t.pumpAndSettle();
        await t.tap(find.text(item));
        await t.pumpAndSettle();
      }

      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 200 && !ready(); i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
        }
        expect(ready(), true);
        await t.pumpAndSettle();
      }

      await menu('重命名');
      await t.enterText(
        find.byKey(const ValueKey('settings-favorite-name')),
        '小说原稿',
      );
      await t.tap(find.text('保存名称'));
      await waitFor(() => library.favoriteName(a.path) == '小说原稿');
      expect(find.text('小说原稿'), findsOneWidget);
      await menu('重新定位'); // picker cancellation preserves the old shortcut
      expect(library.favoriteFolders.value.single, a.path);
      picker.next = b.path;
      await menu('重新定位');
      await waitFor(
        () =>
            library.favoriteFolders.value.single.replaceAll('\\', '/') ==
            b.path.replaceAll('\\', '/'),
      );
      expect(library.favoriteName(b.path), '小说原稿');
      final reopened = PrototypeState(
        settingsDirectory: '${root.absolute.path}/settings',
      );
      final other = LegacyLibraryAdapter(backend: reopened);
      await t.runAsync(() async {
        await other.load();
        expect(other.favoriteName(b.path), '小说原稿');
        expect(other.favoriteFolders.value, library.favoriteFolders.value);
      });
      other.dispose();
      reopened.dispose();
      await menu('取消收藏');
      await waitFor(() => library.favoriteFolders.value.isEmpty);
      expect(find.text('尚未收藏文件夹'), findsOneWidget);
      expect(source.readAsStringSync(), 'keep');
      expect(b.existsSync(), true);
      await t.tap(find.text('转换工具').first);
      await t.pumpAndSettle();
      expect(find.text('KFX / Bokai'), findsOneWidget);
      expect(find.text('D:/tools/bokai.exe'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
