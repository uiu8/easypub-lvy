// 改名（CH-045–049）与在本章前新增卷（CH-060–064）：输入标题 → 生成候选 → 修改前后预览确认。
// 输入草稿经 onTitleChanged 写入工作区；取消或完成后由调用方清除。
import 'package:flutter/material.dart';

import '../../errors.dart';

import '../../../application/chapter_service.dart';
import '../../controls/controls.dart';
import '../../dialogs.dart';
import '../../tokens.dart';
import 'candidate_dialog.dart';

class ChapterRenameDialog extends StatelessWidget {
  const ChapterRenameDialog({
    super.key,
    required this.session,
    required this.page,
    required this.node,
    this.initialTitle,
    this.onTitleChanged,
  });
  final ChapterSession session;
  final ChapterPage page;
  final ChapterNode node;
  final String? initialTitle;
  final ValueChanged<String>? onTitleChanged;
  @override
  Widget build(BuildContext context) => _TitleEditDialog(
    session: session,
    page: page,
    node: node,
    initialTitle: initialTitle ?? node.title,
    onTitleChanged: onTitleChanged,
    title: '修改章节标题',
    closeTooltip: '关闭改名',
    referenceLabel: '原标题',
    inputLabel: '新标题',
    inputKey: const ValueKey('chapter-rename-input'),
    note: '只修改当前章节标题；正文保持不变。确认后可撤销。',
    previewTitle: '改名预览',
    mustDiffer: true,
    edit: (text) => RenameChapter(node.id, text),
  );
}

class ChapterVolumeDialog extends StatelessWidget {
  const ChapterVolumeDialog({
    super.key,
    required this.session,
    required this.page,
    required this.node,
    this.initialTitle,
    this.onTitleChanged,
  });
  final ChapterSession session;
  final ChapterPage page;
  final ChapterNode node;
  final String? initialTitle;
  final ValueChanged<String>? onTitleChanged;
  @override
  Widget build(BuildContext context) => _TitleEditDialog(
    session: session,
    page: page,
    node: node,
    initialTitle: initialTitle ?? '',
    onTitleChanged: onTitleChanged,
    title: '在当前章前新增卷',
    closeTooltip: '关闭新增卷',
    referenceLabel: '插入位置：以下章节之前',
    inputLabel: '新卷标题',
    inputKey: const ValueKey('chapter-volume-input'),
    note: '在当前章前插入卷标题；后续章节按卷结构归属，正文保留。预览后确认，可撤销。',
    previewTitle: '新增卷预览',
    mustDiffer: false,
    edit: (text) => InsertChapterVolume(node.id, text),
  );
}

class _TitleEditDialog extends StatefulWidget {
  const _TitleEditDialog({
    required this.session,
    required this.page,
    required this.node,
    required this.initialTitle,
    required this.onTitleChanged,
    required this.title,
    required this.closeTooltip,
    required this.referenceLabel,
    required this.inputLabel,
    required this.inputKey,
    required this.note,
    required this.previewTitle,
    required this.mustDiffer,
    required this.edit,
  });
  final ChapterSession session;
  final ChapterPage page;
  final ChapterNode node;
  final String initialTitle;
  final ValueChanged<String>? onTitleChanged;
  final String title, closeTooltip, referenceLabel, inputLabel, note;
  final String previewTitle;
  final Key inputKey;
  final bool mustDiffer;
  final ChapterEdit Function(String title) edit;
  @override
  State<_TitleEditDialog> createState() => _TitleEditDialogState();
}

class _TitleEditDialogState extends State<_TitleEditDialog> {
  late final controller = TextEditingController(text: widget.initialTitle);
  bool busy = false, dirty = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    controller.addListener(() => widget.onTitleChanged?.call(controller.text));
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// 不能为空、不能换行、最多 1000 字；改名还须与原标题不同（CH-046/061）。
  String? get problem {
    final text = controller.text;
    if (text.trim().isEmpty) return '请填写标题';
    if (text.contains(RegExp(r'[\r\n]'))) return '标题不能换行';
    if (text.runes.length > 1000) return '标题最多 1000 字';
    if (widget.mustDiffer && text.trim() == widget.node.title) {
      return '新标题与原标题相同';
    }
    return null;
  }

  Future<void> prepare() async {
    if (busy || problem != null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final candidate = await widget.session.preview(
        widget.page,
        widget.edit(controller.text.trim()),
      );
      if (!mounted) return;
      setState(() => busy = false);
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ChapterCandidateDialog(
          session: widget.session,
          preview: candidate,
          originalPage: widget.page,
          initialOffset: widget.page.offset,
          initialNodeId: widget.node.id,
          title: widget.previewTitle,
        ),
      );
      if (mounted && confirmed == true) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '操作没有完成。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reason = problem;
    return DeskDialog(
      title: widget.title,
      closeTooltip: widget.closeTooltip,
      width: 460,
      busy: busy,
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        DeskButton(
          '预览并确认',
          primary: true,
          disabledReason: reason,
          onPressed: busy || reason != null ? null : prepare,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeskReadonlyField(
            label: widget.referenceLabel,
            value: widget.node.title,
          ),
          const SizedBox(height: 12),
          DeskLabel(widget.inputLabel),
          TextField(
            key: widget.inputKey,
            controller: controller,
            autofocus: true,
            enabled: !busy,
            style: ui(13.5, c: context.desk.ink),
            decoration: deskInput(context, error: dirty ? reason : null),
            onChanged: (_) => setState(() {
              dirty = true;
              error = '';
            }),
            onSubmitted: (_) => prepare(),
          ),
          const SizedBox(height: 12),
          DeskNote(widget.note),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 10),
            DeskNote(error, title: '无法预览', tone: Tone.pen),
          ],
        ],
      ),
    );
  }
}
