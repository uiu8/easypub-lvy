import 'book_information_service.dart';

const layoutNumbers = <String, String>{
  'font_size': '字号',
  'fullwidth_indent': '段首全角空格数（0为关闭）',
  'line_height': '行距',
  'paragraph_indent': '首行缩进',
  'paragraph_spacing': '段后间距',
  'margin_top': '上边距',
  'margin_bottom': '下边距',
  'margin_left': '左边距',
  'margin_right': '右边距',
};
const layoutFlags = <String, String>{
  'remove_blank_lines': '导出时去除空行',
  'include_toc': '收录成品目录',
  'visible_toc': '书内目录页',
  'chapter_navigation': '章节顶部导航',
};

/// 章节标题样式（V36，LAY-117）：值与 Rust `HEADING_STYLES` 一一对应。
const headingStyles = {
  'classic': 'EasyPub 经典',
  'amazon': '亚马逊官方',
  'publisher': '出版社',
  'two_line': '精排两行',
  'light_novel': '日系轻小说',
};

/// 场景分隔样式（V46，LAY-118）：值与 Rust `SCENE_BREAK_STYLES` 一一对应。
const sceneBreakStyles = {
  'off': '不识别',
  'keep': '居中保留原符号',
  'stars': '＊　＊　＊',
  'diamonds': '◇　◇　◇',
  'line': '细线',
};

/// 与 Rust `publication_documents::SCENE_SYMBOLS` 相同；“……”“——”不在其中。
const _sceneSymbols = '*＊﹡※◇◆○●◎☆★♢♦✱✲✳✿❀❖⁂#＃=＝~～§';

/// 整行（可夹空白）都是分隔符号且至少 3 个时视为场景分隔（与 Rust 规则一致）。
bool isSceneBreak(String line) {
  var count = 0;
  for (final rune in line.runes) {
    final c = String.fromCharCode(rune);
    if (c.trim().isEmpty) continue;
    if (!_sceneSymbols.contains(c)) return false;
    if (++count > 40) return false;
  }
  return count >= 3;
}

/// 场景分隔在成品里显示的文字；细线在小预览里用横线字符近似。
String sceneBreakText(String style, String original) => switch (style) {
  'stars' => '＊　＊　＊',
  'diamonds' => '◇　◇　◇',
  'line' => '―――',
  _ => original.trim(),
};

/// 章首段落样式（V49，LAY-119）：值与 Rust `FIRST_PARAGRAPH_STYLES` 一一对应。
const firstParagraphStyles = {
  'normal': '同正文',
  'no_indent': '首段不缩进',
  'large_initial': '首字放大',
};

/// 章节样式包（V74，LAY-130）：卷页边框，值与 Rust `VOLUME_FRAMES` 一一对应。
const volumeFrames = {'none': '无', 'single': '单线', 'double': '双线'};

/// 章节样式包的生成、导入与导出（V74，LAY-130）。请求见 Rust `style_packs::run`；
/// 样式包文件放在本机设置目录下，书里只记图片路径。
abstract interface class ChapterStyleStore {
  Future<Map<String, dynamic>> chapterStyleRequest(
    Map<String, Object?> request,
  );
}

/// 生僻字注音（V73，LAY-129）：值与 Rust `RARE_CHAR_RUBY_MODES` 一一对应。
const rareCharRubyModes = {
  'off': '不标',
  'chapter': '每章首次',
  'book': '全书首次',
  'every': '每次',
};

/// 生僻字范围（V73，LAY-129）：值与 Rust `RARE_CHAR_SCOPES` 一一对应。
const rareCharScopes = {'outside': '表外字', 'level3': '表外字和三级字'};

/// 场景样式（V81，LAY-135）：值与 Rust `insets` 模块的常量一一对应。
const chatBlockStyles = {
  'off': '不识别',
  'window': '群聊窗口',
  'script': '剧本对白',
  'channel': '通讯频道',
};
const letterBlockStyles = {'plain': '普通', 'ruled': '信笺格线'};
const insetFonts = {'kai': '楷体', 'body': '正文字体'};

/// 场景识别（V82，LAY-137）：值与 Rust `insets::INSET_DETECT` 一一对应。
const insetDetectModes = {'off': '不识别', 'on': '识别'};

