// 清理源行范围（CLEAN-018–021）：导入原稿行号，含起止行；留空表示该侧不限。
import 'package:flutter/material.dart';

import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';

class CleanupRange {
  const CleanupRange(this.start, this.end);
  final int? start, end;
}

class CleanupRangeDialog extends StatefulWidget {
  const CleanupRangeDialog({super.key, this.start, this.end});
  final int? start, end;
  @override
  State<CleanupRangeDialog> createState() => _CleanupRangeDialogState();
}

class _CleanupRangeDialogState extends State<CleanupRangeDialog> {
  late final start = TextEditingController(
    text: widget.start?.toString() ?? '',
  );
  late final end = TextEditingController(text: widget.end?.toString() ?? '');
  String error = '';
  @override
  void dispose() {
    start.dispose();
    end.dispose();
    super.dispose();
  }

  void save() {
    int? number(TextEditingController c) {
      if (c.text.trim().isEmpty) return null;
      final value = int.tryParse(c.text.trim());
      if (value == null || value < 1 || value > 0xffffffff) {
        throw const FormatException('源行号须为有效正整数。');
      }
      return value;
    }

    try {
      final first = number(start), last = number(end);
      if (first != null && last != null && first > last) {
        throw const FormatException('结束源行不能早于起始源行。');
      }
      Navigator.pop(context, CleanupRange(first, last));
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  Widget field(String label, TextEditingController c) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DeskLabel(label),
      TextField(
        controller: c,
        keyboardType: TextInputType.number,
        style: mono(13, c: context.desk.ink),
        decoration: deskInput(context, hint: '留空不限'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => DeskDialog(
    title: '清理源行范围',
    subtitle: '使用导入原稿的行号，包含起止行。留空表示该侧不限；修改范围不会清空已有保留或候选选择。',
    closeTooltip: '取消',
    width: 540,
    actions: [
      DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
      DeskButton('使用此范围', primary: true, onPressed: save),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: field('起始源行', start)),
            const SizedBox(width: 12),
            Expanded(child: field('结束源行', end)),
          ],
        ),
        if (error.isNotEmpty) ...[
          const SizedBox(height: 12),
          DeskNote(error, tone: Tone.pen),
        ],
      ],
    ),
  );
}
