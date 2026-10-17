import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/app_update_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_app_update_service.dart';
import 'package:easypub_desktop/desk/app/update_prompt.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/errors.dart';

/// 假更新服务：按脚本返回检查结果与下载进度，记录调用。
class FakeUpdates implements AppUpdateService {
  bool packaged = true,
      writable = true,
      failCheck = false,
      failDownload = false;
  int current = 67, latest = 68;
  int? backup;
  bool ready = false;
  final calls = <String>[];
  int _polls = 0;
  String phaseAfterPolls = 'completed';

  Map<String, Object?> get release => {
    'release': latest,
    'tag': 'v$latest-20261017',
    'date': '2026-10-17',
    'notes': '本版新增：自动更新',
    'bytes': 42 * 1024 * 1024,
  };

  @override
  Future<UpdateStatus> status() async => UpdateStatus.fromJson({
    'packaged': packaged,
    'writable': writable,
    'current_release': current,
    'ready': ready ? release : null,
    'backup_release': backup,
    'releases_url': 'https://github.com/uiu8/easypub-lvy/releases',
  });

  @override
  Future<UpdateCheck> check() async {
    calls.add('check');
    if (failCheck) throw const FormatException('连不上 GitHub。');
    return UpdateCheck.fromJson({
      'available': latest > current,
      'current_release': current,
      'latest': release,
    });
  }

  @override
  Future<UpdateProgress> download(int release) async {
    calls.add('download $release');
    _polls = 0;
    return UpdateProgress.fromJson({
      'job_id': 1,
      'phase': 'downloading',
      'received': 0,
      'total': 100,
    });
  }

  @override
  Future<UpdateProgress> poll(int jobId) async {
    _polls++;
    if (_polls < 3) {
      return UpdateProgress.fromJson({
        'job_id': jobId,
        'phase': 'downloading',
        'received': _polls * 40,
        'total': 100,
      });
    }
    if (failDownload) {
      return UpdateProgress.fromJson({
        'job_id': jobId,
        'phase': 'failed',
        'error': 'update_checksum_mismatch',
      });
    }
    if (phaseAfterPolls == 'completed') ready = true;
    return UpdateProgress.fromJson({
      'job_id': jobId,
      'phase': phaseAfterPolls,
      'received': 100,
      'total': 100,
    });
  }

  @override
  Future<UpdateProgress> cancel(int jobId) async {
    calls.add('cancel');
    phaseAfterPolls = 'cancelled';
    return UpdateProgress.fromJson({'job_id': jobId, 'phase': 'downloading'});
  }

  @override
  Future<void> launch(String mode) async => calls.add('launch $mode');
}

