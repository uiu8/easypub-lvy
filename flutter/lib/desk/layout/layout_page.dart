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
import '../../application/settings_service.dart';

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
          BookBatchDialog(library: widget.library, bookId: widget.bookId),
    );
    if (mounted && applied == true) {
      setState(() {
        restore();
        message = '所选排版字段已应用，修改随工作区保存。';
      });
    }
  }

  Future<void> loadDevice() async {
    final store = session;
    if (store is! LayoutPreviewDeviceStore) return;
    try {
      final raw = await (store as LayoutPreviewDeviceStore).readPreviewDevice();
      if (!mounted || raw == null) return;
      device = PreviewDeviceChoice.decode(raw);
      customSize['width']!.text = '${device.width}';
      customSize['height']!.text = '${device.height}';
      customSize['ppi']!.text = '${device.ppi}';
      _previewRevision.value++;
    } catch (_) {}
  }

  void chooseDevice(PreviewDeviceChoice next) {
    device = next;
    previewPage = 0;
    _previewRevision.value++;
    final store = session;
    if (store is LayoutPreviewDeviceStore) {
      (store as LayoutPreviewDeviceStore)
          .savePreviewDevice(next.encode())
          .catchError((_) {});
    }
  }

  /// 按真机校准（LAY-096）：输入在真机当前设置下数到的每行字数与每页正文行数。
  Future<void> calibrate() async {
    final saved = device.calibrations[device.calibrationKey];
    final result = await showDialog<(int, int)?>(
      context: context,
      builder: (_) => _CalibrateDialog(device: device, initial: saved),
    );
    if (!mounted || result == null) return;
    final next = Map<String, (int, int)>.of(device.calibrations);
    if (result.$1 <= 0) {
      next.remove(device.calibrationKey);
    } else {
      next[device.calibrationKey] = result;
    }
    chooseDevice(device.copyWith(calibrations: next));
  }

  void applyCustomSize() {
    final w = int.tryParse(customSize['width']!.text.trim()) ?? 0;
    final h = int.tryParse(customSize['height']!.text.trim()) ?? 0;
    final ppi = int.tryParse(customSize['ppi']!.text.trim()) ?? 0;
    if (customKindleDevice(w, h, ppi) == null) {
      customError = '宽 320–5000、高 320–7000 像素，PPI 72–600。';
      _previewRevision.value++;
      return;
    }
    customError = '';
    chooseDevice(device.copyWith(id: 'custom', width: w, height: h, ppi: ppi));
  }

  Future<void> loadBody() async {
    try {
      final chapters = chapterSession ??= widget.library.openChapters(
        widget.bookId,
      );
      final page = chapters is ChapterOutlineSession
          ? await (chapters as ChapterOutlineSession).readOutline()
          : await chapters.read(0, includeBody: true);
      outline = page;
      final selected =
          page.nodes.where((node) => node.id == selectedChapter).firstOrNull ??
          page.nodes.where((node) => node.role == 'chapter').firstOrNull ??
          page.nodes.firstOrNull;
      selectedChapter = selected?.id;
      // 正文按块续读（每块约 30 行），预览最多取 400 行，避免只排出开头一小段。
      final lines = <String>[];
      var more = false;
      if (selected != null) {
        var offset = 0;
        while (lines.length < 400) {
          final chunk = await chapters.body(page, selected.id, offset);
          if (!mounted) return;
          lines.addAll(chunk.lines);
          more = chunk.more;
          if (!chunk.more || chunk.lines.isEmpty) break;
          offset = chunk.offset + chunk.lines.length;
        }
      }
      if (!mounted) return;
      setState(() {
        chapterTitle = selected?.title ?? '正文';
        bodyError = '';
        body = lines.take(400).join('\n');
        bodyPartial = more || lines.length > 400;
        if (body.length > 40000) {
          body = body.substring(0, 40000);
          bodyPartial = true;
        }
        previewPage = 0;
        if (body.isEmpty) bodyError = '此章节没有可预览正文。';
      });
    } catch (_) {
      if (mounted) setState(() => bodyError = '正文读取失败，请重新进入排版页。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> generatePreview() async {
    if (generatingPreview || session is! LayoutPublicationPreviewSession) {
      return;
    }
    setState(() => generatingPreview = true);
    try {
      await save();
      if (identity != baseline) throw const FormatException('请先补全排版数值。');
      final service = session as LayoutPublicationPreviewSession;
      final generated = await service.renderPreview(entryId: selectedChapter);
      await service.openPreview(generated);
      if (mounted) {
        setState(() => message = '已在浏览器打开实际生成内容，使用本书 XHTML、CSS 和资源。');
      }
    } catch (error) {
      if (mounted) {
        setState(() => message = deskErrorText(error, '实际预览生成失败，请检查本书资源后重试。'));
      }
    } finally {
      if (mounted) setState(() => generatingPreview = false);
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

  Future<void> openKindlePreview() async {
    if (session is! LayoutDraftPreviewSession) return;
    final host = widget.kindlePreview;
    final edge = host.findEdge();
    final plugin = host.findPlugin();
    if (edge == null || plugin == null) {
      setState(
        () => message = edge == null
            ? '没有找到 Microsoft Edge，无法打开真机预览。'
            : '没有找到真机预览组件（plugins/kindle-preview），请检查程序目录是否完整。',
      );
      return;
    }
    try {
      final server = _kindle ??= KindlePreviewServer(
        pluginDirectory: plugin,
        state: _kindleState,
        render: _kindleRender,
        metrics: _kindleMetrics,
        apply: _kindleApply,
      );
      await host.launch(edge, await server.start());
      if (mounted) setState(() => message = '已在独立窗口打开真机预览。');
    } catch (_) {
      if (mounted) setState(() => message = '真机预览没有打开，请重试。');
    }
  }

  Map<String, Object?> _kindleDevice(KindleDevice k) => {
    'id': k.id,
    'name': kindleShortName(k.name),
    'width': k.width,
    'height': k.height,
    'ppi': k.ppi,
    'viewportWidth': k.viewportWidth,
    'viewportHeight': k.viewportHeight,
    'bodyWidthMm': k.bodyWidthMm,
    'bodyHeightMm': k.bodyHeightMm,
    'grip': k.grip,
    'gripLeft': k.gripLeft,
    'topBezelMm': k.topBezelMm,
    'cornerMm': k.cornerMm,
    'logo': k.logo,
    'pressMarks': k.pressMarks,
  };

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

  /// 真机预览送来的样式包设置（V76）：返回去掉这两个键后的排版值，以及对应的样式包（null 为停用）。
  (Map<String, Object?>, Map<String, dynamic>?) _kindleStyle(
    Map<String, Object?> draft,
  ) {
    final rest = Map<String, Object?>.from(draft);
    // 系统提示预设（V77）：换成对应参数；custom 表示不改。
    final note = rest.remove('system_note_preset');
    final panel = rest.remove('system_panel_preset');
    if (blockStylePresets.containsKey(note) ||
        blockStylePresets.containsKey(panel)) {
      final base = Map<String, dynamic>.from(
        (rest['system_styles'] as Map?) ??
            systemStyles ??
            defaultSystemStyles(),
      );
      if (notePresetNames.containsKey(note)) {
        base['note'] = blockStylePresets[note]!;
      }
      if (panelPresetNames.containsKey(panel)) {
        base['panel'] = blockStylePresets[panel]!;
      }
      rest['system_styles'] = base;
    }
    final on = rest.remove('chapter_style_on');
    final frame = rest.remove('chapter_style_volume_frame');
    final style = chapterStyle;
    if (style == null || on == 'off') return (rest, null);
    return (
      rest,
      {
        ...style,
        if (frame is String && volumeFrames.containsKey(frame))
          'volume_frame': frame,
      },
    );
  }

  Future<LayoutDraftPreview> _kindleRender(
    Map<String, Object?> draft,
    String? entry,
  ) {
    final current = session;
    if (!mounted || current is! LayoutDraftPreviewSession) {
      throw const FormatException('排版页已关闭。');
    }
    final (rest, style) = _kindleStyle(draft);
    return (current as LayoutDraftPreviewSession).renderDraftPreview({
      for (final e in values.entries)
        if (e.value != null) e.key: e.value,
      ...rest,
      if (chapterStyle != null) 'chapter_style': style,
    }, entryId: entry ?? selectedChapter);
  }

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

  Future<String?> _kindleApply(Map<String, Object?> request) async {
    if (!mounted || session == null) return '排版页已关闭。';
    if (busy) return '排版页正在处理，请稍后再试。';
    final styled =
        request.containsKey('chapter_style_on') ||
        request.containsKey('chapter_style_volume_frame');
    final (draft, style) = _kindleStyle(request);
    if (draft.keys.any((key) => !layoutFields.contains(key))) {
      return '只能写回排版字段。';
    }
    // 样式包（V76）：与排版页“章节样式包”同一条应用路径，进变更记录。
    if (styled && chapterStyle != null) {
      final before = chapterStyle;
      await setChapterStyle(style, style == null ? '已停用样式包' : '已更新样式包');
      if (!mounted) return '排版页已关闭。';
      if (chapterStyle == before) return '样式包未能写回，请在排版页查看原因。';
      if (draft.isEmpty) return null;
    }
    edit(() {
      for (final e in draft.entries) {
        final value = e.value;
        switch (e.key) {
          case 'text_alignment':
            if (value is String) alignment = value;
          case 'writing_mode':
            if (value is String) writingMode = value;
          case 'vertical_digits':
            if (value is num) verticalDigits = value.toInt();
          case 'heading_style':
            if (value is String && headingStyles.containsKey(value)) {
              headingStyle = value;
            }
          case 'scene_break_style':
            if (value is String && sceneBreakStyles.containsKey(value)) {
              sceneBreakStyle = value;
            }
          case 'first_paragraph_style':
            if (value is String && firstParagraphStyles.containsKey(value)) {
              firstParagraphStyle = value;
            }
          case 'rare_char_ruby':
            if (value is String && rareCharRubyModes.containsKey(value)) {
              rareCharRuby = value;
            }
          case 'rare_char_scope':
            if (value is String && rareCharScopes.containsKey(value)) {
              rareCharScope = value;
            }
          case 'chat_block_style':
            if (value is String && chatBlockStyles.containsKey(value)) {
              chatBlockStyle = value;
            }
          case 'letter_block_style':
            if (value is String && letterBlockStyles.containsKey(value)) {
              letterBlockStyle = value;
            }
          case 'inset_font':
            if (value is String && insetFonts.containsKey(value)) {
              insetFont = value;
            }
          case 'inset_detect':
            if (value is String && insetDetectModes.containsKey(value)) {
              insetDetect = value;
            }
          case 'inset_styles':
            if (value == null || value is Map) {
              insetStyles = (value as Map?)?.cast<String, dynamic>();
            }
          case 'chapter_head_scope':
            if (value is String && chapterHeadScopes.containsKey(value)) {
              chapterHeadScope = value;
            }
          case 'chapter_head_width':
            if (value is String && chapterHeadWidths.containsKey(value)) {
              chapterHeadWidth = value;
            }
          case 'system_block_style':
            if (value is String && systemBlockStyles.containsKey(value)) {
              systemBlockStyle = value;
            }
          case 'system_styles':
            if (value == null || value is Map) {
              systemStyles = (value as Map?)?.cast<String, dynamic>();
            }
          case 'verse_block_style':
            if (value is String && verseBlockStyles.containsKey(value)) {
              verseBlockStyle = value;
            }
          case 'note_style':
            if (value is String && noteStyles.containsKey(value)) {
              noteStyle = value;
            }
          default:
            final controller = numbers[e.key];
            if (controller != null && value is num) {
              controller.text = e.key == 'fullwidth_indent'
                  ? '${value.toInt()}'
                  : '${value.toDouble()}';
            } else if (value is bool && flags.containsKey(e.key)) {
              flags[e.key] = value;
            } else if (value is String && units.containsKey(e.key)) {
              units[e.key] = value;
            }
        }
      }
    });
    await save();
    if (!mounted) return '排版页已关闭。';
    return identity == baseline ? null : '没有写回：$message';
  }

  @override
  void dispose() {
    widget.navigation.check = null;
    chapterHeadPixels?.dispose();
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

  Widget field(String key) {
    final d = context.desk;
    final unitKey = key == 'font_size'
        ? 'font_size_unit'
        : key.startsWith('margin_')
        ? '${key}_unit'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分列时按最长标题决定列数（LAY-103），同一行的标题都放得下，输入框保持对齐；
        // 只剩一列仍放不下时标题换行，不再省略。原来标题与 Spacer 平分剩余宽度，
        // 较长的标题因此被省略；现在标题与帮助图标占用单位切换以外的全部宽度。
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Tooltip(
                        message: key == 'fullwidth_indent'
                            ? '段首全角空格'
                            : layoutNumbers[key]!,
                        child: Text(
                          key == 'fullwidth_indent'
                              ? '段首全角空格'
                              : layoutNumbers[key]!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ui(12, w: 600, c: d.ink2),
                        ),
                      ),
                    ),
                  ),
                  if (_indentHelp[key] case final help?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: DeskHelp(help, key: ValueKey('layout-help-$key')),
                    ),
                ],
              ),
            ),
            if (unitKey != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: KeyedSubtree(
                  key: ValueKey('layout-$unitKey'),
                  child: DeskSegmented<String>(
                    value: units[unitKey]!,
                    options: key == 'font_size'
                        ? const {'%': '%', 'px': 'px'}
                        : const {'em': 'em', 'px': 'px'},
                    onChanged: busy
                        ? null
                        : (value) => key == 'font_size'
                              ? edit(() {
                                  if (value == units['font_size_unit']) return;
                                  final old =
                                      double.tryParse(numbers[key]!.text) ?? 18;
                                  numbers[key]!.text =
                                      (value == '%'
                                              ? old / 16 * 100
                                              : old * 16 / 100)
                                          .toStringAsFixed(1);
                                  units['font_size_unit'] = value;
                                })
                              : edit(() => units[unitKey] = value),
                  ),
                ),
              ),
          ],
        ),
        TextField(
          key: ValueKey('layout-$key'),
          controller: numbers[key],
          enabled: !busy,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: mono(13, c: d.ink),
          decoration: deskInput(context).copyWith(
            suffixText: suffix(key),
            suffixStyle: ui(12, c: d.ink3),
          ),
        ),
      ],
    );
  }

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

  Widget grid(List<String> keys) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: LayoutBuilder(
      builder: (context, c) {
        // 列数按最长的标题行决定（LAY-103）：标题、帮助图标与单位切换都放得下才分列，
        // 输入框至少 120 宽；否则减少列数（设置区收窄后见 LAY-100）。
        final widest = keys.map(labelRowWidth).fold(120.0, math.max);
        var columns = keys.length;
        while (columns > 1 &&
            (c.maxWidth - 10 * (columns - 1)) / columns < widest) {
          columns--;
        }
        final width = (c.maxWidth - 10 * (columns - 1)) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final key in keys) SizedBox(width: width, child: field(key)),
          ],
        );
      },
    ),
  );

  Widget group(String title, List<Widget> children) {
    final d = context.desk;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: ui(13, w: 650, c: d.ink)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
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

  Widget settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        key: const ValueKey('layout-settings-actions'),
        padding: const EdgeInsets.fromLTRB(20, 10, 14, 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: context.desk.line)),
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DeskButton(
              '应用我的默认排版',
              quiet: true,
              icon: Icons.auto_awesome_outlined,
              onPressed: busy ? null : applyClassicDefaults,
            ),
            DeskButton(
              '撤销未应用输入',
              quiet: true,
              icon: Icons.undo_rounded,
              onPressed: busy ? null : discardInput,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 14, 0),
        child: KeyedSubtree(
          key: const ValueKey('layout-tabs'),
          child: DeskSegmented<int>(
            value: settingsTab,
            options: settingsTabs,
            onChanged: (value) => setState(() => settingsTab = value),
          ),
        ),
      ),
      Expanded(child: settingsList()),
    ],
  );

  static const settingsTabs = {0: '文字', 1: '标题', 2: '段落与识别', 3: '页面与结构'};

  /// 段落与识别里的一项：收起时一行显示名称与当前选择，点开才显示选项。
  Widget foldRow({
    required String field,
    required String label,
    required Widget help,
    required String current,
    required Widget control,
  }) {
    final d = context.desk;
    final open = expandedRows.contains(field);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: d.surface,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            key: ValueKey('layout-row-$field'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(
              () => open ? expandedRows.remove(field) : expandedRows.add(field),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Text(label, style: ui(12.5, w: 600, c: d.ink)),
                  help,
                  const Spacer(),
                  Flexible(
                    child: Text(
                      current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(12, c: d.ink2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: d.ink3,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 2, 0, 8),
            child: control,
          ),
        Divider(height: 1, color: d.line),
      ],
    );
  }

  /// 书写方向、竖排数字横排与注音/着重号写法（V28，LAY-104–107）。
  Widget writingControls() {
    final d = context.desk;
    final vertical = writingMode == 'vertical';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const DeskLabel('书写方向'),
        Align(
          alignment: Alignment.centerLeft,
          child: KeyedSubtree(
            key: const ValueKey('layout-writing_mode'),
            child: DeskSegmented<String>(
              value: writingMode,
              options: const {'horizontal': '横排', 'vertical': '竖排'},
              onChanged: busy
                  ? null
                  : (value) => edit(() => writingMode = value),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const DeskLabel('竖排中数字横排'),
        Row(
          children: [
            // 横排时控件自身变淡（onChanged 为 null）；Flexible 让窄栏里按比例缩小。
            Flexible(
              child: KeyedSubtree(
                key: const ValueKey('layout-vertical_digits'),
                child: DeskSegmented<int>(
                  value: verticalDigits,
                  options: const {
                    0: '不横排',
                    1: '1 位',
                    2: '2 位',
                    3: '3 位',
                    4: '4 位',
                  },
                  onChanged: busy || !vertical
                      ? null
                      : (value) => edit(() => verticalDigits = value),
                ),
              ),
            ),
            const DeskHelp(
              '竖排时从右往左翻页；不超过所选位数、前后不连字母的半角数字横着排（如 12 月），更长的仍竖排。横排时不生效。',
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text('注音与着重号写法', style: ui(12.5, c: d.ink)),
            const DeskHelp(
              '正文里写“｜汉字《hàn zì》”生成注音，写“｜重点《・》”生成着重号。必须用全角竖线“｜”开头，普通书名号《》不受影响。目录和书名里只保留基础文字。',
              key: ValueKey('layout-help-inline-markup'),
            ),
          ],
        ),
      ],
    );
  }

  /// 统一章首图（V54，LAY-124）：选图后单独预览并应用（进变更记录），不经草稿；范围与宽度是排版字段。
  Future<void> setChapterHeadImage(String? path) async {
    if (session == null) return;
    setState(() => busy = true);
    try {
      await session!.apply(
        await session!.preview({'chapter_head_image': path}),
      );
      if (mounted) {
        setState(() {
          chapterHeadImage = path;
          message = path == null ? '已移除章首图' : '已设置章首图';
        });
        unawaited(loadChapterHeadPixels());
      }
    } catch (error) {
      if (mounted) {
        setState(() => message = deskErrorText(error, '章首图未能应用'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// 读入章首图供小预览绘制；读不了时不画，不影响保存与成品。
  Future<void> loadChapterHeadPixels() async {
    final path = chapterHeadImage;
    if (path == _chapterHeadLoaded) return;
    _chapterHeadLoaded = path;
    dui.Image? image;
    if (path != null) {
      try {
        final codec = await dui.instantiateImageCodec(
          await File(path).readAsBytes(),
        );
        image = (await codec.getNextFrame()).image;
      } catch (_) {
        image = null;
      }
    }
    if (!mounted || _chapterHeadLoaded != path) {
      image?.dispose();
      return;
    }
    setState(() {
      chapterHeadPixels?.dispose();
      chapterHeadPixels = image;
    });
  }

  Widget chapterHeadControls() {
    final d = context.desk;
    final name = chapterHeadImage?.replaceAll('\\', '/').split('/').last;
    final pick = widget.pickImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('章首图', style: ui(12, w: 600, c: d.ink2)),
            const DeskHelp(
              '选一张图，自动放在每章（或每卷）标题上方；花饰、分隔线这类小图最合适，满宽的大图会挤占章首页的正文。'
              '某章若在资源页把插图版式设为“章首图”，这一章用它代替统一的图。序言、后记不加。'
              '全书只存一份图片；原文不改，EPUB、AZW3、MOBI、KFX 都生效。',
              key: ValueKey('layout-help-chapter-head'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                name ?? '未设置',
                key: const ValueKey('layout-chapter-head-name'),
                overflow: TextOverflow.ellipsis,
                style: ui(12.5, c: name == null ? d.ink3 : d.ink),
              ),
            ),
            DeskButton(
              name == null ? '选择图片…' : '更换…',
              key: const ValueKey('layout-chapter-head-pick'),
              quiet: true,
              onPressed: busy || pick == null
                  ? null
                  : () async {
                      final path = await pick();
                      if (path != null && mounted) {
                        await setChapterHeadImage(path);
                      }
                    },
            ),
            if (name != null)
              DeskButton(
                '移除',
                key: const ValueKey('layout-chapter-head-remove'),
                quiet: true,
                onPressed: busy ? null : () => setChapterHeadImage(null),
              ),
          ],
        ),
        if (name != null ||
            (chapterStyle?['head_images'] as List?)?.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text('用于', style: ui(12, c: d.ink2)),
          const SizedBox(height: 4),
          KeyedSubtree(
            key: const ValueKey('layout-chapter_head_scope'),
            child: DeskSegmented<String>(
              value: chapterHeadScope,
              options: chapterHeadScopes,
              onChanged: busy
                  ? null
                  : (value) => edit(() => chapterHeadScope = value),
            ),
          ),
          const SizedBox(height: 8),
          Text('宽度', style: ui(12, c: d.ink2)),
          const SizedBox(height: 4),
          KeyedSubtree(
            key: const ValueKey('layout-chapter_head_width'),
            child: DeskSegmented<String>(
              value: chapterHeadWidth,
              options: chapterHeadWidths,
              onChanged: busy
                  ? null
                  : (value) => edit(() => chapterHeadWidth = value),
            ),
          ),
        ],
      ],
    );
  }

  /// 章节样式包（V74，LAY-130）：单独预览并应用（进变更记录），不经草稿。
  Future<void> setChapterStyle(Map<String, dynamic>? style, String done) async {
    if (session == null) return;
    setState(() => busy = true);
    try {
      await session!.apply(await session!.preview({'chapter_style': style}));
      if (mounted) {
        setState(() {
          chapterStyle = style;
          message = done;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => message = deskErrorText(error, '章节样式包未能应用'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<Map<String, dynamic>?> styleRequest(
    Map<String, Object?> request,
    String failed,
  ) async {
    final store = session;
    if (store is! ChapterStyleStore) return null;
    setState(() => busy = true);
    try {
      return await (store as ChapterStyleStore).chapterStyleRequest(request);
    } catch (error) {
      if (mounted) setState(() => message = deskErrorText(error, failed));
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> useBuiltinStyle(String id) async {
    final result = await styleRequest({
      'action': 'builtin',
      'id': id,
    }, '内置样式包未能生成');
    final style = (result?['style'] as Map?)?.cast<String, dynamic>();
    if (style != null && mounted) {
      await setChapterStyle(style, '已使用样式包“${style['name']}”');
      applyPackBlocks(result?['blocks']);
      applyPackInsets(result?['insets']);
    }
  }

  /// 系统提示自定义识别规则（V78）：写进本书 rule_options，进变更记录。
  Future<void> setSystemPatterns(List<String> next, String done) async {
    final current = session;
    if (current == null) return;
    setState(() => busy = true);
    try {
      final options = Map<String, dynamic>.from(
        (current.saved['rule_options'] as Map?) ?? const {},
      );
      if (next.isEmpty) {
        options.remove('system_patterns');
      } else {
        options['system_patterns'] = next;
      }
      await current.apply(await current.preview({'rule_options': options}));
      if (mounted) {
        setState(() {
          systemPatterns = next;
          message = done;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => message = deskErrorText(error, '识别规则未能保存'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget systemPatternControls() {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: 64,
              child: Text('自定义识别', style: ui(12, c: d.ink2)),
            ),
          ),
          Expanded(
            child: Wrap(
              key: const ValueKey('layout-system-patterns'),
              children: [
                for (final p in systemPatterns)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, bottom: 4),
                    child: InputChip(
                      key: ValueKey(('layout-system-pattern', p)),
                      label: Text(
                        systemPatternLabel(p),
                        style: ui(12, c: d.ink),
                      ),
                      onDeleted: busy
                          ? null
                          : () => setSystemPatterns(
                              [...systemPatterns]..remove(p),
                              '已删除识别规则',
                            ),
                      deleteButtonTooltipMessage: '删除这条规则',
                    ),
                  ),
                DeskButton(
                  '添加规则…',
                  key: const ValueKey('layout-system-pattern-add'),
                  quiet: true,
                  onPressed: busy || systemPatterns.length >= 20
                      ? null
                      : () async {
                          final p = await showSystemPatternDialog(context);
                          if (p == null || !mounted) return;
                          if (systemPatterns.contains(p)) return;
                          await setSystemPatterns([
                            ...systemPatterns,
                            p,
                          ], '已添加识别规则');
                        },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 样式包带的系统提示块样式（V78）：一并切到分类样式并套用。
  void applyPackBlocks(Object? blocks) {
    if (blocks is! Map || !mounted) return;
    edit(() {
      systemBlockStyle = 'styled';
      systemStyles = Map<String, dynamic>.from(blocks);
    });
  }

  /// 样式包带的场景样式（V82）：聊天记录样式、书信样式与改过的各场景参数一并套用。
  void applyPackInsets(Object? insets) {
    if (insets is! Map || !mounted) return;
    edit(() {
      chatBlockStyle = insets['chat_block_style'] as String? ?? chatBlockStyle;
      letterBlockStyle =
          insets['letter_block_style'] as String? ?? letterBlockStyle;
      final styles = (insets['styles'] as Map?)?.cast<String, dynamic>();
      insetStyles = styles == null || styles.isEmpty ? null : styles;
    });
  }

  Future<void> importStyle() async {
    final path = await widget.pickStylePack?.call();
    if (path == null || !mounted) return;
    final result = await styleRequest({
      'action': 'import',
      'path': path,
    }, '样式包未能导入：请检查文件内容');
    final style = (result?['style'] as Map?)?.cast<String, dynamic>();
    if (style != null && mounted) {
      await setChapterStyle(style, '已导入并使用样式包“${style['name']}”');
      applyPackBlocks(result?['blocks']);
      applyPackInsets(result?['insets']);
    }
  }

  Future<void> exportStyle() async {
    final style = chapterStyle;
    if (style == null) return;
    final path = await widget.pickStylePackDestination?.call(
      style['name'] as String,
    );
    if (path == null || !mounted) return;
    final result = await styleRequest({
      'action': 'export',
      'style': style,
      'blocks': systemBlockStyle == 'styled'
          ? (systemStyles ?? defaultSystemStyles())
          : null,
      // 场景样式（V82）：聊天、书信样式与改过的各场景参数。
      'insets': {
        'chat_block_style': chatBlockStyle,
        'letter_block_style': letterBlockStyle,
        if (insetStyles != null && insetStyles!.isNotEmpty)
          'styles': insetStyles,
      },
      'path': path,
    }, '样式包未能导出：请选择新的文件名');
    if (result != null && mounted) {
      setState(() => message = '已导出样式包');
    }
  }

  /// 去掉样式包里的某一项（再选一次样式包可以恢复）。
  Future<void> dropStyleItem(String key) async {
    final style = Map<String, dynamic>.from(chapterStyle!);
    style[key] = key == 'head_images' ? <String>[] : null;
    await setChapterStyle(style, '已更新样式包');
  }

  static const builtinStyles = {'plain': '素雅', 'classic': '古典'};

  Widget chapterStyleControls() {
    final d = context.desk;
    final style = chapterStyle;
    final name = style?['name'] as String?;
    final heads = (style?['head_images'] as List?)?.length ?? 0;
    Widget choice(String label, bool selected, VoidCallback? onTap, Key key) =>
        Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 6),
          child: ChoiceChip(
            key: key,
            label: Text(label, style: ui(12.5, c: d.ink)),
            selected: selected,
            onSelected: busy || onTap == null ? null : (_) => onTap(),
          ),
        );
    Widget item(String key, String label, bool present) => Row(
      children: [
        Icon(
          present ? Icons.check_rounded : Icons.remove_rounded,
          size: 15,
          color: present ? d.ink : d.ink3,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label, style: ui(12.5, c: present ? d.ink : d.ink3)),
        ),
        if (present)
          DeskButton(
            '去掉',
            key: ValueKey('layout-chapter-style-drop-$key'),
            quiet: true,
            onPressed: busy ? null : () => dropStyleItem(key),
          ),
      ],
    );
    return Column(
      key: const ValueKey('layout-chapter-style'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('章节样式包', style: ui(12, w: 600, c: d.ink2)),
            const DeskHelp(
              '一套章节装饰：章头图（多张时按章轮换）、标题下装饰线、章末装饰、卷页边框。'
              '内置的“素雅”“古典”是程序画的线条与几何装饰；也可以导入别人做的样式包（.zip），或把本书的样式导出分享。'
              '已设“章首图”时以章首图为准。原文不改，EPUB、AZW3、MOBI、KFX 都生效。小预览里不显示样式包。',
              key: ValueKey('layout-help-chapter-style'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          children: [
            choice(
              '不使用',
              style == null,
              style == null ? null : () => setChapterStyle(null, '已停用样式包'),
              const ValueKey('layout-chapter-style-none'),
            ),
            for (final e in builtinStyles.entries)
              choice(
                e.value,
                name == e.value &&
                    (style?['head_images'] as List?)?.every(
                          (p) => '$p'.contains('builtin-${e.key}-'),
                        ) ==
                        true,
                () => useBuiltinStyle(e.key),
                ValueKey('layout-chapter-style-${e.key}'),
              ),
            if (name != null && !builtinStyles.containsValue(name))
              choice(
                name,
                true,
                null,
                const ValueKey('layout-chapter-style-own'),
              ),
          ],
        ),
        Row(
          children: [
            DeskButton(
              '导入样式包…',
              key: const ValueKey('layout-chapter-style-import'),
              quiet: true,
              onPressed: busy || widget.pickStylePack == null
                  ? null
                  : importStyle,
            ),
            if (style != null)
              DeskButton(
                '导出…',
                key: const ValueKey('layout-chapter-style-export'),
                quiet: true,
                onPressed: busy || widget.pickStylePackDestination == null
                    ? null
                    : exportStyle,
              ),
          ],
        ),
        if (style != null) ...[
          const SizedBox(height: 6),
          item('head_images', heads > 0 ? '章头图 $heads 张' : '章头图', heads > 0),
          item('title_rule', '标题下装饰线', style['title_rule'] != null),
          item('chapter_end', '章末装饰', style['chapter_end'] != null),
          const SizedBox(height: 6),
          Text('卷页边框', style: ui(12, c: d.ink2)),
          const SizedBox(height: 4),
          KeyedSubtree(
            key: const ValueKey('layout-chapter-style-volume_frame'),
            child: DeskSegmented<String>(
              value: style['volume_frame'] as String? ?? 'none',
              options: volumeFrames,
              onChanged: busy
                  ? null
                  : (value) => setChapterStyle({
                      ...style,
                      'volume_frame': value,
                    }, '已更新卷页边框'),
            ),
          ),
        ],
      ],
    );
  }

  /// 章节标题样式（V36，LAY-117）：五个缩略图，点选即改；问号说明分页与适用格式。
  Widget headingControls() {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('章节标题样式', style: ui(12, w: 600, c: d.ink2)),
            const DeskHelp(
              '样式取自市面成品书：EasyPub 经典（原版 EasyPub）、亚马逊官方、出版社、精排两行（网文精排）、日系轻小说。'
              '每章从新的一页开始；样式同时用于 EPUB、AZW3、MOBI、KFX。',
              key: ValueKey('layout-help-heading-style'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, box) {
            final columns = box.maxWidth < 300 ? 2 : 3;
            final width = (box.maxWidth - 8 * (columns - 1)) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in headingStyles.entries)
                  SizedBox(width: width, child: headingTile(e.key, e.value)),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 场景分隔（V46，LAY-118）：五个选项，问号说明识别规则。
  Widget sceneBreakControls() => foldRow(
    field: 'scene_break_style',
    label: '场景分隔',
    help: const DeskHelp(
      '章内换场的分隔行：整行都是 *、＊、※、◇、☆、＝、～、# 等符号（至少 3 个）时识别。'
      '“……”“——”单独成行仍当正文。原文不改，只改显示；样式同时用于 EPUB、AZW3、MOBI、KFX。',
      key: ValueKey('layout-help-scene-break'),
    ),
    current: sceneBreakStyles[sceneBreakStyle] ?? sceneBreakStyle,
    control: KeyedSubtree(
      key: const ValueKey('layout-scene_break_style'),
      child: DeskSegmented<String>(
        value: sceneBreakStyle,
        options: sceneBreakStyles,
        onChanged: busy ? null : (value) => edit(() => sceneBreakStyle = value),
      ),
    ),
  );

  /// 系统提示与诗词（V50，LAY-121/122）：三个选项，问号说明识别规则。
  Widget blockControls(
    String label,
    String help,
    String field,
    String value,
    Map<String, String> options,
    void Function(String) assign,
  ) => foldRow(
    field: field,
    label: label,
    help: DeskHelp(help, key: ValueKey('layout-help-$field')),
    current: options[value] ?? value,
    control: KeyedSubtree(
      key: ValueKey('layout-$field'),
      child: DeskSegmented<String>(
        value: value,
        options: options,
        onChanged: busy ? null : (next) => edit(() => assign(next)),
      ),
    ),
  );

  /// 场景识别规则（V82，LAY-137）：写进本书 rule_options.inset_rules，进变更记录；添加规则时一并开启识别。
  Future<void> setInsetRules(
    List<Map<String, dynamic>> next,
    String done, {
    bool enable = false,
  }) async {
    final current = session;
    if (current == null) return;
    setState(() => busy = true);
    try {
      // 先把还没保存的排版修改存掉，再单独写规则。
      _saveTimer?.cancel();
      await save();
      final clean = identity == baseline;
      final options = Map<String, dynamic>.from(
        (current.saved['rule_options'] as Map?) ?? const {},
      );
      if (next.isEmpty) {
        options.remove('inset_rules');
      } else {
        options['inset_rules'] = next;
      }
      await current.apply(
        await current.preview({
          'rule_options': options,
          if (enable && insetDetect != 'on') 'inset_detect': 'on',
        }),
      );
      if (mounted) {
        setState(() {
          insetRules = next;
          if (enable) insetDetect = 'on';
          _identityCache = _computeIdentity();
          savedValues = {...savedValues, 'inset_detect': insetDetect};
          if (clean) baseline = identity;
          message = done;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => message = deskErrorText(error, '识别规则未能保存'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget insetDetectControls() {
    final d = context.desk;
    return foldRow(
      field: 'inset_detect',
      label: '场景识别',
      help: const DeskHelp(
        '按规则把整段正文认成场景：内置“诏书”（以奉天承运、圣旨、诏曰开头，到“钦此”结束）与“论坛楼层”'
        '（连续两层以上的“1楼”“#2”“沙发”）；也可以添加自己的规则：选场景，写开头和结尾（文字或正则）与最多行数。'
        '手工标注优先，其次规则，再其次聊天自动识别。内置项可在规则页单独关闭。原文不改。',
        key: ValueKey('layout-help-inset_detect'),
      ),
      current:
          '${insetDetectModes[insetDetect] ?? insetDetect}'
          '${insetRules.isEmpty ? '' : ' · 自定义 ${insetRules.length} 条'}',
      control: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: const ValueKey('layout-inset_detect'),
            child: DeskSegmented<String>(
              value: insetDetect,
              options: insetDetectModes,
              onChanged: busy
                  ? null
                  : (value) => edit(() => insetDetect = value),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            key: const ValueKey('layout-inset-rules'),
            children: [
              for (final (i, r) in insetRules.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 4),
                  child: InputChip(
                    key: ValueKey(('layout-inset-rule', i)),
                    label: Text(insetRuleLabel(r), style: ui(12, c: d.ink)),
                    onDeleted: busy
                        ? null
                        : () => setInsetRules(
                            [...insetRules]..removeAt(i),
                            '已删除场景识别规则',
                          ),
                    deleteButtonTooltipMessage: '删除这条规则',
                  ),
                ),
              DeskButton(
                '添加规则…',
                key: const ValueKey('layout-inset-rule-add'),
                quiet: true,
                onPressed: busy || insetRules.length >= 20
                    ? null
                    : () async {
                        final rule = await showInsetRuleDialog(context);
                        if (rule == null || !mounted) return;
                        await setInsetRules(
                          [...insetRules, rule],
                          '已添加场景识别规则',
                          enable: true,
                        );
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 各场景的样式（V82，LAY-136）：预设、我的场景样式、自定义，“编辑…”打开编辑器。
  Widget insetStyleControls() {
    final d = context.desk;
    final settings = widget.library is SettingsService
        ? widget.library as SettingsService
        : null;
    Map<String, Object> current(String scene) {
      final mine = insetStyles?[scene];
      return mine is Map
          ? Map<String, Object>.from(mine)
          : defaultInsetStyle(scene, chatBlockStyle);
    }

    void choose(String scene, Map<String, Object> style) => edit(() {
      // 选聊天的三种预设之一且开着识别时，改的是“聊天记录”设置本身。
      final preset = insetPresetOf(scene, style);
      if (scene == 'chat' && chatBlockStyle != 'off' && preset != 'custom') {
        chatBlockStyle = preset;
        insetStyles = {...?insetStyles}..remove('chat');
      } else if (sameInsetStyle(
        defaultInsetStyle(scene, chatBlockStyle),
        style,
      )) {
        insetStyles = {...?insetStyles}..remove(scene);
      } else {
        insetStyles = {...?insetStyles, scene: style};
      }
      if (insetStyles!.isEmpty) insetStyles = null;
    });

    Widget row(String scene, Object? library) {
      final style = current(scene);
      final saved = savedInsetsOf(library, scene);
      final preset = insetPresetOf(scene, style);
      final matched =
          preset != 'custom' ||
          saved.values.any((s) => sameInsetStyle(s, style));
      Widget chip(
        String text,
        bool selected,
        VoidCallback onTap,
        Key key, {
        VoidCallback? onDelete,
      }) => Padding(
        padding: const EdgeInsets.only(right: 6, bottom: 4),
        child: InputChip(
          key: key,
          label: Text(text, style: ui(12, c: d.ink)),
          selected: selected,
          showCheckmark: false,
          onPressed: busy ? null : onTap,
          onDeleted: busy ? null : onDelete,
          deleteButtonTooltipMessage: '从我的场景样式中删除',
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: 64,
                child: Text(insetTypes[scene]!, style: ui(12, c: d.ink2)),
              ),
            ),
            Expanded(
              child: Wrap(
                key: ValueKey('layout-inset-$scene'),
                children: [
                  for (final e in insetStylePresets.entries)
                    if (e.value.$1 == scene)
                      chip(
                        e.value.$2,
                        preset == e.key,
                        () => choose(scene, Map.of(e.value.$3)),
                        ValueKey(('layout-inset-preset', scene, e.key)),
                      ),
                  for (final e in saved.entries)
                    chip(
                      e.key,
                      sameInsetStyle(e.value, style),
                      () => choose(scene, e.value),
                      ValueKey(('layout-inset-saved', scene, e.key)),
                      onDelete: settings == null
                          ? null
                          : () => settings.savePatch({
                              'inset_style_library': [
                                for (final item
                                    in (library as List? ?? const []))
                                  if (!(item is Map &&
                                      item['scene'] == scene &&
                                      item['name'] == e.key))
                                    item,
                              ],
                            }),
                    ),
                  if (!matched)
                    chip(
                      '自定义',
                      true,
                      () {},
                      ValueKey(('layout-inset-custom', scene)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: DeskButton(
                      '编辑…',
                      key: ValueKey(('layout-inset-edit', scene)),
                      quiet: true,
                      onPressed: busy
                          ? null
                          : () async {
                              final result = await showInsetStyleEditor(
                                context,
                                scene: scene,
                                initial: style,
                                takenNames: saved.keys.toSet(),
                              );
                              if (result == null || !mounted) return;
                              choose(scene, result.style);
                              if (result.name != null && settings != null) {
                                await settings.savePatch({
                                  'inset_style_library': [
                                    ...(library as List? ?? const []),
                                    {
                                      'name': result.name,
                                      'scene': scene,
                                      'style': result.style,
                                    },
                                  ],
                                });
                              }
                            },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget rows(Object? library) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final scene in insetTypes.keys) row(scene, library)],
    );
    return foldRow(
      field: 'inset_styles',
      label: '各场景样式',
      help: const DeskHelp(
        '每种场景选一种样式，“编辑…”可逐项调整（外框、线型、底色、标题与饰纹、对齐、字号、首字放大、字体、卷轴杆），'
        '另存为“我的场景样式”后所有书可用；导出章节样式包时连同聊天、书信样式一起带上。'
        '“淡纸纹”是真机测试过的最浅一级，深色模式下会随页面反转；AZW3 不显示底色与楷体。',
        key: ValueKey('layout-help-inset_styles'),
      ),
      current: insetStyles == null || insetStyles!.isEmpty
          ? '全部内置'
          : '改过 ${insetStyles!.length} 种',
      control: settings == null
          ? rows(null)
          : ValueListenableBuilder<SettingsSnapshot>(
              valueListenable: settings.snapshot,
              builder: (_, snap, _) =>
                  rows(snap.configuration['inset_style_library']),
            ),
    );
  }

  /// 系统提示（V50、V77，LAY-121/132）：识别方式；“分类样式”下单行提示与多行面板各选一种样式。
  Widget systemControls() {
    final d = context.desk;
    final styles = systemStyles ?? defaultSystemStyles();
    final note = presetOf(styles['note'] as Map?, notePresetNames);
    final panel = presetOf(styles['panel'] as Map?, panelPresetNames);
    void choose(String kind, Map<String, Object> style) => edit(() {
      systemStyles = {...Map<String, dynamic>.from(styles), kind: style};
    });
    Widget presets(
      String kind,
      String label,
      String value,
      Map<String, String> names,
    ) {
      final current = styles[kind] as Map?;
      final settings = widget.library is SettingsService
          ? widget.library as SettingsService
          : null;
      Widget chips(Object? library) {
        final saved = savedStylesOf(library, kind);
        final matched =
            value != 'custom' || saved.values.any((s) => sameStyle(s, current));
        Widget chip(
          String text,
          bool selected,
          VoidCallback onTap,
          Key key, {
          VoidCallback? onDelete,
        }) => Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 4),
          child: InputChip(
            key: key,
            label: Text(text, style: ui(12, c: d.ink)),
            selected: selected,
            showCheckmark: false,
            onPressed: busy ? null : onTap,
            onDeleted: busy ? null : onDelete,
            deleteButtonTooltipMessage: '从我的样式中删除',
          ),
        );
        return Wrap(
          children: [
            for (final e in names.entries)
              chip(
                e.value,
                value == e.key,
                () => choose(
                  kind,
                  Map<String, Object>.from(blockStylePresets[e.key]!),
                ),
                ValueKey('layout-system-$kind-${e.key}'),
              ),
            for (final e in saved.entries)
              chip(
                e.key,
                sameStyle(e.value, current),
                () => choose(kind, e.value),
                ValueKey(('layout-system-saved', kind, e.key)),
                onDelete: settings == null
                    ? null
                    : () => settings.savePatch({
                        'block_style_library': [
                          for (final item in (library as List? ?? const []))
                            if (!(item is Map &&
                                item['kind'] == kind &&
                                item['name'] == e.key))
                              item,
                        ],
                      }),
              ),
            if (!matched)
              chip('自定义', true, () {}, ValueKey('layout-system-$kind-custom')),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: DeskButton(
                '编辑…',
                key: ValueKey('layout-system-edit-$kind'),
                quiet: true,
                onPressed: busy
                    ? null
                    : () async {
                        final result = await showBlockStyleEditor(
                          context,
                          kind: kind,
                          initial: styleOrPreset(
                            current,
                            kind == 'note' ? 'bar' : 'titled',
                          ),
                          takenNames: saved.keys.toSet(),
                        );
                        if (result == null || !mounted) return;
                        choose(kind, result.style);
                        if (result.name != null && settings != null) {
                          await settings.savePatch({
                            'block_style_library': [
                              ...(library as List? ?? const []),
                              {
                                'name': result.name,
                                'kind': kind,
                                'style': result.style,
                              },
                            ],
                          });
                        }
                      },
              ),
            ),
          ],
        );
      }

      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: 64,
                child: Text(label, style: ui(12, c: d.ink2)),
              ),
            ),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey('layout-system-$kind'),
                child: settings == null
                    ? chips(null)
                    : ValueListenableBuilder<SettingsSnapshot>(
                        valueListenable: settings.snapshot,
                        builder: (_, snap, _) =>
                            chips(snap.configuration['block_style_library']),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    return foldRow(
      field: 'system_block_style',
      label: '系统提示',
      help: const DeskHelp(
        '整行由【……】组成的行（如“【叮！新手礼包已发放。】”）。行中间夹着【】的句子不算。'
        '“分类样式”：只有一行的按“单行提示”排，连续两行以上合成“面板”；紧挨在前面单独一行的“叮！”并入面板；'
        '面板首行短且没有冒号时作标题，“键：值”的键名可加粗，成品里可去掉【】。'
        '“编辑…”可逐项调整并另存为“我的样式”（所有书可用）；更自由的写法是在附加 CSS 里用公开类名 '
        '.blk-note、.blk-panel、.blk-panel-title、.blk-key、.system-line。'
        '原文不改；同时用于 EPUB、AZW3、MOBI、KFX。小预览里分类样式按加框近似显示，以真机预览为准。',
        key: ValueKey('layout-help-system_block_style'),
      ),
      current: systemBlockStyle == 'styled'
          ? describeSystemStyles(styles)
          : systemBlockStyles[systemBlockStyle] ?? systemBlockStyle,
      control: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: const ValueKey('layout-system_block_style'),
            child: DeskSegmented<String>(
              value: systemBlockStyle,
              options: systemBlockStyles,
              onChanged: busy
                  ? null
                  : (value) => edit(() {
                      systemBlockStyle = value;
                      if (value == 'styled') {
                        systemStyles ??= defaultSystemStyles();
                      }
                    }),
            ),
          ),
          if (systemBlockStyle == 'styled') ...[
            presets('note', '单行提示', note, notePresetNames),
            presets('panel', '多行面板', panel, panelPresetNames),
          ],
          if (systemBlockStyle != 'off') systemPatternControls(),
        ],
      ),
    );
  }

  /// 章首段落（V49，LAY-119）：标题后与场景分隔后的第一段。
  Widget firstParagraphControls() => foldRow(
    field: 'first_paragraph_style',
    label: '章首段落',
    help: const DeskHelp(
      '每章标题后、场景分隔后的第一段正文。“首字放大”同时取消缩进，第一个字放大加粗（不下沉）；'
      '段首是引号等标点时只取消缩进。原文不改；样式同时用于 EPUB、AZW3、MOBI、KFX。',
      key: ValueKey('layout-help-first-paragraph'),
    ),
    current: firstParagraphStyles[firstParagraphStyle] ?? firstParagraphStyle,
    control: KeyedSubtree(
      key: const ValueKey('layout-first_paragraph_style'),
      child: DeskSegmented<String>(
        value: firstParagraphStyle,
        options: firstParagraphStyles,
        onChanged: busy
            ? null
            : (value) => edit(() => firstParagraphStyle = value),
      ),
    ),
  );

  /// 生僻字注音（V73，LAY-129）：注音方式与范围；只标正文。
  Widget rareCharControls() => foldRow(
    field: 'rare_char_ruby',
    label: '生僻字注音',
    help: const DeskHelp(
      '不在《通用规范汉字表》8105 字里的字（选“表外字和三级字”时也包括表中最后 1605 个三级字），'
      '在上方标拼音。繁体字按对应简体判断；只标正文，不标标题和目录；已有注音的字不重复标。'
      '多音字取最常用读音。原文不改；同时用于 EPUB、AZW3、MOBI、KFX。小预览里不显示注音。',
      key: ValueKey('layout-help-rare-char'),
    ),
    current: rareCharRuby == 'off'
        ? rareCharRubyModes['off']!
        : '${rareCharRubyModes[rareCharRuby] ?? rareCharRuby} · '
              '${rareCharScopes[rareCharScope] ?? rareCharScope}',
    control: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KeyedSubtree(
          key: const ValueKey('layout-rare_char_ruby'),
          child: DeskSegmented<String>(
            value: rareCharRuby,
            options: rareCharRubyModes,
            onChanged: busy
                ? null
                : (value) => edit(() => rareCharRuby = value),
          ),
        ),
        const SizedBox(height: 6),
        KeyedSubtree(
          key: const ValueKey('layout-rare_char_scope'),
          child: DeskSegmented<String>(
            value: rareCharScope,
            options: rareCharScopes,
            onChanged: busy || rareCharRuby == 'off'
                ? null
                : (value) => edit(() => rareCharScope = value),
          ),
        ),
      ],
    ),
  );

  Widget headingTile(String value, String label) {
    final d = context.desk;
    final selected = headingStyle == value;
    return Semantics(
      selected: selected,
      button: true,
      label: '章节标题样式：$label',
      child: Material(
        color: d.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey('layout-heading_style-$value'),
          borderRadius: BorderRadius.circular(8),
          onTap: busy ? null : () => edit(() => headingStyle = value),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              selected ? 5 : 6,
              selected ? 5 : 6,
              selected ? 5 : 6,
              selected ? 4 : 5,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? d.accent : d.line,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: HeadingSample(
                    look: headingLooks[value]!,
                    ink: d.ink,
                    muted: d.line,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(
                    11.5,
                    w: selected ? 600 : 400,
                    c: selected ? d.ink : d.ink2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget settingsList() {
    final d = context.desk;
    return ListView(
      key: ValueKey(('layout-tab', settingsTab)),
      padding: const EdgeInsets.fromLTRB(20, 12, 14, 16),
      children: switch (settingsTab) {
        1 => [
          group('标题', [
            headingControls(),
            const SizedBox(height: 14),
            chapterHeadControls(),
            const SizedBox(height: 14),
            chapterStyleControls(),
          ]),
        ],
        2 => [
          group('段落', [firstParagraphControls(), rareCharControls()]),
          group('自动识别', [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '原文不改，只影响成品；在章节页可以手工标注，手工优先于自动识别。',
                style: ui(11.5, c: d.ink3),
              ),
            ),
            sceneBreakControls(),
            systemControls(),
            blockControls(
              '诗词',
              '整行是五言或七言对句（如“床前明月光，疑是地上霜。”），相邻几行合成一组；'
                  '紧跟其后以“——”开头的一行作为署名，靠右。自由体诗、歌词识别不了。原文不改。',
              'verse_block_style',
              verseBlockStyle,
              verseBlockStyles,
              (value) => verseBlockStyle = value,
            ),
            blockControls(
              '弹出注释',
              '识别同一章内成对的注释：正文里有 ①、[1]、〔1〕、[注1] 等标记，后面有一行以同样标记开头'
                  '（或写成“注①：”“注1：”）的注释。点标记弹出注释，注释前的标记可点回正文；'
                  '注释行仍留在原位置。不成对、重复或跨章的原样保留，原文不改。'
                  'AZW3、KFX 在 Kindle 上显示为弹窗，MOBI 旧格式为跳转后返回。小预览不显示弹窗效果。',
              'note_style',
              noteStyle,
              noteStyles,
              (value) => noteStyle = value,
            ),
          ]),
          // 场景样式（V81，LAY-135）。
          group('场景样式', [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '动态、论坛楼层、日记、古籍、诏书、羊皮纸、告示、剪报：在章节页选中正文行标注。',
                style: ui(11.5, c: d.ink3),
              ),
            ),
            blockControls(
              '聊天记录',
              '自动识别连续的“名字：内容”行（可带【】[ ]［ ］，名字不超过 6 个字，有人说话两次以上），'
                  '中间可以夹空行和时间行。识别出的聊天优先于系统提示。“不识别”时，章节页手工标注的聊天按群聊窗口排。'
                  '原文不改；同时用于 EPUB、AZW3、MOBI、KFX。',
              'chat_block_style',
              chatBlockStyle,
              chatBlockStyles,
              (value) {
                chatBlockStyle = value;
                if (value != 'off' && insetStyles != null) {
                  insetStyles = {...insetStyles!}..remove('chat');
                  if (insetStyles!.isEmpty) insetStyles = null;
                }
              },
            ),
            blockControls(
              '书信',
              '章节页标为“书信”的段落：信笺格线在每行下画虚线，落款靠右。',
              'letter_block_style',
              letterBlockStyle,
              letterBlockStyles,
              (value) => letterBlockStyle = value,
            ),
            blockControls(
              '场景字体',
              '书信（信笺格线）、古籍、诏书用楷体。Kindle 实测：KFX 里显示楷体；AZW3 由转换器去掉字体设置，用阅读器字体。',
              'inset_font',
              insetFont,
              insetFonts,
              (value) => insetFont = value,
            ),
            insetDetectControls(),
            insetStyleControls(),
          ]),
        ],
        3 => pageAndStructure(),
        _ => [
          group('文字', [
            grid(['font_size', 'line_height']),
            const DeskLabel('对齐'),
            Align(
              alignment: Alignment.centerLeft,
              child: KeyedSubtree(
                key: const ValueKey('layout-text_alignment'),
                child: DeskSegmented<String>(
                  value: alignment,
                  options: const {
                    'start': '随文字方向',
                    'justify': '两端对齐',
                    'left': '左对齐',
                    'center': '居中',
                    'right': '右对齐',
                  },
                  onChanged: busy
                      ? null
                      : (value) => edit(() => alignment = value),
                ),
              ),
            ),
            const SizedBox(height: 10),
            grid(['paragraph_indent', 'paragraph_spacing', 'fullwidth_indent']),
            const SizedBox(height: 4),
            writingControls(),
          ]),
        ],
      },
    );
  }

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

  Widget reading() {
    final d = context.desk;
    // 书页模拟 Kindle 白纸，不随软件主题变（V79）：纸色与字色固定取宣纸令牌。
    const page = Desk.light;
    if (loading) return const Center(child: CircularProgressIndicator());
    // 字号与行高按机型和阅读器设置换算（LAY-096）：书内字号以 110% 为基准缩放。
    final metrics = readerMetrics(
      device,
      bookScale:
          (units['font_size_unit'] == '%'
                  ? number('font_size', 110) / 110
                  : number('font_size', 18) / 17.6)
              .clamp(.3, 4.0),
      bookLineHeight: number('line_height', 1.2).clamp(1, 2.3),
    );
    final size = metrics.fontPx.clamp(6.0, 96.0);
    TextStyle face(double s, {FontWeight? w}) => device.serif
        ? serif(s, w: w == null ? 400 : 650, c: page.ink, h: metrics.lineRatio)
        : ui(s, w: w == null ? 400 : 650, c: page.ink, h: metrics.lineRatio);
    double margin(String side) =>
        (number('margin_$side', 0) *
                (units['margin_${side}_unit'] == 'em' ? size : 1))
            .clamp(0.0, 120.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 预览设置收成一行（LAY-098）：章节、机型、阅读器设置（弹出面板）、实测 / 推算、实际生成预览。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (outline != null && outline!.nodes.isNotEmpty)
                SizedBox(
                  width: narrowPreview ? 170 : 220,
                  child: DeskChoice<String>(
                    value: selectedChapter,
                    decoration: deskInput(context).copyWith(labelText: '预览章节'),
                    searchable: true,
                    items: [
                      for (final node in outline!.nodes)
                        DropdownMenuItem(
                          value: node.id,
                          child: Text(
                            node.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: generatingPreview
                        ? null
                        : (value) {
                            setState(() {
                              selectedChapter = value;
                              loading = true;
                            });
                            loadBody();
                          },
                  ),
                ),
              Tooltip(
                message:
                    '${device.device.name}\n${device.device.width} × ${device.device.height} · ${device.device.ppi} PPI',
                child: SizedBox(
                  width: 160,
                  child: DeskChoice<String>(
                    key: const ValueKey('layout-preview-device'),
                    value: device.id,
                    isExpanded: true,
                    // 选择框只写短名，菜单与悬停提示写全名（LAY-102）。
                    selectedLabel: (id) => Text(
                      kindleShortName(
                        kindleDevices
                                .where((k) => k.id == id)
                                .firstOrNull
                                ?.name ??
                            device.device.name,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    decoration: deskInput(context).copyWith(labelText: '预览机型'),
                    items: [
                      for (final k in kindleDevices)
                        DropdownMenuItem(
                          value: k.id,
                          child: Text(
                            k.name.split('（').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const DropdownMenuItem(
                        value: 'custom',
                        child: Text('自定义分辨率…'),
                      ),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      if (id == 'custom') {
                        applyCustomSize();
                      } else {
                        chooseDevice(device.copyWith(id: id));
                      }
                    },
                  ),
                ),
              ),
              readerMenu(metrics),
              Tooltip(
                message: metrics.measured ? '与真机照片或你的校准一致' : '只有 KPW5 的 4、8、12 档（窄边距、中行距、书内 110% / 1.2）是实测；其余按 Kindle 固件的字号表与页边距推算，可“按真机校准”',
                child: DeskTag(
                  metrics.note,
                  metrics.measured ? Tone.ok : Tone.warn,
                ),
              ),
              if (session is LayoutDraftPreviewSession)
                iconOnlyPreview
                    ? IconButton(
                        key: const ValueKey('layout-kindle-preview'),
                        tooltip: '真机预览：在独立窗口按机身尺寸显示实际生成内容',
                        icon: const Icon(Icons.tablet_android_outlined),
                        onPressed: busy ? null : openKindlePreview,
                      )
                    : DeskButton(
                        '真机预览',
                        key: const ValueKey('layout-kindle-preview'),
                        icon: Icons.tablet_android_outlined,
                        tooltip: '在独立窗口按机身尺寸显示实际生成内容，可调排版并写回',
                        onPressed: busy ? null : openKindlePreview,
                      ),
              if (session is LayoutPublicationPreviewSession)
                iconOnlyPreview
                    // 预览区较窄时只留图标，避免设置行折成两行（LAY-100、LAY-102）。
                    ? IconButton(
                        key: const ValueKey('layout-real-preview-icon'),
                        tooltip: '实际生成预览：用浏览器查看实际生成的 XHTML / CSS',
                        icon: const Icon(Icons.open_in_browser_rounded),
                        onPressed: busy || generatingPreview
                            ? null
                            : generatePreview,
                      )
                    : DeskButton(
                        '实际生成预览',
                        icon: Icons.open_in_browser_rounded,
                        busy: generatingPreview,
                        tooltip: '用浏览器查看实际生成的 XHTML / CSS',
                        onPressed: busy || generatingPreview
                            ? null
                            : generatePreview,
                      ),
              DeskHelp(
                '近似分页，以真机为准；不渲染附加 CSS。实际生成预览在浏览器打开。'
                '${bodyPartial ? '\n本章较长，只预览开头一部分。' : ''}',
              ),
            ],
          ),
          if (device.id == 'custom') ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (key, hint) in const [
                  ('width', '宽'),
                  ('height', '高'),
                  ('ppi', 'PPI'),
                ])
                  SizedBox(
                    width: 84,
                    child: TextField(
                      key: ValueKey('layout-preview-$key'),
                      controller: customSize[key],
                      keyboardType: TextInputType.number,
                      style: mono(12.5, c: d.ink),
                      decoration: deskInput(context).copyWith(labelText: hint),
                      onSubmitted: (_) => applyCustomSize(),
                    ),
                  ),
                DeskButton('更新', quiet: true, onPressed: applyCustomSize),
                if (customError.isNotEmpty)
                  Text(customError, style: ui(11.5, c: d.pen)),
              ],
            ),
          ],
          if (writingMode == 'vertical' &&
              session is LayoutDraftPreviewSession) ...[
            const SizedBox(height: 8),
            Row(
              key: const ValueKey('layout-vertical-hint'),
              children: [
                Expanded(
                  child: Text(
                    '竖排书：这里按横排近似显示，竖排、注音与着重号请在真机预览中查看。',
                    style: ui(12, c: d.ink2),
                  ),
                ),
                DeskButton(
                  '打开真机预览',
                  quiet: true,
                  onPressed: busy ? null : openKindlePreview,
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: bodyError.isNotEmpty
                ? Center(
                    child: Text(bodyError, style: ui(13, c: d.ink2)),
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      final k = device.device;
                      final pageSize = Size(
                        k.viewportWidth.toDouble(),
                        k.viewportHeight.toDouble(),
                      );
                      // 章节标题按所选样式画（V36，LAY-117）。
                      final look =
                          headingLooks[headingStyle] ??
                          headingLooks['classic']!;
                      final titleFace = look.sans
                          ? ui(
                              size * look.scale,
                              w: 700,
                              c: page.ink,
                              h: metrics.lineRatio,
                            )
                          : face(size * look.scale, w: FontWeight.w700);
                      final style = PreviewStyle(
                        title: titleFace,
                        heading: look,
                        sceneBreak: sceneBreakStyle,
                        firstParagraph: firstParagraphStyle,
                        headImage: chapterHeadScope == 'volume'
                            ? null
                            : chapterHeadPixels,
                        headFraction: switch (chapterHeadWidth) {
                          'third' => 1 / 3,
                          'full' => 1.0,
                          _ => .5,
                        },
                        systemBlock: systemBlockStyle,
                        verseBlock: verseBlockStyle,
                        ruleScale: size / 17.6,
                        body: face(size),
                        align: switch (alignment) {
                          'start' => TextAlign.start,
                          'left' => TextAlign.left,
                          'center' => TextAlign.center,
                          'right' => TextAlign.right,
                          _ => TextAlign.justify,
                        },
                        indent:
                            number('paragraph_indent', 2).clamp(0, 6) * size,
                        paragraphSpacing:
                            number('paragraph_spacing', .5).clamp(0, 6) * size,
                        titleSpacing: 20,
                        padding:
                            metrics.padding +
                            EdgeInsets.fromLTRB(
                              margin('left'),
                              margin('top'),
                              margin('right'),
                              margin('bottom'),
                            ),
                      );
                      final fullwidth = number(
                        'fullwidth_indent',
                        0,
                      ).clamp(0, 8).toInt();
                      final key = [
                        device.encode(),
                        k.viewportWidth,
                        k.viewportHeight,
                        identity,
                        chapterTitle,
                        body.length,
                        body.hashCode,
                      ].join('|');
                      if (key != _pagesKey) {
                        _pagesKey = key;
                        _pages = paginatePreview(
                          title: chapterTitle,
                          paragraphs: [
                            for (final paragraph in body.split('\n'))
                              if (flags['remove_blank_lines'] != true ||
                                  paragraph.trim().isNotEmpty)
                                paragraph.trim().isNotEmpty && fullwidth > 0
                                    ? '${'　' * fullwidth}${paragraph.replaceFirst(RegExp(r'^[ 　\t]+'), '')}'
                                    : paragraph,
                          ],
                          style: style,
                          page: pageSize,
                          locale: Localizations.maybeLocaleOf(context),
                        );
                      }
                      final index = previewPage.clamp(0, _pages.length - 1);
                      return Column(
                        children: [
                          // 按剩余空间等比放大（LAY-099）：SizedBox.expand 给出紧约束，
                          // FittedBox 才会放大；原来的 Center 只给松约束，只会缩小。
                          Expanded(
                            // 滚轮在预览上翻页（LAY-101）：向下下一页，向上上一页。
                            child: Listener(
                              key: const ValueKey('layout-preview-wheel'),
                              onPointerSignal: (event) {
                                if (event is! PointerScrollEvent) return;
                                final now = DateTime.now();
                                // 触控板一次滑动会连发很多事件：间隔太近的只算一次。
                                if (now.difference(_lastWheel) <
                                    const Duration(milliseconds: 220)) {
                                  return;
                                }
                                final next = event.scrollDelta.dy > 0
                                    ? index + 1
                                    : event.scrollDelta.dy < 0
                                    ? index - 1
                                    : index;
                                if (next == index ||
                                    next < 0 ||
                                    next >= _pages.length) {
                                  return;
                                }
                                _lastWheel = now;
                                previewPage = next;
                                _previewRevision.value++;
                              },
                              child: SizedBox.expand(
                                child: FittedBox(
                                  child: Container(
                                    key: const ValueKey('layout-preview-page'),
                                    decoration: BoxDecoration(
                                      color: page.paper,
                                      boxShadow: d.shadow2,
                                      border: Border.all(color: d.line),
                                    ),
                                    child: PreviewPage(
                                      pieces: _pages[index],
                                      style: style,
                                      size: pageSize,
                                      paper: page.paper,
                                      locale: Localizations.maybeLocaleOf(
                                        context,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              DeskButton(
                                '上一页',
                                icon: Icons.chevron_left_rounded,
                                quiet: true,
                                onPressed: index == 0
                                    ? null
                                    : () {
                                        previewPage = index - 1;
                                        _previewRevision.value++;
                                      },
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Text(
                                  '第 ${index + 1} / ${_pages.length} 页',
                                  key: const ValueKey('layout-preview-pages'),
                                  style: ui(12, c: d.ink2),
                                ),
                              ),
                              DeskButton(
                                '下一页',
                                icon: Icons.chevron_right_rounded,
                                quiet: true,
                                onPressed: index + 1 >= _pages.length
                                    ? null
                                    : () {
                                        previewPage = index + 1;
                                        _previewRevision.value++;
                                      },
                              ),
                            ],
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

  final readerMenuController = MenuController();
  bool settingsCollapsed = false;

  /// 预览区宽度不足 760 时，设置行里的按钮只留图标。
  bool narrowPreview = false;

  /// 预览区不够宽放下完整设置行时，“实际生成预览”只留图标（LAY-102）。
  bool iconOnlyPreview = false;
  DateTime _lastWheel = DateTime(0);

  /// 阅读器设置弹出面板（LAY-096/098）：字号档位、页边距、行距、字体与按真机校准，
  /// 收起时按钮上显示当前设置，不再占用预览上方的空间。
  Widget readerMenu(ReaderMetrics metrics) {
    final d = context.desk;
    const margins = {'narrow': '窄', 'medium': '中', 'wide': '宽'};
    const spacings = {'small': '小', 'medium': '中', 'large': '大'};
    final summary =
        '字号 ${device.level} · ${margins[device.margin]}边距 · ${spacings[device.spacing]}行距 · ${device.serif ? '衬线' : '无衬线'}';
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: ui(12, c: d.ink3)),
          ),
          Flexible(child: child),
        ],
      ),
    );
    return MenuAnchor(
      controller: readerMenuController,
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        Padding(
          key: const ValueKey('layout-reader-panel'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: SizedBox(
            width: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                row(
                  '字号',
                  Row(
                    children: [
                      IconButton(
                        tooltip: '小一档',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove_rounded, size: 18),
                        onPressed: device.level <= 1
                            ? null
                            : () => chooseDevice(
                                device.copyWith(level: device.level - 1),
                              ),
                      ),
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${device.level}',
                          key: const ValueKey('layout-reader-level'),
                          textAlign: TextAlign.center,
                          style: mono(13, c: d.ink),
                        ),
                      ),
                      IconButton(
                        tooltip: '大一档',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        onPressed: device.level >= 14
                            ? null
                            : () => chooseDevice(
                                device.copyWith(level: device.level + 1),
                              ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '档位 1–14',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(11.5, c: d.ink3),
                        ),
                      ),
                    ],
                  ),
                ),
                row(
                  '页边距',
                  DeskSegmented<String>(
                    value: device.margin,
                    options: margins,
                    onChanged: (v) => chooseDevice(device.copyWith(margin: v)),
                  ),
                ),
                row(
                  '行距',
                  DeskSegmented<String>(
                    value: device.spacing,
                    options: spacings,
                    onChanged: (v) => chooseDevice(device.copyWith(spacing: v)),
                  ),
                ),
                row(
                  '字体',
                  DeskSegmented<bool>(
                    value: device.serif,
                    options: const {false: '无衬线', true: '衬线'},
                    onChanged: (v) => chooseDevice(device.copyWith(serif: v)),
                  ),
                ),
                Divider(height: 1, color: d.line),
                const SizedBox(height: 10),
                Text(
                  metrics.measured ? '当前设置与真机照片或你的校准一致。' : '只有 KPW5 的 4、8、12 档（窄边距、中行距、书内 110% / 1.2）是实测，其余按 Kindle 固件的字号表与页边距推算。',
                  style: ui(11.5, c: d.ink2, h: 1.5),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DeskButton(
                    '按真机校准…',
                    key: const ValueKey('layout-reader-calibrate'),
                    icon: Icons.straighten_rounded,
                    quiet: true,
                    onPressed: () {
                      readerMenuController.close();
                      calibrate();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      child: DeskButton(
        // 预览区较窄时只写字号，完整设置在悬停提示里，预览设置保持一行（LAY-102）。
        narrowPreview ? '字号 ${device.level} …' : summary,
        key: const ValueKey('layout-reader-settings'),
        icon: Icons.tune_rounded,
        tooltip: narrowPreview
            ? '$summary\nKindle 阅读器设置：字号、页边距、行距、字体与按真机校准'
            : 'Kindle 阅读器设置：字号、页边距、行距、字体与按真机校准',
        onPressed: () => readerMenuController.isOpen
            ? readerMenuController.close()
            : readerMenuController.open(),
      ),
    );
  }

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
                final settingsWidth = (c.maxWidth * .34).clamp(340.0, 400.0);
                final previewWidth = c.maxWidth >= 900
                    ? c.maxWidth - (settingsCollapsed ? 40 : settingsWidth)
                    : c.maxWidth;
                narrowPreview = previewWidth < 760;
                iconOnlyPreview = previewWidth < 900;
                if (c.maxWidth >= 900) {
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

/// 按真机校准：在 Kindle 上用与当前预览相同的字号、页边距、行距，数一行的字数和一页正文的行数。
class _CalibrateDialog extends StatefulWidget {
  const _CalibrateDialog({required this.device, this.initial});
  final PreviewDeviceChoice device;
  final (int, int)? initial;
  @override
  State<_CalibrateDialog> createState() => _CalibrateDialogState();
}

class _CalibrateDialogState extends State<_CalibrateDialog> {
  late final perLine = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial!.$1}',
  );
  late final perPage = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial!.$2}',
  );
  String error = '';

  @override
  void dispose() {
    perLine.dispose();
    perPage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final c = widget.device;
    const margins = {'narrow': '窄', 'medium': '中', 'wide': '宽'};
    const spacings = {'small': '小', 'medium': '中', 'large': '大'};
    Widget field(String label, TextEditingController controller, Key key) =>
        Expanded(
          child: TextField(
            key: key,
            controller: controller,
            keyboardType: TextInputType.number,
            style: mono(13, c: d.ink),
            decoration: deskInput(context).copyWith(labelText: label),
          ),
        );
    return DeskDialog(
      title: '按真机校准',
      subtitle:
          '${c.device.name} · 字号 ${c.level} · 页边距${margins[c.margin]} · 行距${spacings[c.spacing]}',
      closeTooltip: '取消校准',
      width: 520,
      actions: [
        if (widget.initial != null)
          DeskButton(
            '清除这条校准',
            quiet: true,
            onPressed: () => Navigator.pop(context, (0, 0)),
          ),
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '保存校准',
          key: const ValueKey('calibrate-save'),
          primary: true,
          onPressed: () {
            final a = int.tryParse(perLine.text.trim()) ?? 0;
            final b = int.tryParse(perPage.text.trim()) ?? 0;
            if (a < 4 || a > 80 || b < 3 || b > 80) {
              setState(() => error = '每行字数填 4–80，每页行数填 3–80。');
              return;
            }
            Navigator.pop(context, (a, b));
          },
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '在 Kindle 上打开同一本书，设成与上面相同的字号、页边距和行距；数一行满行的字数（不含段首缩进），'
            '再数一页正文共有几行（含段落之间的行）。保存后，这台机型在这组设置下按你的数字排版。',
            style: ui(12.5, c: d.ink2, h: 1.55),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              field('每行字数', perLine, const ValueKey('calibrate-line')),
              const SizedBox(width: 10),
              field('每页行数', perPage, const ValueKey('calibrate-page')),
            ],
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(error, style: ui(12, c: d.pen)),
          ],
        ],
      ),
    );
  }
}
