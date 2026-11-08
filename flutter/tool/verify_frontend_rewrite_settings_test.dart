import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

import 'package:easypub_desktop/application/settings_service.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

class SettingsFake implements SettingsService, SettingsBackupService {
  final state = ValueNotifier(
    const SettingsSnapshot(
      configuration: <String, dynamic>{},
      status: '已读取',
      busy: false,
      loaded: true,
      theme: 'paper',
      reducedMotion: false,
    ),
  );
  final patches = <Map<String, dynamic>>[];
  String? lastBackup;
  @override
  ValueListenable<SettingsSnapshot> get snapshot => state;
  @override
  Future<bool> load() async => true;
  @override
  Future<bool> savePatch(Map<String, dynamic> patch) async {
    patches.add(patch);
    final next = {...state.value.configuration, ...patch};
    state.value = SettingsSnapshot(
      configuration: next,
      status: '已保存',
      busy: false,
      loaded: true,
      theme: (next['ui_theme'] as String?) ?? state.value.theme,
      reducedMotion:
          (next['reduced_motion'] as bool?) ?? state.value.reducedMotion,
    );
    return true;
  }

  @override
  Future<Map<String, dynamic>> inspectLegacy(String path) async => {
    'report': {
      'proposed_layout': {'font_size': 20, 'font_size_unit': 'px'},
    },
  };
  @override
  void dispose() => state.dispose();

  @override
  Future<String?> createBackup(String destination) async {
    lastBackup = '$destination/EasyPubPlusPlus-settings-fixture';
    return lastBackup;
  }

  @override
  Future<Map<String, dynamic>?> inspectBackup(String path) async => {
    'path': path,
    'fields': ['output_format', 'ui_theme'],
    'has_output_history': false,
  };

  @override
  Future<bool> restoreBackup(String path) async {
    await savePatch({'output_format': 'AZW3', 'ui_theme': 'night'});
    return true;
  }
}

class DesktopFake implements ConversionDesktop, LicenseDesktop {
  final opened = <String>[];
  @override
  Future<String?> bundledConverter() async =>
      r'D:\software\EasyPub-RustFlutter\converters\kindling.exe';
  @override
  Future<String?> chooseConverter() async =>
      r'D:\software\EasyPub-RustFlutter\converters\kindling.exe';
  @override
  Future<void> openDirectory(String path) async => opened.add(path);
  @override
  Future<void> openOutput(String path) async => opened.add(path);
  @override
  Future<String?> licenseDirectory(String category) async =>
      r'D:\software\EasyPub-RustFlutter\licenses';
}

class PickerFake implements BookFilePicker {
  @override
  Future<List<String>> chooseBooks() async => const [];
  @override
  Future<String?> chooseFolder() async => r'D:\books\finished';
  @override
  Future<String?> chooseProject() async => null;
  @override
  Future<String?> chooseProjectDestination() async => null;
}

