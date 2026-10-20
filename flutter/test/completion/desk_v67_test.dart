import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_rule_catalog_service.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('V67 关闭后的假设命中、参考目录、缓存与只读状态', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v67-'))
        .absolute
        .path;
    final backend = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: backend);
    try {
      await library.load();
      expect(await library.savePatch({'check_after_import': false}), true);
      final source = File('$root/样书.txt')
        ..writeAsStringSync(
          '第一章 开始\n正文①。\n＊＊＊\n床前明月光，疑是地上霜。\n举头望明月，低头思故乡。\n①说明\n第三章 后来\n正文乙。\n第三章 重复\n正文丙。\n第五章 结尾\n结束。\n',
        );
      final bytes = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = backend.currentId;
      final layout = library.openLayout(id);
      await layout.apply(await layout.preview({'note_style': 'popup'}));
      final catalog = jsonDecode(
        await api.catalogRequestText(
          request: jsonEncode({
            'op': 'acquire',
            'source': 'paste',
            'input': '第三章 改名\n第一章 开始\n第二章 缺少',
            'title': '样书',
            'total': 3,
          }),
          cookie: '',
        ),
      ) as Map;
      backend.saveReferenceCatalog(
        id,
        Map<String, dynamic>.from(catalog['catalog'] as Map),
      );
      final service = LegacyRuleCatalogService(backend, id);
      final before = (await service.request())!;
      final ids = [
        'check.number_gap',
        'check.number_reset.repeated_number',
        'layout.verse.five',
        'layout.scene.uff0a',
        'layout.note.circled',
        'catalog_check.missing',
        'catalog_check.extra',
        'catalog_check.title',
        'catalog_check.order',
      ];
      final p = await service.previewToggles([
        for (final id in ids) {'id': id, 'enabled': false},
      ]);
      await service.applyToggles(p['plan_id'] as String);
      final state = backend.projectIdentity;
      final after = (await service.request())!;
      expect(after.configFingerprint, isNot(before.configFingerprint));
      for (final id in ids) {
        expect(before.rules[id]!.count, greaterThan(0), reason: id);
        final row = after.rules[id]!;
        expect(row.enabled, false, reason: id);
        expect(row.hypothetical, true, reason: id);
        expect(row.count, before.rules[id]!.count, reason: id);
        expect(
          row.locations.map((v) => v.utf8Start).toList(),
          before.rules[id]!.locations.map((v) => v.utf8Start).toList(),
          reason: id,
        );
      }
      expect((await service.request())!.cacheHit, true);
      expect(backend.projectIdentity, state);
      expect(source.readAsBytesSync(), bytes);
      service.dispose();
    } finally {
      library.dispose();
      backend.dispose();
    }
  });
}
