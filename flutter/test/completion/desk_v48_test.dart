import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/layout_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('LAY-120：注释默认关闭、保存与撤销往返，真实 EPUB/AZW3/MOBI/KFX 保留双向注释', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v48-notes-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      final source = File('$root/潮汐记.txt')
        ..writeAsStringSync(
          '第一章 灯塔\n　海图标着潮汐①，旧港又被称为石湾[2]。\n'
          '① 潮汐是海水周期性的涨落。\n注2：石湾是旧港从前的名字。\n'
          '第二章 归航\n孤立的标记③保持原样。\n',
        );
      final original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      expect(layoutFields, contains('note_style'));
      expect(state.production.settings(id)['note_style'], 'off');
      final edit = await state.production.previewChanges({
        id: {
          'op': 'patch',
          'fields': {
            'note_style': {'op': 'set', 'value': 'popup'},
          },
        },
      });
      expect(await state.production.confirm(edit), true);
      expect(state.production.settings(id)['note_style'], 'popup');
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'undo'},
          }),
        ),
        true,
      );
      expect(state.production.settings(id)['note_style'], 'off');
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {'op': 'redo'},
          }),
        ),
        true,
      );
      final project = '$root/book.easypub.json';
      expect(await state.saveProjectOutcome(project), true);
      final reopened = PrototypeState(settingsDirectory: '$root/reopened');
      try {
        expect(await reopened.openProjectOutcome(project), true);
        expect(
          reopened.production.settings(reopened.currentId)['note_style'],
          'popup',
        );
      } finally {
        reopened.dispose();
      }
      final evidence = <Object?>[];
      // 生产历史会清理已完成的临时目录，在完成通知内同步留存本测试的校验输入和日志。
      var capturedKfx = false;
      void captureValidation() {
        if (capturedKfx || state.outputs.tasks.isEmpty) return;
        final task = state.outputs.tasks.last;
        if (task.format != 'KFX' || task.phase != 'complete') return;
        final stage = task.receipt!['conversion_directory'] as String;
        File('$stage/input.epub').copySync('$root/kfx-input.epub');
        File('$stage/validation.log').copySync('$root/kfx-validation.log');
        capturedKfx = true;
      }

      state.addListener(captureValidation);
      for (final format in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '$root/$format',
              format: format,
              engine: format == 'EPUB'
                  ? ''
                  : Platform.environment[format == 'KFX'
                        ? 'EASYPUB_TEST_BOKAI'
                        : 'EASYPUB_TEST_KINDLING']!,
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(plan.previewed, true);
          final output = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true, reason: output.detail);
          if (format == 'KFX') {
            // 成品已经过生产链的 bokai validate all；再从 KFX 本身读回注释语义。
            expect(capturedKfx, true);
            final validation = await File('$root/kfx-validation.log')
                .readAsString();
            expect(
              validation,
              matches(RegExp(r'CSS props:\s+100\.00% covered')),
            );
            expect(validation, matches(RegExp(r'Fallback:\s+0 \(0\.00%\)')));
            final roundtrip = '$root/kfx-roundtrip.epub';
            final dump = await Process.run(
              Platform.environment['EASYPUB_TEST_BOKAI']!,
              ['convert', output.path, roundtrip],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
            );
            expect(dump.exitCode, 0, reason: '${dump.stderr}');
            final inspection = await Process.run(
              Platform.environment['EASYPUB_TEST_PYTHON']!,
              [
                '-I',
                '-X',
                'utf8',
                '../tools/verify_popup_notes.py',
                roundtrip,
                '--kfx-roundtrip',
              ],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
            );
            expect(
              inspection.exitCode,
              0,
              reason: '${inspection.stdout}\n${inspection.stderr}',
            );
            evidence.add({
              'format': format,
              'path': output.path,
              'validation': {
                'validator': 'bokai validate all',
                'passed': true,
                'css_coverage': 100,
                'unmapped_tags': 0,
                'log': '$root/kfx-validation.log',
              },
              'roundtrip': jsonDecode(inspection.stdout as String),
              'note_semantics_read_back': true,
            });
          } else {
            final inspection = await Process.run(
              Platform.environment['EASYPUB_TEST_PYTHON']!,
              [
                '-I',
                '-X',
                'utf8',
                '../tools/verify_popup_notes.py',
                output.path,
                if (format == 'EPUB') ...['--source', source.path],
              ],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
            );
            expect(
              inspection.exitCode,
              0,
              reason: '${inspection.stdout}\n${inspection.stderr}',
            );
            evidence.add(jsonDecode(inspection.stdout as String));
          }
        } finally {
          session.dispose();
        }
      }
      expect(source.readAsBytesSync(), original);
      await state.outputs.historySaved;
      await File('$root/verification.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    } finally {
      library.dispose();
      state.dispose();
    }
  });
}