const _insetBase = <String, Object>{
  'border': 'none',
  'line': 'solid',
  'weight': 'thin',
  'corner': 'square',
  'shade': 'none',
  'head': 'plain',
  'ornament': 'none',
  'align': 'start',
  'size': 100,
  'indent': true,
  'drop': false,
  'font': 'body',
  'rods': false,
  'names': 'block',
};

/// 场景样式的内置预设（V82，LAY-136）：与 Rust `inset_styles::presets` 一一对应（测试核对）。
/// 每种场景第一个是默认；聊天的三种对应“聊天记录”设置的三种样式。
final insetStylePresets =
    <String, (String scene, String name, Map<String, Object>)>{
      'window': (
        'chat',
        '群聊窗口',
        {..._insetBase, 'border': 'full', 'head': 'spaced', 'indent': false},
      ),
      'script': (
        'chat',
        '剧本对白',
        {..._insetBase, 'head': 'bold', 'indent': false, 'names': 'center'},
      ),
      'channel': (
        'chat',
        '通讯频道',
        {
          ..._insetBase,
          'border': 'top_bottom',
          'line': 'dashed',
          'size': 85,
          'indent': false,
          'font': 'mono',
          'names': 'inline',
        },
      ),
      'card': (
        'post',
        '动态卡片',
        {
          ..._insetBase,
          'border': 'full',
          'corner': 'round',
          'head': 'bold',
          'indent': false,
        },
      ),
      'floors': ('forum', '楼层', {..._insetBase, 'indent': false}),
      'notebook': (
        'diary',
        '日记本',
        {..._insetBase, 'border': 'left', 'line': 'double'},
      ),
      'frame': (
        'classic',
        '文武边栏',
        {
          ..._insetBase,
          'border': 'frame',
          'weight': 'thick',
          'head': 'underline',
          'ornament': 'diamond',
          'font': 'kai',
        },
      ),
      'bars': (
        'edict',
        '上下粗杆',
        {
          ..._insetBase,
          'border': 'top_bottom',
          'weight': 'heavy',
          'head': 'spaced',
          'font': 'kai',
        },
      ),
      'parchment': (
        'scroll',
        '羊皮纸卷',
        {
          ..._insetBase,
          'border': 'full',
          'line': 'double',
          'shade': 'paper',
          'head': 'spaced',
          'ornament': 'mark',
          'drop': true,
          'rods': true,
        },
      ),
      'poster': (
        'notice',
        '告示',
        {
          ..._insetBase,
          'border': 'full',
          'weight': 'thick',
          'head': 'big',
          'align': 'center',
          'indent': false,
        },
      ),
      'clipping': ('news', '剪报', {..._insetBase, 'border': 'full'}),
    };

/// 场景的默认样式：聊天按“聊天记录”设置（不识别时为群聊窗口），其余取该场景第一个预设。
Map<String, Object> defaultInsetStyle(String scene, String chatLook) {
  if (scene == 'chat') {
    return Map.of(
      insetStylePresets[chatLook == 'off' ? 'window' : chatLook]!.$3,
    );
  }
  return Map.of(insetStylePresets.values.firstWhere((p) => p.$1 == scene).$3);
}

/// 与某个预设参数完全相同时返回预设编号，否则为 custom。
String insetPresetOf(String scene, Map? style) {
  for (final e in insetStylePresets.entries) {
    if (e.value.$1 == scene && _sameMap(e.value.$3, style)) return e.key;
  }
  return 'custom';
}

bool _sameMap(Map a, Map? b) =>
    b != null &&
    a.length == b.length &&
    a.entries.every((e) => b[e.key] == e.value);

/// “我的场景样式”里某场景的条目：名称 → 参数。
Map<String, Map<String, Object>> savedInsetsOf(
  Object? library,
  String scene,
) => {
  for (final item in (library is List ? library : const []))
    if (item is Map && item['scene'] == scene && item['style'] is Map)
      item['name'] as String: Map<String, Object>.from(item['style'] as Map),
};

bool sameInsetStyle(Map a, Map? b) => _sameMap(a, b);

/// 手工标注的场景（V81）：与 Rust `insets::TYPES` 顺序相同。
const insetTypes = {
  'chat': '聊天记录',
  'post': '动态',
  'forum': '论坛楼层',
  'diary': '日记',
  'classic': '古籍',
  'edict': '诏书',
  'scroll': '羊皮纸',
  'notice': '告示',
  'news': '剪报',
};

