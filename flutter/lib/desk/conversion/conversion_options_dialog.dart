// 迁入 desk（conversion，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../dialogs.dart' show DeskAlert;

import '../../application/conversion_desktop.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

class ConversionOptionsDialog extends StatefulWidget {
  const ConversionOptionsDialog({
    super.key,
    required this.engine,
    this.format = 'AZW3',
    required this.desktop,
    this.autosave,
  });
  final String engine, format;
  final ConversionDesktop desktop;
  final WorkspaceAutosaveService? autosave;
  @override
  State<ConversionOptionsDialog> createState() =>
      _ConversionOptionsDialogState();
}

class _ConversionOptionsDialogState extends State<ConversionOptionsDialog> {
  late final controller = TextEditingController(text: widget.engine);
  bool picking = false, engineEdited = false;
  String error = '';
  String get draftKey => 'workspace/conversion-options/${widget.format}';
  @override
  void initState() {
    super.initState();
    final draft = widget.autosave?.readDraft(draftKey);
    if (draft != null) {
      controller.text = draft['engine'] as String? ?? widget.engine;
      engineEdited = draft['engineEdited'] == true;
    }
    controller.addListener(engineChanged);
  }

  void engineChanged() {
    engineEdited = true;
    saveDraft();
  }

  void saveDraft() => widget.autosave?.writeDraft(draftKey, {
    'engine': controller.text,
    'engineEdited': engineEdited,
  });

  void finish({bool apply = false}) {
    widget.autosave?.writeDraft(draftKey, null);
    Navigator.pop(
      context,
      apply
          ? {
              'engine': controller.text.trim(),
              'engineEdited': engineEdited,
            }
          : null,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> browse() async {
    setState(() {
      picking = true;
      error = '';
    });
    try {
      final path = await widget.desktop.chooseConverter();
      if (mounted && path != null) {
        controller.text = path;
        engineEdited = true;
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法选择转换器，请重试。');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !picking,
    child: DeskAlert(
      backgroundColor: context.desk.surface,
      scrollable: true,
      title: const DeskText('转换高级设置', size: 20, bold: true),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DeskText('转换器', bold: true),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              enabled: !picking,
              decoration: InputDecoration(
                labelText: widget.format == 'KFX'
                    ? 'Bokai 转换器路径'
                    : 'Kindling 转换器路径',
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: DeskButton(
                '浏览转换器',
                icon: Icons.folder_open,
                onPressed: picking ? null : browse,
              ),
            ),
            const SizedBox(height: 20),
            DeskText(
              '这些设置只用于本次转换。采用后更新输出计划，可直接转换或先检查。',
              size: 12,
              color: context.desk.ink2,
            ),
            if (error.isNotEmpty)
              DeskText(error, size: 12, color: context.desk.pen),
          ],
        ),
      ),
      actions: [
        DeskButton('取消', quiet: true, onPressed: picking ? null : finish),
        DeskButton(
          '采用设置',
          primary: true,
          onPressed: picking ? null : () => finish(apply: true),
        ),
      ],
    ),
  );
}
