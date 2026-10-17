import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:go_router/go_router.dart';

import 'desk/metadata/cover_preview.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:window_manager/window_manager.dart';

import 'desk/app/rewrite_app.dart';
import 'desk/chapters/outline.dart';
import 'infrastructure/legacy_library_adapter.dart';
import 'infrastructure/native_book_picker.dart';
import 'src/rust/frb_generated.dart';

var _collecting = false;
final _frames = <FrameTiming>[];
final _scrollController = ScrollController();
final _root = GlobalKey();
final _source = Platform.environment['EASYPUB_FRAME_SOURCE'];
final _samples = <Map<String, Object>>[];
final _issues = Platform.environment['EASYPUB_FRAME_TARGET'] == 'issues';
final _data = <String, Object?>{};
final _initialRss = ProcessInfo.currentRss;
int? _scrollStartRss;

Future<void> _initBridge() => RustLib.init(
  externalLibrary: switch (Platform.environment['EASYPUB_TEST_DLL']) {
    final String path => ExternalLibrary.open(path),
    _ => null,
  },
);

// Developer-only profile entrypoint. Production entrypoint is unchanged.
double _percentile(List<int> values, double percentile) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * percentile).round()] / 1000.0;
}

ScrollPosition? _position() {
  if (_source == null) {
    return _scrollController.hasClients ? _scrollController.position : null;
  }
  ScrollPosition? result;
  void visit(Element element) {
    if (element is StatefulElement &&
        element.state is ScrollableState &&
        (_issues
            ? element.findAncestorWidgetOfExactType<ListView>()?.key ==
                  const ValueKey('check-issue-list')
            : element.findAncestorWidgetOfExactType<ChapterOutline>() !=
                  null)) {
      result = (element.state as ScrollableState).position;
    }
    element.visitChildren(visit);
  }

  (_root.currentContext as Element?)?.visitChildren(visit);
  return result;
}

Future<void> _writeReport(String? error) async {
  final builds = _frames.map((f) => f.buildDuration.inMicroseconds).toList();
  final rasters = _frames.map((f) => f.rasterDuration.inMicroseconds).toList();
  final totals = _frames.map((f) => f.totalSpan.inMicroseconds).toList();
  final report = <String, Object?>{
    'schema': 'frontend-frame-perf-v3',
    'generated_at': DateTime.now().toIso8601String(),
    'scope':
        'Profile RewriteApp ${_source == null
            ? 'settings'
            : _issues
            ? 'issue browser'
            : 'chapter tree'} automated scroll; no synthetic frame pump',
    'source': _source,
    'fixture': _data,
    if (_root.currentContext case final context?) ...{
      'physical_width': View.of(context).physicalSize.width,
      'physical_height': View.of(context).physicalSize.height,
      'device_pixel_ratio': View.of(context).devicePixelRatio,
    },
    'error': error,
    'frame_count': _frames.length,
    'build_p50_ms': _percentile(builds, .50),
    'build_p95_ms': _percentile(builds, .95),
    'build_p99_ms': _percentile(builds, .99),
    'raster_p95_ms': _percentile(rasters, .95),
    'raster_p50_ms': _percentile(rasters, .50),
    'raster_p99_ms': _percentile(rasters, .99),
    'total_p95_ms': _percentile(totals, .95),
    'total_p50_ms': _percentile(totals, .50),
    'total_p99_ms': _percentile(totals, .99),
    'missed_frame_ratio':
        totals.where((v) => v > 16667).length /
        (_frames.isEmpty ? 1 : _frames.length),
    'scroll_samples': _samples,
    'scroll_pattern': '10 forward then 10 backward; three viewports per 600ms',
    'frame_budget_ms': 16.667,
    'rss_before_init': _initialRss,
    'rss_before_scroll': _scrollStartRss,
    'rss_after_scroll': ProcessInfo.currentRss,
    'peak_rss_bytes': ProcessInfo.maxRss,
    'sample_completed':
        error == null && _samples.length == 20 && _frames.isNotEmpty,
    'performance_gate_passed': false,
    'gate_note': 'One scenario and one machine; not complete performance or desktop interaction acceptance.',
  };
  final file = File(
    Platform.environment['EASYPUB_FRAME_REPORT'] ??
        'build/frontend-frame-perf.json',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  exit(error == null ? 0 : 1);
}

