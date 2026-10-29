import 'dart:convert';
import 'dart:io';

import 'package:easypub_desktop/application/cleanup_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/output_batch.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 整条使用链的耗时测量（真实 DLL）：导入 → 章节首页与首章正文 → 检查 → 规则统计 →
/// 文本清理检测与影响核对 → EPUB / AZW3 / KFX 准备与生成。只测量并输出，不设门槛。
/// 每轮用新的设置目录（冷启动的书库）。默认跳过，运行方法：
/// `$env:EASYPUB_WORKFLOW_PERF='书1.txt;书2.txt'`（样书路径，先复制出来，不直接读用户目录），
/// 可选 `EASYPUB_WORKFLOW_ROUNDS`（默认 2）、`EASYPUB_WORKFLOW_FORMATS`（默认 EPUB,AZW3,KFX）、
/// `EASYPUB_WORKFLOW_REPORT`（结果 JSON 路径）。
void main() {
  final books = (Platform.environment['EASYPUB_WORKFLOW_PERF'] ?? '')
      .split(';')
      .where((p) => p.trim().isNotEmpty)
      .toList();
  test(
    '整条使用链耗时',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final rounds = int.parse(
        Platform.environment['EASYPUB_WORKFLOW_ROUNDS'] ?? '2',
      );
      final formats =
          (Platform.environment['EASYPUB_WORKFLOW_FORMATS'] ?? 'EPUB,AZW3,KFX')
              .split(',');
      final results = <Map<String, Object?>>[];
      for (var round = 0; round < rounds; round++) {
        for (final source in books) {
          final root = (await Directory('../artifacts').createTemp('wf-perf-'))
              .absolute;
          final state = PrototypeState(
            settingsDirectory: '${root.path}/settings',
          );
          final library = LegacyLibraryAdapter(backend: state);
          final times = <String, int>{};
          final facts = <String, Object?>{};
          Future<T> time<T>(String name, Future<T> Function() body) async {
            final watch = Stopwatch()..start();
            final value = await body();
            times[name] = watch.elapsedMilliseconds;
            return value;
          }

          try {
            await library.load();
            await library.savePatch({'check_after_import': false});
            final copy = await File(source).copy('${root.path}/样书.txt');
            final imported = await time(
              'import',
              () => library.importFiles([copy.path]),
            );
            expect(imported.single.succeeded, true);
            final id = state.currentId;

            final chapters = library.openChapters(id);
            final page = await time(
              'chapters_first_page',
              () => chapters.read(0),
            );
            facts['nodes'] = page.total;
            final firstBody = page.nodes
                .where((n) => n.role == 'chapter' || n.role == 'body')
                .firstOrNull;
            if (firstBody != null) {
              await time(
                'chapter_body',
                () => chapters.body(page, firstBody.id, 0),
              );
            }

            final checks = library.openChecks(id);
            final report = await time('check', () => checks.inspect());
            checks.dispose();
            facts['check_issues'] = report.toString().length;

            final catalog = library.openRuleCatalog(id);
            final stats = await time(
              'rule_statistics',
              () => catalog.request(),
            );
            facts['rule_statistics_ok'] = stats != null;

            final cleanup = library.openCleanup(id);
            final request = jsonEncode(decodeCleanup(cleanup.settings));
            final preview = await time(
              'cleanup_detect',
              () => cleanup.preview(request),
            );
            facts['cleanup_changes'] = preview.stageTotal;
            await time('cleanup_impact', () => cleanup.impact(preview));

            final cover = await File('../samples/b7-covers/transparent.png')
                .copy('${root.path}/cover.png');
            final info = library.openBookInformation(id);
            await info.apply(
              await info.preview({
                'language': 'zh-CN',
                'author': '测量',
                'cover_path': cover.path,
              }),
            );
            info.dispose();

            for (final format in formats) {
              final batch = OutputBatch(state, [id])
                ..parallelOverride = 1
                ..format = format
                ..engine = switch (format) {
                  'KFX' => Platform.environment['EASYPUB_TEST_BOKAI'] ?? '',
                  'EPUB' => '',
                  _ => Platform.environment['EASYPUB_TEST_KINDLING'] ?? '',
                };
              batch.items.single.path =
                  '${root.path}/out.${format.toLowerCase()}';
              await time('${format}_prepare', () => batch.previewAll(() {}));
              await time('${format}_write', () => batch.commitAll(() {}));
              facts['${format}_status'] = batch.items.single.phase;
              if (batch.items.single.phase != 'complete') {
                facts['${format}_message'] = batch.items.single.status;
              }
              final out = File(batch.items.single.path);
              facts['${format}_bytes'] = out.existsSync()
                  ? out.lengthSync()
                  : 0;
            }
          } finally {
            library.dispose();
            state.dispose();
          }
          final row = {
            'round': round + 1,
            'book': source.split(RegExp(r'[\\/]')).last,
            'bytes': File(source).lengthSync(),
            'ms': times,
            ...facts,
          };
          results.add(row);
          // ignore: avoid_print
          print('WORKFLOW_PERF ${jsonEncode(row)}');
        }
      }
      final path = Platform.environment['EASYPUB_WORKFLOW_REPORT'];
      if (path != null) {
        await File(path)
            .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
      }
    },
    skip: books.isEmpty,
    timeout: const Timeout(Duration(minutes: 90)),
  );
}
