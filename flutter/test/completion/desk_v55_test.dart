import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/supplemental_page_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_change_history_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('META-047：模板快照、附页变更与项目、四格式和 Calibre 往返', () async {
    final calibre = Platform.environment['EASYPUB_TEST_CALIBRE'];
    expect(calibre, isNotNull, reason: 'V55 验收必须配置 Calibre，不跳过 KFX 回读。');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory(
      '../artifacts',
    ).createTemp('v55-supplements-')).absolute.path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    final history = LegacyChangeHistoryService(state);
    const text = '第一章 启程\r\n　首段保持原文。\r\n正文留白。  \n第二章 归来\n末行保持';
    final source = File('$root/远行.txt')..writeAsStringSync(text);
    final original = source.readAsBytesSync();
    final evidence = <Object?>[];
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      final pages = library.openSupplementalPages(id);
      addTearDown(pages.dispose);
      expect((await pages.list()).pages, isEmpty);
      final templates = library.supplementalTemplates;
      var catalog = await templates.list();
      catalog = await templates.save(
        catalog,
        name: '版权模板',
        content: SupplementalPageContent(
          kind: SupplementalPageKind.copyright,
          title: '版权声明',
          body: '版权正文 {书名}\n{作者} {译者} {年份}\n{出版社} {未知}\n纯文本 <附页> & 保留',
          includeToc: true,
        ),
      );
      final template = catalog.templates.single;
      expect(
        (await templates.list()).templates.single.content.body,
        template.content.body,
      );
      final copyright = await pages.previewApplyTemplate(template);
      expect(copyright.warnings.single.placeholder, '{未知}');
      expect(copyright.warnings.single.message, contains('原样保留'));
      expect(copyright.after.pages.single.content.body, contains('版权正文 远行'));
      expect((await pages.list()).pages, isEmpty);
      await pages.confirm(copyright);
      await expectLater(
        pages.confirm(copyright),
        throwsA(isA<SupplementalPageException>()),
      );
      final front = (await pages.list()).pages.single;
      await pages.confirm(
        await pages.previewAdd(
          SupplementalPageContent(
            kind: SupplementalPageKind.afterword,
            title: '后记',
            body: '后记正文 谢谢阅读。\n第二段文字。',
            includeToc: true,
          ),
        ),
      );
      final back = (await pages.list()).pages.last;
      await pages.confirm(await pages.previewReorder([back.id, front.id]));
      await pages.confirm(
        await pages.previewUpdate(
          back.id,
          SupplementalPageContent(
            kind: SupplementalPageKind.afterword,
            title: '后记',
            body: '后记正文 谢谢阅读。\n更新后的第二段。',
            includeToc: true,
          ),
        ),
      );
      await pages.confirm(await pages.previewDelete(front.id));
      expect((await pages.list()).pages, hasLength(1));
      await pages.confirm(await pages.previewUndo());
      expect((await pages.list()).pages, hasLength(2));
      await pages.confirm(await pages.previewRedo());
      await pages.confirm(await pages.previewUndo());
      expect(
        history
            .records(id)
            .any(
              (r) =>
                  r.category == '前后附页' &&
                  r.destination == 'information' &&
                  history
                      .detail(r)
                      .fields
                      .any((f) => f.label.startsWith('前后附页')),
            ),
        true,
      );
      final pending = await pages.previewDelete(front.id);
      expect(
        await state.production.confirm(
          await state.production.previewChanges({
            id: {
              'op': 'patch',
              'fields': {
                'title': {'op': 'set', 'value': '新书名'},
                'visible_toc': {'op': 'set', 'value': true},
                'chapter_navigation': {'op': 'set', 'value': false},
              },
            },
          }),
        ),
        true,
      );
      await expectLater(
        pages.confirm(pending),
        throwsA(isA<SupplementalPageException>()),
      );
      expect((await pages.list()).pages.last.content.body, contains('版权正文 远行'));
      catalog = await templates.delete(await templates.list(), template.id);
      expect(catalog.templates, isEmpty);
      expect((await pages.list()).pages, hasLength(2));
      await expectLater(
        pages.previewAdd(
          SupplementalPageContent(
            kind: SupplementalPageKind.dedication,
            body: '字' * 20001,
          ),
        ),
        throwsA(
          isA<SupplementalPageException>().having(
            (e) => e.reason,
            'reason',
            'supplemental_body_too_long',
          ),
        ),
      );
      final project = '$root/book.easypub.json';
      expect(await state.saveProjectOutcome(project), true);
      final reopened = PrototypeState(settingsDirectory: '$root/reopened');
      final other = LegacyLibraryAdapter(backend: reopened);
      try {
        expect(await reopened.openProjectOutcome(project), true);
        final session = other.openSupplementalPages(reopened.currentId);
        expect((await session.list()).pages.map((p) => p.id), [
          back.id,
          front.id,
        ]);
        await session.confirm(await session.previewUndo());
        expect(
          (await session.list()).pages.last.content.body,
          contains('版权正文 远行'),
        );
        session.dispose();
      } finally {
        other.dispose();
        reopened.dispose();
      }
      var captured = false;
      void capture() {
        if (captured || state.outputs.tasks.isEmpty) return;
        final task = state.outputs.tasks.last;
        if (task.format != 'KFX' || task.phase != 'complete') return;
        final stage = task.receipt!['conversion_directory'] as String;
        File('$stage/validation.log').copySync('$root/kfx-validation.log');
        File('$stage/input.epub').copySync('$root/kfx-input.epub');
        captured = true;
      }

      state.addListener(capture);
      Future<void> inspect(String file, {bool sourceMap = false}) async {
        final result = await Process.run(
          Platform.environment['EASYPUB_TEST_PYTHON']!,
          [
            '-I',
            '-X',
            'utf8',
            '../tools/verify_supplemental_pages.py',
            file,
            if (sourceMap) ...['--source', source.path],
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        evidence.add(jsonDecode(result.stdout as String));
      }

      for (final format in ['EPUB', 'AZW3', 'MOBI', 'KFX']) {
        final session = LegacyConversionSession(state);
        late String output;
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
          final result = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(result.complete, true, reason: '$format: ${result.detail}');
          output = result.path;
        } finally {
          session.dispose();
        }
        if (format == 'EPUB') {
          await inspect(output, sourceMap: true);
          continue;
        }
        if (format != 'KFX') {
          final nav = await Process.run(
            Platform.environment['EASYPUB_TEST_PYTHON']!,
            [
              '-I',
              '-X',
              'utf8',
              '../tools/verify_kindle_navigation.py',
              output,
              '--expect-start',
              '第一章 启程',
              '--require-text',
              '版权正文',
              '--require-text',
              '后记正文',
            ],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(nav.exitCode, 0, reason: '${nav.stdout}\n${nav.stderr}');
          evidence.add(jsonDecode(nav.stdout as String));
        }
        final decoded = '$root/$format-roundtrip.epub';
        final decode = await Process.run(
          Platform.environment['EASYPUB_TEST_BOKAI']!,
          ['convert', '--no-validate', output, decoded],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        expect(
          decode.exitCode,
          0,
          reason: '${decode.stdout}\n${decode.stderr}',
        );
        await inspect(decoded);
        if (format == 'KFX') {
          final converted = '$root/KFX-calibre.epub';
          final result = await Process.run(
            calibre!,
            [output, converted],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          final log = '${result.stdout}\n${result.stderr}';
          File('$root/calibre.log').writeAsStringSync(log);
          expect(result.exitCode, 0, reason: log);
          expect(log, isNot(contains('ERROR:')));
          await inspect(converted);
        }
      }
      expect(captured, true);
      final validation = File('$root/kfx-validation.log').readAsStringSync();
      expect(validation, matches(RegExp(r'CSS props:\s+100\.00% covered')));
      expect(validation, matches(RegExp(r'Fallback:\s+0 \(0\.00%\)')));
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
  }, timeout: const Timeout(Duration(minutes: 8)));
}
