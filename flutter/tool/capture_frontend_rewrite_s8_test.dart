import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';

class DesktopFixture implements ConversionDesktop, LicenseDesktop {
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

class Picker implements BookFilePicker {
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
  testWidgets('S8 captures the real settings production route', (tester) async {
    tester.view.physicalSize = const Size(2160, 1440);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    await tester.runAsync(() async {
      final font = FontLoader('Microsoft YaHei')
        ..addFont(
          File(r'C:\Windows\Fonts\msyh.ttc')
              .readAsBytes()
              .then((bytes) => bytes.buffer.asByteData()),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
        );
      await icons.load();
    });
    final key = GlobalKey();
    final backend = PrototypeState();
    backend.globalConfiguration = {
      ...backend.globalConfiguration,
      'ui_theme': 'paper',
      'reduced_motion': false,
      'import_recursive': true,
      'import_skip_existing': true,
      'output_format': 'AZW3',
      'output_directory': r'D:\书稿\成品',
      'output_collision_policy': 'preserve',
      'output_naming': 'title_author',
      'show_output_acceptance': true,
      'attach_conversion_report': true,
      'check_after_import': true,
      'check_before_conversion': false,
      'restore_window': true,
      'generate_cover': true,
      'check_chapters': true,
      'check_duplicate_text': true,
      'check_title_length': true,
      'backup_before_change': true,
      'backup_directory': r'D:\书稿\EasyPub 备份',
      'diagnostic_logging': true,
      'kindle_converter':
          r'D:\software\EasyPub-RustFlutter\converters\kindling.exe',
    };
    backend.shelf.favoriteFolders
      ..add(r'D:\书稿\待制作')
      ..add(r'D:\书稿\文库');
    backend.globalConfiguration['favorite_folder_names'] = {
      r'D:\书稿\待制作': '待制作书稿',
      r'D:\书稿\文库': '我的文库',
    };
    backend.shelf.books.add(
      SampleBook(
        'fixture-river',
        '长河照影',
        '林间客',
        690,
        '4 组待核对',
        source: const ImportedTxt(
          path: r'D:\books\source\长河照影.txt',
          originPath: r'D:\books\source\长河照影.txt',
          sourceId: 'fixture-river-source',
          revision: 1,
          encoding: 'UTF-8',
          lines: 4,
          headings: 2,
        ),
      ),
    );
    backend.currentId = 'fixture-river';
    backend.shelf.selected
      ..clear()
      ..add('fixture-river');
    final library = LegacyLibraryAdapter(backend: backend);
    final desktop = DesktopFixture();
    addTearDown(library.dispose);
    addTearDown(backend.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          home: RewriteApp(
            library: library,
            picker: Picker(),
            conversionDesktop: desktop,
            initialLocation: '/settings',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final output = Directory('../artifacts/frontend-rewrite-s8-actual')
      ..createSync(recursive: true);
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    expect(find.text('外观与交互'), findsWidgets);
    await capture('settings-appearance');
    for (final name in const [
      '导入默认',
      '输出默认',
      '自动检查',
      '转换器',
      '数据与恢复',
      '关于与许可',
      '字段来源',
      '配置迁移',
    ]) {
      await tester.scrollUntilVisible(
        find.text(name),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
      expect(find.text(name), findsWidgets);
      await capture(switch (name) {
        '导入默认' => 'settings-import',
        '输出默认' => 'settings-output',
        '自动检查' => 'settings-checks',
        '转换器' => 'settings-tools',
        '数据与恢复' => 'settings-data',
        '关于与许可' => 'settings-about',
        '字段来源' => 'settings-origins',
        _ => 'settings-migration',
      });
    }
    expect(tester.takeException(), isNull);
  });
}
