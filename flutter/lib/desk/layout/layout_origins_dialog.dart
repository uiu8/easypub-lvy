// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../../application/layout_service.dart';
import '../../application/book_information_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

class LayoutOriginsDialog extends StatefulWidget {
  const LayoutOriginsDialog({
    super.key,
    required this.session,
    required this.values,
    required this.origins,
    required this.label,
    required this.valueText,
  });
  final LayoutSession session;
  final Map<String, Object?> values, origins;
  final String Function(String) label;
  final String Function(String, Object?) valueText;
  @override
  State<LayoutOriginsDialog> createState() => _LayoutOriginsDialogState();
}

class _LayoutOriginsDialogState extends State<LayoutOriginsDialog> {
  final selected = <String>{};
  bool global = false, busy = false;
  String error = '';
  BookInformationPreview? plan;
  String origin(String key) {
    final item = widget.origins[key] as Map?;
    final source =
        {
          'factory': '出厂默认',
          'global': '全局默认',
          'preset': '预设',
          'book': '本书覆盖',
          'restored_default': '已恢复默认',
          'restored_factory': '已恢复出厂默认',
          'restored_global': '恢复时的全局默认',
          'folder_rule': '文件夹规则',
        }[item?['source']] ??
        '尚未记录来源';
    return item?['preset_name'] == null
        ? source
        : '$source · ${item!['preset_name']}';
  }

  Future<void> preview() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.session.restoreFields(
        selected,
        global: global,
      );
      if (mounted) setState(() => plan = result);
    } catch (_) {
      if (mounted) setState(() => error = '无法生成恢复方案。请检查书稿状态、默认值和字段选择。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.session.apply(plan!);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          plan = null;
          error = '恢复失败或预览已过期；未采用，请重新打开来源窗口。';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      backgroundColor: context.desk.surface,
      child: SizedBox(
        width: 680,
        height: 600,
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DeskText(
                      plan == null ? '排版设置来源' : '确认按字段恢复',
                      size: 22,
                      bold: true,
                    ),
                  ),
                  IconButton(
                    onPressed: busy
                        ? null
                        : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (plan == null)
                DeskModeSwitch<bool>(
                  value: global,
                  options: const {false: '出厂默认', true: '全局默认'},
                  onChanged: busy
                      ? null
                      : (value) => setState(() => global = value),
                ),
              const SizedBox(height: 14),
              Expanded(
                child: DeskScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final key in plan == null ? layoutFields : selected)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (plan == null)
                                Checkbox(
                                  value: selected.contains(key),
                                  onChanged: busy
                                      ? null
                                      : (value) => setState(() {
                                          if (value == true &&
                                              selected.length < 13) {
                                            selected.add(key);
                                          } else if (value != true) {
                                            selected.remove(key);
                                          }
                                        }),
                                ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    DeskText(widget.label(key), bold: true),
                                    const SizedBox(height: 4),
                                    DeskText(
                                      plan == null
                                          ? '当前：${widget.valueText(key, widget.values[key])} · ${origin(key)}'
                                          : '${widget.valueText(key, plan!.before[key])} → ${widget.valueText(key, plan!.after[key])}',
                                      size: 13,
                                      color: context.desk.ink2,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                color: context.desk.accentSoft,
                child: DeskText(
                  plan == null
                      ? '按字段恢复：每次选择1至13项；其余参数保持原值。确认后计入制作历史。'
                      : '恢复到${global ? '生成预览时的全局默认' : '出厂默认'}；原始书稿不变。',
                  size: 12,
                  color: context.desk.accent,
                ),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DeskText(error),
                ),
              const SizedBox(height: 22),
              Row(
                children: [
                  DeskButton(
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
                  const Spacer(),
                  DeskButton(
                    plan == null ? '预览并确认' : '确认恢复',
                    primary: true,
                    onPressed: busy || (plan == null && selected.isEmpty)
                        ? null
                        : plan == null
                        ? preview
                        : apply,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
