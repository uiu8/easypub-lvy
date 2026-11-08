import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/layout/layout_units.dart';
import 'package:easypub_desktop/desk/layout/device_preview.dart';

void main() {
  LayoutUnits units(Map<String, Object> v) => LayoutUnits({
    'layout_units_version': 1,
    'font_size': 110.0,
    'font_size_unit': '%',
    'line_height': 1.2,
    ...v,
  }, const PreviewDeviceChoice(id: 'kpw5'));
  test('pt/px equivalent throughout font, margin and paragraph resolution', () {
    final a = units({
      'font_size': 12.0,
      'font_size_unit': 'pt',
      'margin_left': 12.0,
      'margin_left_unit': 'pt',
      'paragraph_spacing': 12.0,
      'paragraph_spacing_unit': 'pt',
    });
    final b = units({
      'font_size': 16.0,
      'font_size_unit': 'px',
      'margin_left': 16.0,
      'margin_left_unit': 'px',
      'paragraph_spacing': 16.0,
      'paragraph_spacing_unit': 'px',
    });
    expect(a.font, closeTo(b.font, 1e-9));
    expect(a.metrics.lineRatio, closeTo(b.metrics.lineRatio, 1e-9));
    expect(a.margin('left'), closeTo(b.margin('left'), 1e-9));
    expect(
      a.paragraph('paragraph_spacing'),
      closeTo(b.paragraph('paragraph_spacing'), 1e-9),
    );
  });
  test('page percentages use distinct axes; paragraph percentage uses content width', () {
    final a = units({
      'margin_top': 5.0,
      'margin_top_unit': '%',
      'margin_left': 5.0,
      'margin_left_unit': '%',
      'paragraph_indent': 5.0,
      'paragraph_indent_unit': '%',
    });
    expect(a.margin('top'), 82.4);
    expect(a.margin('left'), 61.8);
    expect(
      a.paragraph('paragraph_indent'),
      closeTo(
        (1236 - a.metrics.padding.horizontal - a.margins.horizontal) * .05,
        1e-9,
      ),
    );
  });
  test(
    'em follows font and equivalent line height has same own-element metrics',
    () {
      final a = units({
        'paragraph_spacing': 2.0,
        'paragraph_spacing_unit': 'em',
      });
      final b = units({
        'font_size': 150.0,
        'paragraph_spacing': 2.0,
        'paragraph_spacing_unit': 'em',
      });
      expect(a.paragraph('paragraph_spacing'), a.font * 2);
      expect(b.paragraph('paragraph_spacing'), b.font * 2);
      expect(
        units({'line_height': 120.0, 'line_height_unit': '%'})
            .metrics
            .lineRatio,
        a.metrics.lineRatio,
      );
      expect(a.convert('font_size', 12, 'pt', 'px'), closeTo(16, 1e-9));
    },
  );
  test('old saved values keep legacy interpretation', () {
    final old = LayoutUnits({
      'font_size': 110.0,
      'font_size_unit': '%',
      'margin_left': 3.0,
      'margin_left_unit': 'px',
    }, const PreviewDeviceChoice(id: 'kpw5'));
    expect(old.modern, false);
    expect(
      old.metrics.fontPx,
      readerMetrics(const PreviewDeviceChoice(id: 'kpw5')).fontPx,
    );
    expect(old.margin('left'), 3);
    final next = LayoutUnits({
      ...old.values,
      'layout_units_version': 1,
      'margin_left': old.convert('margin_left', 3, 'px', 'pt'),
      'margin_left_unit': 'pt',
    }, old.device);
    expect(next.margin('left'), closeTo(old.margin('left'), 1e-9));
  });
}
