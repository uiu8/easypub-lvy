// Dedicated Release entrypoint: measures the generated Dart/FRB calls.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/rust/api.dart';
import 'src/rust/frb_generated.dart';
import 'source_coordinates.dart';

Future<int> verifyCoordinates(String root) async {
  const line = 'A中😀𠮷e\u0301';
  final file = File('$root/coordinates.txt');
  await file.writeAsString(line);
  final job = await startImport(path: file.path, ruleId: 'builtin-heading-v1');
  final status = await terminal(job);
  require(field(status, 'phase') == 'Completed', status);
  final coordinates = SourceCoordinates(line);
  var checked = 0;
  for (final offset in [0, 1, 2, 4, 6, 7]) {
    final response = await readSourcePageText(
      sourceId: field(status, 'source_id'),
      revision: 1,
      lineIndex: 0,
      utf8Column: coordinates.toUtf8(offset),
      limit: 1,
    );
    require(
      response.split('\n')[1] == '1: ${line.substring(offset)}',
      'Coordinate mismatch at $offset',
    );
    checked++;
  }
  return checked;
}

String field(String status, String key) => status
    .split(';')
    .firstWhere((part) => part.startsWith('$key='))
    .substring(key.length + 1);

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<String> terminal(int job) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    final status = await jobStatusText(jobId: job);
    if (['Completed', 'Failed', 'Cancelled'].contains(field(status, 'phase'))) {
      return status;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TimeoutException('Job $job did not stop');
}

Future<Map<String, Object>> measure(String path) async {
  final clock = Stopwatch()..start();
  final job = await startImport(path: path, ruleId: 'builtin-heading-v1');
  final status = await terminal(job);
  final importUs = clock.elapsedMicroseconds;
  require(field(status, 'phase') == 'Completed', status);
  require(field(status, 'chapters') == '10000', status);
  final source = field(status, 'source_id');
  final revision = int.parse(field(status, 'revision'));
  var maxResponse = 0;
  var responseBytes = 0;
  final latencies = <int>[];
  final lines = int.parse(field(status, 'lines'));
  clock.reset();
  for (var page = 0; page < 100; page++) {
    final requestClock = Stopwatch()..start();
    final text = await readSourcePageText(
      sourceId: source,
      revision: revision,
      lineIndex: (page * (lines - 200) ~/ 99),
      utf8Column: 0,
      limit: 200,
    );
    latencies.add(requestClock.elapsedMicroseconds);
    require(
      text.startsWith('source=$source revision=$revision '),
      'Wrong source',
    );
    final bytes = utf8.encode(text).length;
    require(bytes < 512 * 1024, 'Unbounded source response: $bytes');
    maxResponse = bytes > maxResponse ? bytes : maxResponse;
    responseBytes += bytes;
  }
  final pagesUs = clock.elapsedMicroseconds;
  clock.reset();
  var chapterCount = 0;
  for (var offset = 0; offset < 10000; offset += 200) {
    final text = await readChapterPageText(
      sourceId: source,
      revision: revision,
      offset: offset,
      limit: 200,
    );
    final entries = text
        .split('\n')
        .skip(1)
        .where((line) => line.isNotEmpty)
        .toList();
    require(entries.length == 200, 'Missing chapter page at $offset');
    for (var i = 0; i < entries.length; i++) {
      final expected = offset + i + 1;
      require(
        entries[i].contains(': 第$expected章 合成标题'),
        'Chapter order mismatch: ${entries[i]}',
      );
    }
    require(text.contains('total=10000 '), 'Wrong total');
    require(
      text.contains(
        offset == 9800 ? 'next=None' : 'next=Some(${offset + 200})',
      ),
      'Wrong next offset',
    );
    chapterCount += entries.length;
    final bytes = utf8.encode(text).length;
    require(bytes < 512 * 1024, 'Unbounded chapter response');
    maxResponse = bytes > maxResponse ? bytes : maxResponse;
  }
  final chapterUs = clock.elapsedMicroseconds;
  latencies.sort();
  return {
    'input_bytes': await File(path).length(),
    'import_ms': importUs / 1000,
    'source_id': source,
    'chapter_entries_verified': chapterCount,
    'source_requests': 100,
    'source_pages_ms': pagesUs / 1000,
    'source_latency_p50_ms': latencies[49] / 1000,
    'source_latency_p95_ms': latencies[94] / 1000,
    'source_response_bytes': responseBytes,
    'chapter_requests': 50,
    'all_chapters_ms': chapterUs / 1000,
    'max_response_bytes': maxResponse,
    'rss_after_case_bytes': ProcessInfo.currentRss,
    'peak_rss_process_bytes': ProcessInfo.maxRss,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = Platform.environment['EASYPUB_PERF_ROOT']!;
  final reportFile = File('$root/report.json');
  Map<String, Object?> report;
  try {
    await RustLib.init();
    final coordinateCases = await verifyCoordinates(root);
    final cases = <Map<String, Object>>[];
    for (final size in [20, 100]) {
      cases.add(await measure('$root/sample-$size.txt'));
    }
    final job = await startCancellationProbe();
    final clock = Stopwatch()..start();
    await cancelJobText(jobId: job);
    final cancelled = await terminal(job);
    require(field(cancelled, 'phase') == 'Cancelled', cancelled);
    report = {
      'passed': true,
      'recorded_at': DateTime.now().toIso8601String(),
      'scope': 'Windows Release Flutter engine, Dart generated FRB codec and Rust API; no rendered frame measurements',
      'cases': cases,
      'coordinate_bridge_cases': coordinateCases,
      'cancel_ms': clock.elapsedMicroseconds / 1000,
      'cancel_status': cancelled,
      'memory_scope':
          'whole process; second case includes retained first source snapshot',
    };
  } catch (error, stack) {
    report = {'passed': false, 'error': '$error', 'stack': '$stack'};
  }
  await reportFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    flush: true,
  );
  exit(report['passed'] == true ? 0 : 1);
}
