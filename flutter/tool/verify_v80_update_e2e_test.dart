import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_app_update_service.dart';

/// V80 发布后的端到端更新验证：把真实的 V75 发布包（版本号不改）当作已安装版本，
/// 不设测试源、不带测试公钥，直接向 GitHub 发布页检查、下载 V80 并校验，最后启动 V75 自带的更新程序。
/// 更新程序在本进程退出后替换文件并打开新版本；替换结果由调用方在测试结束后检查。
/// 环境变量：EASYPUB_E2E_INSTALL（安装目录，会先清空重建）、EASYPUB_E2E_RELEASE（V75 解压目录所在的发布目录）。
void main() {
  test('V75 → V80 自动更新（GitHub 发布页、真实包与签名）', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    const installed = 'easypub-lvy-v75-20261018-win-x64';
    final release = Directory(Platform.environment['EASYPUB_E2E_RELEASE']!);
    final install = Directory(Platform.environment['EASYPUB_E2E_INSTALL']!);
    if (install.existsSync()) install.deleteSync(recursive: true);
    final result = await Process.run('robocopy', [
      '${release.path}/$installed',
      install.path,
      '/E',
      '/NFL',
      '/NDL',
      '/NJH',
      '/NJS',
    ]);
    expect(result.exitCode, lessThan(8));
    expect(
      File('${install.path}/version.json').readAsStringSync(),
      contains('"release": 75'),
    );

    // 不传 baseUrl：与用户机器上的 V75 一样访问 GitHub 发布页。
    final service = LegacyAppUpdateService(appDirectory: install.path);
    final before = await service.status();
    expect(before.packaged, true);
    expect(before.writable, true);
    expect(before.currentRelease, 75);

    final check = await service.check();
    expect(check.available, true);
    expect(check.latest.release, 80);

    var p = await service.download(80);
    while (p.active) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      p = await service.poll(p.jobId);
    }
    expect(p.phase, 'completed', reason: '${p.error}');
    final staged = await service.status();
    expect(staged.ready?.release, 80);
    await service.launch('update');
    stdout.writeln('E2E_STAGED_AND_LAUNCHED ${install.path}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