/// 系统提示样式（V50，LAY-121）：值与 Rust `SYSTEM_BLOCK_STYLES` 一一对应。
const systemBlockStyles = {
  'off': '不识别',
  'box': '加框',
  'indent': '缩进',
  'styled': '分类样式',
};

/// 系统提示块样式预设（V77，LAY-132）：参数与 Rust `block_styles::presets` 一一对应，
/// desk_v77_test 逐项核对。
const blockStylePresets = <String, Map<String, Object>>{
  'bar': {
    'border': 'left', 'line': 'single', 'weight': 'thick', 'shade': 'light', //
    'align': 'start', 'size': 90, 'bold': false, 'title': 'none',
    'key_bold': false, 'brackets': 'keep', 'spacing': 'medium',
  },
  'center': {
    'border': 'none', 'line': 'single', 'weight': 'thin', 'shade': 'none', //
    'align': 'center', 'size': 90, 'bold': true, 'title': 'none',
    'key_bold': false, 'brackets': 'keep', 'spacing': 'medium',
  },
  'titled': {
    'border': 'full', 'line': 'single', 'weight': 'thin', 'shade': 'none', //
    'align': 'start', 'size': 90, 'bold': false, 'title': 'shaded',
    'key_bold': true, 'brackets': 'remove', 'spacing': 'medium',
  },
  'rules': {
    'border': 'top_bottom', 'line': 'double', 'weight': 'thick', //
    'shade': 'none', 'align': 'start', 'size': 90, 'bold': false,
    'title': 'none', 'key_bold': false, 'brackets': 'keep',
    'spacing': 'medium',
  },
};
const notePresetNames = {'bar': '提示条', 'center': '居中强调'};
const panelPresetNames = {'titled': '标题面板', 'rules': '上下双线'};

/// 新书默认（与 Rust `default_styles` 相同）：单行提示条，面板标题面板。
Map<String, Object> defaultSystemStyles() => {
  'note': blockStylePresets['bar']!,
  'panel': blockStylePresets['titled']!,
};

/// 某一类当前用的是哪个预设；参数被改过（V78 编辑器）时为 custom。
String presetOf(Map? style, Map<String, String> names) {
  for (final id in names.keys) {
    final p = blockStylePresets[id]!;
    if (style != null &&
        style.length == p.length &&
        p.entries.every((e) => style[e.key] == e.value)) {
      return id;
    }
  }
  return 'custom';
}

String describeSystemStyles(Object? value) {
  if (value is! Map) return '内置默认';
  final note = presetOf(value['note'] as Map?, notePresetNames);
  final panel = presetOf(value['panel'] as Map?, panelPresetNames);
  return '单行${notePresetNames[note] ?? '自定义'} · 面板${panelPresetNames[panel] ?? '自定义'}';
}

/// 诗词样式（V50，LAY-122）：值与 Rust `VERSE_BLOCK_STYLES` 一一对应。
const verseBlockStyles = {'off': '不识别', 'center': '居中', 'indent': '缩进'};

/// 统一章首图用于哪些标题（V54，LAY-124）：值与 Rust `CHAPTER_HEAD_SCOPES` 一一对应。
const chapterHeadScopes = {'chapter': '每章', 'volume': '每卷', 'both': '卷和章'};

/// 章首图宽度（V54，LAY-124）：值与 Rust `CHAPTER_HEAD_WIDTHS` 一一对应。
const chapterHeadWidths = {'third': '三分之一', 'half': '一半', 'full': '满宽'};

/// 弹出注释（V48 能力，V51 界面，LAY-120）：值与 Rust `NOTE_STYLES` 一一对应。
const noteStyles = {'off': '关闭', 'popup': '弹出注释'};

/// 整行由一个或多个【……】组成（之间可有空白）时视为系统提示（与 Rust 规则一致）。
bool isSystemLine(String line) {
  var rest = line.trim();
  if (rest.isEmpty || rest.runes.length > 200) return false;
  while (rest.isNotEmpty) {
    if (!rest.startsWith('【')) return false;
    final end = rest.indexOf('】');
    if (end < 0) return false;
    final inner = rest.substring(1, end);
    if (inner.trim().isEmpty || inner.contains('【')) return false;
    rest = rest.substring(end + 1).trimLeft();
  }
  return true;
}

final _han = RegExp(r'^[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+$');

