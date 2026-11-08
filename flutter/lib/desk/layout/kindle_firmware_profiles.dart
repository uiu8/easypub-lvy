// 从各机型官方更新包提取的阅读器资源；出处及验证边界见
// docs/evidence/kindle-firmware-profiles-20261108.md。
// 资源相同不表示完整排版引擎或真机分页相同。
import 'dart:math' as math;
import 'dart:typed_data';

/// KindleResourceBundle.pixVal 使用 Java float，最后向下取整。
/// 例如 Scribe 的 15.36 pt 在 300 PPI 下为 63.999996，再取整为 63。
double firmwarePixVal(double pt, int ppi, double factor) {
  if (pt <= 0) return 0;
  double f32(double value) => (Float32List(1)..[0] = value)[0];
  final scaled = f32(f32(pt) * f32(factor));
  return math.max(1, f32(scaled * f32(ppi / 72)).floor()).toDouble();
}

class KindleFirmwareProfile {
  const KindleFirmwareProfile(
    this.version, {
    this.cjkRampPt = cjk300RampPt,
    this.screenFactor = 1,
    this.verticalMarginPt = 13.58,
    this.footerHeightPt = 13.58,
    this.sideMarginPt = const [16.98, 33.96, 50.94],
    this.lineSpacing = const [1.14, 1.35, 1.54],
  });

  final String version;
  final List<double> cjkRampPt;
  final double screenFactor, verticalMarginPt, footerHeightPt;

  /// 窄、中、宽；固件资源中的顺序为宽、中、窄。
  final List<double> sideMarginPt;

  /// 小、中、大；不包含固件里未在本软件开放的额外档位。
  final List<double> lineSpacing;
}

const cjk300RampPt = <double>[
  6.96,
  7.92,
  8.40,
  9.36,
  10.56,
  11.52,
  12.48,
  13.92,
  15.36,
  17.04,
  19.20,
  22.08,
  25.20,
  29.04,
];

const cjk167RampPt = <double>[
  7,
  8,
  9,
  11,
  13,
  14.5,
  16,
  19,
  22,
  25,
  28,
  31,
  34,
  37,
];

const kindleFirmwareProfiles = <String, KindleFirmwareProfile>{
  'kpw5': KindleFirmwareProfile('5.17.1.0.3', screenFactor: 1.13),
  'kpw3': KindleFirmwareProfile('5.16.2.1.1'),
  'kpw4': KindleFirmwareProfile('5.18.1.1.1'),
  'kpw6': KindleFirmwareProfile('5.20.1', screenFactor: 1.16),
  'basic11': KindleFirmwareProfile('5.19.2'),
  'basic10': KindleFirmwareProfile('5.18.1.1.1', cjkRampPt: cjk167RampPt),
  'voyage': KindleFirmwareProfile('5.13.6'),
  'oasis1': KindleFirmwareProfile('5.16.2.1.1'),
  'oasis2': KindleFirmwareProfile('5.16.2.1.1', screenFactor: 1.16),
  'oasis3': KindleFirmwareProfile('5.18.2.1.1', screenFactor: 1.16),
  'scribe': KindleFirmwareProfile('5.20.1', verticalMarginPt: 15.36),
  'colorsoft': KindleFirmwareProfile('5.20.1', screenFactor: 1.16),
};
