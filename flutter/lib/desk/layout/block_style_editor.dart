import 'package:flutter/material.dart';

import '../../application/layout_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 系统提示块样式编辑器（V78，LAY-133）：逐项调参数，右侧按成品 CSS 的规则近似预览。
/// 结果：应用到本书（name 为 null），或另存为“我的样式”（带名称，同时应用）。
class BlockStyleEdit {
  const BlockStyleEdit(this.style, {this.name});
  final Map<String, Object> style;
  final String? name;
}

/// 每个参数的取值与名称；顺序即界面顺序。
const _choices = <String, (String, Map<Object, String>)>{
  'border': (
    '边框',
    {'none': '无', 'left': '左侧', 'full': '四周', 'top_bottom': '上下'},
  ),
  'line': ('线型', {'single': '单线', 'double': '双线'}),
  'weight': ('粗细', {'thin': '细', 'thick': '粗'}),
  'shade': ('底色', {'none': '无', 'light': '浅', 'medium': '中'}),
  'align': ('对齐', {'start': '靠左', 'center': '居中'}),
  'size': ('字号', {90: '90%', 100: '100%'}),
  'bold': ('整块加粗', {false: '关', true: '开'}),
  'title': (
    '首行标题',
    {'none': '不用', 'shaded': '带底', 'underline': '下划线', 'bold': '仅加粗'},
  ),
  'key_bold': ('键名加粗', {false: '关', true: '开'}),
  'brackets': ('成品括号', {'keep': '保留【】', 'remove': '去掉'}),
  'spacing': ('上下间距', {'tight': '紧', 'medium': '中', 'loose': '松'}),
};

Future<BlockStyleEdit?> showBlockStyleEditor(
  BuildContext context, {
  required String kind,
  required Map<String, Object> initial,
  required Set<String> takenNames,
}) => showDialog<BlockStyleEdit>(
  context: context,
  builder: (_) => _Editor(kind: kind, initial: initial, takenNames: takenNames),
);

