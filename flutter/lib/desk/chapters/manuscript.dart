// 章节正文（CH-037–040）：纸面阅读区。按块双向续读（center sliver 保持阅读位置），
// 超长行按字符偏移续读；左侧有效稿行号栏不参与选择复制；正文只读可复制。
import 'package:flutter/material.dart';

import '../errors.dart';

import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../application/chapter_service.dart';
import '../../application/rule_catalog_service.dart';
import '../grain.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'block_marks.dart';
import 'issue_marks.dart';
import 'layout_view.dart';
import 'note_marks.dart';

class ChapterManuscript extends StatefulWidget {
  const ChapterManuscript({
    super.key,
    required this.session,
    required this.page,
    required this.node,
    this.initialBody,
    this.initialOffset = 0,
    this.initialScroll = 0,
    this.focusLine,
    this.onPosition,
    this.issues = const [],
    this.showNotes = true,
    this.onToggleNotes,
    this.onReviewIssue,
    this.onRepairIssue,
    this.issuesTruncated = false,
    this.marks,
    this.noteMarks,
    this.layout,
    this.onLayoutMode,
  });

  /// 排版视图（V104，LAY-149）：不为空时正文按排版设置显示识别结果，可拖选几行标注；不能选字复制。
  final ChapterLayoutView? layout;

  /// 页眉“原文 | 排版”切换；书库不提供识别结果时为空，不显示切换。
  final ValueChanged<bool>? onLayoutMode;

  /// 手工标注（V53，LAY-123）；书库不提供标注能力时为空，行号栏不可点。
  final BlockMarkController? marks;

  /// 手工注释（V62，LAY-128）；书库不提供注释能力时为空。
  final NoteMarkController? noteMarks;

  /// 本章问题超过单次上限（200 条）时为真；页眉提示只列出了前 200 条。
  final bool issuesTruncated;

  /// 本章内或触及本章的问题（CH-237）；只为未处理的插入批注。
  final List<ChapterIssue> issues;
  final bool showNotes;
  final ValueChanged<bool>? onToggleNotes;
  final void Function(ChapterIssue)? onReviewIssue, onRepairIssue;
  final ChapterSession session;
  final ChapterPage page;
  final ChapterNode node;
  final ChapterBody? initialBody;
  final int initialOffset;
  final double initialScroll;

  /// 有效稿绝对行号；该行加底色标出（来自问题定位）。
  final int? focusLine;
  final void Function(int offset, double pixels)? onPosition;
  @override
  State<ChapterManuscript> createState() => _ChapterManuscriptState();
}

class _ChapterManuscriptState extends State<ChapterManuscript> {
  final scroll = ScrollController();
  final center = GlobalKey();
  final viewport = GlobalKey();
  final blocks = <int, ChapterBody>{};
  final keys = <int, GlobalKey>{};
  final lineKeys = <int, GlobalKey>{};
  final pending = <int>{};
  final continuedRows = <int, ChapterBodyRow>{};
  final continuationMarkers = <int, GlobalKey>{};
  final pendingLines = <int>{};
  final lineErrors = <int, String>{};
  late int origin = widget.initialBody?.offset ?? widget.initialOffset;
  int generation = 0;
  String error = '';
  int? failedOffset;
  bool initialPositionApplied = false;
  bool positionScheduled = false;

  @override
  void initState() {
    super.initState();
    scroll.addListener(onScroll);
    widget.marks?.addListener(onMarks);
    widget.noteMarks?.addListener(onMarks);
    widget.layout?.addListener(onMarks);
    reset();
  }

