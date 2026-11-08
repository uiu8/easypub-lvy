// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'package:flutter/material.dart';

import '../tokens.dart';

import '../../application/book_information_service.dart';
import '../controls/controls.dart';
import 'cover_preview.dart';
import 'cover_preview_stage.dart';
import 'cover_pan.dart';

class CoverAdjustment {
  const CoverAdjustment(this.crop, this.fit);
  final Map<String, dynamic>? crop;
  final String fit;
}

class CoverAdjustmentPage extends StatefulWidget {
  const CoverAdjustmentPage({
    super.key,
    required this.session,
    required this.path,
    required this.initialCrop,
    required this.initialFit,
    required this.onReturn,
    this.modeSwitch,
    this.onBrowse,
    this.onDraft,
  });
  final BookInformationSession session;
  final ValueChanged<Map<String, dynamic>>? onDraft;
  final String? path;
  final String initialFit;
  final Widget? modeSwitch;
  final VoidCallback? onBrowse;
  final Map<String, dynamic>? initialCrop;
  final ValueChanged<CoverAdjustment?> onReturn;
  @override
  State<CoverAdjustmentPage> createState() => _CoverAdjustmentPageState();
}

class _CoverAdjustmentPageState extends State<CoverAdjustmentPage> {
  late RangeValues horizontal = RangeValues(
    (widget.initialCrop?['x'] as num? ?? 0).toDouble(),
    ((widget.initialCrop?['x'] as num? ?? 0) +
            (widget.initialCrop?['width'] as num? ?? 1))
        .toDouble(),
  );
  late RangeValues vertical = RangeValues(
    (widget.initialCrop?['y'] as num? ?? 0).toDouble(),
    ((widget.initialCrop?['y'] as num? ?? 0) +
            (widget.initialCrop?['height'] as num? ?? 1))
        .toDouble(),
  );
  late String fit = widget.initialFit;
  CoverImageEvidence? evidence;
  double? originalAspectRatio;
  bool busy = true;
  String error = '';
  Map<String, dynamic>? get crop =>
      horizontal.start == 0 &&
          horizontal.end == 1 &&
          vertical.start == 0 &&
          vertical.end == 1
      ? null
      : {
          'x': horizontal.start,
          'y': vertical.start,
          'width': horizontal.end - horizontal.start,
          'height': vertical.end - vertical.start,
        };
  @override
  void initState() {
    super.initState();
    inspect();
  }

  Future<void> inspect() async {
    if (widget.path == null) {
      setState(() => busy = false);
      return;
    }
    try {
      final result = await widget.session.inspectImage(widget.path!);
      if (mounted) setState(() => evidence = result);
    } catch (_) {
      if (mounted) setState(() => error = '图片或书稿不可用，请返回重新选择。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void remember() => widget.onDraft?.call({'crop': crop, 'fit': fit});

  Future<void> adopt() async {
    if (evidence == null) return;
    setState(() => busy = true);
    try {
      final result = await widget.session.inspectImage(widget.path!);
      if (!mounted) return;
      if (result.sha256 != evidence!.sha256) {
        setState(() {
          error = '原图已改变，请返回重新选择。';
          evidence = null;
        });
        return;
      }
      widget.onReturn(CoverAdjustment(crop, fit));
    } catch (_) {
      if (mounted) setState(() => error = '无法采用，请重新选择图片并检查书稿状态。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// 编辑台面板：浮起卡片 + 标题行（V5 换样式，布局沿用）。
  Widget panel(String title, Widget child) {
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
            child: Text(title, style: ui(14, w: 650, c: d.ink)),
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
                        widget.modeSwitch ?? const DeskText('使用图片', bold: true),
                  ),
                  if (widget.onBrowse != null) ...[
                    const SizedBox(height: 14),
                    DeskButton(
                      '浏览封面图片…',
                      icon: Icons.folder_open,
                      onPressed: busy ? null : widget.onBrowse,
                    ),
                  ],
                  const SizedBox(height: 18),
                  DeskText('左右边界', size: 12, color: context.desk.ink2),
                  RangeSlider(
                    key: const ValueKey('cover-horizontal'),
                    values: horizontal,
                    divisions: 100,
                    onChanged: busy
                        ? null
                        : (v) {
                            if (v.end - v.start >= .01) {
                              setState(() => horizontal = v);
                              remember();
                            }
                          },
                  ),
                  DeskText(
                    '${(horizontal.start * 100).round()}% — ${(horizontal.end * 100).round()}%',
                    size: 12,
                  ),
                  const SizedBox(height: 18),
                  DeskText('上下边界', size: 12, color: context.desk.ink2),
                  RangeSlider(
                    key: const ValueKey('cover-vertical'),
                    values: vertical,
                    divisions: 100,
                    onChanged: busy
                        ? null
                        : (v) {
                            if (v.end - v.start >= .01) {
                              setState(() => vertical = v);
                              remember();
                            }
                          },
                  ),
                  DeskText(
                    '${(vertical.start * 100).round()}% — ${(vertical.end * 100).round()}%',
                    size: 12,
                  ),
                  const SizedBox(height: 18),
                  const Divider(),
                  const SizedBox(height: 14),
                  if (evidence != null)
                    DeskText(
                      '原图尺寸  ${evidence!.width} × ${evidence!.height} px',
                    ),
                  const SizedBox(height: 12),
                  DeskText(
                    '调整保留区域。采用后返回待保存表单，原始图片不变。',
                    size: 12,
                    color: context.desk.ink2,
                  ),
                  if (error.isNotEmpty) DeskText(error),
                ],
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              DeskButton(
                '采用并返回',
                primary: true,
                icon: Icons.check,
                onPressed: busy || evidence == null ? null : adopt,
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
        onPan: evidence == null || busy || (crop == null && fit != 'cover')
            ? null
            : (delta, viewport) {
                final ratio =
                    originalAspectRatio ?? evidence!.width / evidence!.height;
                final region = panCoverRegion(
                  Rect.fromLTRB(
                    horizontal.start,
                    vertical.start,
                    horizontal.end,
                    vertical.end,
                  ),
                  Size(ratio, 1),
                  viewport,
                  fit == 'cover'
                      ? BoxFit.cover
                      : fit == 'fill'
                      ? BoxFit.fill
                      : BoxFit.contain,
                  delta,
                );
                setState(() {
                  horizontal = RangeValues(
                    region.left,
                    region.right.clamp(0, 1),
                  );
                  vertical = RangeValues(region.top, region.bottom.clamp(0, 1));
                });
                remember();
              },
        originalAspectRatio: originalAspectRatio,
        fit: fit,
        onFit: (value) {
          setState(() => fit = value);
          remember();
        },
        originalSize: evidence == null
            ? const Size(1200, 1600)
            : Size(evidence!.width.toDouble(), evidence!.height.toDouble()),
        busy: busy,
        message: evidence == null ? (error.isEmpty ? '请选择封面图片' : error) : null,
        onReset: evidence == null || crop == null
            ? null
            : () => setState(() {
                horizontal = const RangeValues(0, 1);
                vertical = const RangeValues(0, 1);
                remember();
              }),
        builder: (original) => CoverPreview(
          onAspectRatio: (value) {
            if (originalAspectRatio != value) {
              setState(() => originalAspectRatio = value);
            }
          },
          path: widget.path!,
          revision: evidence!.sha256,
          crop: original ? null : crop,
          fit: original || fit == 'contain'
              ? BoxFit.contain
              : fit == 'fill'
              ? BoxFit.fill
              : BoxFit.cover,
        ),
      ),
    ),
  );
}
