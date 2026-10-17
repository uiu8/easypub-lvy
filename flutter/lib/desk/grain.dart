// 纸面颗粒：启动时用 Dart 生成一块 256×256 噪声贴图，之后用 ImageShader 平铺，
// 不需要图片资源，也不在每帧重新计算。
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 生产入口在启动时填入；测试宿主保持为空，背景退化为纯色。
final deskGrainTile = ValueNotifier<ui.Image?>(null);

Future<void> prepareDeskGrain() async {
  deskGrainTile.value ??= await makeGrainTile();
}

Future<ui.Image> makeGrainTile({int size = 256, int seed = 7}) {
  final rnd = Random(seed);
  final px = Uint8List(size * size * 4);
  for (var i = 0; i < size * size; i++) {
    // 大部分像素透明，少量深浅不一的颗粒；模仿纸张纤维而不是均匀雪花。
    final r = rnd.nextDouble();
    final a = r < .62
        ? 0
        : (r < .95 ? 14 + rnd.nextInt(26) : 60 + rnd.nextInt(50));
    final v = 60 + rnd.nextInt(60);
    px[i * 4] = v;
    px[i * 4 + 1] = (v * .94).round();
    px[i * 4 + 2] = (v * .84).round();
    px[i * 4 + 3] = a;
  }
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, size, size, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// 在子组件下方铺纸色 + 颗粒。只用于大面积背景，面板与列表保持纯色以保证可读性。
class PaperGround extends StatelessWidget {
  const PaperGround({
    super.key,
    required this.color,
    required this.child,
    this.strength,
  });
  final Color color;
  final Widget child;
  final double? strength;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ui.Image?>(
    valueListenable: deskGrainTile,
    builder: (context, tile, child) => CustomPaint(
      painter: _GrainPainter(tile, color, strength ?? context.desk.grain),
      child: child,
    ),
    child: child,
  );
}

class _GrainPainter extends CustomPainter {
  _GrainPainter(this.tile, this.color, this.strength);
  final ui.Image? tile;
  final Color color;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = color);
    if (tile == null || strength <= 0) return;
    final m = Float64List.fromList([
      .5, 0, 0, 0, //
      0, .5, 0, 0, //
      0, 0, 1, 0, //
      0, 0, 0, 1, //
    ]);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ImageShader(tile!, TileMode.repeated, TileMode.repeated, m)
        ..color = Colors.black.withValues(alpha: (strength * 10).clamp(0, 1))
        ..blendMode = BlendMode.multiply,
    );
  }

  @override
  bool shouldRepaint(_GrainPainter old) =>
      old.tile != tile || old.color != color || old.strength != strength;
}
