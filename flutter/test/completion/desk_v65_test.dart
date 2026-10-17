import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_rule_catalog_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_change_history_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('V65 真实 DLL 混合事务、失败隔离、历史重开与新书默认', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v65-'))
        .absolute
        .path;
    final backend = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: backend);
    try {
      await library.load();
      expect(await library.savePatch({'check_after_import': false}), true);
      final source = File('$root/样书.txt')
        ..writeAsStringSync(
          '第一章 开始\n正文①。  \n***\n【系统提示】\n床前明月光，疑是地上霜。\n①说明\n第三章 后来\n结束。\n',
        );
      final original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = backend.currentId;
      final service = LegacyRuleCatalogService(backend, id);
      final initial = backend.production.settings(id);
      final changes = [
        {'id': 'check.number_gap', 'enabled': false},
        {'id': 'chapter.recognize.author_note', 'enabled': false},
        {'id': 'layout.scene.u002a', 'enabled': false},
        {'id': 'layout.verse.five', 'enabled': false},
        {'id': 'layout.note.bracket', 'enabled': false},
        {'id': 'cleanup.trim_trailing_spaces', 'enabled': false},
        {'id': 'catalog_check.missing', 'enabled': false},
        {'id': 'preflight.language', 'enabled': false},
      ];
      final p = await service.previewToggles(changes);
      expect(backend.production.settings(id), initial);
      expect((p['impact'] as Map)['writes_body'], false);
      await expectLater(
        service.previewToggles([
          ...changes,
          {'id': 'preflight.title', 'enabled': false},
        ]),
        throwsA(anything),
      );
      expect(backend.production.settings(id), initial);
      await service.applyToggles(p['plan_id'] as String);
      final after = backend.production.settings(id);
      final rows = (await service.settings())['rules'] as List;
      for (final c in changes) {
        expect(
          rows.cast<Map>().singleWhere((r) => r['id'] == c['id'])['enabled'],
          false,
        );
      }
      final stats = (await service.request())!;
      expect(stats.rules['check.number_gap']!.count, 1);
      expect(stats.rules['check.number_gap']!.hypothetical, true);
      expect(stats.rules['catalog_check.missing']!.status, 'unavailable');
      expect(stats.rules['catalog_check.missing']!.countAvailable, false);
      final history = LegacyChangeHistoryService(backend);
      final records = history.records(id);
      expect(records.where((r) => r.domain == '规则开关'), hasLength(1));
      final record = records.singleWhere((r) => r.domain == '规则开关');
      await history.undo(history.detail(record));
      expect(backend.production.settings(id), initial);
      await service.moveHistory(undo: false);
      expect(backend.production.settings(id), after);
      final saved = File('$root/规则.easypub.json');
      expect(
        await backend.saveProjectOutcome(saved.path),
        true,
        reason: backend.projectStatus,
      );
      final project = jsonDecode(saved.readAsStringSync()) as Map;
      expect(
        (project['books'] as List).single['rule_toggle_history'],
        isNotNull,
      );
      expect(
        await backend.openProjectOutcome(saved.path),
        true,
        reason: backend.projectStatus,
      );
      await service.moveHistory(undo: true);
      expect(backend.production.settings(id), initial);
      await service.moveHistory(undo: false);
      final stale = await service.previewToggles([
        {'id': 'layout.system', 'enabled': false},
      ]);
      final layout = library.openLayout(id);
      await layout.apply(await layout.preview({'verse_block_style': 'indent'}));
      await expectLater(
        service.applyToggles(stale['plan_id'] as String),
        throwsFormatException,
      );
      final oldBook = backend.production.settings(id);
      final global = await service.previewToggles([
        {'id': 'layout.system', 'enabled': false},
        {'id': 'check.number_gap', 'enabled': false},
      ], scope: 'global');
      await service.applyToggles(global['plan_id'] as String);
      expect(backend.production.settings(id), oldBook);
      final second = File('$root/新书.txt')
        ..writeAsStringSync('第一章 新书\n正文。\n第三章 结尾\n结尾。\n');
      expect((await library.importFiles([second.path])).single.succeeded, true);
      final newId = backend.currentId;
      expect(backend.production.settings(newId)['system_block_style'], 'off');
      final next = LegacyRuleCatalogService(backend, newId);
      expect(
        ((await next.settings())['rules'] as List).cast<Map>().singleWhere(
          (r) => r['id'] == 'check.number_gap',
        )['enabled'],
        false,
      );
      next.dispose();
      expect(source.readAsBytesSync(), original);
      File('$root/verification.json').writeAsStringSync(
        jsonEncode({'plan': p, 'rules': rows, 'source_unchanged': true}),
      );
      history.dispose();
      service.dispose();
      // ignore: avoid_print
      print('V65 evidence: $root');
    } finally {
      library.dispose();
      backend.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
