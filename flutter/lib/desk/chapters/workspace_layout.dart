// 章节工作区分栏（CH-041–044）：按工作区可用宽度在三栏 / 两栏 / 单栏间切换。
// 侧栏改为浮层时保持挂载（Offstage），搜索词与输入不丢失。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

class DeskChapterLayout extends StatefulWidget {
  const DeskChapterLayout({
    super.key,
    required this.outline,
    required this.reader,
    required this.inspector,
    this.showAuxiliary = true,
  });
  final Widget outline, reader, inspector;

  /// 问题、记录页签占满工作区时为 false。
  final bool showAuxiliary;

  /// 目录常驻所需的工作区宽度；以下目录改为浮层。
  static const outlineBreakpoint = 820.0;

  /// 检查器常驻所需的工作区宽度；以下检查器改为浮层。
  static const inspectorBreakpoint = 1150.0;
  static const minReader = 420.0;

  @override
  State<DeskChapterLayout> createState() => DeskChapterLayoutState();
}

class DeskChapterLayoutState extends State<DeskChapterLayout> {
  final _outlineKey = GlobalKey(),
      _inspectorKey = GlobalKey(),
      _readerKey = GlobalKey();
  double outlineWidth = 272, inspectorWidth = 304;
  String? drawer;

  void toggleOutline() =>
      setState(() => drawer = drawer == 'outline' ? null : 'outline');
  void toggleInspector() =>
      setState(() => drawer = drawer == 'inspector' ? null : 'inspector');
  void showOutline() => setState(() => drawer = 'outline');
  void closePanels() {
    if (drawer != null) setState(() => drawer = null);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final d = context.desk;
      final aux = widget.showAuxiliary;
      final hasOutline =
          aux && c.maxWidth >= DeskChapterLayout.outlineBreakpoint;
      final hasInspector =
          aux && c.maxWidth >= DeskChapterLayout.inspectorBreakpoint;
      final lw = outlineWidth.clamp(
        240.0,
        (c.maxWidth -
                (hasInspector ? inspectorWidth + 12 : 0) -
                12 -
                DeskChapterLayout.minReader)
            .clamp(240.0, 420.0),
      );
      final rw = inspectorWidth.clamp(
        260.0,
        (c.maxWidth -
                (hasOutline ? lw + 12 : 0) -
                12 -
                DeskChapterLayout.minReader)
            .clamp(260.0, 340.0),
      );
      final outline = KeyedSubtree(key: _outlineKey, child: widget.outline);
      final inspector = KeyedSubtree(
        key: _inspectorKey,
        child: widget.inspector,
      );
      final reader = KeyedSubtree(key: _readerKey, child: widget.reader);
      final overlay =
          aux &&
          (drawer == 'outline' && !hasOutline ||
              drawer == 'inspector' && !hasInspector);
      Widget floating(Widget child, String name) => Container(
        margin: const EdgeInsets.all(8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: d.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: d.line),
          boxShadow: d.shadow2,
        ),
        child: Stack(
          children: [
            Positioned.fill(child: child),
            Positioned(
              top: 6,
              right: 6,
              child: IconButton(
                tooltip: '关闭$name',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => drawer = null),
                icon: Icon(Icons.close_rounded, size: 18, color: d.ink2),
              ),
            ),
          ],
        ),
      );
      return Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasOutline) ...[
                SizedBox(width: lw, child: outline),
                _Divider(
                  key: const ValueKey('chapter-tree-divider'),
                  label: '调整章节列表宽度',
                  onDrag: (delta) => setState(
                    () => outlineWidth = (lw + delta).clamp(240.0, 420.0),
                  ),
                ),
              ],
              Expanded(child: reader),
              if (hasInspector) ...[
                _Divider(
                  key: const ValueKey('chapter-property-divider'),
                  label: '调整章节设置宽度',
                  onDrag: (delta) => setState(
                    () => inspectorWidth = (rw - delta).clamp(260.0, 340.0),
                  ),
                ),
                SizedBox(width: rw, child: inspector),
              ],
            ],
          ),
          if (overlay)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => drawer = null),
                child: ColoredBox(color: Colors.black.withValues(alpha: .12)),
              ),
            ),
          if (!hasOutline)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: c.maxWidth.clamp(0.0, 320.0),
              child: Offstage(
                offstage: !aux || drawer != 'outline',
                child: ExcludeFocus(
                  excluding: !aux || drawer != 'outline',
                  child: floating(outline, '章节列表'),
                ),
              ),
            ),
          if (!hasInspector)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: c.maxWidth.clamp(0.0, 324.0),
              child: Offstage(
                offstage: !aux || drawer != 'inspector',
                child: ExcludeFocus(
                  excluding: !aux || drawer != 'inspector',
                  child: floating(inspector, '章节设置'),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// 可拖动、可聚焦的分隔条：拖动或聚焦后左右方向键每次 16 逻辑像素。
class _Divider extends StatefulWidget {
  const _Divider({super.key, required this.label, required this.onDrag});
  final String label;
  final ValueChanged<double> onDrag;
  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> {
  bool focused = false, hover = false;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final active = focused || hover;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: Focus(
        onFocusChange: (value) => setState(() => focused = value),
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            widget.onDrag(-16);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            widget.onDrag(16);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          label: widget.label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) =>
                widget.onDrag(details.delta.dx),
            child: SizedBox(
              width: 12,
              child: Center(
                child: AnimatedContainer(
                  duration: DeskMotion.of(context, DeskMotion.fast),
                  curve: DeskMotion.easeOut,
                  width: focused ? 3 : (hover ? 2 : 1),
                  color: active ? d.accent : d.line,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
