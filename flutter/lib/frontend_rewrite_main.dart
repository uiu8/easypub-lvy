import 'dart:io';

import 'application/storage_locations.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'desk/fonts.dart';
import 'desk/grain.dart';
import 'desk/app/rewrite_app.dart';
import 'desk/app/storage_rescue.dart';
import 'infrastructure/crash_log.dart';
import 'infrastructure/legacy_library_adapter.dart';
import 'infrastructure/native_book_picker.dart';
import 'src/rust/frb_generated.dart';

/// Production desktop entry; restore the persisted workspace before mounting UI.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  // 字体与纸纹和 Rust 初始化并行；字体缺失时主题自动回落到微软雅黑。
  await Future.wait([RustLib.init(), loadDeskFonts(), prepareDeskGrain()]);
  // 读不出数据位置记录时只显示救援页，不新建工作区（V104，SET-112）。
  try {
    await StorageLocations.initialize();
  } catch (error) {
    final local = Platform.environment['LOCALAPPDATA'];
    runApp(
      StorageRescueApp(
        error: error,
        pointerFolder: local == null ? null : '$local\\EasyPub-RustFlutter',
        onExit: () => windowManager.destroy(),
      ),
    );
    return;
  }
  final settingsDirectory = StorageLocations.directory('settings');
  CrashLog('$settingsDirectory/crash-logs').install();
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
