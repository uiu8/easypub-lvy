import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';

import 'library_removal_test.dart' as setup;

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test('conversion identity survives navigation and unrelated edits but rejects changed selected input', () async {
    final (state, library, root) = await setup.fixture();
    final conversion = LegacyConversionSession(state);
    addTearDown(() {
      conversion.dispose();
      library.dispose();
      state.dispose();
    });
    final ids = library.books.value.map((b) => b.id).toList();
    final request = ConversionRequest(
      books: [ids.first],
      directory: '$root/out',
      format: 'EPUB',
      runChecks: false,
    );
    final plan = await conversion.preview(request);
    expect(plan.previewed, true);
    final identity = state.conversionContext(ids.first);
    library.selectBook(ids.last);
    expect(state.conversionContext(ids.first), identity);
    expect(conversion.isCurrent(plan), true);
    final other = library.openChapters(ids.last);
    final otherPage = await other.read(0);
    await other.rename(otherPage, otherPage.nodes.first.id, '另一书修改');
    expect(conversion.isCurrent(plan), true);
    final completed = await conversion.commit(plan, acknowledgeWarnings: true);
    expect(completed.single.complete, true);
    final next = await conversion.preview(request);
    final chapters = library.openChapters(ids.first);
    final page = await chapters.read(0);
    await chapters.rename(page, page.nodes.first.id, '本书修改');
    expect(conversion.isCurrent(next), false);
    await expectLater(
      conversion.commit(next, acknowledgeWarnings: true),
      throwsFormatException,
    );
    expect(state.outputs.tasks, hasLength(1));
    final fresh = await conversion.preview(request);
    expect(conversion.isCurrent(fresh), true);
    final source = File(
      state.shelf.books.firstWhere((b) => b.id == ids.first).path,
    );
    final bytes = source.readAsBytesSync();
    source.writeAsStringSync('第一章 外部修改\n不可使用旧预览\n');
    try {
      final external = await conversion.commit(
        fresh,
        acknowledgeWarnings: true,
      );
      expect(external.single.complete, false);
      expect(File(external.single.path).existsSync(), false);
    } finally {
      source.writeAsBytesSync(bytes);
    }
  });
}
