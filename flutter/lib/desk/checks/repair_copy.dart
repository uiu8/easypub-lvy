// 另存修订 TXT 与配套项目（CH-148），一键修复和目录修复共用。
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';

/// 另存修订 TXT（含配套项目），完成后给出回执；原始文件与当前编辑稿不变。
Future<ChapterCopyReceipt?> saveRepairCopy(
  BuildContext context,
  ChapterSession session,
  ChapterEditPreview preview,
) async {
  if (session is! ChapterCopySession) return null;
  final target = await getSaveLocation(
    suggestedName: '修订书稿.txt',
    acceptedTypeGroups: const [
      XTypeGroup(label: 'TXT 书稿', extensions: ['txt']),
    ],
  );
  if (target == null) return null;
  final receipt = await (session as ChapterCopySession).exportCopy(
    preview,
    target.path,
  );
  if (context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (context) => DeskDialog(
        title: '修订副本已保存',
        closeTooltip: '关闭',
        width: 520,
        actions: [
          DeskButton(
            '知道了',
            primary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        child: SelectableText(
          'TXT：${receipt.textPath}\n\n配套项目：${receipt.projectPath}\n\n复查还有 ${receipt.remainingIssues} 项提示。打开配套项目可保留章节层级、标题识别和排版设置；原始文件与当前编辑稿均未改动。',
          style: ui(12.5, c: context.desk.ink2, h: 1.6),
        ),
      ),
    );
  }
  return receipt;
}
