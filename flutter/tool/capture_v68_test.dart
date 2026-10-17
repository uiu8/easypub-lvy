import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/app_update_service.dart';
import 'package:easypub_desktop/desk/app/update_prompt.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/fonts.dart';

/// 截图用的假更新服务：下载一直停在 62%，便于截进度。
class _Fake implements AppUpdateService {
  bool ready = false;
  Map<String, Object?> get _r => {
    'release': 68,
    'tag': 'v68-20261017',
    'date': '2026-10-17',
    'notes': '本版新增\n· 自动更新：下载完重启即可，不用重新解压\n· 规则页：逐项开关、预览影响、新书默认\n\n修正\n· 规则统计停在“取消中”',
    'bytes': 44040192,
  };
  @override
  Future<UpdateStatus> status() async => UpdateStatus.fromJson({
    'packaged': true,
    'writable': true,
    'current_release': 67,
    'ready': ready ? _r : null,
    'backup_release': 66,
    'releases_url': 'https://github.com/uiu8/easypub-lvy/releases',
  });
  @override
  Future<UpdateCheck> check() async => UpdateCheck.fromJson({
    'available': true,
    'current_release': 67,
    'latest': _r,
  });
  @override
  Future<UpdateProgress> download(int release) async =>
      UpdateProgress.fromJson({
        'job_id': 1,
        'phase': 'downloading',
        'received': 27303526,
        'total': 44040192,
      });
  @override
  Future<UpdateProgress> poll(int jobId) => download(68);
  @override
  Future<UpdateProgress> cancel(int jobId) => download(68);
  @override
  Future<void> launch(String mode) async {}
}

/// V68 界面截图：顶栏提示、更新对话框各状态、设置页“版本与更新”。输出 artifacts/v68-preview/。
void main() {
  testWidgets('截图：自动更新', (t) async {
    final capture = GlobalKey();
    await t.runAsync(() async {
      await loadDeskFonts();
      for (final font in {
        'Microsoft YaHei': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons': 'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(font.value).readAsBytes().then((b) => b.buffer.asByteData()),
            ))
            .load();
      }
      Directory('../artifacts/v68-preview').createSync(recursive: true);
    });
    t.view.physicalSize = const Size(1000, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final fake = _Fake();
    final config = <String, dynamic>{};
    final c = AppUpdateController(
      service: fake,
      readConfig: () => config,
      saveConfig: (p) async {
        config.addAll(p);
        return true;
      },
      blockedByTasks: () => false,
      exitApp: () async {},
      pollInterval: const Duration(milliseconds: 50),
    );
    Future<void> shoot(String name) => t.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('../artifacts/v68-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: deskTheme(),
          home: AppUpdateScope(
            controller: c,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Text('龙游令 / 检查与修复'),
                        const Spacer(),
                        UpdatePill(controller: c, leave: () async => true),
                      ],
                    ),
                    const SizedBox(height: 16),
                    UpdateSettingsGroup(leave: () async => true),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.runAsync(c.refresh);
    await t.runAsync(c.check);
    await t.pump();
    await shoot('settings');
    await t.tap(find.byKey(const ValueKey('update-pill')));
    await t.pumpAndSettle();
    await shoot('available');
    await t.tap(find.byKey(const ValueKey('update-download')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    await shoot('downloading');
    await t.tap(find.text('后台下载'));
    await t.pumpAndSettle();
    fake.ready = true;
    c.phase = UpdatePhase.idle;
    await t.runAsync(c.refresh);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('update-pill')));
    await t.pumpAndSettle();
    await shoot('ready');
    c.dispose();
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
  });
}
