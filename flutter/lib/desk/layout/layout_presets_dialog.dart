// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../dialogs.dart' show DeskAlert, DeskDialog;

import '../../application/layout_service.dart';
import '../../application/book_information_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';
import '../widgets.dart';

class LayoutPresetsDialog extends StatefulWidget {
  const LayoutPresetsDialog({
    super.key,
    required this.session,
    required this.values,
    required this.allowApply,
    required this.label,
    required this.valueText,
    required this.pickFile,
    required this.pickDestination,
  });
  final LayoutSession session;
  final Map<String, Object?> values;
  final bool allowApply;
  final String Function(String) label;
  final String Function(String, Object?) valueText;
  final Future<String?> Function() pickFile, pickDestination;
  @override
  State<LayoutPresetsDialog> createState() => _LayoutPresetsDialogState();
}

class _LayoutPresetsDialogState extends State<LayoutPresetsDialog> {
  late List<LayoutPreset> presets = widget.session.presets;
  final name = TextEditingController();
  String search = '';
  List<LayoutPreset> get visiblePresets => presets
      .where(
        (preset) => preset.name.toLowerCase().contains(search.toLowerCase()),
      )
      .toList();
  String? selected;
  String message = '';
  bool busy = false;
  String scope = 'project';
  bool get global => scope == 'global';
  bool get local => scope == 'project';
  BookInformationPreview? plan;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => message = deskErrorText(
            error,
            '预设没有改成：参数可能超出范围，或预设文件被占用。核对排版参数后重新打开预设库。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() => run(() async {
    await widget.session.savePreset(name.text, widget.values);
    if (!mounted) return;
    setState(() {
      presets = widget.session.presets;
      selected = name.text.trim();
      message = '已加入本项目，随工作区自动保存。';
      name.clear();
      plan = null;
    });
  });
  Future<void> preview() => run(() async {
    // 内置预设（V114）不必先复制到本项目，直接按它的数值预览。
    final result = scope == 'builtin'
        ? await widget.session.previewBuiltin(selectedPreset!)
        : await widget.session.previewPreset(selected!);
    if (mounted) setState(() => plan = result);
  });

  LayoutPreset? get selectedPreset =>
      presets.where((p) => p.name == selected).firstOrNull;
  bool get canApply => local || scope == 'builtin';
  Future<void> switchScope(bool value) => run(() async {
    final next = value
        ? await widget.session.readGlobalPresets()
        : widget.session.presets;
    if (mounted) {
      setState(() {
        scope = value ? 'global' : 'project';
        presets = next;
        selected = null;
      });
    }
  });
  Future<void> rename() => run(() async {
    await widget.session.renamePreset(selected!, name.text);
    if (mounted) {
      setState(() {
        presets = widget.session.presets;
        selected = name.text.trim();
        name.clear();
        message = '预设已重命名；已有书籍的历史来源名称保留。';
      });
    }
  });
  Future<void> publish() => run(() async {
    await widget.session.readGlobalPresets();
    await widget.session.publishPreset(selected!);
    if (mounted) setState(() => message = '已保存到全局预设，其他项目可复制使用。');
  });
  Future<void> copyToProject() => run(() async {
    if (global) {
      await widget.session.copyGlobalPreset(selected!);
    } else {
      await widget.session.importPreset(
        presets.firstWhere((value) => value.name == selected),
      );
    }
    if (mounted) {
      setState(() {
        scope = 'project';
        presets = widget.session.presets;
        message = '已复制到本项目；应用到书籍仍需预览确认。';
      });
    }
  });
  Future<void> loadFile() => run(() async {
    final path = await widget.pickFile();
    if (!mounted || path == null) return;
    final loaded = await widget.session.readPresetFile(path);
    if (mounted) {
      setState(() {
        presets = loaded;
        selected = null;
        scope = 'file';
        message = '文件校验通过；选择后复制到本项目，尚未改变书籍。';
      });
    }
  });
  Future<void> exportFile() => run(() async {
    final path = await widget.pickDestination();
    if (!mounted || path == null) return;
    await widget.session.exportPresetFile(selected!, path);
    if (mounted) setState(() => message = '预设文件已导出；已有目标文件不会覆盖。');
  });
  Future<void> showBuiltin() => run(() async {
    final values = await widget.session.builtinPresets();
    if (mounted) {
      setState(() {
        presets = values;
        selected = null;
        scope = 'builtin';
      });
    }
  });
  Future<void> apply() => run(() async {
    final pack = scope == 'builtin' ? selectedPreset?.stylePack : null;
    await widget.session.apply(plan!);
    // 内置预设带的样式包（如“出版社纸书”配“素雅”）与排版页“章节样式包”同一条应用路径。
    final store = widget.session;
    if (pack != null && store is ChapterStyleStore) {
      final result = await (store as ChapterStyleStore).chapterStyleRequest({
        'action': 'builtin',
        'id': pack,
      });
      final style = (result['style'] as Map?)?.cast<String, dynamic>();
      if (style != null) {
        await widget.session.apply(
          await widget.session.preview({'chapter_style': style}),
        );
      }
    }
    if (mounted) Navigator.pop(context, true);
  });
  Future<void> remove() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => DeskAlert(
        title: Text('删除${global ? '全局' : '项目'}预设“$selected”？'),
        content: const Text('已有书籍排版保持不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除预设'),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    await run(() async {
      if (global) {
        await widget.session.deleteGlobalPreset(selected!);
      } else {
        widget.session.deletePreset(selected!);
      }
      final next = global
          ? await widget.session.readGlobalPresets()
          : widget.session.presets;
      if (!mounted) return;
      setState(() {
        presets = next;
        selected = null;
      });
    });
  }

  @override
  // 编辑台弹窗（R5-03）：统一标题与关闭按钮，Esc 关闭；内容与行为不变。
  Widget build(BuildContext context) => DeskDialog(
    title: plan == null ? '预设库' : '应用排版预设',
    closeTooltip: '关闭',
    width: 680,
    height: 580,
    busy: busy,
    escapeCloses: true,
    onClose: () => Navigator.pop(context, false),
    footerLeft: Align(
      alignment: Alignment.centerLeft,
      child: DeskButton(
        plan == null ? '取消' : '返回选择',
        quiet: true,
        onPressed: busy
            ? null
            : () {
                if (plan == null) {
                  Navigator.pop(context, false);
                } else {
                  setState(() => plan = null);
                }
              },
      ),
    ),
    actions: [
      DeskButton(
        plan == null ? '预览并确认' : '确认应用',
        primary: true,
        busy: busy,
        disabledReason: selected == null
            ? '先选择一个预设'
            : !widget.allowApply
            ? '先补全排版数值'
            : !canApply
            ? '先复制到本项目，再应用到书籍'
            : '正在处理',
        onPressed: busy || selected == null || !widget.allowApply || !canApply
            ? null
            : plan == null
            ? preview
            : apply,
      ),
    ],
    child: DeskScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plan == null)
            Wrap(
              spacing: 10,
              children: [
                DeskModeSwitch<String>(
                  value: scope,
                  options: const {
                    'project': '本项目',
                    'global': '全局预设',
                    'builtin': '内置',
                  },
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value == 'builtin') {
                            showBuiltin();
                          } else {
                            switchScope(value == 'global');
                          }
                        },
                ),
                if (global)
                  DeskButton(
                    '重新读取',
                    quiet: true,
                    onPressed: busy ? null : () => switchScope(true),
                  ),
                DeskButton(
                  '导入文件',
                  quiet: true,
                  onPressed: busy ? null : loadFile,
                ),
                if (scope == 'file') const DeskTag('已导入文件 · 待复制', Tone.warn),
              ],
            )
          else
            DeskText('$selected · 当前书', color: context.desk.accent),
          const SizedBox(height: 14),
          if (plan == null) ...[
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索预设',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (value) => setState(() => search = value),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            height: 240,
            child: plan == null
                ? visiblePresets.isEmpty
                      ? Center(
                          child: DeskText(
                            presets.isEmpty ? '尚无预设，可将当前排版另存为预设。' : '没有匹配的预设',
                          ),
                        )
                      : ListView.builder(
                          itemCount: visiblePresets.length,
                          itemBuilder: (_, index) {
                            final preset = visiblePresets[index];
                            return ListTile(
                              selected: selected == preset.name,
                              selectedTileColor: context.desk.accentSoft,
                              title: DeskText(preset.name, bold: true),
                              subtitle: DeskText(
                                preset.description.isNotEmpty
                                    ? preset.description
                                    : '排版 · ${preset.values.length} 项参数',
                                size: 12,
                                color: context.desk.ink2,
                              ),
                              onTap: busy
                                  ? null
                                  : () =>
                                        setState(() => selected = preset.name),
                            );
                          },
                        )
                : DeskScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final key in plan!.changed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Text(
                              '${widget.label(key)}\n${widget.valueText(key, plan!.before[key])}'
                              ' → ${widget.valueText(key, plan!.after[key])}',
                            ),
                          ),
                        if (plan!.changed.isEmpty) const Text('没有需要修改的字段。'),
                      ],
                    ),
                  ),
          ),
          if (plan == null && local) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('layout-preset-name'),
                    controller: name,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: '新预设名称'),
                  ),
                ),
                const SizedBox(width: 12),
                DeskButton(
                  '另存为预设',
                  icon: Icons.add,
                  onPressed: busy ? null : save,
                ),
                const SizedBox(width: 8),
                DeskButton(
                  '删除',
                  quiet: true,
                  dangerous: true,
                  onPressed: busy || selected == null ? null : remove,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              children: [
                DeskButton(
                  '重命名为输入名称',
                  quiet: true,
                  onPressed: busy || selected == null ? null : rename,
                ),
                DeskButton(
                  '保存到全局',
                  quiet: true,
                  onPressed: busy || selected == null ? null : publish,
                ),
                DeskButton(
                  '导出文件',
                  quiet: true,
                  onPressed: busy || selected == null ? null : exportFile,
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (plan == null && !local) ...[
            Wrap(
              spacing: 10,
              children: [
                DeskButton(
                  '复制到本项目',
                  onPressed: busy || selected == null ? null : copyToProject,
                ),
                if (global)
                  DeskButton(
                    '删除全局预设',
                    quiet: true,
                    dangerous: true,
                    onPressed: busy || selected == null ? null : remove,
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          Container(
            padding: const EdgeInsets.all(14),
            color: context.desk.accentSoft,
            child: DeskText(
              widget.allowApply
                  ? '应用前查看差异；预设不携带书名、封面或正文。'
                  : '补全排版数值后即可应用；当前输入也可另存为预设。',
              size: 12,
              color: context.desk.accent,
            ),
          ),
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: DeskText(message, size: 12),
            ),
        ],
      ),
    ),
  );
}
