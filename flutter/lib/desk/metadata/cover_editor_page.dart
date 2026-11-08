// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'package:flutter/material.dart';

import '../tokens.dart';

import '../../application/book_information_service.dart';
import '../../application/workspace_autosave_service.dart';
import 'cover_adjustment_page.dart';
import 'cover_image_dialog.dart';
import 'text_cover_page.dart';

class CoverEditorResult {
  const CoverEditorResult(this.path, this.fit, this.crop, this.design);
  final String path, fit;
  final Map<String, dynamic>? crop, design;
}

/// Both modes own their drafts until the active mode explicitly adopts one.
class CoverEditorPage extends StatefulWidget {
  const CoverEditorPage({
    super.key,
    required this.session,
    required this.title,
    required this.author,
    required this.series,
    required this.path,
    required this.fit,
    required this.crop,
    required this.design,
    required this.startWithText,
    required this.pickImage,
    required this.onReturn,
    this.autosave,
    this.draftKey,
  });
  final BookInformationSession session;
  final WorkspaceAutosaveService? autosave;
  final String? draftKey;
  final String title, author, series, fit;
  final String? path;
  final Map<String, dynamic>? crop, design;
  final bool startWithText;
  final Future<String?> Function() pickImage;
  final ValueChanged<CoverEditorResult?> onReturn;
  @override
  State<CoverEditorPage> createState() => _CoverEditorPageState();
}

class _CoverEditorPageState extends State<CoverEditorPage> {
  late final restored = widget.draftKey == null
      ? null
      : widget.autosave?.readDraft(widget.draftKey!);
  late Map<String, dynamic>? textDraft = (restored?['text'] as Map?)
      ?.cast<String, dynamic>();
  late bool textMode = restored?['textMode'] as bool? ?? widget.startWithText;
  late String? path = restored?['path'] as String? ?? widget.path;
  late String fit = restored?['fit'] as String? ?? widget.fit;
  late Map<String, dynamic>? crop = restored == null
      ? widget.crop
      : (restored!['crop'] as Map?)?.cast<String, dynamic>();
  late Map<String, dynamic>? design = widget.design;
  int imageVersion = 0;
  void remember() {
    if (widget.draftKey == null) return;
    widget.autosave?.writeDraft(widget.draftKey!, {
      'textMode': textMode,
      'path': path,
      'fit': fit,
      'crop': crop,
      'text': textDraft,
    });
  }

  void finish(CoverEditorResult? value) {
    if (widget.draftKey != null) {
      widget.autosave?.writeDraft(widget.draftKey!, null);
    }
    widget.onReturn(value);
  }

  /// 文字封面 / 使用图片：分段样式；每段保留 key cover-mode-true/false 以便定位。
  Widget modes() {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: d.sunken,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          for (final mode in [true, false])
            Expanded(
              child: InkWell(
                key: ValueKey('cover-mode-$mode'),
                borderRadius: BorderRadius.circular(7),
                onTap: () {
                  setState(() => textMode = mode);
                  remember();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: textMode == mode
                      ? BoxDecoration(
                          color: d.surface,
                          borderRadius: BorderRadius.circular(7),
                          boxShadow: d.shadow1,
                        )
                      : null,
                  alignment: Alignment.center,
                  child: Text(
                    mode ? '文字封面' : '使用图片',
                    style: ui(
                      12.5,
                      w: textMode == mode ? 620 : 480,
                      c: textMode == mode ? d.ink : d.ink2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> browse() async {
    final value = await showDialog<CoverImageChoice>(
      context: context,
      builder: (_) => CoverImageDialog(
        session: widget.session,
        pickImage: widget.pickImage,
        initialFit: fit,
        autosave: widget.autosave,
        draftKey: widget.draftKey == null ? null : '${widget.draftKey}:image',
      ),
    );
    if (!mounted || value == null) return;
    setState(() {
      path = value.evidence.path;
      fit = value.fit;
      crop = null;
      design = null;
      imageVersion++;
    });
    remember();
  }

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: textMode ? 0 : 1,
    sizing: StackFit.expand,
    children: [
      TickerMode(
        enabled: textMode,
        child: TextCoverPage(
          session: widget.session,
          title: widget.title,
          author: widget.author,
          series: widget.series,
          initialDesign:
              (textDraft?['design'] as Map?)?.cast<String, dynamic>() ??
              widget.design,
          initialFit: textDraft?['fit'] as String? ?? widget.fit,
          onDraft: (value) {
            textDraft = value;
            remember();
          },
          modeSwitch: modes(),
          onReturn: (value) => finish(
            value == null
                ? null
                : CoverEditorResult(
                    value.image.path,
                    value.fit,
                    null,
                    value.design,
                  ),
          ),
        ),
      ),
      TickerMode(
        enabled: !textMode,
        child: CoverAdjustmentPage(
          key: ValueKey(imageVersion),
          session: widget.session,
          path: path,
          initialCrop: crop,
          initialFit: fit,
          onDraft: (value) {
            crop = (value['crop'] as Map?)?.cast<String, dynamic>();
            fit = value['fit'] as String;
            remember();
          },
          modeSwitch: modes(),
          onBrowse: browse,
          onReturn: (value) => finish(
            value == null
                ? null
                : CoverEditorResult(path!, value.fit, value.crop, design),
          ),
        ),
      ),
    ],
  );
}
