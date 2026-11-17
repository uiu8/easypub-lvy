import 'package:easypub_desktop/desk/layout/device_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('底色面板的实际绘制高度与分页高度一致', (t) async {
    final style = PreviewStyle(
      title: const TextStyle(fontSize: 20),
      body: const TextStyle(fontSize: 16, height: 1.6),
      align: TextAlign.start,
      indent: 0,
      paragraphSpacing: 6,
      titleSpacing: 12,
      padding: const EdgeInsets.all(12),
      systemBlock: 'styled',
      verseBlock: 'center',
      systemStyles: {
        'panel': {'title': 'shaded', 'shade': 'light', 'border': 'full'},
      },
    );
    const size = Size(420, 900);
    const tail = PreviewPiece('after', indent: false);
    Future<double> tailY(List<PreviewPiece> pieces) async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: PreviewPage(
            pieces: pieces,
            style: style,
            size: size,
            paper: Colors.white,
          ),
        ),
      );
      final canvas = TestRecordingCanvas();
      t
          .widget<CustomPaint>(find.byType(CustomPaint))
          .painter!
          .paint(canvas, size);
      final draw = canvas.invocations
          .where((v) => v.invocation.memberName == #drawParagraph)
          .last;
      return (draw.invocation.positionalArguments[1] as Offset).dy;
    }

    final baseline = await tailY([tail]);
    for (final heading in [false, true]) {
      for (final count in [1, 3, 12]) {
        final panel = [
          for (var i = 0; i < count; i++)
            PreviewPiece(
              'line $i',
              kind: 'system',
              role: 'panel',
              runStart: i == 0,
              runEnd: i == count - 1,
              heading: heading && i == 0,
            ),
        ];
        final actual = await tailY([...panel, tail]);
        final expected =
            baseline +
            PreviewPage.contentHeight(
              panel,
              style,
              size.width - style.padding.horizontal,
            ) +
            style.paragraphSpacing;
        expect(
          actual,
          closeTo(expected, .001),
          reason: 'heading=$heading count=$count',
        );
      }
    }
    expect(t.takeException(), isNull);
  });
}
