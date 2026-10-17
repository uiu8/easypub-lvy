// 合并 / 移动章节（CH-065–078）：分页选择目标；移动还可选目标卷的卷首/卷末或全书末尾。
// 合并与改名打包为同一批候选；预览前不写入。
import 'package:flutter/material.dart';

import '../../errors.dart';

import '../../../application/chapter_service.dart';
import '../../controls/controls.dart';
import '../../dialogs.dart';
import '../../tokens.dart';
import '../../widgets.dart';
import 'candidate_dialog.dart';

export 'candidate_dialog.dart';

class ChapterTargetDialog extends StatefulWidget {
  const ChapterTargetDialog({
    super.key,
    required this.session,
    required this.page,
    required this.node,
    required this.merge,
    this.initialTitle,
    this.onTitleChanged,
  });
  final ChapterSession session;
  final ChapterPage page;
  final ChapterNode node;
  final bool merge;
  final String? initialTitle;
  final ValueChanged<String>? onTitleChanged;
  @override
  State<ChapterTargetDialog> createState() => _ChapterTargetDialogState();
}

class _ChapterTargetDialogState extends State<ChapterTargetDialog> {
  ChapterPage? targets;
  ChapterNode? target;
  ChapterPage? volumeOptions;
  String? selectedVolume, volumeEdge;
  String selectedVolumeTitle = '';
  bool end = false, busy = false;
  String error = '';
  String titlePolicy = 'target';
  final mergedTitle = TextEditingController();

  @override
  void dispose() {
    mergedTitle.dispose();
    super.dispose();
  }

