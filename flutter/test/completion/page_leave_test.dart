import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:window_manager/window_manager.dart';
import 'package:go_router/go_router.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/shell/workspace_leave.dart';
import 'package:easypub_desktop/desk/library/project_menu.dart';
import 'package:easypub_desktop/desk/chapters/dialogs/title_dialogs.dart';
import 'package:easypub_desktop/desk/chapters/chapter_workspace.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

import 'leave_protection_test.dart' show LeavePicker, TrackedLeaveLibrary;

class BadSavePicker extends Fake implements BookFilePicker {
  BadSavePicker(this.path);
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

  test('autosave recovers resident sources, selection and drafts after an incomplete write', () async {
    final root = (await Directory(
      '../artifacts',
    ).createTemp('workspace-recovery-')).absolute;
    var state = PrototypeState(settingsDirectory: '${root.path}/settings');
    var library = LegacyLibraryAdapter(backend: state);
    addTearDown(() async {
      await library.closeWorkspaceStorage();
      library.dispose();
      state.dispose();
    });
    await library.load();
    expect(await library.initializeWorkspace(), true);
    await library.savePatch({'check_after_import': false});
    final source = File('${root.path}/恢复样书.txt');
    const original = '第一章 原稿\n自动保存保留这段正文。\n';
    await source.writeAsString(original);
    expect((await library.importFiles([source.path])).single.succeeded, true);
    final id = library.books.value.single.id;
    library.checkBook(id, true);
    library.writeDraft('layout:$id', {'paragraph_indent': '-'});

    // A real filesystem failure must not be reported as a successful save.
    final obstruction = File('${root.path}/settings/workspace/sources');
    await obstruction.writeAsString('测试写入失败');
    expect(await library.flushWorkspace(), false);
    expect(library.workspaceSave.value.message, contains('自动保存失败'));
    expect(library.books.value.single.id, id);
    await obstruction.delete();
    expect(await library.flushWorkspace(), true);

    // Later form snapshots reuse the captured source instead of copying it.
    library.writeDraft('layout:$id', {'paragraph_indent': '1.'});
    expect(await library.flushWorkspace(), true);
    final sourceCopies = Directory('${root.path}/settings/workspace/sources')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList();
    expect(sourceCopies, hasLength(1));
    expect(await sourceCopies.single.readAsString(), original);
    await library.closeWorkspaceStorage();
    library.dispose();
    state.dispose();
    await source.writeAsString('外部已换成另一份文件。');

    // An interrupted last generation must fall back to the last committed one.
    final incomplete = Directory(
      '${root.path}/settings/workspace/snapshot-99999999999999999999-1',
    );
    await incomplete.create();
    await File('${incomplete.path}/workspace.json').writeAsString('{');
    state = PrototypeState(settingsDirectory: '${root.path}/settings');
    library = LegacyLibraryAdapter(backend: state);
    await library.load();
    expect(await library.initializeWorkspace(), true);
    expect(library.selection.value.current, id);
    expect(library.selection.value.selected, {id});
    expect(library.readDraft('layout:$id'), {'paragraph_indent': '1.'});
    expect(library.workspaceSave.value.message, '已恢复上一份完整工作区');
    expect(await File(state.current.path).readAsString(), original);
    expect(await source.readAsString(), '外部已换成另一份文件。');
    library.writeDraft('layout:$id', {'paragraph_indent': '2.'});
    expect(await library.flushWorkspace(), true);
    expect(
      await library.flushWorkspace(),
      true,
      reason: 'Retaining a damaged old snapshot cannot turn a committed save into failure',
    );
  });

