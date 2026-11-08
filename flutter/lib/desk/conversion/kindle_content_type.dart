import 'package:flutter/material.dart';

import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';

bool supportsKindleContentType(String format) =>
    format == 'KFX' || format == 'AZW3';
String kindleContentTypeLabel(String value, String format) => switch (value) {
  'PDOC' => '个人文档（PDOC）',
  'EBOK' => '书籍（EBOK）',
  _ => '沿用旧行为（${format == 'KFX' ? 'PDOC' : 'EBOK'}）',
};
const kindleTypeNote = '只改分类，不改排版，不会上传书籍。';
const ebokNote = '联网同步时，有些自己传进去的书可能被删除。';
const pdocNote = '担心删书可以选这个，但不保证完全避免。';

Future<String?> showKindleContentTypeIntro(
  BuildContext context, {
  bool keepExisting = false,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (context) => DeskDialog(
    title: '担心 Kindle 联网后删书？',
    closeTooltip: '暂不选择',
    subtitle: '仅适用于 KFX / AZW3',
    width: 640,
    actions: [
      DeskButton('改用个人文档', onPressed: () => Navigator.pop(context, 'PDOC')),
      DeskButton(
        keepExisting ? '保持当前选择' : '保持默认',
        primary: true,
        onPressed: () => Navigator.pop(context, 'keep'),
      ),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DeskText('书籍（EBOK，默认）', bold: true),
        const SizedBox(height: 8),
        const DeskText(ebokNote),
        const SizedBox(height: 20),
        const DeskText('个人文档（PDOC）', bold: true),
        const SizedBox(height: 8),
        const DeskText(pdocNote),
        const SizedBox(height: 20),
        const DeskText(kindleTypeNote),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const DeskText('固件版本与适用范围', size: 12),
          children: const [
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: DeskText(
                '删书实测：Oasis 2 / 5.16.2.1.1，测试中 EBOK 被删除，PDOC 未被删除。其他固件尚无统一保证。\n\n'
                'KFX 个人文档封面：5.15.1 及以后支持。这是封面支持条件，不是“防删”版本线；不套用于 AZW3。',
                size: 12,
              ),
            ),
          ],
        ),
      ],
    ),
  ),
);

class KindleContentTypeControl extends StatelessWidget {
  const KindleContentTypeControl({
    super.key,
    required this.value,
    required this.format,
    required this.enabled,
    required this.onChanged,
    required this.onHelp,
  });
  final String value, format;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onHelp;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const DeskText('Kindle 内容类型', bold: true),
            DeskButton('了解区别', quiet: true, onPressed: enabled ? onHelp : null),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final type in ['EBOK', 'PDOC'])
              DeskButton(
                kindleContentTypeLabel(type, format),
                key: ValueKey('kindle-type-$type'),
                primary: value == type,
                onPressed: enabled ? () => onChanged(type) : null,
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (value == 'default')
          Text(
            '${kindleContentTypeLabel(value, format)}，选择上方类型后才改变本次输出。',
            style: ui(12, c: d.ink2),
          ),
        Text(
          value == 'PDOC' || (value == 'default' && format == 'KFX')
              ? pdocNote
              : ebokNote,
          style: ui(12.5, c: d.ink2, h: 1.6),
        ),
        const SizedBox(height: 4),
        Text(kindleTypeNote, style: ui(12, c: d.ink3, h: 1.6)),
        Text(
          '仅用于 KFX、AZW3；本次选择应用于所有勾选的书稿。',
          style: ui(11.5, c: d.ink3, h: 1.6),
        ),
      ],
    );
  }
}
