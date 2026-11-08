import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/block_annotation_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_block_annotation_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_chapter_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_change_history_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('LAY-123：服务预览确认、项目和历史往返、四格式输出、清理后失效', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v52-blocks-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final history = LegacyChangeHistoryService(state);
    const text =
        '第一章 来信\n　首段保持原文。\n亲爱的友人：\n　你提到的潮汐①，我已看过。  \n林舟\n'
        '【误判是普通文字】\n【自动提示】\n①潮汐是海水周期性的涨落。\n第二章 归航\n正文保持。\n';
    final source = File('$root/远行.txt')..writeAsStringSync(text);
    final original = source.readAsBytesSync();
    int offset(String marker) =>
        utf8.encode(text.substring(0, text.indexOf(marker))).length;
    final evidence = <Object?>[];
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      final notes = LegacyBlockAnnotationSession(state, id);
      addTearDown(notes.dispose);
      var snapshot = await notes.list();
      expect(snapshot.annotations, isEmpty);
      final chapters = LegacyChapterSession(state, id);
      final page = await chapters.read(0);
      final range = await notes.resolveLines(
        snapshot,
        entryId: page.nodes.first.id,
        firstLine: 2,
        lastLine: 4,
      );
      expect(range.start, offset('亲爱的'));
      expect(range.end, offset('【误判'));
      final letter = await notes.previewAdd(
        snapshot,
        start: range.start,
        end: range.end,
        kind: BlockAnnotationKind.letter,
      );
      expect(letter.after.annotations.single.excerpt, contains('林舟'));
      expect((await notes.list()).annotations, isEmpty);
      await notes.confirm(letter);
      snapshot = await notes.list();
      final letterId = snapshot.annotations.single.id;
      await expectLater(
        notes.previewAdd(
          snapshot,
          start: offset('亲爱的'),
          end: offset('林舟'),
          kind: BlockAnnotationKind.quote,
        ),
        throwsA(
          isA<BlockAnnotationException>().having(
            (e) => e.reason,
            'reason',
            'block_annotation_overlap',
          ),
        ),
      );
      await notes.confirm(await notes.previewUndo());
      expect((await notes.list()).annotations, isEmpty);
      await notes.confirm(await notes.previewRedo());
      snapshot = await notes.list();
      await notes.confirm(
        await notes.previewUpdate(
          snapshot,
          letterId,
          start: offset('亲爱的'),
          end: offset('【误判'),
          kind: BlockAnnotationKind.quote,
        ),
      );
      expect(
        (await notes.list()).annotations.single.kind,
        BlockAnnotationKind.quote,
      );
      await notes.confirm(await notes.previewUndo());
      await notes.confirm(
        await notes.previewAdd(
          await notes.list(),
          start: offset('【误判'),
          end: offset('【自动'),
          kind: BlockAnnotationKind.none,
        ),
      );
      expect(
        history
            .records(id)
            .any(
              (r) =>
                  r.category == '手工标注' &&
                  r.destination == 'chapters' &&
                  history
                      .detail(r)
                      .fields
                      .any((f) => f.label.startsWith('手工标注块')),
            ),
        true,
      );
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'note_style': {'op': 'set', 'value': 'popup'},
                'first_paragraph_style': {
                  'op': 'set',
                  'value': 'large_initial',
                },
              },
            },
          }),
        ),
        true,
      );
      final project = '$root/book.easypub.json';
      expect(await state.saveProjectOutcome(project), true);
      final reopened = PrototypeState(settingsDirectory: '$root/reopened');
      try {
        expect(await reopened.openProjectOutcome(project), true);
        final session = LegacyBlockAnnotationSession(
          reopened,
          reopened.currentId,
        );
        expect((await session.list()).annotations.map((a) => a.kind), [
          BlockAnnotationKind.letter,
          BlockAnnotationKind.none,
        ]);
        session.dispose();
      } finally {
        reopened.dispose();
      }
      var capturedKfx = false;
      void captureValidation() {
        if (capturedKfx || state.outputs.tasks.isEmpty) return;
        final task = state.outputs.tasks.last;
        if (task.format != 'KFX' || task.phase != 'complete') return;
        final stage = task.receipt!['conversion_directory'] as String;
        File('$stage/validation.log').copySync('$root/kfx-validation.log');
        File('$stage/input.epub').copySync('$root/kfx-input.epub');
        capturedKfx = true;
      }

      state.addListener(captureValidation);
      Future<String> convert(String format, String directory) async {
        final session = LegacyConversionSession(state);
        try {
          final plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: directory,
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
          expect(output.complete, true, reason: '$format: ${output.detail}');
          return output.path;
        } finally {
          session.dispose();
        }
      }

      Future<void> inspect(
        String path, {
        bool restore = false,
        bool invalidated = false,
        bool roundtrip = false,
      }) async {
        final process = await Process.run(
          Platform.environment['EASYPUB_TEST_PYTHON']!,
          [
            '-I',
            '-X',
            'utf8',
            '../tools/verify_manual_blocks.py',
            path,
            if (restore) ...['--source', source.path],
            if (invalidated) '--invalidated',
            if (roundtrip) '--roundtrip',
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          process.exitCode,
          0,
          reason: '${process.stdout}\n${process.stderr}',
        );
        evidence.add(jsonDecode(process.stdout as String));
      }

      for (final format in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
        final output = await convert(format, '$root/$format');
        if (format == 'EPUB') {
          await inspect(output, restore: true);
          continue;
        }
        if (format == 'MOBI') await inspect(output);
        final decoded = '$root/$format-roundtrip.epub';
        final result = await Process.run(
          Platform.environment['EASYPUB_TEST_BOKAI']!,
          ['convert', '--no-validate', output, decoded],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        await inspect(decoded, roundtrip: true);
      }
      expect(capturedKfx, true);
      final validation = File('$root/kfx-validation.log').readAsStringSync();
      expect(validation, matches(RegExp(r'CSS props:\s+100\.00% covered')));
      expect(validation, matches(RegExp(r'Fallback:\s+0 \(0\.00%\)')));
      // 清理不覆盖 TXT，也不能把旧标注猜测搬到新位置。
      snapshot = await notes.list();
      final pending = await notes.previewDelete(letterId);
      final cleanup = library.openCleanup(id);
      try {
        await cleanup.apply(
          await cleanup.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'trim_trailing_spaces'},
              ],
            }),
          ),
        );
      } finally {
        cleanup.dispose();
      }
      await expectLater(
        notes.confirm(pending),
        throwsA(isA<BlockAnnotationException>()),
      );
      expect((await notes.list()).invalidAnnotations, hasLength(2));
      await expectLater(
        notes.previewAdd(
          snapshot,
          start: offset('亲爱的'),
          end: offset('【误判'),
          kind: BlockAnnotationKind.letter,
        ),
        throwsA(
          isA<BlockAnnotationException>().having(
            (e) => e.reason,
            'reason',
            'block_annotation_stale',
          ),
        ),
      );
      await inspect(
        await convert('EPUB', '$root/invalidated'),
        invalidated: true,
      );
      await notes.confirm(await notes.previewDelete(letterId));
      expect((await notes.list()).annotations, hasLength(1));
      expect(source.readAsBytesSync(), original);
      await state.outputs.historySaved;
      File(
        '$root/verification.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
    } finally {
      history.dispose();
      library.dispose();
      state.dispose();
    }
  });
}
