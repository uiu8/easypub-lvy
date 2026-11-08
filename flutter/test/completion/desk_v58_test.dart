import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/manual_note_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/desk/fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('LAY-126：两种手工注释的服务、项目、四格式输出和失效', () async {
    await loadDeskFonts();
    final calibre = Platform.environment['EASYPUB_TEST_CALIBRE'];
    expect(calibre, isNotNull, reason: 'V58 验收必须配置 Calibre，不跳过注释回读。');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v58-notes-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final evidence = <Object?>[];

    Future<String> run(
      String program,
      List<String> args,
      String logName,
    ) async {
      final result = await Process.run(
        program,
        args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final log = '${result.stdout}\n${result.stderr}';
      File('$root/$logName').writeAsStringSync(log);
      expect(result.exitCode, 0, reason: log);
      return log;
    }

    Future<void> inspect(String path, List<String> options, String name) async {
      final log = await run(Platform.environment['EASYPUB_TEST_PYTHON']!, [
        '-I',
        '-X',
        'utf8',
        '../tools/verify_popup_notes.py',
        path,
        '--expected',
        '2',
        ...options,
      ], name);
      evidence.add(jsonDecode(log));
    }

    try {
      await library.load();
      expect(await library.savePatch({'check_after_import': false}), true);
      const body = '　　港口的雾（甲）从傍晚开始往岸上爬。  ';
      final source = File('$root/V58书籍复验.txt')
        ..writeAsStringSync(
          '第一章 雾港\r\n$body\r\n作者注：雾是近地面的小水滴。\r\n'
          '第二章 旧码头\n　　旧码头在晨光里显出轮廓。\n'
          '　　船夫收起缆绳，沿着木桥走向岸边。\n'
          '　　这一段仍是正文。新写注释应当出现在本章正文结束之后。\n',
        );
      final original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'author': {'op': 'set', 'value': 'EasyPub 验收'},
              },
            },
          }),
        ),
        true,
      );
      final notes = library.openManualNotes(id);
      addTearDown(notes.dispose);
      final chapters = library.openChapters(id);
      final tree = await chapters.read(0);
      var snapshot = await notes.list();
      expect(snapshot.notes, isEmpty);
      final reference = await notes.resolvePosition(
        snapshot,
        entryId: tree.nodes.first.id,
        line: 1,
        utf16Start: body.indexOf('（甲）'),
        utf16End: body.indexOf('（甲）') + 3,
      );
      final definition = await notes.resolvePosition(
        snapshot,
        entryId: tree.nodes.first.id,
        line: 2,
        utf16Start: 0,
        utf16End: 0,
      );
      final pair = await notes.previewAdd(
        snapshot,
        ManualNoteDraft.pair(reference, definition),
      );
      expect((await notes.list()).notes, isEmpty);
      await notes.confirm(pair);
      await expectLater(
        notes.confirm(pair),
        throwsA(isA<ManualNoteException>()),
      );
      snapshot = await notes.list();
      final pairId = snapshot.notes.single.id;
      final position = await notes.resolvePosition(
        snapshot,
        entryId: tree.nodes.last.id,
        line: 1,
        utf16Start: 5,
        utf16End: 5,
      );
      await notes.confirm(
        await notes.previewAdd(
          snapshot,
          ManualNoteDraft.newText(
            position,
            '这是读者自己写的注释，原稿中没有这段话。\n第二段：用于确认多段文字完整显示。',
          ),
        ),
      );
      snapshot = await notes.list();
      expect(snapshot.notes.map((n) => n.kind), [
        ManualNoteKind.pair,
        ManualNoteKind.newNote,
      ]);
      expect(snapshot.notes.every((n) => n.valid && n.enabled), true);
      expect(state.publicationRequest(id)['settings']['note_style'], 'off');
      await notes.confirm(await notes.previewUndo());
      expect((await notes.list()).notes, hasLength(1));
      await notes.confirm(await notes.previewRedo());
      final project = '$root/project.easypub.json';
      expect(await state.saveProjectOutcome(project), true);
      final reopened = PrototypeState(
        settingsDirectory: '$root/reopened-settings',
      );
      final reopenedLibrary = LegacyLibraryAdapter(backend: reopened);
      try {
        expect(await reopened.openProjectOutcome(project), true);
        final restored = reopenedLibrary.openManualNotes(reopened.currentId);
        expect(
          (await restored.list()).notes.map((n) => n.text),
          (await notes.list()).notes.map((n) => n.text),
        );
        restored.dispose();
      } finally {
        reopenedLibrary.dispose();
        reopened.dispose();
      }
      var captured = false;
      var azw3Captured = false;
      void captureValidation() {
        if (state.outputs.tasks.isEmpty) return;
        final task = state.outputs.tasks.last;
        if (task.phase != 'complete' ||
            (task.format != 'AZW3' && task.format != 'KFX')) {
          return;
        }
        final stage = task.receipt!['conversion_directory'] as String;
        if (task.format == 'AZW3' && !azw3Captured) {
          File('$stage/input.epub').copySync('$root/azw3-input.epub');
          azw3Captured = true;
        }
        if (task.format == 'KFX' && !captured) {
          File('$stage/input.epub').copySync('$root/kfx-input.epub');
          File('$stage/validation.log').copySync('$root/kfx-validation.log');
          captured = true;
        }
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
              engine: switch (format) {
                'KFX' => Platform.environment['EASYPUB_TEST_BOKAI']!,
                'AZW3' ||
                'MOBI' => Platform.environment['EASYPUB_TEST_KINDLING']!,
                _ => '',
              },
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
          if (format == 'AZW3') {
            final receipt = state.outputs.tasks.last.receipt!;
            expect(receipt['kindle_identity']['content_type'], 'EBOK');
            expect(azw3Captured, true);
            final report = await run(
              Platform.environment['EASYPUB_TEST_PYTHON']!,
              [
                '-I',
                '-X',
                'utf8',
                '../tools/verify_kindle_book.py',
                output.path,
              ],
              'azw3-book-identity.json',
            );
            evidence.add(jsonDecode(report));
          }
          if (format != 'KFX') {
            await inspect(output.path, [
              if (format == 'EPUB') ...['--source', source.path],
            ], '$format-verification.json');
            continue;
          }
          expect(captured, true);
          final validation = File('$root/kfx-validation.log')
              .readAsStringSync();
          expect(validation, matches(RegExp(r'CSS props:\s+100\.00% covered')));
          expect(validation, matches(RegExp(r'Fallback:\s+0 \(0\.00%\)')));
          await inspect('$root/kfx-input.epub', [
            '--kfx-roundtrip',
            '--source',
            source.path,
          ], 'kfx-input-verification.json');
          await run(Platform.environment['EASYPUB_TEST_BOKAI']!, [
            'convert',
            output.path,
            '$root/kfx-roundtrip.epub',
          ], 'kfx-roundtrip.log');
          await inspect('$root/kfx-roundtrip.epub', [
            '--kfx-roundtrip',
          ], 'kfx-roundtrip-verification.json');
          final log = await run(calibre!, [
            output.path,
            '$root/calibre-roundtrip.epub',
          ], 'calibre.log');
          expect(log, isNot(matches(RegExp(r'^ERROR:', multiLine: true))));
          await inspect('$root/calibre-roundtrip.epub', [
            '--calibre-roundtrip',
          ], 'calibre-verification.json');
          evidence.add({
            'format': 'KFX',
            'path': output.path,
            'bokai_validation': true,
            'calibre_conversion': true,
            'kindle_device': 'pending',
          });
        } finally {
          session.dispose();
        }
      }
      final stale = await notes.previewDelete(pairId);
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
      expect((await notes.list()).notes.where((n) => !n.valid), hasLength(2));
      await expectLater(
        notes.confirm(stale),
        throwsA(isA<ManualNoteException>()),
      );
      expect(source.readAsBytesSync(), original);
      await state.outputs.historySaved;
      File(
        '$root/verification.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
