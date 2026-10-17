// 生成编辑快照（CH-100–101）：保留当前书稿与可撤销记录，腾出编辑容量；原稿不变。
// 生成期间仍可取消；取消后即使后台生成完成也不切换当前稿与历史。
import 'package:flutter/material.dart';

import '../../errors.dart';

import '../../../application/chapter_service.dart';
import '../../controls/controls.dart';
import '../../dialogs.dart';
import '../../tokens.dart';

class ChapterCheckpointDialog extends StatefulWidget {
  const ChapterCheckpointDialog({
    super.key,
    required this.session,
    required this.page,
  });
  final ChapterSession session;
  final ChapterPage page;
  @override
  State<ChapterCheckpointDialog> createState() =>
      _ChapterCheckpointDialogState();
}

class _ChapterCheckpointDialogState extends State<ChapterCheckpointDialog> {
  bool busy = false;
  bool cancelled = false;
  String error = '';

  Future<void> create() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final candidate = await (widget.session as ChapterCheckpointSession)
          .previewCheckpoint(widget.page);
      // 取消只丢弃候选：后台生成可能完成，但关闭后不再切换当前稿与历史。
      if (!mounted || cancelled) return;
      await widget.session.confirm(candidate);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = deskErrorText(e, '检查点生成失败，当前书稿与编辑记录保持不变。');
        });
      }
    }
  }

  void cancel() {
    cancelled = true;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    // 生成中允许取消：不传 busy 给框架，以免锁住返回键与关闭按钮。
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) cancelled = true;
      },
      child: DeskDialog(
        title: '生成编辑快照',
        closeTooltip: '关闭生成编辑快照',
        width: 470,
        onClose: cancel,
        actions: [
          DeskButton('取消', quiet: true, onPressed: cancel),
          DeskButton(
            '生成并继续编辑',
            primary: true,
            disabledReason: '正在生成，可取消本次应用',
            onPressed: busy ? null : create,
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '保留当前书稿和可撤销记录，腾出后续编辑容量。原稿不变。',
              style: ui(12.5, c: d.ink2, h: 1.55),
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: d.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('正在生成，可取消本次应用…', style: ui(12, c: d.ink2)),
                ],
              ),
            ],
            if (error.isNotEmpty) ...[
              const SizedBox(height: 12),
              DeskNote(error, tone: Tone.pen),
            ],
          ],
        ),
      ),
    );
  }
}
