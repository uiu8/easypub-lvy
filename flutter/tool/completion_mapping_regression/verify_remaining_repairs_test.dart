import 'dart:io';
import 'dart:convert';

import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/infrastructure/native_book_picker.dart';
import 'package:easypub_desktop/desk/folders/folder_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/book_check_service.dart';

void main() {
  test('parameterized automatic checks survive project reopening', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory.systemTemp.createTemp('easypub-finish-');
    final first = PrototypeState(settingsDirectory: '${dir.path}/settings');
    final library = LegacyLibraryAdapter(backend: first);
    await library.load();
    expect(
      await library.savePatch({
        'automatic_cleanup_pipeline': [
          {'kind': 'literal_replace', 'find': '错字', 'replace': '正字'},
        ],
      }),
      true,
      reason: '带参数检测规则必须能保存并被入库检查消费',
    );
    final source = File('${dir.path}/book.txt');
    await source.writeAsString('第一卷 起点\n第一章 来信\n这里有错字。\n第二章 回信\n正文。\n');
    expect((await library.importFiles([source.path])).single.succeeded, true);
    final id = library.books.value.single.id;
    final overview = await (library as BookOverviewService).overview(id);
    expect(overview['chapters'], 2);
    expect(overview['volumes'], 1);
    expect(overview['characters'], 9);
    expect(overview['project_state'], '尚未保存项目');
    final checks = library.openChecks(id);
    final report = (checks as CachedBookCheckSession).latest!;
    expect(
      report.domains.firstWhere((d) => d.id == 'cleanup').status,
      contains('1 处'),
    );
    final project = '${dir.path}/saved.easypub.json';
    final saved = await library.saveProject(project);
    expect(saved.succeeded, true, reason: saved.message);
    expect((await library.overview(id))['project_state'], '更改已保存');
    checks.dispose();
    library.dispose();
    first.dispose();
    final second = PrototypeState(settingsDirectory: '${dir.path}/settings');
    final reopened = LegacyLibraryAdapter(backend: second);
    await reopened.load();
    expect((await reopened.openProject(project)).succeeded, true);
    final reopenedChecks = reopened.openChecks(reopened.books.value.single.id);
    expect(
      (reopenedChecks as CachedBookCheckSession).latest,
      isNotNull,
      reason: '项目重开应复用一致版本的报告',
    );
    expect(await source.readAsString(), contains('错字'));
    final cleanup = reopened.openCleanup(reopened.books.value.single.id);
    final preview = await cleanup.preview(
      jsonEncode({
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'literal_replace', 'find': '错字', 'replace': '正字'},
        ],
      }),
    );
    expect(preview.stepCounts[0], 1);
    final context = await (cleanup as CleanupContextSession).previewSource(
      preview,
      preview.actions.single,
    );
    expect(context, contains('这里有错字。'));
    expect(context, contains('第二章 回信'));
    await cleanup.apply(preview);
    expect(
      (await reopened.overview(
        reopened.books.value.single.id,
      ))['project_state'],
      '有未保存更改',
    );
    expect(await source.readAsString(), contains('错字'));
    cleanup.dispose();
    expect(
      await reopened.savePatch({
        'automatic_cleanup_pipeline': [],
        'ui_scale': 1.3,
        'restore_window': false,
        'import_directory': dir.path,
        'import_recursive': true,
      }),
      true,
    );
    expect(
      (reopenedChecks as CachedBookCheckSession).latest,
      isNull,
      reason: '更改规则必须使旧报告失效',
    );
    expect(
      await File('${dir.path}/settings/window-restore-disabled').exists(),
      true,
    );
    expect(
      await NativeBookPicker(settings: reopened).initialDirectory(),
      dir.path,
    );
    final nested = Directory('${dir.path}/nested');
    await nested.create();
    await File('${nested.path}/nested.txt').writeAsString('第一章 开始\n内容\n');
    final folders = FolderController(reopened);
    await folders.scan(dir.path);
    expect(folders.recursive, true);
    expect(
      folders.listing!.books.any((b) => b.path.endsWith('nested.txt')),
      true,
    );
    folders.dispose();
    await reopened.savePatch({'backup_before_change': true});
    await reopened.savePatch({'ui_scale': 1.15, 'restore_window': true});
    expect(
      await File('${dir.path}/settings/window-restore-disabled').exists(),
      false,
    );
    expect(
      await Directory('${dir.path}/settings-backups').list().isEmpty,
      false,
    );
    expect(
      await reopened.savePatch({'ui_scale': 9.0}),
      false,
      reason: '越界字号不能写入',
    );

    reopenedChecks.dispose();
    reopened.dispose();
    second.dispose();
  });
}
