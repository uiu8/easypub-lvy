// 文件夹自动入库（V26，FOLD-080–082）：开启“自动入库”的文件夹里新出现的书自动导入书库。
// · 何时同步：书库载入后、窗口回到前台时、运行中监听到文件夹有变化（停 2 秒后合并为一次）；
// · 只导入书库里还没有的书；用户从书库移除过的文件记入忽略列表，不再自动导入；
// · 文件夹里的原稿被删除或移走时，书库只标记“原稿缺失”，不删书；
// · 有导入、项目切换等工作在进行时推迟，稍后重试。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'library_service.dart';

/// 书库对界面提供的自动入库能力（LegacyLibraryAdapter 实现）。
abstract interface class FolderAutoImportService {
  ValueListenable<List<String>> get autoImportFolders;
  ValueListenable<AutoImportState> get autoImportState;
  Future<bool> setAutoImport(String folder, bool enabled);

  /// 立即同步一次（窗口回到前台时由界面调用）。
  Future<void> syncAutoImport();

  /// 书库看过“新增”角标后清零。
  void acknowledgeAutoImport();
}

@immutable
class AutoImportState {
  const AutoImportState({
    this.added = const [],
    this.missing = const {},
    this.running = false,
    this.message = '',
    this.lastRun,
  });

  /// 自上次清零以来自动导入的书名。
  final List<String> added;

  /// 位于自动入库文件夹、原稿文件已不在的书（书库 id）。
  final Set<String> missing;
  final bool running;
  final String message;
  final DateTime? lastRun;

  AutoImportState copyWith({
    List<String>? added,
    Set<String>? missing,
    bool? running,
    String? message,
    DateTime? lastRun,
  }) => AutoImportState(
    added: added ?? this.added,
    missing: missing ?? this.missing,
    running: running ?? this.running,
    message: message ?? this.message,
    lastRun: lastRun ?? this.lastRun,
  );
}

