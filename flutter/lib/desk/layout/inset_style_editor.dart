import 'package:flutter/material.dart';

import '../../application/layout_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 场景样式编辑器（V82，LAY-136）：逐项调参数，右侧按成品 CSS 的规则近似预览。
/// 结果：应用到本书（name 为 null），或另存为“我的场景样式”（带名称，同时应用）。
class InsetStyleEdit {
  const InsetStyleEdit(this.style, {this.name});
  final Map<String, Object> style;
  final String? name;
}

/// 每个参数的取值与名称；顺序即界面顺序。`names` 只对聊天显示。
const insetStyleChoices = <String, (String, Map<Object, String>)>{
  'border': (
    '外框',
    {
      'none': '无',
      'left': '左线',
      'top_bottom': '上下',
      'full': '四周',
      'frame': '双框',
    },
  ),
  'line': ('线型', {'solid': '实线', 'double': '双线', 'dashed': '虚线'}),
  'weight': ('粗细', {'thin': '细', 'thick': '粗', 'heavy': '很粗'}),
  'corner': ('四角', {'square': '直角', 'round': '圆角'}),
  'shade': ('底色', {'none': '无', 'light': '浅灰', 'medium': '中灰', 'paper': '淡纸纹'}),
  'head': (
    '标题',
    {
      'plain': '普通',
      'bold': '加粗',
      'spaced': '居中拉开',
      'underline': '居中下划线',
      'big': '居中大字',
    },
  ),
  'ornament': (
    '标题饰纹',
    {'none': '无', 'diamond': '◆', 'mark': '※', 'lenticular': '〖〗'},
  ),
  'align': ('正文对齐', {'start': '靠左', 'center': '居中'}),
  'size': ('字号', {85: '85%', 90: '90%', 100: '100%'}),
  'indent': ('首行缩进', {true: '缩进', false: '不缩进'}),
  'drop': ('首字放大', {false: '关', true: '开'}),
  'font': ('字体', {'body': '正文', 'kai': '楷体', 'mono': '等宽'}),
  'rods': ('卷轴杆', {false: '无', true: '上下'}),
  'names': ('名字位置', {'block': '发言上方', 'center': '居中', 'inline': '同一行'}),
};

Future<InsetStyleEdit?> showInsetStyleEditor(
  BuildContext context, {
  required String scene,
  required Map<String, Object> initial,
  required Set<String> takenNames,
}) => showDialog<InsetStyleEdit>(
  context: context,
  builder: (_) =>
      _Editor(scene: scene, initial: initial, takenNames: takenNames),
);

