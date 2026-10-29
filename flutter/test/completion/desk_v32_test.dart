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
    // V118：上下边距按真机实测（KPW5 上 63 像素，即 15.12 磅），各机型按 ppi 换算。
    final k5 = readerMetrics(choice('kpw5'));
    expect((k5.padding.top, k5.padding.bottom), (63, 63));
    final b10 = readerMetrics(choice('basic10'));
    expect(b10.padding.top, (15.12 * 167 / 72).roundToDouble());
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

  test('14 档逐档变大；同一档位在 300 ppi 机型上物理字号相同', () {
    // V118：各机型按 KPW5 真机规则，字号 = 固件字号表 × ppi/72（取整）× 书内 110%。
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
    // 物理字号（毫米）= 屏幕像素 ÷ 每毫米像素（视口即分辨率）。
    double mm(String id, int level) {
      final k = device(id);
      final perMm = k.viewportWidth / (k.width / k.ppi * 25.4);
      return readerMetrics(choice(id, level: level)).fontPx / perMm;
    }

    for (final level in [3, 8, 13]) {
      expect(mm('scribe', level), closeTo(mm('voyage', level), 1e-6));
      expect(mm('kpw6', level), closeTo(mm('voyage', level), 1e-6));
      // 167 ppi 字号表略大（第 8 档 14.23 对 13.92 磅）；字号先取整到像素，允许 1% 误差。
      expect(
        mm('basic10', level) / mm('voyage', level),
        closeTo(
          kindleFontRamp[167]![level - 1] / kindleFontRamp[300]![level - 1],
          .01,
        ),
      );
    }
    final m6 = readerMetrics(choice('kpw6', level: 6));
    expect(m6.measured, false);
    expect(m6.note, '按 KPW5 真机规则按 300 PPI 换算');
    // 所有机型按原生分辨率排版。
    for (final k in kindleDevices) {
      expect((k.viewportWidth, k.viewportHeight), (k.width, k.height));
    }
  });

  test('实测每行 N 字按 N−0.25 个字的行宽：容得下 N−1 个整字加一个压半的行末标点（V34）', () {
    expect(readerLineEms(16), 15.75);
    expect(readerLineEms(16), greaterThanOrEqualTo(15.5));
    expect(readerLineEms(16), lessThan(16));
  });
}
