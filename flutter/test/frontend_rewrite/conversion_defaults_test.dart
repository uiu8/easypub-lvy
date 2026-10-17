import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart' show DeskAlert;

import '../../tool/verify_frontend_rewrite_conversion_form_test.dart' as form;
import '../../tool/capture_frontend_rewrite_s7_test.dart' as fixture;

class DelayedDesktop extends form.Desktop {
  final converter = Completer<String?>();
  @override
  Future<String?> bundledConverter() => converter.future;
}

class DefaultsChanges extends ChangeNotifier {
  void publish() => notifyListeners();
}

class DefaultsSession extends form.Session {
  final DefaultsChanges _changes = DefaultsChanges();
  @override
  DefaultsChanges get changes => _changes;
}

class TwoDiscoveryDesktop extends form.Desktop {
  final first = Completer<String?>(), second = Completer<String?>();
  int calls = 0;
  @override
  Future<String?> bundledConverter() =>
      calls++ == 0 ? first.future : second.future;
}

void main() {
  void size(WidgetTester t) {
    t.view.physicalSize = const Size(1440, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Widget page(
    form.SettingsLibrary l,
    form.Session s,
    ConversionFormDraft d, {
    double scale = 1,
  }) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    theme: deskTheme(),
    home: Scaffold(
      body: ConversionPage(
        library: l,
        picker: fixture.VisualPicker(),
        openRepair: (_, _) {},
        desktop: form.Desktop(),
        session: s,
        draft: d,
      ),
    ),
  );
  testWidgets('KFX and Kindling paths stay separate when changing format', (
    t,
  ) async {
    size(t);
    final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
    final d = ConversionFormDraft();
    await l.savePatch({
      'output_directory': 'D:/out',
      'output_format': 'AZW3',
      'kindle_converter': 'D:/kindling.exe',
      'kfx_converter': 'D:/bokai.exe',
    });
    await t.pumpWidget(page(l, s, d));
    await t.pumpAndSettle();
    expect(d.engine, 'D:/kindling.exe');
    await t.ensureVisible(find.text('KFX').first);
    await t.tap(find.text('KFX').first);
    await t.pumpAndSettle();
    expect(d.format, 'KFX');
    expect(d.engine, 'D:/bokai.exe');
    await t.ensureVisible(find.text('AZW3').first);
    await t.tap(find.text('AZW3').first);
    await t.pumpAndSettle();
    expect(d.engine, 'D:/kindling.exe');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'untouched inherited fields use latest settings after reentry and while open',
    (t) async {
      size(t);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      await l.savePatch({
        'output_directory': 'D:/old',
        'output_format': 'EPUB',
      });
      await t.pumpWidget(page(l, s, d));
      await t.pumpAndSettle();
      expect(d.directory, 'D:/old');
      await t.pumpWidget(const SizedBox());
      await l.savePatch({
        'output_directory': 'D:/new',
        'output_format': 'MOBI',
      });
      await t.pumpWidget(page(l, s, d));
      await t.pumpAndSettle();
      expect(d.directory, 'D:/new');
      expect(d.format, 'MOBI');
      await l.savePatch({
        'output_directory': 'D:/live',
        'output_format': 'AZW3',
      });
      await t.pumpAndSettle();
      expect(d.directory, 'D:/live');
      expect(d.format, 'AZW3');
      expect(s.committed, 0);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );
  testWidgets(
    'same-value manual input stays manual while inherited fields require review',
    (t) async {
      size(t);
      t.view.physicalSize = const Size(1080, 720);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      await l.savePatch({
        'output_directory': 'D:/old',
        'output_format': 'EPUB',
      });
      await t.pumpWidget(page(l, s, d, scale: 1.3));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, 'D:/old-edited');
      await t.enterText(find.byType(TextField).first, 'D:/old');
      await t.pump();
      await l.savePatch({
        'output_directory': 'D:/new',
        'output_format': 'MOBI',
      });
      await t.pumpAndSettle();
      expect(d.directory, 'D:/old');
      expect(d.format, 'EPUB');
      await t.tap(find.text('查看默认变更'));
      await t.pumpAndSettle();
      expect(find.text('手工设置 · 保留'), findsWidgets);
      await t.tap(find.text('更新继承项并重新预览'));
      await t.pumpAndSettle();
      expect(d.directory, 'D:/old');
      expect(d.format, 'MOBI');
      expect(s.request!.directory, 'D:/old');
      expect(s.request!.format, 'MOBI');
      expect(s.committed, 0);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );
  testWidgets(
    'manual empty path survives and keeping current values pins only changed inherited fields',
    (t) async {
      size(t);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      await l.savePatch({
        'output_directory': 'D:/old',
        'output_format': 'EPUB',
      });
      await t.pumpWidget(page(l, s, d));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, '');
      await t.pump();
      await l.savePatch({
        'output_directory': 'D:/new',
        'output_format': 'MOBI',
      });
      await t.pumpAndSettle();
      await t.tap(find.text('查看默认变更'));
      await t.pumpAndSettle();
      // 提示条上也有同名按钮（OUT-066）；这里点对话框中的那个。
      await t.tap(
        find.descendant(
          of: find.byType(DeskAlert),
          matching: find.text('保留当前设置'),
        ),
      );
      await t.pumpAndSettle();
      expect(d.directory, '');
      expect(d.format, 'EPUB');
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(page(l, s, d));
      await t.pumpAndSettle();
      expect(find.text('查看默认变更'), findsNothing);
      expect(d.directory, '');
      expect(d.format, 'EPUB');
      await t.tap(find.byTooltip('默认设置与继承'));
      await t.pumpAndSettle();
      await t.tap(find.text('全部恢复默认继承'));
      await t.pumpAndSettle();
      expect(d.directory, 'D:/new');
      expect(d.format, 'MOBI');
      expect(s.committed, 0);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );
  testWidgets(
    'settings update invalidates a preview and never changes an in-flight request',
    (t) async {
      size(t);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      await l.savePatch({
        'output_directory': 'D:/old',
        'output_format': 'EPUB',
      });
      await t.pumpWidget(page(l, s, d));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('检查书稿'));
      await t.tap(find.text('检查书稿'));
      await t.pumpAndSettle();
      final frozen = s.request!;
      expect(d.reviewing.value, true);
      s.busy = true;
      s.changes.publish();
      await t.pump();
      await l.savePatch({
        'output_directory': 'D:/new',
        'output_format': 'MOBI',
      });
      await t.pump();
      expect(identical(s.request, frozen), true);
      expect(frozen.directory, 'D:/old');
      expect(d.directory, 'D:/old');
      s.busy = false;
      s.changes.publish();
      await t.pumpAndSettle();
      expect(d.reviewing.value, false);
      expect(find.text('查看默认变更'), findsOneWidget);
      expect(s.committed, 0);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );
  testWidgets(
    'a settings change during initial converter discovery wins over the older load',
    (t) async {
      size(t);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      final desktop = DelayedDesktop();
      await l.savePatch({'output_directory': 'D:/old', 'kindle_converter': ''});
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversionPage(
              library: l,
              picker: fixture.VisualPicker(),
              openRepair: (_, _) {},
              desktop: desktop,
              session: s,
              draft: d,
            ),
          ),
        ),
      );
      await t.pump();
      await l.savePatch({
        'output_directory': 'D:/latest',
        'kindle_converter': 'D:/latest-engine.exe',
        'output_format': 'MOBI',
      });
      desktop.converter.complete('D:/old-engine.exe');
      await t.pumpAndSettle();
      expect(d.directory, 'D:/latest');
      expect(d.engine, 'D:/latest-engine.exe');
      expect(d.format, 'MOBI');
      expect(s.committed, 0);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );
  testWidgets(
    'failed settings reload keeps existing values and retries without destroying draft',
    (t) async {
      size(t);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      await l.savePatch({'output_directory': 'D:/old'});
      await t.pumpWidget(page(l, s, d));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      await l.savePatch({'output_directory': 'D:/new'});
      l.failLoad = true;
      await t.pumpWidget(page(l, s, d));
      await t.pumpAndSettle();
      expect(d.directory, 'D:/old');
      expect(d.initialized, true);
      expect(find.text('重新读取默认设置'), findsOneWidget);
      l.failLoad = false;
      await t.tap(find.text('重新读取默认设置'));
      await t.pumpAndSettle();
      expect(d.directory, 'D:/new');
      expect(find.text('重新读取默认设置'), findsNothing);
      expect(s.committed, 0);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );

  testWidgets(
    'newest defaults must finish discovery before starting conversion',
    (t) async {
      size(t);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      final desktop = TwoDiscoveryDesktop();
      await l.savePatch({'output_directory': 'D:/old', 'kindle_converter': ''});
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ConversionPage(
              library: l,
              picker: fixture.VisualPicker(),
              openRepair: (_, _) {},
              desktop: desktop,
              session: s,
              draft: d,
            ),
          ),
        ),
      );
      await t.pump();
      await l.savePatch({
        'output_directory': 'D:/latest',
        'output_format': 'MOBI',
      });
      desktop.first.complete('D:/first-engine.exe');
      await t.pump();
      await t.pump();
      expect(desktop.calls, 2);
      await t.ensureVisible(find.text('开始转换'));
      await t.tap(find.text('开始转换'));
      await t.pump();
      expect(s.committed, 0);
      expect(s.request, isNull);
      desktop.second.complete('D:/new-engine.exe');
      await t.pumpAndSettle();
      expect(d.directory, 'D:/latest');
      expect(d.engine, 'D:/new-engine.exe');
      expect(s.committed, 0);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );
  testWidgets(
    'requested recheck waits for default discovery and then previews once',
    (t) async {
      size(t);
      final l = form.SettingsLibrary(), s = DefaultsSession()..request = null;
      final d = ConversionFormDraft();
      final desktop = DelayedDesktop();
      await l.savePatch({
        'output_directory': 'D:/ready',
        'kindle_converter': '',
      });
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: ConversionPage(
              library: l,
              picker: fixture.VisualPicker(),
              openRepair: (_, _) {},
              desktop: desktop,
              session: s,
              draft: d,
              recheckOnOpen: true,
            ),
          ),
        ),
      );
      await t.pump();
      expect(s.request, isNull);
      desktop.converter.complete('D:/ready-engine.exe');
      await t.pumpAndSettle();
      expect(s.request, isNotNull);
      expect(s.request!.directory, 'D:/ready');
      expect(d.reviewing.value, true);
      expect(s.committed, 0);
      final same = s.request;
      await l.savePatch({'ui_scale': 1.1});
      await t.pumpAndSettle();
      expect(identical(s.request, same), true);
      await t.pumpWidget(const SizedBox());
      l.settings.dispose();
      s.changes.dispose();
    },
  );
}
