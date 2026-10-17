import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/library/project_menu.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class Destination extends Fake implements BookFilePicker {
  Destination(this.path);
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
  testWidgets(
    'empty project saves from menu, replaces populated workspace, tracks dirty and imports again',
    (t) async {
      t.view.physicalSize = const Size(1440, 960);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late String root;
      late PrototypeState state;
      late LegacyLibraryAdapter library;
      await t.runAsync(() async {
        root = (await Directory('../artifacts').createTemp('empty-project-'))
            .absolute
            .path;
        state = PrototypeState(settingsDirectory: '$root/settings');
        // Same empty state used by the owned production library at startup.
        state.shelf.books.clear();
        state.shelf.selected.clear();
        state.currentId = '';
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        expect(await library.savePatch({'check_after_import': false}), true);
        expect(library.books.value, isEmpty);
        expect(library.hasUnsavedChanges, false);
        expect(jsonDecode(state.projectIdentity)['books'], isEmpty);
      });
      expect(t.takeException(), isNull);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ProjectMenu(
              library: library,
              picker: Destination('$root/empty.easypub.json'),
            ),
          ),
        ),
      );
      await t.tap(find.text('另存项目…'));
      for (var i = 0; i < 300 && state.savedProjectIdentity == null; i++) {
        await t.pump(const Duration(milliseconds: 20));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(
        state.savedProjectIdentity,
        isNotNull,
        reason: state.projectStatus,
      );
      expect(library.hasUnsavedChanges, false);
      await t.runAsync(() async {
        final saved = jsonDecode(
          await File('$root/empty.easypub.json').readAsString(),
        );
        expect(saved['books'], isEmpty);
        expect(saved['current_path'], '');
        final file = File('$root/new.txt');
        const text = '第一章 开始\n保留原稿\n';
        await file.writeAsString(text);
        expect((await library.importFiles([file.path])).single.succeeded, true);
        final id = library.books.value.single.id;
        library.checkBook(id, true);
        final info = library.openBookInformation(id);
        await info.apply(await info.preview({'author': '人工作者'}));
        info.dispose();
        final generation = library.workspaceGeneration.value;
        expect(
          (await library.openProject('$root/empty.easypub.json')).succeeded,
          true,
        );
        expect(library.workspaceGeneration.value, generation + 1);
        expect(library.books.value, isEmpty);
        expect(library.selection.value.current, isNull);
        expect(library.selection.value.selected, isEmpty);
        expect(state.currentId, '');
        expect(state.production.histories, isEmpty);
        expect(library.hasUnsavedChanges, false);
        state.change(() => state.format = 'MOBI');
        expect(
          library.hasUnsavedChanges,
          true,
          reason: 'empty saved project changes must remain dirty',
        );
        expect(
          (await library.saveProject('$root/empty-updated.easypub.json'))
              .succeeded,
          true,
        );
        expect(library.hasUnsavedChanges, false);
        expect(
          (await library.openProject('$root/empty-updated.easypub.json'))
              .succeeded,
          true,
        );
        expect(state.format, 'MOBI');
        expect((await library.importFiles([file.path])).single.succeeded, true);
        expect(library.books.value, hasLength(1));
        final malformed = Map<String, dynamic>.from(saved as Map);
        malformed['current_path'] = file.path;
        await File('$root/malformed.easypub.json')
            .writeAsString(jsonEncode(malformed));
        final identity = state.projectIdentity;
        expect(
          (await library.openProject('$root/malformed.easypub.json')).succeeded,
          false,
        );
        expect(state.projectIdentity, identity);
        expect(library.books.value, hasLength(1));
        expect(await file.readAsString(), text);
        expect(
          (await library.saveProject('$root/empty.easypub.json')).succeeded,
          false,
          reason: 'save must not overwrite existing project',
        );
        expect(
          jsonDecode(
            await File('$root/empty.easypub.json').readAsString(),
          )['books'],
          isEmpty,
        );
      });
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
