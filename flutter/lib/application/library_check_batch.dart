import 'package:flutter/foundation.dart';

import 'book_check_service.dart';
import 'parallel_books.dart';

class LibraryCheckResult {
  const LibraryCheckResult(this.id, this.title, this.message, this.failed);
  final String id, title, message;
  final bool failed;
}

/// Library-owned read-only batch. Selection is captured by the caller.
class LibraryCheckBatch extends ChangeNotifier {
  bool running = false, stopping = false, cancelled = false;
  bool _disposed = false;
  int total = 0;
  String currentTitle = '';

  /// 正在检查的书（V38 起可以同时几本）；关闭时全部取消。
  final Set<BookCheckSession> _active = {};
  final List<String> _runningTitles = [];
  void reset() {
    if (running) return;
    total = 0;
    _results = [];
    cancelled = false;
    _publish();
  }

  /// 结果按所选书的顺序；还没检查完的位置为空。
  List<LibraryCheckResult?> _results = [];
  List<LibraryCheckResult> get results =>
      List.unmodifiable(_results.whereType<LibraryCheckResult>());
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void stop() {
    if (!running || stopping) return;
    stopping = true;
    _publish();
  }

  /// [parallel] 为同时检查的本数（V38，LIB-115）；1 与原来的逐本检查相同。
  /// “停止”后不再开始新的书，正在检查的几本完成后结束。
  Future<void> run(
    List<(String, String)> books,
    BookCheckSession Function(String) open, {
    int parallel = 1,
  }) async {
    if (_disposed || running) throw StateError('检查正在运行或工作区已关闭。');
    final targets = List<(String, String)>.of(books);
    running = true;
    stopping = false;
    cancelled = false;
    total = targets.length;
    _results = List.filled(targets.length, null);
    _publish();
    try {
      await runLimited(targets, parallel, (target, index) async {
        if (stopping || _disposed) return;
        _runningTitles.add(target.$2);
        currentTitle = _runningTitles.join('、');
        _publish();
        BookCheckSession? session;
        try {
          session = open(target.$1);
          _active.add(session);
          final report = await session.inspect();
          if (!session.isCurrent(report)) {
            throw const FormatException('书稿已变化，请重新检查。');
          }
          final failed = report.domains.any((d) => d.failed);
          _results[index] = LibraryCheckResult(
            target.$1,
            target.$2,
            report.domains
                .where((d) => d.id != 'output')
                .map((d) => '${d.title}：${d.status}')
                .join('；'),
            failed,
          );
        } catch (e) {
          _results[index] = LibraryCheckResult(
            target.$1,
            target.$2,
            e is FormatException ? e.message : '检查未完成，请在检查页重试。',
            true,
          );
        } finally {
          if (session != null) _active.remove(session);
          session?.dispose();
          _runningTitles.remove(target.$2);
          currentTitle = _runningTitles.join('、');
        }
        _publish();
      });
    } finally {
      cancelled = results.length < total;
      running = false;
      currentTitle = '';
      _publish();
    }
  }

  @override
  void dispose() {
    for (final session in _active) {
      session.cancel();
    }
    _disposed = true;
    stopping = true;
    super.dispose();
  }
}

abstract class LibraryBatchChecks {
  LibraryCheckBatch get checkBatch;
  Future<void> inspectBooks(Set<String> ids);
}
