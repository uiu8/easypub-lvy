import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:easypub_desktop/infrastructure/native_conversion_desktop.dart';

void main() {
  late Directory root;
  late NativeConversionDesktop desktop;
  final opened = <String>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('easypub-license-regression-');
    opened.clear();
    desktop = NativeConversionDesktop(
      executablePath: p.join(root.path, 'easypub_desktop.exe'),
      launchDirectory: (path) async {
        opened.add(path);
      },
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<Directory> notice(String relative) async {
    final folder = await Directory(p.join(root.path, relative))
        .create(recursive: true);
    await File(p.join(folder.path, 'LICENSE'))
        .writeAsString('synthetic notice');
    return folder;
  }

  test(
    'packaged third_party categories and dependencies resolve and open',
    () async {
      for (final category in [
        'epub_export',
        'chinese_variant',
        'fontations',
        'kindling',
      ]) {
        final folder = await notice('third_party/$category');
        final actual = await desktop.licenseDirectory(category);
        expect(p.equals(actual!, folder.path), isTrue);
        await desktop.openDirectory(actual);
        expect(p.equals(opened.last, folder.path), isTrue);
      }
      final dependencies = await desktop.licenseDirectory('dependencies');
      expect(p.equals(dependencies!, p.join(root.path, 'third_party')), isTrue);
      // Third-party notices must not be presented as the application's license.
      expect(await desktop.licenseDirectory('app'), isNull);
    },
  );
  test('explicit category licenses take priority over third_party', () async {
    final license = await notice('licenses/kindling');
    await notice('third_party/kindling');
    expect(
      p.equals((await desktop.licenseDirectory('kindling'))!, license.path),
      isTrue,
    );
    final app = await notice('licenses/app');
    expect(
      p.equals((await desktop.licenseDirectory('app'))!, app.path),
      isTrue,
    );
  });
  test(
    'missing and invalid categories never open unrelated directories',
    () async {
      await notice('third_party/kindling');
      for (final category in [
        'missing',
        '../third_party',
        '',
        r'..\third_party',
        root.path,
      ]) {
        expect(await desktop.licenseDirectory(category), isNull);
      }
      expect(opened, isEmpty);
    },
  );
}
