import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_catalog_session.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import 'library_removal_test.dart' as setup;

import 'package:easypub_desktop/desk/tokens.dart';

void main() {
  testWidgets(
    'protected cookie UI saves reopens replaces clears without project leakage; request uses saved scope',
    (t) async {
      final local = Platform.environment['LOCALAPPDATA']!;
      // Never use or clear a user's real credential store in this integration test.
      expect(local.replaceAll('\\', '/'), contains('/artifacts/completion-'));
      final stored = File(
        '$local/EasyPubRustFlutter/credentials-v1/qidian.dpapi',
      );
      t.view.physicalSize = const Size(1200, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value)
                    .readAsBytes()
                    .then((b) => b.buffer.asByteData()),
              ))
              .load();
        }
      });
      final (state, library, root) = (await t.runAsync(setup.fixture))!;
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = library.books.value.first.id;
      var session = LegacyCatalogSession(state, id);
      await t.runAsync(session.clearCredential);
      addTearDown(() async {
        await session.clearCredential();
        session.cancel();
      });
      final capture = GlobalKey();
      var instance = 0;
      Widget app() => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: deskTheme(),
        home: Scaffold(
          body: RepaintBoundary(
            key: capture,
            child: ColoredBox(
              color: Desk.light.canvas,
              child: CatalogSourceDialog(
                key: ValueKey(instance),
                session: session,
                pickFile: () async => null,
              ),
            ),
          ),
        ),
      );
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 500; i++) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (done()) return;
        }
        fail('credential action did not settle');
      }

      Future<void> click(String text) async {
        await t.ensureVisible(find.text(text));
        await t.tap(find.text(text));
        await t.pump();
      }

      await t.pumpWidget(app());
      await until(
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await click('访问设置');
      await t.pumpAndSettle();
      const original = 'Cookie: session=SYNTHETIC_UI_FIRST';
      var field = find.widgetWithText(TextField, '当前窗口 Cookie（可选）');
      await t.enterText(field, original);
      await click('保存到本机');
      await until(() => find.text('已在本机保护保存。').evaluate().isNotEmpty);
      expect(stored.existsSync(), true);
      final cipher = stored.readAsBytesSync();
      expect(latin1.decode(cipher), isNot(contains('SYNTHETIC_UI_FIRST')));
      expect(await t.runAsync(session.credentialSaved), true);
      await t.enterText(field, 'invalid credential');
      await click('替换本机Cookie');
      await until(
        () => find.textContaining('Cookie格式无法识别').evaluate().isNotEmpty,
      );
      expect(stored.readAsBytesSync(), cipher);
      expect(t.widget<TextField>(field).controller!.text, 'invalid credential');

      // Reopen a fresh presentation/session. Saved bytes are never returned to the UI.
      session = LegacyCatalogSession(state, id);
      instance++;
      await t.pumpWidget(app());
      await until(
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await click('访问设置');
      await t.pumpAndSettle();
      field = find.widgetWithText(TextField, '当前窗口 Cookie（可选）');
      expect(t.widget<TextField>(field).controller!.text, isEmpty);
      expect(find.text('本机已保存 · 仅用于起点目录'), findsOneWidget);
      const replacement = 'Cookie: session=SYNTHETIC_UI_SECOND';
      await t.enterText(field, replacement);
      await click('替换本机Cookie');
      await until(() => find.text('已在本机保护保存。').evaluate().isNotEmpty);
      expect(stored.readAsBytesSync(), isNot(cipher));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('$root/credential-settings.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        expect(
          (await library.saveProject('$root/credential-test.easypub.json'))
              .succeeded,
          true,
        );
        expect(
          await File('$root/credential-test.easypub.json').readAsString(),
          isNot(contains('SYNTHETIC_UI')),
        );
        // A book-scoped export is valid to store; a different request path must not receive it.
        await session.saveCredential(
          jsonEncode([
            {
              'name': 'session',
              'value': 'SYNTHETIC_SCOPE',
              'domain': '.qidian.com',
              'path': '/book/777/',
            },
          ]),
        );
        await expectLater(
          session.acquire(
            'qidian',
            'https://www.qidian.com/book/123/',
            useCache: false,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'reason',
              contains('没有适用于当前请求'),
            ),
          ),
        );
        // Explicit window input overrides the saved export (failure code proves which input reached normalization).
        await expectLater(
          session.acquire(
            'qidian',
            'https://www.qidian.com/book/123/',
            cookie: 'invalid override',
            useCache: false,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'reason',
              contains('Cookie格式无法识别'),
            ),
          ),
        );
      });
      await click('清除已保存Cookie');
      await until(() => find.text('已清除本机Cookie。').evaluate().isNotEmpty);
      expect(stored.existsSync(), false);
      expect(t.widget<TextField>(field).controller!.text, replacement);
      expect(await t.runAsync(session.credentialSaved), false);
      File('$root/credential-evidence.json').writeAsStringSync(
        jsonEncode({
          'protected': true,
          'failedReplacementPreserved': true,
          'reopenedBlankInput': true,
          'savedScopeUsed': true,
          'explicitOverrideUsed': true,
          'cleared': true,
          'projectContainsCredential': false,
        }),
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
