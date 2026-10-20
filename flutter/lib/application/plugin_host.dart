// 插件系统（V86）：插件是独立进程，放在插件目录里，每个插件一个子文件夹：
//   plugin.json  {"id","name","version","description","executable","sha256","permissions":[…],"protocol":1}
//   可执行文件
// 启动前核对可执行文件的 SHA-256 与清单一致；与插件之间每行一个 JSON（见 Rust 插件说明）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class PluginManifest {
  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.executable,
    required this.sha256,
    required this.permissions,
    required this.directory,
  });
  final String id, name, version, description, executable, sha256;
  final List<String> permissions;
  final String directory;

  static PluginManifest? read(Directory dir) {
    final file = File('${dir.path}${Platform.pathSeparator}plugin.json');
    if (!file.existsSync()) return null;
    try {
      final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final id = '${j['id'] ?? ''}';
      // 只认独立进程插件（有可执行文件）；网页组件（如真机预览）不在插件页里管理。
      if ('${j['executable'] ?? ''}'.isEmpty) return null;
      if (!RegExp(r'^[a-z0-9_-]{1,40}$').hasMatch(id)) return null;
      return PluginManifest(
        id: id,
        name: '${j['name'] ?? id}',
        version: '${j['version'] ?? ''}',
        description: '${j['description'] ?? ''}',
        executable: '${j['executable'] ?? ''}',
        sha256: '${j['sha256'] ?? ''}'.toLowerCase(),
        permissions: [for (final p in (j['permissions'] as List? ?? [])) '$p'],
        directory: dir.path,
      );
    } catch (_) {
      return null;
    }
  }

  String get executablePath => '$directory${Platform.pathSeparator}$executable';
}

/// 权限的中文说明（安装与插件列表里显示）。
const pluginPermissionLabels = {
  'network': '访问网络',
  'write-downloads': '写入你指定的下载文件夹',
  'webview': '使用系统 WebView2 打开网页',
  'import-library': '把下载的书加入书库（需你确认或开启自动加入）',
};

class PluginEntry {
  PluginEntry(
    this.manifest, {
    required this.enabled,
    required this.problem,
    required this.removable,
  });
  final PluginManifest manifest;
  final bool enabled;

  /// 不为空时插件不能启动（文件缺失、校验不符）。
  final String? problem;

  /// 用户目录里安装的插件才能卸载；随程序附带的只能停用。
  final bool removable;
}

class PluginRegistry {
  PluginRegistry({List<String>? roots, String? userRoot, String? dataRoot})
    : userRoot = userRoot ?? _appData('plugins'),
      dataRoot = dataRoot ?? _appData('plugin-data'),
      _extraRoots = roots ?? _defaultRoots();

  static String _appData(String name) =>
      '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}${Platform.pathSeparator}EasyPub-RustFlutter${Platform.pathSeparator}$name';

