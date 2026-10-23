// 迁入 desk（settings，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import '../../application/cleanup_rule_resolution.dart';

import 'package:flutter/material.dart';

import '../dialogs.dart' show DeskAlert;

import '../../application/cleanup_service.dart';
import '../controls/controls.dart';
import '../cleanup/rule_dialog.dart';
import '../tokens.dart';
import '../errors.dart';

class AutomaticRulesEditor extends StatelessWidget {
  const AutomaticRulesEditor({
    super.key,
    required this.configuration,
    required this.save,
    required this.busy,
    this.loadPresets,
  });
  final Map<String, dynamic> configuration;
  final Future<bool> Function(Map<String, dynamic>) save;
  final bool busy;
  final Future<List<Map<String, dynamic>>> Function()? loadPresets;
  Future<void> choosePreset(BuildContext context) async {
    try {
      final values = await loadPresets!();
      if (!context.mounted) return;
      final chosen = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (c) => DeskAlert(
          title: const Text('常用检查规则'),
          content: SizedBox(
            width: 520,
            height: 360,
            child: ListView(
              children: [
                for (final p in values)
                  ListTile(
                    title: Text(p['name'] as String),
                    subtitle: Text(p['description'] as String),
                    onTap: () => Navigator.pop(c, p),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (chosen == null || !context.mounted) return;
      await store([
        ...rules,
        ...(chosen['rules'] as List).map(
          (r) => (r as Map).cast<String, dynamic>(),
        ),
      ]);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deskErrorText(e, '规则库没有读出来：规则文件可能损坏或被占用。关闭占用的程序后重新打开。'),
            ),
          ),
        );
      }
    }
  }

  List<Map<String, dynamic>> get rules =>
      resolveCleanupRules(configuration).pipeline;
  Future<bool> store(List<Map<String, dynamic>> value) =>
      save({'automatic_cleanup_pipeline': value});
  Future<void> editRule(BuildContext context, int? index) async {
    final before = rules;
    final rule = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          CleanupRuleDialog(initial: index == null ? null : before[index]),
    );
    if (rule == null) return;
    if (index == null) {
      before.add(rule);
    } else {
      before[index] = rule;
    }
    await store(before);
  }

  /// 全部启用或停用（表头三态勾选；G-067），默认状态不变。
  Future<bool> enableAll(bool enabled) => store([
    for (final old in rules)
      old['kind'] == 'configured'
          ? {...old, 'enabled': enabled}
          : {
              'kind': 'configured',
              'enabled': enabled,
              'scope': 'all',
              'rule': old,
            },
  ]);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (rules.isNotEmpty)
        SelectAllHeader(
          selected: rules.where((r) => r['enabled'] != false).length,
          total: rules.length,
          compact: false,
          padding: EdgeInsets.zero,
          note: '启用的规则',
          onChanged: busy ? null : enableAll,
        ),
      for (var i = 0; i < rules.length; i++)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Checkbox(
            value: rules[i]['enabled'] != false,
            onChanged: busy
                ? null
                : (enabled) {
                    final next = rules;
                    final old = next[i];
                    next[i] = old['kind'] == 'configured'
                        ? {...old, 'enabled': enabled}
                        : {
                            'kind': 'configured',
                            'enabled': enabled,
                            'scope': 'all',
                            'rule': old,
                          };
                    store(next);
                  },
          ),
          title: Text(cleanupLabel(rules[i])),
          subtitle: Text(
            '第 ${i + 1} 步 · ${{'all': '全文', 'body': '正文', 'headings': '标题'}[rules[i]['scope'] ?? 'all']}',
          ),
          onTap: busy ? null : () => editRule(context, i),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '上移规则',
                onPressed: busy || i == 0
                    ? null
                    : () {
                        final next = rules;
                        final r = next.removeAt(i);
                        next.insert(i - 1, r);
                        store(next);
                      },
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              IconButton(
                tooltip: '删除规则',
                onPressed: busy
                    ? null
                    : () {
                        final next = rules..removeAt(i);
                        store(next);
                      },
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
        ),
      if (rules.isEmpty) const DeskText('未启用文本检测规则'),
      Wrap(
        spacing: 8,
        children: [
          if (loadPresets != null)
            DeskButton(
              '常用检查规则',
              onPressed: busy ? null : () => choosePreset(context),
            ),
          DeskButton(
            '添加检测规则',
            onPressed: busy ? null : () => editRule(context, null),
          ),
          DeskCommandMenu<int>(
            tooltip: '采用清理预设',
            enabled: !busy,
            itemBuilder: (_) => [
              for (
                var i = 0;
                i < (configuration['cleanup_presets'] as List? ?? []).length;
                i++
              )
                PopupMenuItem(
                  height: 36,
                  value: i,
                  child: Text('${configuration['cleanup_presets'][i]['name']}'),
                ),
            ],
            onSelected: (i) => store(
              (configuration['cleanup_presets'][i]['pipeline'] as List)
                  .map((v) => (v as Map).cast<String, dynamic>())
                  .toList(),
            ),
            // 与旁边的按钮同样外观，看得出可以点（V12）。
            child: Builder(
              builder: (context) {
                final d = context.desk;
                return Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: d.surface,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: d.lineStrong),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('采用清理预设', style: ui(14, w: 500, c: d.ink)),
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more_rounded, size: 18, color: d.ink2),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ],
  );
}
