// 问题位置的界面部件（CH-234–240）：严重度配色、目录右侧的全书问题刻度条、正文行内批注卡片。
// 数据来自 ChapterIssueMapSession（当前编辑稿的章节结构检查），这里只负责画与转发点击。
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 错误朱、提醒赭、提示灰（不用彩色强调）。
(Color, Color) severityTone(Desk d, String severity) =>
    d.tone(switch (severity) {
      'error' => Tone.pen,
      'warning' => Tone.warn,
      _ => Tone.neutral,
    });

int severityRank(String severity) => switch (severity) {
  'error' => 0,
  'warning' => 1,
  _ => 2,
};

/// 刻度条上的一处：所在行在目录可见行中的序号。
class SpineMark {
  const SpineMark(this.row, this.severity, this.open);
  final int row;
  final String severity;
  final bool open;
}

/// 全书问题分布刻度条：按目录可见顺序画出有问题章节的位置，并画出目录当前可见范围。
/// 点在刻度附近（6 像素内）时 [onMark] 选中那一行；否则 [onJump] 按比例滚动。
class IssueSpine extends StatelessWidget {
  const IssueSpine({
    super.key,
    required this.marks,
    required this.rows,
    required this.rowExtent,
    required this.scroll,
    required this.onJump,
    required this.onMark,
  });
  final List<SpineMark> marks;
  final int rows;
  final double rowExtent;
  final ScrollController scroll;
  final void Function(int row) onJump, onMark;

  int? nearest(double y, double height) {
    if (rows == 0 || marks.isEmpty) return null;
    SpineMark? best;
    var distance = double.infinity;
    for (final m in marks) {
      final d = ((m.row + .5) / rows * height - y).abs();
      if (d < distance) {
        distance = d;
        best = m;
      }
    }
    return distance <= 6 ? best!.row : null;
  }

  void handle(Offset position, double height, {required bool tap}) {
    if (rows == 0 || height <= 0) return;
    final y = position.dy.clamp(0.0, height);
    final mark = tap ? nearest(y, height) : null;
    if (mark != null) {
      onMark(mark);
    } else {
      onJump((y / height * rows).floor().clamp(0, rows - 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Semantics(
      label: '全书问题分布，${marks.length} 个章节有问题',
      child: Tooltip(
        message: '全书问题分布：点刻度选中该章',
        waitDuration: const Duration(milliseconds: 800),
        child: LayoutBuilder(
          builder: (context, c) => MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey('chapter-issue-spine'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (e) => handle(e.localPosition, c.maxHeight, tap: true),
              onVerticalDragUpdate: (e) =>
                  handle(e.localPosition, c.maxHeight, tap: false),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(painter: _MarksPainter(d, marks, rows)),
                  ),
                  CustomPaint(
                    painter: _ViewportPainter(d, scroll, rows * rowExtent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MarksPainter extends CustomPainter {
  _MarksPainter(this.d, this.marks, this.rows);
  final Desk d;
  final List<SpineMark> marks;
  final int rows;
  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(4),
    );
    canvas.drawRRect(frame, Paint()..color = d.sunken);
    canvas.drawRRect(
      frame,
      Paint()
        ..color = d.line
        ..style = PaintingStyle.stroke,
    );
    if (rows == 0) return;
    // 大书的刻度会重叠：按 2 像素分桶，每桶只画最重的一处（未处理优先）。
    final buckets = <int, SpineMark>{};
    int weight(SpineMark m) => severityRank(m.severity) + (m.open ? 0 : 3);
    for (final m in marks) {
      final bucket = ((m.row + .5) / rows * size.height / 2).floor();
      final old = buckets[bucket];
      if (old == null || weight(m) < weight(old)) buckets[bucket] = m;
    }
    for (final MapEntry(key: bucket, value: m) in buckets.entries) {
      final y = (bucket * 2.0).clamp(1.0, size.height - 3.2);
      canvas.drawRRect(
        RRect.fromLTRBR(
          1.5,
          y,
          size.width - 1.5,
          y + 2.2,
          const Radius.circular(1),
        ),
        Paint()
          ..color = m.open
              ? severityTone(d, m.severity).$1
              : d.ink3.withValues(alpha: .35),
      );
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) =>
      old.d != d || old.rows != rows || !identical(old.marks, marks);
}

class _ViewportPainter extends CustomPainter {
  _ViewportPainter(this.d, this.scroll, this.content) : super(repaint: scroll);
  final Desk d;
  final ScrollController scroll;
  final double content;
  @override
  void paint(Canvas canvas, Size size) {
    if (!scroll.hasClients || content <= 0) return;
    final position = scroll.position;
    if (!position.hasViewportDimension ||
        position.viewportDimension >= content) {
      return;
    }
    final top = (position.pixels / content).clamp(0.0, 1.0) * size.height;
    final height = (position.viewportDimension / content * size.height).clamp(
      6.0,
      size.height,
    );
    final box = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        -1.5,
        top.clamp(0, size.height - height),
        size.width + 3,
        height,
      ),
      const Radius.circular(3),
    );
    canvas.drawRRect(box, Paint()..color = d.accent.withValues(alpha: .12));
    canvas.drawRRect(
      box,
      Paint()
        ..color = d.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_ViewportPainter old) =>
      old.d != d || old.scroll != scroll || old.content != content;
}

/// 正文行内批注：类型、严重度、说明与序号；操作转到问题浏览器或逐项修复。
/// 整块不参与正文选择复制。
class IssueNoteCard extends StatelessWidget {
  const IssueNoteCard({
    super.key,
    required this.issue,
    required this.number,
    required this.total,
    this.onReview,
    this.onRepair,
  });
  final ChapterIssue issue;
  final int number, total;
  final VoidCallback? onReview, onRepair;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (fg, _) = severityTone(d, issue.severity);
    return SelectionContainer.disabled(
      child: Container(
        key: ValueKey('chapter-issue-note-${issue.id}'),
        margin: const EdgeInsets.only(top: 6, bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        decoration: BoxDecoration(
          color: d.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: d.line),
          boxShadow: d.shadow1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Dot(fg),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${issue.categoryLabel} · '
                    '${chapterIssueSeverities[issue.severity] ?? '提示'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12.5, w: 650, c: d.ink),
                  ),
                ),
                Text('$number / $total', style: ui(11, c: d.ink3)),
              ],
            ),
            const SizedBox(height: 4),
            Text(issue.title, style: ui(12.5, c: d.ink2, h: 1.5)),
            if (issue.evidence.isNotEmpty && issue.evidence != issue.title) ...[
              const SizedBox(height: 2),
              Text(
                issue.evidence,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: d.ink3, h: 1.5),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                if (onReview != null)
                  TextButton.icon(
                    key: ValueKey('chapter-issue-review-${issue.id}'),
                    onPressed: onReview,
                    icon: const Icon(Icons.fact_check_outlined, size: 16),
                    label: const Text('在问题中核对'),
                  ),
                if (onRepair != null && issue.hasSuggestion)
                  TextButton.icon(
                    key: ValueKey('chapter-issue-repair-${issue.id}'),
                    onPressed: onRepair,
                    icon: const Icon(Icons.auto_fix_high_outlined, size: 16),
                    label: const Text('修复方案'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
