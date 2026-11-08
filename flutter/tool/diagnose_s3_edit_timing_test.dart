// Diagnostic harness: real Release DLL, same S3 data, without widget rendering.
import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('measure S3 state reads and a real move without rendering', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final state = PrototypeState();
    addTearDown(state.dispose);
    await state.importBookOutcome(
      File('../samples/章节独立场景/S3/缺陷样书.txt').absolute.path,
    );
    final rows = <dynamic>[];
    final times = <String, int>{};
    final clock = Stopwatch()..start();
    for (var offset = 0; offset < 360; offset += 30) {
      final page = await state.manuscript.effectiveTree(state.currentId, offset);
      rows.addAll(page['nodes'] as List);
    }
    times['twelve_pages_ms'] = clock.elapsedMilliseconds;
    final from = rows.singleWhere((n) => n['title'] == '第20章 卷2的旅程20');
    final to = rows.singleWhere((n) => n['title'] == '第41章 卷2的旅程41');
    clock.reset();
    expect(
      await state.manuscript.editEffectiveDraft(state.currentId, {
        'op': 'append',
        'action': {
          'kind': 'move_subtree',
          'entry_id': from['entry_id'],
          'before_id': to['entry_id'],
        },
      }),
      true,
    );
    times['move_ms'] = clock.elapsedMilliseconds;
    clock.reset();
    for (var offset = 0; offset < 360; offset += 30) {
      await state.manuscript.effectiveTree(state.currentId, offset, includeEdits: false);
      await state.manuscript.effectiveTree(state.currentId, offset);
    }
    times['twelve_pages_base_and_edited_ms'] = clock.elapsedMilliseconds;
    // ignore: avoid_print
    print(jsonEncode(times));
    File('../docs/evidence/r4-s3-state-timing.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(times));
  });
}
