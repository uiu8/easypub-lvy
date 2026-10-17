// 真机预览组件的查找与启动（V30，LAY-108）：组件在发布包 plugins/kindle-preview/，
// 用系统 Edge 以应用窗口（无地址栏）打开，使用单独的配置目录，不碰用户自己的 Edge 资料。
import 'dart:io';

abstract interface class KindlePreviewHost {
  /// 系统 Edge 的路径；找不到时为 null。
  String? findEdge();

  /// 组件目录（含 plugin.json）；找不到时为 null。
  String? findPlugin();

  Future<void> launch(String edge, Uri url);
}

class SystemKindlePreviewHost implements KindlePreviewHost {
  const SystemKindlePreviewHost();

  @override
  String? findEdge() {
    final env = Platform.environment;
    for (final root in [
      env['ProgramFiles(x86)'],
      env['ProgramFiles'],
      env['LOCALAPPDATA'],
    ]) {
      if (root == null) continue;
      final path = '$root\\Microsoft\\Edge\\Application\\msedge.exe';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  @override
  String? findPlugin() {
    // 发布包：程序目录下；开发运行：从程序目录或当前目录向上找仓库根目录。
    for (final start in [
      File(Platform.resolvedExecutable).parent,
      Directory.current,
    ]) {
      Directory? dir = start.absolute;
      for (var i = 0; i < 8 && dir != null; i++) {
        final candidate = Directory(
          '${dir.path}${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}kindle-preview',
        );
        if (File('${candidate.path}${Platform.pathSeparator}plugin.json')
            .existsSync()) {
          return candidate.path;
        }
        final parent = dir.parent;
        dir = parent.path == dir.path ? null : parent;
      }
    }
    return null;
  }

  @override
  Future<void> launch(String edge, Uri url) async {
    final profile = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'EasyPub-kindle-preview-edge',
    );
    await Process.start(edge, [
      '--app=$url',
      '--user-data-dir=${profile.path}',
      '--no-first-run',
      '--no-default-browser-check',
      '--window-size=1320,940',
    ], mode: ProcessStartMode.detached);
  }
}
