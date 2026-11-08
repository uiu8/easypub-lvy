import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/block_annotation_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/chapters/block_marks.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/layout/layout_page.dart';

const sample =
    '第一章 群聊\n正文。\n— 22:01 —\n【四：以雕像作为封印阵法。】\n【一：眉心开裂？】\n【四：有可能。】\n后文。\n'
    '奉天承运 皇帝诏曰\n着即晋封国公。\n钦此\n契约\n立约人以血为誓。\n——灰塔之印\n'
    '林小满 @xiaoman · 3 分钟前\n今天的江面。\n转发 12 评论 34 赞 560\n沈舟：拍得真好\n'
    '吾儿见字如面：\n勿念家中。\n母字\n结尾。\n';

Finder lineNumber(int line) => find.byWidgetPredicate((w) {
  final key = w.key;
  if (key is! ValueKey) return false;
  final value = key.value;
  return value is (String, String, int) &&
      value.$1 == 'line-number' &&
      value.$3 == line;
});

Future<Map<String, String>> members(String path) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import json,sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 print(json.dumps({n:(z.read(n).decode('utf-8','replace') if n.rsplit('.',1)[-1].lower() in ('opf','xhtml','html','htm','css') else str(len(z.read(n)))) for n in z.namelist()},ensure_ascii=False))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Map<String, String>.from(jsonDecode(result.stdout as String) as Map);
}

