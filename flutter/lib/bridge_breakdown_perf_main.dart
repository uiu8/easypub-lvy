// 桥接第 2 批测速入口（只用于测量，Release 构建）：大书各热点调用拆成
// 跨桥耗时（含 Rust 计算）、返回字节数、Dart 解码耗时三部分。
// 环境变量：EASYPUB_BRIDGE_PERF_SOURCE（TXT）、EASYPUB_BRIDGE_PERF_REPORT（JSON 报告）、
// EASYPUB_TEST_DLL（桥接 DLL）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'bridge_breakdown_ops.dart';
import 'infrastructure/legacy_library_adapter.dart';
import 'prototype/prototype_state.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sourcePath = env['EASYPUB_BRIDGE_PERF_SOURCE']!;
  final reportPath = env['EASYPUB_BRIDGE_PERF_REPORT']!;
  final report = <String, Object?>{
    'recorded_at': DateTime.now().toIso8601String(),
    'input_path': sourcePath,
    'input_bytes': await File(sourcePath).length(),
    'samples_per_operation': 20,
  };
  final state = PrototypeState();
  state.shelf.books.clear();
  state.shelf.selected.clear();
  state.currentId = '';
  final library = LegacyLibraryAdapter(backend: state);
  try {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(env['EASYPUB_TEST_DLL']!),
    );
    final timer = Stopwatch()..start();
    final imported = await library.importFiles([sourcePath]);
    report['import_ms'] = timer.elapsedMicroseconds / 1000;
    if (!imported.single.succeeded) throw StateError(imported.single.message);
    final id = library.books.value.single.id;
    final book = state.shelf.books.firstWhere((b) => b.id == id);
    report['operations'] = await measureBridgeOperations(
      state,
      id,
      book.source!.sourceId,
      book.source!.revision,
    );
    report['probe_completed'] = true;
  } catch (e, stack) {
    report['probe_completed'] = false;
    report['error'] = '$e';
    report['stack'] = '$stack';
  } finally {
    library.dispose();
    state.dispose();
  }
  await File(reportPath).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    flush: true,
  );
  exit(report['probe_completed'] == true ? 0 : 1);
}
