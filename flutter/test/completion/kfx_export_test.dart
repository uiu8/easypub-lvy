import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_defaults.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/native_conversion_desktop.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

void main() {
  test('Bokai KFX uses effective Chinese book, persists defaults and history, keeps source', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory('../artifacts').createTemp('kfx-export-');
    final engine = Platform.environment['EASYPUB_TEST_BOKAI']!;
    final state = PrototypeState(
      settingsDirectory: '${root.absolute.path}/settings',
    );
    final library = LegacyLibraryAdapter(backend: state);
    final evidence = <Object>[];
    try {
      await library.load();
      await library.savePatch({
        'check_after_import': false,
        'output_format': 'KFX',
        'kfx_converter': engine,
        'output_directory': root.absolute.path,
      });
      final defaults = await resolveConversionDefaults(
        readConversionDefaults(state.globalConfiguration),
        NativeConversionDesktop(),
      );
      expect(defaults['kindle_converter'], engine);
      final source = File('${root.absolute.path}/原稿.txt')
        ..writeAsStringSync(
          '第一章 开始\n这是简体正文，保留中文标点：“你好！”\n第二章 結束\n這是繁體正文。END_SENTINEL_中文。\n',
        );
      final longText = StringBuffer();
      for (var chapter = 3; chapter <= 120; chapter++) {
        longText.writeln('第$chapter章 长篇校验');
        for (var line = 0; line < 60; line++) {
          longText.writeln('中文长篇正文保留，繁體文字與標點同行。第$chapter节，第$line行。');
        }
      }
      source.writeAsStringSync(longText.toString(), mode: FileMode.append);
      final original = source.readAsBytesSync();
      expect((await library.importFiles([source.path])).single.succeeded, true);
      final id = state.currentId;
      for (final language in ['zh-CN', 'zh-TW']) {
        final info = library.openBookInformation(id);
        await info.apply(
          await info.preview({
            'title': '中文 KFX & 测试',
            'author': '合成作者',
            'publisher': '合成出版社',
            'description': '简介与正文分别保留。',
            'language': language,
          }),
        );
        info.dispose();
        final session = LegacyConversionSession(state);
        try {
          var plan = await session.preview(
            ConversionRequest(
              books: [id],
              directory: '${root.absolute.path}/$language',
              format: 'KFX',
              engine: engine,
              generateCover: true,
              runChecks: false,
            ),
          );
          expect(
            plan.previewed,
            true,
            reason: plan.findings.map((e) => e.detail).join('\n'),
          );
          if (language == 'zh-CN') {
            final occupied = File(plan.outputs.single.path);
            occupied.parent.createSync(recursive: true);
            occupied.writeAsStringSync('已有文件保持不变');
            final failed = (await session.commit(
              plan,
              acknowledgeWarnings: true,
            )).single;
            expect(failed.failed, true);
            expect(occupied.readAsStringSync(), '已有文件保持不变');
            occupied.deleteSync();
            plan = await session.previewRetry([state.outputs.tasks.last.taskId]);
            expect(plan.previewed, true);
            expect(session.request!.format, 'KFX');
            expect(session.request!.engine, engine);
          }
          final output = (await session.commit(
            plan,
            acknowledgeWarnings: true,
          )).single;
          expect(output.complete, true, reason: output.detail);
          final bytes = File(output.path).readAsBytesSync();
          expect(ascii.decode(bytes.take(4).toList()), 'CONT');
          final metadata = await Process.run(
            engine,
            ['info', '--json', output.path],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(metadata.exitCode, 0, reason: '${metadata.stderr}');
          final book = jsonDecode(metadata.stdout as String) as Map;
          expect(book['metadata']['title'], '中文 KFX&测试');
          expect(book['metadata']['authors'], contains('合成作者'));
          expect(jsonEncode(book['toc']), contains('第一章 开始'));
          expect(jsonEncode(book['toc']), contains('第二章 結束'));
          expect(jsonEncode(book['toc']), contains('第120章 长篇校验'));
          expect((book['toc'] as List).length, 121);
          expect(
            (book['toc'] as List).map((e) => e['href']).toSet().length,
            121,
          );
          expect(
            book['metadata']['language'],
            language == 'zh-CN' ? 'zh-hans' : 'zh-hant',
          );
          final txt = '${root.absolute.path}/$language.txt';
          final decoded = await Process.run(
            engine,
            ['convert', output.path, txt],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
          final content = File(txt).readAsStringSync().replaceAll(r'\_', '_');
          expect(content, contains('END_SENTINEL_中文'));
          expect(content, contains('这是简体正文'));
          final calibre = Platform.environment['EASYPUB_TEST_CALIBRE'];
          if (calibre != null) {
            final decoded = await Process.run(
              calibre,
              [output.path, '${root.absolute.path}/$language-calibre.epub'],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
            );
            final log = '${decoded.stdout}\n${decoded.stderr}';
            File('${root.absolute.path}/$language-calibre.log')
                .writeAsStringSync(log);
            expect(decoded.exitCode, 0, reason: log);
            expect(log, isNot(contains('ERROR:')), reason: log);
          }
          final history = library.openOutputHistory();
          await history.load();
          final record = history
              .page(0)
              .firstWhere((e) => e.path == output.path);
          expect(record.format, 'KFX');
          expect(
            (await history.inspectPackage(record.id)).status,
            'kfx_container_checked',
          );
          evidence.add({
            'language': language,
            'path': output.path,
            'bytes': bytes.length,
            'metadata': book['metadata'],
          });
        } finally {
          session.dispose();
        }
      }
      final project = '${root.absolute.path}/saved.easypub.json';
      expect((await library.saveProject(project)).succeeded, true);
      final reopened = LegacyLibraryAdapter(
        backend: PrototypeState(
          settingsDirectory: '${root.absolute.path}/settings',
        ),
      );
      try {
        await reopened.load();
        expect((await reopened.openProject(project)).succeeded, true);
        final history = reopened.openOutputHistory();
        await history.load();
        expect(history.page(0).where((e) => e.format == 'KFX').length, 3);
      } finally {
        reopened.dispose();
      }
      expect(source.readAsBytesSync(), original);
    } finally {
      File(
        '${root.absolute.path}/evidence.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
      library.dispose();
      state.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
