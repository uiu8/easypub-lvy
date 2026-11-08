// 修改前后预览（CH-079–089）：分页浏览真实候选的结构与所选节点正文。
// “修改前”读取当前有效稿，书稿版本变化时报错，不展示伪造的旧版本；
// “修改后”读取尚未采用的候选。只读模式（修复差异核对）没有确认按钮。
import 'package:flutter/material.dart';

import '../../errors.dart';

import '../../../application/chapter_service.dart';
import '../../controls/controls.dart';
import '../../dialogs.dart';
import '../../tokens.dart';
import '../../widgets.dart';

class ChapterCandidateDialog extends StatefulWidget {
  const ChapterCandidateDialog({
    super.key,
    required this.session,
    required this.preview,
    required this.originalPage,
    required this.title,
    this.initialOffset = 0,
    this.initialNodeId,
    this.focusNodeId,
    this.focusLine,
    this.readOnly = false,
    this.explanation,
  });
  final ChapterSession session;
  final ChapterEditPreview preview;
  final ChapterPage originalPage;
  final String title;
  final int initialOffset;
  final String? initialNodeId;

  /// 被处理的标题（CH-257）：“修改前”选中它；“修改后”选中 [focusLine]
  /// 所在的章节并把正文翻到这一行。
  final String? focusNodeId;
  final int? focusLine;
  final bool readOnly;

  /// 给出时显示在标题下，并提供“卷前正文”入口（标题降级、删除正文等需核对卷前内容）。
  final String? explanation;
  @override
  State<ChapterCandidateDialog> createState() => _ChapterCandidateDialogState();
}

class _ChapterCandidateDialogState extends State<ChapterCandidateDialog> {
  ChapterPage? page;
  ChapterNode? selected;
  ChapterBody? body;
  bool busy = false;
  String error = '';
  bool before = false;
  static const prefix = chapterPrefixNode;

  Future<ChapterPage> readTree(int offset) async {
    if (!before) return widget.session.previewTree(widget.preview, offset);
    final value = await widget.session.read(offset);
    if (value.guard != widget.originalPage.guard) {
      throw const FormatException('书稿已变化，请关闭并重新预览。');
    }
    return value;
  }

  Future<ChapterBody> readBody(String nodeId, int offset) => before
      ? widget.session.body(widget.originalPage, nodeId, offset)
      : widget.session.previewBody(widget.preview, nodeId, offset);

  @override
  void initState() {
    super.initState();
    load(widget.initialOffset, focus: true);
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '操作没有完成。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load(int offset, {bool focus = false}) => run(() async {
    var next = await readTree(offset);
    if (next.nodes.isEmpty && offset > 0) {
      next = await readTree(((next.total - 1).clamp(0, next.total) ~/ 30) * 30);
    }
    final line = widget.focusLine;
    ChapterNode? target;
    if (focus && line != null) {
      if (before) {
        target = next.nodes
            .where((n) => n.id == widget.focusNodeId)
            .firstOrNull;
      } else {
        // 降级后这一行归入它前面最近的标题；当前页第一个标题已在它之后时看上一页。
        if (next.offset > 0 &&
            next.nodes.isNotEmpty &&
            next.nodes.first.line > line) {
          next = await readTree(next.offset - 30);
        }
        target = next.nodes.lastWhere(
          (n) => n.line <= line,
          orElse: () => prefix,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      page = next;
      selected =
          target ??
          ((selected?.id ?? widget.initialNodeId) == prefix.id
              ? prefix
              : next.nodes
                        .where(
                          (n) => n.id == (selected?.id ?? widget.initialNodeId),
                        )
                        .firstOrNull ??
                    next.nodes.firstOrNull);
      body = null;
    });
    if (selected != null) {
      var bodyOffset = 0;
      if (target != null && line != null && !before) {
        final row = line - (target.id == prefix.id ? 0 : target.line) - 1;
        bodyOffset = row > 5 ? row - 5 : 0;
      }
      final content = await readBody(selected!.id, bodyOffset);
      if (mounted) setState(() => body = content);
    }
  });

  Future<void> select(ChapterNode node, int offset) => run(() async {
    setState(() {
      selected = node;
      body = null;
    });
    final content = await readBody(node.id, offset);
    if (mounted) setState(() => body = content);
  });

  int lineNumber(ChapterBody content, int index) {
    final offset = content.rows.isNotEmpty
        ? content.rows[index].lineOffset
        : content.offset + index + 1;
    return selected?.id == prefix.id ? offset : selected!.line + offset;
  }

