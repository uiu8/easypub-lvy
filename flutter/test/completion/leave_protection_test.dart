import 'dart:async';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:easypub_desktop/desk/shell/title_bar.dart';
import 'package:easypub_desktop/application/workspace_leave_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/library/project_menu.dart';

class LeaveLibrary implements LibraryService {
  int saves = 0, opens = 0;
  bool saveSucceeds = false;
  @override
  final books = ValueNotifier<List<BookSummary>>([
    const BookSummary(
      id: 'b',
      title: '测试',
      author: '',
      path: 'D:/book.txt',
      format: 'TXT',
      chapters: 1,
      status: '',
    ),
  ]);
  @override
  final projectBusy = ValueNotifier(false);
  @override
  final importing = ValueNotifier(false);
  @override
  Future<ProjectOutcome> saveProject(String path) async {
    saves++;
    return ProjectOutcome(saveSucceeds, '保存失败测试');
  }

  @override
  Future<ProjectOutcome> openProject(String path) async {
    opens++;
    return const ProjectOutcome(true, '打开成功');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LeavePicker implements BookFilePicker {
  @override
  Future<String?> chooseProject() async => 'D:/next.easypub.json';
  @override
  Future<String?> chooseProjectDestination() async => 'D:/saved.easypub.json';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TrackedLeaveLibrary extends LeaveLibrary
    implements WorkspaceLeaveService {
  bool dirty = true, pending = false, editDuringSave = false;
  @override
  bool get hasUnsavedChanges => dirty;
  @override
  bool get hasPendingWork => pending;
  @override
  String get workspaceIdentity => dirty ? 'changed' : 'saved';
  @override
  Future<ProjectOutcome> saveProject(String path) async {
    saves++;
    dirty = editDuringSave;
    return const ProjectOutcome(true, '已保存');
  }
}

void main() {
  testWidgets(
    'open project offers save and failed save never replaces workspace',
    (tester) async {
      final library = LeaveLibrary();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectMenu(library: library, picker: LeavePicker()),
          ),
        ),
      );
      await tester.tap(find.text('打开项目…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('保存并继续'), findsOneWidget);
      await tester.tap(find.text('保存并继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(library.saves, 1);
      expect(library.opens, 0);
      expect(find.textContaining('保存失败测试'), findsOneWidget);
    },
  );
  for (final scenario in [
    'saved',
    'discard',
    'cancel',
    'busy',
    'new-edit',
    'clean',
  ]) {
    testWidgets('workspace leave $scenario', (tester) async {
      final library = TrackedLeaveLibrary()
        ..pending = scenario == 'busy'
        ..dirty = scenario != 'clean'
        ..editDuringSave = scenario == 'new-edit';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectMenu(library: library, picker: LeavePicker()),
          ),
        ),
      );
      await tester.tap(find.text('打开项目…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (scenario == 'busy') {
        expect(find.textContaining('仍有导入'), findsOneWidget);
        expect(library.opens, 0);
      } else if (scenario == 'clean') {
        expect(library.opens, 1);
        expect(library.saves, 0);
      } else {
        final choice = scenario == 'discard'
            ? '放弃更改'
            : scenario == 'cancel'
            ? '取消'
            : '保存并继续';
        await tester.tap(find.text(choice));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          library.opens,
          scenario == 'cancel' || scenario == 'new-edit' ? 0 : 1,
        );
        if (scenario == 'new-edit') {
          expect(find.textContaining('保存期间又有修改'), findsOneWidget);
        }
      }
    });
  }
  testWidgets(
    'titlebar and native close event share guard and only approved exit destroys window',
    (tester) async {
      final calls = <String>[];
      const channel = MethodChannel('window_manager');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'isMaximized') return false;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      var guard = Completer<bool>();
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeskTitleBar(
              onClose: () {
                requests++;
                return guard.future;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(calls, contains('setPreventClose'));
      await tester.tap(find.byTooltip('关闭'));
      windowManager.listeners.single.onWindowClose();
      expect(requests, 1);
      expect(calls, isNot(contains('destroy')));
      guard.complete(false);
      await tester.pump();
      expect(calls, isNot(contains('destroy')));
      guard = Completer<bool>();
      windowManager.listeners.single.onWindowClose();
      expect(requests, 2);
      guard.complete(true);
      await tester.pump();
      expect(calls.where((c) => c == 'destroy'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
