// 迁入 desk（layout，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../../application/book_information_service.dart';
import '../../application/layout_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

const batchFieldLabels = {
  ...bookInformationFields,
  'cover': '图片、适配与裁切',
  ...layoutNumbers,
  ...layoutFlags,
  'font_size_unit': '字号单位',
  'text_alignment': '文字对齐',
  'writing_mode': '书写方向',
  'vertical_digits': '竖排数字横排',
  'heading_style': '章节标题样式',
  'scene_break_style': '场景分隔',
  'first_paragraph_style': '章首段落',
  'rare_char_ruby': '生僻字注音',
  'rare_char_scope': '生僻字范围',
  'chapter_head_scope': '章首图用于',
  'chapter_head_width': '章首图宽度',
  'system_block_style': '系统提示',
  'verse_block_style': '诗词',
  'note_style': '弹出注释',
  'margin_top_unit': '上边距单位',
  'margin_bottom_unit': '下边距单位',
  'margin_left_unit': '左边距单位',
  'margin_right_unit': '右边距单位',
};
const batchCoverLabels = {
  'cover_path': '封面图片',
  'cover_fit': '适配方式',
  'cover_crop': '裁切区域',
  'cover_design': '文字封面参数',
};
String describeBatchValue(String field, Object? value) {
  if (value == null || value == '') return '未设置';
  if (value is bool) return value ? '开启' : '关闭';
  if (field == 'cover_fit') return value == 'cover' ? '裁切填充' : '完整显示 · 保持比例';
  if (field == 'writing_mode') return value == 'vertical' ? '竖排' : '横排';
  if (field == 'vertical_digits') return value == 0 ? '不横排' : '$value 位';
  if (field == 'heading_style') return headingStyles[value] ?? '$value';
  if (field == 'scene_break_style') return sceneBreakStyles[value] ?? '$value';
  if (field == 'first_paragraph_style') {
    return firstParagraphStyles[value] ?? '$value';
  }
  if (field == 'rare_char_ruby') return rareCharRubyModes[value] ?? '$value';
  if (field == 'rare_char_scope') return rareCharScopes[value] ?? '$value';
  if (field == 'system_block_style') {
    return systemBlockStyles[value] ?? '$value';
  }
  if (field == 'verse_block_style') return verseBlockStyles[value] ?? '$value';
  if (field == 'note_style') return noteStyles[value] ?? '$value';
  if (field == 'chapter_head_scope') {
    return chapterHeadScopes[value] ?? '$value';
  }
  if (field == 'chapter_head_width') {
    return chapterHeadWidths[value] ?? '$value';
  }
  if (field == 'text_alignment') {
    return {
          'start': '段首对齐',
          'left': '左对齐',
          'center': '居中',
          'right': '右对齐',
          'justify': '两端对齐',
        }[value] ??
        '$value';
  }
  if (field == 'cover_crop' && value is Map) {
    String percent(String key) =>
        '${((value[key] as num) * 100).toStringAsFixed(1)}%';
    return '左 ${percent('x')} · 上 ${percent('y')} · 宽 ${percent('width')} · 高 ${percent('height')}';
  }
  if (field == 'cover_design' && value is Map) {
    const colors = {
      0xff23664f: '河岸绿',
      0xff82705a: '暖棕',
      0xff5e6d7d: '灰蓝',
      0xff694c52: '酒红',
    };
    return '标题：${value['title']}；署名：${value['author']}；系列：${value['series']}；${colors[value['color']] ?? '自定义色'}';
  }
  return '$value';
}

class BatchFieldDialog extends StatefulWidget {
  const BatchFieldDialog({super.key, required this.selected});
  final Set<String> selected;
  @override
  State<BatchFieldDialog> createState() => _BatchFieldDialogState();
}

class _BatchFieldDialogState extends State<BatchFieldDialog> {
  late final draft = Set<String>.of(widget.selected);

  /// 全部字段（全选用；G-067）。
  Iterable<String> get allFields => batchFieldLabels.keys;
  void setMany(Iterable<String> keys, bool value) => setState(() {
    value ? draft.addAll(keys) : draft.removeAll(keys);
  });

  /// 每组标题前有本组的三态勾选框。
  Widget group(String title, Iterable<String> keys) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 8, 4),
        child: SelectAllHeader(
          selected: keys.where(draft.contains).length,
          total: keys.length,
          padding: EdgeInsets.zero,
          onChanged: (v) => setMany(keys, v),
          body: DeskText(title, bold: true, color: context.desk.accent),
        ),
      ),
      Wrap(
        children: [
          for (final key in keys)
            SizedBox(
              width: 286,
              child: CheckboxListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                controlAffinity: ListTileControlAffinity.leading,
                title: DeskText(batchFieldLabels[key]!, size: 13),
                value: draft.contains(key),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    draft.add(key);
                  } else {
                    draft.remove(key);
                  }
                }),
              ),
            ),
        ],
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: context.desk.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: SizedBox(
      width: 624,
      height: 600,
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: DeskText('选择要复制的字段', size: 22, bold: true),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectAllHeader(
              selected: draft.length,
              total: allFields.length,
              padding: EdgeInsets.zero,
              onChanged: (v) => setMany(allFields, v),
              body: DeskText(
                '只复制勾选项；来源为空的字段也会清空目标值，请在预览中核对。',
                size: 12,
                color: context.desk.ink2,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: SelectionKeys(
                hasSelection: draft.isNotEmpty,
                onSelectAll: () => setMany(allFields, true),
                onClear: () => setMany(allFields, false),
                child: DeskScrollView(
                  child: Column(
                    children: [
                      group('书籍信息', bookInformationFields.keys),
                      group('封面', const ['cover']),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: DeskText(
                          '封面组包含现有文字封面参数；不会自动按目标书名重新生成图片。',
                          size: 12,
                          color: context.desk.ink2,
                        ),
                      ),
                      group('文字与页面', layoutFields),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 28),
            Row(
              children: [
                DeskButton(
                  '取消',
                  quiet: true,
                  onPressed: () => Navigator.pop(context),
                ),
                const Spacer(),
                DeskText(
                  '已选 ${draft.length} 项',
                  size: 12,
                  color: context.desk.ink2,
                ),
                const SizedBox(width: 14),
                DeskButton(
                  '采用所选字段',
                  primary: true,
                  onPressed: () => Navigator.pop(context, draft),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
