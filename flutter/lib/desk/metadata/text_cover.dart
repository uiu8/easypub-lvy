// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class TextCoverPainter extends CustomPainter {
  const TextCoverPainter(
    this.title,
    this.author,
    this.series,
    this.color, {
    this.background,
  });
  final String title, author, series;
  final Color color;

  /// 样式包封面背景（V74b）：有背景时文字用深色，并在文字下铺浅底。
  final ui.Image? background;

  /// Measures complete text; a null result means it cannot remain readable.
  static TextPainter? fitText(
    String text, {
    required Size bounds,
    required double maximum,
    required double minimum,
    bool bold = false,
    Color ink = Colors.white,
  }) {
    TextPainter measure(double size) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Microsoft YaHei',
          fontSize: size,
          height: 1.35,
          color: ink,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: bounds.width);
    bool fits(TextPainter value) =>
        value.height <= bounds.height &&
        value.computeLineMetrics().every(
          (line) => line.width <= bounds.width + .01,
        );
    var result = measure(maximum);
    if (fits(result)) return result;
    result.dispose();
    result = measure(minimum);
    if (!fits(result)) {
      result.dispose();
      return null;
    }
    var low = minimum, high = maximum;
    for (var i = 0; i < 10; i++) {
      final middle = (low + high) / 2;
      final candidate = measure(middle);
      if (fits(candidate)) {
        result.dispose();
        result = candidate;
        low = middle;
      } else {
        candidate.dispose();
        high = middle;
      }
    }
    return result;
  }

  List<(String, String, Rect, double, double, bool)> get fields => [
    ('系列文字', series, const Rect.fromLTWH(156, 156, 888, 220), 70, 28, false),
    ('封面标题', title, const Rect.fromLTWH(156, 620, 888, 600), 170, 36, true),
    ('作者署名', author, const Rect.fromLTWH(156, 1320, 888, 160), 80, 32, false),
  ];

  String? get validationMessage {
    if (title.trim().isEmpty) return '请填写封面标题。';
    for (final field in fields) {
      if (field.$2.runes.length > 512) return '${field.$1}最多512个字符。';
      final layout = fitText(
        field.$2,
        bounds: field.$3.size,
        maximum: field.$4,
        minimum: field.$5,
        bold: field.$6,
      );
      if (layout == null) return '${field.$1}过长，请缩短文字或减少手动换行。';
      layout.dispose();
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1200, size.height / 1600);
    const bounds = Rect.fromLTWH(0, 0, 1200, 1600);
    final image = background;
    if (image == null) {
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color, Color.lerp(color, Colors.black, .22)!],
          ).createShader(bounds),
      );
    } else {
      // 等比铺满后居中裁切。
      final src = Size(image.width.toDouble(), image.height.toDouble());
      final scale = (1200 / src.width) > (1600 / src.height)
          ? 1200 / src.width
          : 1600 / src.height;
      final crop = Size(1200 / scale, 1600 / scale);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(
          (src.width - crop.width) / 2,
          (src.height - crop.height) / 2,
          crop.width,
          crop.height,
        ),
        bounds,
        Paint()..filterQuality = FilterQuality.high,
      );
    }
    const deep = Color(0xff2f2a24), soft = Color(0xff4a433a);
    for (final field in fields) {
      final layout = field.$2.runes.length <= 512
          ? fitText(
              field.$2,
              bounds: field.$3.size,
              maximum: field.$4,
              minimum: field.$5,
              bold: field.$6,
              ink: image == null
                  ? (field.$6 ? Colors.white : Colors.white70)
                  : (field.$6 ? deep : soft),
            )
          : null;
      final visible =
          layout ??
          fitText(
            '${field.$1}过长，请调整文字',
            bounds: field.$3.size,
            maximum: 36,
            minimum: 28,
          )!;
      // 样式包背景：只在实际文字外围铺一圈浅底，保证文字在任何背景上都清楚。
      if (image != null && field.$2.trim().isNotEmpty) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            (field.$3.topLeft & Size(visible.width, visible.height)).inflate(
              24,
            ),
            const Radius.circular(14),
          ),
          Paint()..color = const Color(0x99ffffff),
        );
      }
      visible.paint(canvas, field.$3.topLeft);
      visible.dispose();
    }
    canvas.restore();
  }

  Future<ui.Image> render() async {
    final error = validationMessage;
    if (error != null) throw FormatException(error);
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder), const Size(1200, 1600));
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(1200, 1600);
    } finally {
      picture.dispose();
    }
  }

  @override
  bool shouldRepaint(TextCoverPainter old) =>
      old.title != title ||
      old.author != author ||
      old.series != series ||
      old.color != color ||
      old.background != background;
}