  void updateMergedTitle() {
    if (titlePolicy == 'target') mergedTitle.text = target?.title ?? '';
    if (titlePolicy == 'source') mergedTitle.text = widget.node.title;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialTitle != null) {
      titlePolicy = 'custom';
      mergedTitle.text = widget.initialTitle!;
    }
    mergedTitle.addListener(
      () => widget.onTitleChanged?.call(mergedTitle.text),
    );
    loadInitial();
  }

  Future<void> loadInitial() async {
    await load(widget.page.offset);
    if (mounted && !widget.merge && widget.node.role != 'volume') {
      await loadVolumes(0);
    }
  }

  Future<void> loadVolumes(int offset) => run(() async {
    final result = await widget.session.volumes(widget.page, offset);
    if (mounted) setState(() => volumeOptions = result);
  });

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '操作没有完成。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load(int offset) => run(() async {
    final next = selectedVolume == null
        ? await widget.session.read(offset)
        : await widget.session.volumes(
            widget.page,
            offset,
            volumeId: selectedVolume,
          );
    if (next.guard != widget.page.guard) {
      throw const FormatException('书稿已变化，请关闭窗口并刷新章节。');
    }
    if (mounted) setState(() => targets = next);
  });

  Future<void> prepare() => run(() async {
    final edit = widget.merge
        ? MergeChapter(
            widget.node.id,
            target!.id,
            title: mergedTitle.text.trim(),
          )
        : selectedVolume != null && volumeEdge != null
        ? MoveChapterIntoVolume(
            widget.node.id,
            selectedVolume!,
            atStart: volumeEdge == 'start',
          )
        : MoveChapter(widget.node.id, end ? null : target!.id);
    final preview = await widget.session.preview(widget.page, edit);
    if (!mounted) return;
    // 候选已生成；预览弹窗自管读取状态，这里不再保留进度条。
    setState(() => busy = false);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChapterCandidateDialog(
        session: widget.session,
        preview: preview,
        originalPage: widget.page,
        title: widget.merge ? '合并预览' : '移动预览',
        initialOffset: targets!.offset,
      ),
    );
    if (mounted && confirmed == true) Navigator.pop(context, true);
  });

  void chooseTarget(ChapterNode node) => setState(() {
    target = node;
    end = false;
    volumeEdge = null;
    updateMergedTitle();
  });

  String? get problem {
    if (!end && target == null && volumeEdge == null) {
      return widget.merge ? '先选择合并目标' : '先选择插入位置';
    }
    if (widget.merge && mergedTitle.text.trim().isEmpty) return '请填写合并后标题';
    return null;
  }

  Widget volumePicker(Desk d) {
    final options = volumeOptions!;
    return Row(
      children: [
        const DeskLabel('目标卷'),
        const SizedBox(width: 10),
        Expanded(
          child: DeskChoice<String>(
            key: ValueKey('volume-selector-${options.offset}-$selectedVolume'),
            initialValue: selectedVolume ?? '',
            isDense: true,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: '', child: Text('全部位置')),
              if (selectedVolume != null &&
                  !options.nodes.any((n) => n.id == selectedVolume))
                DropdownMenuItem(
                  value: selectedVolume,
                  child: Text(selectedVolumeTitle),
                ),
              for (final n in options.nodes)
                DropdownMenuItem(value: n.id, child: Text(n.title)),
            ],
            onChanged: busy
                ? null
                : (v) {
                    setState(() {
                      selectedVolume = v == '' ? null : v;
                      selectedVolumeTitle =
                          options.nodes
                              .where((n) => n.id == v)
                              .firstOrNull
                              ?.title ??
                          selectedVolumeTitle;
                      volumeEdge = null;
                      target = null;
                      end = false;
                    });
                    load(0);
                  },
          ),
        ),
        IconButton(
          tooltip: '上一页卷',
          visualDensity: VisualDensity.compact,
          onPressed: busy || options.offset == 0
              ? null
              : () => loadVolumes(options.offset - 30),
          icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
        ),
        IconButton(
          tooltip: '下一页卷',
          visualDensity: VisualDensity.compact,
          onPressed: busy || options.offset + 30 >= options.total
              ? null
              : () => loadVolumes(options.offset + 30),
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final reason = problem;
    final page = targets;
    return DeskDialog(
      title: widget.merge ? '合并章节' : '移动章节',
      subtitle: widget.merge
          ? '将“${widget.node.title}”并入目标章：本章正文接在目标正文后，下级节点一并迁移。可能改变阅读顺序，请预览后确认。'
          : '移动“${widget.node.title}”及其下级：选择插入位置；移动完整子树，不复制或删除正文。',
      closeTooltip: '关闭结构编辑',
      width: 720,
      height: widget.merge ? 680 : 640,
      busy: busy,
      footerLeft: Text(
        volumeEdge != null
            ? '插入目标卷${volumeEdge == 'start' ? '首' : '末'}'
            : end
            ? '插入全书末尾'
            : target == null
            ? '尚未选择目标'
            : '目标：${target!.title}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ui(
          12,
          c: target == null && !end && volumeEdge == null ? d.ink3 : d.ink,
        ),
      ),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        DeskButton(
          '预览并确认',
          primary: true,
          disabledReason: reason,
          onPressed: busy || reason != null ? null : prepare,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.merge &&
              volumeOptions != null &&
              volumeOptions!.total > 0) ...[
            volumePicker(d),
            const SizedBox(height: 8),
          ],
          if (!widget.merge && selectedVolume != null) ...[
            Row(
              children: [
                DeskButton(
                  '卷首',
                  icon: Icons.vertical_align_top_rounded,
                  primary: volumeEdge == 'start',
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          volumeEdge = 'start';
                          target = null;
                          end = false;
                        }),
                ),
                const SizedBox(width: 8),
                DeskButton(
                  '卷末',
                  icon: Icons.vertical_align_bottom_rounded,
                  primary: volumeEdge == 'end',
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          volumeEdge = 'end';
                          target = null;
                          end = false;
                        }),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          DeskLabel(widget.merge ? '选择合并目标' : '选择目标章节，移动到其前方'),
          if (error.isNotEmpty) ...[
            DeskNote(error, title: '未应用', tone: Tone.pen),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: DeskListBox(
              paper: false,
              child: ListView.builder(
                padding: const EdgeInsets.all(4),
                itemCount: page?.nodes.length ?? 0,
                itemBuilder: (_, i) {
                  final node = page!.nodes[i];
                  final self = node.id == widget.node.id;
                  return Padding(
                    key: ValueKey('target-${node.id}'),
                    padding: EdgeInsets.only(
                      left: node.depth.clamp(0, 4) * 10.0,
                    ),
                    child: DeskChoiceRow(
                      title: node.title,
                      detail: widget.merge ? null : '第 ${node.line} 行',
                      disabledNote: self ? '当前章节' : null,
                      selected: !end && target?.id == node.id,
                      onTap: busy || self ? null : () => chooseTarget(node),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 4),
          DeskPager(
            previous: '上一页目标',
            next: '下一页目标',
            iconOnly: true,
            info: page == null
                ? ''
                : '第 ${page.offset + 1}–${page.offset + page.nodes.length} 项 / ${page.total}',
            onPrevious: busy || page == null || page.offset == 0
                ? null
                : () => load(page.offset - 30),
            onNext: busy || page == null || page.offset + 30 >= page.total
                ? null
                : () => load(page.offset + 30),
          ),
          if (!widget.merge && selectedVolume == null) ...[
            Container(
              height: 1,
              color: d.line,
              margin: const EdgeInsets.symmetric(vertical: 6),
            ),
            DeskChoiceRow(
              key: const ValueKey('target-end'),
              title: '全书末尾',
              selected: end,
              onTap: busy
                  ? null
                  : () => setState(() {
                      end = true;
                      target = null;
                    }),
            ),
          ],
          if (widget.merge) ...[
            const SizedBox(height: 12),
            const DeskLabel('保留标题方式'),
            KeyedSubtree(
              key: const ValueKey('merge-title-policy'),
              child: DeskSegmented<String>(
                value: titlePolicy,
                options: const {
                  'target': '保留目标章标题',
                  'source': '保留当前章标题',
                  'custom': '自定义标题',
                },
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        titlePolicy = v;
                        updateMergedTitle();
                      }),
              ),
            ),
            const SizedBox(height: 10),
            const DeskLabel('合并后标题'),
            TextField(
              key: const ValueKey('merge-title'),
              controller: mergedTitle,
              readOnly: titlePolicy != 'custom',
              enabled: !busy,
              style: ui(13.5, c: titlePolicy == 'custom' ? d.ink : d.ink2),
              decoration:
                  deskInput(
                    context,
                    hint: titlePolicy == 'custom' ? '填写合并后的章节标题' : '先选择合并目标',
                  ).copyWith(
                    fillColor: titlePolicy == 'custom' ? d.surface : d.sunken,
                  ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
    );
  }
}