void main() {
  testWidgets(
    'settings tabs expose real persisted controls and migration review',
    (tester) async {
      final settings = SettingsFake();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: SettingsPage(settings: settings, picker: PickerFake()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('深色'), findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<double>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('较大 · 115%').last);
      await tester.pumpAndSettle();
      expect(
        settings.patches.any((patch) => patch['ui_scale'] == 1.15),
        isTrue,
      );
      await tester.tap(find.text('导入默认'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('递归扫描文件夹'));
      await tester.pumpAndSettle();
      expect(
        settings.patches.any((patch) => patch['import_recursive'] == true),
        isTrue,
      );
      await tester.tap(find.text('选择文件夹…'));
      await tester.pumpAndSettle();
      expect(
        settings.patches.any(
          (patch) => patch['import_directory'] == r'D:\books\finished',
        ),
        isTrue,
      );
      await tester.tap(find.text('输出默认'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AZW3'));
      await tester.pumpAndSettle();
      expect(
        settings.patches.any((patch) => patch['output_format'] == 'AZW3'),
        isTrue,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('每次询问').last);
      await tester.pumpAndSettle();
      expect(
        settings.patches.any(
          (patch) => patch['output_collision_policy'] == 'ask',
        ),
        isTrue,
      );
      expect(find.text('完成后显示成品验收页'), findsNothing);
      await tester.ensureVisible(find.text('浏览…'));
      await tester.tap(find.text('浏览…').first);
      await tester.pumpAndSettle();
      expect(
        settings.patches.any(
          (patch) => patch['output_directory'] == r'D:\books\finished',
        ),
        isTrue,
      );
      await tester.tap(find.text('配置迁移'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), r'D:\old.json');
      await tester.ensureVisible(find.text('检查旧设置'));
      await tester.tap(find.text('检查旧设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已读取 2 项排版设置'), findsOneWidget);
      expect(find.text('字号'), findsOneWidget);
      expect(find.text('字号单位'), findsOneWidget);
      await tester.tap(find.text('确认迁移可识别字段'));
      await tester.pumpAndSettle();
      expect(
        settings.patches.any(
          (patch) =>
              patch['layout_defaults'] is Map &&
              patch['layout_defaults']['font_size'] == 20 &&
              patch['layout_defaults']['font_size_unit'] == 'px',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'settings survive adapter restart and preserve unrelated configuration',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          File(
            Platform.environment['EASYPUB_TEST_DLL'] ??
                '../target/release/easypub_bridge.dll',
          ).absolute.path,
        ),
      );
      final root = await Directory.systemTemp.createTemp(
        'easypub-settings-reopen-',
      );
      addTearDown(() => root.delete(recursive: true));
      final favoriteDir = Directory('${root.path}\\finished')
        ..createSync(recursive: true);
      await Directory('${root.path}/settings').create(recursive: true);
      final first = LegacyLibraryAdapter(
        settingsDirectory: '${root.path}/settings',
      );
      expect(await first.load(), isTrue);
      expect(
        await first.savePatch({
          'ui_theme': 'night',
          'reduced_motion': true,
          'import_recursive': true,
          'import_skip_existing': true,
          'import_directory': '${root.path}\\source',
          'check_after_import': true,
          'output_format': 'AZW3',
          'output_directory': '${root.path}\\finished',
          'output_collision_policy': 'ask',
          'output_naming': 'title_author',
          'generate_cover': false,
          'show_output_acceptance': true,
          'attach_conversion_report': true,
          'check_before_conversion': true,
          'restore_window': false,
          'check_chapters': false,
          'check_duplicate_text': true,
          'check_title_length': false,
          'backup_before_change': true,
          'backup_directory': '${root.path}\\backups',
          'diagnostic_logging': true,
          'kindle_converter': '${root.path}\\kindling.exe',
        }),
        isTrue,
        reason: first.snapshot.value.status,
      );
      first.dispose();

      final reopened = LegacyLibraryAdapter(
        settingsDirectory: '${root.path}/settings',
      );
      addTearDown(reopened.dispose);
      expect(await reopened.load(), isTrue);
      final state = reopened.snapshot.value;
      expect(state.theme, 'night');
      expect(state.reducedMotion, isTrue);
      expect(state.configuration['import_recursive'], isTrue);
      expect(state.configuration['import_skip_existing'], isTrue);
      expect(state.configuration['import_directory'], '${root.path}\\source');
      expect(state.configuration['check_after_import'], isTrue);
      expect(state.configuration['output_format'], 'AZW3');
      expect(state.configuration['output_directory'], '${root.path}\\finished');
      expect(state.configuration['output_collision_policy'], 'ask');
      expect(state.configuration['output_naming'], 'title_author');
      expect(state.configuration['generate_cover'], isFalse);
      expect(state.configuration['show_output_acceptance'], isTrue);
      expect(state.configuration['attach_conversion_report'], isTrue);
      expect(state.configuration['check_before_conversion'], isTrue);
      expect(state.configuration['restore_window'], isFalse);
      expect(state.configuration.containsKey('check_chapters'), isFalse);
      expect(state.configuration.containsKey('check_duplicate_text'), isFalse);
      expect(state.configuration.containsKey('check_title_length'), isFalse);
      expect(state.configuration['backup_before_change'], isTrue);
      expect(state.configuration['backup_directory'], '${root.path}\\backups');
      expect(state.configuration['diagnostic_logging'], isTrue);
      expect(
        state.configuration['kindle_converter'],
        '${root.path}\\kindling.exe',
      );
      expect(await reopened.setFavorite(favoriteDir.path, true), isTrue);
      expect(reopened.favoriteFolders.value, contains(favoriteDir.path));
      final backupRoot = Directory('${root.path}\\backups');
      final backupPath = await (reopened as SettingsBackupService).createBackup(
        backupRoot.path,
      );
      expect(backupPath, isNotNull);
      expect(
        Directory(backupPath!).listSync(recursive: true).whereType<File>(),
        isNotEmpty,
      );
      final backupService = reopened as SettingsBackupService;
      expect(await reopened.savePatch({'output_format': 'EPUB'}), isTrue);
      final inspection = await backupService.inspectBackup(backupPath);
      expect(inspection?['fields'], contains('output_format'));
      expect(await backupService.restoreBackup(backupPath), isTrue);
      expect(await reopened.load(), isTrue);
      expect(reopened.snapshot.value.configuration['output_format'], 'AZW3');
    },
  );

  testWidgets(
    'settings whole group closes checks, tools, backup, license, origins and migration chains',
    (tester) async {
      final settings = SettingsFake();
      final desktop = DesktopFake();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: SettingsPage(
              settings: settings,
              picker: PickerFake(),
              desktop: desktop,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('自动检查'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('行尾空白'));
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('行尾空白'),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        settings.patches.any(
          (p) =>
              p['automatic_cleanup_pipeline'] is List &&
              (p['automatic_cleanup_pipeline'] as List).first['enabled'] ==
                  false,
        ),
        isTrue,
      );

      await tester.tap(find.text('转换器'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查可用性'));
      await tester.pumpAndSettle();
      expect(find.textContaining('kindling.exe'), findsNWidgets(2));
      await tester.tap(find.text('浏览…').first);
      await tester.pumpAndSettle();
      expect(
        settings.patches.any(
          (p) => p['kindle_converter'].toString().contains('kindling.exe'),
        ),
        isTrue,
      );

      await tester.tap(find.text('数据与恢复'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览…').first);
      await tester.pumpAndSettle();
      expect(settings.lastBackup, contains('EasyPubPlusPlus-settings-fixture'));
      await tester.tap(find.text('从备份恢复…'));
      await tester.pumpAndSettle();
      expect(find.text('确认恢复设置'), findsOneWidget);
      await tester.tap(find.text('确认恢复'));
      await tester.pumpAndSettle();
      expect(settings.patches.any((p) => p['ui_theme'] == 'night'), isTrue);
      ScaffoldMessenger.of(tester.element(find.byType(SettingsPage)))
          .clearSnackBars();
      await tester.pump();

      await tester.tap(find.text('关于与许可'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看').first);
      await tester.tap(find.text('查看').first);
      await tester.pumpAndSettle();
      expect(desktop.opened, isNotEmpty);

      await tester.tap(find.text('字段来源'));
      await tester.pumpAndSettle();
      expect(find.text('元信息'), findsOneWidget);
      await tester.ensureVisible(find.text('配置迁移'));
      await tester.tap(find.text('配置迁移'));
      await tester.pumpAndSettle();
      expect(find.text('检查旧设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
