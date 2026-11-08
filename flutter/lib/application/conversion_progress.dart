// 转换进度百分比（V134）：后台只报告“准备 / 生成 / 核验”三个阶段，没有逐章进度。
// 每个阶段占一段（准备 0–12%、生成 12–88%、核验 88–99%），阶段内按已用时间与
// 同格式最近的实际耗时估算，最多走到这一段的 95%，阶段真正结束才跳到下一段；完成为 100%。
// 显示时写“约”，说明是估算。
import 'dart:math' as math;

import 'conversion_service.dart';

class ConversionProgress {
  ConversionProgress._();
  static final instance = ConversionProgress._();

  static const _bands = [(0.0, 0.12), (0.12, 0.88), (0.88, 0.99)];

  /// 每个任务当前阶段与开始时间。
  final _phase = <String, (int, DateTime)>{};

  /// 格式/阶段 → 最近几次的平均耗时（秒）。
  final _seconds = <String, double>{};

  static int? _group(String phase) => switch (phase) {
    'preparing' => 0,
    'prepared' || 'converting' => 1,
    'checking' || 'publishing' => 2,
    _ => null,
  };

  static double _default(String format, int group) => switch (group) {
    0 => 2,
    2 => 3,
    _ => switch (format.toUpperCase()) {
      'KFX' => 40,
      'AZW3' || 'MOBI' => 12,
      _ => 4,
    },
  };

  static String _key(ConversionOutput o) =>
      o.taskId ?? '${o.batchId}|${o.bookId}|${o.format}';

  /// 0–1；等待中为 0，完成为 1；失败、取消或状态不明时为 null。
  double? fraction(ConversionOutput o, {DateTime? now}) {
    if (o.complete) {
      _finish(o, now ?? DateTime.now());
      return 1;
    }
    if (o.phase == 'waiting') return 0;
    final group = _group(o.phase);
    if (group == null || !o.statusAvailable) return null;
    final at = now ?? DateTime.now();
    final key = _key(o);
    final seen = _phase[key];
    if (seen == null || seen.$1 != group) {
      if (seen != null && seen.$1 < group) _learn(o.format, seen, at);
      _phase[key] = (group, at);
    }
    final start = _phase[key]!.$2;
    final expected =
        _seconds['${o.format}/$group'] ?? _default(o.format, group);
    final elapsed = at.difference(start).inMilliseconds / 1000;
    // 指数趋近：用到预计时间时约走完 63%，之后越来越慢，最多 95%。
    final within = math.min(0.95, 1 - math.exp(-elapsed / expected));
    final (from, to) = _bands[group];
    return from + (to - from) * within;
  }

  void _learn(String format, (int, DateTime) seen, DateTime at) {
    final seconds = at.difference(seen.$2).inMilliseconds / 1000;
    if (seconds <= 0) return;
    final key = '$format/${seen.$1}';
    final old = _seconds[key];
    _seconds[key] = old == null ? seconds : old * 0.5 + seconds * 0.5;
  }

  void _finish(ConversionOutput o, DateTime at) {
    final seen = _phase.remove(_key(o));
    if (seen != null) _learn(o.format, seen, at);
  }

  /// 整批：每本按自己的进度，失败或取消的算走完。
  double? batch(List<ConversionOutput> outputs, {DateTime? now}) {
    if (outputs.isEmpty) return null;
    var sum = 0.0;
    for (final o in outputs) {
      sum += fraction(o, now: now) ?? 1;
    }
    return sum / outputs.length;
  }

  static String label(double value) =>
      value >= 1 ? '100%' : '约 ${(value * 100).floor().clamp(0, 99)}%';
}
