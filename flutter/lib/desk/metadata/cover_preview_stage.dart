// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'package:flutter/material.dart';

import '../controls/controls.dart';
import '../tokens.dart';

/// Viewing the original aspect ratio never changes the stored crop or fit.
class CoverPreviewStage extends StatefulWidget {
  const CoverPreviewStage({
    super.key,
    required this.fit,
    required this.onFit,
    required this.originalSize,
    required this.builder,
    this.onReset,
    this.busy = false,
    this.message,
    this.originalAspectRatio,
    this.onPan,
    this.textOnly = false,
  });
  final bool textOnly;
  final String fit;
  final ValueChanged<String> onFit;
  final Size originalSize;
  final Widget Function(bool original) builder;
  final VoidCallback? onReset;
  final bool busy;
  final String? message;
  final double? originalAspectRatio;
  final void Function(Offset delta, Size viewport)? onPan;
  @override
  State<CoverPreviewStage> createState() => _CoverPreviewStageState();
}

class _CoverPreviewStageState extends State<CoverPreviewStage> {
  bool original = false;
  Offset? lastPointer;
  @override
  Widget build(BuildContext context) {
    final ratio = original
        ? widget.originalAspectRatio ?? widget.originalSize.aspectRatio
        : 3 / 4;
    // A bounded viewport keeps extreme panoramic/tall inputs inside the panel.
    final width = ratio >= 3 / 4 ? 480.0 : 640 * ratio;
    final height = width / ratio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.textOnly)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in ['contain', 'cover', 'fill'])
                DeskButton(
                  mode == 'contain'
                      ? '完整显示'
                      : mode == 'cover'
                      ? '裁切填充'
                      : '拉伸填满',
                  quiet: true,
                  icon: !original && widget.fit == mode ? Icons.check : null,
                  onPressed: widget.busy
                      ? null
                      : () {
                          setState(() => original = false);
                          widget.onFit(mode);
                        },
                ),
              DeskButton(
                '原图比例',
                quiet: true,
                icon: original ? Icons.check : null,
                onPressed: widget.busy
                    ? null
                    : () => setState(() => original = !original),
              ),
              DeskButton(
                '重置裁切',
                quiet: true,
                icon: Icons.restart_alt,
                onPressed: widget.busy ? null : widget.onReset,
              ),
            ],
          ),
        if (!widget.textOnly) const SizedBox(height: 14),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: context.desk.canvas,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: widget.busy
                ? const CircularProgressIndicator()
                : widget.message != null
                ? DeskText(widget.message!)
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: MouseRegion(
                        cursor: !original && widget.onPan != null
                            ? SystemMouseCursors.move
                            : SystemMouseCursors.basic,
                        child: GestureDetector(
                          key: const ValueKey('cover-pan-surface'),
                          behavior: HitTestBehavior.opaque,
                          onPanStart: original || widget.onPan == null
                              ? null
                              : (details) =>
                                    lastPointer = details.localPosition,
                          onPanUpdate: original || widget.onPan == null
                              ? null
                              : (details) {
                                  final before = lastPointer;
                                  lastPointer = details.localPosition;
                                  if (before != null) {
                                    widget.onPan!(
                                      details.localPosition - before,
                                      Size(width, height),
                                    );
                                  }
                                },
                          onPanEnd: (_) => lastPointer = null,
                          onPanCancel: () => lastPointer = null,
                          child: widget.builder(original),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DeskText(
                widget.textOnly
                    ? '成品比例预览 · 文字完整排版'
                    : original
                    ? '原图比例：查看完整原图，已设裁切保持不变。'
                    : widget.onPan != null
                    ? '拖动图片调整位置；裁切仅影响成品，原图保持不变。'
                    : '封面适配与裁切仅影响成品；原图保持不变。',
                size: 12,
                color: context.desk.ink2,
              ),
            ),
            const SizedBox(width: 12),
            DeskText(
              '${widget.originalSize.width.round()} × ${widget.originalSize.height.round()}',
              size: 12,
              color: context.desk.ink2,
            ),
          ],
        ),
      ],
    );
  }
}
