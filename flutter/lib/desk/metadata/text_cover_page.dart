// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../tokens.dart';

import '../../application/book_information_service.dart';
import '../controls/controls.dart';
import 'text_cover.dart';
import 'cover_preview_stage.dart';

/// 文字封面可选底色。属于书稿数据（写入封面设计并由 Rust production.rs 校验），
/// 与界面强调色无关，界面换主题时不得改动。
const textCoverColors = [
  Color(0xff23664F),
  Color(0xff82705A),
  Color(0xff5E6D7D),
  Color(0xff694C52),
];

class GeneratedCover {
  GeneratedCover(this.image, Map<String, dynamic> design, this.fit)
    : design = Map.unmodifiable(design);
  final CoverImageEvidence image;
  final Map<String, dynamic> design;
  final String fit;
}

class TextCoverPage extends StatefulWidget {
  const TextCoverPage({
    super.key,
    required this.session,
    required this.title,
    required this.author,
    required this.series,
    required this.onReturn,
    this.initialDesign,
    this.onDraft,
    this.modeSwitch,
    this.initialFit = 'contain',
  });
  final BookInformationSession session;
  final ValueChanged<Map<String, dynamic>>? onDraft;
  final String title, author, series;
  final ValueChanged<GeneratedCover?> onReturn;
  final Map<String, dynamic>? initialDesign;
  final Widget? modeSwitch;
  final String initialFit;
  @override
  State<TextCoverPage> createState() => _TextCoverPageState();
}

class _TextCoverPageState extends State<TextCoverPage> {
  late final title = TextEditingController(
    text: widget.initialDesign?['title'] as String? ?? widget.title,
  )..addListener(refresh);
  late final author = TextEditingController(
    text: widget.initialDesign?['author'] as String? ?? widget.author,
  )..addListener(refresh);
  late final series = TextEditingController(
    text: widget.initialDesign?['series'] as String? ?? widget.series,
  )..addListener(refresh);
  late Color color = Color(
    widget.initialDesign?['color'] as int? ?? textCoverColors.first.toARGB32(),
  );
  bool busy = false;
  // 样式包封面背景（V74b，LAY-130）：书用了带背景的样式包时可选。
  late final String? backgroundPath = widget.session.styleCoverBackground;
  late bool useBackground =
      backgroundPath != null &&
      widget.initialDesign?['style'] == 'pack-background-v1';
  ui.Image? backgroundImage;
  late String fit = widget.initialFit;
  String error = '';
  final _previewRevision = ValueNotifier<int>(0);
  (String, String, String)? _previewText;
  void remember() => widget.onDraft?.call({
    'design': {
      'title': title.text,
      'author': author.text,
      'series': series.text,
      'color': color.toARGB32(),
      'style': style,
    },
    'fit': fit,
  });
  void refresh() {
    final next = (title.text, author.text, series.text);
    if (next == _previewText) return;
    _previewText = next;
    if (mounted) _previewRevision.value++;
    remember();
  }

  String get style => useBackground && backgroundImage != null
      ? 'pack-background-v1'
      : 'river-classic-v1';

  TextCoverPainter get painter => TextCoverPainter(
    title.text,
    author.text,
    series.text,
    color,
    background: useBackground ? backgroundImage : null,
  );

  @override
  void initState() {
    super.initState();
    loadBackground();
  }

