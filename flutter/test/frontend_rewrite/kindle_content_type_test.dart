import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/kindle_content_type.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';

import '../../tool/verify_frontend_rewrite_conversion_form_test.dart'
    as fixture;
import '../../tool/capture_frontend_rewrite_s7_test.dart' as visual;

void main() {
  test('新默认 EBOK，旧任务恢复类型，reset 清理，MOBI 不继承新的选择', () {
    final d = ConversionFormDraft()..format = 'KFX';
    expect(d.requestFor(['a']).outputOptions['document_type'], 'EBOK');
    d.adoptRequest(
      ConversionRequest(
        books: ['a'],
        directory: 'D:/out',
        format: 'AZW3',
        outputOptions: {'document_type': 'PDOC'},
      ),
      null,
    );
    expect(d.kindleContentType, 'PDOC');
    expect(d.requestFor(['a']).outputOptions['document_type'], 'PDOC');
    d.reset();
    expect(d.outputOptions, isEmpty);
    d.kindleContentType = 'PDOC';
    d.format = 'MOBI';
    expect(
      d.requestFor(['a']).outputOptions.containsKey('document_type'),
      false,
    );
    d.adoptRequest(
      ConversionRequest(books: ['a'], directory: '', format: 'KFX'),
      null,
    );
    expect(d.kindleContentType, 'default');
    d.dispose();
  });
  testWidgets('首次选 PDOC、跨格式不再提示、只给 KFX AZW3 传类型', (t) async {
    t.view.physicalSize = const Size(1440, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final l = fixture.SettingsLibrary();
    final s = fixture.Session()..request = null;
    final d = ConversionFormDraft();
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ConversionPage(
            library: l,
            picker: visual.VisualPicker(),
            openRepair: (_, _) {},
            desktop: fixture.Desktop(),
            session: s,
            draft: d,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('AZW3').first);
    await t.pumpAndSettle();
    await t.tap(find.text('改用个人文档'));
    await t.pumpAndSettle();
    expect(d.kindleContentType, 'PDOC');
    expect(
      l.snapshot.value.configuration['kindle_content_type_explained'],
      true,
    );
    expect(d.requestFor(['a']).outputOptions['document_type'], 'PDOC');
    await t.tap(find.text('KFX').first);
    await t.pumpAndSettle();
    expect(find.text('担心 Kindle 联网后删书？'), findsNothing);
    expect(find.byKey(const ValueKey('kindle-type-PDOC')), findsOneWidget);
    await t.tap(find.text('MOBI').first);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('kindle-type-PDOC')), findsNothing);
    expect(
      d.requestFor(['a']).outputOptions.containsKey('document_type'),
      false,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('首次提示窄窗和放大字体可读', (t) async {
    t.view.physicalSize = const Size(520, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: w!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showKindleContentTypeIntro(c),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text(kindleTypeNote), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(find.text('保持默认'));
    await t.pumpAndSettle();
  });
}