class _Editor extends StatefulWidget {
  const _Editor({
    required this.scene,
    required this.initial,
    required this.takenNames,
  });
  final String scene;
  final Map<String, Object> initial;
  final Set<String> takenNames;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final style = Map<String, Object>.from(widget.initial);
  final name = TextEditingController();

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  String? get nameError {
    final n = name.text.trim();
    if (n.isEmpty) return null;
    if (n.length > 24) return '名称最多 24 个字';
    if (widget.takenNames.contains(n)) return '已有同名的样式';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final presets = {
      for (final e in insetStylePresets.entries)
        if (e.value.$1 == widget.scene) e.key: e.value,
    };
    final rows = [
      if (presets.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 6,
            children: [
              for (final e in presets.entries)
                DeskButton(
                  '从“${e.value.$2}”开始',
                  key: ValueKey(('inset-editor-preset', e.key)),
                  quiet: true,
                  onPressed: () => setState(
                    () => style
                      ..clear()
                      ..addAll(e.value.$3),
                  ),
                ),
            ],
          ),
        ),
      for (final e in insetStyleChoices.entries)
        if (e.key != 'names' || widget.scene == 'chat')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(e.value.$1, style: ui(12, c: d.ink2)),
                ),
                Flexible(
                  child: KeyedSubtree(
                    key: ValueKey('inset-editor-${e.key}'),
                    child: DeskSegmented<Object>(
                      value: style[e.key]!,
                      options: e.value.$2,
                      onChanged: (v) => setState(() => style[e.key] = v),
                    ),
                  ),
                ),
              ],
            ),
          ),
    ];
    return DeskDialog(
      title: '编辑场景样式：${insetTypes[widget.scene]}',
      closeTooltip: '关闭',
      width: 900,
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        DeskButton(
          name.text.trim().isEmpty ? '应用到本书' : '另存并应用',
          key: const ValueKey('inset-editor-apply'),
          primary: true,
          onPressed: nameError != null
              ? null
              : () => Navigator.of(context).pop(
                  InsetStyleEdit(
                    style,
                    name: name.text.trim().isEmpty ? null : name.text.trim(),
                  ),
                ),
        ),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...rows,
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('inset-editor-name'),
                  controller: name,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '另存为我的场景样式（名称）',
                    errorText: nameError,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                Text(
                  '只能调这些选项，样式由程序生成，保证 Kindle 深色模式与 KFX 都能正常显示。'
                  'AZW3 不显示底色与楷体，双线显示成单线。各场景特有的部分（聊天的时间、动态的转评赞、'
                  '剪报的报头等）保持内置写法；更自由的写法是在“附加 CSS”里用公开类名 .inset-${widget.scene}、'
                  '.inset-head、.inset-body、.inset-end 自己写。',
                  style: ui(11.5, c: d.ink3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 9,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('预览（近似，以真机预览为准）', style: ui(11.5, c: d.ink3)),
                const SizedBox(height: 6),
                InsetStylePreview(scene: widget.scene, style: style),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 各场景的示例文字：(标题, 正文, 落款)。
const _samples = {
  'chat': ('九州一号群', '四：以雕像作为封印阵法，不排除。', '一：眉心开裂，是不是封印不稳？'),
  'post': ('林小满 @xiaoman · 3 分钟前', '今天的江面，像被谁打翻了一整瓶月光。', ''),
  'forum': ('1 楼　楼主', '有人知道昨晚城西那道金光是什么吗？', ''),
  'diary': ('九月十二日　星期四　阴', '今天又梦见那扇门。门后有人叫我的名字。', ''),
  'classic': ('九阴真经', '天之道，损有余而补不足，是故虚胜实，不足胜有余。', ''),
  'edict': ('奉天承运　皇帝诏曰', '镇北侯沈氏，忠勇可嘉，着即晋封国公。', '钦此'),
  'scroll': ('契约', '立约人以血为誓：自今日起，灰塔守望者听命于持戒之人。', '——灰塔之印'),
  'notice': ('悬赏', '“红鸦”伊莲娜 · 生死不论', '王都治安厅 立'),
  'news': ('江城晚报', '城西夜现金光，专家称系罕见天象。', ''),
};

/// 按 Rust `inset_styles` 生成 CSS 的同一套规则近似画出成品效果。
class InsetStylePreview extends StatelessWidget {
  const InsetStylePreview({
    super.key,
    required this.scene,
    required this.style,
  });
  final String scene;
  final Map<String, Object> style;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF26241F);
    const paper = Color(0xFFF7F5EF);
    final (head, body, end) = _samples[scene]!;
    final double width = style['line'] == 'double'
        ? 3
        : switch (style['weight']) {
            'thick' => 2,
            'heavy' => 5,
            _ => 1,
          };
    final side = BorderSide(color: ink, width: width);
    final border = switch (style['border']) {
      'left' => Border(left: side),
      'top_bottom' => Border(top: side, bottom: side),
      'full' || 'frame' => Border.fromBorderSide(side),
      _ => null,
    };
    final shade = switch (style['shade']) {
      'light' => const Color(0xFFECECEC),
      'medium' => const Color(0xFFDCDCDC),
      'paper' => const Color(0xFFF1EFEA),
      _ => null,
    };
    final family = switch (style['font']) {
      'kai' => 'KaiTi',
      'mono' => 'Consolas',
      _ => null,
    };
    final scale = (style['size'] as int) / 100;
    TextStyle text({double size = 13, FontWeight? w, double spacing = 0}) =>
        TextStyle(
          color: ink,
          fontSize: size * scale,
          fontWeight: w,
          letterSpacing: spacing,
          fontFamily: family,
          height: 1.7,
        );
    final (open, close) = switch (style['ornament']) {
      'diamond' => ('◆ ', ' ◆'),
      'mark' => ('※ ', ' ※'),
      'lenticular' => ('〖 ', ' 〗'),
      _ => ('', ''),
    };
    final headStyle = style['head'];
    final centered = headStyle != 'plain' && headStyle != 'bold';
    final headText = Text(
      '$open$head$close',
      key: const ValueKey('inset-preview-head'),
      textAlign: centered ? TextAlign.center : TextAlign.start,
      style: text(
        size: headStyle == 'big' ? 20 : 13,
        w:
            headStyle == 'plain' ||
                headStyle == 'spaced' ||
                headStyle == 'underline'
            ? null
            : FontWeight.w700,
        spacing: switch (headStyle) {
          'spaced' || 'underline' => 4,
          'big' => 8,
          _ => 0,
        },
      ),
    );
    final indent = style['indent'] == true && style['align'] != 'center';
    final drop = style['drop'] == true;
    final bodyText = Text.rich(
      TextSpan(
        children: [
          if (indent) const TextSpan(text: '　　'),
          if (drop)
            TextSpan(
              text: body.characters.first,
              style: text(size: 22, w: FontWeight.w700),
            ),
          TextSpan(text: drop ? body.characters.skip(1).string : body),
        ],
      ),
      textAlign: style['align'] == 'center'
          ? TextAlign.center
          : TextAlign.start,
      style: text(),
    );
    Widget inner = Container(
      padding: border != null || shade != null
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: shade,
        border: style['border'] == 'frame'
            ? Border.fromBorderSide(const BorderSide(color: ink))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (headStyle == 'underline')
            Container(
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: ink)),
              ),
              child: headText,
            )
          else
            headText,
          bodyText,
          if (end.isNotEmpty)
            Text(end, textAlign: TextAlign.right, style: text()),
        ],
      ),
    );
    final block = Container(
      key: const ValueKey('inset-preview-block'),
      padding: style['border'] == 'frame'
          ? const EdgeInsets.all(2)
          : style['border'] == 'left'
          ? const EdgeInsets.only(left: 10)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        border: border,
        borderRadius: style['corner'] == 'round' && style['border'] == 'full'
            ? BorderRadius.circular(6)
            : null,
      ),
      child: inner,
    );
    Widget rod() => Container(
      height: 8,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: paper,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.desk.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '　　前文一段普通正文。',
            style: const TextStyle(color: ink, fontSize: 13, height: 1.7),
          ),
          const SizedBox(height: 8),
          if (style['rods'] == true) rod(),
          block,
          if (style['rods'] == true) rod(),
          const SizedBox(height: 8),
          Text(
            '　　后文一段普通正文。',
            style: const TextStyle(color: ink, fontSize: 13, height: 1.7),
          ),
        ],
      ),
    );
  }
}
