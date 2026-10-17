import 'package:flutter/material.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/conversion/conversion_page.dart';

import 'capture_frontend_rewrite_s7_test.dart' as fixture;
import 'verify_frontend_rewrite_settings_test.dart' show SettingsFake;

import 'package:easypub_desktop/application/settings_service.dart';
import 'package:flutter/foundation.dart';

class SettingsLibrary extends fixture.VisualLibrary implements SettingsService {
  final settings = SettingsFake();
  bool failLoad = false;
  @override
  ValueListenable<SettingsSnapshot> get snapshot => settings.snapshot;
  @override
  Future<bool> load() async => !failLoad;
  @override
  Future<bool> savePatch(Map<String, dynamic> patch) =>
      settings.savePatch(patch);
  @override
  Future<Map<String, dynamic>> inspectLegacy(String path) =>
      settings.inspectLegacy(path);
}

class Session extends fixture.VisualConversion {
  int committed = 0;
  @override
  Future<List<ConversionOutput>> commit(
    ConversionPreview plan, {
    required bool acknowledgeWarnings,
  }) async {
    committed++;
    return [];
  }
}

class Desktop extends fixture.VisualDesktop {
  @override
  Future<String?> chooseConverter() async => r'D:\chosen\kindling.exe';
}

void main() {
  testWidgets(
    'defaults initialize and retry failures; untouched inherited draft refreshes',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = SettingsLibrary()..failLoad = true;
      final session = Session()..request = null;
      final draft = ConversionFormDraft();
      await library.savePatch({
        'output_directory': r'D:\defaults',
        'output_format': 'MOBI',
        'kindle_converter': r'D:\selected\kindling.exe',
        'generate_cover': false,
        'check_before_conversion': true,
      });
      List<String>? initialBooks, retryBooks;
      Widget page() => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: ConversionPage(
            library: library,
            picker: fixture.VisualPicker(),
            openRepair: (_, _) {},
            desktop: Desktop(),
            session: session,
            draft: draft,
            initialBooks: initialBooks,
            retryBooks: retryBooks,
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(draft.initialized, isFalse);
      expect(find.text('开始转换'), findsNothing);
      library.failLoad = false;
      await tester.tap(find.text('重新读取默认设置'));
      await tester.pumpAndSettle();
      expect(draft.directory, r'D:\defaults');
      expect(draft.format, 'MOBI');
      expect(draft.engine, r'D:\selected\kindling.exe');
      expect(draft.generateCover, isFalse);
      expect(draft.autoCheck, isTrue);
      await tester.pumpWidget(const SizedBox());
      await library.savePatch({
        'output_format': 'EPUB',
        'output_directory': r'D:\changed',
      });
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(draft.directory, r'D:\changed');
      expect(draft.format, 'EPUB');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      final oldPlan = await session.preview(
        ConversionRequest(
          books: ['river'],
          directory: draft.directory,
          format: draft.format,
        ),
      );
      draft.manualDefaults.add('output_directory');
      draft.pendingPreview = oldPlan;
      initialBooks = ['sea'];
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(draft.selected, {'sea'});
      expect(find.text('本次书稿'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      initialBooks = null;
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(draft.selected, {'sea'});
      await tester.pumpWidget(const SizedBox());
      draft.pendingPreview = oldPlan;
      retryBooks = ['river'];
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(draft.selected, {'river'});
      expect(find.text('本次书稿'), findsOneWidget);
      expect(draft.reviewing.value, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      library.settings.dispose();
      session.changes.dispose();
    },
  );
  testWidgets(
    'short form preserves advanced settings and auto check across reentry',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = fixture.VisualLibrary(),
          session = Session(),
          desktop = Desktop();
      final draft = ConversionFormDraft();
      Widget page() => MaterialApp(
        theme: deskTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: ConversionPage(
              library: library,
              picker: fixture.VisualPicker(),
              openRepair: (_, _) {},
              desktop: desktop,
              session: session,
              draft: draft,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('已检查'), findsNWidgets(2));
      await tester.tap(find.byTooltip('转换高级设置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, r'D:\cancelled.exe');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(draft.engine, isNot(r'D:\cancelled.exe'));
      await tester.tap(find.byTooltip('转换高级设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览转换器'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用设置'));
      await tester.pumpAndSettle();
      expect(draft.engine, r'D:\chosen\kindling.exe');
      expect(session.committed, 0);
      final check = find.byType(Switch).first;
      await tester.ensureVisible(check);
      if (tester.widget<Switch>(check).value) {
        await tester.tap(check);
        await tester.pumpAndSettle();
      }
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(draft.autoCheck, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
      await tester.ensureVisible(find.text('开始转换'));
      await tester.tap(find.text('开始转换'));
      await tester.pumpAndSettle();
      expect(session.committed, 1);
      expect(session.request!.runChecks, isTrue);
      expect(session.request!.engine, r'D:\chosen\kindling.exe');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.changes.dispose();
    },
  );
  testWidgets(
    'large book selection stays lazy and both form bottoms are reachable',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = fixture.VisualLibrary(), session = Session();
      library.books.value = List.generate(
        128,
        (i) => BookSummary(
          id: 'book$i',
          title: '样书 $i',
          author: '',
          path: 'book$i.txt',
          format: 'TXT',
          chapters: 10000,
          status: '检查完成：章节及清理有待复核问题',
        ),
      );
      library.selection.value = BookSelection('book0', {'book0'});
      session.request = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: ConversionPage(
                library: library,
                picker: fixture.VisualPicker(),
                openRepair: (_, _) {},
                desktop: Desktop(),
                session: session,
                draft: ConversionFormDraft(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Checkbox).evaluate().length, lessThan(20));
      await tester.ensureVisible(find.text('原稿始终保留'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('原稿始终保留')).bottom,
        lessThanOrEqualTo(600),
      );
      await tester.ensureVisible(find.text('开始转换'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('开始转换')).bottom, lessThanOrEqualTo(600));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.changes.dispose();
    },
  );
}
