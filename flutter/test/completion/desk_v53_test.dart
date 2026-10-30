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

/// 行号栏上某一行的点击区域（V53）。
Finder lineNumber(int line) => find.byWidgetPredicate((w) {
  final key = w.key;
  if (key is! ValueKey) return false;
  final value = key.value;
  return value is (String, String, int) &&
      value.$1 == 'line-number' &&
      value.$3 == line;
});

/// 只返回列表的假会话：用于失效提示条。
class _InvalidOnlySession implements BlockAnnotationSession {
  final notifier = ChangeNotifier();
  final deleted = <String>[];
  bool removed = false;
  @override
  Listenable get changes => notifier;
  @override
  Future<BlockAnnotationSnapshot> list() async =>
      BlockAnnotationSnapshot.fromJson({
        'content_id': 'c',
        'byte_length': 10,
        'annotations': [
          if (!removed)
            {
              'annotation': {
                'id': 'gone',
                'start': 0,
                'end': 4,
                'kind': 'letter',
                'fingerprint': 'f',
              },
              'valid': false,
              'reason': 'block_text_changed',
              'excerpt': '',
              'location': null,
            },
        ],
      });
  @override
  Future<BlockAnnotationPreview> previewDelete(String id) async {
    deleted.add(id);
    final before = await list();
    return BlockAnnotationPreview(before, before);
  }

  @override
  Future<void> confirm(BlockAnnotationPreview preview) async {
    removed = true;
  }

  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// V53：章节页手工标注界面（LAY-123）。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('章节页：行号框选、预览确认标为书信、标签改为引文、重叠给出原因，成品带引文块', (t) async {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String root, id;
    late List<int> original;
    late File source;
    await t.runAsync(() async {
      root = (await Directory('../artifacts').createTemp('v53-marks-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      source = File('$root/来信.txt')
        ..writeAsStringSync(
          '第一章 来信\n信是傍晚送到的。\n周叔：见字如面。\n港口的雾一年比一年大。\n阿青\n他把信折好。\n第二章 下山\n天亮了。\n',
        );
      original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      id = state.currentId;
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
    await until(() => lineNumber(4).evaluate().isNotEmpty, '正文行号');

    // 点第 2 行，按住 Shift 点第 4 行：选中“周叔……”到“阿青”。
    await t.tap(lineNumber(2));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.tap(lineNumber(4));
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.pump();
    expect(find.byKey(const ValueKey('block-mark-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('block-mark-bar')), findsOneWidget);

    // 第一步只预览，不写入。
    await t.tap(find.byKey(const ValueKey(('block-mark-choose', 'letter'))));
    await until(
      () => find
          .byKey(const ValueKey('block-mark-confirm'))
          .evaluate()
          .isNotEmpty,
      '确认步骤',
    );
    expect(find.textContaining('标为书信'), findsOneWidget);
    expect(annotations(), isEmpty, reason: '预览不写入');
    await t.tap(find.byKey(const ValueKey('block-mark-confirm')));
    await until(() => annotations().length == 1, '标注写入');
    expect(annotations().single['kind'], 'letter');
    await until(
      () => find.byKey(const ValueKey('block-mark-bar')).evaluate().isEmpty,
      '工具条收起',
    );

    // 标签出现在首行；点开菜单改为引文，确认后写入。
    final tagId = annotations().single['id'] as String;
    await until(
      () => find.byKey(ValueKey(('block-tag', tagId))).evaluate().isNotEmpty,
      '类型标签',
    );
    expect(find.text('书信 · 手工'), findsOneWidget);
    await t.tap(find.byKey(ValueKey(('block-tag', tagId))));
    await t.pumpAndSettle();
    await t.tap(find.byKey(ValueKey(('block-tag-change', tagId, 'quote'))));
    await until(() => find.text('修改手工标注').evaluate().isNotEmpty, '确认对话框');
    expect(find.textContaining('从“书信”改为“引文”'), findsOneWidget);
    await t.tap(find.widgetWithText(DeskButton, '确认'));
    await until(() => annotations().single['kind'] == 'quote', '改为引文');
    await until(() => find.text('引文 · 手工').evaluate().isNotEmpty, '标签刷新');

    // 已标注的行再选（V121）：选中整条标注，面板写明现在是引文，选诗词是“改为”，不再因重叠被拒绝。
    await t.tap(lineNumber(3));
    await t.pump();
    expect(
      t.widget<Text>(find.byKey(const ValueKey('block-mark-current'))).data,
      '现在：引文（手工标注）',
    );
    await t.tap(find.byKey(const ValueKey(('block-mark-choose', 'verse'))));
    await until(
      () => find
          .byKey(const ValueKey('block-mark-confirm'))
          .evaluate()
          .isNotEmpty,
      '改为诗词的确认',
    );
    expect(find.textContaining('改为诗词'), findsOneWidget);
    expect(find.byKey(const ValueKey('block-mark-remove')), findsOneWidget);
    expect(annotations().length, 1);
    await t.tap(find.byKey(const ValueKey('block-mark-cancel')));
    await t.pump();
    expect(find.byKey(const ValueKey('block-mark-bar')), findsNothing);
    expect(t.takeException(), isNull);

    // 界面写入的标注进入成品。
    await t.runAsync(() async {
      final session = LegacyConversionSession(state);
      try {
        final plan = await session.preview(
          ConversionRequest(
            books: [id],
            directory: '$root/out',
            format: 'EPUB',
            runChecks: false,
          ),
        );
        final result = (await session.commit(
          plan,
          acknowledgeWarnings: true,
        )).single;
        expect(result.complete, true, reason: result.detail);
        final run = await Process.run(
          Platform.environment['EASYPUB_TEST_PYTHON']!,
          [
            '-X',
            'utf8',
            '-c',
            r'''
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 print('\n'.join(z.read(n).decode('utf-8') for n in z.namelist() if n.endswith('.xhtml')))
''',
            result.path,
          ],
          stdoutEncoding: utf8,
        );
        expect(run.stdout as String, contains('quote-block'));
      } finally {
        session.dispose();
      }
      expect(source.readAsBytesSync(), original);
    });
  });

  testWidgets('失效提示条：显示条数与原因，删除后提示条消失', (t) async {
    final session = _InvalidOnlySession();
    final controller = BlockMarkController(session);
    addTearDown(controller.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => BlockInvalidBanner(controller: controller),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('本书有 1 条手工标注因书稿改动已失效'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('block-invalid-show')));
    await t.pumpAndSettle();
    expect(find.text('原位置的文字已改变，请重新标注或删除。'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey(('block-invalid-delete', 'gone'))));
    await t.pumpAndSettle();
    expect(session.deleted, ['gone']);
    expect(find.text('没有失效的标注。'), findsOneWidget);
    await t.tap(find.widgetWithText(DeskButton, '关闭'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('block-invalid-banner')), findsNothing);
  });
}
