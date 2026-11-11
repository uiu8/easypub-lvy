// 进度条：左边回检查，中间看进度、点格子跳转，右边处理当前这条。
// 三段只表示进度，可以按任意顺序处理，不是步骤。
// 每处一格；格子放不下时连成一条。画的时候只看数量，问题多少都一样快。
import 'package:flutter/material.dart';

import '../tokens.dart';
import 'check_board.dart';

/// 放在内容区下面、输出栏上面，占一行；不显示时不占地方。
class CheckProgressBar extends StatefulWidget {
  const CheckProgressBar({
    super.key,
    required this.board,
    required this.bookId,
    required this.page,
  });
  final CheckBoard board;
  final String? bookId;
  final String? page;
  @override
  State<CheckProgressBar> createState() => _CheckProgressBarState();
}

class _CheckProgressBarState extends State<CheckProgressBar> {
  /// 鼠标正指着或正拖着的格子。
  CheckCell? hover;
  final portal = OverlayPortalController();
  final bubbleLink = LayerLink();
  final anchor = GlobalKey();
  double bubbleX = 0;

  @override
  void initState() {
    super.initState();
    _enter();
  }

  @override
  void didUpdateWidget(CheckProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId || oldWidget.page != widget.page) {
      _enter();
    }
  }

  void _enter() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) widget.board.enter(widget.bookId, widget.page);
  });

  void _hover(CheckCell? cell, double x) {
    if (cell == hover && x == bubbleX) return;
    setState(() {
      hover = cell;
      bubbleX = x;
    });
    if (cell != null && !portal.isShowing) portal.show();
    if (cell == null && portal.isShowing) portal.hide();
  }

  /// 拖完松手：走到气泡指着的那一条。
  void _drop() {
    final cell = hover;
    if (cell != null && cell.index >= 0) {
      widget.board.select(cell.track, cell.index);
    }
    _hover(null, 0);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.board,
    builder: (context, _) {
      final board = widget.board;
      if (!board.visibleOn(widget.bookId, widget.page)) {
        return const SizedBox.shrink();
      }
      return RepaintBoundary(child: _bar(context, board));
    },
  );

  Widget _bar(BuildContext context, CheckBoard board) {
    final d = context.desk;
    final (title, detail) = board.current;
    final next = board.nextTrack;
    final action = board.action;
    return OverlayPortal(
      controller: portal,
      overlayChildBuilder: (_) => _bubble(board),
      child: Semantics(
        container: true,
        label: '检查进度',
        child: Container(
          key: const ValueKey('check-bar'),
          height: 40,
          padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
          decoration: BoxDecoration(
            color: d.surface,
            border: Border(top: BorderSide(color: d.line)),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 980;
              final narrow = box.maxWidth < 720;
              return Row(
                children: [
                  if (board.onChecks)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text('全书进度', style: ui(12.5, c: d.ink2)),
                    )
                  else
                    _Back(onTap: board.backToChecks),
                  const SizedBox(width: 8),
                  _Sep(),
                  Expanded(
                    child: CompositedTransformTarget(
                      link: bubbleLink,
                      child: Padding(
                        key: anchor,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            for (final (i, track) in board.tracks.indexed) ...[
                              if (i > 0) const SizedBox(width: 14),
                              Expanded(
                                flex: track.total.clamp(4, 14) + 3,
                                child: _Segment(
                                  key: ValueKey('check-bar-track-${track.id}'),
                                  track: track,
                                  current: board.selected?.track == track.id
                                      ? board.selected!.index
                                      : null,
                                  compact: narrow,
                                  anchor: anchor,
                                  onHover: _hover,
                                  onDrop: _drop,
                                  onPick: (index) =>
                                      board.select(track.id, index),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  _Sep(),
                  const SizedBox(width: 8),
                  if (!narrow)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (box.maxWidth * .3).clamp(120.0, 380.0),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              key: const ValueKey('check-bar-title'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ui(13, w: 600, c: d.ink),
                            ),
                          ),
                          if (wide && detail.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: ui(12, c: d.ink3),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(width: 6),
                  if (board.finished)
                    Icon(Icons.check_rounded, size: 16, color: d.ink2)
                  else
                    _Nav(board: board),
                  // 这一条还能处理时放处理按钮；这一段做完才变成去下一段。
                  if (action != null) ...[
                    const SizedBox(width: 6),
                    _Button(
                      action,
                      key: const ValueKey('check-bar-action'),
                      onTap: board.act,
                    ),
                  ] else if (next != null) ...[
                    const SizedBox(width: 6),
                    _Button(
                      '去${next.label} ${next.pending}',
                      key: const ValueKey('check-bar-next-track'),
                      icon: Icons.arrow_forward_rounded,
                      onTap: () => board.select(next.id, 0),
                    ),
                  ],
                  if (!board.onChecks)
                    IconButton(
                      key: const ValueKey('check-bar-close'),
                      tooltip: '关闭（F8 重新打开）',
                      visualDensity: VisualDensity.compact,
                      onPressed: board.close,
                      icon: Icon(Icons.close_rounded, size: 16, color: d.ink3),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 指着格子时的气泡：这一处是什么。
  Widget _bubble(CheckBoard board) {
    final cell = hover;
    if (cell == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: board,
      builder: (context, _) {
        final d = context.desk;
        final (title, detail) = cell.index < 0
            ? ('已处理', '')
            : board.describe(cell.track, cell.index);
        return Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: bubbleLink,
            showWhenUnlinked: false,
            offset: Offset(bubbleX, -8),
            followerAnchor: Alignment.bottomCenter,
            targetAnchor: Alignment.topLeft,
            child: IgnorePointer(
              child: Container(
                key: const ValueKey('check-bar-bubble'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: d.ink,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: d.shadow1,
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: title,
                        style: ui(12.5, w: 620, c: d.canvas),
                      ),
                      if (detail.isNotEmpty)
                        TextSpan(
                          text: '  $detail',
                          style: ui(12, c: d.canvas.withValues(alpha: .75)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 栏里的主按钮：比普通按钮矮一截，一行 40 高放得下。
class _Button extends StatelessWidget {
  const _Button(this.label, {super.key, required this.onTap, this.icon});
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Material(
      color: d.accent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: ui(12.5, w: 620, c: d.canvas)),
              if (icon != null) ...[
                const SizedBox(width: 4),
                Icon(icon, size: 14, color: d.canvas),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 20, color: context.desk.line);
}

class _Back extends StatelessWidget {
  const _Back({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Material(
      color: d.sunken,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        key: const ValueKey('check-bar-back'),
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(5, 5, 10, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chevron_left_rounded, size: 17, color: d.ink2),
              Text('回到检查', style: ui(12.5, w: 600, c: d.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({required this.board});
  final CheckBoard board;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    Widget button(String key, String tip, IconData icon, int delta) =>
        IconButton(
          key: ValueKey(key),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: EdgeInsets.zero,
          onPressed: board.canStep(delta) || board.nextTrack != null
              ? () => board.step(delta)
              : null,
          icon: Icon(icon, size: 17),
        );
    return Container(
      decoration: BoxDecoration(
        color: d.sunken,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(
            'check-bar-prev',
            '上一条（Shift+F8）',
            Icons.keyboard_arrow_up_rounded,
            -1,
          ),
          button(
            'check-bar-step',
            '下一条（F8）',
            Icons.keyboard_arrow_down_rounded,
            1,
          ),
        ],
      ),
    );
  }
}

/// 一段：名字、已做/总数、格子。
class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.track,
    required this.current,
    required this.compact,
    required this.anchor,
    required this.onHover,
    required this.onPick,
    required this.onDrop,
  });
  final CheckTrack track;

  /// 当前这条在“还没处理”里的位置；不在这一段时为空。
  final int? current;
  final bool compact;
  final GlobalKey anchor;
  final VoidCallback onDrop;
  final void Function(CheckCell? cell, double x) onHover;
  final void Function(int index) onPick;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final on = current != null;
    return Row(
      children: [
        if (!compact) ...[
          Text(
            track.label,
            style: ui(12.5, w: on ? 620 : 450, c: on ? d.ink : d.ink2),
          ),
          const SizedBox(width: 4),
          Text(
            '${track.done}/${track.total}',
            style: mono(11.5, c: on ? d.ink2 : d.ink3),
          ),
          const SizedBox(width: 7),
        ],
        Expanded(
          child: _Cells(
            track: track,
            current: current,
            anchor: anchor,
            onHover: onHover,
            onPick: onPick,
            onDrop: onDrop,
          ),
        ),
      ],
    );
  }
}

class _Cells extends StatelessWidget {
  const _Cells({
    required this.track,
    required this.current,
    required this.anchor,
    required this.onHover,
    required this.onPick,
    required this.onDrop,
  });
  final CheckTrack track;
  final int? current;
  final GlobalKey anchor;
  final VoidCallback onDrop;
  final void Function(CheckCell? cell, double x) onHover;
  final void Function(int index) onPick;

  /// 这个位置是第几条还没处理的；落在做完的格子上时为 -1。
  int _at(double x, double width) {
    if (track.total == 0 || width <= 0) return -1;
    final cell = (x / width * track.total).floor().clamp(0, track.total - 1);
    return cell < track.done ? -1 : cell - track.done;
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        double origin() {
          final render = context.findRenderObject() as RenderBox?;
          final target = anchor.currentContext?.findRenderObject();
          if (render == null || target == null) return 0;
          return render.localToGlobal(Offset.zero, ancestor: target).dx;
        }

        void point(Offset local) {
          final index = _at(local.dx, width);
          onHover((track: track.id, index: index), origin() + local.dx);
        }

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => point(e.localPosition),
          onExit: (_) => onHover(null, 0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (e) {
              final index = _at(e.localPosition.dx, width);
              if (index >= 0) onPick(index);
            },
            onHorizontalDragUpdate: (e) => point(e.localPosition),
            onHorizontalDragEnd: (_) => onDrop(),
            onHorizontalDragStart: (e) => point(e.localPosition),
            child: SizedBox(
              height: 28,
              child: CustomPaint(
                painter: _CellsPainter(
                  done: track.done,
                  pending: track.pending,
                  current: current,
                  empty: d.line,
                  full: d.accent,
                  mark: d.warn,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CellsPainter extends CustomPainter {
  const _CellsPainter({
    required this.done,
    required this.pending,
    required this.current,
    required this.empty,
    required this.full,
    required this.mark,
  });
  final int done, pending;
  final int? current;
  final Color empty, full, mark;

  /// 一格至少这么宽；再窄就连成一条。
  static const _minCell = 4.0, _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final total = done + pending;
    if (total == 0 || size.width <= 0) return;
    final cell = size.width / total;
    final mid = size.height / 2;
    final paint = Paint();
    if (cell < _minCell) {
      final bar = RRect.fromLTRBR(
        0,
        mid - 4,
        size.width,
        mid + 4,
        const Radius.circular(3),
      );
      canvas.drawRRect(bar, paint..color = empty);
      if (done > 0) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, done * cell, size.height));
        canvas.drawRRect(bar, paint..color = full);
        canvas.restore();
      }
      if (current != null && current! >= 0) {
        final x = (done + current! + .5) * cell;
        canvas.drawRRect(
          RRect.fromLTRBR(
            x - 2,
            mid - 8,
            x + 2,
            mid + 8,
            const Radius.circular(2),
          ),
          paint..color = mark,
        );
      }
      return;
    }
    final shown = current != null && current! >= 0 ? done + current! : -1;
    for (var i = 0; i < total; i++) {
      final left = i * cell;
      final on = i == shown;
      final half = on ? 8.0 : 4.0;
      canvas.drawRRect(
        RRect.fromLTRBR(
          left,
          mid - half,
          left + cell - _gap,
          mid + half,
          Radius.circular(on ? 3 : 2),
        ),
        paint
          ..color = on
              ? mark
              : i < done
              ? full
              : empty,
      );
    }
  }

  @override
  bool shouldRepaint(_CellsPainter old) =>
      old.done != done ||
      old.pending != pending ||
      old.current != current ||
      old.empty != empty ||
      old.full != full ||
      old.mark != mark;
}