class _Editor extends StatefulWidget {
  const _Editor({
    required this.kind,
    required this.initial,
    required this.takenNames,
  });
  final String kind;
  final Map<String, Object> initial;
  final Set<String> takenNames;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final style = Map<String, Object>.from(widget.initial);
  final name = TextEditingController();
  bool get panel => widget.kind == 'panel';

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
    final rows = [
      for (final e in _choices.entries)
        if (panel || e.key != 'title')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(e.value.$1, style: ui(12, c: d.ink2)),
                ),
                Flexible(
                  child: KeyedSubtree(
                    key: ValueKey('block-editor-${e.key}'),
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
      title: panel ? '编辑多行面板样式' : '编辑单行提示样式',
      closeTooltip: '关闭',
      width: 820,
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        DeskButton(
          name.text.trim().isEmpty ? '应用到本书' : '另存并应用',
          key: const ValueKey('block-editor-apply'),
          primary: true,
          onPressed: nameError != null
              ? null
              : () => Navigator.of(context).pop(
                  BlockStyleEdit(
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
            flex: 11,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...rows,
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('block-editor-name'),
                  controller: name,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '另存为我的样式（名称）',
                    errorText: nameError,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                Text(
                  '只能调这些选项，样式由程序生成，保证 Kindle 夜间模式与 KFX 都能正常显示。'
                  '更自由的写法：在“附加 CSS”里用公开类名 .blk-note、.blk-panel、.blk-panel-title、.blk-key、.system-line 自己写。',
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
                BlockStylePreview(kind: widget.kind, style: style),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 按 Rust `block_styles` 生成 CSS 的同一套规则近似画出成品效果。
class BlockStylePreview extends StatelessWidget {
  const BlockStylePreview({super.key, required this.kind, required this.style});
  final String kind;
  final Map<String, Object> style;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF26241F);
    const paper = Color(0xFFF7F5EF);
    final panel = kind == 'panel';
    final double width = style['line'] == 'double' || style['weight'] == 'thick'
        ? 3
        : 1;
    final side = BorderSide(color: ink, width: width);
    final border = switch (style['border']) {
      'left' => Border(left: side),
      'full' => Border.fromBorderSide(side),
      'top_bottom' => Border(top: side, bottom: side),
      _ => null,
    };
    final shade = switch (style['shade']) {
      'light' => const Color(0xFFECECEC),
      'medium' => const Color(0xFFDCDCDC),
      _ => null,
    };
    final boxed = border != null || shade != null;
    final size = 13.0 * ((style['size'] as int) / 100);
    final center = style['align'] == 'center';
    final bold = style['bold'] == true;
    final remove = style['brackets'] == 'remove';
    String text(String raw) {
      if (!remove || !raw.startsWith('【')) return raw;
      return raw.substring(1, raw.length - 1).replaceAll(RegExp(r'】\s*【'), '　');
    }

    TextStyle base({bool strong = false}) => TextStyle(
      fontSize: size,
      height: 1.6,
      color: ink,
      fontWeight: (bold || strong) ? FontWeight.w700 : FontWeight.w400,
    );
    Widget line(String raw, {bool key = true}) {
      final t = text(raw);
      final colon = t.indexOf('：');
      final spans = key && style['key_bold'] == true && colon > 0 && colon < 12
          ? [
              TextSpan(text: t.substring(0, colon), style: base(strong: true)),
              TextSpan(text: t.substring(colon), style: base()),
            ]
          : [TextSpan(text: t, style: base())];
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: boxed ? 8 : 0),
        child: Text.rich(
          TextSpan(children: spans),
          textAlign: center ? TextAlign.center : TextAlign.start,
        ),
      );
    }

    final lines = panel
        ? ['【苍白的正义】', '【攻击力：20-25】', '【终极圣炎：附带30点伤害】']
        : ['【叮！击杀成功，经验+120】'];
    final title = panel ? style['title'] as String : 'none';
    final margin = switch (style['spacing']) {
      'tight' => 5.0,
      'loose' => 15.0,
      _ => 10.0,
    };
    Widget titleRow() {
      final t = text(lines.first);
      final strong = Text(
        t,
        style: base(strong: true),
        textAlign: center ? TextAlign.center : TextAlign.start,
      );
      return switch (title) {
        'shaded' => Container(
          color: const Color(0xFFE4E4E4),
          padding: EdgeInsets.symmetric(horizontal: boxed ? 8 : 0, vertical: 2),
          margin: const EdgeInsets.only(bottom: 3),

          child: strong,
        ),
        'underline' => Container(
          margin: const EdgeInsets.only(bottom: 3),
          padding: EdgeInsets.symmetric(horizontal: boxed ? 8 : 0),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: ink)),
          ),
          child: strong,
        ),
        _ => Padding(
          padding: EdgeInsets.symmetric(horizontal: boxed ? 8 : 0),
          child: strong,
        ),
      };
    }

    final hasTitle = panel && title != 'none';
    final block = Container(
      key: const ValueKey('block-style-preview-box'),
      margin: EdgeInsets.symmetric(vertical: margin),
      padding: EdgeInsets.only(
        top: boxed && !(hasTitle && title == 'shaded') ? 4 : 0,
        bottom: boxed ? 4 : 0,
      ),
      decoration: BoxDecoration(color: shade, border: border),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasTitle) titleRow() else line(lines.first, key: panel),
          for (final l in lines.skip(1)) line(l),
        ],
      ),
    );
    const body = TextStyle(fontSize: 13, height: 1.7, color: ink);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: paper,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('　　他再探手，取出那把战锤。', style: body),
          block,
          const Text('　　“这东西……”他喃喃道。', style: body),
        ],
      ),
    );
  }
}

/// “我的样式”里某一类的条目（名称 → 参数）。
Map<String, Map<String, Object>> savedStylesOf(
  Object? library,
  String kind,
) => {
  for (final item in (library as List? ?? const []).whereType<Map>())
    if (item['kind'] == kind && item['name'] is String && item['style'] is Map)
      item['name'] as String: Map<String, Object>.from(item['style'] as Map),
};

/// 两组参数是否相同。
bool sameStyle(Map? a, Map? b) =>
    a != null &&
    b != null &&
    a.length == b.length &&
    a.entries.every((e) => b[e.key] == e.value);

