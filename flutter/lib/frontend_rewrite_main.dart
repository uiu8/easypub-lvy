import 'dart:io';

import 'application/storage_locations.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'desk/controls/controls.dart';
import 'desk/fonts.dart';
import 'desk/tokens.dart';
import 'desk/grain.dart';
import 'desk/app/rewrite_app.dart';
import 'desk/app/storage_rescue.dart';
import 'infrastructure/crash_log.dart';
import 'infrastructure/startup_profile.dart';
import 'infrastructure/legacy_library_adapter.dart';
import 'infrastructure/native_book_picker.dart';
import 'src/rust/frb_generated.dart';

/// 上次保存的主题（只用于启动时的底色）：读设置记录里编号最大的一份，读不到按宣纸。
String? _savedTheme(String settingsDirectory) {
  try {
    File? latest;
    var best = -1;
    for (final f in Directory(settingsDirectory).listSync()) {
      final name = f.uri.pathSegments.last;
      final m = RegExp(r'^(\d+)\.json$').firstMatch(name);
      if (f is File && m != null) {
        final n = int.parse(m.group(1)!);
        if (n > best) (best, latest) = (n, f);
      }
    }
    final text = latest?.readAsStringSync() ?? '';
    return RegExp(r'"ui_theme"\s*:\s*"(\w+)"').firstMatch(text)?.group(1);
  } catch (_) {
    return null;
  }
}

/// 启动底色：与主题同色的空白页，让窗口先出来。
class _StartupCanvas extends StatelessWidget {
  const _StartupCanvas(this.mode);
  final String mode;
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: deskTheme(mode: mode),
    debugShowCheckedModeBanner: false,
    home: Builder(builder: (c) => ColoredBox(color: c.desk.canvas)),
  );
}

/// Production desktop entry; restore the persisted workspace before mounting UI.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await startupTimed('window_manager', () => windowManager.ensureInitialized());
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  // 字体与纸纹和 Rust 初始化并行；字体缺失时主题自动回落到微软雅黑。
  await startupTimed(
    'init_parallel',
    () => Future.wait([
      startupTimed('rust_init', () => RustLib.init()),
      startupTimed('fonts', () => loadDeskFonts()),
      startupTimed('grain', () => prepareDeskGrain()),
    ]),
  );
  // 读不出数据位置记录时只显示救援页，不新建工作区。
  try {
    await startupTimed('storage', () => StorageLocations.initialize());
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
  // 窗口先出来：恢复工作区要几百毫秒到几秒（书多时更久），这期间显示同色底。
  runApp(
    _StartupCanvas(
      deskThemeMode(
        _savedTheme(settingsDirectory),
        systemDark:
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark,
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => startupMark('canvas_frame_at'),
  );
  final library = LegacyLibraryAdapter(settingsDirectory: settingsDirectory);
  await startupTimed('workspace', () => library.initializeWorkspace());
  startupMark('before_run_app_at');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    startupMark('first_frame_at');
    writeStartupProfile();
  });
  runApp(
    ProviderScope(
      child: RewriteApp(
        library: library,
        picker: NativeBookPicker(settings: library),
      ),
    ),
  );
}
