import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
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
  test('recheck refreshes only changed book and revalidates bytes destinations and cancellation', () async {
    final (state, library, root) = await setup.fixture();
    final calls = <String>[];
    final conversion = LegacyConversionSession(
      state,
      epubCall: (request) async {
        if (request['op'] == 'preview') {
          calls.add(request['source_path'] as String);
        }
        return (jsonDecode(
          await api.epubExportText(requestJson: jsonEncode(request)),
        ) as Map).cast<String, dynamic>();
      },
    );
    addTearDown(() {
      conversion.dispose();
      library.dispose();
      state.dispose();
    });
    final ids = library.books.value.map((b) => b.id).toList();
    final paths = {
      for (final b in state.shelf.books.where((b) => ids.contains(b.id)))
        b.id: b.source!.path,
    };
    final request = ConversionRequest(
      books: ids,
      directory: '$root/out',
      format: 'EPUB',
      runChecks: true,
      generateCover: true,
    );
    final first = await conversion.preview(request);
    expect(first.previewed, true);
    expect(calls, hasLength(2));
    final unchangedReport = conversion.batch!.preflightReports.singleWhere(
      (r) => r.bookId == ids.last,
    );
    final chapters = library.openChapters(ids.first);
    final page = await chapters.read(0);
    await chapters.rename(page, page.nodes.first.id, '第一章 已修复');
    calls.clear();
    final repaired = await conversion.preview(request);
    expect(repaired.previewed, true);
    expect(calls, [paths[ids.first]]);
    expect(
      identical(
        conversion.batch!.preflightReports.singleWhere(
          (r) => r.bookId == ids.last,
        ),
        unchangedReport,
      ),
      true,
    );
    library.selectBook(ids.last);
    calls.clear();
    await conversion.preview(request);
    expect(calls, isEmpty);
    final css = File('$root/theme.css')..writeAsStringSync('p{color:red}');
    final layout = library.openLayout(ids.last);
    await layout.applyCss(
      await layout.previewCss('@import url(theme.css);', root),
    );
    layout.dispose();
    calls.clear();
    await conversion.preview(request);
    expect(calls, [paths[ids.last]]);
    final cssPlan = conversion.batch!.items.last.preview!['plan_id'];
    calls.clear();
    await conversion.preview(request);
    expect(calls, isEmpty);
    css.writeAsStringSync('p{color:tan}');
    calls.clear();
    await conversion.preview(request);
    expect(calls, [paths[ids.last]]);
    expect(conversion.batch!.items.last.preview!['plan_id'], isNot(cssPlan));
    final collision = File(conversion.batch!.items.last.path)
      ..writeAsStringSync('用户已有成品');
    calls.clear();
    await conversion.preview(request);
    expect(calls, [paths[ids.last]]);
    expect(collision.readAsStringSync(), '用户已有成品');
    expect(conversion.batch!.items.last.path, isNot(collision.path));
    final source = File(paths[ids.first]!);
    final original = source.readAsBytesSync();
    final modified = List<int>.of(original);
    modified[modified.length - 1] = 32;
    final stamp = source.statSync().modified;
    source.writeAsBytesSync(modified);
    source.setLastModifiedSync(stamp);
    calls.clear();
    final stale = await conversion.preview(request);
    expect(calls, [paths[ids.first]]);
    expect(stale.previewed, false);
    source.writeAsBytesSync(original);
    calls.clear();
    final restored = await conversion.preview(request);
    expect(restored.previewed, true);
    expect(calls, [paths[ids.first]]);
    await conversion.cancel();
    calls.clear();
    final afterCancel = await conversion.preview(request);
    expect(calls, hasLength(2));
    final output = await conversion.commit(
      afterCancel,
      acknowledgeWarnings: true,
    );
    expect(output.every((r) => r.complete), true);
    final checked = await Process.run(
      Platform.environment['EASYPUB_TEST_PYTHON']!,
      [
        '-X',
        'utf8',
        '-c',
        'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); assert any(b"color:tan" in z.read(n) for n in z.namelist() if n.endswith(".css")); print("updated CSS in actual EPUB")',
        output.singleWhere((r) => r.bookId == ids.last).path,
      ],
    );
    expect(checked.exitCode, 0, reason: checked.stderr.toString());
    File('$root/incremental-output-evidence.json').writeAsStringSync(
      jsonEncode({
        'outputs': output.map((r) => r.path).toList(),
        'css_verified': checked.stdout.toString(),
        'repair_preview_calls': 1,
        'unchanged_preview_calls': 0,
        'external_source_refresh': true,
        'collision_preserved': true,
      }),
    );
    expect(collision.readAsStringSync(), '用户已有成品');
    calls.clear();
    await conversion.preview(request);
    expect(calls, hasLength(2));
  });
}
