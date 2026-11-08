import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/infrastructure/legacy_app_update_service.dart';

/// V70 发布前的端到端更新验证：用真实发布包、真实签名清单（内置公钥校验，不带测试公钥），
/// 从“装好的 V69”（V70 解压目录复制一份、版本号改为 69）检查、下载、校验，最后启动更新程序。
/// 更新程序在本进程退出后替换文件并打开新版本；替换结果由调用方在测试结束后检查。
/// 环境变量：EASYPUB_E2E_INSTALL（安装目录，会先清空重建）、EASYPUB_E2E_RELEASE（发布文件所在目录）。
void main() {
  test('V69 → V70 自动更新（真实包与签名）', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    const name = 'easypub-lvy-v70-20261017-win-x64';
    final release = Directory(Platform.environment['EASYPUB_E2E_RELEASE']!);
    final install = Directory(Platform.environment['EASYPUB_E2E_INSTALL']!);
    if (install.existsSync()) install.deleteSync(recursive: true);
    // 复制解压好的 V70 当作已安装版本，并把版本号改成 69。
    final result = await Process.run('robocopy', [
      '${release.path}/$name',
      install.path,
      '/E',
      '/NFL',
      '/NDL',
      '/NJH',
      '/NJS',
    ]);
    expect(result.exitCode, lessThan(8));
    final version = File('${install.path}/version.json');
    version.writeAsStringSync(
      version.readAsStringSync().replaceFirst('"release": 70', '"release": 69'),
    );
    expect(version.readAsStringSync(), contains('"release": 69'));

    final files = {
      'update-manifest.json': File('${release.path}/$name-update/update-manifest.json'),
      'update-manifest.json.sig': File('${release.path}/$name-update/update-manifest.json.sig'),
      '$name.zip': File('${release.path}/$name.zip'),
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final f = files[r.uri.pathSegments.last];
      if (f == null) {
        r.response.statusCode = 404;
      } else {
        r.response.headers.contentLength = f.lengthSync();
        await r.response.addStream(f.openRead());
      }
      await r.response.close();
    });
    final service = LegacyAppUpdateService(
      appDirectory: install.path,
      baseUrl: 'http://127.0.0.1:${server.port}/download',
    );
    final before = await service.status();
    expect(before.packaged, true);
    expect(before.writable, true);
    expect(before.currentRelease, 69);

    final check = await service.check();
    expect(check.available, true);
    expect(check.latest.release, 70);

    var p = await service.download(70);
    while (p.active) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      p = await service.poll(p.jobId);
    }
    expect(p.phase, 'completed', reason: '${p.error}');
    final staged = await service.status();
    expect(staged.ready?.release, 70);
    await service.launch('update');
    await server.close(force: true);
    stdout.writeln('E2E_STAGED_AND_LAUNCHED ${install.path}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
