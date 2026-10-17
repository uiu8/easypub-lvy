import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'frontend_rewrite_main.dart' as desktop;
import 'infrastructure/legacy_library_adapter.dart';
import 'prototype/prototype_state.dart';
import 'src/rust/frb_generated.dart';
import 'desk/catalog/paste_field.dart';
import 'desk/catalog/alignment_panel.dart';
import 'application/cleanup_service.dart';

/// Release-only developer probe; never interprets widget-test time as UI time.
Future<void> main() async {
  if (Platform.environment['EASYPUB_COMPLETION_PERF_REPORT']
      case final String path) {
    await completionPerformance(path);
    return;
  }
  final sourcePath = Platform.environment['EASYPUB_REWRITE_PERF_SOURCE'];
  final reportPath = Platform.environment['EASYPUB_REWRITE_PERF_REPORT'];
  if (sourcePath == null || reportPath == null) {
    await desktop.main();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{
    'recorded_at': DateTime.now().toIso8601String(),
    'scope': 'Release Flutter engine + actual DLL; bounded structure/body queries, no rendered frames',
    'input_path': sourcePath,
    'input_bytes': await File(sourcePath).length(),
    'rss_before_init': ProcessInfo.currentRss,
    'samples_per_operation': 20,
    'frames_measured': false,
    'performance_gate_passed': false,
  };
  final state = PrototypeState();
  state.shelf.books.clear();
  state.shelf.selected.clear();
  state.currentId = '';
  final library = LegacyLibraryAdapter(backend: state);
  try {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final timer = Stopwatch()..start();
    final imported = await library.importFiles([sourcePath]);
    report['import_ms'] = timer.elapsedMicroseconds / 1000;
    if (!imported.single.succeeded) throw StateError(imported.single.message);
    final id = library.books.value.single.id;
    final session = library.openChapters(id);
    final first = await session.read(0);
    report['nodes'] = first.total;
    report['rss_after_import'] = ProcessInfo.currentRss;
    final node = first.nodes.firstWhere((n) => n.role == 'chapter');
    final results = <String, Object?>{};
    Future<void> measure(String name, Future<int> Function(int) action) async {
      await action(0); // Warm-up is excluded and performed for each path.
      final values = <double>[];
      var maximumItems = 0;
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        final items = await action(i);
        values.add(watch.elapsedMicroseconds / 1000);
        if (items > maximumItems) maximumItems = items;
        if (items > 30) throw StateError('$name returned more than 30 items');
      }
      final sorted = [...values]..sort();
      results[name] = {
        'samples_ms': values,
        'p50_ms': sorted[9],
        'p95_ms': sorted[18],
        'max_ms': sorted.last,
        'max_items': maximumItems,
        'rss_after': ProcessInfo.currentRss,
      };
    }

    await measure(
      'existing_effective_tree',
      (i) async =>
          ((await state.manuscript.effectiveTree(id, (i * 30) % first.total))['nodes']
                  as List)
              .length,
    );
    await measure(
      'new_session_tree',
      (i) async => (await session.read((i * 30) % first.total)).nodes.length,
    );
    await measure(
      'new_session_body',
      (_) async => (await session.body(first, node.id, 0)).lines.length,
    );
    await measure(
      'new_session_volume_navigation',
      (_) async => (await session.volumes(first, 0)).nodes.length,
    );
    await measure('existing_page_then_body', (i) async {
      final offset = (i * 30) % first.total;
      final page = await state.manuscript.effectiveTree(id, offset);
      final nodeId = (page['nodes'] as List).first['entry_id'] as String;
      final content = await state.manuscript.effectiveTree(
        id,
        offset,
        previewNodeId: nodeId,
      );
      return ((content['body_preview'] as Map)['rows'] as List).length;
    });
    await measure('combined_page_and_body', (i) async {
      final page = await session.read(
        (i * 30) % first.total,
        includeBody: true,
      );
      if (page.bodyNodeId != page.nodes.first.id || page.body == null) {
        throw StateError('Combined query returned mismatched node/body');
      }
      return page.body!.lines.length;
    });
    report['operations'] = results;
    report['rss_final'] = ProcessInfo.currentRss;
    report['peak_rss'] = ProcessInfo.maxRss;
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

/// Runs the real text-input formatter and layout in a native engine, followed by
/// the production catalog and cleanup services. It does not simulate a clipboard.
Future<void> completionPerformance(String reportPath) async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(
      Platform.environment['EASYPUB_TEST_DLL']!,
    ),
  );
  final root = File(reportPath).parent;
  await root.create(recursive: true);
  final state = PrototypeState(settingsDirectory: '${root.path}/settings');
  final library = LegacyLibraryAdapter(backend: state);
  await library.load();
  await library.savePatch({'check_after_import': false});
  final useClipboard = Platform.environment['EASYPUB_PERF_CLIPBOARD'] == '1';
  final controller = TextEditingController();
  final rootKey = GlobalKey();
  final content = ValueNotifier<Widget>(
    CatalogPasteField(controller: controller, enabled: true, onChanged: () {}),
  );
  runApp(
    MaterialApp(
      home: Scaffold(
        key: rootKey,
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<Widget>(
            valueListenable: content,
            builder: (_, child, _) => child,
          ),
        ),
      ),
    ),
  );
  await SchedulerBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(milliseconds: 500));
  late EditableTextState editor;
  void visit(Element element) {
    if (element is StatefulElement && element.state is EditableTextState) {
      editor = element.state as EditableTextState;
    }
    element.visitChildren(visit);
  }

  visit(rootKey.currentContext! as Element);
  final results = <Map<String, Object?>>[];
  final pulseWatch = Stopwatch()..start();
  var lastPulse = 0, maximumGap = 0;
  final pulse = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = pulseWatch.elapsedMicroseconds;
    final gap = now - lastPulse;
    if (gap > maximumGap) maximumGap = gap;
    lastPulse = now;
  });
  void resetPulse() {
    maximumGap = 0;
    lastPulse = pulseWatch.elapsedMicroseconds;
  }

  for (final count in [3666, 10000, 30000]) {
    final input = List.generate(
      count,
      (i) => '第${i + 1}章 测量目录标题${i + 1}',
    ).join('\n');
    final source = File('${root.path}/catalog-$count.txt');
    await source.writeAsString(
      input.split('\n').map((title) => '$title\n正文。\n').join(),
    );
    final imported = await library.importFiles([source.path]);
    if (!imported.single.succeeded) throw StateError(imported.single.message);
    final catalog = library.openCatalog(
      library.books.value.firstWhere((b) => b.path == source.path).id,
    );
    for (var run = 0; run < 3; run++) {
      content.value = CatalogPasteField(
        controller: controller,
        enabled: true,
        onChanged: () {},
      );
      controller.clear();
      await SchedulerBinding.instance.endOfFrame;
      visit(rootKey.currentContext! as Element);
      if (useClipboard) {
        await Clipboard.setData(ClipboardData(text: input));
        // Clipboard history may briefly hold the native clipboard after a write.
        // Fixture preparation is excluded from the measured read/paste stage.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      resetPulse();
      final watch = Stopwatch()..start();
      final pasted = useClipboard
          ? (await Clipboard.getData(Clipboard.kTextPlain))!.text!
          : input;
      final clipboardUs = watch.elapsedMicroseconds;
      editor.updateEditingValue(
        TextEditingValue(
          text: pasted,
          selection: TextSelection.collapsed(offset: pasted.length),
        ),
      );
      final syncUs = watch.elapsedMicroseconds;
      await SchedulerBinding.instance.endOfFrame;
      final layoutUs = watch.elapsedMicroseconds;
      if (controller.text != input) throw StateError('Catalog input was lost');
      watch.reset();
      final snapshot = await catalog.acquire(
        'paste',
        input,
        declaredTotal: count,
      );
      if (snapshot.entries.length != count) {
        throw StateError('Catalog entries were lost');
      }
      final acquireUs = watch.elapsedMicroseconds;
      watch.reset();
      final alignment = await catalog.preview(
        snapshot,
        identityConfirmed: true,
      );
      final alignmentUs = watch.elapsedMicroseconds;
      if (alignment.matched != count || alignment.unresolved != 0) {
        throw StateError(
          'Alignment lost chapters: ${alignment.matched}/$count, unresolved ${alignment.unresolved}',
        );
      }
      watch.reset();
      content.value = CatalogAlignmentPanel(
        alignment: alignment,
        onReturn: () {},
        onChoose: (_, _) {},
        readEvidence: (row) => catalog.evidence(alignment, row),
        onComposition: () {},
      );
      await SchedulerBinding.instance.endOfFrame;
      final presentationUs = watch.elapsedMicroseconds;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      results.add({
        'phase': 'catalog',
        'entries': count,
        'run': run + 1,
        'system_clipboard': useClipboard,
        'clipboard_read_us': useClipboard ? clipboardUs : null,
        'input_sync_us': syncUs,
        'input_layout_us': layoutUs,
        'acquire_us': acquireUs,
        'alignment_us': alignmentUs,
        'presentation_us': presentationUs,
        'matched': alignment.matched,
        'source_path': source.path,
        'event_loop_max_gap_us': maximumGap,
        'rss': ProcessInfo.currentRss,
      });
    }
  }
  for (final lines
      in Platform.environment['EASYPUB_PERF_CATALOG_ONLY'] == '1'
          ? <int>[]
          : [64, 512, 8192]) {
    final file = File('${root.path}/cleanup-$lines.txt');
    await file.writeAsString('第一章 起\n${('${'正文' * 170}  \n') * lines}');
    final imported = await library.importFiles([file.path]);
    if (!imported.single.succeeded) throw StateError(imported.single.message);
    final id = library.books.value
        .firstWhere((book) => book.path == file.path)
        .id;
    for (var run = 0; run < 3; run++) {
      final cleanup = library.openCleanup(id);
      resetPulse();
      final watch = Stopwatch()..start();
      final request = jsonEncode({
        'kind': 'cleanup',
        'pipeline': [
          {'kind': 'trim_trailing_spaces'},
        ],
      });
      final preview = await cleanup.preview(request);
      final coldUs = watch.elapsedMicroseconds;
      watch.reset();
      final page = await cleanup.preview(request, offset: 40);
      await (cleanup as PairedCleanupContextSession).pairedContext(
        page,
        page.actions.first,
      );
      final contextUs = watch.elapsedMicroseconds;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      results.add({
        'phase': 'cleanup',
        'bytes': await file.length(),
        'run': run + 1,
        'preview_us': coldUs,
        'cached_context_us': contextUs,
        'event_loop_max_gap_us': maximumGap,
        'same_plan': preview.id == page.id,
        'rss': ProcessInfo.currentRss,
      });
      cleanup.dispose();
    }
  }
  pulse.cancel();
  await File(reportPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'scope': useClipboard
          ? 'Windows native profile; system clipboard read, actual input formatter/layout and DLL; not OS keyboard latency'
          : 'Windows native profile, real input formatting/layout and DLL services; no system clipboard or widget-test clock',
      'samples_per_size': 3,
      'physical_width': View.of(rootKey.currentContext!).physicalSize.width,
      'physical_height': View.of(rootKey.currentContext!).physicalSize.height,
      'device_pixel_ratio': View.of(rootKey.currentContext!).devicePixelRatio,
      'results': results,
      'peak_rss': ProcessInfo.maxRss,
    }),
  );
  library.dispose();
  state.dispose();
  exit(0);
}
