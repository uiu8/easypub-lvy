import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/project_io.dart' as project_io;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
  });

  test(
    'edits completed during save remain dirty until actually persisted',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'easypub-save-snapshot-',
      );
      final entered = Completer<void>(), release = Completer<void>();
      var saves = 0;
      var failNext = false;
      final state = PrototypeState(
        settingsDirectory: '${dir.path}/settings',
        projectSaver: (path, data) async {
          if (failNext) throw const FormatException('synthetic save failure');
          final frozen = (jsonDecode(jsonEncode(data)) as Map)
              .cast<String, dynamic>();
          await project_io.saveProject(path, frozen);
          if (saves++ == 0) {
            entered.complete();
            await release.future;
          }
        },
      );
      final library = LegacyLibraryAdapter(backend: state);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await library.load();
      final source = File('${dir.path}/source.txt');
      const original = '第一章 保存前\n测试内容\n第二章 继续\n结尾\n';
      await source.writeAsString(original);
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = library.books.value.single.id;
      final chapters = library.openChapters(id);
      var page = await chapters.read(0);
      final project = '${dir.path}/book.easypub.json';
      final saving = state.saveProjectOutcome(project);
      await entered.future;
      await chapters.rename(page, page.nodes.first.id, '第一章 保存期间修改');
      release.complete();
      expect(await saving, true);

      final reopened = PrototypeState(settingsDirectory: '${dir.path}/reopen');
      addTearDown(reopened.dispose);
      expect(await reopened.openProjectOutcome(project), true);
      final disk = await reopened.manuscript.effectiveTree(reopened.currentId, 0);
      expect((disk['nodes'] as List).first['title'], '第一章 保存前');
      expect((await chapters.read(0)).nodes.first.title, '第一章 保存期间修改');
      expect(
        state.savedProjectIdentity,
        isNot(state.projectIdentity),
        reason: 'The new edit is absent from disk and must remain dirty.',
      );

      final nextProject = '${dir.path}/book-next.easypub.json';
      expect(await state.saveProjectOutcome(nextProject), true);
      expect(state.savedProjectIdentity, state.projectIdentity);
      expect(await reopened.openProjectOutcome(nextProject), true);
      final saved = await reopened.manuscript.effectiveTree(reopened.currentId, 0);
      expect((saved['nodes'] as List).first['title'], '第一章 保存期间修改');

      final savedIdentity = state.savedProjectIdentity;
      page = await chapters.read(0);
      await chapters.rename(page, page.nodes.first.id, '第一章 保存失败前修改');
      failNext = true;
      expect(await state.saveProjectOutcome(nextProject), false);
      expect(state.savedProjectIdentity, savedIdentity);
      expect(state.savedProjectIdentity, isNot(state.projectIdentity));
      expect(await reopened.openProjectOutcome(nextProject), true);
      final afterFailure = await reopened.manuscript.effectiveTree(reopened.currentId, 0);
      expect((afterFailure['nodes'] as List).first['title'], '第一章 保存期间修改');
      expect(await source.readAsString(), original);
    },
  );
}
