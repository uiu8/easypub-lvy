// 一键目录修复的目录身份核对（CH-246）：显示书名、作者、来源、条目数与完整性，
// 必须勾选“已核对”才可继续；取消返回参考目录页，不改书稿。
import 'package:flutter/material.dart';

import '../../application/catalog_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

class CatalogQuickIdentityDialog extends StatefulWidget {
  const CatalogQuickIdentityDialog({
    super.key,
    required this.snapshot,
    required this.candidate,
  });
  final CatalogSnapshot snapshot;

  /// 新取得、尚未保存的目录。
  final bool candidate;
  @override
  State<CatalogQuickIdentityDialog> createState() =>
      _CatalogQuickIdentityDialogState();
}

class _CatalogQuickIdentityDialogState
    extends State<CatalogQuickIdentityDialog> {
  bool confirmed = false;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final s = widget.snapshot;
    final completeness = switch (s.completeness) {
      'complete' => ('声明范围完整', Tone.ok),
      'partial' => ('目录不完整', Tone.warn),
      _ => ('完整性未确认', Tone.warn),
    };
    Widget kv(String k, String v, {Widget? tail}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(k, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: Text(v, style: ui(12.5, c: d.ink)),
          ),
          ?tail,
        ],
      ),
    );
    return DeskDialog(
      title: '一键目录修复 · 核对目录身份',
      subtitle: '确认这份目录属于本书后，对齐当前书稿并打开目录修复预览；预览确认前不改书稿。',
      closeTooltip: '取消一键目录修复',
      width: 520,
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.pop(context, false),
        ),
        DeskButton(
          '对齐并预览修复',
          key: const ValueKey('catalog-quick-continue'),
          primary: true,
          icon: Icons.arrow_forward_rounded,
          disabledReason: '先勾选“已核对书名、作者、来源和目录范围”',
          onPressed: confirmed ? () => Navigator.pop(context, true) : null,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          kv('书名', s.title),
          kv('作者', s.author.isEmpty ? '作者未提供' : s.author),
          kv('来源', s.origin == 'paste' ? '粘贴文本' : s.origin),
          kv(
            '目录',
            '${s.entries.length} 条',
            tail: DeskTag(completeness.$1, completeness.$2),
          ),
          if (widget.candidate)
            kv('状态', '新来源，尚未保存为本书目录快照')
          else
            kv('状态', '本书已保存的目录快照'),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => setState(() => confirmed = !confirmed),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                Checkbox(
                  key: const ValueKey('catalog-quick-identity'),
                  value: confirmed,
                  onChanged: (v) => setState(() => confirmed = v == true),
                ),
                Expanded(
                  child: Text(
                    '已核对书名、作者、来源和目录范围',
                    style: ui(13, w: 560, c: d.ink),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
