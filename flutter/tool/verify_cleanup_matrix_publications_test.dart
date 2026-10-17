import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kindling_matrix_helper.dart';

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          Platform.environment['EASYPUB_TEST_DLL'] ??
              '../target/release/easypub_bridge.dll',
        ).absolute.path,
      ),
    ),
  );
  for (final scenario in ['S2', 'S4', 'S7', 'S8', 'S9']) {
    test('$scenario widget-saved cleanup project reaches both publications', () async {
      final prior = jsonDecode(
        File('../docs/evidence/r4-matrix-${scenario.toLowerCase()}-widget.json')
            .readAsStringSync(),
      ) as Map;
      final manual = ['S2', 'S7', 'S9'].contains(scenario);
      final project = manual
          ? File(
              '${File(prior['output'] as String).parent.path}/待重做.easypub.json',
            )
          : File(prior['project'] as String);
      final projectBytes = project.readAsBytesSync();
      final state = PrototypeState();
      addTearDown(state.dispose);
      await state.openProjectOutcome(project.path);
      expect(state.shelf.books.where((book) => !book.isDemo), hasLength(1));
      final book = state.shelf.books.firstWhere((book) => !book.isDemo);
      final source = File(book.source!.path);
      final original = source.readAsBytesSync();
      if (manual) {
        final saved = state.manuscript.manualEditDrafts[book.id]!;
        final cursor = saved['cursor'] as int;
        final redone = (jsonDecode(
          await api.editManualDraft(
            sourceId: book.source!.sourceId,
            revision: book.source!.revision,
            draftJson: jsonEncode(saved),
            commandJson: jsonEncode({'op': 'redo'}),
          ),
        ) as Map).cast<String, dynamic>();
        expect(redone['cursor'], cursor + 1);
        expect(
          (redone['history'] as List)[redone['cursor'] as int],
          hasLength(
            scenario == 'S2'
                ? 11
                : scenario == 'S7'
                ? 6
                : 1,
          ),
        );
        state.manuscript.manualEditDrafts[book.id] = redone;
      }
      final expectedText = ['S4', 'S9'].contains(scenario)
          ? File(prior['output'] as String)
          : File('../samples/章节独立场景/$scenario/完整原稿.txt');
      if (scenario == 'S4') {
        final truth = jsonDecode(
          File('../samples/章节独立场景/S4/真值清单.json').readAsStringSync(),
        ) as Map;
        final removed = <int>{};
        for (final instance in truth['instances'] as List) {
          if (RegExp(r'^v3-c(7[0-9]|80)$').hasMatch(instance['id'] as String)) {
            removed.add((instance['start_line'] as int) + 1);
          }
        }
        expect(removed, hasLength(11));
        final lines = utf8.decode(original).split('\n');
        expect(
          expectedText.readAsStringSync(),
          [
            for (var i = 0; i < lines.length; i++)
              if (!removed.contains(i)) lines[i],
          ].join('\n'),
        );
      }
      if (scenario == 'S9') {
        expect(
          expectedText.readAsStringSync(),
          File('../samples/章节独立场景/S9/完整原稿.txt')
              .readAsStringSync()
              .replaceFirst('第119章 卷5的旅程119', '第一百一十九章 卷5的旅程119'),
        );
      }
      expect(
        File(prior['output'] as String).readAsBytesSync(),
        expectedText.readAsBytesSync(),
      );
      final directory = Directory(
        '../artifacts/r4-cleanup-publications/$scenario-${DateTime.now().microsecondsSinceEpoch}',
      ).absolute..createSync(recursive: true);
      await configureMatrixLanguage(state, book.id);
      final publication = state.publicationRequest(book.id);
      final output = File('${directory.path}/$scenario.epub');
      final request = {
        'op': 'preview',
        'publication': publication,
        'source_path': source.path,
        'output_path': output.path,
      };
      final preview = jsonDecode(
        await api.epubExportText(requestJson: jsonEncode(request)),
      ) as Map;
      expect(preview['node_count'], 696);
      expect(directory.listSync(), isEmpty);
      final receipt = jsonDecode(
        await api.epubExportText(
          requestJson: jsonEncode({
            ...request,
            'op': 'commit',
            'confirmed': true,
            'plan_id': preview['plan_id'],
          }),
        ),
      ) as Map;
      expect(receipt['committed'], true);
      expect(
        File('${receipt['transaction']['transaction_dir']}/source-backup.bin')
            .readAsBytesSync(),
        original,
      );
      await verifyKindlingMatrix(
        publication: publication,
        source: source,
        expectedText: expectedText,
        directory: directory,
        scenario: scenario,
        mode: 'M1',
        nodes: 696,
      );
      expect(source.readAsBytesSync(), original);
      expect(project.readAsBytesSync(), projectBytes);
      File('../docs/evidence/r4-matrix-${scenario.toLowerCase()}-epub.json')
          .writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'passed_partial': true,
              'scenario': scenario,
              'mode': 'M1',
              'epub': output.path,
              'expected_text': expectedText.absolute.path,
              'receipt': receipt,
              'project': project.path,
              'source': source.path,
              'widget_saved_project_reopened': true,
              'redo_after_reopen': manual,
              'source_and_project_unchanged': true,
              'reader_verified': false,
            }),
          );
    });
  }
}
