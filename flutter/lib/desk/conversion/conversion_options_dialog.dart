// 迁入 desk（conversion，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../dialogs.dart' show DeskAlert, deskInput;

import '../../application/conversion_desktop.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';
import '../widgets.dart';

class ConversionOptionsDialog extends StatefulWidget {
  const ConversionOptionsDialog({
    super.key,
    required this.engine,
    this.format = 'AZW3',
    this.outputOptions = const {},
    required this.desktop,
    this.autosave,
  });
  final String engine, format;
  final Map<String, dynamic> outputOptions;
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
  late Map<String, dynamic> outputOptions = {...widget.outputOptions};
  String get draftKey => 'workspace/conversion-options/${widget.format}';
  @override
  void initState() {
    super.initState();
    final draft = widget.autosave?.readDraft(draftKey);
    if (draft != null) {
      controller.text = draft['engine'] as String? ?? widget.engine;
      engineEdited = draft['engineEdited'] == true;
      outputOptions =
          (draft['outputOptions'] as Map?)?.cast<String, dynamic>() ??
          outputOptions;
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
    if (outputOptions.isNotEmpty) 'outputOptions': outputOptions,
  });

  void finish({bool apply = false}) {
    widget.autosave?.writeDraft(draftKey, null);
    Navigator.pop(
      context,
      apply
          ? {
              'engine': controller.text.trim(),
              'engineEdited': engineEdited,
              if (outputOptions.isNotEmpty) 'outputOptions': outputOptions,
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
            for (final entry in <String, (String, Map<String, String>, String)>{
              if (widget.format == 'EPUB')
                'epub_version': (
                  'EPUB 版本',
                  {'3': 'EPUB 3', '2': 'EPUB 2'},
                  '3',
                ),
              if (widget.format == 'TXT') ...{
                'txt_encoding': (
                  'TXT 编码',
                  {'utf-8': 'UTF-8', 'gbk': 'GBK', 'big5': 'Big5'},
                  'utf-8',
                ),
                'txt_newline': (
                  'TXT 换行',
                  {'preserve': '沿用原行为', 'windows': 'Windows', 'system': '系统默认'},
                  'preserve',
                ),
              },
            }.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DeskText(entry.value.$1, bold: true),
                    const SizedBox(height: 8),
                    KeyedSubtree(
                      key: ValueKey(('conversion-option', entry.key)),
                      child: DeskSegmented<String>(
                        value: '${outputOptions[entry.key] ?? entry.value.$3}',
                        options: entry.value.$2,
                        onChanged: (value) {
                          setState(
                            () => outputOptions[entry.key] =
                                entry.key == 'epub_version'
                                ? int.parse(value)
                                : value,
                          );
                          saveDraft();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            DeskText(
              widget.format == 'KFX' ? 'Bokai 转换器' : 'Kindling 转换器',
              bold: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    enabled: !picking,
                    style: ui(13, c: context.desk.ink),
                    decoration: deskInput(context),
                  ),
                ),
                const SizedBox(width: 8),
                DeskButton(
                  '浏览…',
                  icon: Icons.folder_open,
                  onPressed: picking ? null : browse,
                ),
              ],
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
