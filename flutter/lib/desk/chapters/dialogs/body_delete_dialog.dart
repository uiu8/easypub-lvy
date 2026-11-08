// 删除正文行（CH-090–095）：先单击一行，再点另一行选中两端包含的连续范围，可跨页；
// 预览后才删除，确认后可撤销，原稿不变。
import 'package:flutter/material.dart';

import '../../errors.dart';

import '../../../application/chapter_service.dart';
import '../../controls/controls.dart';
import '../../dialogs.dart';
import '../../tokens.dart';
import 'candidate_dialog.dart';

class ChapterBodyDeleteDialog extends StatefulWidget {
  const ChapterBodyDeleteDialog({
    super.key,
    required this.session,
    required this.page,
    required this.node,
  });
  final ChapterSession session;
  final ChapterPage page;
  final ChapterNode node;
  @override
  State<ChapterBodyDeleteDialog> createState() =>
      _ChapterBodyDeleteDialogState();
}

class _ChapterBodyDeleteDialogState extends State<ChapterBodyDeleteDialog> {
  ChapterBody? body;
  int? anchor, first, last;
  bool busy = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    load(0);
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await operation();
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
    if (mounted) setState(() => body = next);
  });

  int line(int offset) => widget.node.id == chapterPrefixNode.id
      ? offset
      : widget.node.line + offset;

  void choose(int offset) => setState(() {
    if (anchor == null) {
      anchor = offset;
      first = offset;
      last = offset;
    } else {
      first = anchor! < offset ? anchor : offset;
      last = anchor! > offset ? anchor : offset;
      anchor = null;
    }
  });

  Future<void> preview() async {
    ChapterEditPreview? candidate;
    await run(() async {
      candidate = await widget.session.preview(
        widget.page,
        ExcludeChapterBodyLines(widget.node.id, first!, last!),
      );
    });
    if (!mounted || candidate == null) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChapterCandidateDialog(
        session: widget.session,
        preview: candidate!,
        originalPage: widget.page,
        title: '删除正文预览',
        initialOffset: widget.page.offset,
        initialNodeId: widget.node.id,
        explanation:
            '从草稿删除有效文本第 ${line(first!)}—${line(last!)} 行，共 ${last! - first! + 1} 行。标题与其它正文保留，确认后可撤销；原稿不变。删除范围内的插图位置需重新核对。',
      ),
    );
    if (mounted && changed == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '删除正文行',
      subtitle: '单击选择一行；再点击另一行可选中连续范围，支持跨页。预览后才删除。',
      closeTooltip: '关闭删除正文行',
      width: 720,
      height: 600,
      busy: busy,
      footerLeft: Text(
        first == null
            ? '尚未选择'
            : anchor != null
            ? '已选第 ${line(first!)} 行 · 再点一行可选范围'
            : '已选第 ${line(first!)}—${line(last!)} 行，共 ${last! - first! + 1} 行',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ui(12, c: first == null ? d.ink3 : d.ink),
      ),
      actions: [
        DeskButton(
          '重新选择',
          quiet: true,
          onPressed: busy
              ? null
              : () => setState(() {
                  anchor = null;
                  first = null;
                  last = null;
                }),
        ),
        DeskButton(
          '取消',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        DeskButton(
          '预览删除',
          primary: true,
          disabledReason: '先选择要删除的行',
          onPressed: busy || first == null ? null : preview,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.node.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: serif(14, w: 650, c: d.ink),
          ),
          const SizedBox(height: 8),
          if (error.isNotEmpty) ...[
            DeskNote(error, title: '未应用', tone: Tone.pen),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: DeskListBox(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: body?.rows.length ?? 0,
                itemBuilder: (_, i) {
                  final row = body!.rows[i];
                  final inRange =
                      first != null &&
                      row.lineOffset >= first! &&
                      row.lineOffset <= last!;
                  return DeskLineRow(
                    key: ValueKey('delete-body-line-${row.lineOffset}'),
                    number: line(row.lineOffset),
                    text: row.text,
                    inRange: inRange,
                    onTap: busy ? null : () => choose(row.lineOffset),
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
        ],
      ),
    );
  }
}
