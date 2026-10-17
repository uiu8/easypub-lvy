import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/metadata/cover_pan.dart';

void main() {
  test('drag materializes cover crop and stops at source boundaries', () {
    final region = panCoverRegion(
      const Rect.fromLTWH(0, 0, 1, 1),
      const Size(400, 400),
      const Size(200, 400),
      BoxFit.cover,
      const Offset(40, 0),
    );
    expect(region.left, closeTo(.15, 1e-9));
    expect(region.width, .5);
    expect(region.height, 1);
    final edge = panCoverRegion(
      region,
      const Size(400, 400),
      const Size(200, 400),
      BoxFit.cover,
      const Offset(-10000, 10000),
    );
    expect(edge, const Rect.fromLTWH(.5, 0, .5, 1));
  });
  test('contain drag accounts for letterboxing and retains selection size', () {
    final region = panCoverRegion(
      const Rect.fromLTWH(.2, .2, .6, .6),
      const Size(1000, 1000),
      const Size(300, 400),
      BoxFit.contain,
      const Offset(50, -50),
    );
    expect(region.left, closeTo(.1, 1e-9));
    expect(region.top, closeTo(.3, 1e-9));
    expect(region.width, closeTo(.6, 1e-9));
    expect(region.height, closeTo(.6, 1e-9));
  });
}
