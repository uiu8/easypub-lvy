// 迁入 desk（V5a）：逻辑与布局沿用 V5 前的同名文件，只换面板与切换样式；见 docs/evidence/v5-meta-layout-resources-20261011.md。
import 'package:flutter/material.dart';

import '../../application/book_information_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import 'cover_preview.dart';
import '../tokens.dart';

class CoverImageChoice {
  const CoverImageChoice(this.evidence, this.fit, {this.adjust = false});
  final bool adjust;
  final CoverImageEvidence evidence;
  final String fit;
}

class CoverImageDialog extends StatefulWidget {
  const CoverImageDialog({
    super.key,
    required this.session,
    required this.pickImage,
    required this.initialFit,
    this.autosave,
    this.draftKey,
    this.initialPath,
  });

  /// 拖入的图片：打开时直接核验它（优先于上次未确认的选择）。
  final String? initialPath;
  final BookInformationSession session;
  final WorkspaceAutosaveService? autosave;
  final String? draftKey;
  final Future<String?> Function() pickImage;
  final String initialFit;
  @override
  State<CoverImageDialog> createState() => _CoverImageDialogState();
}

class _CoverImageDialogState extends State<CoverImageDialog> {
  CoverImageEvidence? evidence;
  late String fit = widget.initialFit;
  String error = '';
  bool busy = false;
  int generation = 0;
  void remember() {
    if (widget.draftKey != null && evidence != null) {
      widget.autosave?.writeDraft(widget.draftKey!, {
        'path': evidence!.path,
        'fit': fit,
      });
    }
  }

  void discard() {
    if (widget.draftKey != null) {
      widget.autosave?.writeDraft(widget.draftKey!, null);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialPath case final path?) {
      busy = true;
      widget.session
          .inspectImage(path)
          .then((value) {
            if (mounted) setState(() => evidence = value);
            remember();
          })
          .catchError((Object _) {
            if (mounted) {
              setState(
                () => error = '拖入的图片不能用作封面，请换一张 PNG、JPEG、WebP、GIF 或 BMP。',
              );
            }
          })
          .whenComplete(() {
            if (mounted) setState(() => busy = false);
          });
      return;
    }
    final saved = widget.draftKey == null
        ? null
        : widget.autosave?.readDraft(widget.draftKey!);
    if (saved != null) {
      fit = saved['fit'] as String? ?? fit;
      widget.session
          .inspectImage(saved['path'] as String)
          .then((value) {
            if (mounted) setState(() => evidence = value);
          })
          .catchError((Object _) {
            if (mounted) setState(() => error = '上次选择的图片不可用，请重新选择。');
          });
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> browse() async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final path = await widget.pickImage();
      if (!mounted || ticket != generation || path == null) return;
      setState(() => evidence = null);
      final next = await widget.session.inspectImage(path);
      if (mounted && ticket == generation) {
        setState(() => evidence = next);
        remember();
      }
    } catch (_) {
      if (mounted && ticket == generation) {
        setState(() {
          evidence = null;
          error = '图片检查失败，请选择有效的 PNG、JPEG、WebP、GIF 或 BMP；检查书稿是否已改变。';
        });
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> adopt({bool adjust = false}) async {
    final selected = evidence;
    if (selected == null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final checked = await widget.session.inspectImage(selected.path);
      if (!mounted) return;
      if (checked.sha256 != selected.sha256) {
        setState(() {
          evidence = checked;
          error = '图片文件已改变，请查看新预览后再次确认。';
        });
      } else {
        discard();
        Navigator.pop(context, CoverImageChoice(checked, fit, adjust: adjust));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          evidence = null;
          error = '图片或书稿已不可用，请重新选择。';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DeskDialog(
    closeTooltip: '关闭',
    title: '选择封面图片',
    width: 680,
    actions: [
      DeskButton(
        '取消',
        quiet: true,
        onPressed: () {
          discard();
          Navigator.pop(context);
        },
      ),
      DeskButton(
        '进入裁切调整',
        onPressed: busy || evidence == null ? null : () => adopt(adjust: true),
      ),
      DeskButton(
        '使用此图片',
        primary: true,
        onPressed: busy || evidence == null ? null : adopt,
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DeskNote(
          '支持 PNG、JPEG、WebP、GIF、BMP；转换时自动转成 Kindle 可用的 JPEG 或 PNG，原图不变。',
          title: '从 Windows 文件选择器浏览图片',
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DeskText('已选择图片', size: 12, color: context.desk.ink2),
                  const SizedBox(height: 6),
                  SelectableText(evidence?.path ?? '尚未选择图片', maxLines: 2),
                ],
              ),
            ),
            const SizedBox(width: 12),
            DeskButton(
              '浏览图片',
              icon: Icons.folder_open,
              onPressed: busy ? null : browse,
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (busy) const LinearProgressIndicator(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 150,
              height: 200,
              color: context.desk.canvas,
              child: evidence == null
                  ? Center(
                      child: Icon(
                        Icons.image_outlined,
                        color: context.desk.ink2,
                      ),
                    )
                  : CoverPreview(
                      key: const ValueKey('selected-cover-preview'),
                      path: evidence!.path,
                      revision: evidence!.sha256,
                      decodeWidth: 450,
                      fit: fit == 'cover'
                          ? BoxFit.cover
                          : fit == 'fill'
                          ? BoxFit.fill
                          : BoxFit.contain,
                    ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DeskText(
                    evidence?.path.replaceAll('\\', '/').split('/').last ??
                        '等待选择图片',
                    size: 18,
                    bold: true,
                  ),
                  const SizedBox(height: 10),
                  if (evidence != null) ...[
                    DeskText('图片检查通过', color: context.desk.accent),
                    const SizedBox(height: 12),
                    DeskText(
                      '${evidence!.width} × ${evidence!.height} px · ${evidence!.format.toUpperCase()} · ${(evidence!.bytes / 1024).toStringAsFixed(1)} KB',
                      color: context.desk.ink2,
                    ),
                  ],
                  const SizedBox(height: 18),
                  DeskText('适配方式', size: 12, color: context.desk.ink2),
                  const SizedBox(height: 6),
                  DeskChoice<String>(
                    initialValue: fit,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: 'contain',
                        child: Text('完整显示 · 保持比例'),
                      ),
                      DropdownMenuItem(
                        value: 'cover',
                        child: Text('填满封面 · 保持比例'),
                      ),
                      DropdownMenuItem(value: 'fill', child: Text('拉伸填满')),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            setState(() => fit = value!);
                            remember();
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        DeskText(
          '选择后应用到当前书；原始图片保留。未应用的选择也会暂存。',
          size: 12,
          color: context.desk.ink2,
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DeskText(error),
          ),
      ],
    ),
  );
}
