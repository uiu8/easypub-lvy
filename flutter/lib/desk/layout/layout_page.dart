// 本书排版（LAY-001–030）：左侧正文 / 页面 / 成品结构三组设置（停顿自动应用，未补全的数字只暂存），
// 右侧阅读预览（机型与分页，LAY-092/093）与“实际生成预览”。保存、草稿、预设、来源、CSS、批量的逻辑逐行沿用 V5 前的 LayoutPage。
// 设计：design_review_v37/d3_layout.dart（D3-D）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as dui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_service.dart';
import '../../application/kindle_preview_server.dart';
import '../../application/layout_service.dart';
import '../../application/library_service.dart';
import '../../application/resource_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../../infrastructure/kindle_preview_launcher.dart';
import '../controls/controls.dart' show DeskButton, DeskChoice;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'book_batch_dialog.dart';
import 'css_dialog.dart';
import 'device_preview.dart';
import 'layout_origins_dialog.dart';
import 'layout_presets_dialog.dart';
import 'block_style_editor.dart';
import 'inset_rule_dialog.dart';
import 'inset_style_editor.dart';
import 'recognition_counts.dart';
import '../../application/rule_catalog_service.dart';
import '../../application/settings_service.dart';

part 'layout_page_text.dart';
part 'layout_page_heading.dart';
part 'layout_page_paragraph.dart';
part 'layout_page_preview.dart';

class LayoutNavigationGuard {
  Future<bool> Function()? check;
  Future<bool> canLeave() async => await check?.call() ?? true;
}

class LayoutPage extends StatefulWidget {
  const LayoutPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.navigation,
    required this.pickPresetFile,
    required this.pickPresetDestination,
    required this.importCss,
    this.pickImage,
    this.pickStylePack,
    this.pickStylePackDestination,
    this.openCssOnStart = false,
    this.initialTab = 0,
    this.kindlePreview = const SystemKindlePreviewHost(),
  });
  final LibraryService library;
  final String bookId;
  final LayoutNavigationGuard navigation;
  final Future<String?> Function() pickPresetFile, pickPresetDestination;
  final Future<({String text, String base})?> Function() importCss;

  /// 统一章首图的选图对话框（V54，LAY-124）；为空时不能选图。
  final Future<String?> Function()? pickImage;

  /// 章节样式包文件（V74，LAY-130）：导入时选 .zip，导出时选保存位置。
  final Future<String?> Function()? pickStylePack;
  final Future<String?> Function(String name)? pickStylePackDestination;
  final bool openCssOnStart;

  /// 打开时显示的左栏分页（V63：规则中心“去设置”可直接打开“段落与识别”）。
  final int initialTab;

  /// 真机预览组件的查找与启动（V30）；测试中替换。
  final KindlePreviewHost kindlePreview;
  @override
  State<LayoutPage> createState() => _LayoutPageState();
}

class _LayoutPageState extends State<LayoutPage> {
  /// 拆出的 part 文件经由扩展访问本类，用它代替受保护的 setState（R5-13）。
  void update(VoidCallback fn) => setState(fn);

  LayoutSession? session;
  final numbers = <String, TextEditingController>{};
  final flags = <String, bool>{};
  final units = <String, String>{};
  Map<String, Object?> savedValues = {};
  String alignment = 'justify', baseline = '', message = '';
  // 书写方向与纵中横位数（V28，LAY-104）。
  String writingMode = 'horizontal';
  int verticalDigits = 2;
  // 章节标题样式（V36，LAY-117）。
  String headingStyle = 'classic';
  // 场景分隔样式（V46，LAY-118）。
  String sceneBreakStyle = 'keep';
  // 章首段落样式（V49，LAY-119）。
  String firstParagraphStyle = 'normal';
  // 生僻字注音（V73，LAY-129）。
  String rareCharRuby = 'off';
  String rareCharScope = 'outside';
  // 场景样式（V81，LAY-135）。
  String chatBlockStyle = 'off';
  String letterBlockStyle = 'plain';
  String insetFont = 'kai';
  // 场景识别（V82，LAY-137）与本书的自定义规则（存在 rule_options.inset_rules）。
  String insetDetect = 'off';
  List<Map<String, dynamic>> insetRules = const [];
  // 本书改过的场景样式参数（V82，LAY-136）：场景编号 → 参数；没改的用内置预设。
  Map<String, dynamic>? insetStyles;
  // 统一章首图（V54，LAY-124）：图片路径单独保存，不进草稿；范围与宽度是排版字段。
  String? chapterHeadImage;
  // 章节样式包（V74，LAY-130）：与章首图一样单独应用，不进草稿。
  Map<String, dynamic>? chapterStyle;
  // 系统提示自定义识别规则（V78，LAY-134）：在 rule_options 里，单独应用。
  List<String> systemPatterns = const [];

