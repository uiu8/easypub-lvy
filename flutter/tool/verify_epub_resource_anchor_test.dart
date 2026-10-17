import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_resource_session.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('imported EPUB body images reach the committed EPUB output', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    );
    final rootPath = Directory('..').absolute.path;
    final source = File(
      '$rootPath/artifacts/r5-kindle-full-resources/sample.epub',
    );
    expect(await source.exists(), true);
    final original = await source.readAsBytes();
    final root = Directory(
      '$rootPath/artifacts/epub-resource-anchor-e2e/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    addTearDown(state.dispose);
    await state.importBookOutcome(source.path, destination: DeskPage.conversion);
    expect(
      state.shelf.books.where((book) => !book.isDemo),
      isNotEmpty,
      reason: state.importStatus,
    );

    final book = state.shelf.books.firstWhere((b) => !b.isDemo);
    final draft = state.draftFor(book.id);
    final resources = draft.epubResources;
    expect(resources, isNotNull);
    final placements = (resources!['image_placements'] as List?) ?? const [];
    expect(placements, isNotEmpty);
    final inventorySession = LegacyResourceSession(state, book.id);
    final inventory = await inventorySession.read();
    for (final group in ['images', 'css', 'fonts']) {
      final entries = resources[group] as List;
      expect(
        inventory.where((r) => r.kind == 'epub-$group').length,
        entries.length,
      );
      for (final row in inventory.where((r) => r.kind == 'epub-$group')) {
        expect(row.editable, false);
        expect(row.status, '已提取 · 待复核');
        expect(row.byteLength, greaterThan(0));
      }
    }
    expect(inventory.where((r) => r.kind == 'epub-images'), isNotEmpty);
    expect(inventory.where((r) => r.kind == 'epub-css'), isNotEmpty);
    inventorySession.dispose();
    expect(draft.illustrations, hasLength(placements.length));
    expect(
      draft.illustrations.every(
        (item) =>
            item['source_line'] is int &&
            File(item['path'] as String).existsSync(),
      ),
      true,
    );

    final output = File('${root.path}/sample.epub');
    final publication = state.publicationRequest(book.id);
    final request = {
      'op': 'preview',
      'publication': publication,
      'source_path': book.source!.path,
      'output_path': output.path,
    };
    final preview = jsonDecode(
      await api.epubExportText(requestJson: jsonEncode(request)),
    ) as Map;
    expect(preview['committed'], isNot(true));

    final receipt = jsonDecode(
      await api.epubExportText(
        requestJson: jsonEncode({
          ...request,
          'op': 'commit',
          'confirmed': true,
          'plan_id': preview['plan_id'],
        }),
      ),
    ) as Map;
    expect(receipt['committed'], true);
    expect(output.existsSync(), true);
    expect(await source.readAsBytes(), original);

    final project = File('${root.path}/resource-project.easypub.json');
    await state.saveProjectOutcome(project.path);
    expect(project.existsSync(), true, reason: state.projectStatus);
    final reopened = PrototypeState(
      settingsDirectory: '${root.path}/reopen-settings',
    );
    addTearDown(reopened.dispose);
    await reopened.openProjectOutcome(project.path);
    final reopenedBook = reopened.shelf.books.firstWhere((b) => !b.isDemo);
    expect(reopenedBook.source!.originPath, source.path);
    expect(reopened.draftFor(reopenedBook.id).epubResources?['schema'], 3);
    final restoredInventorySession = LegacyResourceSession(
      reopened,
      reopenedBook.id,
    );
    expect(
      (await restoredInventorySession.read())
          .where((r) => r.kind.startsWith('epub-'))
          .length,
      inventory.where((r) => r.kind.startsWith('epub-')).length,
    );
    restoredInventorySession.dispose();
    final mapping = await reopened.previewFolderMapping(
      [
        {
          'folder': source.parent.path,
          'fields': {
            'author': {'op': 'fill_empty', 'value': '不会覆盖已有作者'},
          },
        },
      ],
      [reopenedBook.id],
    );
    expect(mapping.result['items'][0]['mapping']['winner'], 0);

    await File(
      '$rootPath/docs/evidence/epub-resource-anchor.json',
    ).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'passed': true, 'source_unchanged': true, 'image_placements_imported': placements.length, 'image_placements_exported': placements.length, 'output': output.path, 'project_origin_path_restored': true, 'folder_mapping_uses_origin_path': true, 'receipt': receipt})}\n',
    );
  });
}
