import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:go_router/go_router.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/metadata/book_information_page.dart';
import 'package:easypub_desktop/desk/library/library_page.dart';
import 'package:easypub_desktop/desk/library/project_menu.dart';

class SwitchingPicker extends Fake implements BookFilePicker {
  String? project;
  @override
  Future<String?> chooseProject() async => project;
}

class ResetDesktop extends Fake
    implements ConversionDesktop, OutputDirectoryDesktop {
  ResetDesktop(this.directory);
  final String directory;
  @override
  Future<String?> bundledConverter() async => null;
  @override
  Future<String> defaultOutputDirectory() async => directory;
}

void main() {
  testWidgets(
    'accepted same-book project replaces old editor; failed open preserves draft and route',
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
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late Directory root;
      late String id, a, b;
      await t.runAsync(() async {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(
            Platform.environment['EASYPUB_TEST_DLL']!,
          ),
        );
        root = (await Directory('../artifacts').createTemp('project-reset-'))
            .absolute;
        state = PrototypeState(settingsDirectory: '${root.path}/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.initializeWorkspace(), true);
        await library.savePatch({'check_after_import': false});
        final file = File('${root.path}/样书.txt')
          ..writeAsStringSync('第一章 开始\n保持正文。\n');
        expect((await library.importFiles([file.path])).single.succeeded, true);
        id = state.currentId;
        final info = library.openBookInformation(id);
        await info.apply(await info.preview({'author': '甲项目作者'}));
        a = '${root.path}/a.easypub.json';
        b = '${root.path}/b.easypub.json';
        expect((await library.saveProject(a)).succeeded, true);
        final before = library.workspaceGeneration.value;
        await info.apply(await info.preview({'author': '乙项目作者'}));
        expect((await library.saveProject(b)).succeeded, true);
        expect(
          library.workspaceGeneration.value,
          before,
          reason: 'edits and saves are not replacement events',
        );
        info.dispose();
        expect((await library.openProject(a)).succeeded, true);
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      final picker = SwitchingPicker()
        ..project = '${root.path}/missing.easypub.json';
      await t.pumpWidget(
        RewriteApp(
          library: library,
          picker: picker,
          initialLocation: '/conversion',
          conversionDesktop: ResetDesktop(root.path),
        ),
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 300; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
        fail('Expected project UI state did not arrive');
      }

      await until(
        () =>
            find.byType(TextField).evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await t.pumpAndSettle();
      final oldConversion = t.widget<ConversionPage>(
        find.byType(ConversionPage),
      );
      final oldDirectory = '${root.path}/old-project-only';
      await t.enterText(find.byType(TextField), oldDirectory);
      expect(oldConversion.draft.directory, oldDirectory);
      GoRouter.of(t.element(find.byType(ConversionPage)))
          .go('/books/${Uri.encodeComponent(id)}/information');
      final field = find.byKey(const ValueKey('information-author'));
      await until(() => field.evaluate().isNotEmpty);
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field).controller!.text, '甲项目作者');
      await t.enterText(field, '旧页未应用输入');
      final oldRouter = GoRouter.of(
        t.element(find.byType(BookInformationPage)),
      );
      final generation = library.workspaceGeneration.value;
      await t.tap(find.text('项目'));
      await t.pumpAndSettle();
      await t.tap(find.text('打开项目…'));
      await until(
        () =>
            find.byType(ProjectMenu).evaluate().isNotEmpty &&
            !library.projectBusy.value &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await t.pumpAndSettle();
      expect(library.workspaceGeneration.value, generation);
      expect(
        find.byType(BookInformationPage, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('打开项目…'), findsNothing);
      expect(find.byType(ProjectMenu), findsOneWidget);
      expect(t.widget<TextField>(field).controller!.text, '旧页未应用输入');
      expect(
        identical(
          GoRouter.of(t.element(find.byType(BookInformationPage))),
          oldRouter,
        ),
        true,
      );
      picker.project = b;
      await t.tap(find.text('项目'));
      await t.pumpAndSettle();
      await t.tap(find.text('打开项目…'));
      await until(
        () =>
            find.byType(LibraryPage).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await t.pumpAndSettle();
      expect(library.workspaceGeneration.value, generation + 1);
      expect(find.byType(ProjectMenu), findsOneWidget);
      expect(find.byType(BookInformationPage), findsNothing);
      expect(library.books.value.single.author, '乙项目作者');
      final router = GoRouter.of(t.element(find.byType(LibraryPage)));
      expect(identical(router, oldRouter), false);
      router.go('/conversion');
      await until(
        () =>
            find.byType(ConversionPage).evaluate().isNotEmpty &&
            t
                .widget<ConversionPage>(find.byType(ConversionPage))
                .draft
                .initialized &&
            find.byType(TextField).evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await until(
        () =>
            !t.binding.hasScheduledFrame &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await t.pumpAndSettle();
      final newConversion = t.widget<ConversionPage>(
        find.byType(ConversionPage),
      );
      expect(identical(newConversion.draft, oldConversion.draft), false);
      expect(identical(newConversion.session, oldConversion.session), false);
      expect(newConversion.draft.directory, isNot(oldDirectory));
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        isNot(oldDirectory),
      );
      router.go('/books/${Uri.encodeComponent(id)}/information');
      await until(() => field.evaluate().isNotEmpty);
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field).controller!.text, '乙项目作者');
      expect(find.text('保留未保存的书籍信息？'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      var storageClosed = false;
      library.closeWorkspaceStorage().then((_) => storageClosed = true);
      await until(() => storageClosed);
    },
  );
}
