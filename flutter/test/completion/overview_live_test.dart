import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/library/book_overview_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import 'library_removal_test.dart' as setup;

import 'package:easypub_desktop/desk/tokens.dart';

class Picker extends setup.NoPicker {
  Picker(this.path);
  final String path;
  @override
  Future<String?> chooseProjectDestination() async => path;
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
    'overview uses live shared checks, three statistics, real save and responsive panels',
    (t) async {
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final fixture = await t.runAsync(setup.fixture);
      final (state, library, root) = fixture!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = library.books.value.first.id;
      final info = library.openBookInformation(id);
      await t.runAsync(() async {
        await info.apply(
          await info.preview({
            'title': '长河照影',
            'author': '林间客',
            'description': '一条长河，几代人的来路与归途。沿岸旧事被重新拾起，风雨与故人在字里行间相逢。',
          }),
        );
      });
      info.dispose();
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
      var scale = 1.0;
      String? revealed;
      Widget app() => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: deskTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: capture, child: child!),
        ),
        home: Scaffold(
          backgroundColor: Desk.light.canvas,
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: BookOverviewPage(
              library: library,
              bookId: id,
              picker: Picker('$root/overview.easypub.json'),
              onRevealSource: (path) async {
                revealed = path;
              },
            ),
          ),
        ),
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 1000; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        fail(
          'overview operation did not settle: ${state.projectStatus}; pending=${library.hasPendingWork}; dirty=${library.hasUnsavedChanges}; path=${state.projectPath}',
        );
      }

      await t.pumpWidget(app());
      await until(() => find.textContaining('字号').evaluate().isNotEmpty);
      for (final field in ['volumes', 'chapters', 'characters']) {
        expect(find.byKey(ValueKey('overview-stat-$field')), findsOneWidget);
      }
      final observer = library.openChecks(id);
      var notifications = 0;
      observer.changes.addListener(() => notifications++);
      final external = library.openChecks(id);
      var done = false;
      external.inspect().then((_) {
        done = true;
      });
      await until(() => done);
      // V16：检查摘要并入制作进度，标题行写检查时间（LIB-111）。
      expect(
        t.widget<Text>(find.byKey(const ValueKey('overview-checked-at'))).data,
        startsWith('检查于 '),
      );
      expect(find.text('检查摘要'), findsNothing);
      final before = notifications;
      done = false;
      external.inspect().then((_) {
        done = true;
      });
      await until(() => done);
      expect(notifications, greaterThan(before));
      observer.dispose();
      external.dispose();
      // V15（LIB-110）：项目文件状态写在“项目与来源”里，与草稿自动保存分开说明。
      expect(find.text('尚未另存为项目文件'), findsOneWidget);
      expect(find.textContaining('草稿已自动保存在本机'), findsOneWidget);
      await t.ensureVisible(find.text('另存为项目…'));
      expect(
        t
            .widget<TextButton>(find.widgetWithText(TextButton, '另存为项目…'))
            .onPressed,
        isNotNull,
      );
      await t.tap(find.text('另存为项目…'));
      await until(
        () =>
            !state.projectBusy &&
            File('$root/overview.easypub.json').existsSync() &&
            !library.hasUnsavedChanges,
      );
      await until(() => find.text('项目文件已是最新').evaluate().isNotEmpty);
      expect(
        t
            .widget<TextButton>(find.widgetWithText(TextButton, '更新项目文件'))
            .onPressed,
        isNull,
      );
      // 转换统一用底部的“转换当前书”，概览里不再有重复入口（LIB-109）。
      expect(find.text('生成成品'), findsOneWidget); // 只剩“制作进度”中的一行
      expect(find.text('转换本书'), findsNothing);
      await t.ensureVisible(find.text('打开原文件位置'));
      await t.tap(find.text('打开原文件位置'));
      expect(revealed, library.books.value.first.path);
      Future<void> shot(String name) async {
        final target = File('$root/screens/$name.png');
        await t.pump();
        await t.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await target.parent.create(recursive: true);
          await target.writeAsBytes(bytes!.buffer.asUint8List());
        });
      }

      final scroll = t.state<ScrollableState>(find.byType(Scrollable).first);
      scroll.position.jumpTo(0);
      await t.pump();
      await shot('overview-wide');
      t.view.physicalSize = const Size(900, 720);
      scale = 1.3;
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await shot('overview-narrow');
      await t.ensureVisible(find.text('全部记录 →'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
