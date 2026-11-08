// 拆分章节 / 正文行设为标题（CH-050–059、CH-010）：选一行 → 生成候选 → 弹窗内核对结构 → 确认。
// 设为标题模式沿用被选行文字，卷内深度为卷 +1；翻页清除行选择。
import 'package:flutter/material.dart';

import '../../errors.dart';

import '../../../application/chapter_service.dart';
import '../../controls/controls.dart';
import '../../dialogs.dart';
import '../../tokens.dart';

class ChapterSplitDialog extends StatefulWidget {
  const ChapterSplitDialog({
    super.key,
    required this.session,
    required this.page,
    required this.node,
    this.useExistingLine = false,
    this.initialTitle,
    this.onTitleChanged,
  });
  final bool useExistingLine;
  final ChapterSession session;
  final ChapterPage page;
  final ChapterNode node;
  final String? initialTitle;
  final ValueChanged<String>? onTitleChanged;
  @override
  State<ChapterSplitDialog> createState() => _ChapterSplitDialogState();
}

class _ChapterSplitDialogState extends State<ChapterSplitDialog> {
  ChapterBody? body;
  ChapterBodyRow? selected;
  ChapterEditPreview? preview;
  ChapterPage? result;
  late final titleController = TextEditingController(
    text: widget.initialTitle ?? '',
  );
  String error = '';
  bool busy = false;

  String get title => titleController.text;

  @override
  void initState() {
    super.initState();
    load(0);
  }

  @override
  void dispose() {
    titleController.dispose();
    super.dispose();
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

  Future<void> load(int offset) => run(() async {
    final next = await widget.session.body(widget.page, widget.node.id, offset);
    if (mounted) {
      setState(() {
        body = next;
        selected = null;
      });
    }
  });

  Future<void> prepare() => run(() async {
    final candidate = await widget.session.preview(
      widget.page,
      widget.useExistingLine
          ? CreateChapterBoundary(
              widget.node.id,
              selected!.lineOffset,
              depth: widget.node.role == 'volume'
                  ? widget.node.depth + 1
                  : widget.node.depth,
            )
          : SplitChapter(widget.node.id, selected!.lineOffset, title.trim()),
    );
    final tree = await widget.session.previewTree(
      candidate,
      widget.page.offset,
    );
    if (mounted) {
      setState(() {
        preview = candidate;
        result = tree;
      });
    }
  });

  int lineNumber(ChapterBodyRow row) => widget.node.id == chapterPrefixNode.id
      ? row.lineOffset
      : widget.node.line + row.lineOffset;

  String? get problem {
    if (selected == null) {
      return widget.useExistingLine ? '先选择作为标题的正文行' : '先选择新章节开始的正文行';
    }
    if (!widget.useExistingLine && title.trim().isEmpty) return '请填写新标题';
    return null;
  }

  Widget chooser(Desk d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        widget.node.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: serif(14, w: 650, c: d.ink),
      ),
      const SizedBox(height: 10),
      DeskLabel(widget.useExistingLine ? '选择作为章节标题的原有正文行' : '选择新章节开始的正文行'),
      Expanded(
        child: DeskListBox(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: body?.rows.length ?? 0,
            itemBuilder: (_, i) {
              final row = body!.rows[i];
              return DeskLineRow(
                number: lineNumber(row),
                text: row.text,
                selected: identical(row, selected),
                onTap: busy || !row.selectable
                    ? null
                    : () => setState(() => selected = row),
              );
            },
          ),
        ),
      ),
      const SizedBox(height: 4),
      DeskPager(
        previous: '前 30 行',
        next: '后 30 行',
        info: '共 ${body?.total ?? 0} 行',
        onPrevious: busy || body == null || body!.offset == 0
            ? null
            : () => load((body!.offset - 30).clamp(0, body!.total)),
        onNext: busy || body?.more != true
            ? null
            : () => load(body!.offset + 30),
      ),
      if (!widget.useExistingLine) ...[
        const SizedBox(height: 8),
        const DeskLabel('新标题'),
        TextField(
          key: const ValueKey('split-title'),
          controller: titleController,
          enabled: !busy,
          maxLength: 1000,
          style: ui(13.5, c: d.ink),
          decoration: deskInput(context, hint: '下半段成为新章的标题'),
          onChanged: (v) {
            setState(() {});
            widget.onTitleChanged?.call(v);
          },
        ),
      ],
    ],
  );

  Widget review(Desk d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DeskNote('结构节点：${widget.page.total} → ${result!.total}；尚未写入草稿。'),
      const SizedBox(height: 10),
      Expanded(
        child: DeskListBox(
          paper: false,
          child: ListView.builder(
            padding: const EdgeInsets.all(4),
            itemCount: result!.nodes.length,
            itemBuilder: (_, i) {
              final node = result!.nodes[i];
              return Padding(
                padding: EdgeInsets.only(left: node.depth.clamp(0, 4) * 10.0),
                child: DeskChoiceRow(
                  radio: false,
                  title: node.title,
                  detail: '有效文本第 ${node.line} 行',
                ),
              );
            },
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text('显示当前结构页；采用前已校验正文与结构。', style: ui(11.5, c: d.ink3)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final reviewing = preview != null;
    final reason = reviewing ? null : problem;
    return DeskDialog(
      title: widget.useExistingLine
          ? (reviewing ? '新增标题预览' : '正文行设为标题')
          : (reviewing ? '分章预览' : '从此处分章'),
      subtitle: widget.useExistingLine
          ? '选中行文字直接成为标题，不重复插入文字；原正文保留。'
          : '上半段保留原章名，下半段成为新章。原文保留，确认后可撤销。',
      closeTooltip: widget.useExistingLine ? '关闭新增标题' : '关闭分章',
      width: 720,
      height: 600,
      busy: busy,
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        if (reviewing)
          DeskButton(
            '返回调整',
            quiet: true,
            onPressed: busy
                ? null
                : () => setState(() {
                    preview = null;
                    result = null;
                  }),
          ),
        DeskButton(
          reviewing ? (widget.useExistingLine ? '确认新增标题' : '确认分章') : '预览并确认',
          primary: true,
          disabledReason: reason,
          onPressed: busy || reason != null
              ? null
              : () {
                  if (!reviewing) {
                    prepare();
                  } else {
                    run(() async {
                      await widget.session.confirm(preview!);
                      if (context.mounted) Navigator.pop(context, true);
                    });
                  }
                },
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error.isNotEmpty) ...[
            DeskNote(error, title: '未应用', tone: Tone.pen),
            const SizedBox(height: 10),
          ],
          Expanded(child: reviewing ? review(d) : chooser(d)),
        ],
      ),
    );
  }
}
