import 'dart:convert';

import 'infrastructure/import_profile.dart';

import 'dart:io';
import 'dart:math' show max;
import 'dart:ui' as ui;

import 'package:go_router/go_router.dart';

import 'desk/metadata/cover_preview.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:window_manager/window_manager.dart';

import 'application/plugin_host.dart';
import 'desk/app/rewrite_app.dart';
import 'desk/chapters/manuscript.dart';
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
// V83：拖动章节页目录与正文之间的分隔条。
final _divider = Platform.environment['EASYPUB_FRAME_TARGET'] == 'divider';
// V121：章节页排版视图（按真机规则画的正文）滚动。
final _layout = Platform.environment['EASYPUB_FRAME_TARGET'] == 'layout';
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
            : _layout
            ? element.findAncestorWidgetOfExactType<CustomScrollView>() !=
                      null &&
                  element.findAncestorWidgetOfExactType<ChapterManuscript>() !=
                      null
            : element.findAncestorWidgetOfExactType<ChapterOutline>() !=
                  null)) {
      result = (element.state as ScrollableState).position;
    }
    element.visitChildren(visit);
  }

  (_root.currentContext as Element?)?.visitChildren(visit);
  return result;
}

final _flutterErrors = <String>[];

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
            : _divider
            ? 'chapter divider drag (synthetic mouse events)'
            : _layout
            ? 'chapter layout view body'
            : 'chapter tree'} automated ${_divider ? 'drag' : 'scroll'}; no synthetic frame pump',
    'source': _source,
    'fixture': _data,
    if (_root.currentContext case final context?) ...{
      'physical_width': View.of(context).physicalSize.width,
      'physical_height': View.of(context).physicalSize.height,
      'device_pixel_ratio': View.of(context).devicePixelRatio,
    },
    'error': error,
    if (_flutterErrors.isNotEmpty) 'flutter_errors': _flutterErrors,
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
    'scroll_pattern': _divider
        ? '6 drags: 45 moves of 4px right then 45 left, one move per 16ms'
        : '10 forward then 10 backward; three viewports per 600ms',
    'frame_budget_ms': 16.667,
    'rss_before_init': _initialRss,
    'rss_before_scroll': _scrollStartRss,
    'rss_after_scroll': ProcessInfo.currentRss,
    'peak_rss_bytes': ProcessInfo.maxRss,
    'sample_completed':
        error == null &&
        _samples.length == (_divider ? 6 : 20) &&
        _frames.isNotEmpty,
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
  if (Platform.environment['EASYPUB_FRAME_TARGET'] == 'switch') {
    await _navigationSwitch();
    return;
  }
  if (Platform.environment['EASYPUB_FRAME_TARGET'] == 'library') {
    await _libraryScrollFilter();
    return;
  }
  if (Platform.environment['EASYPUB_FRAME_TARGET'] == 'booksource') {
    await _booksourcePage();
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
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => _divider
        ? _driveDivider()
        : _layout
        ? _openLayout().then((_) => _driveScroll())
        : _driveScroll(),
  );
}

/// 排版视图场景：等章节页出现后点“排版”，再等正文按真机规则画好。
Future<void> _openLayout() async {
  Element? mode;
  for (var i = 0; i < 150 && mode == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    void visit(Element element) {
      if (element.widget.key == const ValueKey('chapter-layout-mode')) {
        mode = element;
      }
      if (mode == null) element.visitChildren(visit);
    }

    (_root.currentContext as Element?)?.visitChildren(visit);
  }
  if (mode == null) throw StateError('No layout switch in target scene');
  Element? target;
  void find(Element element) {
    final w = element.widget;
    if (w is Text && w.data == '排版') target = element;
    if (target == null) element.visitChildren(find);
  }

  mode!.visitChildren(find);
  final box = target!.renderObject! as RenderBox;
  final center = box.localToGlobal(box.size.center(Offset.zero));
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(position: center, kind: PointerDeviceKind.mouse),
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(position: center, kind: PointerDeviceKind.mouse),
  );
  // 识别结果在后台算，排好再测。
  await Future<void>.delayed(const Duration(seconds: 4));
  _data['layout_view'] = true;
}

int _count<T extends Widget>() {
  var n = 0;
  void visit(Element element) {
    if (element.widget is T) n++;
    element.visitChildren(visit);
  }

  (_root.currentContext as Element?)?.visitChildren(visit);
  return n;
}

