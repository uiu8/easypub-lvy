import 'dart:io';

import 'package:easypub_desktop/application/book_check_service.dart';

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/folders/folder_controller.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('256 selected real TXT files import across native batches and resume without duplicates', () async {
    final count = int.parse(
      Platform.environment['EASYPUB_IMPORT_COUNT'] ?? '256',
    );
    final autoCheck = Platform.environment['EASYPUB_IMPORT_AUTO_CHECK'] == '1';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory.systemTemp.createTemp(
      'folder-native-regression-',
    );
    final books = await Directory('${root.path}/books').create();
    for (var i = 0; i < count; i++) {
      await File('${books.path}/book-$i.txt').writeAsString('第一章 测试$i\n正文$i\n');
    }
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final controller = FolderController(library);
    addTearDown(() {
      controller.dispose();
      library.dispose();
      state.dispose();
    });
    await library.load();
    expect(await library.savePatch({'check_after_import': autoCheck}), true);
    await controller.scan(books.path);
    expect(controller.selected, hasLength(count));
    final watch = Stopwatch()..start();
    await controller.importSelected();
    expect(controller.outcomes, hasLength(count));
    expect(
      controller.outcomes.where((r) => !r.succeeded),
      isEmpty,
      reason: controller.outcomes
          .where((r) => !r.succeeded)
          .map((r) => r.message)
          .join('\n'),
    );
    expect(library.books.value, hasLength(count));
    if (autoCheck) {
      for (final book in library.books.value) {
        final checks = library.openChecks(book.id);
        final report = (checks as CachedBookCheckSession).latest;
        expect(report, isNotNull, reason: book.path);
        expect(checks.isCurrent(report!), true, reason: book.path);
        checks.dispose();
      }
    }
    stdout.writeln(
      'import count=$count auto_check=$autoCheck elapsed_ms=${watch.elapsedMilliseconds} rss=${ProcessInfo.currentRss}',
    );
    final project = '${root.path}/books.easypub.json';
    expect((await library.saveProject(project)).succeeded, true);
    final reopened = PrototypeState(settingsDirectory: '${root.path}/reopened');
    addTearDown(reopened.dispose);
    expect(
      await reopened.openProjectOutcome(project),
      true,
      reason: reopened.projectStatus,
    );
    expect(reopened.shelf.books.where((b) => !b.isDemo), hasLength(count));
    final last = reopened.shelf.books.where((b) => !b.isDemo).last;
    final tree = await reopened.manuscript.effectiveTree(last.id, 0);
    expect(tree['nodes'], isNotEmpty);
    await controller.scan(books.path);
    expect(controller.selected, isEmpty);
    expect(controller.listing!.books.every((b) => b.alreadyImported), true);
  // 单独运行约 80 秒；全量并发 8 时与其他重型测试争用 CPU，实测 100–110 秒，
  // 偶尔超过 2 分钟。上限放宽到 4 分钟，耗时仍由上方 elapsed_ms 记录。
  }, timeout: const Timeout(Duration(minutes: 4)));
}