  static List<String> _defaultRoots() => [
    ?Platform.environment['EASYPUB_PLUGIN_DIR'],
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}plugins',
  ];

  static PluginRegistry instance = PluginRegistry();

  final String userRoot, dataRoot;
  final List<String> _extraRoots;
  final ValueNotifier<int> changes = ValueNotifier(0);
  final Map<String, PluginClient> _clients = {};

  File get _stateFile => File('$dataRoot${Platform.pathSeparator}plugins.json');

  Map<String, dynamic> _state() {
    try {
      return jsonDecode(_stateFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  List<PluginEntry> scan() {
    final state = _state();
    final seen = <String, PluginEntry>{};
    for (final root in [userRoot, ..._extraRoots]) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final sub in dir.listSync().whereType<Directory>()) {
        final m = PluginManifest.read(sub);
        if (m == null || seen.containsKey(m.id)) continue;
        seen[m.id] = PluginEntry(
          m,
          // 新装的插件默认停用，由用户在设置里启用。
          enabled: state['enabled']?[m.id] == true,
          problem: _problem(m),
          removable: root == userRoot,
        );
      }
    }
    return seen.values.toList()
      ..sort((a, b) => a.manifest.name.compareTo(b.manifest.name));
  }

  String? _problem(PluginManifest m) {
    final exe = File(m.executablePath);
    if (m.executable.isEmpty ||
        m.executable.contains('..') ||
        !exe.existsSync()) {
      return '找不到插件程序';
    }
    if (m.sha256.isEmpty) return '插件清单没有校验值';
    final digest = sha256.convert(exe.readAsBytesSync()).toString();
    if (digest != m.sha256) return '插件程序与清单的校验值不符（可能被改动），已阻止运行';
    return null;
  }

  PluginEntry? find(String id) {
    for (final e in scan()) {
      if (e.manifest.id == id) return e;
    }
    return null;
  }

  bool isActive(String id) {
    final e = find(id);
    return e != null && e.enabled && e.problem == null;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final state = _state();
    (state['enabled'] ??= <String, dynamic>{})[id] = enabled;
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(jsonEncode(state));
    if (!enabled) await _clients.remove(id)?.close();
    changes.value++;
  }

  /// 从文件夹安装：复制到用户插件目录（同标识的旧版本被替换），默认停用。
  Future<PluginEntry> installFromFolder(String folder) async {
    final m = PluginManifest.read(Directory(folder));
    if (m == null) throw const PluginError('这个文件夹里没有有效的 plugin.json');
    final problem = _problem(m);
    if (problem != null) throw PluginError(problem);
    await _clients.remove(m.id)?.close();
    final target = Directory('$userRoot${Platform.pathSeparator}${m.id}');
    if (target.existsSync()) await target.delete(recursive: true);
    await target.create(recursive: true);
    await for (final f in Directory(folder).list()) {
      if (f is File) {
        await f.copy(
          '${target.path}${Platform.pathSeparator}${f.uri.pathSegments.last}',
        );
      }
    }
    changes.value++;
    return find(m.id)!;
  }

  Future<void> uninstall(String id) async {
    await _clients.remove(id)?.close();
    final target = Directory('$userRoot${Platform.pathSeparator}$id');
    if (target.existsSync()) await target.delete(recursive: true);
    changes.value++;
  }

  String dataDirectory(String id) => '$dataRoot${Platform.pathSeparator}$id';

  /// 启动（或复用）插件进程。
  Future<PluginClient> client(String id) async {
    final existing = _clients[id];
    if (existing != null && !existing.closed) return existing;
    final entry = find(id);
    if (entry == null) throw const PluginError('没有安装这个插件');
    if (!entry.enabled) throw const PluginError('插件已停用，请在设置的“插件”里启用');
    if (entry.problem != null) throw PluginError(entry.problem!);
    final client = await PluginClient.start(
      entry.manifest.executablePath,
      dataDirectory(id),
    );
    _clients[id] = client;
    return client;
  }

  Future<void> closeAll() async {
    for (final c in _clients.values) {
      await c.close();
    }
    _clients.clear();
  }
}

class PluginError implements Exception {
  const PluginError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 与插件进程的连接：请求 / 回复按 id 配对，事件经 [events] 广播。
class PluginClient {
  PluginClient._(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone);
    _process.stderr.drain<void>();
  }

  static Future<PluginClient> start(String executable, String dataDir) async {
    await Directory(dataDir).create(recursive: true);
    final process = await Process.start(executable, ['--data', dataDir]);
    return PluginClient._(process);
  }

  final Process _process;
  final Map<int, Completer<dynamic>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast();
  int _next = 0;
  bool closed = false;

  Stream<Map<String, dynamic>> get events => _events.stream;

  void _onLine(String line) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (msg['event'] != null) {
      _events.add(msg);
      return;
    }
    final c = _pending.remove(msg['id']);
    if (c == null) return;
    if (msg.containsKey('error')) {
      c.completeError(PluginError('${msg['error']}'));
    } else {
      c.complete(msg['result']);
    }
  }

  void _onDone() {
    closed = true;
    for (final c in _pending.values) {
      c.completeError(const PluginError('插件进程已退出'));
    }
    _pending.clear();
  }

  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (closed) return Future.error(const PluginError('插件进程已退出'));
    final id = ++_next;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    return c.future;
  }

  Future<void> close() async {
    if (closed) return;
    try {
      await call('exit').timeout(const Duration(seconds: 2));
    } catch (_) {}
    closed = true;
    _process.kill();
  }
}
