// 插件管理（PLG-001–004）：列出、启用 / 停用、从文件夹安装、卸载。
import 'package:flutter/material.dart';

import '../../application/plugin_host.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';

class PluginsPage extends StatefulWidget {
  const PluginsPage({
    super.key,
    required this.registry,
    required this.chooseFolder,
    this.onOpen,
  });
  final PluginRegistry registry;
  final Future<String?> Function() chooseFolder;

  /// 打开插件自己的页面（目前只有书源下载）。
  final void Function(String id)? onOpen;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  String? message;
  Tone tone = Tone.neutral;

  Future<void> _install() async {
    final folder = await widget.chooseFolder();
    if (folder == null) return;
    try {
      final e = await widget.registry.installFromFolder(folder);
      _say('已安装“${e.manifest.name}”，启用后才会运行。', Tone.ok);
    } on PluginError catch (e) {
      _say(e.message, Tone.warn);
    }
  }

  void _say(String text, Tone t) {
    if (!mounted) return;
    setState(() {
      message = text;
      tone = t;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return ValueListenableBuilder<int>(
      valueListenable: widget.registry.changes,
      builder: (context, _, _) {
        final plugins = widget.registry.scan();
        return DeskPageFrame(
          header: DeskPageHeader(
            title: '插件',
            subtitle: '插件是独立运行的程序，启用前请确认它需要的权限。',
            actions: [
              DeskButton(
                '从文件夹安装…',
                key: const ValueKey('plugin-install'),
                icon: Icons.add,
                onPressed: _install,
              ),
            ],
          ),
          child: DeskScrollView(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (message != null) ...[
                    DeskNote(message!, tone: tone),
                    const SizedBox(height: 12),
                  ],
                  if (plugins.isEmpty)
                    const DeskNote('还没有插件。可以从插件发布包解压后的文件夹安装。'),
                  for (final p in plugins)
                    Container(
                      key: ValueKey('plugin-${p.manifest.id}'),
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: d.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: d.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              DeskText(p.manifest.name, bold: true, size: 15),
                              const SizedBox(width: 8),
                              DeskText(
                                p.manifest.version,
                                color: d.ink2,
                                size: 12,
                              ),
                              const SizedBox(width: 8),
                              if (p.problem != null)
                                DeskTag('不能运行', Tone.warn)
                              else if (p.enabled)
                                DeskTag('已启用', Tone.ok),
                              const Spacer(),
                              if (p.enabled &&
                                  p.problem == null &&
                                  widget.onOpen != null)
                                DeskButton(
                                  '打开',
                                  quiet: true,
                                  onPressed: () =>
                                      widget.onOpen!(p.manifest.id),
                                ),
                              Switch(
                                key: ValueKey(
                                  'plugin-enabled-${p.manifest.id}',
                                ),
                                value: p.enabled,
                                onChanged: p.problem != null && !p.enabled
                                    ? null
                                    : (v) => widget.registry.setEnabled(
                                        p.manifest.id,
                                        v,
                                      ),
                              ),
                            ],
                          ),
                          if (p.manifest.description.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            DeskText(p.manifest.description, color: d.ink2),
                          ],
                          const SizedBox(height: 8),
                          DeskText(
                            '需要的权限：${p.manifest.permissions.map((x) => pluginPermissionLabels[x] ?? x).join('、')}',
                            size: 12,
                            color: d.ink2,
                          ),
                          if (p.problem != null) ...[
                            const SizedBox(height: 8),
                            DeskNote(p.problem!, tone: Tone.warn),
                          ],
                          if (p.removable) ...[
                            const SizedBox(height: 8),
                            DeskButton(
                              '卸载',
                              quiet: true,
                              dangerous: true,
                              onPressed: () async {
                                await widget.registry.uninstall(p.manifest.id);
                                _say(
                                  '已卸载“${p.manifest.name}”。下载的文件不受影响。',
                                  Tone.neutral,
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
