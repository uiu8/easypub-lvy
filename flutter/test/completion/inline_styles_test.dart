import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/inline_style_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('V105 inline style history, project and four format output', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('inline-styles-'))
        .absolute
        .path;
    final state = PrototypeState(settingsDirectory: '$root/settings');
    final library = LegacyLibraryAdapter(backend: state);
    try {
      await library.load();
      await library.savePatch({'check_after_import': false});
      const body = '😀粗体斜体着重下划波浪楷体仿宋与｜汉字《hàn zì》。';
      final source = File('$root/合成稿.txt')
        ..writeAsStringSync('第一章 起始\n$body\n第二章 结束\n保留原文。\n');
      final original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      final info = library.openBookInformation(id);
      await info.apply(
        await info.preview({
          'title': '行内样式验收',
          'author': '合成作者',
          'language': 'zh-CN',
        }),
      );
      info.dispose();
      final styles = library.openInlineStyles(id);
      final chapters = library.openChapters(id);
      final tree = await chapters.read(0);
      const cases = {
        '粗体': 'bold',
        '斜体': 'italic',
        '着重': 'em_dot',
        '下划': 'underline',
        '波浪': 'wavy',
        '楷体': 'kai',
        '仿宋': 'fang_song',
      };
      for (final entry in cases.entries) {
        final snapshot = await styles.list();
        final anchor = await styles.resolvePosition(
          snapshot,
          entryId: tree.nodes.first.id,
          line: 1,
          utf16Start: body.indexOf(entry.key),
          utf16End: body.indexOf(entry.key) + entry.key.length,
        );
        final preview = await styles.previewAdd(
          snapshot,
          InlineStyleDraft(anchor, entry.value),
        );
        expect((await styles.list()).items.length, snapshot.items.length);
        await styles.confirm(preview);
        await expectLater(
          styles.confirm(preview),
          throwsA(isA<InlineStyleException>()),
        );
      }
      await styles.confirm(await styles.previewUndo());
      expect((await styles.list()).items.length, 6);
      await styles.confirm(await styles.previewRedo());
      expect((await styles.list()).items.length, 7);
      final project = '$root/book.easypub.json';
      expect(await state.saveProjectOutcome(project), true);
      final restored = PrototypeState(
        settingsDirectory: '$root/restored-settings',
      );
      final other = LegacyLibraryAdapter(backend: restored);
      try {
        expect(await restored.openProjectOutcome(project), true);
        final session = other.openInlineStyles(restored.currentId);
        expect((await session.list()).items.length, 7);
        session.dispose();
      } finally {
        other.dispose();
        restored.dispose();
      }
      var captured = false;
      void capture() {
        if (captured || state.outputs.tasks.isEmpty) return;
        final task = state.outputs.tasks.last;
        if (task.phase != 'complete' || task.format != 'KFX') return;
        final stage = task.receipt!['conversion_directory'] as String;
        File('$stage/input.epub').copySync('$root/kfx-input.epub');
        File('$stage/validation.log').copySync('$root/kfx-validation.log');
        captured = true;
      }

      state.addListener(capture);
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
          expect(
            plan.previewed,
            true,
            reason: plan.findings.map((e) => e.detail).join('\n'),
          );
          final output = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true, reason: '$format: ${output.detail}');
          if (format == 'KFX') {
            final validation = File('$root/kfx-validation.log')
                .readAsStringSync();
            expect(
              validation,
              matches(RegExp(r'CSS props:\s+100\.00% covered')),
            );
            expect(validation, matches(RegExp(r'Fallback:\s+0 \(0\.00%\)')));
          }
          if (format != 'EPUB') {
            final decoded = await Process.run(
              Platform.environment['EASYPUB_TEST_CALIBRE']!,
              [output.path, '$root/$format-roundtrip.epub'],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
            );
            File('$root/$format-calibre.log')
                .writeAsStringSync('${decoded.stdout}\n${decoded.stderr}');
            expect(
              decoded.exitCode,
              0,
              reason: '${decoded.stdout}\n${decoded.stderr}',
            );
          }
        } finally {
          session.dispose();
        }
      }
      expect(source.readAsBytesSync(), original);
      styles.dispose();
    } finally {
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