Future<void> main() async {
  if (Platform.environment['EASYPUB_FRAME_TARGET'] == 'navigation') {
    await _navigationCovers();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  await _initBridge();
  SchedulerBinding.instance.addTimingsCallback((batch) {
    if (_collecting) _frames.addAll(batch);
  });
  final library = LegacyLibraryAdapter(
    settingsDirectory:
        '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}/EasyPub-RustFlutter/settings',
  );
  var route = '/settings';
  if (_source != null) {
    await library.load();
    await library.savePatch({'check_after_import': false});
    final imported = await library.importFiles([_source!]);
    if (!imported.single.succeeded) {
      await _writeReport(imported.single.message);
      return;
    }
    final id = library.books.value.single.id;
    _data['rss_after_import'] = ProcessInfo.currentRss;
    route =
        '/books/${Uri.encodeComponent(id)}/${_issues ? 'checks' : 'chapters'}';
    if (_issues) {
      final session = library.openChapters(id);
      final tree = await session.read(0);
      final first = await session.issues(tree, 0, effective: true);
      if (first.total < 1000) {
        throw StateError('Fixture must contain at least 1000 actual issues');
      }
      final pageCounts = <int>[];
      for (final offset in [
        0,
        (first.total ~/ 100) * 50,
        ((first.total - 1) ~/ 50) * 50,
      ]) {
        final page = await session.issues(tree, offset, effective: true);
        if (page.items.length > 50 || page.total != first.total) {
          throw StateError('Issue page is unbounded or inconsistent');
        }
        pageCounts.add(page.items.length);
      }
      _data.addAll({
        'nodes': tree.total,
        'issue_total': first.total,
        'first_middle_last_page_counts': pageCounts,
      });
    }
  }
  runApp(
    ProviderScope(
      child: RepaintBoundary(
        key: _root,
        child: RewriteApp(
          library: library,
          picker: NativeBookPicker(),
          initialLocation: route,
          performanceScrollController: _scrollController,
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => _driveScroll());
}

Future<void> _driveScroll() async {
  try {
    ScrollPosition? position;
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      position = _position();
      if (position != null &&
          position.hasContentDimensions &&
          position.maxScrollExtent > 0) {
        break;
      }
    }
    if (position == null ||
        !position.hasContentDimensions ||
        position.maxScrollExtent <= 0) {
      throw StateError('No scrollable content in target scene');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _frames.clear();
    _scrollStartRss = ProcessInfo.currentRss;
    _collecting = true;
    for (var index = 0; index < 20; index++) {
      final current = _position() ?? position;
      final target =
          (current.pixels +
                  current.viewportDimension * 3 * (index < 10 ? 1 : -1))
              .clamp(current.minScrollExtent, current.maxScrollExtent);
      final watch = Stopwatch()..start();
      await current.animateTo(
        target,
        duration: const Duration(milliseconds: 600),
        curve: Curves.linear,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _samples.add({
        'round': index + 1,
        'offset': current.pixels,
        'extent': current.maxScrollExtent,
        'rss_bytes': ProcessInfo.currentRss,
        'frames': _frames.length,
        'elapsed_ms': watch.elapsedMicroseconds / 1000,
        'viewport': current.viewportDimension,
        'direction': index < 10 ? 'forward' : 'backward',
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _collecting = false;
    await _writeReport(null);
  } catch (error) {
    _collecting = false;
    await _writeReport(error.toString());
  }
}

// Exercises real route disposal and image providers, without forcing GC.
Future<void> _navigationCovers() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await _initBridge();
  final report = File(Platform.environment['EASYPUB_FRAME_REPORT']!);
  final root = report.parent;
  await root.create(recursive: true);
  final library = LegacyLibraryAdapter(
    settingsDirectory: '${root.path}/settings',
  );
  await library.load();
  await library.savePatch({'check_after_import': false});
  for (var i = 0; i < 2; i++) {
    final source = File('${root.path}/book-$i.txt');
    await source.writeAsString('第一章 开始\n样本正文$i。\n第二章 继续\n结束。\n');
    final imported = await library.importFiles([source.path]);
    if (!imported.single.succeeded) throw StateError(imported.single.message);
  }
  final covers = <String>[];
  for (var i = 0; i < 4; i++) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1200, 1600),
      Paint()
        ..color = [Colors.red, Colors.blue, Colors.green, Colors.orange][i],
    );
    canvas.drawRect(
      Rect.fromLTWH(100.0 + i * 100, 100, 600, 1200),
      Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    final bitmap = await picture.toImage(1200, 1600);
    picture.dispose();
    final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    bitmap.dispose();
    final file = File('${root.path}/cover-$i.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    covers.add(file.path);
  }
  runApp(
    ProviderScope(
      child: RepaintBoundary(
        key: _root,
        child: RewriteApp(library: library, picker: NativeBookPicker()),
      ),
    ),
  );
  await SchedulerBinding.instance.endOfFrame;
  GoRouter? foundRouter;
  void findContext(Element element) {
    if (element.widget is Scaffold) foundRouter = GoRouter.of(element);
    element.visitChildren(findContext);
  }

  (_root.currentContext! as Element).visitChildren(findContext);
  final router = foundRouter!;
  final ids = library.books.value.map((b) => b.id).toList();
  final samples = <Map<String, Object?>>[];
  for (var round = 0; round < 20; round++) {
    final id = ids[round % 2];
    library.selectBook(id);
    final information = library.openBookInformation(id);
    await information.apply(
      await information.preview({
        'cover_path': covers[round % 4],
        'cover_fit': round.isEven ? 'contain' : 'cover',
      }),
    );
    information.dispose();
    final routes = [
      '/',
      '/books/${Uri.encodeComponent(id)}/overview',
      '/books/${Uri.encodeComponent(id)}/information',
      '/books/${Uri.encodeComponent(id)}/chapters',
      '/books/${Uri.encodeComponent(id)}/resources',
      '/books/${Uri.encodeComponent(id)}/layout',
      '/books/${Uri.encodeComponent(id)}/cleanup',
      '/books/${Uri.encodeComponent(id)}/checks',
      '/books/${Uri.encodeComponent(id)}/catalog',
      '/books/${Uri.encodeComponent(id)}/repairs',
      '/folders',
      '/settings',
      '/conversion',
      '/tasks',
      '/tasks/history',
      '/history',
    ];
    for (final route in routes) {
      router.go(route);
      await SchedulerBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (router.routeInformationProvider.value.uri.path !=
          Uri.parse(route).path) {
        throw StateError('Navigation was blocked: $route');
      }
    }
    router.go('/');
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    var mountedCovers = 0;
    void count(Element element) {
      if (element.widget is CoverPreview) mountedCovers++;
      element.visitChildren(count);
    }

    (_root.currentContext! as Element).visitChildren(count);
    final cache = PaintingBinding.instance.imageCache;
    samples.add({
      'round': round + 1,
      'book_id': id,
      'cover_path': covers[round % 4],
      'rss_bytes': ProcessInfo.currentRss,
      'cache_bytes': cache.currentSizeBytes,
      'cache_entries': cache.currentSize,
      'live_images': cache.liveImageCount,
      'pending_images': cache.pendingImageCount,
      'mounted_covers': mountedCovers,
      'visited_routes': routes,
    });
  }
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'scope': 'Profile real RewriteApp routes, production cover apply/image providers, 20 rounds, no forced GC',
      'samples': samples,
      'physical_width': View.of(_root.currentContext!).physicalSize.width,
      'physical_height': View.of(_root.currentContext!).physicalSize.height,
      'dpr': View.of(_root.currentContext!).devicePixelRatio,
      'image_cache_limit_bytes':
          PaintingBinding.instance.imageCache.maximumSizeBytes,
    }),
  );
  exit(0);
}