  /// 读入样式包封面背景；读不了时只能用经典模板。
  Future<void> loadBackground() async {
    final path = backgroundPath;
    if (path == null) return;
    try {
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
      );
      final image = (await codec.getNextFrame()).image;
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => backgroundImage = image);
      _previewRevision.value++;
    } catch (_) {
      if (mounted) setState(() => useBackground = false);
    }
  }

  @override
  void dispose() {
    backgroundImage?.dispose();
    title.dispose();
    author.dispose();
    series.dispose();
    _previewRevision.dispose();
    super.dispose();
  }

  Future<void> adopt() async {
    final validation = painter.validationMessage;
    if (validation != null) {
      setState(() => error = validation);
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final image = await painter.render();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw const FormatException('封面编码失败。');
        final result = await widget.session.storeGeneratedCover(
          bytes.buffer.asUint8List(),
        );
        if (mounted) {
          widget.onReturn(
            GeneratedCover(result, {
              'title': title.text,
              'author': author.text,
              'series': series.text,
              'color': color.toARGB32(),
              'style': style,

              'image_sha256': result.sha256,
            }, fit),
          );
        }
      } finally {
        image.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => error = '封面生成失败，请检查书稿状态或资源目录。输入已保留。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(String name, TextEditingController controller) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DeskText(name, size: 12, color: context.desk.ink2),
        const SizedBox(height: 6),
        TextField(
          key: ValueKey('cover-$name'),
          controller: controller,
          minLines: 1,
          maxLines: name == '封面标题' ? 3 : 2,
          enabled: !busy,
        ),
      ],
    ),
  );

  /// 编辑台面板：浮起卡片 + 标题行（V5 换样式，布局沿用）。
  Widget panel(String label, Widget child) {
    final d = context.desk;
    return Container(
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: d.ink,
              ),
            ),
          ),
          Expanded(
            child: Padding(padding: const EdgeInsets.all(18), child: child),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DeskSplitView(
    leadingLabel: '封面设置',
    trailingLabel: '封面预览',
    leadingWidth: 322,
    leading: panel(
      '封面调整',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: DeskButton(
              '返回书籍信息',
              quiet: true,
              icon: Icons.arrow_back,
              onPressed: busy ? null : () => widget.onReturn(null),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: DeskScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  IgnorePointer(
                    ignoring: busy,
                    child:
                        widget.modeSwitch ?? const DeskText('文字封面', bold: true),
                  ),
                  const SizedBox(height: 18),
                  field('封面标题', title),
                  field('作者署名', author),
                  field('系列文字', series),
                  for (final (value, label) in [
                    (false, '河岸 · 经典'),
                    if (backgroundImage != null) (true, '样式包背景'),
                  ])
                    InkWell(
                      key: ValueKey(
                        'cover-template-${value ? 'pack' : 'river'}',
                      ),
                      onTap: busy
                          ? null
                          : () {
                              setState(() => useBackground = value);
                              _previewRevision.value++;
                              remember();
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Icon(
                              useBackground == value
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 18,
                              color: useBackground == value
                                  ? context.desk.accent
                                  : context.desk.ink3,
                            ),
                            const SizedBox(width: 6),
                            Expanded(child: DeskText(label, size: 13)),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 14),
                  DeskText('配色', size: 12, color: context.desk.ink2),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final choice in textCoverColors)
                        Semantics(
                          label: '封面配色 ${choice.toARGB32().toRadixString(16)}',
                          selected: color == choice,
                          button: true,
                          child: InkWell(
                            onTap: busy
                                ? null
                                : () {
                                    setState(() => color = choice);
                                    remember();
                                  },
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: choice,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: context.desk.line),
                              ),
                              child: color == choice
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 18,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Divider(),
                  const SizedBox(height: 14),
                  const DeskText('成品尺寸  1200 × 1600'),
                  const SizedBox(height: 8),
                  const DeskText('输出  PNG'),
                  const SizedBox(height: 14),
                  DeskText(
                    '封面文字独立于书名，长文字自动换行和缩字。',
                    size: 12,
                    color: context.desk.ink2,
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: _previewRevision,
                    builder: (_, _, _) {
                      final message = painter.validationMessage;
                      return message == null
                          ? const SizedBox.shrink()
                          : DeskText(message, color: context.desk.pen);
                    },
                  ),
                ],
              ),
            ),
          ),
          if (error.isNotEmpty) DeskText(error, color: context.desk.pen),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              DeskButton(
                '采用并返回',
                primary: true,
                icon: Icons.check,
                onPressed: busy ? null : adopt,
              ),
              DeskButton(
                '取消',
                quiet: true,
                onPressed: busy ? null : () => widget.onReturn(null),
              ),
            ],
          ),
        ],
      ),
    ),
    trailing: panel(
      '书籍信息 / 封面预览',
      CoverPreviewStage(
        textOnly: true,
        fit: fit,
        onFit: (value) {
          setState(() => fit = value);
          remember();
        },
        originalSize: const Size(1200, 1600),
        busy: busy,
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: _previewRevision,
          builder: (_, _, _) =>
              CustomPaint(painter: painter, child: const SizedBox.expand()),
        ),
      ),
    ),
  );
}
