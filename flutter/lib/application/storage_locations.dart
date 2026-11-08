import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as paths;

import '../src/rust/api.dart' as api;

/// 生产入口初始化后使用 Rust 布局；未初始化的测试保留旧位置且不访问指针。
class StorageLocations {
  static Map<String, dynamic>? _layout;
  static bool get initialized => _layout != null;
  static Map<String, dynamic> get layout => Map.unmodifiable(_layout ?? {});
  static Future<Map<String, dynamic>> request(
    Map<String, Object?> value,
  ) async {
    final reply = jsonDecode(
      await api.storageText(requestJson: jsonEncode(value)),
    ) as Map;
    if (reply['ok'] != true) throw StorageException(reply['error'] as String);
    return Map<String, dynamic>.from(reply['result'] as Map);
  }

  static Future<void> initialize({String? local, String? temp}) async {
    _layout = await request({
      'op': 'initialize',
      'local': ?local,
      'temp': ?temp,
    });
  }

  /// 成品目录沿用调用方现有设置和默认规则；不会改变转换配置。
  static Future<Map<String, dynamic>> summary({
    required String outputDirectory,
    required String defaultOutputDirectory,
  }) async {
    final layout = await request({'op': 'status'});
    final usage = await request({'op': 'stats'});
    final output = await request({
      'op': 'directory.stats',
      'path': outputDirectory,
    });
    return {
      ...layout,
      'usage': usage,
      'output': {...output, 'default_path': defaultOutputDirectory},
    };
  }

  static Future<Map<String, dynamic>> configure(
    Map<String, Object?> value,
  ) async {
    _layout = await request(value);
    return layout;
  }

  static String directory(String kind, {String? settingsDirectory}) {
    final selected = (_layout?['paths'] as Map?)?[kind] as String?;
    if (selected != null) return selected;
    final local = Platform.environment['LOCALAPPDATA'];
    final root = paths.join(
      local ?? Directory.systemTemp.path,
      'EasyPub-RustFlutter',
    );
    final settings = settingsDirectory ?? paths.join(root, 'settings');
    return switch (kind) {
      'settings' => settings,
      'generated_covers' => paths.join(settings, 'generated-covers'),
      'conversion_covers' => paths.join(
        settingsDirectory ?? root,
        'conversion-covers',
      ),
      'source_recovery' => paths.join(settings, 'source-recovery'),
      'imports' =>
        local == null
            ? paths.join(Directory.systemTemp.path, 'easypub-epub-imports')
            : paths.join(root, 'imports'),
      'kindle_preview' => paths.join(
        Directory.systemTemp.path,
        'EasyPub-kindle-preview-edge',
      ),
      'plugin_data' => paths.join(root, 'plugin-data'),
      'plugins' => paths.join(root, 'plugins'),
      _ => throw ArgumentError.value(kind),
    };
  }

  static dynamic remap(dynamic value) {
    if (value is String) {
      for (final pair in (_layout?['aliases'] as List? ?? const [])) {
        final old = pair[0] as String;
        if (paths.equals(old, value) || paths.isWithin(old, value)) {
          value = paths.join(
            pair[1] as String,
            paths.relative(value, from: old),
          );
        }
      }
      return value;
    }
    if (value is List) return value.map(remap).toList();
    if (value is Map) return value.map((k, v) => MapEntry(k, remap(v)));
    return value;
  }

  static Future<String> copyImage(String path, {bool force = false}) async {
    if (!initialized || (!force && _layout?['image_mode'] == 'reference')) {
      return path;
    }
    return (await request({'op': 'asset.copy', 'path': path}))['path']
        as String;
  }

  /// 预览/解包等跨会话使用的目录保留到程序退出，清理返回 in_use。
  static final _leases = <String>{};
  static Future<String> retain(String kind, {String? settingsDirectory}) async {
    final root = directory(kind, settingsDirectory: settingsDirectory);
    if (!initialized || _leases.contains(root)) return root;
    final lease = await request({'op': 'lease.acquire', 'kind': kind});
    final actual = lease['path'] as String;
    _leases.add(actual);
    return actual;
  }
}

class StorageException implements Exception {
  const StorageException(this.code);
  final String code;
  @override
  String toString() => code;
}