RenderBox? _dividerBox() {
  RenderBox? box;
  void visit(Element element) {
    if (element.widget.key == const ValueKey('chapter-tree-divider')) {
      box = element.renderObject as RenderBox?;
    }
    if (box == null) element.visitChildren(visit);
  }

  (_root.currentContext as Element?)?.visitChildren(visit);
  return box;
}

Future<void> _driveDivider() async {
  try {
    for (var i = 0; i < 150 && _dividerBox() == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_dividerBox() == null) {
      throw StateError('No chapter divider in target scene');
    }
    // 等正文排好。
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    // 每次都重新找分隔条：页面可能在拖动结束后重建。
    double x() => _dividerBox()!.localToGlobal(Offset.zero).dx;
    _frames.clear();
    _scrollStartRss = ProcessInfo.currentRss;
    _collecting = true;
    final clock = Stopwatch()..start();
    Duration now() => Duration(microseconds: clock.elapsedMicroseconds);
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (_flutterErrors.length < 5) {
        _flutterErrors.add(details.exceptionAsString());
      }
      previous?.call(details);
    };
    for (var round = 0; round < 6; round++) {
      final watch = Stopwatch()..start();
      final frameStart = _frames.length;
      final pointer = 900 + round, device = 40 + round;
      // 每轮从分隔条当前的中点按下。
      final bar = _dividerBox()!;
      var position = bar.localToGlobal(bar.size.center(Offset.zero));
      GestureBinding.instance.handlePointerEvent(
        PointerAddedEvent(
          timeStamp: now(),
          device: device,
          position: position,
          kind: PointerDeviceKind.mouse,
        ),
      );
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          timeStamp: now(),
          pointer: pointer,
          device: device,
          position: position,
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        ),
      );
      double? middle;
      for (var step = 0; step < 90; step++) {
        if (step == 45) {
          // 拖到最右时分隔条的实际位置：证明拖动真的生效。
          middle = x();
        }
        final dx = step < 45 ? 4.0 : -4.0;
        position += Offset(dx, 0);
        GestureBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            timeStamp: now(),
            pointer: pointer,
            device: device,
            position: position,
            delta: Offset(dx, 0),
            kind: PointerDeviceKind.mouse,
            buttons: kPrimaryMouseButton,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          timeStamp: now(),
          pointer: pointer,
          device: device,
          position: position,
          kind: PointerDeviceKind.mouse,
        ),
      );
      GestureBinding.instance.handlePointerEvent(
        PointerRemovedEvent(
          timeStamp: now(),
          device: device,
          position: position,
          kind: PointerDeviceKind.mouse,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _samples.add({
        'round': round + 1,
        'frames': _frames.length,
        'round_worst_total_ms': _frames
            .skip(frameStart)
            .fold<double>(
              0,
              (m, f) => max(m, f.totalSpan.inMicroseconds / 1000),
            ),
        'elapsed_ms': watch.elapsedMicroseconds / 1000,
        'rss_bytes': ProcessInfo.currentRss,
        'divider_end_x': x(),
        'divider_middle_x': ?middle,
        'reader_paragraphs': _count<RichText>(),
      });
    }
    FlutterError.onError = previous;
    _collecting = false;
    await _writeReport(null);
  } catch (error) {
    _collecting = false;
    await _writeReport(error.toString());
  }
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

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

/// 书库规模（R0）：EASYPUB_FRAME_BOOKS 取 40 / 300 / 1000，默认 40。
int get _bookCount {
  final n =
      int.tryParse(Platform.environment['EASYPUB_FRAME_BOOKS'] ?? '') ?? 40;
  if (n != 40 && n != 300 && n != 1000) {
    throw StateError('EASYPUB_FRAME_BOOKS must be 40, 300 or 1000');
  }
  return n;
}

