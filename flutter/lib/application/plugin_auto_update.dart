// 插件随软件版本自动更新（测试版 8）：软件升到某一版后，把已经装在用户插件目录里的插件
// 换成随那一版发布的插件。清单有发布签名，下载、校验和解压在 Rust（op: app_update）。
// 只更新已经装了的插件，不替用户新装；启用状态和插件数据不动。
import 'dart:io';

import 'plugin_host.dart';

class PluginOffer {
  PluginOffer.fromJson(Map v)
    : id = '${v['id'] ?? ''}',
      version = '${v['version'] ?? ''}',
      exeSha256 = '${v['exe_sha256'] ?? ''}'.toLowerCase(),
      permissions = [for (final p in (v['permissions'] as List? ?? [])) '$p'];
  final String id, version, exeSha256;
  final List<String> permissions;
}

class PluginOffers {
  PluginOffers.fromJson(Map v)
    : release = v['release'] as int?,
      plugins = [
        for (final p in (v['plugins'] as List? ?? []))
          PluginOffer.fromJson(p as Map),
      ];

  /// 这些插件对应的软件批次号；最新 Release 没有插件清单时为 null。
  final int? release;
  final List<PluginOffer> plugins;
}

abstract interface class PluginUpdateService {
  /// 读最新 Release 的插件清单（签名已校验）。
  Future<PluginOffers> pluginCheck();

  /// 下载并校验插件 [id]，解压到还不存在的文件夹 [target]。
  Future<void> pluginDownload(String id, String target);
}

/// 检查并更新已装的插件，返回给用户看的一句话（没有可说的为空串）。
///
/// 规则：
/// - 软件自己还没升到清单对应的版本时不动（插件跟着软件走，不抢先）；
/// - 只管用户插件目录里已经装了的；随程序附带的和没装的不管；
/// - 插件程序的校验值和清单一样就是已经最新；
/// - 新版要的权限超出已装那一版时不自动换，留给用户在插件页手动更新后确认；
/// - 插件正在运行（可能在下载）时不打断，下次启动再换。
Future<String> updateInstalledPlugins(
  PluginUpdateService service,
  PluginRegistry registry, {
  required int? currentRelease,
}) async {
  if (currentRelease == null) return '';
  final offers = await service.pluginCheck();
  final release = offers.release;
  if (release == null || release > currentRelease) return '';
  final notes = <String>[];
  for (final offer in offers.plugins) {
    final entry = registry.find(offer.id);
    if (entry == null || !entry.removable) continue;
    if (entry.manifest.sha256 == offer.exeSha256) continue;
    final name = entry.manifest.name;
    if (offer.permissions.any((p) => !entry.manifest.permissions.contains(p))) {
      notes.add('“$name”有新版本，需要新的权限，请到插件页手动更新。');
      continue;
    }
    if (registry.isRunning(offer.id)) {
      notes.add('“$name”有新版本，正在运行，下次启动时更新。');
      continue;
    }
    final temp = await Directory.systemTemp.createTemp('easypub-plugin-');
    try {
      final staged = '${temp.path}${Platform.pathSeparator}${offer.id}';
      await service.pluginDownload(offer.id, staged);
      await registry.installFromFolder(staged);
      notes.add('“$name”已随测试版 $release 更新。');
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {
        // 临时文件夹删不掉不影响使用。
      }
    }
  }
  return notes.join('\n');
}
