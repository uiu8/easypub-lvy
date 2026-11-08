import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/manual_note_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/chapters/note_marks.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

/// 行号栏上某一行（本节正文行号，从 1 开始）的点击区域。
Finder lineNumber(int line) => find.byWidgetPredicate((w) {
  final key = w.key;
  if (key is! ValueKey) return false;
  final value = key.value;
  return value is (String, String, int) &&
      value.$1 == 'line-number' &&
      value.$3 == line;
});

/// 只返回失效注释的假会话：用于失效提示条。
class _InvalidOnlySession implements ManualNoteSession {
  final notifier = ChangeNotifier();
  bool removed = false;
  @override
  Listenable get changes => notifier;
  @override
  Future<ManualNoteSnapshot> list() async => ManualNoteSnapshot.fromJson({
    'content_id': 'c',
    'notes': [
      if (!removed)
        {
          'id': 'gone',
          'kind': 'new',
          'valid': false,
          'enabled': true,
          'reason': 'note_text_changed',
          'marker': '',
          'text': '旧注释',
          'location': null,
          'definition_location': null,
          'note': null,
        },
    ],
  });
  @override
  Future<ManualNotePreview> previewDelete(String id) async {
    final before = await list();
    return ManualNotePreview(before, before);
  }

  @override
  Future<void> confirm(ManualNotePreview preview) async => removed = true;
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// V62：章节页手工注释界面（LAY-128），真实 DLL。
void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );

  testWidgets('补配对、新写注释、标签与删除，均先预览再确认；原稿不变', (t) async {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    late String id;
    late File source;
    late List<int> original;
    const marked = '　　港口的雾（甲）从傍晚开始往岸上爬。';
    await t.runAsync(() async {
      final root = (await Directory('../artifacts').createTemp('v62-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
      await library.savePatch({'check_after_import': false});
      source = File('$root/雾港.txt')
        ..writeAsStringSync(
          '第一章 雾港\n$marked\n作者注：雾是近地面的小水滴。\n　　旧码头在晨光里。\n'
          '第二章 下山\n天亮了。\n',
        );
      original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      id = state.currentId;
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    List<Map> notes() =>
        ((state.production.settings(id)['manual_notes'] as List?) ?? const [])
            .cast<Map>();
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

    bool shown(Finder f) => f.evaluate().isNotEmpty;
    TextEditingController controllerOf(String key) =>
        t.widget<TextField>(find.byKey(ValueKey(key))).controller!;

    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ChapterWorkspace(library: library, bookId: id),
        ),
      ),
    );
    await until(() => shown(lineNumber(3)), '正文行号');

    // 补配对：第 1 行选中“（甲）”，注释行选第 2 行。
    await t.tap(lineNumber(1));
    await until(() => shown(find.byKey(const ValueKey('note-open'))), '工具条');
    await t.tap(find.byKey(const ValueKey('note-open')));
    await until(
      () => shown(find.byKey(const ValueKey('note-line-text'))),
      '注释对话框',
    );
    final preview = find.byKey(const ValueKey('note-preview'));
    expect(t.widget<DeskButton>(preview).onPressed, isNull, reason: '还没选位置');
    controllerOf('note-line-text').selection = TextSelection(
      baseOffset: marked.indexOf('（甲）'),
      extentOffset: marked.indexOf('（甲）') + 3,
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey(('note-definition', 2))));
    await t.pump();
    await t.tap(preview);
    await until(
      () => shown(find.byKey(const ValueKey('note-preview-body'))),
      '配对预览',
    );
    expect(find.textContaining('“（甲）”将链接到'), findsOneWidget);
    expect(notes(), isEmpty, reason: '预览不写入');
    await t.tap(find.byKey(const ValueKey('note-confirm')));
    await until(() => notes().length == 1, '写入配对');
    await until(
      () => find.byType(ManualNoteDialog).evaluate().isEmpty,
      '配对对话框关闭',
    );
    expect(notes().single['body']['kind'], 'pair');
    final pairId = notes().single['id'] as String;
    await until(
      () => shown(find.byKey(ValueKey(('note-tag', pairId, false)))),
      '引用行标签',
    );
    expect(find.byKey(ValueKey(('note-tag', pairId, true))), findsOneWidget);
    expect(find.text('注 · 配对 → 第 3 行'), findsOneWidget);

    // 新写注释：第 3 行第 4 个字之后，两段文字。
    await t.tap(lineNumber(3));
    await until(() => shown(find.byKey(const ValueKey('note-open'))), '工具条');
    await t.tap(find.byKey(const ValueKey('note-open')));
    await until(() => shown(find.byKey(const ValueKey('note-mode'))), '对话框');
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('note-mode')),
        matching: find.text('新写注释'),
      ),
    );
    await t.pump();
    controllerOf('note-line-text').selection = const TextSelection.collapsed(
      offset: 5,
    );
    await t.enterText(
      find.byKey(const ValueKey('note-text')),
      '旧码头：清末修建。\n第二段：可以分段。',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey('note-preview')));
    await until(
      () => shown(find.byKey(const ValueKey('note-preview-body'))),
      '新写预览',
    );
    expect(notes(), hasLength(1));
    expect(find.textContaining('旧码头：清末修建。'), findsWidgets);
    final confirm = find.byKey(const ValueKey('note-confirm'));
    await t.ensureVisible(confirm);
    await t.pump();
    expect(t.widget<DeskButton>(confirm).onPressed, isNotNull);
    await t.tap(confirm);
    await until(() => notes().length == 2, '写入新写注释');
    final newId =
        notes().firstWhere((n) => n['body']['kind'] == 'new')['id'] as String;
    expect(
      notes().firstWhere((n) => n['id'] == newId)['body']['text'],
      '旧码头：清末修建。\n第二段：可以分段。',
    );
    final tag = find.byKey(ValueKey(('note-tag', newId, false)));
    await until(() => shown(tag), '新写标签');

    // 标签菜单删除：先确认。
    await t.tap(tag);
    await t.pump();
    await t.tap(find.byKey(ValueKey(('note-tag-delete', newId, false))));
    await until(
      () => shown(find.byKey(const ValueKey('note-delete-confirm'))),
      '删除确认',
    );
    expect(notes(), hasLength(2));
    await t.tap(find.byKey(const ValueKey('note-delete-confirm')));
    await until(() => notes().length == 1, '删除');
    expect(notes().single['id'], pairId);
    expect(source.readAsBytesSync(), original);
    expect(t.takeException(), isNull);
  });

  testWidgets('失效注释：提示条显示条数，列表中删除后提示条消失', (t) async {
    final session = _InvalidOnlySession();
    final controller = NoteMarkController(session);
    addTearDown(controller.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(body: NoteInvalidBanner(controller: controller)),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.textContaining('1 条手工注释'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('note-invalid-show')));
    await t.pumpAndSettle();
    expect(find.textContaining('原位置的文字或换行已改变'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey(('note-invalid-delete', 'gone'))));
    await t.pumpAndSettle();
    await t.tap(find.text('关闭').last);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-invalid-banner')), findsNothing);
  });
}