void main() {
  late FakeUpdates fake;
  late Map<String, dynamic> config;
  late bool blocked, exited;
  AppUpdateController controller() => AppUpdateController(
    service: fake,
    readConfig: () => config,
    saveConfig: (patch) async {
      config.addAll(patch);
      return true;
    },
    blockedByTasks: () => blocked,
    exitApp: () async => exited = true,
    pollInterval: const Duration(milliseconds: 5),
  );
  setUp(() {
    fake = FakeUpdates();
    config = {};
    blocked = false;
    exited = false;
  });

  Widget host(
    AppUpdateController c, {
    bool leaveOk = true,
    List<String>? leaves,
  }) => MaterialApp(
    theme: deskTheme(),
    home: AppUpdateScope(
      controller: c,
      child: Scaffold(
        body: Column(
          children: [
            UpdatePill(
              controller: c,
              leave: () async {
                leaves?.add('leave');
                return leaveOk;
              },
            ),
            Expanded(
              child: SingleChildScrollView(
                child: UpdateSettingsGroup(
                  leave: () async {
                    leaves?.add('leave');
                    return leaveOk;
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('启动时自动检查：新版本提示 → 下载进度 → 待重启 → 重启并更新', (t) async {
    final c = controller();
    final leaves = <String>[];
    await t.pumpWidget(host(c, leaves: leaves));
    await t.runAsync(() => c.start(delay: Duration.zero));
    await t.pump();
    expect(find.text('新版本 V68'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('update-pill')));
    await t.pumpAndSettle();
    expect(find.text('发现新版本 V68'), findsOneWidget);
    expect(find.textContaining('当前 V67'), findsOneWidget);
    expect(find.text('本版新增：自动更新'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('update-download')));
    await settle(t);
    expect(fake.calls, contains('download 68'));
    expect(c.phase, UpdatePhase.ready);
    expect(find.text('V68 已下载并校验'), findsOneWidget);
    expect(find.text('重启以更新'), findsOneWidget);

    // 有任务进行时不能重启。
    blocked = true;
    await t.tap(find.byKey(const ValueKey('update-restart')));
    await settle(t);
    expect(find.byKey(const ValueKey('update-restart-note')), findsOneWidget);
    expect(fake.calls, isNot(contains('launch update')));
    expect(exited, false);
    blocked = false;
    await t.tap(find.byKey(const ValueKey('update-restart')));
    await settle(t);
    expect(leaves, ['leave'], reason: '先走离开保护');
    expect(fake.calls.last, 'launch update');
    expect(exited, true);
  });

  testWidgets('离开保护取消时不启动更新程序', (t) async {
    fake.ready = true;
    final c = controller();
    await t.pumpWidget(host(c, leaveOk: false));
    await t.runAsync(c.refresh);
    await t.pump();
    expect(find.text('重启以更新'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('update-pill')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('update-restart')));
    await settle(t);
    expect(fake.calls, isNot(contains('launch update')));
    expect(exited, false);
    expect(find.text('已取消。'), findsOneWidget);
  });

  testWidgets('跳过这个版本：自动检查不再提示，手动检查仍会显示', (t) async {
    final c = controller();
    await t.pumpWidget(host(c));
    await t.runAsync(() => c.start(delay: Duration.zero));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('update-pill')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('update-skip')));
    await settle(t);
    expect(config['update_skipped_release'], 68);
    expect(find.byKey(const ValueKey('update-pill')), findsNothing);

    final next = controller();
    await t.runAsync(() => next.check(manual: false));
    expect(next.phase, UpdatePhase.skipped);
    await t.runAsync(() => next.check());
    expect(next.phase, UpdatePhase.available);
  });

  testWidgets('关闭“启动时检查”后不自动检查；开发版本不检查', (t) async {
    config['update_check_on_start'] = false;
    final c = controller();
    await t.runAsync(() => c.start(delay: Duration.zero));
    expect(fake.calls, isEmpty);

    config.clear();
    fake.packaged = false;
    final dev = controller();
    await t.pumpWidget(host(dev));
    await t.runAsync(() => dev.start(delay: Duration.zero));
    await t.pump();
    expect(fake.calls, isEmpty);
    expect(find.byKey(const ValueKey('update-settings-dev')), findsOneWidget);
  });

  testWidgets('检查失败：自动检查不打扰，手动检查显示原因；下载失败可以重试', (t) async {
    fake.failCheck = true;
    final c = controller();
    await t.runAsync(() => c.check(manual: false));
    expect(c.phase, UpdatePhase.idle);
    await t.runAsync(() => c.check());
    expect(c.phase, UpdatePhase.failed);
    expect(c.error, '连不上 GitHub。');

    fake.failCheck = false;
    fake.failDownload = true;
    await t.runAsync(c.retry);
    expect(c.phase, UpdatePhase.available);
    await t.pumpWidget(host(c));
    await t.tap(find.byKey(const ValueKey('update-pill')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('update-download')));
    await settle(t);
    expect(c.phase, UpdatePhase.failed);
    expect(
      find.text(deskErrorReason('update_checksum_mismatch')!),
      findsOneWidget,
    );
    fake.failDownload = false;
    await t.tap(find.byKey(const ValueKey('update-retry')));
    await settle(t);
    expect(
      fake.calls.where((c) => c.startsWith('download')).length,
      2,
      reason: '重试直接重新下载',
    );
    expect(c.phase, UpdatePhase.ready);
  });

  testWidgets('下载中可以取消，回到“有新版本”', (t) async {
    final c = controller();
    await t.pumpWidget(host(c));
    await t.runAsync(() => c.check());
    await t.pump();
    await t.tap(find.byKey(const ValueKey('update-pill')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('update-download')));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('update-progress')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('update-cancel')));
    await settle(t);
    expect(fake.calls, contains('cancel'));
    expect(c.phase, UpdatePhase.available);
  });

  testWidgets('设置页：启动时检查开关、手动检查、回退到上一版', (t) async {
    fake.backup = 66;
    fake.latest = 67;
    final c = controller();
    final leaves = <String>[];
    await t.pumpWidget(host(c, leaves: leaves));
    await t.runAsync(c.refresh);
    await t.pump();
    expect(find.byKey(const ValueKey('update-settings')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('update-auto-check')));
    await settle(t);
    expect(config['update_check_on_start'], false);

    await t.tap(find.byKey(const ValueKey('update-check')));
    await settle(t);
    expect(find.text('已是最新版本'), findsWidgets);
    await t.tap(find.widgetWithText(DeskButton, '关闭').last);
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('update-rollback')));
    await t.pumpAndSettle();
    expect(find.text('回退到 V66'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('update-rollback-confirm')));
    await settle(t);
    expect(leaves, ['leave']);
    expect(fake.calls.last, 'launch rollback');
    expect(exited, true);
  });

  group('真实 DLL', () {
    setUpAll(
      () async => RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      ),
    );

    test('状态、签名不符与缺少清单都被拒绝，没下载不能启动更新', () async {
      final root = (await Directory('../artifacts').createTemp('v68-'))
          .absolute;
      final app = Directory('${root.path}/app')..createSync();
      File('${app.path}/version.json').writeAsStringSync('{"release":67}');
      File('${app.path}/easypub_updater.exe').writeAsStringSync('stub');
      File('${app.path}/easypub_desktop.exe').writeAsStringSync('stub');

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var serveManifest = true;
      server.listen((r) {
        final path = r.uri.path;
        if (serveManifest && path.endsWith('/update-manifest.json')) {
          r.response.write('{"schema":1}');
        } else if (serveManifest &&
            path.endsWith('/update-manifest.json.sig')) {
          r.response.write('00' * 64);
        } else {
          r.response.statusCode = 404;
        }
        r.response.close();
      });
      addTearDown(server.close);
      final service = LegacyAppUpdateService(
        appDirectory: app.path,
        baseUrl: 'http://127.0.0.1:${server.port}/download',
      );

      final status = await service.status();
      expect(status.packaged, true);
      expect(status.writable, true);
      expect(status.currentRelease, 67);
      expect(status.ready, isNull);

      Future<String> reason(Future<Object?> f) async {
        try {
          await f;
        } catch (e) {
          return deskErrorText(e, '?');
        }
        return 'no error';
      }

      expect(
        await reason(service.check()),
        deskErrorReason('update_signature_invalid'),
      );
      serveManifest = false;
      expect(
        await reason(service.check()),
        deskErrorReason('update_not_found'),
      );
      expect(
        await reason(service.launch('update')),
        deskErrorReason('update_not_ready'),
      );
      expect(
        await reason(service.launch('rollback')),
        deskErrorReason('update_no_backup'),
      );
      // 程序目录没有被动过。
      expect(
        File('${app.path}/easypub_desktop.exe').readAsStringSync(),
        'stub',
      );

      final foreign = LegacyAppUpdateService(
        appDirectory: app.path,
        baseUrl: 'https://example.com/download',
      );
      expect(
        await reason(foreign.check()),
        deskErrorReason('update_source_invalid'),
      );
    });
  });
}
