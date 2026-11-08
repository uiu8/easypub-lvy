import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'source_image_refresh_test.dart' show makeImageEpub;

void main() {
  test('resource findings identify each failed reference and survive repair, undo, reopen and EPUB', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('check-findings84-')).absolute.path;
    final source = '$root/source.epub';
    await makeImageEpub(source, updated: false);
    final sourceBytes = await File(source).readAsBytes();
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    await library.savePatch({'check_after_import': false});
    expect((await library.importFiles([source])).single.succeeded, true);
    final id = state.currentId;
    final images = (state.production.settings(id)['illustrations'] as List)
        .cast<Map>();
    final first = images.first;
    final resources = library.openResources(id);
    addTearDown(resources.dispose);
    await resources.read();
    await resources.apply(
      await resources.change(index: 0, path: first['path'] as String),
    );
    expect(
      (await library.saveProject('$root/before.easypub.json')).succeeded,
      true,
    );
    final missing = File(images[1]['path'] as String);
    final savedBytes = await missing.readAsBytes();
    await missing.delete();
    final checks = library.openChecks(id);
    addTearDown(checks.dispose);
    var report = await checks.inspect();
    CheckDomain domain(String id) =>
        report.domains.firstWhere((d) => d.id == id);
    expect(domain('resources').failed, true);
    expect(
      domain('resources').findings.map((f) => f.id),
      containsAll([
        'resource:0:unplaced',
        'resource:1:unreadable',
        'resources:combined',
      ]),
    );
    expect(
      domain('resources').findings
          .firstWhere((f) => f.id == 'resource:1:unreadable')
          .detail,
      contains(missing.path),
    );
    expect(
      domain('metadata').findings.map((f) => f.id),
      contains('metadata:author'),
    );
    final restored = BookCheckReport.fromJson(
      jsonDecode(jsonEncode(report.toJson())) as Map,
    );
    expect(restored.toJson(), report.toJson());
    // The legacy serialized report remains readable; it does not invent findings.
    final legacy = report.toJson();
    for (final d in legacy['domains'] as List) {
      (d as Map).remove('findings');
    }
    expect(
      BookCheckReport.fromJson(legacy).domains.every((d) => d.findings.isEmpty),
      true,
    );
    await missing.writeAsBytes(savedBytes);
    await resources.read();
    await resources.apply(
      await resources.change(
        index: 0,
        path: first['path'] as String,
        sourceLine: first['source_line'] as int,
      ),
    );
    final info = library.openBookInformation(id);
    await info.apply(await info.preview({'author': '已补作者'}));
    info.dispose();
    report = await checks.inspect();
    expect(domain('resources').failed, false);
    expect(domain('resources').findings, isEmpty);
    expect(
      domain('metadata').findings.any((f) => f.id == 'metadata:author'),
      false,
    );
    final chapters = library.openChapters(id);
    final tree = await chapters.read(0);
    final body = await chapters.body(tree, tree.nodes.first.id, 0);
    final anchor = body.rows.firstWhere((row) => row.text.contains('保持正文'));
    await chapters.confirm(
      await chapters.preview(
        tree,
        ExcludeChapterBodyLines(
          tree.nodes.first.id,
          anchor.lineOffset,
          anchor.lineOffset,
        ),
      ),
    );
    report = await checks.inspect();
    expect(
      domain('resources').findings.map((f) => f.id),
      contains('resource:0:needs_relocation'),
    );
    await chapters.history(await chapters.read(0), undo: true);
    report = await checks.inspect();
    expect(domain('resources').failed, false);
    for (var i = 0; i < 2; i++) {
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
    }
    report = await checks.inspect();
    expect(
      domain('resources').findings.map((f) => f.id),
      contains('resource:0:unplaced'),
    );
    expect(
      domain('metadata').findings.map((f) => f.id),
      contains('metadata:author'),
    );
    for (var i = 0; i < 2; i++) {
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'redo'},
          }),
        ),
        true,
      );
    }
    expect(
      (await library.saveProject('$root/fixed.easypub.json')).succeeded,
      true,
    );
    expect(
      (await library.openProject('$root/fixed.easypub.json')).succeeded,
      true,
    );
    report = await checks.inspect();
    expect(domain('resources').failed, false);
    expect(domain('resources').findings, isEmpty);
    expect(
      domain('metadata').findings.any((f) => f.id == 'metadata:author'),
      false,
    );
    final conversion = library.openConversion();
    addTearDown(conversion.dispose);
    final proposal = await conversion.preview(
      ConversionRequest(
        books: [id],
        directory: root,
        format: 'EPUB',
        runChecks: false,
      ),
    );
    expect(proposal.previewed, true);
    final output = (await conversion.commit(
      proposal,
      acknowledgeWarnings: true,
    )).single;
    expect(output.phase, 'complete', reason: output.detail);
    final parsed = await Process.run(
      Platform.environment['EASYPUB_TEST_PYTHON']!,
      [
        '-X',
        'utf8',
        '-c',
        "import sys,zipfile,xml.etree.ElementTree as E;z=zipfile.ZipFile(sys.argv[1]);b=E.fromstring(z.read('EPUB/body.xhtml'));assert len(b.findall('.//{http://www.w3.org/1999/xhtml}img'))==3;assert any('已补作者' in z.read(p).decode('utf-8') for p in z.namelist() if p.endswith('.opf'))",
        output.path,
      ],
    );
    expect(parsed.exitCode, 0, reason: parsed.stderr.toString());
    expect(await File(source).readAsBytes(), sourceBytes);
    expect(
      (await library.openProject('$root/before.easypub.json')).succeeded,
      true,
    );
    report = await checks.inspect();
    expect(
      domain('resources').findings.map((f) => f.id),
      contains('resource:0:unplaced'),
    );
  });
}
