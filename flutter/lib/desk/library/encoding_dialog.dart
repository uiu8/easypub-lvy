// 选择编码（G-114）：左边编码列表，右边显示前 30 行，看着对就用。
import 'package:flutter/material.dart';

import '../../application/text_encoding_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../errors.dart';
import '../tokens.dart';

/// 返回选中的编码；取消时为空。[note] 写在列表上面，说明为什么要选。
Future<String?> showEncodingDialog(
  BuildContext context,
  TextEncodingService service,
  String path, {
  required String note,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => EncodingDialog(service: service, path: path, note: note),
);

class EncodingDialog extends StatefulWidget {
  const EncodingDialog({
    super.key,
    required this.service,
    required this.path,
    required this.note,
  });
  final TextEncodingService service;
  final String path, note;
  @override
  State<EncodingDialog> createState() => _EncodingDialogState();
}

class _EncodingDialogState extends State<EncodingDialog> {
  EncodingProbe? probe;
  String? chosen;
  String error = '';

  @override
  void initState() {
    super.initState();
    read();
  }

  Future<void> read() async {
    try {
      final value = await widget.service.probeEncoding(widget.path);
      if (!mounted) return;
      setState(() {
        probe = value;
        chosen =
            value.suggested ??
            value.candidates.where((c) => c.ok).firstOrNull?.label;
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '文件读不出来，请确认文件还在。'));
      }
    }
  }

  EncodingChoice? get current =>
      probe?.candidates.where((c) => c.label == chosen).firstOrNull;

  Widget choice(EncodingChoice c) {
    final d = context.desk;
    final on = c.label == chosen;
    final label = [
      c.name,
      if (c.label == probe?.suggested) '建议',
      if (c.label == probe?.auto) '自动判断',
      if (!c.ok) '解不开',
    ];
    return InkWell(
      key: ValueKey(('encoding-choice', c.label)),
      onTap: c.ok ? () => setState(() => chosen = c.label) : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: on ? d.accentSoft : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.name,
              style: ui(13, w: on ? 600 : 400, c: c.ok ? d.ink : d.ink3),
            ),
            if (label.length > 1)
              Text(label.skip(1).join(' · '), style: ui(11, c: d.ink3)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final view = current;
    return DeskDialog(
      title: '选择编码',
      subtitle: widget.path.replaceAll('\\', '/').split('/').last,
      closeTooltip: '取消',
      width: 860,
      height: 620,
      scrollBody: false,
      actions: [
        DeskButton('取消', onPressed: () => Navigator.pop(context)),
        DeskButton(
          '用这个编码',
          key: const ValueKey('encoding-use'),
          primary: true,
          onPressed: chosen == null
              ? null
              : () => Navigator.pop(context, chosen),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.note, style: ui(13, c: d.ink2)),
          const SizedBox(height: 10),
          Expanded(
            child: error.isNotEmpty
                ? Text(error, style: ui(13, c: d.pen))
                : probe == null
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 210,
                        child: ListView(
                          children: [
                            for (final c in probe!.candidates) choice(c),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: d.line),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: view == null || !view.ok
                              ? Text('这种编码解不开这个文件。', style: ui(13, c: d.ink3))
                              : ListView(
                                  key: ValueKey(('encoding-lines', view.label)),
                                  children: [
                                    for (final line in view.lines)
                                      Text(
                                        line,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: serif(14, c: d.ink, h: 1.7),
                                      ),
                                  ],
                                ),
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
