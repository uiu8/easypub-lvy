import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_progress.dart';
import 'package:easypub_desktop/application/conversion_service.dart';

/// V134：转换进度百分比按阶段与上次耗时估算。
void main() {
  ConversionOutput task(String id, String phase, {String format = 'KFX'}) =>
      ConversionOutput(
        'b',
        '书',
        '',
        '',
        phase: phase,
        format: format,
        taskId: id,
      );

  test('阶段内只走到本段 95%，阶段结束才进入下一段；完成为 100%', () {
    final p = ConversionProgress.instance;
    final t0 = DateTime(2026, 11, 5, 12);
    expect(p.fraction(task('a', 'waiting')), 0);
    final start = p.fraction(task('a', 'preparing'), now: t0)!;
    expect(start, closeTo(0, 0.001));
    // 准备阶段过了很久也不超过 12% 的 95%。
    final late = p.fraction(
      task('a', 'preparing'),
      now: t0.add(const Duration(minutes: 5)),
    )!;
    expect(late, lessThanOrEqualTo(0.12 * 0.95 + 1e-9));
    // 进入生成阶段从 12% 起步，并单调增加，不超过 88%。
    final t1 = t0.add(const Duration(minutes: 5));
    final g0 = p.fraction(task('a', 'converting'), now: t1)!;
    expect(g0, closeTo(0.12, 0.001));
    final g1 = p.fraction(
      task('a', 'converting'),
      now: t1.add(const Duration(seconds: 20)),
    )!;
    final g2 = p.fraction(
      task('a', 'converting'),
      now: t1.add(const Duration(minutes: 30)),
    )!;
    expect(g1, greaterThan(g0));
    expect(g2, greaterThan(g1));
    expect(g2, lessThan(0.88));
    expect(p.fraction(task('a', 'complete')), 1);
    expect(p.fraction(task('a', 'failed')), isNull);
    expect(ConversionProgress.label(0.623), '约 62%');
    expect(ConversionProgress.label(0.999), '约 99%');
    expect(ConversionProgress.label(1), '100%');
  });

  test('整批：完成算 100%、等待算 0，失败算走完', () {
    final p = ConversionProgress.instance;
    expect(
      p.batch([
        task('x', 'complete'),
        task('y', 'waiting'),
        task('z', 'failed'),
        task('w', 'waiting'),
      ]),
      0.5,
    );
  });
}
