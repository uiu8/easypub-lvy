// 迁入 desk（resources，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import '../../application/resource_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';

class ResourcePositionChoice {
  const ResourcePositionChoice(this.sourceLine, this.chapter, this.text);
  final int sourceLine;
  final String chapter, text;
}

class ResourcePositionDialog extends StatefulWidget {
  const ResourcePositionDialog({super.key, required this.session});
  final ResourcePlacementSession session;
  @override
  State<ResourcePositionDialog> createState() => _ResourcePositionDialogState();
}

class _ResourcePositionDialogState extends State<ResourcePositionDialog> {
  List<ChapterNode> chapters = [];
  ChapterNode? chapter;
  ResourceParagraphPage? page;
  ResourceParagraph? selected;
  String query = '', error = '';
  final expanded = <String>{};
  bool busy = true;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    loadChapters();
  }

  Future<void> loadChapters() async {
    try {
      final result = await widget.session.placementChapters();
      if (!mounted) return;
      setState(() => chapters = result);
      if (result.isEmpty) {
        setState(() => busy = false);
        return;
      }
      final first = result.firstWhere(
        (n) => n.role == 'chapter',
        orElse: () => result.first,
      );
      expandFor(first);
      await load(first, 0);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> load(ChapterNode node, int offset) async {
    final ticket = ++generation;
    setState(() {
      chapter = node;
      selected = null;
      page = null;
      busy = true;
      error = '';
    });
    try {
      final result = await widget.session.placementParagraphs(node.id, offset);
      if (mounted && ticket == generation) setState(() => page = result);
    } catch (e) {
      if (mounted && ticket == generation) setState(() => error = '$e');
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  /// 卷与其下章节（RES-046）：卷可折叠，卷前的章节直接列出。
  List<(ChapterNode, bool)> visibleRows() {
    final q = query.trim();
    if (q.isNotEmpty) {
      return [
        for (final n in chapters)
          if (n.role != 'volume' && n.title.contains(q)) (n, false),
      ];
    }
    final rows = <(ChapterNode, bool)>[];
    ChapterNode? volume;
    for (final n in chapters) {
      if (n.role == 'volume') {
        volume = n;
        rows.add((n, true));
      } else if (volume == null ||
          n.depth == 0 ||
          expanded.contains(volume.id)) {
        rows.add((n, false));
      }
    }
    return rows;
  }

  /// 默认展开当前章节所在的卷。
  void expandFor(ChapterNode node) {
    ChapterNode? volume;
    for (final n in chapters) {
      if (n.role == 'volume') volume = n;
      if (n.id == node.id) break;
    }
    if (volume != null) expanded.add(volume.id);
  }

  Widget chapterRow(ChapterNode node, bool isVolume) {
    final d = context.desk;
    final open = expanded.contains(node.id);
    final on = chapter?.id == node.id;
    final count = isVolume
        ? chapters
              .skipWhile((n) => n.id != node.id)
              .skip(1)
              .takeWhile((n) => n.role != 'volume')
              .length
        : 0;
    return Material(
      color: on ? d.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        key: ValueKey('position-chapter-${node.id}'),
        borderRadius: BorderRadius.circular(6),
        onTap: isVolume
            ? () => setState(
                () => open ? expanded.remove(node.id) : expanded.add(node.id),
              )
            : () => load(node, 0),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isVolume ? 4 : (query.trim().isEmpty && node.depth > 0 ? 22 : 8),
            7,
            8,
            7,
          ),
          child: Row(
            children: [
              if (isVolume) ...[
                Icon(
                  open
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 18,
                  color: d.ink2,
                ),
                const SizedBox(width: 2),
              ],
              Expanded(
                child: Text(
                  node.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(
                    12.5,
                    w: isVolume || on ? 600 : 400,
                    c: isVolume ? d.ink : d.ink2,
                  ),
                ),
              ),
              if (isVolume) Text('$count', style: mono(10.5, c: d.ink3)),
            ],
          ),
        ),
      ),
    );
  }

  /// 正文行（RES-047）：空行只是淡色分隔，不可绑定的段落只有说明，都不显示选择圈。
  Widget paragraphRow(ResourceParagraph row) {
    final d = context.desk;
    if (row.text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Row(
          children: [
            Expanded(child: Divider(height: 1, color: d.line)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('空行', style: ui(10.5, c: d.ink3)),
            ),
            Expanded(child: Divider(height: 1, color: d.line)),
          ],
        ),
      );
    }
    final usable = row.originalLine != null;
    final on = selected?.offset == row.offset;
    return Material(
      color: on ? d.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: usable ? () => setState(() => selected = row) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                child: usable
                    ? Icon(
                        on
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                        color: on ? d.ink : d.ink3,
                      )
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.text,
                      style: serif(13.5, c: usable ? d.ink : d.ink3, h: 1.6),
                    ),
                    if (!usable)
                      Text('这段文字没有可绑定的位置，请选择相邻正文。', style: ui(11.5, c: d.ink3)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final rows = visibleRows();
    final current = page;
    return DeskDialog(
      title: '选择图片插入位置',
      subtitle: '先选章节，再选择正文段落。图片将放在所选段落之后。',
      closeTooltip: '取消',
      width: 900,
      height: 640,
      footerLeft: Text(
        selected == null ? '尚未选择插入位置' : '插在“${selected!.text.trim()}”之后',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: ui(12.5, c: selected == null ? d.ink3 : d.ink),
      ),
      actions: [
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        DeskButton(
          '使用此位置',
          primary: true,
          disabledReason: '先选择一段正文',
          onPressed: busy || selected == null
              ? null
              : () => Navigator.pop(
                  context,
                  ResourcePositionChoice(
                    selected!.originalLine!,
                    chapter!.title,
                    selected!.text,
                  ),
                ),
        ),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 240,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  autofocus: true,
                  style: ui(13, c: d.ink),
                  decoration: deskInput(context, hint: '搜索章节').copyWith(
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: d.ink3,
                    ),
                  ),
                  onChanged: (v) => setState(() => query = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: DeskScrollArea(
                    builder: (controller) => ListView.builder(
                      controller: controller,
                      itemCount: rows.length,
                      itemBuilder: (_, i) => chapterRow(rows[i].$1, rows[i].$2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 24, color: d.line),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (chapter != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      chapter!.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: serif(15, w: 650, c: d.ink),
                    ),
                  ),
                Expanded(
                  child: busy
                      ? const Center(child: CircularProgressIndicator())
                      : error.isNotEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(error, style: ui(12.5, c: d.pen)),
                              const SizedBox(height: 8),
                              DeskButton(
                                '重新读取',
                                quiet: true,
                                onPressed: chapter == null
                                    ? loadChapters
                                    : () => load(chapter!, 0),
                              ),
                            ],
                          ),
                        )
                      : current == null || current.rows.isEmpty
                      ? Center(
                          child: Text(
                            '本节没有正文，请选择其他章节。',
                            style: ui(12.5, c: d.ink3),
                          ),
                        )
                      : DeskScrollArea(
                          builder: (controller) => ListView.builder(
                            controller: controller,
                            itemCount: current.rows.length,
                            itemBuilder: (_, i) =>
                                paragraphRow(current.rows[i]),
                          ),
                        ),
                ),
                if (current != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        DeskButton(
                          '上一页',
                          quiet: true,
                          icon: Icons.chevron_left_rounded,
                          onPressed: busy || current.offset == 0
                              ? null
                              : () => load(
                                  chapter!,
                                  (current.offset - 30).clamp(0, current.total),
                                ),
                        ),
                        Expanded(
                          child: Text(
                            current.rows.isEmpty
                                ? '暂无正文'
                                : '${current.offset + 1}–${current.offset + current.rows.length} / ${current.total} 行',
                            textAlign: TextAlign.center,
                            style: ui(12, c: d.ink3),
                          ),
                        ),
                        DeskButton(
                          '下一页',
                          quiet: true,
                          icon: Icons.chevron_right_rounded,
                          onPressed:
                              busy ||
                                  current.offset + current.rows.length >=
                                      current.total
                              ? null
                              : () => load(chapter!, current.offset + 30),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
