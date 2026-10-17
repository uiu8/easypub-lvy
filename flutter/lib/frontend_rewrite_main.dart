import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'desk/fonts.dart';
import 'desk/grain.dart';
import 'desk/app/rewrite_app.dart';
import 'infrastructure/crash_log.dart';
import 'infrastructure/legacy_library_adapter.dart';
import 'infrastructure/native_book_picker.dart';
import 'src/rust/frb_generated.dart';

/// Production desktop entry; restore the persisted workspace before mounting UI.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settingsDirectory =
      '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}/EasyPub-RustFlutter/settings';
  // 本地崩溃日志（V22）：未捕获的错误写入设置目录 crash-logs/，不上传。
  CrashLog('$settingsDirectory/crash-logs').install();
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  // 字体与纸纹和 Rust 初始化并行；字体缺失时主题自动回落到微软雅黑。
  await Future.wait([RustLib.init(), loadDeskFonts(), prepareDeskGrain()]);
  final library = LegacyLibraryAdapter(settingsDirectory: settingsDirectory);
  await library.initializeWorkspace();
  runApp(
    ProviderScope(
      child: RewriteApp(
        library: library,
        picker: NativeBookPicker(settings: library),
      ),
    ),
  );
}