String _norm(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

/// [path] 是否在 [folder] 之内（含子文件夹；Windows 路径不分大小写）。
bool pathInside(String path, String folder) {
  final p = _norm(path), f = _norm(folder);
  return p.startsWith('$f/');
}

/// 一次同步的结果（测试与状态说明用）。
class AutoImportRun {
  const AutoImportRun(
    this.imported,
    this.failed,
    this.missing, {
    this.deferred = false,
  });
  final List<ImportOutcome> imported;
  final List<ImportOutcome> failed;
  final Set<String> missing;
  final bool deferred;
}

/// 自动入库的执行部分：不依赖界面，扫描与导入通过书库服务完成。
class FolderAutoImporter {
  FolderAutoImporter({
    required this.library,
    required this.folders,
    required this.ignored,
    required this.recursive,
    required this.busy,
    this.debounce = const Duration(seconds: 2),
    this.retry = const Duration(seconds: 10),
    this.watch = true,
  });

  final LibraryService library;

  /// 当前开启自动入库的文件夹与忽略列表（每次同步时读取，设置改了立即生效）。
  final List<String> Function() folders;
  final Set<String> Function() ignored;
  final bool Function() recursive;

  /// 书库正在导入、切换项目等时返回 true，本次推迟。
  final bool Function() busy;
  final Duration debounce, retry;
  final bool watch;

  final state = ValueNotifier(const AutoImportState());
  final _subscriptions = <String, StreamSubscription<FileSystemEvent>>{};
  Timer? _timer;
  bool _disposed = false;
  Future<AutoImportRun>? _running;
  bool _again = false;

  /// 按当前文件夹列表重建监听，并立即同步一次。
  Future<AutoImportRun> start() {
    _rewatch();
    return sync();
  }

  void _rewatch() {
    final wanted = {for (final f in folders()) _norm(f): f};
    for (final key in _subscriptions.keys.toList()) {
      if (!wanted.containsKey(key)) _subscriptions.remove(key)!.cancel();
    }
    if (!watch) return;
    for (final MapEntry(key: key, value: folder) in wanted.entries) {
      if (_subscriptions.containsKey(key)) continue;
      final directory = Directory(folder);
      if (!directory.existsSync()) continue;
      try {
        _subscriptions[key] = directory
            .watch(recursive: recursive())
            .listen((_) => schedule(), onError: (_) {});
      } on FileSystemException {
        // 监听不可用（网络盘等）时，仍在启动与回到前台时同步。
      }
    }
  }

  /// 合并短时间内的多次变化，停 [debounce] 后同步一次。
  void schedule([Duration? after]) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(after ?? debounce, () => sync());
  }

  /// 同步一次；正在同步时，结束后再补一次。
  Future<AutoImportRun> sync() {
    if (_disposed) {
      return Future.value(const AutoImportRun([], [], {}, deferred: true));
    }
    final current = _running;
    if (current != null) {
      _again = true;
      return current;
    }
    final run = _sync();
    _running = run;
    return run.whenComplete(() {
      _running = null;
      if (_again && !_disposed) {
        _again = false;
        schedule(Duration.zero);
      }
    });
  }

  Future<AutoImportRun> _sync() async {
    final list = folders();
    if (list.isEmpty) {
      state.value = state.value.copyWith(missing: const {}, message: '');
      return const AutoImportRun([], [], {});
    }
    if (busy()) {
      schedule(retry);
      return const AutoImportRun([], [], {}, deferred: true);
    }
    state.value = state.value.copyWith(running: true, message: '正在检查自动入库文件夹…');
    final skip = {for (final p in ignored()) _norm(p)};
    final candidates = <String>[];
    final problems = <String>[];
    for (final folder in list) {
      if (_disposed) break;
      if (!Directory(folder).existsSync()) {
        problems.add('文件夹不在：$folder');
        continue;
      }
      FolderListing? listing;
      try {
        listing = await library.scanFolder(
          folder,
          recursive: recursive(),
          cancelled: () => _disposed,
        );
        for (final book in listing.books) {
          if (!book.alreadyImported && !skip.contains(_norm(book.path))) {
            candidates.add(book.path);
          }
        }
      } catch (_) {
        problems.add('扫描失败：$folder');
      } finally {
        listing?.close?.call();
      }
    }
    var imported = <ImportOutcome>[], failed = <ImportOutcome>[];
    if (candidates.isNotEmpty && !_disposed && !busy()) {
      final outcomes = await library.importFiles(
        candidates,
        skipExisting: true,
      );
      imported = outcomes.where((o) => o.succeeded && !o.skipped).toList();
      failed = outcomes.where((o) => !o.succeeded).toList();
    }
    if (_disposed) return const AutoImportRun([], [], {}, deferred: true);
    final missing = <String>{
      for (final book in library.books.value)
        if (list.any((f) => pathInside(book.path, f)) &&
            !File(book.path).existsSync())
          book.id,
    };
    final titles = <String>[
      ...state.value.added,
      for (final o in imported) o.path.replaceAll('\\', '/').split('/').last,
    ];
    state.value = AutoImportState(
      added: titles,
      missing: missing,
      running: false,
      lastRun: DateTime.now(),
      message: [
        if (imported.isNotEmpty) '自动导入 ${imported.length} 本',
        if (failed.isNotEmpty) '${failed.length} 本导入失败',
        if (missing.isNotEmpty) '${missing.length} 本原稿缺失',
        ...problems,
      ].join(' · '),
    );
    return AutoImportRun(imported, failed, missing);
  }

  void acknowledge() {
    if (state.value.added.isEmpty) return;
    state.value = state.value.copyWith(added: const []);
  }

  /// 文件夹列表改变后调用：重建监听并同步。
  Future<AutoImportRun> foldersChanged() => start();

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final s in _subscriptions.values) {
      s.cancel();
    }
    _subscriptions.clear();
    state.dispose();
  }
}
