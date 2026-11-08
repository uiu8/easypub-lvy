import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_helpers.dart';

void main() {
  test(
    'actual batch history exceeds 64KiB without bloating settings generations',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File('../target/release/easypub_bridge.dll').absolute.path,
        ),
      );
      final parent = Directory(
        '../artifacts/frontend-rewrite/batch-history-capacity',
      ).absolute;
      await parent.create(recursive: true);
      final directory = await parent.createTemp('run-');
      final state = PrototypeState(settingsDirectory: directory.path);
      final reopened = PrototypeState(settingsDirectory: directory.path);
      addTearDown(state.dispose);
      addTearDown(reopened.dispose);
      for (var i = 0; i < 40; i++) {
        expect(
          await state.outputs.saveBatchRecord({
            'batch_id': 'capacity-$i',
            'created_at': '2026-10-02T00:00:${i.toString().padLeft(2, '0')}Z',
            'state': 'preflight_ready',
            'items': [],
            'preflight': {
              'reports': [
                {'detail': List.filled(1400, '校验').join()},
              ],
            },
          }),
          true,
          reason: 'batch $i: ${state.globalSettingsStatus}',
        );
      }
      expect(
        utf8.encode(jsonEncode(state.outputs.batchRecords)).length,
        greaterThan(65536),
      );
      expect(await reopened.loadGlobalSettings(), true);
      expect(reopened.outputs.batchRecords, state.outputs.batchRecords);
      final snapshots = await directory
          .list()
          .where((f) => f is File && f.path.endsWith('.json'))
          .toList();
      for (final file in snapshots) {
        expect(await File(file.path).length(), lessThanOrEqualTo(65536));
      }
      final objects = Directory('${directory.path}/batch-records');
      final before = await objects.list().length;
      expect(
        await state.saveGlobalLayout({
          'font_size': 22.0,
        }, state.globalSettingsToken),
        true,
      );
      expect(await objects.list().length, before);
      expect(
        await reopened.saveGlobalLayout({
          'font_size': 18.0,
        }, reopened.globalSettingsToken),
        false,
      );
    },
  );
}
