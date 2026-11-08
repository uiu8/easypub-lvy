// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../tokens.dart';

/// Uses the editable's laid-out caret positions so wrapped lines retain their
/// source line number. Only visible line labels are painted during scrolling.
class CssEditor extends StatefulWidget {
  const CssEditor({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;
  @override
  State<CssEditor> createState() => _CssEditorState();
}

class _CssEditorState extends State<CssEditor> {
  final scroll = ScrollController();
  final field = GlobalKey();
  final gutter = GlobalKey();
  List<int> starts = [0];
  String? indexed;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(indexLines);
    indexLines();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void indexLines() {
    final text = widget.controller.text;
    if (indexed == text) return;
    indexed = text;
    starts = [0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) starts.add(i + 1);
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CssEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(indexLines);
      widget.controller.addListener(indexLines);
      indexed = null;
      indexLines();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(indexLines);
    scroll.dispose();
    super.dispose();
  }

  RenderEditable? editable(RenderObject? node) {
    if (node is RenderEditable) return node;
    RenderEditable? found;
    node?.visitChildren((child) {
      found ??= editable(child);
    });
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: starts.length.toString().length.clamp(2, 6) * 9.0 + 12,
          child: ClipRect(
            child: CustomPaint(
              key: gutter,
              painter: _LineNumbers(
                Listenable.merge([scroll, widget.controller]),
                () => starts,
                () => editable(field.currentContext?.findRenderObject()),
                () => gutter.currentContext?.findRenderObject() as RenderBox?,
                d.ink3,
              ),
            ),
          ),
        ),
        Expanded(
          child: TextField(
            key: field,
            controller: widget.controller,
            scrollController: scroll,
            enabled: widget.enabled,
            expands: true,
            minLines: null,
            maxLines: null,
            style: mono(14, c: d.ink).copyWith(height: 1.45),
            decoration: InputDecoration(
              filled: false,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              hintStyle: mono(14, c: d.ink3),
              hintText: 'p { text-indent: 2em; }',
            ),
            onChanged: widget.onChanged,
          ),
        ),
      ],
    );
  }
}

class _LineNumbers extends CustomPainter {
  _LineNumbers(
    Listenable listenable,
    this.starts,
    this.editable,
    this.gutter,
    this.color,
  ) : super(repaint: listenable);
  final List<int> Function() starts;
  final RenderEditable? Function() editable;
  final RenderBox? Function() gutter;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final render = editable();
    final box = gutter();
    if (render == null || box == null || !render.hasSize || !box.hasSize) {
      return;
    }
    final lines = starts();
    final origin = box.globalToLocal(render.localToGlobal(Offset.zero));
    double y(int index) =>
        origin.dy +
        render.getLocalRectForCaret(TextPosition(offset: lines[index])).top;
    var low = 0, high = lines.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (y(mid) < -24) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var i = low; i < lines.length; i++) {
      final top = y(i);
      if (top > size.height) break;
      final text = TextPainter(
        text: TextSpan(
          text: '${i + 1}'.padLeft(2, '0'),
          style: mono(14, c: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      text.paint(canvas, Offset(0, top));
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_LineNumbers oldDelegate) => true;
}
