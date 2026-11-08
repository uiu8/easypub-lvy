import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';
import 'capture_frontend_rewrite_s7_test.dart' as fixture;

void main() {
  testWidgets('library conversion uses new selection instead of previous batch', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    final library = fixture.VisualLibrary();
    library.selection.value = BookSelection('sea', {'sea'});
    await tester.pumpWidget(RewriteApp(
      library: library, picker: fixture.VisualPicker(),
      conversionDesktop: fixture.VisualDesktop(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('转换所选 1 本'));
    await tester.pumpAndSettle();
    final page = tester.widget<ConversionPage>(find.byType(ConversionPage));
    expect(page.draft.selected, {'sea'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
