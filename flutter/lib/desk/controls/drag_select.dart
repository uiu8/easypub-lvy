// 列表拖拽多选（LIB-095/096）：
// · 从勾选列按下拖动：经过的行统一设为第一行的相反状态（连续勾选或取消）；
// · 从行的其他位置按下拖动：画出选框，框内的行加入勾选，拖回时恢复原状态；
// · 拖到列表上下边缘自动滚动；Ctrl+A 全选当前列表，Esc 清空勾选。
// 只处理鼠标与触控笔的主键拖动；点击（未超过拖动阈值）仍交给行内控件。
// 网格（书架视图，LIB-101）：给出 hitTiles 时只用选框，框住的格子加入勾选。
// 拖书进收藏夹（V84，LIB-121）：passThrough 对按下位置返回 true 时（例如按在已勾选的书上），
// 本区域不处理这次拖动，交给书本身的拖放。
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

class DragSelectRegion extends StatefulWidget {
  const DragSelectRegion({
    super.key,
    required this.scroll,
    required this.itemExtent,
    required this.ids,
    required this.isChecked,
    required this.apply,
    required this.child,
    this.topPadding = 0,
    this.checkColumnWidth = 64,
    this.onSelectAll,
    this.onClear,
    this.hitTiles,
    this.passThrough,
  });

  final ScrollController scroll;
  final double itemExtent, topPadding;

  /// 当前列表显示的行（顺序与列表一致）。
  final List<String> ids;
  final bool Function(String id) isChecked;

  /// 一次提交需要勾选与取消的行。
  final void Function(Set<String> check, Set<String> uncheck) apply;
  final Widget child;

  /// 从左侧这一宽度内按下时按“连续勾选”处理，其余位置按“选框”处理。
  final double checkColumnWidth;
  final VoidCallback? onSelectAll, onClear;

  /// 网格模式：返回与选框（内容坐标）相交的格子序号。
  final Set<int> Function(Rect contentRect)? hitTiles;

  /// 按下位置（内容坐标）与该处的行序号；返回 true 时不开始连选或框选。
  final bool Function(Offset contentPosition, int index)? passThrough;

  @override
  State<DragSelectRegion> createState() => _DragSelectRegionState();
}

enum _Mode { paint, band }

class _DragSelectRegionState extends State<DragSelectRegion> {
  final focus = FocusNode(debugLabel: 'drag-select');
  int? pointer;
  _Mode mode = _Mode.band;
  Offset? down, current; // down 为内容坐标（含滚动偏移），current 为视口坐标
  bool active = false, target = true;
  Set<String> before = const {};
  Timer? autoScroll;
  double height = 0;

  @override
  void dispose() {
    autoScroll?.cancel();
    focus.dispose();
    super.dispose();
  }

  double get offset => widget.scroll.hasClients ? widget.scroll.offset : 0.0;

  int indexAt(double contentY) =>
      ((contentY - widget.topPadding) / widget.itemExtent).floor().clamp(
        0,
        widget.ids.isEmpty ? 0 : widget.ids.length - 1,
      );

  void start(PointerDownEvent e) {
    if (pointer != null ||
        widget.ids.isEmpty ||
        e.kind == PointerDeviceKind.touch ||
        e.buttons != kPrimaryMouseButton) {
      return;
    }
    final at = e.localPosition.translate(0, offset);
    if (widget.passThrough?.call(at, indexAt(at.dy)) ?? false) return;
    focus.requestFocus();
    pointer = e.pointer;
    down = at;
    current = e.localPosition;
    active = false;
    mode =
        widget.hitTiles == null && e.localPosition.dx <= widget.checkColumnWidth
        ? _Mode.paint
        : _Mode.band;
    before = {
      for (final id in widget.ids)
        if (widget.isChecked(id)) id,
    };
    target = !before.contains(widget.ids[indexAt(down!.dy)]);
  }

  void move(PointerMoveEvent e) {
    if (e.pointer != pointer || down == null) return;
    current = e.localPosition;
    final travelled = (current!.translate(0, offset) - down!).distance;
    if (!active && travelled < kTouchSlop) return;
    if (!active) setState(() => active = true);
    final y = current!.dy;
    const edge = 28.0;
    if (y < edge || y > height - edge) {
      autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
        final c = current;
        if (c == null || !widget.scroll.hasClients) return;
        final p = widget.scroll.position;
        final step = c.dy < edge ? -14.0 : 14.0;
        final next = (p.pixels + step).clamp(0.0, p.maxScrollExtent);
        if (next != p.pixels) {
          widget.scroll.jumpTo(next);
          update();
        }
      });
    } else {
      autoScroll?.cancel();
      autoScroll = null;
    }
    update();
  }

  void update() {
    final a = down, b = current;
    if (a == null || b == null) return;
    final from = indexAt(a.dy), to = indexAt(b.dy + offset);
    final lo = from < to ? from : to, hi = from < to ? to : from;
    final hits = widget.hitTiles?.call(
      Rect.fromPoints(a, b.translate(0, offset)),
    );
    final check = <String>{}, uncheck = <String>{};
    for (var i = 0; i < widget.ids.length; i++) {
      final id = widget.ids[i];
      final inRange = hits != null ? hits.contains(i) : i >= lo && i <= hi;
      final want = inRange
          ? (mode == _Mode.paint ? target : true)
          : before.contains(id);
      final now = widget.isChecked(id);
      if (want && !now) check.add(id);
      if (!want && now) uncheck.add(id);
    }
    if (check.isNotEmpty || uncheck.isNotEmpty) widget.apply(check, uncheck);
    if (mode == _Mode.band) setState(() {});
  }

  void end(PointerEvent e) {
    if (e.pointer != pointer) return;
    autoScroll?.cancel();
    autoScroll = null;
    pointer = null;
    down = null;
    current = null;
    if (active) setState(() => active = false);
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return CallbackShortcuts(
      bindings: {
        if (widget.onSelectAll != null)
          const SingleActivator(LogicalKeyboardKey.keyA, control: true):
              widget.onSelectAll!,
        if (widget.onClear != null)
          const SingleActivator(LogicalKeyboardKey.escape): widget.onClear!,
      },
      child: Focus(
        focusNode: focus,
        child: LayoutBuilder(
          builder: (context, box) {
            height = box.maxHeight;
            final a = down, b = current;
            final band = active && mode == _Mode.band && a != null && b != null
                ? Rect.fromPoints(a.translate(0, -offset), b)
                : null;
            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: start,
              onPointerMove: move,
              onPointerUp: end,
              onPointerCancel: end,
              child: Stack(
                children: [
                  Positioned.fill(child: widget.child),
                  if (band != null)
                    Positioned.fromRect(
                      rect: band,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: const ValueKey('drag-select-band'),
                          decoration: BoxDecoration(
                            color: d.accent.withValues(alpha: .08),
                            border: Border.all(
                              color: d.accent.withValues(alpha: .45),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
