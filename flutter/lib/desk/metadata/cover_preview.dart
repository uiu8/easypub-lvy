// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../prototype/png_orientation.dart';

/// New presentation widget; only the nonvisual bounded EXIF parser is shared.
class CoverPreview extends StatefulWidget {
  const CoverPreview({
    super.key,
    required this.path,
    this.crop,
    this.fit = BoxFit.contain,
    this.decodeWidth = 900,
    this.revision = '',
    this.onAspectRatio,
  });
  final String path, revision;
  final Map<String, dynamic>? crop;
  final BoxFit fit;
  final int decodeWidth;
  final ValueChanged<double>? onAspectRatio;
  @override
  State<CoverPreview> createState() => _CoverPreviewState();
}

// Share decoded images by content rather than path: replacing a file at the
// same path must not revive Flutter's old FileImage cache entry.
class _ContentKey {
  const _ContentKey(this.digest);
  final String digest;
  @override
  bool operator ==(Object other) =>
      other is _ContentKey && other.digest == digest;
  @override
  int get hashCode => digest.hashCode;
}

class _ContentImage extends ImageProvider<_ContentKey> {
  _ContentImage(this.bytes)
    : key = _ContentKey(sha256.convert(bytes).toString());
  final Uint8List bytes;
  final _ContentKey key;
  // Only the small digest is retained as an ImageCache key. Encoded originals
  // can be released after decode instead of accumulating outside its byte budget.
  @override
  Future<_ContentKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(key);
  @override
  ImageStreamCompleter loadImage(
    _ContentKey key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _decode(decode), scale: 1);
  Future<ui.Codec> _decode(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(bytes));
}

class _CoverPreviewState extends State<CoverPreview> {
  ImageStream? stream;
  ImageStreamListener? listener;
  ImageInfo? info;
  int serial = 0, orientation = 1;
  bool failed = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    resolve();
  }

  @override
  void didUpdateWidget(CoverPreview old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path ||
        old.decodeWidth != widget.decodeWidth ||
        old.revision != widget.revision) {
      resolve();
    }
  }

  void detach() {
    if (listener != null) stream?.removeListener(listener!);
    info?.dispose();
    info = null;
  }

  Future<void> resolve() async {
    final ticket = ++serial;
    detach();
    failed = false;
    Uint8List bytes;
    RandomAccessFile? file;
    try {
      file = await File(widget.path).open();
      bytes = await file.read(32 * 1024 * 1024 + 1);
      if (bytes.length > 32 * 1024 * 1024) {
        throw const FormatException('封面图片过大');
      }
    } catch (_) {
      if (mounted && ticket == serial) setState(() => failed = true);
      return;
    } finally {
      await file?.close();
    }
    if (!mounted || ticket != serial) return;
    orientation = pngOrientationBytes(bytes);
    stream = ResizeImage(
      _ContentImage(bytes),
      width: widget.decodeWidth,
      allowUpscaling: false,
    ).resolve(createLocalImageConfiguration(context));
    listener = ImageStreamListener(
      (image, _) {
        if (!mounted || ticket != serial) {
          image.dispose();
          return;
        }
        setState(() {
          info?.dispose();
          info = image;
        });
        final ratio = orientation >= 5
            ? image.image.height / image.image.width
            : image.image.width / image.image.height;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && ticket == serial) widget.onAspectRatio?.call(ratio);
        });
      },
      onError: (_, _) {
        if (mounted && ticket == serial) setState(() => failed = true);
      },
    );
    stream!.addListener(listener!);
  }

  @override
  void dispose() {
    serial++;
    detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => failed
      ? const Center(child: Text('封面图片不可读取'))
      : info == null
      ? const Center(child: CircularProgressIndicator())
      : CustomPaint(
          painter: CoverRegionPainter(
            info!.image,
            orientation,
            widget.crop,
            widget.fit,
          ),
          child: const SizedBox.expand(),
        );
}

class CoverRegionPainter extends CustomPainter {
  CoverRegionPainter(this.image, this.orientation, this.crop, this.fit);
  final ui.Image image;
  final int orientation;
  final Map<String, dynamic>? crop;
  final BoxFit fit;
  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width.toDouble(), h = image.height.toDouble();
    final oriented = orientation >= 5 ? Size(h, w) : Size(w, h);
    final c = crop;
    final region = c == null
        ? Offset.zero & oriented
        : Rect.fromLTRB(
            ((c['x'] as num) * oriented.width).floorToDouble(),
            ((c['y'] as num) * oriented.height).floorToDouble(),
            (((c['x'] as num) + (c['width'] as num)) * oriented.width)
                .ceilToDouble()
                .clamp(0, oriented.width),
            (((c['y'] as num) + (c['height'] as num)) * oriented.height)
                .ceilToDouble()
                .clamp(0, oriented.height),
          );
    if (region.isEmpty || size.isEmpty) return;
    final fitted = applyBoxFit(fit, region.size, size);
    final src = Alignment.center.inscribe(fitted.source, region);
    final dst = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.save();
    canvas.clipRect(dst);
    canvas.translate(dst.left, dst.top);
    canvas.scale(dst.width / src.width, dst.height / src.height);
    canvas.translate(-src.left, -src.top);
    switch (orientation) {
      case 2:
        canvas.translate(w, 0);
        canvas.scale(-1, 1);
      case 3:
        canvas.translate(w, h);
        canvas.rotate(math.pi);
      case 4:
        canvas.translate(0, h);
        canvas.scale(1, -1);
      case 5:
        canvas.rotate(math.pi / 2);
        canvas.scale(1, -1);
      case 6:
        canvas.translate(h, 0);
        canvas.rotate(math.pi / 2);
      case 7:
        canvas.translate(h, w);
        canvas.rotate(math.pi / 2);
        canvas.scale(-1, 1);
      case 8:
        canvas.translate(0, w);
        canvas.rotate(-math.pi / 2);
    }
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(CoverRegionPainter old) =>
      old.image != image ||
      old.crop != crop ||
      old.fit != fit ||
      old.orientation != orientation;
}
