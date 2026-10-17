import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/cleanup/rule_dialog.dart';
import 'package:easypub_desktop/desk/cleanup/range_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

void main() {
  testWidgets(
    'rule forms feed Rust notice protection, numbering, punctuation and inclusive source ranges',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = PrototypeState();
      addTearDown(backend.dispose);
      final dir = Directory(
        '../artifacts/frontend-rewrite/cleanup-rules-probe',
      );
      final file = File('${dir.path}/规则样书.txt');
      const original =
          '第一章 夜渡\n夜色,价格1,234.56 http://example.com/a?b=1&x=2\n[推广]关注本站\n正文引用：[推广]他读到一段话。\nabc广告\n第二章 来信\n001 附记\n结尾  \n';
      await tester.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            File(
              Platform.environment['EASYPUB_TEST_DLL'] ??
                  '../target/release/easypub_bridge.dll',
            ).absolute.path,
          ),
        );
        await dir.create(recursive: true);
        await file.writeAsString(original);
        for (final entry in {
          'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value)
                    .readAsBytes()
                    .then((v) => v.buffer.asByteData()),
              ))
              .load();
        }
        await backend.importBookOutcome(file.absolute.path);
      });
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(library.dispose);
      final session = library.openCleanup(backend.currentId);
      addTearDown(session.dispose);
      final capture = GlobalKey();
      Future<void> shot(String name) => tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${dir.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      Future<Map<String, dynamic>> form(
        Map<String, dynamic> initial,
        Future<void> Function() edit,
        String name,
      ) async {
        Map<String, dynamic>? result;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: deskTheme(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (_) => CleanupRuleDialog(initial: initial),
                      );
                    },
                    child: const Text('打开规则'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开规则'));
        await tester.pumpAndSettle();
        await edit();
        await tester.pumpAndSettle();
        await shot(name);
        final accept = find.byKey(const ValueKey('cleanup-rule-accept'));
        expect(
          accept.hitTestable(),
          findsOneWidget,
          reason: '规则表单滚动后，固定底部的采用按钮仍可点击',
        );
        await tester.tap(accept);
        await tester.pumpAndSettle();
        expect(result, isNotNull);
        return result!;
      }

      Future<void> fill(String label, String text) async {
        final field = find.byWidgetPredicate(
          (v) => v is TextField && v.decoration?.labelText == label,
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, text);
        await tester.pumpAndSettle();
      }

      Future<void> toggle(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      final notice = await form(
        {
          'kind': 'notice_lines',
          'options': {
            'include_defaults': false,
            'include_headers': false,
            'ignore_case': false,
            'keywords': [],
            'preserve_keywords': [],
            'pattern': null,
            'preserve_pattern': null,
          },
        },
        () async {
          await tester.enterText(
            find.byKey(const ValueKey('cleanup-rule-name')),
            '推广候选与正文保护',
          );
          await toggle('忽略大小写');
          await fill('候选关键词（每行一个）', '[推广]');
          await fill('优先保留关键词（每行一个）', '正文引用');
          await fill('候选匹配条件（可为空）', '^ABC');
          await toggle('候选条件使用正则');
          await fill('优先保留条件（可为空）', '^正文引用');
          await toggle('保留条件使用正则');
        },
        'notice-rule',
      );
      expect(notice['name'], '推广候选与正文保护');
      expect(notice['rule']['options']['ignore_case'], true);
      await tester.runAsync(() async {
        final request = {
          'kind': 'cleanup',
          'pipeline': [notice],
        };
        final plan = await session.preview(jsonEncode(request));
        expect(plan.candidates.map((v) => v.line), [3, 4, 5]);
        expect(
          plan.candidates.singleWhere((v) => v.line == 4).selectable,
          false,
        );
        expect(plan.total, 0);
        await expectLater(
          session.preview(
            jsonEncode({
              ...request,
              'remove_lines': [4],
            }),
          ),
          throwsA(isA<api.ApiError>()),
        );
        final selected = await session.preview(
          jsonEncode({
            ...request,
            'remove_lines': [3, 5],
          }),
        );
        expect(selected.actions.map((v) => v.line), [3, 5]);
        expect(backend.cleanup.drafts, isEmpty);
      });
      final numbers = await form(
        {
          'kind': 'configured',
          'enabled': true,
          'scope': 'headings',
          'rule': {
            'kind': 'chapter_numbers',
            'style': 'arabic',
            'bare_titles': false,
          },
        },
        () async => toggle('同时识别数字开头的标题'),
        'number-rule',
      );
      expect(numbers['scope'], 'all');
      expect(numbers['rule']['bare_titles'], true);
      await tester.runAsync(() async {
        final plan = await session.preview(
          jsonEncode({
            'kind': 'cleanup',
            'pipeline': [numbers],
          }),
        );
        expect(
          plan.actions.any((v) => v.line == 1 && v.after!.contains('第1章')),
          true,
        );
        expect(plan.actions.any((v) => v.line == 7), true);
      });
      final punctuation = await form(
        {
          'kind': 'chinese_punctuation',
          'options': {
            'marks': true,
            'ellipsis': true,
            'dashes': true,
            'quotes': true,
          },
        },
        () async => toggle('成对重复弯引号'),
        'punctuation-rule',
      );
      expect(punctuation['rule']['options']['quotes'], false);
      await tester.runAsync(() async {
        final plan = await session.preview(
          jsonEncode({
            'kind': 'cleanup',
            'pipeline': [punctuation],
          }),
        );
        final value = plan.actions.singleWhere((v) => v.line == 2).after!;
        expect(value, contains('夜色，价格1,234.56'));
        expect(value, contains('http://example.com/a?b=1&x=2'));
      });
      CleanupRange? range;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  range = await showDialog<CleanupRange>(
                    context: context,
                    builder: (_) => const CleanupRangeDialog(),
                  );
                },
                child: const Text('范围'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('范围'));
      await tester.pumpAndSettle();
      await fill('起始源行', '8');
      await fill('结束源行', '2');
      await tester.tap(find.text('使用此范围'));
      await tester.pumpAndSettle();
      expect(find.text('结束源行不能早于起始源行。'), findsOneWidget);
      expect(range, isNull);
      await fill('结束源行', '8');
      await tester.tap(find.text('使用此范围'));
      await tester.pumpAndSettle();
      expect(range!.start, 8);
      expect(range!.end, 8);
      await tester.runAsync(() async {
        final plan = await session.preview(
          jsonEncode({
            'kind': 'cleanup',
            'pipeline': [
              punctuation,
              {'kind': 'trim_trailing_spaces'},
            ],
            'start_line': range!.start,
            'end_line': range!.end,
          }),
        );
        expect(plan.total, 1);
        expect(plan.actions.single.line, 8);
        expect(plan.actions.single.after, '结尾');
        expect(await file.readAsString(), original);
        expect(backend.cleanup.drafts, isEmpty);
      });
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