  Widget structure(Desk d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: DeskListBox(
          paper: false,
          child: ListView.builder(
            padding: const EdgeInsets.all(4),
            itemCount: page?.nodes.length ?? 0,
            itemBuilder: (_, i) {
              final node = page!.nodes[i];
              return Padding(
                padding: EdgeInsets.only(left: node.depth.clamp(0, 4) * 10.0),
                child: DeskChoiceRow(
                  radio: false,
                  title: node.title,
                  detail: '${node.line}',
                  selected: selected?.id == node.id,
                  onTap: busy ? null : () => select(node, 0),
                ),
              );
            },
          ),
        ),
      ),
      const SizedBox(height: 4),
      DeskPager(
        iconOnly: true,
        previous: '上一页预览结构',
        next: '下一页预览结构',
        info: page == null
            ? ''
            : '结构 ${page!.offset + 1}–${page!.offset + page!.nodes.length} / ${page!.total}',
        onPrevious: busy || page == null || page!.offset == 0
            ? null
            : () => load(page!.offset - 30),
        onNext: busy || page == null || page!.offset + 30 >= page!.total
            ? null
            : () => load(page!.offset + 30),
      ),
    ],
  );

  Widget reader(Desk d) {
    final content = body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            selected?.title ?? '选择章节',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: serif(15, w: 650, c: d.ink),
          ),
        ),
        Expanded(
          child: DeskListBox(
            child: content == null
                ? const SizedBox.shrink()
                : SelectionArea(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: content.lines.length,
                      itemBuilder: (_, i) {
                        final number = lineNumber(content, i);
                        final focused = number == widget.focusLine;
                        return DeskLineRow(
                          key: focused
                              ? const Key('candidate-focus-line')
                              : null,
                          number: number,
                          text: content.lines[i],
                          selected: focused,
                        );
                      },
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        DeskPager(
          previous: '前段',
          next: '后段',
          info: content == null
              ? ''
              : '共 ${content.total} 行 · 第 ${content.offset + 1}–${content.offset + content.lines.length} 行',
          onPrevious: busy || content == null || content.offset == 0
              ? null
              : () => select(
                  selected!,
                  (content.offset - 30).clamp(0, content.total),
                ),
          onNext: busy || content?.more != true
              ? null
              : () => select(selected!, content!.offset + 30),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: widget.title,
      subtitle: widget.explanation,
      closeTooltip: widget.readOnly ? '关闭修复核对' : '关闭预览',
      width: 980,
      height: 640,
      busy: busy,
      footerLeft: Row(
        children: [
          Dot(error.isEmpty ? d.ink3 : d.pen),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              error.isEmpty ? '尚未写入草稿' : '未应用',
              style: ui(12, c: error.isEmpty ? d.ink2 : d.pen),
            ),
          ),
        ],
      ),
      actions: [
        DeskButton(
          widget.readOnly ? '返回修复差异' : '返回调整',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        if (!widget.readOnly)
          DeskButton(
            '确认写入草稿',
            primary: true,
            icon: Icons.check_rounded,
            disabledReason: error.isNotEmpty ? '预览不可用，请返回调整' : '等待预览读取完成',
            onPressed: busy || page == null || error.isNotEmpty
                ? null
                : () => run(() async {
                    await widget.session.confirm(widget.preview);
                    if (context.mounted) Navigator.pop(context, true);
                  }),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DeskSegmented<bool>(
                value: before,
                options: const {true: '修改前', false: '修改后'},
                onChanged: busy
                    ? null
                    : (value) {
                        if (value == before) return;
                        setState(() => before = value);
                        load(page?.offset ?? 0, focus: true);
                      },
              ),
              if (widget.explanation != null) ...[
                const SizedBox(width: 8),
                DeskButton(
                  '卷前正文',
                  quiet: true,
                  icon: Icons.vertical_align_top_rounded,
                  tooltip: '查看第一个标题之前的正文',
                  onPressed: busy ? null : () => select(prefix, 0),
                ),
              ],
              const Spacer(),
              Text(before ? '当前有效稿' : '候选，确认前不生效', style: ui(11.5, c: d.ink3)),
            ],
          ),
          const SizedBox(height: 10),
          if (error.isNotEmpty) ...[
            DeskNote(error, title: '未应用', tone: Tone.pen),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => c.maxWidth >= 640
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 280, child: structure(d)),
                        const SizedBox(width: 14),
                        Expanded(child: reader(d)),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: 180, child: structure(d)),
                        const SizedBox(height: 10),
                        Expanded(child: reader(d)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
