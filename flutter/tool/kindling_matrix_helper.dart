import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// Explicit fixture metadata through the same production plan as the UI.
Future<void> configureMatrixLanguage(
  PrototypeState state,
  String bookId,
) async {
  final plan = await state.production.previewChanges({
    bookId: {
      'op': 'patch',
      'fields': {
        'language': {'op': 'set', 'value': 'zh-CN'},
      },
    },
  });
  expect(await state.production.confirm(plan), true);
  expect(state.production.settings(bookId)['language'], 'zh-CN');
}

/// Executes the real job API using an explicitly configured synthetic cover.
Future<void> verifyKindlingMatrix({
  required Map<String, dynamic> publication,
  required File source,
  required File expectedText,
  required Directory directory,
  required String scenario,
  required String mode,
  required int nodes,
}) async {
  final cover = File('${directory.path}/matrix-cover.png')
    ..writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQVDIGAACuAGcVHqFfAAAAAElFTkSuQmCC',
      ),
    );
  // Only the test fixture gets a cover; the application does not invent one.
  final configured = {
    ...publication,
    'settings': {
      ...publication['settings'] as Map,
      'cover_path': cover.absolute.path,
    },
  };
  final original = source.readAsBytesSync();
  final output = File('${directory.path}/$scenario.azw3').absolute;
  Future<Map> job(Map request) async {
    final start = jsonDecode(
      await api.kindlingJobText(
        requestJson: jsonEncode({'op': 'start', 'request': request}),
      ),
    ) as Map;
    final id = start['job_id'];
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (true) {
      final status = jsonDecode(
        await api.kindlingJobText(
          requestJson: jsonEncode({'op': 'status', 'job_id': id}),
        ),
      ) as Map;
      if (status['terminal'] == true) {
        await api.kindlingJobText(
          requestJson: jsonEncode({'op': 'forget', 'job_id': id}),
        );
        expect(status['phase'], 'completed', reason: jsonEncode(status));
        return status['result'] as Map;
      }
      if (DateTime.now().isAfter(deadline)) {
        await api.kindlingJobText(
          requestJson: jsonEncode({'op': 'cancel', 'job_id': id}),
        );
        fail('Kindling matrix timeout, cancellation requested: $id');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  final request = {
    'op': 'preview',
    'publication': configured,
    'source_path': source.absolute.path,
    'output_path': output.path,
    'engine_path':
        Platform.environment['EASYPUB_TEST_KINDLING'] ??
        r'D:\software\DeepSeek-Harness\workspace\ebook-bench\kindling.exe',
  };
  final count = directory.listSync().length;
  final preview = await job(request);
  expect(preview['node_count'], nodes);
  expect(directory.listSync().length, count);
  expect(output.existsSync(), false);
  final receipt = await job({
    ...request,
    'op': 'commit',
    'confirmed': true,
    'plan_id': preview['plan_id'],
  });
  expect(receipt['committed'], true);
  expect(source.readAsBytesSync(), original);
  expect(
    File('${receipt['transaction']['transaction_dir']}/source-backup.bin')
        .readAsBytesSync(),
    original,
  );
  expect(ascii.decode(output.readAsBytesSync().sublist(60, 68)), 'BOOKMOBI');
  expect(
    File(receipt['engine_log'] as String).readAsStringSync(),
    contains('19 P0 checks passed'),
  );
  File('../docs/evidence/r4-matrix-${scenario.toLowerCase()}-kindling.json')
      .writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'passed_partial': true,
          'scenario': scenario,
          'mode': mode,
          'output': output.path,
          'input_epub': '${receipt['conversion_directory']}/input.epub',
          'expected_text': expectedText.absolute.path,
          'source': source.absolute.path,
          'receipt': receipt,
          'effective_nodes': nodes,
          'configured_synthetic_cover': true,
          'original_project_composition': true,
          'source_and_backup_unchanged': true,
          'not_verified': ['native desktop', 'reader', 'complete matrix cell'],
        }),
      );
}
