import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production Rust plans confirm, undo, persist and reject stale inputs', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('../target/release/easypub_bridge.dll').absolute.path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r5-production-plan/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${dir.absolute.path}/样书.txt');
    const raw = '第一章 开始\n正文内容\n第二章 继续\n更多正文';
    await file.writeAsString(raw);
    final state = PrototypeState();
    try {
      await state.importBookOutcome(file.path);
      final source = state.current.source!;
      final settings = <String, dynamic>{
        'title': '样书',
        'author': '',
        'description': '原简介',
        'cover_path': null,
        'cover_fit': 'cover',
        'font_family': 'Microsoft YaHei',
        'font_size': 18.0,
        'line_height': 1.8,
        'include_toc': true,
        'illustrations': [],
      };
      final target = <String, dynamic>{
        'book_id': state.currentId,
        'history': {
          'source_id': source.sourceId,
          'revision': source.revision,
          'states': [settings],
          'cursor': 0,
        },
        'change': {
          'op': 'patch',
          'fields': {
            'title': {'op': 'keep'},
            'author': {'op': 'fill_empty', 'value': '作者'},
            'description': {'op': 'clear'},
            'font_size': {'op': 'set', 'value': 24.0},
          },
        },
      };
      Future<Map<String, dynamic>> run({
        bool apply = false,
        String id = '',
        bool confirm = false,
      }) async => (jsonDecode(
        await api.productionBatchText(
          requestJson: jsonEncode({
            'targets': [target],
          }),
          apply: apply,
          planId: id,
          confirmed: confirm,
        ),
      ) as Map).cast<String, dynamic>();
      final preview = await run();
      expect(preview['applied'], false);
      expect(preview['items'][0]['history'], null);
      expect(preview['items'][0]['changed_fields'], [
        'author',
        'description',
        'font_size',
        'layout_origins',
      ]);
      await expectLater(
        run(apply: true, id: preview['plan_id']),
        throwsA(anything),
      );
      final applied = await run(
        apply: true,
        id: preview['plan_id'],
        confirm: true,
      );
      final after = (applied['items'][0]['after'] as Map)
          .cast<String, dynamic>();
      target['history'] = applied['items'][0]['history'];
      target['change'] = {'op': 'undo'};
      final undoPreview = await run();
      expect(undoPreview['items'][0]['after']['description'], '原简介');
      await expectLater(
        run(apply: true, id: preview['plan_id'], confirm: true),
        throwsA(anything),
      );
      final undone = await run(
        apply: true,
        id: undoPreview['plan_id'],
        confirm: true,
      );
      final undoneAfter = (undone['items'][0]['after'] as Map)
          .cast<String, dynamic>();
      expect(undoneAfter['title'], settings['title']);
      expect(undoneAfter['author'], settings['author']);
      expect(undoneAfter['description'], settings['description']);
      expect(undoneAfter['font_size'], settings['font_size']);
      target['history'] = undone['items'][0]['history'];
      target['change'] = {'op': 'redo'};
      final redo = await run();
      final redone = await run(apply: true, id: redo['plan_id'], confirm: true);
      expect(redone['items'][0]['after'], after);
      final project = state.projectDocument();
      final row = (project['books'] as List).single as Map;
      row.addAll(after);
      row['production_history'] = redone['items'][0]['history'];
      final projectPath = '${dir.absolute.path}/制作历史.easypub.json';
      final saved = await api.saveProjectText(
        path: projectPath,
        payload: jsonEncode(project),
      );
      expect(jsonDecode(saved)['ok'], true);
      final reopened = jsonDecode(await api.openProjectText(path: projectPath));
      expect(
        reopened['project']['books'][0]['production_history'],
        row['production_history'],
      );
      expect(reopened['project']['books'][0]['description'], '');
      expect(await file.readAsString(), raw);
      await File('../docs/evidence/r5-production-plan.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'rust_release_bridge': true,
          'explicit_field_diff': true,
          'unconfirmed_rejected': true,
          'old_plan_rejected': true,
          'undo_redo': true,
          'project_history_roundtrip': true,
          'source_unchanged': true,
          'covers_widget_interaction': false,
          'fixture': dir.absolute.path,
        }),
      );
    } finally {
      state.dispose();
    }
  });
}
