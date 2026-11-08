import 'dart:typed_data';

import 'package:easypub_desktop/prototype/png_orientation.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/metadata/cover_preview.dart';

void main() {
  test('byte snapshot PNG orientation handles all EXIF orientations and truncated chunks', () {
    for (final endian in [Endian.little, Endian.big]) {
      for (var orientation = 1; orientation <= 8; orientation++) {
        final tiff = Uint8List(26);
        tiff[0] = tiff[1] = endian == Endian.little ? 73 : 77;
        final data = ByteData.sublistView(tiff);
        data.setUint16(2, 42, endian);
        data.setUint32(4, 8, endian);
        data.setUint16(8, 1, endian);
        data.setUint16(10, 0x112, endian);
        data.setUint16(12, 3, endian);
        data.setUint32(14, 1, endian);
        data.setUint16(18, orientation, endian);
        final png = Uint8List.fromList([
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
          0,
          0,
          0,
          26,
          101,
          88,
          73,
          102,
          ...tiff,
          0,
          0,
          0,
          0,
        ]);
        expect(pngOrientationBytes(png), orientation);
        expect(pngOrientationBytes(Uint8List.sublistView(png, 0, 20)), 1);
      }
    }
  });
  test(
    'cover painter preserves all eight orientation grids and crop coordinates',
    () async {
      final colors = [
        Colors.red,
        Colors.green,
        Colors.blue,
        Colors.yellow,
        Colors.cyan,
        Colors.purple,
      ];
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var i = 0; i < 6; i++) {
        canvas.drawRect(
          Rect.fromLTWH((i % 2) * 20, (i ~/ 2) * 20, 20, 20),
          Paint()..color = colors[i],
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(40, 60);
      picture.dispose();
      const grids = [
        [0, 1, 2, 3, 4, 5],
        [1, 0, 3, 2, 5, 4],
        [5, 4, 3, 2, 1, 0],
        [4, 5, 2, 3, 0, 1],
        [0, 2, 4, 1, 3, 5],
        [4, 2, 0, 5, 3, 1],
        [5, 3, 1, 4, 2, 0],
        [1, 3, 5, 0, 2, 4],
      ];
      for (var orientation = 1; orientation <= 8; orientation++) {
        final columns = orientation >= 5 ? 3 : 2,
            rows = orientation >= 5 ? 2 : 3;
        for (final cropped in [false, true]) {
          final outputColumns = cropped ? 1 : columns;
          final rec = ui.PictureRecorder();
          final target = Canvas(rec);
          CoverRegionPainter(
            image,
            orientation,
            cropped
                ? {
                    'x': (columns - 1) / columns,
                    'y': 0,
                    'width': 1 / columns,
                    'height': 1,
                  }
                : null,
            BoxFit.fill,
          ).paint(target, Size(outputColumns * 20, rows * 20));
          final pic = rec.endRecording();
          final result = await pic.toImage(outputColumns * 20, rows * 20);
          pic.dispose();
          final bytes = (await result.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          for (var row = 0; row < rows; row++) {
            for (var col = 0; col < outputColumns; col++) {
              final index =
                  ((row * 20 + 10) * outputColumns * 20 + col * 20 + 10) * 4;
              final color =
                  colors[grids[orientation - 1][row * columns +
                          (cropped ? columns - 1 : col)]]
                      .toARGB32();
              expect(
                bytes.getUint8(index),
                (color >> 16) & 255,
                reason: 'orientation $orientation crop $cropped red',
              );
              expect(bytes.getUint8(index + 1), (color >> 8) & 255);
              expect(bytes.getUint8(index + 2), color & 255);
            }
          }
          result.dispose();
        }
      }
      image.dispose();
    },
  );
}