  /// 小预览用的章首图像素（V54）；路径变化时重新读取。
  dui.Image? chapterHeadPixels;
  String? _chapterHeadLoaded;
  String chapterHeadScope = 'chapter';
  String chapterHeadWidth = 'half';
  // 系统提示与诗词（V50，LAY-121/122）。
  String systemBlockStyle = 'box';
  // 系统提示分类样式参数（V77，LAY-132）。
  Map<String, dynamic>? systemStyles;
  String verseBlockStyle = 'center';
  // 弹出注释（V51，LAY-120）。
  String noteStyle = 'off';

  /// 左栏分页（V60）：0 文字、1 标题、2 段落与识别、3 页面与结构。
  late int settingsTab = widget.initialTab;

  /// 段落与识别分页中已展开的项（字段名）。
  final expandedRows = <String>{};
  String _identityCache = '';
  final _previewRevision = ValueNotifier<int>(0);
  String chapterTitle = '', body = '', bodyError = '';

  /// 本章正文超出预览读取范围（只预览开头一部分）。
  bool bodyPartial = false;

  /// 本章正文插图（R5-01）：键是插在正文第几行之后（0 起，按 [body] 的行），-1 为紧接标题。
  Map<int, List<PreviewImage>> bodyImages = const {};

  /// 本章插图版式为“章首图”的那张，代替统一章首图。
  PreviewImage? chapterHeadOverride;
  PreviewDeviceChoice device = const PreviewDeviceChoice();
  final customSize = <String, TextEditingController>{
    'width': TextEditingController(text: '1264'),
    'height': TextEditingController(text: '1680'),
    'ppi': TextEditingController(text: '300'),
  };
  String customError = '';
  int previewPage = 0;
  String _pagesKey = '';
  List<List<PreviewPiece>> _pages = const [[]];
  ChapterSession? chapterSession;
  ChapterPage? outline;
  String? selectedChapter;