Future<(PrototypeState, LegacyLibraryAdapter, String, String)> book(
  String tag,
) async {
  final root = (await Directory('../artifacts').createTemp('v81-$tag-'))
      .absolute
      .path;
  final state = PrototypeState(settingsDirectory: '$root/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  final file = File('$root/场景.txt')..writeAsStringSync(sample);
  expect((await library.importFiles([file.path])).single.succeeded, true);
  return (state, library, root, state.currentId);
}

/// V81：场景样式（LAY-135）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  test('场景选项名称与标识', () {
    expect(insetMarkChoices.length, 9);
    expect(blockMarkLabel(BlockAnnotationKind.inset, 'scroll'), '场景 · 羊皮纸');
    expect(blockMarkKey(BlockAnnotationKind.inset, 'edict'), 'inset-edict');
    expect(blockMarkLabel(BlockAnnotationKind.letter), '书信');
  });

  testWidgets('章节页：选中几行标为“场景 · 诏书”，标签改为古籍', (t) async {
    t.view.physicalSize = const Size(1440, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final made = await book('marks');
      (state, library, _, id) = made;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> until(bool Function() ready, String what) async {
      for (var i = 0; i < 400; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('未就绪：$what');
    }

    List annotations() =>
        (state.production.settings(id)['block_annotations'] as List?) ??
        const [];
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterWorkspace(library: library, bookId: id),
        ),
      ),
    );
    await until(() => lineNumber(9).evaluate().isNotEmpty, '正文行号');
    // 第 7–9 行：奉天承运……钦此。
    await t.tap(lineNumber(7));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.tap(lineNumber(9));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('block-mark-inset')));
    await t.pumpAndSettle();
    for (final type in ['chat', 'post', 'scroll', 'news']) {
      expect(
        find.byKey(ValueKey(('block-mark-choose', 'inset-$type'))),
        findsOneWidget,
      );
    }
    await t.tap(
      find.byKey(const ValueKey(('block-mark-choose', 'inset-edict'))),
    );
    await until(
      () => find
          .byKey(const ValueKey('block-mark-confirm'))
          .evaluate()
          .isNotEmpty,
      '确认步骤',
    );
    expect(find.textContaining('标为场景 · 诏书'), findsOneWidget);
    expect(annotations(), isEmpty, reason: '预览不写入');
    await t.tap(find.byKey(const ValueKey('block-mark-confirm')));
    await until(() => annotations().length == 1, '标注写入');
    expect(annotations().single['kind'], 'inset');
    expect(annotations().single['variant'], 'edict');
    final tagId = annotations().single['id'] as String;
    await until(
      () => find.byKey(ValueKey(('block-tag', tagId))).evaluate().isNotEmpty,
      '类型标签',
    );
    expect(find.text('场景 · 诏书 · 手工'), findsOneWidget);
    // 标签菜单 → 改为场景 → 古籍。
    await t.tap(find.byKey(ValueKey(('block-tag', tagId))));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey(('block-tag-change-inset', tagId))));
    await t.pumpAndSettle();
    expect(
      find.byKey(ValueKey(('block-tag-change', tagId, 'inset-edict'))),
      findsNothing,
      reason: '当前场景不列出',
    );
    await t.tap(
      find.byKey(ValueKey(('block-tag-change', tagId, 'inset-classic'))),
    );
    await until(() => find.text('修改手工标注').evaluate().isNotEmpty, '确认对话框');
    expect(find.textContaining('从“场景 · 诏书”改为“场景 · 古籍”'), findsOneWidget);
    await t.tap(find.widgetWithText(DeskButton, '确认'));
    await until(() => annotations().single['variant'] == 'classic', '改为古籍');
    expect(t.takeException(), isNull);
  });

  testWidgets('排版页：场景样式三项（新书默认群聊窗口、信笺格线、楷体）', (t) async {
    t.view.physicalSize = const Size(1100, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    await t.runAsync(() async {
      final made = await book('layout');
      (state, library, _, id) = made;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 600; i++) {
        await t.pump(const Duration(milliseconds: 20));
        if (ready()) return;
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      fail('界面未就绪');
    }

    Map<String, dynamic> settings() => state.production.settings(id);
    expect(settings()['chat_block_style'], 'window');
    expect(settings()['letter_block_style'], 'ruled');
    expect(settings()['inset_font'], 'kai');
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: LayoutPage(
            library: library,
            bookId: id,
            navigation: LayoutNavigationGuard(),
            pickPresetFile: () async => null,
            pickPresetDestination: () async => null,
            importCss: () async => null,
          ),
        ),
      ),
    );
    final tabs = find.byKey(const ValueKey('layout-tabs'));
    await until(() => tabs.evaluate().isNotEmpty);
    await t.tap(find.descendant(of: tabs, matching: find.text('段落与识别')));
    await t.pump();
    for (final (field, label, value) in [
      ('chat_block_style', '剧本对白', 'script'),
      ('letter_block_style', '普通', 'plain'),
      ('inset_font', '正文字体', 'body'),
    ]) {
      final row = find.byKey(ValueKey('layout-row-$field'));
      await until(() => row.evaluate().isNotEmpty);
      await t.ensureVisible(row);
      await t.tap(row);
      await t.pump();
      final seg = find.byKey(ValueKey('layout-$field'));
      await until(() => seg.evaluate().isNotEmpty);
      await t.ensureVisible(seg);
      await t.pump();
      await t.tap(find.descendant(of: seg, matching: find.text(label)));
      await until(() => settings()[field] == value);
    }
    expect(t.takeException(), isNull);
  });

  test('手工场景、自动聊天、书信格线：真实转换 EPUB、AZW3、KFX', () async {
    final (state, library, root, id) = await book('output');
    final bokai = Platform.environment['EASYPUB_TEST_BOKAI']!;
    try {
      final session = library.openBlockAnnotations(id);
      int offset(String marker) =>
          utf8.encode(sample.substring(0, sample.indexOf(marker))).length;
      Future<void> mark(
        String from,
        String to,
        BlockAnnotationKind kind, [
        String? variant,
      ]) async {
        final snap = await session.list();
        await session.confirm(
          await session.previewAdd(
            snap,
            start: offset(from),
            end: offset(to),
            kind: kind,
            variant: variant,
          ),
        );
      }

      await mark('奉天承运', '契约', BlockAnnotationKind.inset, 'edict');
      await mark('契约', '林小满', BlockAnnotationKind.inset, 'scroll');
      await mark('林小满', '吾儿', BlockAnnotationKind.inset, 'post');
      await mark('吾儿', '结尾', BlockAnnotationKind.letter);
      expect((await session.list()).annotations.map((a) => a.variant), [
        'edict',
        'scroll',
        'post',
        null,
      ]);
      session.dispose();

      Future<String> convert(String format, String dir) async {
        final s = LegacyConversionSession(state);
        try {
          final plan = await s.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/$dir',
              format: format,
              engine: switch (format) {
                'KFX' => bokai,
                'AZW3' => Platform.environment['EASYPUB_TEST_KINDLING']!,
                _ => '',
              },
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(
            plan.previewed,
            true,
            reason: plan.findings
                .map((f) => '${f.title} ${f.detail}')
                .join('; '),
          );
          final r = (await s.commit(plan, acknowledgeWarnings: true)).single;
          expect(r.complete, true, reason: '$dir $format ${r.detail}');
          return r.path;
        } finally {
          s.dispose();
        }
      }

      for (final look in ['window', 'script', 'channel']) {
        final change = await state.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'chat_block_style': {'op': 'set', 'value': look},
            },
          },
        });
        expect(await state.production.confirm(change), true);
        final epub = await members(await convert('EPUB', 'epub-$look'));
        final xhtml = epub.entries
            .where((e) => e.key.endsWith('.xhtml'))
            .map((e) => e.value)
            .join('\n');
        final css = epub.entries
            .where((e) => e.key.endsWith('.css'))
            .map((e) => e.value)
            .join('\n');
        // V82 起聊天块按名字位置分类：群聊窗口在上方、剧本居中、频道同一行。
        final names = {
          'window': 'block',
          'script': 'center',
          'channel': 'inline',
        }[look];
        expect(xhtml, contains('class="inset inset-chat inset-names-$names"'));
        expect(xhtml, contains('inset-line inset-time'));
        if (look == 'channel') {
          expect(xhtml, contains('<span class="inset-who">四</span> ▷ '));
        } else {
          expect(xhtml, contains('<p class="inset-line inset-who">四</p>'));
        }
        expect(xhtml, isNot(contains('blk blk-')), reason: '聊天优先于系统提示');
        expect(xhtml, contains('class="inset inset-edict"'));
        expect(xhtml, contains('class="inset inset-scroll"'));
        expect(xhtml, contains('<p class="inset-rod"><img src="'));
        expect(xhtml, contains('<span class="inset-drop">立</span>'));
        expect(xhtml, contains('class="inset inset-post"'));
        expect(xhtml, contains('inset-line inset-count'));
        expect(xhtml, contains('inset-line inset-reply'));
        expect(xhtml, contains('class="letter-block letter-ruled"'));
        expect(
          css,
          contains(
            '.inset-scroll .inset-inner { padding: 0.4em 0.9em; background-image:',
          ),
        );
        expect(css, contains('"STKai", "楷体", KaiTi'));
        expect(
          epub.keys.where((k) => k.endsWith('.png')).length,
          greaterThanOrEqualTo(2),
          reason: '卷轴杆与纸纹',
        );
        // KFX 由 Bokai 转换并校验（validate all）。
        await convert('KFX', 'kfx-$look');
      }
      await convert('AZW3', 'azw3');
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
