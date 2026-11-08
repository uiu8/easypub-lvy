// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'package:flutter/painting.dart';

/// Move the image under the viewport, in visually oriented coordinates.
Rect panCoverRegion(
  Rect region,
  Size source,
  Size viewport,
  BoxFit fit,
  Offset drag,
) {
  if (source.isEmpty || viewport.isEmpty || region.isEmpty) return region;
  final pixels = Rect.fromLTWH(
    region.left * source.width,
    region.top * source.height,
    region.width * source.width,
    region.height * source.height,
  );
  final fitted = applyBoxFit(fit, pixels.size, viewport);
  if (fitted.destination.isEmpty) return region;
  // Materialize the implicit center crop before moving a cover-filled image.
  final visible = Alignment.center.inscribe(fitted.source, pixels);
  final width = visible.width / source.width;
  final height = visible.height / source.height;
  final x =
      (visible.left / source.width - drag.dx * width / fitted.destination.width)
          .clamp(0.0, 1 - width);
  final y =
      (visible.top / source.height -
              drag.dy * height / fitted.destination.height)
          .clamp(0.0, 1 - height);
  return Rect.fromLTWH(x, y, width, height);
}
