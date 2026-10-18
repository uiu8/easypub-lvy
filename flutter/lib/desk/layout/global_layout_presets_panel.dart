// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../../application/layout_service.dart';
import '../../application/settings_service.dart';
import '../controls/controls.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../dialogs.dart';

/// The shared preset catalog is available before any book is imported.
class GlobalLayoutPresetsPanel extends StatefulWidget {
  const GlobalLayoutPresetsPanel({super.key, required this.settings});
  final SettingsService settings;

  @override
  State<GlobalLayoutPresetsPanel> createState() =>
      _GlobalLayoutPresetsPanelState();
}

class _GlobalLayoutPresetsPanelState extends State<GlobalLayoutPresetsPanel> {
  String? selected;
  String message = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    if (!widget.settings.snapshot.value.loaded) widget.settings.load();
  }

  List<Map<String, dynamic>> presets(SettingsSnapshot state) => [
    for (final value
        in state.configuration['layout_presets'] as List? ?? const [])
      Map<String, dynamic>.from(value as Map),
  ];

  Future<bool> save(List<Map<String, dynamic>> values) async {
    setState(() => busy = true);
    try {
      final ok = await widget.settings.savePatch({'layout_presets': values});
      if (mounted) {
        setState(() => message = ok ? '全局预设已保存' : '保存失败，原预设保留。');
      }
      return ok;
    } catch (_) {
      if (mounted) setState(() => message = '保存失败，请重试；原预设保留。');
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> editName({String? previous}) async {
    var enteredName = previous ?? '我的排版';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => DeskDialog(
        closeTooltip: '关闭',
        title: previous == null ? '保存当前全局默认为预设' : '重命名全局预设',
        width: 440,
        actions: [
          DeskButton('取消', onPressed: () => Navigator.pop(context)),
          DeskButton(
            '保存',
            primary: true,
            onPressed: () => Navigator.pop(context, enteredName.trim()),
          ),
        ],
        child: TextFormField(
          initialValue: enteredName,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '预设名称'),
          onChanged: (value) => enteredName = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
      ),
    );
    if (!mounted || name == null) return;
    final state = widget.settings.snapshot.value;
    final values = presets(state);
    if (name.isEmpty ||
        values.any((value) => value['name'] == name && name != previous)) {
      setState(() => message = '请输入非空且不重复的预设名称。');
      return;
    }
    if (previous == null) {
      final defaults = Map<String, dynamic>.from(
        state.configuration['layout_defaults'] as Map? ?? const {},
      );
      if (defaults.isEmpty) {
        setState(() => message = '当前使用内置默认；选择书籍后可将本书排版保存为预设。');
        return;
      }
      values.add({'name': name, 'values': defaults});
    } else {
      final index = values.indexWhere((value) => value['name'] == previous);
      if (index < 0) return;
      values[index] = {...values[index], 'name': name};
    }
    if (await save(values) && mounted) setState(() => selected = name);
  }

  Future<void> remove(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => DeskAlert(
        title: Text('删除全局预设“$name”？'),
        content: const Text('已有书籍和项目中的排版保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final values = presets(widget.settings.snapshot.value)
      ..removeWhere((value) => value['name'] == name);
    if (await save(values) && mounted) setState(() => selected = null);
  }

  String label(String key) {
    if (key.endsWith('_unit')) {
      return '${layoutNumbers[key.substring(0, key.length - 5)] ?? '字号'}单位';
    }
    return layoutNumbers[key] ??
        layoutFlags[key] ??
        {
          'font_family': '字体',
          'text_alignment': '对齐',
          'writing_mode': '书写方向',
          'vertical_digits': '竖排数字横排',
          'heading_style': '章节标题样式',
          'scene_break_style': '场景分隔',
          'first_paragraph_style': '章首段落',
          'rare_char_ruby': '生僻字注音',
          'rare_char_scope': '生僻字范围',
          'chapter_head_scope': '章首图用于',
          'chapter_head_width': '章首图宽度',
          'system_block_style': '系统提示',
          'system_styles': '系统提示样式',
          'verse_block_style': '诗词',
          'note_style': '弹出注释',
        }[key] ??
        key;
  }

  String display(Object? value) => value is bool
      ? value
            ? '开启'
            : '关闭'
      : const {
              'justify': '两端对齐',
              'start': '随文字方向',
              'left': '左对齐',
              'center': '居中',
              'right': '右对齐',
            }[value] ??
            '$value';

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<SettingsSnapshot>(
        valueListenable: widget.settings.snapshot,
        builder: (context, state, _) {
          final entries = presets(state);
          final chosen = entries
              .where((value) => value['name'] == selected)
              .firstOrNull;
          final defaults =
              state.configuration['layout_defaults'] as Map? ?? const {};
          final values = chosen?['values'] as Map? ?? defaults;
          return DeskPageFrame(
            header: const DeskPageHeader(title: '通用排版预设'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DeskText(
                    '选择上方书籍后可编辑本书排版。这里管理所有项目可用的预设，已有书籍保持原设置。',
                    size: 12,
                    color: context.desk.ink2,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      DeskButton(
                        '从全局默认创建',
                        onPressed: busy || !state.loaded || defaults.isEmpty
                            ? null
                            : editName,
                      ),
                      DeskButton(
                        '重命名',
                        onPressed: busy || chosen == null
                            ? null
                            : () => editName(previous: selected),
                      ),
                      DeskButton(
                        '删除',
                        onPressed: busy || chosen == null
                            ? null
                            : () => remove(selected!),
                      ),
                    ],
                  ),
                  if (message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: DeskText(message, size: 12),
                    ),
                  const Divider(height: 24),
                  Expanded(
                    child: DeskScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DeskChoice<String>(
                            value: selected ?? '',
                            searchable: true,
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('全局默认'),
                              ),
                              for (final entry in entries)
                                DropdownMenuItem(
                                  value: entry['name'] as String,
                                  child: Text(entry['name'] as String),
                                ),
                            ],
                            onChanged: (value) => setState(
                              () => selected = value == '' ? null : value,
                            ),
                          ),
                          const SizedBox(height: 16),
                          DeskText(
                            chosen == null
                                ? '全局默认 · 用于以后导入的书稿'
                                : '预设内容 · ${chosen['name']}',
                            bold: true,
                          ),
                          const SizedBox(height: 8),
                          if (values.isEmpty)
                            DeskText(
                              '当前使用内置默认排版。导入书籍后，可在排版页保存并发布新的全局预设。',
                              color: context.desk.ink2,
                            ),
                          for (final entry in values.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: DeskText(
                                      label(entry.key as String),
                                      size: 13,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Flexible(
                                    child: DeskText(
                                      display(entry.value),
                                      size: 13,
                                      color: context.desk.accent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}
