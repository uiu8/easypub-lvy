import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:easypub_desktop/desk/layout/kindle_firmware_profiles.dart';

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

  test('页边距按固件磅值与屏幕系数换算：KPW5 窄边距约 6.5%，中、宽为窄的 2、3 倍', () {
    final kpw5 = device('kpw5');
    final narrow = readerSideMargin(kpw5, 'narrow');
    // V131：固件 pixVal，6.8 英寸屏乘 1.13。
    expect(
      narrow / kpw5.viewportWidth,
      closeTo(16.98 * 1.13 * 300 / 72 / 1236, 1e-9),
    );
    expect(readerSideMargin(kpw5, 'medium'), closeTo(narrow * 2, 1e-9));
    expect(readerSideMargin(kpw5, 'wide'), closeTo(narrow * 3, 1e-9));
    // V131：上下边距按固件 13.58 磅 × 屏幕系数 × ppi ÷ 72 向下取整，换机型时随之变化。
    final k5 = readerMetrics(choice('kpw5'));
    expect((k5.padding.top, k5.padding.bottom), (63, 63));
    expect(readerMetrics(choice('kpw6')).padding.top, 65);
    expect(readerMetrics(choice('oasis3')).padding.bottom, 65);
    expect(readerMetrics(choice('kpw4')).padding.top, 56);
    expect(readerMetrics(choice('voyage')).padding.top, 56);
    expect(readerMetrics(choice('basic10')).padding.top, 31);
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
      // Basic 10 的本机中文表，第 8 档为 19 pt，不是西文表的 14.23 pt。
      expect(
        mm('basic10', level) / mm('voyage', level),
        closeTo(cjk167RampPt[level - 1] / cjk300RampPt[level - 1], .01),
      );
    }
    final m6 = readerMetrics(choice('kpw6', level: 6));
    expect(m6.measured, false);
    expect(m6.note, '按 KPW6 固件 5.20.1 · 未经真机核对');
    // 所有机型按原生分辨率排版。
    for (final k in kindleDevices) {
      expect((k.viewportWidth, k.viewportHeight), (k.width, k.height));
    }
  });

  test('12 款参数与逐机固件提取记录一致，KPW5 实测版心保持不变', () {
    final proof = jsonDecode(
      File('../docs/evidence/kindle-firmware-profiles-20261108.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final profiles = proof['profiles'] as Map<String, dynamic>;
    expect(
      kindleFirmwareProfiles.keys.toSet(),
      kindleDevices.map((d) => d.id).toSet(),
    );
    for (final d in kindleDevices) {
      final source = profiles[d.id] as Map<String, dynamic>;
      final profile = kindleFirmwareProfiles[d.id]!;
      expect([d.width, d.height], source['resolution'], reason: d.id);
      expect(profile.cjkRampPt, source['cjk_ramp_pt'], reason: d.id);
      expect(profile.sideMarginPt, source['side_margin_pt'], reason: d.id);
      expect(profile.lineSpacing, source['line_spacing'], reason: d.id);
      expect(profile.footerHeightPt, source['footer_height_pt'], reason: d.id);
      expect(profile.screenFactor, source['screen_factor'], reason: d.id);
      expect(firmwareVerticalMarginPx(d), source['vertical_px'], reason: d.id);
      if (d.id != 'kpw5') {
        expect(profile.version, source['firmware'], reason: d.id);
        expect(readerMetrics(choice(d.id)).measured, false);
        expect(readerMetrics(choice(d.id)).note, contains('未经真机核对'));
      }
    }
    final k5 = readerMetrics(choice('kpw5'));
    expect(k5.fontPx, closeTo(63.8, 1e-9));
    expect(k5.lineRatio * k5.fontPx, closeTo(103, 1e-9));
    expect(k5.padding.left, closeTo(107.6, 1e-9));
    expect(k5.measured, true);
    expect(firmwarePixVal(15.36, 300, 1), 63); // Java float 取整，非 double 的 64。
    expect(readerMetrics(choice('basic10')).fontPx, closeTo(48.4, 1e-9));
    expect(
      readerMetrics(const PreviewDeviceChoice(id: 'custom')).note,
      contains('推算'),
    );
  });

  test('实测每行 N 字按 N−0.25 个字的行宽：容得下 N−1 个整字加一个压半的行末标点（V34）', () {
    expect(readerLineEms(16), 15.75);
    expect(readerLineEms(16), greaterThanOrEqualTo(15.5));
    expect(readerLineEms(16), lessThan(16));
  });
}
