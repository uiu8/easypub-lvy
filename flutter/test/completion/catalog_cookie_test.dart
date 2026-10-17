import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

import 'catalog_search_test.dart' show SearchCatalog;

void main() {
  testWidgets(
    'explicit clipboard paste preserves export lines; failed paste retains last credential',
    (t) async {
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      const exported =
          '# Netscape HTTP Cookie File\n.qidian.com\tTRUE\t/\tTRUE\t0\tfixture\ttest-only';
      var fail = false;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            if (fail) throw PlatformException(code: 'test_unavailable');
            return {'text': exported};
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final session = SearchCatalog();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogSourceDialog(
              session: session,
              pickFile: () async => null,
            ),
          ),
        ),
      );
      await t.enterText(find.widgetWithText(TextField, '书名或起点书籍链接'), '合成测试');
      await t.tap(find.text('访问设置'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('粘贴Cookie'));
      await t.tap(find.text('粘贴Cookie'));
      await t.pumpAndSettle();
      final field = t.widget<TextField>(
        find.widgetWithText(TextField, '当前窗口 Cookie（可选）'),
      );
      expect(field.obscureText, true);
      expect(field.controller!.text, exported);
      fail = true;
      await t.tap(find.text('粘贴Cookie'));
      await t.pumpAndSettle();
      expect(field.controller!.text, exported);
      expect(find.text('无法读取剪贴板，请重新复制Cookie。'), findsOneWidget);
      await t.ensureVisible(find.text('搜索书名'));
      await t.tap(find.text('搜索书名'));
      await t.pumpAndSettle();
      expect(session.searchCookie, exported);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  test('native bridge rejects unsupported or inapplicable exports without echoing values', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    const marker = 'SYNTHETIC_PRIVATE_MARKER';
    for (final item in {
      'Cookie: sid=$marker\nInjected: yes': 'invalid_cookie_format',
      jsonEncode([
        {'name': 'sid', 'value': marker, 'domain': '.example.org', 'path': '/'},
      ]): 'cookie_no_applicable_entries',
      jsonEncode([
        {
          'name': 'sid',
          'value': marker,
          'domain': '.qidian.com',
          'path': '/',
          'partitionKey': 'https://example.org',
        },
      ]): 'cookie_partition_unsupported',
    }.entries) {
      final result = await api.catalogRequestText(
        request: jsonEncode({
          'op': 'acquire',
          'source': 'qidian',
          'input': 'https://www.qidian.com/book/123/',
          'use_cache': false,
        }),
        cookie: item.key,
      );
      expect(jsonDecode(result)['reason'], item.value);
      expect(result, isNot(contains(marker)));
    }
  });
}
