import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('OUT-086：KFX 弹出注释可被 Calibre 读回，四格式保留双向链接与原文', () async {
    final calibre = Platform.environment['EASYPUB_TEST_CALIBRE'];
    expect(calibre, isNotNull, reason: 'V57 验收必须配置 Calibre，不跳过注释回读。');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('v57-notes-'))
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
        '3',
        ...options,
      ], name);
      evidence.add(jsonDecode(log));
    }

    try {
      await library.load();
      expect(await library.savePatch({'check_after_import': false}), true);
      // 自拟文字同时作为 Kindle 真机样书；三种标记和不成对的 ④。
      final source = File('$root/V57注释验收.txt')
        ..writeAsStringSync(
          '第一章 雾港\r\n'
          '　　港口的雾①从傍晚开始往岸上爬，先是吞掉了灯塔的底座。\r\n'
          '　　老周把船缆绕在桩上[2]，抬头看了一眼天色。\r\n'
          '　　没有对应注释的标记④应原样保留。\r\n'
          '①雾：近地面空气中的水汽凝结成的小水滴。\r\n'
          '[2] 桩：码头边用来系船的铁柱或木柱。\r\n'
          '第二章 旧码头\n'
          '　　天亮时，旧码头〔3〕露出了斑驳的样子。\n'
          '〔3〕旧码头：清末修建，后来废弃。',
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
                'note_style': {'op': 'set', 'value': 'popup'},
              },
            },
          }),
        ),
        true,
      );
      var captured = false;
      void captureValidation() {
        if (captured || state.outputs.tasks.isEmpty) return;
        final task = state.outputs.tasks.last;
        if (task.format != 'KFX' || task.phase != 'complete') return;
        final stage = task.receipt!['conversion_directory'] as String;
        File('$stage/input.epub').copySync('$root/kfx-input.epub');
        File('$stage/validation.log').copySync('$root/kfx-validation.log');
        captured = true;
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
