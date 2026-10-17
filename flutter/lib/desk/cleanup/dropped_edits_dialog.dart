// 章节修改无法换算时的确认（V13 采用清理；V17 起撤销 / 重做清理与批量清理共用，CLEAN-103/104）。
// 只列出无法保留的修改并请用户确认，不替用户决定。
import 'package:flutter/material.dart';

import '../../application/cleanup_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';

/// 列出 [skipped] 并请用户确认放弃；确认返回 true，取消或关闭返回 false。
Future<bool> confirmDroppedChapterEdits(
  BuildContext context, {
  required String title,
  required String confirm,
  required String lead,
  required List<CleanupSkippedEdit> skipped,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => DeskDialog(
      title: title,
      closeTooltip: '取消',
      width: 520,
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.pop(dialogContext, false),
        ),
        DeskButton(
          confirm,
          primary: true,
          onPressed: () => Navigator.pop(dialogContext, true),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(lead, style: ui(12.5, c: dialogContext.desk.ink2)),
          const SizedBox(height: 10),
          for (final s in skipped.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '第 ${s.index + 1} 处 · ${s.action}：${s.reason}',
                key: Key('cleanup-dropped-edit-${s.index}'),
                style: ui(12.5),
              ),
            ),
          if (skipped.length > 8)
            Text(
              '另有 ${skipped.length - 8} 处。',
              style: ui(12, c: dialogContext.desk.ink3),
            ),
        ],
      ),
    ),
  );
  return confirmed == true;
}

/// 撤销或重做清理遇到无法换算的章节修改时：确认后放弃这些修改并完成这一步。
/// 返回是否已完成；用户取消时返回 false，状态不变。
Future<bool> resolveCleanupEditConfirmation(
  BuildContext context,
  CleanupEditsNeedConfirmation request,
) async {
  final step = request.redo ? '重做' : '撤销';
  final ok = await confirmDroppedChapterEdits(
    context,
    title: '放弃 ${request.skipped.length} 处章节修改并$step清理？',
    confirm: '放弃这些修改并$step',
    lead:
        '其余 ${request.kept} 处章节修改会换算到$step后的文本并保留。'
        '下面这些修改对应的行在$step后不存在或已改变，无法保留；'
        '完成后仍可在变更记录中撤销。',
    skipped: request.skipped,
  );
  if (!ok) return false;
  await request.proceed();
  return true;
}
