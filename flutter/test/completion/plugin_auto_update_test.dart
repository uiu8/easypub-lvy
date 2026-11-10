// 插件随软件版本自动更新（测试版 8）：只换已装的、校验值不同的插件；软件没升到位、
// 新版要更多权限时不动；启用状态保留。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easypub_desktop/application/plugin_auto_update.dart';
import 'package:easypub_desktop/application/plugin_host.dart';
import 'package:flutter_test/flutter_test.dart';

void writePlugin(
  String folder,
  String program, {
  List<String> permissions = const ['network'],
}) {
  Directory(folder).createSync(recursive: true);
  final bytes = utf8.encode(program);
  File('$folder/plugin.exe').writeAsBytesSync(bytes);
  File('$folder/plugin.json').writeAsStringSync(
    jsonEncode({
      'id': 'booksource',
      'name': '书源下载',
      'version': '0.1.0',
      'executable': 'plugin.exe',
      'sha256': sha256.convert(bytes).toString(),
      'permissions': permissions,
      'protocol': 1,
    }),
  );
}

class FakeService implements PluginUpdateService {
  FakeService(
    this.release,
    this.program, {
    this.permissions = const ['network'],
  });
  int? release;
  String program;
  List<String> permissions;
  int downloads = 0;

  @override
  Future<PluginOffers> pluginCheck() async => PluginOffers.fromJson({
    'release': release,
    'plugins': release == null
        ? []
        : [
            {
              'id': 'booksource',
              'version': '0.2.0',
              'exe_sha256': sha256.convert(utf8.encode(program)).toString(),
              'permissions': permissions,
            },
          ],
  });

  @override
  Future<void> pluginDownload(String id, String target) async {
    downloads++;
    writePlugin(target, program, permissions: permissions);
  }
}

void main() {
  late Directory root;
  late PluginRegistry registry;
  String installed() =>
      File('${root.path}/plugins/booksource/plugin.exe').readAsStringSync();

  setUp(() {
    root = Directory.systemTemp.createTempSync('plugin-auto-update-');
    registry = PluginRegistry(
      roots: const [],
      userRoot: '${root.path}/plugins',
      dataRoot: '${root.path}/data',
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('已装插件在软件升到位后换成新版，启用状态保留', () async {
    writePlugin('${root.path}/plugins/booksource', 'old');
    await registry.setEnabled('booksource', true);
    final service = FakeService(8, 'new');

    // 软件还在旧版：插件不抢先更新。
    expect(
      await updateInstalledPlugins(service, registry, currentRelease: 7),
      '',
    );
    expect(installed(), 'old');
    expect(service.downloads, 0);
    // 不是发布包（读不到版本）：不动。
    expect(
      await updateInstalledPlugins(service, registry, currentRelease: null),
      '',
    );

    final note = await updateInstalledPlugins(
      service,
      registry,
      currentRelease: 8,
    );
    expect(note, '“书源下载”已随测试版 8 更新。');
    expect(installed(), 'new');
    expect(registry.find('booksource', fresh: true)!.enabled, isTrue);
    expect(registry.find('booksource', fresh: true)!.problem, isNull);

    // 已经是这一版：不再下载。
    expect(
      await updateInstalledPlugins(service, registry, currentRelease: 8),
      '',
    );
    expect(service.downloads, 1);
  });

  test('没装插件、要更多权限、Release 没有插件清单时都不动', () async {
    final service = FakeService(8, 'new');
    expect(
      await updateInstalledPlugins(service, registry, currentRelease: 8),
      '',
    );
    expect(Directory('${root.path}/plugins/booksource').existsSync(), isFalse);

    writePlugin('${root.path}/plugins/booksource', 'old');
    service.permissions = const ['network', 'webview'];
    expect(
      await updateInstalledPlugins(service, registry, currentRelease: 8),
      '“书源下载”有新版本，需要新的权限，请到插件页手动更新。',
    );
    expect(installed(), 'old');

    service
      ..permissions = const ['network']
      ..release = null;
    expect(
      await updateInstalledPlugins(service, registry, currentRelease: 8),
      '',
    );
    expect(installed(), 'old');
    expect(service.downloads, 0);
  });
}
