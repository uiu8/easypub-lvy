import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('manual values, deliberate clears and same-valued intent survive mapping history and project reopening', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('metadata-origins-')).absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final file = File('${root.path}/来源.txt')
        ..writeAsStringSync('第一章 开始\n合成正文。\n');
      expect((await library.importFiles([file.path])).single.succeeded, true);
      final id = state.currentId;
      var info = library.openBookInformation(id);
      await info.apply(await info.preview({'author': '手工作者', 'publisher': ''}));
      info.dispose();
      final history = library.openChangeHistory();
      final record = history.records(id).firstWhere((r) => r.domain == '制作');
      expect(record.category, '批量制作', reason: 'Observed bug: author edit misclassified');
      final detail = history.detail(record);
      expect(detail.fields.any((f) => f.label.contains('metadata_origins')), true,
        reason: 'Observed bug: internal provenance labels exposed');
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
