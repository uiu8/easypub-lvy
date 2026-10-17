import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy resources remain review-only in actual DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final run = Directory(
      '../artifacts/r5-resource-review/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute..createSync(recursive: true);
    final file = File('${run.path}/app-settings.json');
    final content = jsonEncode({
      'LastProfile': {
        'Options': {
          'AdditionalCss': 'p { color: red; }',
          'CoverImagePath': 'cover.png',
          'Illustrations': [],
          'Metadata': {'Title': '旧书'},
        },
      },
      'Presets': [],
    });
    file.writeAsStringSync(content);
    final original = file.readAsBytesSync();
    final state = PrototypeState(settingsDirectory: '${run.path}/settings');
    addTearDown(state.dispose);
    final report = await state.inspectLegacySettings(file.path);
    final map = report['report'] as Map;
    final items = (map['items'] as List)
        .where((e) => (e as Map)['source'].toString().contains('/Options/'))
        .toList();
    expect(items, hasLength(4));
    expect(
      items.every((e) => (e as Map)['status'] == 'needs_confirmation'),
      true,
    );
    expect(map['proposed_layout'], isEmpty);
    expect(file.readAsBytesSync(), original);
    expect(Directory(state.settingsDirectory!).existsSync(), false);
    File('../docs/evidence/r5-resource-review.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'passed': true,
        'review_only_fields': 4,
        'layout_defaults_created': false,
        'source_unchanged': true,
        'settings_directory_created': false,
        'not_verified': ['resource copy', 'Kindle visual/device'],
      }),
    );
  });
}

