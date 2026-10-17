import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('combined manual and cleanup output retains audit and source guards', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('build/windows/x64/runner/Release/easypub_bridge.dll')
            .absolute
            .path,
      ),
    );
    final dir = await Directory(
      '../artifacts/r45-publication-output/${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final source = File('${dir.absolute.path}/原稿.txt');
    const body = '第一章 甲  \r\n\r\n\n他说请收藏这个盒子。\r广告：站点\n本章完\r\n尾文\r';
    await source.writeAsString(body);
    final imported = await readTxt(source.path, () => false);
    final cleanup = <String, dynamic>{
      'kind': 'cleanup',
      'rules': [
        'trim_trailing_spaces',
        'collapse_blank_lines',
        'remove_ad_lines',
      ],
    };
    final value = <String, dynamic>{
      'kind': 'publication',
      'manual': {
        'kind': 'manual_batch',
        'actions': [
          {'kind': 'rename_title', 'source_line': 1, 'title': '第一章 新标题'},
        ],
      },
      'cleanup': cleanup,
    };
    Future<Map<String, dynamic>> preview(Map<String, dynamic> r) async =>
        jsonDecode(
          await api.previewRepairPlanText(
            sourceId: imported.sourceId,
            revision: imported.revision,
            selectedJson: jsonEncode(r),
          ),
        ) as Map<String, dynamic>;
    final first = await preview(value);
    cleanup['remove_lines'] = [5];
    final selected = await preview(value);
    expect(selected['change_count'], 3);
    expect(selected['plan_id'], isNot(first['plan_id']));
    final output = File('${dir.absolute.path}/清理副本.txt');
    Future<String> commit(String id, String path, bool confirmed) =>
        api.commitRepairOutputText(
          sourceId: imported.sourceId,
          revision: imported.revision,
          sourcePath: source.path,
          outputPath: path,
          selectedJson: jsonEncode(value),
          planId: id,
          confirmed: confirmed,
        );
    await expectLater(
      commit(selected['plan_id'], output.path, false),
      throwsA(anything),
    );
    await expectLater(
      commit(first['plan_id'], output.path, true),
      throwsA(anything),
    );
    expect(await output.exists(), false);
    final receipt = jsonDecode(
      await commit(selected['plan_id'], output.path, true),
    );
    expect(receipt['source_unchanged'], true);
    expect(
      await output.readAsString(),
      '第一章 新标题\r\n\r\n他说请收藏这个盒子。\r本章完\r\n尾文\r',
    );
    expect(await source.readAsString(), body);
    expect(
      await File('${receipt['transaction_dir']}/source-backup.bin')
          .readAsBytes(),
      await source.readAsBytes(),
    );
    final evidence = jsonDecode(
      await File('${receipt['transaction_dir']}/edit-evidence.json')
          .readAsString(),
    );
    expect(evidence['plan_id'], selected['plan_id']);
    expect(evidence['manual']['changes'], hasLength(1));
    expect(evidence['manual']['changes'][0]['before'], '第一章 甲  ');
    expect(evidence['cleanup']['stage']['changes'], hasLength(2));
    expect(
      (evidence['cleanup']['stage']['changes'] as List).singleWhere(
        (c) => c['reason'] == 'selected_notice',
      )['before'],
      '广告：站点\n',
    );
    expect(evidence['effective_structure']['nodes'][0]['title'], '第一章 新标题');
    await expectLater(
      commit(selected['plan_id'], output.path, true),
      throwsA(anything),
    );
    await source.writeAsString('$body外部改写');
    final denied = '${dir.absolute.path}/不应生成.txt';
    await expectLater(
      commit(selected['plan_id'], denied, true),
      throwsA(anything),
    );
    expect(await File(denied).exists(), false);
    await File('../docs/evidence/r45-publication-output.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'passed': true,
        'verified_at': DateTime.now().toIso8601String(),
        'receipt': receipt,
        'checks': [
          'real changes preview',
          'manual and cleanup stages include complete original text',
          'mixed endings and body retained',
          'complete per-line evidence before publish',
          'backup matches source',
          'changed selection invalidates plan',
          'confirmation required',
          'output conflict rejected',
          'external source change rejected',
        ],
      }),
    );
  });
}
