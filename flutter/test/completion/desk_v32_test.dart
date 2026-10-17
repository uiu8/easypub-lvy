import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';

/// V32：阅读器字号与页边距按 Kindle 固件参数（LAY-113）。
void main() {
  KindleDevice device(String id) => kindleDevices.firstWhere((k) => k.id == id);
  PreviewDeviceChoice choice(
    String id, {
    int level = 8,
    String margin = 'narrow',
  }) {
    final k = device(id);
    return PreviewDeviceChoice(
      id: id,
      width: k.width,
      height: k.height,
      ppi: k.ppi,
      level: level,
      margin: margin,
    );
  }

  test('页边距按固件磅值换算：KPW5 窄边距约 5.7%，中、宽为窄的 2、3 倍', () {
    final kpw5 = device('kpw5');
    final narrow = readerSideMargin(kpw5, 'narrow');
    expect(narrow / kpw5.viewportWidth, closeTo(16.98 * 300 / 72 / 1236, 1e-9));
    expect(readerSideMargin(kpw5, 'medium'), closeTo(narrow * 2, 1e-9));
    expect(readerSideMargin(kpw5, 'wide'), closeTo(narrow * 3, 1e-9));
    final m = readerMetrics(choice('kpw5'));
    expect(m.padding.top, closeTo(kindlePtToCss(kpw5, 13.58), 1e-9));
    expect(m.padding.bottom, closeTo(kindlePtToCss(kpw5, 13.58), 1e-9));
  });

  test('字号表按 ppi 选取：300 ppi 机型用 300 表，基础款第 10 代（167 ppi）用 167 表', () {
    expect(kindleRamp(device('kpw5')), kindleFontRamp[300]);
    expect(kindleRamp(device('basic10')), kindleFontRamp[167]);
    for (final ramp in kindleFontRamp.values) {
      expect(ramp, hasLength(14));
      for (var i = 1; i < 14; i++) {
        expect(ramp[i], greaterThan(ramp[i - 1]));
      }
    }
  });

  test('KPW5 实测档位不变；14 档逐档变大；同一档位在 300 ppi 机型上物理字号相同', () {
    final kpw5 = device('kpw5');
    final width = kpw5.viewportWidth - 2 * readerSideMargin(kpw5, 'narrow');
    for (final e in kpw5Calibration.entries) {
      final m = readerMetrics(choice('kpw5', level: e.key));
      expect(m.measured, true);
      expect(width / m.fontPx, closeTo(readerLineEms(e.value.$1), 1e-6));
    }
    for (final id in [
      'kpw3',
      'kpw5',
      'kpw6',
      'voyage',
      'oasis3',
      'scribe',
      'basic10',
    ]) {
      var last = 0.0;
      for (var level = 1; level <= 14; level++) {
        final px = readerMetrics(choice(id, level: level)).fontPx;
        expect(px, greaterThan(last), reason: '$id $level');
        last = px;
      }
    }
    // 物理字号（毫米）= CSS 像素 ÷ 每毫米 CSS 像素。
    double mm(String id, int level) {
      final k = device(id);
      final perMm = k.viewportWidth / (k.width / k.ppi * 25.4);
      return readerMetrics(choice(id, level: level)).fontPx / perMm;
    }

    for (final level in [3, 8, 13]) {
      expect(mm('voyage', level), closeTo(mm('kpw5', level), 1e-6));
      expect(mm('scribe', level), closeTo(mm('kpw5', level), 1e-6));
      // 167 ppi 字号表略大（第 8 档 14.23 对 13.92 磅）。
      expect(
        mm('basic10', level) / mm('kpw5', level),
        closeTo(
          kindleFontRamp[167]![level - 1] / kindleFontRamp[300]![level - 1],
          1e-6,
        ),
      );
    }
    final m6 = readerMetrics(choice('kpw5', level: 6));
    expect(m6.measured, false);
    expect(m6.note, '按固件推算');
  });

  test('实测每行 N 字按 N−0.25 个字的行宽：容得下 N−1 个整字加一个压半的行末标点（V34）', () {
    expect(readerLineEms(16), 15.75);
    expect(readerLineEms(16), greaterThanOrEqualTo(15.5));
    expect(readerLineEms(16), lessThan(16));
  });
}
