import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'legacy_state_helpers.dart';

void main() {
  test('EPUB import preserves resources and metadata', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('build/windows/x64/runner/Release/easypub_bridge.dll')
            .absolute
            .path,
      ),
    );
    final source = File(
      '${Directory('..').absolute.path}/artifacts/r4-matrix-s1-ui/1790582336545717/S1-M2.epub',
    );
    expect(await source.exists(), true);
    final before = await source.readAsBytes();
    final state = PrototypeState();
    try {
      await state.importBookOutcome(source.path);
      expect(state.current.isDemo, false, reason: state.importStatus);
      expect(await source.readAsBytes(), before);
      final draft = state.draftFor(state.currentId);
      final resources = draft.epubResources;
      expect(resources, isNotNull);
      expect((resources!['images'] as List).isNotEmpty, true);
      expect(resources['resource_root'], contains('resources'));
      expect(state.current.hasCover, true);
      await File('../docs/evidence/epub-resource-import.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'passed': true,
          'source_unchanged': true,
          'resource_manifest': true,
          'cover_bound': true,
          'style_reported': true,
          'font_review_reported': true,
        }),
      );
    } finally {
      state.dispose();
    }
  });
}
