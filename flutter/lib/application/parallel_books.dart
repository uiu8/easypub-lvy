// 同时处理的书（V38，SET-069、LIB-115、OUT-083）：导入、书库检查、转换前检查与转换按此本数同时进行。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// 设置值与显示文字；值与 Rust `settings_store` 的校验一致。
const parallelBookChoices = {
  'auto': '自动',
  '1': '1 本',
  '2': '2 本',
  '4': '4 本',
  '8': '8 本',
};

/// 本机逻辑处理器数（设置页显示用）。
int logicalProcessors() => Platform.numberOfProcessors;

/// “自动”对应的本数：每个 Kindling 用 4 个线程，取逻辑处理器数 ÷ 4，限 1–4 本。
int autoParallelBooks([int? processors]) =>
    ((processors ?? Platform.numberOfProcessors) ~/ 4).clamp(1, 4);

/// 按全局设置取同时处理的本数；没有设置或值不认识时按“自动”。
int parallelBooks(Map<String, dynamic>? configuration, {int? processors}) {
  final value = int.tryParse('${configuration?['parallel_books'] ?? ''}');
  if (value != null && parallelBookChoices.containsKey('$value')) return value;
  return autoParallelBooks(processors);
}

/// 最多 [limit] 个同时执行 [action]：按 [items] 的顺序开始，前面的完成后再开始下一个。
/// [action] 自己处理错误；全部完成后返回。[limit] 为 1 时与逐个顺序执行相同。
Future<void> runLimited<T>(
  Iterable<T> items,
  int limit,
  Future<void> Function(T item, int index) action,
) async {
  final list = items.toList(growable: false);
  var next = 0;
  Future<void> worker() async {
    while (next < list.length) {
      final index = next++;
      await action(list[index], index);
    }
  }

  await Future.wait([
    for (var i = 0; i < math.min(math.max(limit, 1), list.length); i++)
      worker(),
  ]);
}

/// 同时进行的数量不超过 [limit]：超出的排队，按提交顺序开始。
class ConcurrencyLimit {
  ConcurrencyLimit(this.limit);
  final int limit;
  int _running = 0;
  final _waiting = <void Function()>[];

  Future<T> run<T>(Future<T> Function() action) async {
    if (_running >= limit) {
      // 名额由完成的任务直接交过来，计数不变，新来的任务不会在交接时插队。
      final turn = Completer<void>();
      _waiting.add(turn.complete);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0)();
      } else {
        _running--;
      }
    }
  }
}

/// 让异步操作一个接一个执行（批次记录、全局设置等不能同时写的地方）。
class SerialQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
