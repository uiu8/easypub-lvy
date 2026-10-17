import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/crash_log.dart';
import 'package:easypub_desktop/application/app_info.dart';
import 'package:easypub_desktop/application/crash_log_service.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/settings/settings_page.dart';

/// V22：应用版本与本版更新（SET-066）、本地崩溃日志（SET-067）。
void main() {
  const notes = '''EasyPub++ · 编辑台版
说明更新于 2026-10-13；交付包：EasyPub-desk-v22-20261013-win-x64.zip。

本版新增（相对 V20 包）：
1. 设置 → 关于与许可显示版本号和本版更新说明。
2. 程序意外出错时，会在本机记录崩溃日志。

所有修改仍然遵循“预览 → 确认 → 复查”的顺序；原稿不会被改写。
''';

  test('读取发布包中的版本与本版更新；读不到或损坏时视为开发版本（SET-066）', () async {
    final dir = await Directory.systemTemp.createTemp('v22-info-');
    addTearDown(() => dir.delete(recursive: true));
    expect((await loadAppInfo(dir.path)).packaged, false);
    File('${dir.path}/先读我.txt').writeAsStringSync(notes);
    File('${dir.path}/version.json').writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'package': 'EasyPub-desk-v22-20261013-win-x64',
        'version': 'desk-v22',
        'date': '2026-10-13',
        'commit': 'de24d06',
        'uncommitted_changes': true,
        'notes': '先读我.txt',
      }),
    );
    final info = await loadAppInfo(dir.path);
    expect(info.packaged, true);
    expect(info.version, 'desk-v22');
    expect(info.date, '2026-10-13');
    expect(info.commit, 'de24d06');
    expect(info.uncommittedChanges, true);
    expect(info.releaseNotes, [
      '1. 设置 → 关于与许可显示版本号和本版更新说明。',
      '2. 程序意外出错时，会在本机记录崩溃日志。',
    ]);
    expect(info.notesText, notes);
    // 说明文件名只能是同目录下的文件名，不能带路径。
    File('${dir.path}/version.json').writeAsStringSync(
      jsonEncode({'version': 'desk-v22', 'notes': '../secret.txt'}),
    );
    expect((await loadAppInfo(dir.path)).notesText, '');
    File('${dir.path}/version.json').writeAsStringSync('{坏的');
    expect((await loadAppInfo(dir.path)).packaged, false);
    expect(releaseNotesFrom('没有这一节'), isEmpty);
  });

  test('崩溃日志：同步写入、新的在前、最多保留指定份数、接管框架错误（SET-067）', () async {
    final dir = await Directory.systemTemp.createTemp('v22-crash-');
    addTearDown(() => dir.delete(recursive: true));
    final log = CrashLog('${dir.path}/crash-logs', limit: 3);
    expect(log.list(), isEmpty);
    for (var i = 0; i < 5; i++) {
      log.record(StateError('第 $i 次'), StackTrace.current, source: '测试');
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final entries = log.list();
    expect(entries, hasLength(3));
    final newest = File(entries.first.path).readAsStringSync();
    expect(newest, contains('第 4 次'));
    expect(newest, contains('来源：测试'));
    expect(newest, contains('只保存在本机，不会上传'));
    expect(File(entries.last.path).readAsStringSync(), contains('第 2 次'));
    // 目录里其他文件不受影响，也不计入。
    File('${dir.path}/crash-logs/说明.txt').writeAsStringSync('x');
    expect(log.list(), hasLength(3));
    // 写不进去时静默放弃，不抛出。
    final blocked = File('${dir.path}/blocked')..writeAsStringSync('文件');
    CrashLog('${blocked.path}/crash-logs').record('错误', null, source: '测试');

    // 接管 Flutter 框架错误：记录后仍交给原来的处理。
    final previous = FlutterError.onError;
    final forwarded = <FlutterErrorDetails>[];
    FlutterError.onError = forwarded.add;
    final installed = CrashLog('${dir.path}/installed');
    try {
      installed.install();
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('框架错误'), library: '测试库'),
      );
    } finally {
      FlutterError.onError = previous;
    }
    expect(forwarded, hasLength(1));
    final recorded = installed.list();
    expect(recorded, hasLength(1));
    expect(
      File(recorded.single.path).readAsStringSync(),
      contains('来源：Flutter 框架（测试库）'),
    );
  });

  testWidgets('设置 · 关于与许可：版本、本版更新与崩溃日志（SET-066/067）', (t) async {
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    late PrototypeState state;
    late LegacyLibraryAdapter library;
    await t.runAsync(() async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = (await Directory('../artifacts').createTemp('v22-settings-'))
          .absolute
          .path;
      state = PrototypeState(settingsDirectory: '$root/settings');
      library = LegacyLibraryAdapter(backend: state);
      await library.load();
    });
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    Future<void> about(AppInfo info) async {
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: SettingsPage(
              key: ValueKey(info.packaged),
              settings: library,
              library: library,
              appInfo: () async => info,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('关于与许可').first);
      await t.pumpAndSettle();
    }

    await about(const AppInfo(packaged: false));
    expect(find.text('开发版本（未打包）'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-release-notes')), findsNothing);
    expect(find.text('还没有崩溃记录。'), findsOneWidget);
    expect(find.text('EasyPub++ 1.0.0'), findsNothing);

    await t.runAsync(() async {
      CrashLog(library.crashLogDirectory!)
          .record(StateError('界面里出的错'), StackTrace.current, source: '测试');
    });
    await about(
      AppInfo(
        packaged: true,
        version: 'desk-v22',
        date: '2026-10-13',
        commit: 'de24d06',
        uncommittedChanges: true,
        releaseNotes: releaseNotesFrom(notes),
        notesText: notes,
        notesName: '先读我.txt',
      ),
    );
    expect(find.text('desk-v22 · 2026-10-13'), findsOneWidget);
    expect(find.text('de24d06（含未提交改动）'), findsOneWidget);
    expect(find.textContaining('程序意外出错时，会在本机记录崩溃日志。'), findsOneWidget);
    await t.ensureVisible(
      find.byKey(const ValueKey('settings-release-notes-full')),
    );
    await t.tap(find.byKey(const ValueKey('settings-release-notes-full')));
    await t.pumpAndSettle();
    expect(find.textContaining('交付包：EasyPub-desk-v22'), findsOneWidget);
    await t.tap(find.text('关闭').last);
    await t.pumpAndSettle();
    expect(find.textContaining('共 1 份 · 最近一次'), findsOneWidget);
    await t.ensureVisible(
      find.byKey(const ValueKey('settings-crash-logs-latest')),
    );
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('settings-crash-logs-latest')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pumpAndSettle();
    expect(find.textContaining('界面里出的错'), findsOneWidget);
    expect(find.text('最近一份崩溃日志'), findsOneWidget);
    // 只读日志文件夹中的日志。
    await t.runAsync(() async {
      await expectLater(
        library.readCrashLog(
          CrashLogEntry(
            '${Directory.systemTemp.path}/其他.txt',
            DateTime.now(),
            1,
          ),
        ),
        throwsFormatException,
      );
    });
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
