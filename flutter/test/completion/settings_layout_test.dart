import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/settings_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/tokens.dart';

class Settings implements SettingsService {
  @override
  final ValueNotifier<SettingsSnapshot> snapshot = ValueNotifier(
    const SettingsSnapshot(
      configuration: {},
      status: '',
      busy: false,
      loaded: true,
      theme: 'light',
      reducedMotion: false,
    ),
  );
  int saves = 0;
  @override
  Future<bool> load() async => true;
  @override
  Future<bool> savePatch(Map<String, dynamic> patch) async {
    saves++;
    return true;
  }

  @override
  Future<Map<String, dynamic>> inspectLegacy(String path) async => {};
  @override
  void dispose() => snapshot.dispose();
}

class Favorites implements LibraryService {
  @override
  final ValueNotifier<List<String>> favoriteFolders = ValueNotifier(
    List.generate(24, (i) => 'D:/小说收藏/长篇小说与整理资料/分卷原稿与校对记录/目录$i'),
  );
  @override
  String favoriteName(String path) => path.split('/').last;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DelayedMigrationSettings extends Settings {
  Completer<Map<String, dynamic>>? request;
  @override
  Future<Map<String, dynamic>> inspectLegacy(String path) =>
      (request = Completer<Map<String, dynamic>>()).future;
}

void main() {
  testWidgets('清除迁移结果后，旧检查的成功和失败都不能重新出现', (t) async {
    t.view.physicalSize = const Size(1200, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final settings = DelayedMigrationSettings();
    addTearDown(settings.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(body: SettingsPage(settings: settings)),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('数据与迁移').first);
    await t.pumpAndSettle();
    final path = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '旧设置文件路径',
    );
    await t.ensureVisible(path);
    await t.enterText(path, 'D:/isolated/legacy.ini');
    for (final fails in [false, true]) {
      await t.ensureVisible(find.text('检查旧设置'));
      await t.tap(find.text('检查旧设置'));
      await t.pump();
      final pending = settings.request!;
      await t.tap(find.text('清除结果'));
      await t.pump();
      if (fails) {
        pending.completeError(const FormatException('旧请求失败'));
      } else {
        pending.complete({
          'report': {
            'proposed_layout': {'font_size': 120},
          },
        });
      }
      await t.pumpAndSettle();
      expect(find.text('确认迁移可识别字段'), findsNothing);
      expect(find.textContaining('已读取 1 项排版设置'), findsNothing);
      expect(find.text('旧设置读取失败，当前设置未改变。'), findsNothing);
      expect(settings.saves, 0);
      expect(t.takeException(), isNull);
    }
  });
  testWidgets(
    'settings keeps actions reachable and favorites independently scrollable at large text',
    (t) async {
      t.view.physicalSize = const Size(900, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final settings = Settings();
      final library = Favorites();
      addTearDown(settings.dispose);
      addTearDown(library.favoriteFolders.dispose);
      await t.runAsync(() async {
        await (FontLoader('Microsoft YaHei')..addFont(
              File('C:/Windows/Fonts/msyh.ttc')
                  .readAsBytes()
                  .then((b) => b.buffer.asByteData()),
            ))
            .load();
        await (FontLoader('MaterialIcons')..addFont(
              File(
                'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      });
      final capture = GlobalKey();
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          debugShowCheckedModeBanner: false,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ColoredBox(
                  color: Desk.light.canvas,
                  child: SettingsPage(settings: settings, library: library),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('导入与收藏').first);
      await t.pumpAndSettle();
      // 保存状态只在左下角一处。
      final status = find.byKey(const ValueKey('settings-save-status'));
      expect(t.widget<Text>(status).data, '修改后自动保存');
      final initial = t.getCenter(status);
      expect(status.hitTestable(), findsOneWidget);
      expect(find.text('保存设置'), findsNothing);
      final favoritesList = find.ancestor(
        of: find.text('目录0'),
        matching: find.byType(ListView),
      );
      expect(favoritesList, findsOneWidget);
      await t.drag(favoritesList, const Offset(0, -1600));
      await t.pumpAndSettle();
      expect(find.text('目录0').hitTestable(), findsNothing);
      expect(t.getCenter(status), initial);
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -1300));
      await t.pumpAndSettle();
      expect(t.getCenter(status), initial);
      expect(find.text('恢复本页默认…').hitTestable(), findsOneWidget);
      expect(settings.saves, 0);
      expect(t.takeException(), isNull);
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, 1600));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('../artifacts/settings55-import.png');
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await t.tap(find.text('转换工具').first);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('KFX / Bokai'));
      await t.pumpAndSettle();
      expect(find.text('KFX / Bokai').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/ui-converters-20261009.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await t.tap(find.text('成品与输出').first);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('KFX'));
      await t.tap(find.text('KFX'));
      await t.pumpAndSettle();
      expect(settings.saves, 1);
      expect(find.text('已自动保存'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await (await File(
          '../artifacts/kfx-implementation-20261008/settings-kfx.png',
        ).create(recursive: true)).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    },
  );
}