  testWidgets(
    'project replacement respects mounted page guard even when project is clean',
    (t) async {
      final library = TrackedLeaveLibrary()..dirty = false;
      var allow = false, checks = 0;
      final guard = WorkspaceDraftGuard(() async {
        checks++;
        return allow;
      });
      await t.pumpWidget(
        WorkspaceDraftScope(
          guard: guard,
          child: MaterialApp(
            home: Scaffold(
              body: ProjectMenu(library: library, picker: LeavePicker()),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开项目…'));
      await t.pumpAndSettle();
      expect(checks, 1);
      expect(library.opens, 0);
      allow = true;
      await t.tap(find.text('打开项目…'));
      await t.pumpAndSettle();
      expect(checks, 2);
      expect(library.opens, 1);
    },
  );
  testWidgets(
    'native close saves edits without a save prompt and reopening restores the page and author',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final calls = <String>[];
      const channel = MethodChannel('window_manager');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'isMaximized') return false;
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late Directory root;
      late String id;
      await t.runAsync(() async {
        root = (await Directory('../artifacts').createTemp('page-leave-'))
            .absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.initializeWorkspace(), true);
        await library.savePatch({'check_after_import': false});
        final file = File('${root.path}/样书.txt')
          ..writeAsStringSync('第一章 开始\n原稿保持。\n');
        expect((await library.importFiles([file.path])).single.succeeded, true);
        id = state.currentId;
        expect(
          (await library.saveProject('${root.path}/saved.easypub.json'))
              .succeeded,
          true,
        );
        expect(await library.flushWorkspace(), true);
        expect(library.hasUnsavedChanges, false);
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await t.pumpWidget(
        RewriteApp(
          library: library,
          picker: BadSavePicker(root.path),
          initialLocation: '/books/${Uri.encodeComponent(id)}/information',
        ),
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 250; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
        fail('UI operation timed out');
      }

      Future<void> closeStorage() async {
        var closed = false;
        library.closeWorkspaceStorage().then((_) => closed = true);
        await until(() => closed);
      }

      final rename = find.byKey(const ValueKey('chapter-rename-input'));
      Future<void> openRename() async {
        final more = find.descendant(
          of: find.byType(ChapterWorkspace),
          matching: find.byTooltip('更多章节操作'),
        );
        // 正文栏窄于 700 时“更多”按设计折成图标按钮，宽时为带文字按钮。
        final action = find.descendant(
          of: more,
          matching: find.byWidgetPredicate(
            (w) => w is DeskButton || w is IconButton,
          ),
        );
        // The old layout preview also contains the chapter title. Wait for
        // the actual chapter toolbar and its asynchronous read to finish.
        await until(
          () =>
              more.hitTestable().evaluate().isNotEmpty &&
              action.evaluate().isNotEmpty &&
              switch (action.evaluate().first.widget) {
                DeskButton(:final onPressed) => onPressed != null,
                IconButton(:final onPressed) => onPressed != null,
                _ => false,
              },
        );
        await t.tap(more);
        await until(() => find.text('重命名章节').evaluate().isNotEmpty);
        await t.pump(const Duration(milliseconds: 300));
        await t.tap(find.text('重命名章节'));
        await until(() => rename.evaluate().isNotEmpty);
        await t.pump(const Duration(milliseconds: 300));
      }

      final field = find.byKey(const ValueKey('information-author'));
      await until(
        () =>
            field.evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await t.pumpAndSettle();
      final originalProject = File('${root.path}/saved.easypub.json')
          .readAsBytesSync();
      final originalSource = File('${root.path}/样书.txt').readAsBytesSync();
      await t.enterText(field, '自动保存的作者');
      windowManager.listeners.single.onWindowClose();
      await until(() => calls.contains('destroy'));
      expect(find.text('保存并继续'), findsNothing);
      expect(find.text('保留未保存的书籍信息？'), findsNothing);
      expect(calls.where((c) => c == 'destroy'), hasLength(1));
      expect(library.books.value.single.author, '自动保存的作者');
      expect(
        File('${root.path}/saved.easypub.json').readAsBytesSync(),
        originalProject,
      );
      expect(File('${root.path}/样书.txt').readAsBytesSync(), originalSource);
      await t.pumpWidget(const SizedBox.shrink());
      await closeStorage();
      library.dispose();
      state.dispose();
      await t.runAsync(() async {
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.initializeWorkspace(), true);
      });
      await t.pumpWidget(
        RewriteApp(library: library, picker: BadSavePicker(root.path)),
      );
      await until(() => field.evaluate().isNotEmpty);
      expect(t.widget<TextField>(field).controller!.text, '自动保存的作者');
      expect(library.books.value.single.author, '自动保存的作者');
      final router = GoRouter.of(t.element(field));
      router.go('/books/${Uri.encodeComponent(id)}/layout');
      final indent = find.byKey(const ValueKey('layout-paragraph_indent'));
      await until(() => indent.evaluate().isNotEmpty);
      final legalIndent = state.production.settings(id)['paragraph_indent'];
      await t.ensureVisible(indent);
      await t.enterText(indent, '-');
      calls.clear();
      windowManager.listeners.single.onWindowClose();
      await until(() => calls.contains('destroy'));
      expect(state.production.settings(id)['paragraph_indent'], legalIndent);
      await t.pumpWidget(const SizedBox.shrink());
      await closeStorage();
      library.dispose();
      state.dispose();
      await t.runAsync(() async {
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.initializeWorkspace(), true);
      });
      await t.pumpWidget(
        RewriteApp(library: library, picker: BadSavePicker(root.path)),
      );
      await until(() => indent.evaluate().isNotEmpty);
      expect(t.widget<TextField>(indent).controller!.text, '-');
      expect(state.production.settings(id)['paragraph_indent'], legalIndent);
      await t.ensureVisible(indent);
      await t.enterText(indent, '0');
      await t.pump(const Duration(seconds: 1));
      await until(() => library.readDraft('layout:$id') == null);
      expect(state.production.settings(id)['paragraph_indent'], 0);
      GoRouter.of(t.element(indent))
          .go('/books/${Uri.encodeComponent(id)}/chapters');
      await openRename();
      await t.enterText(rename, '第一章 尚未确认的标题');
      calls.clear();
      windowManager.listeners.single.onWindowClose();
      await until(() => calls.contains('destroy'));
      await t.pumpWidget(const SizedBox.shrink());
      await closeStorage();
      library.dispose();
      state.dispose();
      await t.runAsync(() async {
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.initializeWorkspace(), true);
        final chapters = library.openChapters(id);
        expect(
          (await chapters.read(0)).nodes.first.title,
          '第一章 开始',
          reason: 'Closing a dialog must not apply its proposed chapter edit',
        );
      });
      await t.pumpWidget(
        RewriteApp(library: library, picker: BadSavePicker(root.path)),
      );
      await openRename();
      expect(find.byType(ChapterRenameDialog), findsOneWidget);
      expect(t.widget<TextField>(rename).controller!.text, '第一章 尚未确认的标题');
      await t.tap(find.byTooltip('关闭改名'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await closeStorage();
    },
  );
}