  /// 真机预览窗口的本机连接；排版页关闭时停止（LAY-108）。
  KindlePreviewServer? _kindle;
  bool generatingPreview = false;
  bool busy = false, loading = true, _restoring = false;
  Timer? _saveTimer;
  Future<void>? _saving;
  WorkspaceAutosaveService? get autosave =>
      widget.library is WorkspaceAutosaveService
      ? widget.library as WorkspaceAutosaveService
      : null;
  String get draftKey => 'layout:${widget.bookId}';
  Map<String, dynamic> get rawValues => {
    for (final key in numbers.keys) key: numbers[key]!.text,
    ...flags,
    ...units,
    'text_alignment': alignment,
    'writing_mode': writingMode,
    'vertical_digits': verticalDigits,
    'heading_style': headingStyle,
    'scene_break_style': sceneBreakStyle,
    'first_paragraph_style': firstParagraphStyle,
    'rare_char_ruby': rareCharRuby,
    'rare_char_scope': rareCharScope,
    'chat_block_style': chatBlockStyle,
    'letter_block_style': letterBlockStyle,
    'inset_font': insetFont,
    'inset_styles': insetStyles,
    'inset_detect': insetDetect,
    'chapter_head_scope': chapterHeadScope,
    'chapter_head_width': chapterHeadWidth,
    'system_block_style': systemBlockStyle,
    'system_styles': systemStyles,
    'verse_block_style': verseBlockStyle,
    'note_style': noteStyle,
  };
  void changed() {
    if (_restoring) return;
    autosave?.writeDraft(draftKey, rawValues);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), save);
  }

  void restoreDraft() {
    final draft = autosave?.readDraft(draftKey);
    if (draft == null) return;
    _restoring = true;
    for (final key in numbers.keys) {
      if (draft.containsKey(key)) numbers[key]!.text = draft[key] as String;
    }
    for (final key in flags.keys) {
      if (draft.containsKey(key)) flags[key] = draft[key] as bool;
    }
    for (final key in units.keys) {
      if (draft.containsKey(key)) units[key] = draft[key] as String;
    }
    alignment = draft['text_alignment'] as String? ?? alignment;
    writingMode = draft['writing_mode'] as String? ?? writingMode;
    verticalDigits = (draft['vertical_digits'] as num? ?? verticalDigits)
        .toInt();
    headingStyle = draft['heading_style'] as String? ?? headingStyle;
    sceneBreakStyle = draft['scene_break_style'] as String? ?? sceneBreakStyle;
    firstParagraphStyle =
        draft['first_paragraph_style'] as String? ?? firstParagraphStyle;
    rareCharRuby = draft['rare_char_ruby'] as String? ?? rareCharRuby;
    rareCharScope = draft['rare_char_scope'] as String? ?? rareCharScope;
    chatBlockStyle = draft['chat_block_style'] as String? ?? chatBlockStyle;
    letterBlockStyle =
        draft['letter_block_style'] as String? ?? letterBlockStyle;
    insetFont = draft['inset_font'] as String? ?? insetFont;
    insetDetect = draft['inset_detect'] as String? ?? insetDetect;
    if (draft.containsKey('inset_styles')) {
      insetStyles = (draft['inset_styles'] as Map?)?.cast<String, dynamic>();
    }
    chapterHeadScope =
        draft['chapter_head_scope'] as String? ?? chapterHeadScope;
    chapterHeadWidth =
        draft['chapter_head_width'] as String? ?? chapterHeadWidth;
    systemBlockStyle =
        draft['system_block_style'] as String? ?? systemBlockStyle;
    if (draft.containsKey('system_styles')) {
      systemStyles = (draft['system_styles'] as Map?)?.cast<String, dynamic>();
    }
    verseBlockStyle = draft['verse_block_style'] as String? ?? verseBlockStyle;
    noteStyle = draft['note_style'] as String? ?? noteStyle;
    _identityCache = _computeIdentity();
    _restoring = false;
    message = '已恢复上次编辑的内容';
  }

  Map<String, Object?> get values => {
    for (final key in numbers.keys)
      key: key == 'fullwidth_indent'
          ? int.tryParse(numbers[key]!.text)
          : double.tryParse(numbers[key]!.text),
    ...flags,
    ...units,
    'text_alignment': alignment,
    'writing_mode': writingMode,
    'vertical_digits': verticalDigits,
    'heading_style': headingStyle,
    'scene_break_style': sceneBreakStyle,
    'first_paragraph_style': firstParagraphStyle,
    'rare_char_ruby': rareCharRuby,
    'rare_char_scope': rareCharScope,
    'chat_block_style': chatBlockStyle,
    'letter_block_style': letterBlockStyle,
    'inset_font': insetFont,
    'inset_styles': insetStyles,
    'inset_detect': insetDetect,
    'chapter_head_scope': chapterHeadScope,
    'chapter_head_width': chapterHeadWidth,
    'system_block_style': systemBlockStyle,
    'system_styles': systemStyles,
    'verse_block_style': verseBlockStyle,
    'note_style': noteStyle,
  };
  String _computeIdentity() => jsonEncode({
    for (final key in numbers.keys) key: numbers[key]!.text,
    ...flags,
    ...units,
    'text_alignment': alignment,
    'writing_mode': writingMode,
    'vertical_digits': verticalDigits,
    'heading_style': headingStyle,
    'scene_break_style': sceneBreakStyle,
    'first_paragraph_style': firstParagraphStyle,
    'rare_char_ruby': rareCharRuby,
    'rare_char_scope': rareCharScope,
    'chat_block_style': chatBlockStyle,
    'letter_block_style': letterBlockStyle,
    'inset_font': insetFont,
    'inset_styles': insetStyles,
    'inset_detect': insetDetect,
    'chapter_head_scope': chapterHeadScope,
    'chapter_head_width': chapterHeadWidth,
    'system_block_style': systemBlockStyle,
    'system_styles': systemStyles,
    'verse_block_style': verseBlockStyle,
    'note_style': noteStyle,
  });
  String get identity => _identityCache;
  @override
  void initState() {
    super.initState();
    widget.navigation.check = canLeave;
    try {
      session = widget.library.openLayout(widget.bookId);
      restore();
      restoreDraft();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identity != baseline) changed();
      });
      loadBody();
      loadDevice();
      if (widget.openCssOnStart) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showCss();
        });
      }
    } catch (_) {
      loading = false;
      message = '无法打开排版，请返回书库检查书稿。';
    }
  }

  void restore() {
    _restoring = true;
    final saved = session!.saved;
    for (final key in layoutNumbers.keys) {
      numbers
              .putIfAbsent(
                key,
                () => TextEditingController()..addListener(refresh),
              )
              .text =
          '${saved[key] ?? (key == 'fullwidth_indent' ? 0 : '')}';
    }
    for (final key in layoutFlags.keys) {
      flags[key] = saved[key] == true;
    }
    for (final side in ['top', 'bottom', 'left', 'right']) {
      units['margin_${side}_unit'] = saved['margin_${side}_unit'] as String;
    }
    units['font_size_unit'] = saved['font_size_unit'] as String? ?? 'px';
    alignment = saved['text_alignment'] as String;
    writingMode = saved['writing_mode'] as String? ?? 'horizontal';
    verticalDigits = (saved['vertical_digits'] as num? ?? 2).toInt();
    headingStyle = saved['heading_style'] as String? ?? 'classic';
    sceneBreakStyle = saved['scene_break_style'] as String? ?? 'keep';
    firstParagraphStyle = saved['first_paragraph_style'] as String? ?? 'normal';
    rareCharRuby = saved['rare_char_ruby'] as String? ?? 'off';
    rareCharScope = saved['rare_char_scope'] as String? ?? 'outside';
    chatBlockStyle = saved['chat_block_style'] as String? ?? 'off';
    letterBlockStyle = saved['letter_block_style'] as String? ?? 'plain';
    insetFont = saved['inset_font'] as String? ?? 'kai';
    insetDetect = saved['inset_detect'] as String? ?? 'off';
    insetRules = [
      for (final r
          in ((saved['rule_options'] as Map?)?['inset_rules'] as List?) ??
              const [])
        Map<String, dynamic>.from(r as Map),
    ];
    insetStyles = (saved['inset_styles'] as Map?)?.cast<String, dynamic>();
    chapterHeadImage = saved['chapter_head_image'] as String?;
    chapterStyle = (saved['chapter_style'] as Map?)?.cast<String, dynamic>();
    systemPatterns = [
      for (final p
          in ((saved['rule_options'] as Map?)?['system_patterns'] as List?) ??
              const [])
        '$p',
    ];
    unawaited(loadChapterHeadPixels());
    chapterHeadScope = saved['chapter_head_scope'] as String? ?? 'chapter';
    chapterHeadWidth = saved['chapter_head_width'] as String? ?? 'half';
    systemBlockStyle = saved['system_block_style'] as String? ?? 'box';
    systemStyles = (saved['system_styles'] as Map?)?.cast<String, dynamic>();
    verseBlockStyle = saved['verse_block_style'] as String? ?? 'center';
    noteStyle = saved['note_style'] as String? ?? 'off';
    _identityCache = _computeIdentity();
    baseline = _identityCache;
    savedValues = Map.of(values);
    _restoring = false;
  }

  Future<void> showBatch() async {
    await save();
    if (!mounted) return;
    if (identity != baseline) {
      setState(() => message = '请先补全排版数值，再应用到多本书。');
      return;
    }
    final applied = await showDialog<bool>(
      context: context,
      builder: (_) =>
          // 从排版页进来默认勾选全部排版字段（R5-02）。
          BookBatchDialog(
            library: widget.library,
            bookId: widget.bookId,
            initialFields: layoutFields,
          ),
    );
    if (mounted && applied == true) {
      setState(() {
        restore();
        message = '所选排版字段已应用，修改随工作区保存。';
      });
    }
  }

  void refresh() {
    if (_restoring) return;
    final next = _computeIdentity();
    if (next == _identityCache) return;
    _identityCache = next;
    if (mounted) _previewRevision.value++;
    changed();
  }

  void edit(VoidCallback action) {
    setState(() {
      action();
      _identityCache = _computeIdentity();
    });
    changed();
  }

  Future<void> applyClassicDefaults() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      _saveTimer?.cancel();
      await _saving;
      _saveTimer?.cancel();
      if (!mounted) return;
      final preset = await session!.builtinPreset();
      final fields = Map<String, Object?>.fromEntries(
        preset.values.entries.where((e) => layoutFields.contains(e.key)),
      );
      await session!.apply(await session!.preview(fields));
      if (mounted) {
        setState(() {
          restore();
          autosave?.writeDraft(draftKey, null);
          message = '已应用你的 EasyPub 默认排版：110%、1.2 倍行距、两个全角空格。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = '应用默认排版失败，请重新打开本书后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> showOrigins() async {
    await save();
    if (!mounted) return;
    if (identity != baseline) {
      setState(() => message = '请先补全排版数值，再按字段恢复默认。');
      return;
    }
    try {
      final origins = session!.origins;
      final applied = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => LayoutOriginsDialog(
          session: session!,
          values: values,
          origins: origins,
          label: fieldLabel,
          valueText: displayValue,
        ),
      );
      if (mounted && applied == true) {
        setState(() {
          restore();
          message = '选定排版字段已恢复默认。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = '设置来源已过期，请恢复已保存值后重试。');
    }
  }

  Future<void> showCss() async {
    await save();
    if (!mounted) return;
    if (identity != baseline) {
      setState(() => message = '请先补全排版数值，再编辑附加 CSS。');
      return;
    }
    try {
      session!.savedCss;
      final applied = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CssDialog(
          session: session!,
          importFile: widget.importCss,
          autosave: autosave,
          draftKey: 'css:${widget.bookId}',
        ),
      );
      if (mounted && applied == true) {
        setState(() {
          restore();
          message = '附加 CSS 已保存；实际效果需验收导出成品。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = '书稿已改变，请恢复已保存值后重试。');
    }
  }

  Future<void> showPresets() async {
    await save();
    if (!mounted) return;
    try {
      session!.presets;
      final applied = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => LayoutPresetsDialog(
          session: session!,
          values: values,
          allowApply: identity == baseline,
          pickFile: widget.pickPresetFile,
          pickDestination: widget.pickPresetDestination,
          label: fieldLabel,
          valueText: displayValue,
        ),
      );
      if (mounted && applied == true) {
        setState(() {
          restore();
          message = '预设已应用到本书。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = '预设库已过期，请恢复已保存值后重试。');
    }
  }

  Future<bool> canLeave() async {
    _saveTimer?.cancel();
    if (session != null && identity != baseline) {
      autosave?.writeDraft(draftKey, rawValues);
      await save();
      if (identity != baseline) await save();
    }
    return await autosave?.flushWorkspace() ?? !busy;
  }

  String fieldLabel(String key) {
    if (key.endsWith('_unit')) {
      return '${layoutNumbers[key.substring(0, key.length - 5)] ?? '边距'}单位';
    }
    return layoutNumbers[key] ??
        layoutFlags[key] ??
        {
          'text_alignment': '对齐',
          'writing_mode': '书写方向',
          'vertical_digits': '竖排中数字横排',
          'heading_style': '章节标题样式',
          'scene_break_style': '场景分隔',
          'first_paragraph_style': '章首段落',
          'rare_char_ruby': '生僻字注音',
          'rare_char_scope': '生僻字范围',
          'chat_block_style': '聊天记录',
          'letter_block_style': '书信样式',
          'inset_font': '场景字体',
          'inset_styles': '场景样式参数',
          'inset_detect': '场景识别',
          'chapter_head_scope': '章首图用于',
          'chapter_head_width': '章首图宽度',
          'system_block_style': '系统提示',
          'system_styles': '系统提示样式',
          'verse_block_style': '诗词',
          'note_style': '弹出注释',
          'layout_origins': '设置来源',
        }[key] ??
        key;
  }

  String displayValue(String key, Object? value) {
    if (key == 'layout_origins') return value == null ? '默认设置' : '已记录字段来源';
    if (value is bool) return value ? '开启' : '关闭';
    if (key == 'writing_mode') return value == 'vertical' ? '竖排' : '横排';
    if (key == 'vertical_digits') return value == 0 ? '不横排' : '$value 位';
    if (key == 'heading_style') return headingStyles[value] ?? '$value';
    if (key == 'scene_break_style') return sceneBreakStyles[value] ?? '$value';
    if (key == 'first_paragraph_style') {
      return firstParagraphStyles[value] ?? '$value';
    }
    if (key == 'rare_char_ruby') return rareCharRubyModes[value] ?? '$value';
    if (key == 'rare_char_scope') return rareCharScopes[value] ?? '$value';
    if (key == 'chat_block_style') return chatBlockStyles[value] ?? '$value';
    if (key == 'letter_block_style') {
      return letterBlockStyles[value] ?? '$value';
    }
    if (key == 'inset_font') return insetFonts[value] ?? '$value';
    if (key == 'inset_detect') return insetDetectModes[value] ?? '$value';
    if (key == 'inset_styles') {
      return value is Map && value.isNotEmpty ? '改过 ${value.length} 种' : '全部内置';
    }
    if (key == 'system_block_style') {
      return systemBlockStyles[value] ?? '$value';
    }
    if (key == 'system_styles') return describeSystemStyles(value);
    if (key == 'verse_block_style') return verseBlockStyles[value] ?? '$value';
    if (key == 'note_style') return noteStyles[value] ?? '$value';
    if (key == 'chapter_head_scope') {
      return chapterHeadScopes[value] ?? '$value';
    }
    if (key == 'chapter_head_width') {
      return chapterHeadWidths[value] ?? '$value';
    }
    if (key == 'text_alignment') {
      return {
            'start': '随文字方向',
            'left': '左对齐',
            'right': '右对齐',
            'center': '居中',
            'justify': '两端对齐',
          }[value] ??
          '$value';
    }
    return value == null ? '未设置' : '$value';
  }

  Future<void> save() => _saving ??= _save().whenComplete(() => _saving = null);
  Future<void> _save() async {
    if (session == null || identity == baseline) return;
    final snapshot = Map<String, Object?>.from(values);
    final snapshotIdentity = identity;
    // 只有数字框没填完时才暂缓；系统提示、场景样式参数等可以为空（用内置默认）。
    if (snapshot.entries.any(
          (e) => numbers.containsKey(e.key) && e.value == null,
        ) ||
        snapshot.values.whereType<double>().any((value) => !value.isFinite)) {
      if (mounted) setState(() => message = '输入已暂存；数字补全后自动应用。');
      return;
    }
    try {
      final plan = await session!.preview({
        for (final entry in snapshot.entries)
          if (entry.value != savedValues[entry.key]) entry.key: entry.value,
      });
      await session!.apply(plan);
      if (!mounted) return;
      setState(() {
        savedValues = snapshot;
        baseline = snapshotIdentity;
        message = '已应用到本书';
      });
      if (identity == baseline) {
        autosave?.writeDraft(draftKey, null);
      } else {
        changed();
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message = '${deskErrorText(error, '暂未应用到书稿')}；输入已暂存，可重试保存。',
        );
      }
    }
  }

  // ---------------------------------------------------------------- 真机预览（V30，LAY-108–110）

  Map<String, Object?> _kindleState() => {
    'title': '',
    'devices': [
      for (final k in kindleDevices) _kindleDevice(k),
      if (device.id == 'custom') _kindleDevice(device.device),
    ],
    'device': device.id,
    'reader': {
      'level': device.level,
      'margin': device.margin,
      'spacing': device.spacing,
    },
    'values': {
      for (final e in values.entries)
        if (e.value != null) e.key: e.value,
      // 章节样式包（V76）：预览里可开关、改卷页边框；写回时按样式包单独应用。
      // 系统提示分类样式（V77）：预览里按预设切换，参数被改过时为 custom。
      'system_note_preset': presetOf(
        (systemStyles ?? defaultSystemStyles())['note'] as Map?,
        notePresetNames,
      ),
      'system_panel_preset': presetOf(
        (systemStyles ?? defaultSystemStyles())['panel'] as Map?,
        panelPresetNames,
      ),
      if (chapterStyle != null) ...{
        'chapter_style_on': 'on',
        'chapter_style_volume_frame':
            chapterStyle!['volume_frame'] as String? ?? 'none',
      },
    },
    'font_size_unit': units['font_size_unit'],
    'entry': selectedChapter,
    // 设了章首图或样式包带章头图时，真机预览才显示章首图的范围与宽度（V61、V76）。
    'chapter_head':
        chapterHeadImage != null ||
        (chapterStyle?['head_images'] as List?)?.isNotEmpty == true,
    'chapter_style_name': chapterStyle?['name'],
  };

  Map<String, Object?> _kindleMetrics(Map<String, Object?> request) {
    final known = {
      for (final k in kindleDevices) k.id,
      if (device.id == 'custom') 'custom',
    };
    final id = request['device'];
    String pick(Object? value, List<String> allowed, String fallback) =>
        allowed.contains(value) ? value as String : fallback;
    final choice = device.copyWith(
      id: known.contains(id) ? id as String : device.id,
      level: ((request['level'] as num?)?.toInt() ?? device.level).clamp(1, 14),
      margin: pick(request['margin'], [
        'narrow',
        'medium',
        'wide',
      ], device.margin),
      spacing: pick(request['spacing'], [
        'small',
        'medium',
        'large',
      ], device.spacing),
      serif: request['serif'] == true,
    );
    final draft = (request['values'] as Map?) ?? const {};
    final line = (draft['line_height'] as num?)?.toDouble() ?? 1.2;
    final m = readerMetrics(choice, bookLineHeight: line);
    return {
      // 校准点是书内字号 110% 时的正文字号；根字号按此还原，书内 % 字号再在其上缩放。
      'rootPx': m.fontPx / 1.1,
      'lineRatio': m.lineRatio,
      'padding': {
        'left': m.padding.left,
        'top': m.padding.top,
        'right': m.padding.right,
        'bottom': m.padding.bottom,
      },
      'measured': m.measured,
      'note': m.note,
    };
  }

  @override
  void dispose() {
    widget.navigation.check = null;
    chapterHeadPixels?.dispose();
    disposeBodyImages(bodyImages, chapterHeadOverride);
    unawaited(_kindle?.close());
    _saveTimer?.cancel();
    session?.dispose();
    for (final controller in numbers.values) {
      controller.dispose();
    }
    _previewRevision.dispose();
    for (final c in customSize.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- 视图（V5 起，设计 D3-D）

  /// 窄窗时“排版设置 / 阅读预览”分段切换。
  int pane = 0;

  double number(String key, double fallback) {
    final value = double.tryParse(numbers[key]?.text ?? '');
    return value != null && value.isFinite ? value : fallback;
  }

  String? suffix(String key) => key == 'font_size'
      ? null
      : key == 'fullwidth_indent'
      ? '个'
      : key == 'line_height'
      ? '倍'
      : key.startsWith('margin_')
      ? null
      : 'em';

  static const _indentHelp = {
    'paragraph_indent':
        '首行缩进：生成 CSS 的 text-indent，单位为字号的倍数（em）。'
        '与“段首全角空格”同时设置时两者叠加，例如 2em + 2 个全角空格约等于缩进 4 个字；通常只用其一。',
    'fullwidth_indent':
        '段首全角空格：生成时先去掉每段原有的段首空白，再写入 N 个全角空格（最多 8 个）；0 为关闭，保留原文段首空白。'
        '与“首行缩进”同时设置时两者叠加；阅读器不支持 CSS 缩进时，全角空格仍然有效。',
  };

  /// 一个表单项标题行需要的宽度：标题文字 + 帮助图标 + 单位切换。
  double labelRowWidth(String key) {
    final painter = TextPainter(
      text: TextSpan(
        text: key == 'fullwidth_indent' ? '段首全角空格' : layoutNumbers[key]!,
        style: ui(12, w: 600),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final text = painter.width;
    painter.dispose();
    final unit = key == 'font_size' || key.startsWith('margin_');
    return text + (_indentHelp.containsKey(key) ? 26 : 0) + (unit ? 84 : 0) + 8;
  }

  Future<void> discardInput() async {
    try {
      _saveTimer?.cancel();
      await _saving;
      if (!mounted) return;
      setState(() {
        _saveTimer?.cancel();
        restore();
        autosave?.writeDraft(draftKey, null);
        message = '';
      });
    } catch (_) {
      setState(() => message = '书稿已改变，请重新打开。');
    }
  }

  static const settingsTabs = {0: '文字', 1: '标题', 2: '段落与识别', 3: '页面与结构'};

  static const builtinStyles = {'plain': '素雅', 'classic': '古典'};

  List<Widget> pageAndStructure() {
    final d = context.desk;
    return [
      group('页面', [
        grid(['margin_top', 'margin_bottom']),
        grid(['margin_left', 'margin_right']),
        Row(
          children: [
            Text('单位说明', style: ui(11.5, c: d.ink3)),
            const DeskHelp('边距改单位不换算数值；字号单位切换按 16px 基准换算。'),
          ],
        ),
      ]),
      group('成品结构', [
        for (final entry in layoutFlags.entries)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: busy
                ? null
                : () => edit(() => flags[entry.key] = !flags[entry.key]!),
            child: Row(
              children: [
                Expanded(
                  child: Text(entry.value, style: ui(12.5, c: d.ink)),
                ),
                Switch(
                  value: flags[entry.key]!,
                  onChanged: busy
                      ? null
                      : (value) => edit(() => flags[entry.key] = value),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text('附加 CSS：保存前检查字体与图片依赖', style: ui(12.5, c: d.ink)),
            ),
            DeskButton(
              '附加 CSS',
              icon: Icons.code_rounded,
              onPressed: busy ? null : showCss,
            ),
          ],
        ),
      ]),
    ];
  }

  final readerMenuController = MenuController();
  bool settingsCollapsed = false;

  /// 预览区宽度不足 760 时，设置行里的按钮只留图标。
  bool narrowPreview = false;

  /// 预览区不够宽放下完整设置行时，“实际生成预览”只留图标（LAY-102）。
  bool iconOnlyPreview = false;
  DateTime _lastWheel = DateTime(0);

  Widget statusTag() {
    if (message.isEmpty) return const SizedBox.shrink();
    final tone = message == '已应用到本书' || message.endsWith('已应用到本书。')
        ? Tone.ok
        : message.contains('暂存') ||
              message.contains('失败') ||
              message.contains('请')
        ? Tone.warn
        : Tone.neutral;
    return Tooltip(message: message, child: DeskTag(message, tone));
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    if (session == null) {
      return Center(
        child: Text(message, style: ui(13, c: d.ink2)),
      );
    }
    return Material(
      color: d.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: d.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Row(
              children: [
                Text('排版', style: ui(16, w: 650, c: d.ink)),
                const SizedBox(width: 12),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      statusTag(),
                      DeskButton(
                        '预设库 / 另存为预设',
                        quiet: true,
                        icon: Icons.bookmarks_outlined,
                        onPressed: busy ? null : showPresets,
                      ),
                      DeskButton(
                        '设置来源 / 恢复默认',
                        quiet: true,
                        icon: Icons.history_toggle_off_rounded,
                        onPressed: busy ? null : showOrigins,
                      ),
                      DeskButton(
                        '应用到多本书',
                        quiet: true,
                        icon: Icons.library_add_check_outlined,
                        onPressed: busy ? null : showBatch,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final preview = ValueListenableBuilder<int>(
                  valueListenable: _previewRevision,
                  builder: (_, _, _) => reading(),
                );
                // 设置栏宽度和两栏所需宽度都随字号放大；放不下时改用“排版设置 / 阅读预览”
                // 切换，不再把选项缩成小字（R5-04）。
                final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
                final settingsWidth = (c.maxWidth * .34).clamp(
                  340.0 * scale,
                  400.0 * scale,
                );
                final twoColumns = c.maxWidth >= 900 * scale;
                final previewWidth = twoColumns
                    ? c.maxWidth - (settingsCollapsed ? 40 : settingsWidth)
                    : c.maxWidth;
                narrowPreview = previewWidth < 760;
                iconOnlyPreview = previewWidth < 900;
                if (twoColumns) {
                  // 设置区固定较窄宽度，可收起；其余空间给预览（LAY-100）。
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (settingsCollapsed)
                        Container(
                          width: 40,
                          alignment: Alignment.topCenter,
                          padding: const EdgeInsets.only(top: 8),
                          child: IconButton(
                            key: const ValueKey('layout-settings-expand'),
                            tooltip: '展开排版设置',
                            icon: const Icon(Icons.chevron_right_rounded),
                            onPressed: () =>
                                setState(() => settingsCollapsed = false),
                          ),
                        )
                      else
                        SizedBox(
                          width: settingsWidth,
                          child: Stack(
                            children: [
                              Positioned.fill(child: settings()),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: IconButton(
                                  key: const ValueKey(
                                    'layout-settings-collapse',
                                  ),
                                  tooltip: '收起排版设置，放大预览',
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.chevron_left_rounded,
                                    color: d.ink3,
                                  ),
                                  onPressed: () =>
                                      setState(() => settingsCollapsed = true),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(left: BorderSide(color: d.line)),
                          ),
                          child: preview,
                        ),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DeskSegmented<int>(
                          value: pane,
                          options: const {0: '排版设置', 1: '阅读预览'},
                          onChanged: (v) => setState(() => pane = v),
                        ),
                      ),
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: pane,
                        children: [settings(), preview],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