  void onMarks() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ChapterManuscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.marks != widget.marks) {
      oldWidget.marks?.removeListener(onMarks);
      widget.marks?.addListener(onMarks);
    }
    if (oldWidget.noteMarks != widget.noteMarks) {
      oldWidget.noteMarks?.removeListener(onMarks);
      widget.noteMarks?.addListener(onMarks);
    }
    if (oldWidget.layout != widget.layout) {
      oldWidget.layout?.removeListener(onMarks);
      widget.layout?.addListener(onMarks);
    }
    if (oldWidget.node.id != widget.node.id ||
        oldWidget.page.guard != widget.page.guard ||
        oldWidget.initialOffset != widget.initialOffset) {
      reset();
    }
  }

  void reset() {
    generation++;
    blocks.clear();
    keys.clear();
    lineKeys.clear();
    pending.clear();
    continuedRows.clear();
    continuationMarkers.clear();
    pendingLines.clear();
    lineErrors.clear();
    _notesSource = null;
    error = '';
    failedOffset = null;
    initialPositionApplied = false;
    origin = widget.initialBody?.offset ?? widget.initialOffset;
    if (widget.initialBody != null) blocks[origin] = widget.initialBody!;
    if (blocks.isEmpty) {
      load(origin);
    } else {
      schedulePosition();
    }
  }

  void schedulePosition() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !scroll.hasClients) return;
    if (!initialPositionApplied) {
      final line = lineKeys[origin]?.currentContext?.findRenderObject();
      if (line is RenderBox &&
          (widget.initialScroll > line.size.height ||
              widget.initialScroll > scroll.position.maxScrollExtent) &&
          rowAt(origin)?.nextCharOffset != null) {
        continueLine(origin);
        return;
      }
      initialPositionApplied = true;
      // 记忆的像素是“视口顶相对该行顶”的距离；该行之前可能有页眉，故按行的实际位置换算。
      var target = widget.initialScroll;
      final view = viewport.currentContext?.findRenderObject();
      if (line is RenderBox && line.attached && view is RenderBox) {
        target +=
            scroll.offset +
            line.localToGlobal(Offset.zero).dy -
            view.localToGlobal(Offset.zero).dy;
      }
      scroll.jumpTo(
        target.clamp(
          scroll.position.minScrollExtent,
          scroll.position.maxScrollExtent,
        ),
      );
    }
    loadNearEdges();
    loadVisibleContinuations();
  });

  Future<void> load(int offset) async {
    if (offset < 0 || blocks.containsKey(offset) || !pending.add(offset)) {
      return;
    }
    final ticket = generation;
    try {
      final next = await widget.session.body(
        widget.page,
        widget.node.id,
        offset,
      );
      if (!mounted || ticket != generation) return;
      setState(() {
        blocks[offset] = next;
        error = '';
        failedOffset = null;
      });
      schedulePosition();
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          error = deskErrorText(e, '正文没有读出来：原稿可能被移动或占用。在书库用“刷新来源”核对原稿位置。');
          failedOffset = offset;
        });
      }
    } finally {
      if (ticket == generation) pending.remove(offset);
    }
  }

  void loadNearEdges() {
    if (!scroll.hasClients || blocks.isEmpty || error.isNotEmpty) return;
    final offsets = blocks.keys.toList()..sort();
    if (scroll.position.extentBefore < 600 && offsets.first > 0) {
      load((offsets.first - 30).clamp(0, offsets.first));
    }
    final last = blocks[offsets.last]!;
    if (scroll.position.extentAfter < 600 && last.more) {
      load(last.offset + 30);
    }
  }

  void onScroll() {
    loadNearEdges();
    if (positionScheduled) return;
    positionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      positionScheduled = false;
      if (!mounted) return;
      loadVisibleContinuations();
      rememberPosition();
    });
  }

  void rememberPosition() {
    if (!initialPositionApplied) return;
    final box = viewport.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final top = box.localToGlobal(Offset.zero).dy;
    int? nearest;
    double best = -double.infinity;
    for (final entry in lineKeys.entries) {
      final item = entry.value.currentContext?.findRenderObject();
      if (item is! RenderBox || !item.attached) continue;
      final y = item.localToGlobal(Offset.zero).dy;
      if (y <= top + 1 && y > best) {
        best = y;
        nearest = entry.key;
      }
    }
    if (nearest != null) {
      widget.onPosition?.call(nearest, (top - best).clamp(0, double.infinity));
    }
  }

  ChapterBodyRow? rowAt(int line) {
    if (continuedRows[line] != null) return continuedRows[line];
    for (final block in blocks.values) {
      for (final row in block.rows) {
        if (row.lineOffset - 1 == line) return row;
      }
    }
    return null;
  }

  void loadVisibleContinuations() {
    if (widget.session is! ChapterBodyContinuationSession) return;
    final box = viewport.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    for (final entry in continuationMarkers.entries) {
      if (lineErrors.containsKey(entry.key)) continue;
      final marker = entry.value.currentContext?.findRenderObject();
      if (marker is! RenderBox || !marker.attached) continue;
      final y = marker.localToGlobal(Offset.zero).dy;
      if (y >= top - 600 && y <= bottom + 600) continueLine(entry.key);
    }
  }

  Future<void> continueLine(int line) async {
    final row = rowAt(line);
    final session = widget.session;
    if (session is! ChapterBodyContinuationSession ||
        row?.nextCharOffset == null ||
        !pendingLines.add(line)) {
      return;
    }
    final ticket = generation;
    try {
      final next = await (session as ChapterBodyContinuationSession).bodyLine(
        widget.page,
        widget.node.id,
        line,
        row!.nextCharOffset!,
      );
      if (!mounted || generation != ticket) return;
      setState(() {
        continuedRows[line] = ChapterBodyRow(
          row.text + next.text,
          row.lineOffset,
          row.selectable,
          nextCharOffset: next.nextCharOffset,
        );
        lineErrors.remove(line);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadVisibleContinuations();
      });
      schedulePosition();
    } catch (e) {
      if (mounted && generation == ticket) {
        setState(() => lineErrors[line] = deskErrorText(e, '本段后续内容未读取，请重试。'));
      }
    } finally {
      if (ticket == generation) pendingLines.remove(line);
    }
  }

  List<ChapterIssue>? _notesSource;
  Map<int, List<ChapterIssue>> _notes = const {};
  List<ChapterIssue> _headingNotes = const [];
  Map<String, int> _numbers = const {};

  /// 按有效稿行号归类本章未处理问题；正文行之外（标题行等）的放在页眉下。
  void groupNotes(ChapterBody body) {
    if (identical(_notesSource, widget.issues)) return;
    _notesSource = widget.issues;
    final first = widget.node.line + 1;
    final last = widget.node.line + body.total;
    final placed = <(int, ChapterIssue)>[];
    for (final issue in widget.issues) {
      if (issue.decision != null || issue.categoryReviewed) continue;
      final own = issue.anchors.where((a) => a.entryId == widget.node.id);
      final line = own.isNotEmpty
          ? own.first.line
          : issue.lines.firstWhere(
              (l) => l >= widget.node.line && l <= last,
              orElse: () => widget.node.line,
            );
      placed.add((line, issue));
    }
    placed.sort((a, b) => a.$1.compareTo(b.$1));
    final notes = <int, List<ChapterIssue>>{};
    final heading = <ChapterIssue>[];
    for (final (line, issue) in placed) {
      if (line >= first && line <= last) {
        (notes[line] ??= []).add(issue);
      } else {
        heading.add(issue);
      }
    }
    _notes = notes;
    _headingNotes = heading;
    _numbers = {for (var i = 0; i < placed.length; i++) placed[i].$2.id: i + 1};
  }

  int get noteCount => _numbers.length;

  Widget note(ChapterIssue issue) => IssueNoteCard(
    issue: issue,
    number: _numbers[issue.id] ?? 0,
    total: noteCount,
    onReview: widget.onReviewIssue == null
        ? null
        : () => widget.onReviewIssue!(issue),
    onRepair: widget.onRepairIssue == null
        ? null
        : () => widget.onRepairIssue!(issue),
  );

  Widget heading(Desk d, ChapterBody body) => Padding(
    padding: const EdgeInsets.only(top: 30, bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.node.title, style: serif(24, w: 650, c: d.ink, h: 1.35)),
        const SizedBox(height: 6),
        Text(
          widget.node.id == chapterPrefixNode.id
              ? '首个标题之前 · 共 ${body.total} 行'
              : '第 ${widget.node.line} 行起 · 共 ${body.total} 行',
          style: ui(11.5, c: d.ink3),
        ),
        if (noteCount > 0)
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Dot(d.pen, size: 6),
                  const SizedBox(width: 6),
                  Text(
                    widget.issuesTruncated
                        ? '本章问题较多，以下只列出前 200 条中的 $noteCount 个未处理问题'
                        : '本章 $noteCount 个未处理问题',
                    style: ui(11.5, c: d.ink2),
                  ),
                  const SizedBox(width: 4),
                  if (widget.onToggleNotes != null)
                    TextButton(
                      key: const ValueKey('chapter-issue-notes-toggle'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 26),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      onPressed: () => widget.onToggleNotes!(!widget.showNotes),
                      child: Text(widget.showNotes ? '收起批注' : '展开批注'),
                    ),
                ],
              ),
            ),
          ),
        if (widget.showNotes)
          for (final issue in _headingNotes) note(issue),
      ],
    ),
  );

  Widget paragraph(Desk d, ChapterBody body, int index, double gutter) {
    final initial = body.rows.isNotEmpty ? body.rows[index] : null;
    final line = (initial?.lineOffset ?? body.offset + index + 1) - 1;
    final row = continuedRows[line] ?? initial;
    final absolute = widget.node.line + line + 1;
    final focused = absolute == widget.focusLine;
    final marks = widget.marks;
    final entry = widget.node.id;
    final mark = marks == null ? null : markLines[line + 1];
    final chosen = marks?.selected(entry, line + 1) ?? false;
    final noteTags = noteLines[line + 1] ?? const <NoteLineTag>[];
    final lineText = row?.text ?? body.lines[index];
    final notes = widget.showNotes ? _notes[absolute] : null;
    final layout = widget.layout;
    final auto = layout == null ? null : layoutLines[line + 1];
    final inBlock = systemRoles.containsKey(line + 1);
    final flagged = _notes[absolute];
    final flag = flagged == null
        ? null
        : severityTone(
            d,
            flagged
                .map((i) => i.severity)
                .reduce((a, b) => severityRank(a) <= severityRank(b) ? a : b),
          ).$1;
    final text = Container(
      key: lineKeys.putIfAbsent(line, GlobalKey.new),
      // 排版视图里同一块系统提示的各行紧挨着，边框和底色连成一片。
      margin: EdgeInsets.only(bottom: inBlock ? 0 : 2),
      decoration: focused || chosen
          ? BoxDecoration(
              color: d.accentSoft,
              borderRadius: BorderRadius.circular(6),
            )
          : flag != null
          ? BoxDecoration(
              border: Border(left: BorderSide(color: flag, width: 3)),
            )
          : null,
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: gutter,
                child: SelectionContainer.disabled(
                  child: MouseRegion(
                    cursor: marks == null
                        ? MouseCursor.defer
                        : SystemMouseCursors.click,
                    child: GestureDetector(
                      key: ValueKey(('line-number', entry, line + 1)),
                      behavior: HitTestBehavior.opaque,
                      onTap: marks == null
                          ? null
                          : () => marks.tapLine(
                              entry,
                              line + 1,
                              extend: blockMarkExtending(),
                            ),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 9, right: 14),
                        child: Text(
                          '$absolute',
                          textAlign: TextAlign.right,
                          style: mono(
                            10.5,
                            c: chosen
                                ? d.ink
                                : focused
                                ? d.ink
                                : (flag ?? d.ink3),
                            w: focused || chosen || flag != null ? 600 : 400,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: inBlock ? 0 : 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (layout != null)
                        LayoutLineText(
                          key: ValueKey(('body-line', widget.node.id, line)),
                          text: lineText,
                          line: layoutLines[line + 1],
                          role: systemRoles[line + 1],
                          view: layout,
                          style: serif(16, c: d.ink, h: 1.9),
                        )
                      else if ((mark != null && mark.first) ||
                          noteTags.isNotEmpty)
                        Text.rich(
                          TextSpan(
                            text: lineText,
                            children: [
                              if (mark != null && mark.first)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: BlockTag(
                                    controller: marks!,
                                    view: mark.view,
                                    lines: lineRange(
                                      mark.view.firstLine!,
                                      mark.view.lastLine!,
                                    ),
                                  ),
                                ),
                              for (final tag in noteTags)
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: NoteTag(
                                    controller: widget.noteMarks!,
                                    tag: tag,
                                    lineLabel: lineLabel,
                                    onEdit: () => editNote(tag),
                                  ),
                                ),
                            ],
                          ),
                          key: ValueKey(('body-line', widget.node.id, line)),
                          style: serif(16, c: d.ink, h: 1.9),
                        )
                      else
                        Text(
                          row?.text ?? body.lines[index],
                          key: ValueKey(('body-line', widget.node.id, line)),
                          style: serif(16, c: d.ink, h: 1.9),
                        ),
                      if (row?.nextCharOffset != null)
                        Align(
                          key: continuationMarkers.putIfAbsent(
                            line,
                            GlobalKey.new,
                          ),
                          alignment: Alignment.centerLeft,
                          child: SelectionContainer.disabled(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: lineErrors.containsKey(line)
                                    ? d.pen
                                    : d.ink2,
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              onPressed: pendingLines.contains(line)
                                  ? null
                                  : () => continueLine(line),
                              child: Text(lineErrors[line] ?? '继续读取本段'),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 排版视图：行号旁色条，手工标注与自动识别颜色不同；悬停时右上角出标签（V104）。
          if (layout != null && (mark != null || auto != null))
            Positioned(
              left: gutter - 8,
              top: 2,
              bottom: 2,
              width: 3,
              child: DecoratedBox(
                key: ValueKey(('layout-bar', entry, line + 1)),
                decoration: BoxDecoration(
                  color: layoutBarColor(d, manual: mark != null),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          if (layout != null && (mark != null || auto != null))
            Positioned(
              right: 0,
              top: 0,
              child: ValueListenableBuilder<int?>(
                valueListenable: hoverLine,
                builder: (context, hover, child) =>
                    hover == line ? child! : const SizedBox.shrink(),
                child: mark != null
                    ? BlockTag(
                        controller: marks!,
                        view: mark.view,
                        lines: lineRange(
                          mark.view.firstLine!,
                          mark.view.lastLine!,
                        ),
                      )
                    : LayoutAutoTag(
                        key: ValueKey(('layout-tag', entry, line + 1)),
                        label: layoutLineLabel(auto!, systemRoles[line + 1]),
                        onTap: marks == null
                            ? null
                            : () => selectBlock(line + 1),
                      ),
              ),
            ),
          // 手工标注的括号叠在行号栏右侧，上下与本行等高（V53）。
          if (mark != null && layout == null)
            Positioned(
              left: gutter - 10,
              top: 0,
              bottom: 0,
              child: BlockBracket(mark),
            ),
        ],
      ),
    );
    final shown = layout == null || marks == null
        ? text
        : MouseRegion(
            onEnter: (_) => hoverLine.value = line,
            onExit: (_) {
              if (hoverLine.value == line) hoverLine.value = null;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () =>
                  marks.tapLine(entry, line + 1, extend: blockMarkExtending()),
              onPanStart: (_) {
                dragAnchor = line + 1;
                marks.selectRange(entry, line + 1, line + 1);
              },
              onPanUpdate: (details) {
                final to = lineAt(details.globalPosition);
                if (dragAnchor != null && to != null) {
                  marks.selectRange(entry, dragAnchor!, to + 1);
                }
              },
              onPanEnd: (_) => setState(() => dragAnchor = null),
              onPanCancel: () => setState(() => dragAnchor = null),
              child: text,
            ),
          );
    // 拖选途中不出工具条，免得它把下面的行挤开；松手后再出。
    final bar = chosen && marks!.last == line + 1 && dragAnchor == null
        ? Padding(
            padding: EdgeInsets.only(left: gutter),
            child: BlockMarkBar(
              controller: marks,
              lines: lineRange(marks.first!, marks.last!),
              onNote: widget.noteMarks == null || marks.first != marks.last
                  ? null
                  : () => addNote(line + 1, lineText),
            ),
          )
        : null;
    if (notes == null && bar == null) return shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        shown,
        ?bar,
        if (notes != null)
          Padding(
            padding: EdgeInsets.only(left: gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final issue in notes) note(issue)],
            ),
          ),
      ],
    );
  }

  /// 本节正文行号（从 1 开始）对应的显示行号范围，例如“第 13–15 行”。
  String lineRange(int first, int last) {
    final a = widget.node.line + first, b = widget.node.line + last;
    return a == b ? '第 $a 行' : '第 $a–$b 行';
  }

  /// 本节每行所属的手工标注；每次构建时按最新列表计算。
  Map<int, BlockMarkLine> markLines = const {};

  /// 排版视图（V104）：本节每行的识别结果、系统提示所属的块，悬停中的行，拖选起点。
  Map<int, LayoutLine> layoutLines = const {};
  Map<int, SystemRole> systemRoles = const {};
  final hoverLine = ValueNotifier<int?>(null);
  int? dragAnchor;

  /// 拖选时指针所在的行（本节内从 0 开始）；不在任何行上时为空。
  int? lineAt(Offset global) {
    for (final entry in lineKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (global.dy >= top && global.dy < top + box.size.height) {
        return entry.key;
      }
    }
    return null;
  }

  /// 点自动识别标签：选中这一块连续的同类行，弹出标注工具条。
  void selectBlock(int line) {
    final marks = widget.marks;
    final kind = layoutLines[line]?.kind;
    if (marks == null || kind == null) return;
    var (a, b) = (line, line);
    while (layoutLines[a - 1]?.kind == kind && markLines[a - 1] == null) {
      a--;
    }
    while (layoutLines[b + 1]?.kind == kind && markLines[b + 1] == null) {
      b++;
    }
    marks.selectRange(widget.node.id, a, b);
  }

  /// 页眉：本节识别到的数量与“原文 | 排版”切换（V104，LAY-149）。
  Widget layoutHeader(Desk d) {
    final layout = widget.layout;
    final counts = layout?.counts(layoutLines, markLines);
    final phase = layout?.state.phase;
    return Container(
      key: const ValueKey('chapter-layout-header'),
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              layout == null
                  ? ''
                  : counts == null || layout.state.result == null
                  ? phase == RuleStatisticsPhase.failed
                        ? '暂时识别不出本章的系统提示与诗词。'
                        : '正在识别本章的系统提示与诗词…'
                  : '本章 系统提示 ${counts.system} · 诗词 ${counts.verse}'
                        '${counts.manual > 0 ? ' · 手工标注 ${counts.manual}' : ''}'
                        '　拖选几行可标注；排版视图只看和标注，改字请切回原文',
              key: const ValueKey('chapter-layout-counts'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: d.ink3),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('chapter-layout-mode'),
            child: DeskSegmented<bool>(
              value: layout != null,
              options: const {false: '原文', true: '排版'},
              onChanged: (v) => widget.onLayoutMode!(v),
            ),
          ),
        ],
      ),
    );
  }

  /// 本节每行的手工注释标签（V62）；每次构建时按最新列表计算。
  Map<int, List<NoteLineTag>> noteLines = const {};

  /// 本节正文行号对应的显示行号，例如“第 13 行”。
  String lineLabel(int line) => '第 ${widget.node.line + line} 行';

  /// 本节已读入的正文行（行号从 1 开始）。
  List<(int, String)> loadedLines() {
    final result = <int, String>{};
    for (final body in blocks.values) {
      for (var i = 0; i < body.lines.length; i++) {
        final row = body.rows.isNotEmpty ? body.rows[i] : null;
        final line = row?.lineOffset ?? body.offset + i + 1;
        result[line] =
            continuedRows[line - 1]?.text ?? row?.text ?? body.lines[i];
      }
    }
    return [
      for (final e
          in (result.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
        (e.key, e.value),
    ];
  }

  NoteContext noteContext(int line, String text) => NoteContext(
    entryId: widget.node.id,
    line: line,
    lineText: text,
    chapterLines: loadedLines(),
    lineLabel: lineLabel,
  );

  Future<void> addNote(int line, String text) async {
    final notes = widget.noteMarks;
    if (notes == null) return;
    if (await showNoteDialog(context, notes, noteContext(line, text))) {
      widget.marks?.clearSelection();
    }
  }

  Future<void> editNote(NoteLineTag tag) async {
    final notes = widget.noteMarks;
    final at = tag.view.location;
    if (notes == null || at == null) return;
    final text = loadedLines()
        .where((l) => l.$1 == at.line)
        .map((l) => l.$2)
        .firstOrNull;
    if (text == null) {
      notes.report('这条注释所在的行还没有读入，请先滚动到该行。');
      return;
    }
    await showNoteDialog(
      context,
      notes,
      noteContext(at.line, text),
      existing: tag.view,
    );
  }

  Widget block(Desk d, int offset, double gutter) {
    final body = blocks[offset]!;
    final following = blocks.keys.where((v) => v > offset).toList()..sort();
    final end = following.isEmpty
        ? body.offset + body.lines.length
        : following.first;
    return Column(
      key: keys.putIfAbsent(offset, GlobalKey.new),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (body.offset == 0)
          Padding(
            padding: EdgeInsets.only(left: gutter),
            child: heading(d, body),
          ),
        for (var i = 0; i < body.lines.length && body.offset + i < end; i++)
          paragraph(d, body, i, gutter),
        if (!body.more && offset == (blocks.keys.toList()..sort()).last)
          const SizedBox(height: 120),
      ],
    );
  }

  @override
  void dispose() {
    generation++;
    widget.marks?.removeListener(onMarks);
    widget.noteMarks?.removeListener(onMarks);
    widget.layout?.removeListener(onMarks);
    hoverLine.dispose();
    scroll.removeListener(onScroll);
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) loadVisibleContinuations();
    });
    final before = blocks.keys.where((v) => v < origin).toList()
      ..sort((a, b) => b.compareTo(a));
    final after = blocks.keys.where((v) => v >= origin).toList()..sort();
    if (blocks.isNotEmpty) groupNotes(blocks.values.first);
    markLines = widget.marks?.linesFor(widget.node.id) ?? const {};
    noteLines = widget.noteMarks?.tagsFor(widget.node.id) ?? const {};
    final layout = widget.layout;
    layoutLines = layout?.linesFor(widget.node.id) ?? const {};
    systemRoles = layout == null
        ? const {}
        : layout.systemRoles(layoutLines, markLines, {
            for (final (line, text) in loadedLines()) line: text,
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.onLayoutMode != null) layoutHeader(d),
        if (widget.marks != null) BlockInvalidBanner(controller: widget.marks!),
        if (widget.noteMarks != null)
          NoteInvalidBanner(controller: widget.noteMarks!),
        if (error.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
            decoration: BoxDecoration(
              color: d.penSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: d.pen),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(error, style: ui(12.5, c: d.ink)),
                ),
                TextButton(
                  onPressed: () {
                    final offset = failedOffset!;
                    setState(() => error = '');
                    load(offset);
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        Expanded(
          child: blocks.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, c) {
                    final narrow = c.maxWidth < 700;
                    final margin = narrow ? 10.0 : 24.0;
                    final paper = (c.maxWidth - margin * 2).clamp(0.0, 780.0);
                    final side = (c.maxWidth - paper) / 2;
                    final gutter = narrow ? 52.0 : 68.0;
                    final inner = EdgeInsets.fromLTRB(
                      side + 4,
                      0,
                      side + (narrow ? 20 : 44),
                      0,
                    );
                    return Stack(
                      children: [
                        Positioned(
                          left: side,
                          width: paper,
                          top: 14,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10),
                              ),
                              boxShadow: d.shadow1,
                            ),
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10),
                              ),
                              child: PaperGround(
                                color: d.paper,
                                strength: d.grain * .5,
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          top: 14,
                          // 排版视图里拖动用来选行标注，不再选字复制。
                          child: _MaybeSelectable(
                            selectable: layout == null,
                            child: Container(
                              key: viewport,
                              child: ScrollConfiguration(
                                behavior: ScrollConfiguration.of(context)
                                    .copyWith(scrollbars: false),
                                child: Scrollbar(
                                  controller: scroll,
                                  child: CustomScrollView(
                                    controller: scroll,
                                    center: center,
                                    scrollCacheExtent:
                                        const ScrollCacheExtent.pixels(600),
                                    slivers: [
                                      SliverPadding(
                                        padding: inner,
                                        sliver: SliverList(
                                          delegate: SliverChildBuilderDelegate(
                                            (_, i) =>
                                                block(d, before[i], gutter),
                                            childCount: before.length,
                                          ),
                                        ),
                                      ),
                                      SliverPadding(
                                        key: center,
                                        padding: inner,
                                        sliver: SliverList(
                                          delegate: SliverChildBuilderDelegate(
                                            (_, i) =>
                                                block(d, after[i], gutter),
                                            childCount: after.length,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MaybeSelectable extends StatelessWidget {
  const _MaybeSelectable({required this.selectable, required this.child});
  final bool selectable;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      selectable ? SelectionArea(child: child) : child;
}