/// 整行是五言或七言对句、前后两句等长时视为诗句（与 Rust 规则一致）。
bool isVerseLine(String line) {
  var t = line.trim();
  if (t.isNotEmpty && '。！？；!?;'.contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1);
  }
  final i = t.indexOf(RegExp('[，,]'));
  if (i < 0) return false;
  final a = t.substring(0, i), b = t.substring(i + 1);
  return a.length == b.length &&
      (a.length == 5 || a.length == 7) &&
      _han.hasMatch(a) &&
      _han.hasMatch(b);
}

/// 紧跟诗句、以“——”开头的短行视为署名（与 Rust 规则一致）。
bool isVerseAttribution(String line) {
  final t = line.trim();
  if (!t.startsWith('——')) return false;
  final by = t.substring(2);
  return by.trim().isNotEmpty && by.runes.length <= 40;
}

final layoutFields = Set<String>.unmodifiable({
  ...layoutNumbers.keys,
  ...layoutFlags.keys,
  'text_alignment',
  'writing_mode',
  'vertical_digits',
  'heading_style',
  'scene_break_style',
  'note_style',
  'first_paragraph_style',
  'rare_char_ruby',
  'rare_char_scope',
  'chat_block_style',
  'letter_block_style',
  'inset_font',
  'inset_styles',
  'inset_detect',
  'chapter_head_scope',
  'chapter_head_width',
  'system_block_style',
  'system_styles',
  'verse_block_style',
  'font_size_unit',
  'margin_top_unit',
  'margin_bottom_unit',
  'margin_left_unit',
  'margin_right_unit',
});

/// Layout uses the same guarded production-change DTO as book information.
abstract class LayoutSession {
  Map<String, Object?> get savedCss;
  Future<CssPreview> previewCss(String text, String base);
  Future<void> applyCss(CssPreview preview);
  Future<List<LayoutPreset>> readPresetFile(String path);
  Future<void> exportPresetFile(String name, String path);
  Future<void> importPreset(LayoutPreset preset);
  Future<LayoutPreset> builtinPreset();
  List<LayoutPreset> get presets;
  Future<void> renamePreset(String name, String replacement);
  Future<List<LayoutPreset>> readGlobalPresets();
  Future<void> publishPreset(String name);
  Future<void> copyGlobalPreset(String name);
  Future<void> deleteGlobalPreset(String name);
  Future<void> savePreset(String name, Map<String, Object?> values);
  void deletePreset(String name);
  Future<BookInformationPreview> previewPreset(String name);
  Map<String, Object?> get origins;
  Future<BookInformationPreview> restoreFields(
    Set<String> fields, {
    required bool global,
  });
  Map<String, Object?> get saved;
  Future<BookInformationPreview> preview(Map<String, Object?> values);
  Future<void> apply(BookInformationPreview preview);
  void dispose();
}

class CssPreview {
  CssPreview(this.change, List<String> issues, List<String> files, this.bytes)
    : issues = List.unmodifiable(issues),
      files = List.unmodifiable(files);
  final BookInformationPreview change;
  final List<String> issues, files;
  final int bytes;
}

class LayoutPreset {
  LayoutPreset(this.name, Map<String, Object?> values)
    : values = Map.unmodifiable(values);
  final String name;
  final Map<String, Object?> values;
}

/// Optional because lightweight page previews and tests need no desktop shell.
/// 排版预览机型偏好（LAY-092）：界面偏好，存于设置目录，不写入书稿。
abstract interface class LayoutPreviewDeviceStore {
  Future<String?> readPreviewDevice();
  Future<void> savePreviewDevice(String value);
}

abstract interface class LayoutPublicationPreviewSession {
  Future<LayoutPublicationPreview> renderPreview({String? entryId});
  Future<void> openPreview(LayoutPublicationPreview preview);
}

/// 真机预览（LAY-108/110）：按还没写回的排版值生成本书内容，不保存。
abstract interface class LayoutDraftPreviewSession {
  Future<LayoutDraftPreview> renderDraftPreview(
    Map<String, Object?> values, {
    String? entryId,
  });
}

class LayoutDraftPreview {
  const LayoutDraftPreview({
    required this.directory,
    required this.content,
    required this.title,
    this.anchor,
  });

  /// 生成内容所在目录；[content] 为其中正文 XHTML 的相对路径（用 / 分隔）。
  final String directory, content, title;
  final String? anchor;
}

class LayoutPublicationPreview {
  const LayoutPublicationPreview({
    required this.publicationId,
    required this.path,
    required this.documents,
  });
  final String publicationId, path;
  final List<({String path, String title})> documents;
}
