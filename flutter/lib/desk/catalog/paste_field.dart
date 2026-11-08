import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dialogs.dart';
import '../tokens.dart';

// 粘贴目录文本（CH-187、CH-203–207）：完整目录保存在 controller，只排版一段可编辑切片；
// 跨段撤销/重做只作用于目录文本。逻辑沿用 V3 前的 CatalogPasteField，仅换样式。

/// Keeps the whole manuscript in [controller] while laying out one editable
/// slice. Formatting occurs before EditableText lays out an incoming paste.
class CatalogPasteField extends StatefulWidget {
  const CatalogPasteField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;
  @override
  State<CatalogPasteField> createState() => _CatalogPasteFieldState();
}

class _CatalogPasteFieldState extends State<CatalogPasteField> {
  static const limit = 4096;
  final editor = TextEditingController();
  final previous = <int>[];
  final past = <(int, String, String)>[], future = <(int, String, String)>[];

  void restore(bool redo) {
    if (!widget.enabled) return;
    final from = redo ? future : past, to = redo ? past : future;
    if (from.isEmpty) return;
    final change = from.removeLast();
    final before = redo ? change.$2 : change.$3;
    final after = redo ? change.$3 : change.$2;
    final text = widget.controller.text.replaceRange(
      change.$1,
      change.$1 + before.length,
      after,
    );
    to.add(change);
    updating = true;
    try {
      widget.controller.text = text;
    } finally {
      updating = false;
    }
    setState(() {
      start = 0;
      previous.clear();
      showPage();
    });
    widget.onChanged();
  }

  void clear() {
    past.add((0, widget.controller.text, ''));
    future.clear();
    updating = true;
    try {
      widget.controller.clear();
    } finally {
      updating = false;
    }
    setState(() {
      start = 0;
      previous.clear();
      showPage();
    });
    widget.onChanged();
  }

  int start = 0, end = 0;
  bool updating = false;

  int pageEnd(String text, int from) {
    var to = (from + limit).clamp(0, text.length);
    if (to < text.length) {
      final newline = text.lastIndexOf('\n', to - 1);
      if (newline >= from) {
        to = newline + 1;
      } else if (text.codeUnitAt(to - 1) >= 0xd800 &&
          text.codeUnitAt(to - 1) <= 0xdbff) {
        to--;
      }
    }
    return to;
  }

  void showPage() {
    final text = widget.controller.text;
    start = start.clamp(0, text.length);
    end = pageEnd(text, start);
    editor.value = TextEditingValue(
      text: text.substring(start, end),
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  void externalChange() {
    if (updating) return;
    past.clear();
    future.clear();
    start = 0;
    previous.clear();
    showPage();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(externalChange);
    showPage();
  }

  @override
  void didUpdateWidget(covariant CatalogPasteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(externalChange);
      widget.controller.addListener(externalChange);
      externalChange();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(externalChange);
    editor.dispose();
    super.dispose();
  }

  TextEditingValue edit(TextEditingValue oldValue, TextEditingValue value) {
    final before = widget.controller.text.substring(start, end);
    if (before != value.text) {
      past.add((start, before, value.text));
      future.clear();
    }
    final text = widget.controller.text.replaceRange(start, end, value.text);
    updating = true;
    try {
      widget.controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: (start + value.selection.extentOffset).clamp(0, text.length),
        ),
      );
    } finally {
      updating = false;
    }
    end = pageEnd(text, start);
    final visible = text.substring(start, end);
    return TextEditingValue(
      text: visible,
      selection: TextSelection(
        baseOffset: value.selection.baseOffset.clamp(0, visible.length),
        extentOffset: value.selection.extentOffset.clamp(0, visible.length),
      ),
      composing:
          value.composing.isValid && value.composing.end <= visible.length
          ? value.composing
          : TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      UndoTextIntent: CallbackAction<UndoTextIntent>(
        onInvoke: (_) {
          restore(false);
          return null;
        },
      ),
      RedoTextIntent: CallbackAction<RedoTextIntent>(
        onInvoke: (_) {
          restore(true);
          return null;
        },
      ),
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: editor,
          enabled: widget.enabled,
          minLines: 5,
          maxLines: 8,
          inputFormatters: [TextInputFormatter.withFunction(edit)],
          onChanged: (_) {
            setState(() {});
            widget.onChanged();
          },
          style: mono(12.5, c: context.desk.ink),
          decoration: deskInput(context).copyWith(labelText: '粘贴目录文本'),
        ),
        if (start > 0 || end < widget.controller.text.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  '分段编辑 · 获取时使用全部目录（${widget.controller.text.length} 字符）',
                  style: ui(11.5, c: context.desk.ink3),
                ),
                TextButton(
                  onPressed: !widget.enabled || previous.isEmpty
                      ? null
                      : () {
                          setState(() {
                            start = previous.removeLast();
                            showPage();
                          });
                        },
                  child: const Text('上一段'),
                ),
                TextButton(
                  onPressed:
                      !widget.enabled || end >= widget.controller.text.length
                      ? null
                      : () {
                          setState(() {
                            previous.add(start);
                            start = end;
                            showPage();
                          });
                        },
                  child: const Text('下一段'),
                ),
                TextButton(
                  onPressed: !widget.enabled
                      ? null
                      : () {
                          clear();
                        },
                  child: const Text('清空目录'),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
