import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';

/// V31：真机预览机身外观按实拍照片校正（LAY-112）。
void main() {
  KindleDevice device(String id) => kindleDevices.firstWhere((k) => k.id == id);

  test('非握持机型：屏幕左右居中，上边框按实拍，下边框取余量且更宽', () {
    for (final k in kindleDevices.where((k) => !k.grip)) {
      final bottom = k.bodyHeightMm - k.topBezelMm - k.screenHeightMm;
      expect(bottom, greaterThan(k.topBezelMm), reason: k.id);
      expect(k.logo, isNotEmpty, reason: k.id);
    }
    // 用户的 KPW5 实拍：上边框与左右边框相同（约 10 毫米），下边框约 25 毫米。
    final kpw5 = device('kpw5');
    final side = (kpw5.bodyWidthMm - kpw5.screenWidthMm) / 2;
    expect(kpw5.topBezelMm, closeTo(side, .5));
    expect(
      kpw5.bodyHeightMm - kpw5.topBezelMm - kpw5.screenHeightMm,
      closeTo(25.0, .2),
    );
    // KPW4、Voyage 上边框比左右厚。
    for (final id in ['kpw4', 'voyage']) {
      final k = device(id);
      expect(k.topBezelMm, greaterThan((k.bodyWidthMm - k.screenWidthMm) / 2));
    }
    expect(device('voyage').pressMarks, true);
    expect(device('basic10').logo, 'dark');
  });

  test('握持机型：三条窄边等宽，宽边 Oasis 在右、Scribe 在左，前面没有字样', () {
    for (final k in kindleDevices.where((k) => k.grip)) {
      expect(
        k.topBezelMm * 2 + k.screenHeightMm,
        closeTo(k.bodyHeightMm, .6),
        reason: k.id,
      );
      expect(
        k.bodyWidthMm - k.topBezelMm - k.screenWidthMm,
        greaterThan(k.topBezelMm * 1.8),
        reason: k.id,
      );
      expect(k.logo, isEmpty, reason: k.id);
    }
    expect(device('scribe').gripLeft, true);
    expect(device('oasis3').gripLeft, false);
  });
}
