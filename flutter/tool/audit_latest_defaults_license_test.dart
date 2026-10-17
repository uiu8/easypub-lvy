// Defect-observation probes: passing means the current gap is reproduced.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';
import 'package:easypub_desktop/infrastructure/native_conversion_desktop.dart';

import 'verify_frontend_rewrite_conversion_form_test.dart' as form;
import 'capture_frontend_rewrite_s7_test.dart' as fixture;

void main() {
  testWidgets(
    'observe untouched defaults remaining stale after settings change',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = form.SettingsLibrary();
      final session = form.Session()..request = null;
      final draft = ConversionFormDraft();
      Widget page() => MaterialApp(
        home: Scaffold(
          body: ConversionPage(
            library: library,
            picker: fixture.VisualPicker(),
            openRepair: (_, _) {},
            desktop: form.Desktop(),
            session: session,
            draft: draft,
          ),
        ),
      );
      await library.savePatch({
        'output_directory': 'D:/old-default',
        'output_format': 'EPUB',
      });
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(draft.directory, 'D:/old-default');
      await tester.pumpWidget(const SizedBox());
      await library.savePatch({
        'output_directory': 'D:/new-default',
        'output_format': 'MOBI',
      });
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(
        draft.directory,
        'D:/old-default',
        reason: 'Observed defect: no user edits, new default still ignored',
      );
      expect(draft.format, 'EPUB');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      library.settings.dispose();
      session.changes.dispose();
    },
  );
  test('observe license lookup missing real r2 packaged notices', () async {
    final root = Directory(
      '../artifacts/release/EasyPubPlusPlus-workflow-fixed-20261003-r2-win-x64',
    ).absolute;
    expect(
      File('${root.path}/third_party/chinese_variant/LICENSE-APACHE-2.0.txt')
          .existsSync(),
      true,
    );
    final desktop = NativeConversionDesktop(
      executablePath: '${root.path}/easypub_desktop.exe',
    );
    expect(
      await desktop.licenseDirectory('chinese_variant'),
      isNull,
      reason: 'Observed defect: packaged notice exists but UI adapter cannot find it',
    );
  });
}