/// 切页与书库场景共用：导入 [_bookCount] 本样本书（每本 30 章），有书源插件目录时启用插件，
/// 启动真实 RewriteApp 并等 3 秒稳定。
Future<(LegacyLibraryAdapter, GoRouter, bool, String, File, int)>
_switchFixture() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await _initBridge();
  SchedulerBinding.instance.addTimingsCallback((batch) {
    if (_collecting) _frames.addAll(batch);
  });
  final report = File(Platform.environment['EASYPUB_FRAME_REPORT']!);
  final root = report.parent;
  await root.create(recursive: true);
  final library = LegacyLibraryAdapter(
    settingsDirectory: '${root.path}/settings',
  );
  await library.load();
  await library.savePatch({'check_after_import': false});
  final sources = <String>[];
  for (var i = 0; i < _bookCount; i++) {
    final source = File('${root.path}/books/样本书-$i.txt');
    await source.parent.create(recursive: true);
    await source.writeAsString(
      [for (var c = 1; c <= 30; c++) '第$c章 标题$c\n样本正文$i-$c。\n'].join(),
    );
    sources.add(source.path);
  }
  final importWatch = Stopwatch()..start();
  for (var i = 0; i < sources.length; i += 100) {
    final imported = await library.importFiles(
      sources.sublist(i, (i + 100).clamp(0, sources.length)),
    );
    if (imported.any((r) => !r.succeeded)) throw StateError('import failed');
  }
  final importMs = importWatch.elapsedMilliseconds;
  if (ImportProfile.enabled) _data['import_totals'] = ImportProfile.snapshot();
  if (PluginRegistry.instance.find('booksource') != null) {
    await PluginRegistry.instance.setEnabled('booksource', true);
  }
  final plugin = PluginRegistry.instance.isActive('booksource');
  final id = library.books.value.first.id;
  library.selectBook(id);
  runApp(
    ProviderScope(
      child: RepaintBoundary(
        key: _root,
        child: RewriteApp(library: library, picker: NativeBookPicker()),
      ),
    ),
  );
  await SchedulerBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(seconds: 3));
  GoRouter? foundRouter;
  void findContext(Element element) {
    if (element.widget is Scaffold) foundRouter = GoRouter.of(element);
    element.visitChildren(findContext);
  }

  (_root.currentContext! as Element).visitChildren(findContext);
  return (library, foundRouter!, plugin, id, report, importMs);
}

Map<String, double> _frameStats() {
  final builds = _frames.map((f) => f.buildDuration.inMicroseconds / 1000);
  final rasters = _frames.map((f) => f.rasterDuration.inMicroseconds / 1000);
  return {
    'max_build_ms': builds.fold(0.0, max),
    'max_raster_ms': rasters.fold(0.0, max),
    'frames': _frames.length.toDouble(),
    'janky_frames': _frames
        .where((f) => f.totalSpan.inMicroseconds > 16667)
        .length
        .toDouble(),
  };
}

/// V94：侧栏切页耗时。导入 [_bookCount] 本书，在真实 RewriteApp 里按侧栏顺序切换页面 5 轮；
/// 每次记录从 go() 到首帧结束的时间，以及之后 600ms 内各帧的构建 / 光栅耗时。
/// 设置 EASYPUB_PLUGIN_DIR 指向带书源插件的目录时，同时启用插件并包含书源页。
Future<void> _navigationSwitch() async {
  final (_, router, plugin, id, report, importMs) = await _switchFixture();
  final book = Uri.encodeComponent(id);
  final routes = [
    '/',
    '/folders',
    if (plugin) '/plugins/booksource',
    '/books/$book/overview',
    '/books/$book/chapters',
    '/tasks',
    '/history',
    '/plugins',
    '/settings',
  ];
  final perRoute = <String, List<Map<String, double>>>{
    for (final r in routes) r: [],
  };
  for (var round = 0; round < 5; round++) {
    for (final route in routes) {
      _frames.clear();
      _collecting = true;
      final watch = Stopwatch()..start();
      router.go(route);
      await SchedulerBinding.instance.endOfFrame;
      final first = watch.elapsedMicroseconds / 1000;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _collecting = false;
      perRoute[route]!.add({'first_frame_ms': first, ..._frameStats()});
    }
  }
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schema': 'navigation-switch-v1',
      'scope':
          'Profile RewriteApp, $_bookCount imported books, 5 rounds of router.go over rail pages; first frame = go() to endOfFrame; frames within 600ms after.',
      'books': _bookCount,
      'import_ms': importMs,
      if (ImportProfile.enabled) 'import_profile': ImportProfile.rows,
      if (ImportProfile.enabled) 'import_totals': _data['import_totals'],
      'plugin_active': plugin,
      'physical_width': View.of(_root.currentContext!).physicalSize.width,
      'physical_height': View.of(_root.currentContext!).physicalSize.height,
      'dpr': View.of(_root.currentContext!).devicePixelRatio,
      'median': {
        for (final e in perRoute.entries)
          e.key: {
            for (final k in e.value.first.keys)
              k: _median([for (final s in e.value) s[k]!]),
          },
      },
      'samples': perRoute,
    }),
  );
  exit(0);
}

