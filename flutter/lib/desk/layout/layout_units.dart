import 'package:flutter/widgets.dart';

import 'device_preview.dart';

/// Author units are resolved before the final window display scale.
class LayoutUnits {
  LayoutUnits(this.values, this.device);
  final Map values;
  final PreviewDeviceChoice device;
  bool get modern => values['layout_units_version'] == 1;
  double n(String key, double fallback) {
    final value = (values[key] as num?)?.toDouble();
    return value != null && value.isFinite ? value : fallback;
  }

  String unit(String key, String fallback) =>
      values['${key}_unit'] as String? ?? fallback;
  double get baseFont => readerMetrics(device).fontPx / 1.1;
  double get pixelScale => readerMetrics(device).cssPx;
  double length(
    double value,
    String unit, {
    required double font,
    required double percent,
  }) => switch (unit) {
    'em' => value * font,
    '%' => value * percent / 100,
    'pt' => value * 4 / 3 * pixelScale,
    _ => value * pixelScale,
  };
  double get font {
    if (!modern) {
      return readerMetrics(
        device,
        bookScale:
            (unit('font_size', 'px') == '%'
                    ? n('font_size', 110) / 110
                    : n('font_size', 18) / 17.6)
                .clamp(.3, 4),
      ).fontPx;
    }
    return length(
      n('font_size', 110),
      unit('font_size', '%'),
      font: baseFont,
      percent: baseFont,
    ).clamp(1, 2000);
  }

  double get lineRatio {
    final v = n('line_height', 1.2);
    final u = unit('line_height', 'number');
    return (u == 'number' ? v : length(v, u, font: font, percent: font) / font)
        .clamp(0.1, 1000);
  }

  ReaderMetrics get metrics => readerMetrics(
    device,
    bookScale: font / readerMetrics(device).fontPx,
    bookLineHeight: modern ? lineRatio : n('line_height', 1.2).clamp(1, 2.3),
  );
  double margin(String side) {
    final value = n('margin_$side', 0), u = unit('margin_$side', 'px');
    if (!modern) {
      return (value * (u == 'em' ? font.clamp(6, 96) : 1)).clamp(0, 120);
    }
    final viewport = device.device;
    return length(
      value,
      u,
      font: font,
      percent: (side == 'top' || side == 'bottom')
          ? viewport.viewportHeight.toDouble()
          : viewport.viewportWidth.toDouble(),
    ).clamp(0, double.infinity);
  }

  EdgeInsets get margins => EdgeInsets.fromLTRB(
    margin('left'),
    margin('top'),
    margin('right'),
    margin('bottom'),
  );
  double paragraph(String key) {
    final value = n(key, key == 'paragraph_spacing' ? 0.6 : 0);
    if (!modern) return value.clamp(0, 6) * font.clamp(6, 96);
    final width =
        device.device.viewportWidth -
        metrics.padding.horizontal -
        margins.horizontal;
    return length(
      value,
      unit(key, 'em'),
      font: font,
      percent: width.clamp(1, double.infinity),
    );
  }

  /// Current-preview conversion; future reader font changes retain the NEW unit's semantics.
  double convert(String key, double value, String from, String to) {
    final f = key == 'font_size' ? baseFont : font;
    final basis = key == 'font_size'
        ? baseFont
        : key == 'line_height'
        ? font
        : key.startsWith('margin_')
        ? ((key == 'margin_top' || key == 'margin_bottom')
                  ? device.device.viewportHeight
                  : device.device.viewportWidth)
              .toDouble()
        : (device.device.viewportWidth -
                  metrics.padding.horizontal -
                  margins.horizontal)
              .clamp(1, double.infinity)
              .toDouble();
    double resolve(double x, String u) =>
        u == 'number' ? x * font : length(x, u, font: f, percent: basis);
    final current = modern
        ? resolve(value, from)
        : key == 'font_size'
        ? font
        : key.startsWith('margin_')
        ? margin(key.substring(7))
        : key == 'line_height'
        ? value * font
        : paragraph(key);
    return current / resolve(1, to);
  }
}
