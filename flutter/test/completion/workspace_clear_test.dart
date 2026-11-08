import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';

import 'library_removal_test.dart' as fixtures;

class ClearPicker implements BookFilePicker {
  ClearPicker(this.destination);
  String? destination;
  @override
  Future<String?> chooseProjectDestination() async => destination;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'clear has one dedicated confirmation, preserves source and explicit project, then releases the workspace',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      const channel = MethodChannel('window_manager');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await t.runAsync(
        () async => RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        ),
      );
      final fixture = await t.runAsync(fixtures.fixture);
      final (state, library, root) = fixture!;
      await t.runAsync(library.initializeWorkspace);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final id = library.books.value.first.id;
      final sourcePath = library.books.value.first.path;
      final sourceBytes = File(sourcePath).readAsBytesSync();
      final globals = jsonDecode(jsonEncode(state.globalConfiguration));
      final oldIds = library.books.value.map((b) => b.id).toSet();
      final oldEpoch = library.workspaceGeneration.value;
      final oldCleanup = library.openCleanup(id);
      addTearDown(oldCleanup.dispose);
      late CleanupPreview oldPreview;
      await t.runAsync(() async {
        oldPreview = await oldCleanup.preview(
          jsonEncode({
            'kind': 'cleanup',
            'pipeline': [
              {'kind': 'trim_trailing_spaces'},
            ],
          }),
        );
      });
      final picker = ClearPicker(root);
      await t.pumpWidget(
        RewriteApp(
          library: library,
          picker: picker,
          initialLocation: '/books/${Uri.encodeComponent(id)}/information',
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 400; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('workspace did not settle');
      }

      Future<void> flushWorkspace() async {
        bool? saved;
        Object? failure;
        // A debounce save may already belong to the test's fake-async zone.
        // Keep pumping that zone while disk I/O completes in runAsync.
        library.flushWorkspace().then<void>(
          (value) {
            saved = value;
          },
          onError: (Object error) {
            failure = error;
          },
        );
        for (var i = 0; i < 400 && saved == null && failure == null; i++) {
          await t.pump(const Duration(milliseconds: 20));
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(failure, isNull);
        expect(saved, true, reason: '自动保存必须真正完成，不能只等待界面静止');
      }

      await settle();
      final author = find.byKey(const ValueKey('information-author'));
      await t.enterText(author, '尚未应用的作者');
      await t.tap(find.text('项目'));
      await t.pumpAndSettle();
      await t.tap(find.text('清空当前工作区…'));
      for (
        var i = 0;
        i < 300 && find.text('清空当前工作区？').evaluate().isEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('清空当前工作区？'), findsOneWidget);
      await t.tap(find.text('取消'));
      await settle();
      expect(library.books.value.map((b) => b.id).toSet(), oldIds);
      expect(library.workspaceGeneration.value, oldEpoch);
      expect(t.widget<TextField>(author).controller!.text, '尚未应用的作者');
      expect(find.text('打开项目…'), findsNothing);
      await t.pump(const Duration(seconds: 1));
      await settle();
      picker.destination = '$root/before-clear.easypub.json';
      await flushWorkspace();
      await t.runAsync(() async {
        expect(
          (await library.saveProject(picker.destination!)).succeeded,
          true,
        );
      });
      await t.tap(find.text('项目'));
      await t.pumpAndSettle();
      await t.tap(find.text('清空当前工作区…'));
      for (
        var i = 0;
        i < 300 && find.text('清空当前工作区？').evaluate().isEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('清空工作区'));
      for (var i = 0; i < 300 && library.books.value.isNotEmpty; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      await settle();
      await flushWorkspace();
      expect(find.text('保存并继续'), findsNothing);
      expect(library.books.value, isEmpty);
      expect(library.workspaceGeneration.value, oldEpoch + 1);
      expect(find.byKey(const ValueKey('information-author')), findsNothing);
      expect(state.globalConfiguration, globals);
      expect(library.hasUnsavedChanges, false);
      expect(state.projectPath, isEmpty);
      final saved = File(picker.destination!).readAsBytesSync();
      await t.runAsync(() async {
        state.change(() => state.cleanup.historyBusy = true);
        expect((await library.clearWorkspace()).succeeded, false);
        state.change(() => state.cleanup.historyBusy = false);
        expect(
          (await library.saveProject('$root/empty.easypub.json')).succeeded,
          true,
        );
        expect(
          (await library.importFiles([sourcePath])).single.succeeded,
          true,
        );
        expect(library.books.value.length, 1);
        expect(oldCleanup.isCurrent(oldPreview), false);
        await expectLater(oldCleanup.apply(oldPreview), throwsFormatException);
        expect(
          (await library.openProject(picker.destination!)).succeeded,
          true,
        );
        expect(library.books.value.map((b) => b.id).toSet(), oldIds);
        expect(File(sourcePath).readAsBytesSync(), sourceBytes);
        expect(File(picker.destination!).readAsBytesSync(), saved);
      });
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
