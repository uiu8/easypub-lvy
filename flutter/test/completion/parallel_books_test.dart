import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/application/parallel_books.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/output_batch.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

/// V38：多本并行（SET-069、LIB-115、OUT-083）——导入、书库检查、转换前检查与转换按设置同时进行，
/// 结果与逐本处理相同，顺序不乱。
Future<Map<String, String>> members(String path) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import json,re,sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
 out={}
 for n in z.namelist():
  t=z.read(n).decode('utf-8','replace')
  # 只去掉生成时间这一项，其余逐字比较。
  if n.endswith('.opf'): t=re.sub(r'<meta property="dcterms:modified">[^<]*</meta>','',t)
  out[n]=t
 print(json.dumps(out,ensure_ascii=False))
''',
      path,
    ],
    stdoutEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Map<String, String>.from(jsonDecode(result.stdout as String) as Map);
}

/// AZW3 的各条 PDB 记录，去掉 SRCS（Kindling 原样嵌入的源 EPUB：生成时间不同，压缩后大小可差 1 字节）。
List<String> azw3Records(String path) {
  final d = File(path).readAsBytesSync();
  final view = ByteData.sublistView(d);
  final n = view.getUint16(76);
  final offsets = [
    for (var i = 0; i < n; i++) view.getUint32(78 + 8 * i),
    d.length,
  ];
  return [
    for (var i = 0; i < n; i++)
      if (String.fromCharCodes(d.sublist(offsets[i], offsets[i] + 4)) != 'SRCS')
        base64Encode(d.sublist(offsets[i], offsets[i + 1])),
  ];
}

void main() {
  test('本数换算：自动按处理器数，值不认识时按自动', () {
    expect(autoParallelBooks(32), 4);
    expect(autoParallelBooks(8), 2);
    expect(autoParallelBooks(4), 1);
    expect(autoParallelBooks(2), 1);
    expect(parallelBooks({'parallel_books': '2'}), 2);
    expect(parallelBooks({'parallel_books': '8'}), 8);
    expect(parallelBooks({'parallel_books': 'auto'}, processors: 16), 4);
    expect(parallelBooks({'parallel_books': '3'}, processors: 8), 2);
    expect(parallelBooks(const {}, processors: 12), 3);
    expect(parallelBookChoices.keys, ['auto', '1', '2', '4', '8']);
  });

  test('runLimited 与 ConcurrencyLimit 不超过上限、按顺序开始；SerialQueue 逐个执行', () async {
    for (final limit in [1, 2, 4]) {
      var running = 0, peak = 0;
      final started = <int>[];
      await runLimited(List.generate(10, (i) => i), limit, (item, index) async {
        expect(item, index);
        started.add(item);
        running++;
        if (running > peak) peak = running;
        await Future<void>.delayed(Duration(milliseconds: 3 + (item * 7) % 5));
        running--;
      });
      expect(started, List.generate(10, (i) => i), reason: '$limit');
      expect(peak, limit);
    }
    // 交接名额时新来的任务不能插队超出上限。
    final gate = ConcurrencyLimit(2);
    var running = 0, peak = 0;
    final order = <int>[];
    Future<void> job(int i) => gate.run(() async {
      order.add(i);
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      running--;
    });
    final jobs = [for (var i = 0; i < 6; i++) job(i)];
    await Future<void>.delayed(const Duration(milliseconds: 1));
    jobs.addAll([for (var i = 6; i < 9; i++) job(i)]);
    await Future.wait(jobs);
    expect(peak, 2);
    expect(order, List.generate(9, (i) => i));
    final queue = SerialQueue();
    final log = <String>[];
    await Future.wait([
      for (var i = 0; i < 4; i++)
        queue.run(() async {
          log.add('start $i');
          await Future<void>.delayed(Duration(milliseconds: 4 - i));
          log.add('end $i');
        }),
    ]);
    expect(log, [
      for (var i = 0; i < 4; i++) ...['start $i', 'end $i'],
    ]);
  });

  test('4 本同时：导入、书库检查、转换前检查、EPUB / AZW3 转换与逐本处理结果相同，顺序不乱', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('parallel-books-'))
        .absolute;
    final evidence = <String, Object?>{};
    Future<Map<String, Object?>> runAll(String parallel) async {
      final dir = '${root.path}/p$parallel';
      final state = PrototypeState(settingsDirectory: '$dir/settings');
      final library = LegacyLibraryAdapter(backend: state);
      final out = <String, Object?>{};
      try {
        await library.load();
        expect(
          await library.savePatch({
            'check_after_import': true,
            'parallel_books': parallel,
          }),
          true,
        );
        expect(state.globalConfiguration['parallel_books'], parallel);
        // 6 本：每本 60 章，各本内容不同。
        final paths = <String>[];
        for (var b = 1; b <= 6; b++) {
          final text = StringBuffer();
          for (var c = 1; c <= 60; c++) {
            text.writeln('第$c章 第$b本第$c章');
            for (var p = 0; p < 6; p++) {
              text.writeln('这是第$b本书第$c章的第$p段，窗外的雨下了一整夜。');
            }
          }
          final file = File('$dir/书$b.txt')
            ..createSync(recursive: true)
            ..writeAsStringSync(text.toString());
          paths.add(file.path);
        }
        final watch = Stopwatch()..start();
        final imported = await library.importFiles(paths);
        out['import_ms'] = watch.elapsedMilliseconds;
        expect(imported.map((r) => r.path), paths);
        expect(imported.every((r) => r.succeeded), true);
        // 书的标识是原稿路径的小写（与导入时相同）。
        final ids = [for (final p in paths) p.trim().toLowerCase()];
        for (final id in ids) {
          expect(state.shelf.books.any((b) => b.id == id), true, reason: id);
        }
        // 书库批量检查：结果按所选顺序。
        await library.inspectBooks(ids.toSet());
        final titles = [
          for (final id in ids)
            state.shelf.books.firstWhere((b) => b.id == id).title,
        ];
        // 书库检查按书库列表的顺序；并行与逐本的顺序必须相同（见文末比较）。
        expect(
          library.checkBatch.results.map((r) => r.title).toSet(),
          titles.toSet(),
        );
        out['check_order'] = [
          for (final r in library.checkBatch.results) r.title,
        ];
        expect(library.checkBatch.results.length, 6);
        // 转换前检查：报告按批次顺序。
        final batch = OutputBatch(state, ids)..format = 'AZW3';
        batch.engine = Platform.environment['EASYPUB_TEST_KINDLING']!;
        expect(batch.parallel, int.parse(parallel));
        final reports = await batch.runPreflight(() {});
        expect(reports.map((r) => r.bookId), ids);
        // EPUB 与 AZW3 转换（经软件的正式入口）。
        for (final format in ['EPUB', 'AZW3']) {
          final session = LegacyConversionSession(state);
          try {
            watch.reset();
            final plan = await session.preview(
              ConversionRequest(
                books: ids,
                directory: '$dir/out-$format',
                format: format,
                engine: Platform.environment['EASYPUB_TEST_KINDLING']!,
                generateCover: true,
                runChecks: false,
              ),
            );
            expect(
              plan.previewed,
              true,
              reason: plan.findings.map((e) => e.detail).join('\n'),
            );
            final results = await session.commit(
              plan,
              acknowledgeWarnings: true,
            );
            out['${format}_ms'] = watch.elapsedMilliseconds;
            expect(results.length, 6);
            expect(
              results.every((r) => r.complete),
              true,
              reason: results.map((r) => r.detail).join('\n'),
            );
            out[format] = [for (final r in results) r.path];
          } finally {
            session.dispose();
          }
        }
        // 批次记录按原顺序，状态为完成；任务的批次序号连续。
        final record = state.outputs.batchRecords.last;
        expect(record['state'], 'complete');
        expect([for (final i in record['items'] as List) i['book_id']], ids);
        final tasks =
            state.outputs.tasks
                .where((t) => t.batchId == record['batch_id'])
                .toList()
              ..sort((a, b) => a.batchIndex!.compareTo(b.batchIndex!));
        expect(tasks.map((t) => t.bookId), ids);
        expect(tasks.every((t) => t.phase == 'complete'), true);
        return out;
      } finally {
        library.dispose();
        state.dispose();
      }
    }

    final serial = await runAll('1');
    final parallel = await runAll('4');
    evidence['serial'] = serial;
    evidence['parallel'] = parallel;
    expect(parallel['check_order'], serial['check_order']);
    // 同一本书的 EPUB 内容（除生成时间）逐字相同；AZW3 除嵌入的源 EPUB（SRCS）外各条记录逐字节相同。
    final serialEpub = serial['EPUB'] as List;
    final parallelEpub = parallel['EPUB'] as List;
    for (var i = 0; i < 6; i++) {
      expect(
        await members(parallelEpub[i] as String),
        await members(serialEpub[i] as String),
        reason: 'book ${i + 1}',
      );
      expect(
        azw3Records((parallel['AZW3'] as List)[i] as String),
        azw3Records((serial['AZW3'] as List)[i] as String),
        reason: 'AZW3 book ${i + 1}',
      );
    }
    File(
      '${root.path}/evidence.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