/// R8：书源页。脚本事先在插件数据目录写好 N 个假书源（不访问网络），这里：
/// 1) 打开书源下载页、切到“书源”页签，记录到首帧时间并等列表读完；
/// 2) 书源列表每 16ms 滚动 120 像素，先到底再回到顶，统计逐帧耗时；
/// 3) 在“搜索书源”框里逐字输入再逐字删掉，每次改动记录到首帧结束的时间。
Future<void> _booksourcePage() async {
  final (_, router, plugin, _, report, importMs) = await _switchFixture();
  if (!plugin) throw StateError('booksource plugin is not active');
  final sourceCount = int.parse(
    Platform.environment['EASYPUB_FRAME_SOURCES'] ?? '0',
  );
  T? find<T>(bool Function(Element e) test, T Function(Element e) pick) {
    T? found;
    void visit(Element element) {
      if (found != null) return;
      if (test(element)) {
        found = pick(element);
        return;
      }
      element.visitChildren(visit);
    }

    (_root.currentContext! as Element).visitChildren(visit);
    return found;
  }

  final openWatch = Stopwatch()..start();
  router.go('/plugins/booksource');
  await SchedulerBinding.instance.endOfFrame;
  final openMs = openWatch.elapsedMicroseconds / 1000;
  await Future<void>.delayed(const Duration(seconds: 2));
  final tab = find<InkWell>(
    (e) => e.widget.key == const ValueKey('booksource-tab-sources'),
    (e) => e.widget as InkWell,
  );
  if (tab == null) throw StateError('No sources tab');
  _frames.clear();
  _collecting = true;
  final tabWatch = Stopwatch()..start();
  tab.onTap!();
  await SchedulerBinding.instance.endOfFrame;
  final tabMs = tabWatch.elapsedMicroseconds / 1000;
  await Future<void>.delayed(const Duration(milliseconds: 600));
  _collecting = false;
  final tabFrames = _frameStats();
  // 等书源读完（标签上显示“书源 a/N”）。
  final loadWatch = Stopwatch()..start();
  while (find<Text>(
        (e) =>
            e.widget is Text &&
            ((e.widget as Text).data ?? '').endsWith('/$sourceCount'),
        (e) => e.widget as Text,
      ) ==
      null) {
    if (loadWatch.elapsed > const Duration(seconds: 60)) {
      throw StateError('sources not loaded');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final loadMs = loadWatch.elapsedMilliseconds + tabMs;
  await Future<void>.delayed(const Duration(seconds: 1));
  ScrollPosition? list;
  void visitLists(Element element) {
    if (element is StatefulElement) {
      final state = element.state;
      if (state is ScrollableState &&
          state.position.axis == Axis.vertical &&
          state.position.maxScrollExtent > (list?.maxScrollExtent ?? -1)) {
        list = state.position;
      }
    }
    element.visitChildren(visitLists);
  }

  (_root.currentContext! as Element).visitChildren(visitLists);
  if (list == null) throw StateError('No source list');
  final position = list!;
  _frames.clear();
  _collecting = true;
  var steps = 0;
  for (var direction = 1; direction >= -1; direction -= 2) {
    for (var i = 0; i < 400; i++) {
      final target = (position.pixels + 120 * direction).clamp(
        0.0,
        position.maxScrollExtent,
      );
      if (target == position.pixels) break;
      position.jumpTo(target);
      steps++;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  _collecting = false;
  final scroll = <String, double>{
    'steps': steps.toDouble(),
    'max_scroll_extent': position.maxScrollExtent,
    ..._frameStats(),
    'build_p95_ms': _percentile(
      _frames.map((f) => f.buildDuration.inMicroseconds).toList(),
      .95,
    ),
    'total_p95_ms': _percentile(
      _frames.map((f) => f.totalSpan.inMicroseconds).toList(),
      .95,
    ),
  };
  final search = find<EditableTextState>(
    (e) =>
        e is StatefulElement &&
        e.state is EditableTextState &&
        e.findAncestorWidgetOfExactType<TextField>()?.key ==
            const ValueKey('booksource-filter'),
    (e) => (e as StatefulElement).state as EditableTextState,
  );
  if (search == null) throw StateError('No source filter');
  const word = '合成书源12';
  final typing = <double>[];
  _frames.clear();
  _collecting = true;
  for (final text in [
    for (var i = 1; i <= word.length; i++) word.substring(0, i),
    for (var i = word.length - 1; i >= 0; i--) word.substring(0, i),
  ]) {
    final watch = Stopwatch()..start();
    search.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await SchedulerBinding.instance.endOfFrame;
    typing.add(watch.elapsedMicroseconds / 1000);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  _collecting = false;
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schema': 'booksource-page-v1',
      'scope':
          'Profile RewriteApp book source page with $sourceCount fake sources (no network); open page, switch to sources tab, scroll 120px per 16ms down then up, type and delete a query one character at a time.',
      'sources': sourceCount,
      'books': _bookCount,
      'import_ms': importMs,
      'open_first_frame_ms': openMs,
      'tab_first_frame_ms': tabMs,
      'tab_frames': tabFrames,
      'sources_loaded_ms': loadMs,
      'physical_width': View.of(_root.currentContext!).physicalSize.width,
      'physical_height': View.of(_root.currentContext!).physicalSize.height,
      'scroll': scroll,
      'filter': {
        'keystrokes': typing.length,
        'first_frame_median_ms': _median(typing),
        'first_frame_max_ms': typing.fold(0.0, max),
        ..._frameStats(),
      },
    }),
  );
  exit(0);
}

/// R0：书库滚动与筛选。导入 [_bookCount] 本书，在书库页：
/// 1) 书架列表每 16ms 滚动 120 像素，先到底再回到顶（每个方向最多 200 步），统计逐帧耗时；
/// 2) 在搜索框里逐字输入“样本书-1”再逐字删掉，每次改动记录到首帧结束的时间。
Future<void> _libraryScrollFilter() async {
  final (_, _, plugin, _, report, importMs) = await _switchFixture();
  ScrollPosition? shelf;
  EditableTextState? search;
  void visit(Element element) {
    if (element is StatefulElement) {
      final state = element.state;
      if (state is ScrollableState &&
          state.position.axis == Axis.vertical &&
          state.position.maxScrollExtent > (shelf?.maxScrollExtent ?? -1)) {
        shelf = state.position;
      }
      if (state is EditableTextState &&
          search == null &&
          (element
                      .findAncestorWidgetOfExactType<TextField>()
                      ?.decoration
                      ?.hintText ??
                  '')
              .contains('搜索书名')) {
        search = state;
      }
    }
    element.visitChildren(visit);
  }

  (_root.currentContext! as Element).visitChildren(visit);
  if (shelf == null || search == null) {
    throw StateError('No library shelf or search field');
  }
  final position = shelf!;
  _frames.clear();
  _collecting = true;
  var steps = 0;
  for (var direction = 1; direction >= -1; direction -= 2) {
    for (var i = 0; i < 200; i++) {
      final target = (position.pixels + 120 * direction).clamp(
        0.0,
        position.maxScrollExtent,
      );
      if (target == position.pixels) break;
      position.jumpTo(target);
      steps++;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  _collecting = false;
  final scroll = <String, double>{
    'steps': steps.toDouble(),
    'max_scroll_extent': position.maxScrollExtent,
    ..._frameStats(),
    'build_p95_ms': _percentile(
      _frames.map((f) => f.buildDuration.inMicroseconds).toList(),
      .95,
    ),
    'total_p95_ms': _percentile(
      _frames.map((f) => f.totalSpan.inMicroseconds).toList(),
      .95,
    ),
  };
  const word = '样本书-1';
  final typing = <double>[];
  _frames.clear();
  _collecting = true;
  for (final text in [
    for (var i = 1; i <= word.length; i++) word.substring(0, i),
    for (var i = word.length - 1; i >= 0; i--) word.substring(0, i),
  ]) {
    final watch = Stopwatch()..start();
    search!.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await SchedulerBinding.instance.endOfFrame;
    typing.add(watch.elapsedMicroseconds / 1000);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  _collecting = false;
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schema': 'library-scroll-filter-v1',
      'scope':
          'Profile RewriteApp library page, $_bookCount imported books; scroll 120px per 16ms down then up; type and delete a 5-character query one character at a time.',
      'books': _bookCount,
      'import_ms': importMs,
      if (ImportProfile.enabled) 'import_profile': ImportProfile.rows,
      if (ImportProfile.enabled) 'import_totals': _data['import_totals'],
      'plugin_active': plugin,
      'physical_width': View.of(_root.currentContext!).physicalSize.width,
      'physical_height': View.of(_root.currentContext!).physicalSize.height,
      'scroll': scroll,
      'filter': {
        'keystrokes': typing.length,
        'first_frame_median_ms': _median(typing),
        'first_frame_max_ms': typing.fold(0.0, max),
        ..._frameStats(),
      },
    }),
  );
  exit(0);
}
