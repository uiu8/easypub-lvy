// 生成封面（LIB-102 样式；V16 起书库显示与转出的书共用同一画法，OUT-070）：
// 纸色底、按书名固定的墨色书脊、细线内框、衬线书名居中、作者在下；很小时只留书脊与书名首字。
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as dart_ui;

import 'package:flutter/rendering.dart';

import '../tokens.dart';

/// 生成封面的色带：几种低饱和墨色，按书名固定选取，同一本书每次相同。
const _coverInks = [
  Color(0xFF6F6A63),
  Color(0xFF7A6A58),
  Color(0xFF5E6B66),
  Color(0xFF6B6070),
  Color(0xFF5F6874),
  Color(0xFF7D6B5F),
];

Color coverInkFor(String title) {
  var hash = 0;
  for (final unit in title.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _coverInks[hash % _coverInks.length];
}

/// 生成封面的画法。[framed] 为 true 时画圆角与外边线（书库里的缩略图）；
/// 转出的封面图片铺满整张，不画外边线。
class GeneratedCoverPainter extends CustomPainter {
  GeneratedCoverPainter({
    required this.title,
    required this.author,
    required this.paper,
    required this.edge,
    required this.titleColor,
    required this.authorColor,
    this.framed = true,
  }) : ink = coverInkFor(title);

  /// 用编辑台配色画封面；转出的封面始终用浅色配色。
  factory GeneratedCoverPainter.desk(
    Desk d, {
    required String title,
    required String author,
    bool framed = true,
  }) => GeneratedCoverPainter(
    title: title,
    author: author,
    paper: d.paper,
    edge: d.lineStrong,
    titleColor: d.ink,
    authorColor: d.ink2,
    framed: framed,
  );

  final String title, author;
  final Color paper, edge, titleColor, authorColor, ink;
  final bool framed;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final scale = w / 150;
    final small = w < 70;
    final outer = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(framed ? (small ? 3 : 5) : 0),
    );
    canvas.save();
    canvas.clipRRect(outer);
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    final spine = math.max(3.0, w * .07);
    canvas.drawRect(Rect.fromLTWH(0, 0, spine, h), Paint()..color = ink);
    final inset = w * .09;
    if (small) {
      _text(
        canvas,
        title.isEmpty ? '书' : String.fromCharCodes(title.runes.take(1)),
        serif(w * .42, w: 650, c: ink),
        Rect.fromLTRB(spine + 2, 0, w - 2, h),
        center: true,
      );
    } else {
      canvas.drawRect(
        Rect.fromLTRB(spine + inset * .6, inset, w - inset * .6, h - inset),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8 * scale
          ..color = ink.withValues(alpha: .35),
      );
      final box = Rect.fromLTRB(
        spine + inset,
        inset * 1.6,
        w - inset,
        h - inset * 1.6,
      );
      final titlePainter = TextPainter(
        text: TextSpan(
          text: title,
          style: serif(w * .105, w: 650, c: titleColor, h: 1.35),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 4,
        ellipsis: '…',
      )..layout(maxWidth: box.width);
      final authorPainter = author.trim().isEmpty
          ? null
          : (TextPainter(
              text: TextSpan(
                text: author.trim(),
                style: ui(w * .07, c: authorColor),
              ),
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
              maxLines: 1,
              ellipsis: '…',
            )..layout(maxWidth: box.width));
      final gap = w * .05, rule = math.max(1.0, scale);
      final rest =
          box.height -
          titlePainter.height -
          gap -
          rule -
          (authorPainter?.height ?? 0);
      // 与书库里的排法相同：书名上方空白与下方空白为 2 : 3。
      final top = box.top + math.max(0.0, rest) * 2 / 5;
      titlePainter.paint(
        canvas,
        Offset(box.left + (box.width - titlePainter.width) / 2, top),
      );
      final ruleTop = top + titlePainter.height + gap;
      canvas.drawRect(
        Rect.fromLTWH(box.center.dx - w * .08, ruleTop, w * .16, rule),
        Paint()..color = ink,
      );
      titlePainter.dispose();
      if (authorPainter != null) {
        authorPainter.paint(
          canvas,
          Offset(
            box.left + (box.width - authorPainter.width) / 2,
            box.bottom - authorPainter.height,
          ),
        );
        authorPainter.dispose();
      }
    }
    canvas.restore();
    if (framed) {
      canvas.drawRRect(
        outer.deflate(.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8
          ..color = edge,
      );
    }
  }

  void _text(
    Canvas canvas,
    String text,
    TextStyle style,
    Rect box, {
    bool center = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: box.width);
    painter.paint(
      canvas,
      Offset(
        box.left + (box.width - painter.width) / 2,
        center ? box.top + (box.height - painter.height) / 2 : box.top,
      ),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(GeneratedCoverPainter old) =>
      old.title != title ||
      old.author != author ||
      old.paper != paper ||
      old.edge != edge ||
      old.titleColor != titleColor ||
      old.authorColor != authorColor ||
      old.framed != framed;
}

/// 把生成封面画成 1200 × 1600 的 PNG，供转换在书没有封面时写入成品（OUT-070）。
/// 返回新文件的路径；不改动任何已有的用户封面。
Future<String> renderGeneratedCover(
  String title,
  String author,
  Directory root,
) async {
  const size = Size(1200, 1600);
  final recorder = dart_ui.PictureRecorder();
  GeneratedCoverPainter.desk(
    Desk.light,
    title: title,
    author: author,
    framed: false,
  ).paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  picture.dispose();
  final data = await image.toByteData(format: dart_ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) throw const FormatException('文字封面生成失败，请选择封面图片后重试。');
  await root.create(recursive: true);
  final file = File(
    '${root.path}/cover-${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return file.path;
}
