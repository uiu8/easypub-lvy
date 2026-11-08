import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../application/conversion_desktop.dart';

class NativeConversionDesktop
    implements
        ConversionDesktop,
        LicenseDesktop,
        OutputDirectoryDesktop,
        BookSourceDesktop,
        KfxConversionDesktop,
        ConverterFileDesktop {
  NativeConversionDesktop({
    String? executablePath,
    Future<void> Function(String)? launchDirectory,
    Future<void> Function(String)? revealFile,
  }) : executablePath = executablePath ?? Platform.resolvedExecutable,
       launchDirectory = launchDirectory ?? _launch,
       revealFile = revealFile ?? _reveal;
  Future<String>? _desktopDirectory;
  @override
  Future<String> defaultOutputDirectory() =>
      _desktopDirectory ??= _readDesktop();

  Future<String> _readDesktop() async {
    try {
      // Windows resolves redirected and OneDrive desktops through its known folder.
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        '[Console]::OutputEncoding = [Text.UTF8Encoding]::new(); [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)',
      ]);
      final path = result.stdout.toString().trim();
      if (result.exitCode != 0 || path.isEmpty || !Directory(path).isAbsolute) {
        throw const FormatException('无法取得桌面位置，请选择输出文件夹。');
      }
      return path;
    } catch (_) {
      _desktopDirectory = null;
      rethrow;
    }
  }

  final Future<void> Function(String) revealFile;
  static Future<void> _reveal(String path) async {
    await Process.start('explorer.exe', [
      '/select,',
      p.windows.normalize(path),
    ], runInShell: false);
  }

  @override
  Future<void> revealSource(String path) async {
    final file = File(path);
    if (!file.isAbsolute || !await file.exists()) {
      throw const FormatException('原文件不存在或无法访问，请核对书稿来源。');
    }
    await revealFile(file.absolute.path);
  }

  final String executablePath;
  final Future<void> Function(String) launchDirectory;
  @override
  Future<String?> bundledConverter() async {
    final candidate = File(
      '${File(executablePath).absolute.parent.path}/converters/kindling.exe',
    );
    return await candidate.exists() ? candidate.absolute.path : null;
  }

  @override
  Future<String?> bundledKfxConverter() async {
    final candidate = File(
      '${File(executablePath).absolute.parent.path}/converters/bokai.exe',
    );
    return await candidate.exists() ? candidate.absolute.path : null;
  }

  @override
  Future<bool> converterExists(String path) async {
    final file = File(path);
    return file.isAbsolute &&
        path.toLowerCase().endsWith('.exe') &&
        await file.exists();
  }

  @override
  Future<String?> chooseConverter() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '电子书转换器', extensions: ['exe']),
      ],
    );
    if (file == null) return null;
    final candidate = File(file.path);
    if (!candidate.isAbsolute ||
        !file.path.toLowerCase().endsWith('.exe') ||
        !await candidate.exists()) {
      throw const FormatException('请选择可访问的转换器 EXE 文件。');
    }
    return candidate.absolute.path;
  }

  static Future<void> _launch(String path) async {
    await Process.start('explorer.exe', [
      p.windows.normalize(path),
    ], runInShell: false);
  }

  @override
  Future<void> openDirectory(String path) async {
    final directory = Directory(path.trim());
    if (!directory.isAbsolute || !await directory.exists()) {
      throw const FormatException('输出文件夹不存在或无法访问。');
    }
    await launchDirectory(directory.absolute.path);
  }

  @override
  Future<void> openOutput(String path) async {
    final file = File(path.trim());
    if (!file.isAbsolute ||
        !RegExp(
          r'\.(epub|azw3|mobi|kfx)$',
          caseSensitive: false,
        ).hasMatch(file.path) ||
        !await file.exists()) {
      throw const FormatException('成品不存在或格式不可打开。');
    }
    await launchDirectory(file.absolute.path);
  }

  @override
  Future<String?> licenseDirectory(String category) async {
    // Resolve the layout produced by package_r2_review.ps1. Do not return
    // unrelated notices for a missing category (especially the app license).
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(category)) return null;
    final base = File(executablePath).absolute.parent.path;
    final candidates = [
      '$base/licenses/$category',
      if (category == 'dependencies') '$base/third_party',
      if (category != 'app' && category != 'dependencies')
        '$base/third_party/$category',
    ];
    for (final path in candidates) {
      final directory = Directory(path);
      if (await directory.exists()) return directory.absolute.path;
    }
    return null;
  }
}