/// 参数是否与某个内置预设相同，供编辑器默认值等使用。
Map<String, Object> styleOrPreset(Map? value, String fallback) => value == null
    ? Map<String, Object>.from(blockStylePresets[fallback]!)
    : Map<String, Object>.from(value);

/// 自定义识别规则的显示：括号对写法显示成“≮……≯”，其余显示正则原文。
String systemPatternLabel(String pattern) {
  final m = RegExp(r'^(\\?.)\.\+(\\?.)$').firstMatch(pattern);
  if (m == null) return '正则：$pattern';
  String plain(String s) => s.startsWith(r'\') ? s.substring(1) : s;
  return '${plain(m.group(1)!)}……${plain(m.group(2)!)}';
}

/// 与 Rust 相同的整行匹配；正则无效时为 null。
RegExp? systemPatternRegExp(String pattern) {
  try {
    return RegExp('^(?:$pattern)\$');
  } on FormatException {
    return null;
  }
}

/// 添加一条系统提示自定义识别规则（V78，LAY-134）：括号对或正则，带“试一试”。返回正则。
Future<String?> showSystemPatternDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const _PatternDialog(),
    );

class _PatternDialog extends StatefulWidget {
  const _PatternDialog();
  @override
  State<_PatternDialog> createState() => _PatternDialogState();
}

class _PatternDialogState extends State<_PatternDialog> {
  String mode = 'brackets';
  final open = TextEditingController(text: '≮');
  final close = TextEditingController(text: '≯');
  final regex = TextEditingController();
  final sample = TextEditingController(text: '≮任务：清剿妖兽≯');

  @override
  void dispose() {
    for (final c in [open, close, regex, sample]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get pattern {
    if (mode == 'regex') {
      final p = regex.text.trim();
      return p.isEmpty || p.length > 200 ? null : p;
    }
    final a = open.text.trim(), b = close.text.trim();
    if (a.characters.length != 1 || b.characters.length != 1) return null;
    return '${RegExp.escape(a)}.+${RegExp.escape(b)}';
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final p = pattern;
    final re = p == null ? null : systemPatternRegExp(p);
    final matched = re?.hasMatch(sample.text.trim()) ?? false;
    Widget field(String label, TextEditingController c, Key key) => TextField(
      key: key,
      controller: c,
      decoration: InputDecoration(isDense: true, labelText: label),
      onChanged: (_) => setState(() {}),
    );
    return DeskDialog(
      title: '添加系统提示识别规则',
      closeTooltip: '关闭',
      width: 520,
      actions: [
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '添加',
          key: const ValueKey('system-pattern-add'),
          primary: true,
          onPressed: re == null ? null : () => Navigator.pop(context, p),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyedSubtree(
            key: const ValueKey('system-pattern-mode'),
            child: DeskSegmented<String>(
              value: mode,
              options: const {'brackets': '括号对', 'regex': '正则表达式'},
              onChanged: (v) => setState(() => mode = v),
            ),
          ),
          const SizedBox(height: 10),
          if (mode == 'brackets')
            Row(
              children: [
                Expanded(
                  child: field(
                    '开头符号（一个字符）',
                    open,
                    const ValueKey('system-pattern-open'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: field(
                    '结尾符号（一个字符）',
                    close,
                    const ValueKey('system-pattern-close'),
                  ),
                ),
              ],
            )
          else
            field(
              '正则表达式（整行匹配，最多 200 字）',
              regex,
              const ValueKey('system-pattern-regex'),
            ),
          const SizedBox(height: 10),
          field('试一试：输入一行', sample, const ValueKey('system-pattern-sample')),
          const SizedBox(height: 6),
          Text(
            re == null
                ? (mode == 'regex' ? '正则表达式无效。' : '开头、结尾各填一个字符。')
                : matched
                ? '这一行会被识别为系统提示。'
                : '这一行不会被识别。',
            key: const ValueKey('system-pattern-result'),
            style: ui(12.5, c: re != null && matched ? d.add : d.ink2),
          ),
          const SizedBox(height: 6),
          Text(
            '整行（去掉首尾空白）符合规则才算；已是标题、手工标注或其他识别结果的行不受影响。'
            '规则只用于本书，最多 20 条。',
            style: ui(11.5, c: d.ink3),
          ),
        ],
      ),
    );
  }
}
