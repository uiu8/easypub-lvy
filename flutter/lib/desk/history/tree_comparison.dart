// 章节变化对照（HIS-012–019）：修改前 / 修改后两棵章节树分页并排；点节点在两个版本中定位同一节点。
// 粗体只表示本页对照中的差异。逻辑沿用 V4 前的 HistoryTreeComparison。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/change_history_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';

class HistoryTreeComparison extends StatefulWidget {
  const HistoryTreeComparison({
    super.key,
    required this.history,
    required this.detail,
  });
  final ChangeHistoryService history;
  final ChangeDetail detail;
  @override
  State<HistoryTreeComparison> createState() => _HistoryTreeComparisonState();
}

class _HistoryTreeComparisonState extends State<HistoryTreeComparison> {
  int offset = 0;
  String? focusedId;
  final previous = <int>[];
  late Future<HistoryTrees> pending = widget.history.chapterTrees(
    widget.detail,
    offset,
  );
  @override
  void didUpdateWidget(HistoryTreeComparison old) {
    super.didUpdateWidget(old);
    if (!identical(old.history, widget.history) ||
        old.detail.record.id != widget.detail.record.id ||
        old.detail.guard != widget.detail.guard) {
      offset = 0;
      focusedId = null;
      previous.clear();
      pending = widget.history.chapterTrees(widget.detail, offset);
    }
  }

  void load(int next, {String? entryId}) => setState(() {
    offset = next;
    focusedId = entryId;
    pending = widget.history.chapterTrees(
      widget.detail,
      offset,
      entryId: entryId,
    );
  });

  Widget tree(
    String label,
    List<HistoryTreeNode> nodes,
    List<HistoryTreeNode> other,
    int pageOffset,
    bool found,
  ) {
    final d = context.desk;
    final after = label == '修改后';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: d.paper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: ui(12, w: 620, c: after ? d.add : d.del)),
          if (focusedId != null)
            Text(
              found ? '目标所在页 · 从第 ${pageOffset + 1} 项' : '此版本不存在该节点',
              style: ui(11.5, c: d.ink3),
            ),
          const SizedBox(height: 8),
          if (nodes.isEmpty) Text('此页无节点', style: ui(12, c: d.ink3)),
          for (final node in nodes)
            Padding(
              padding: EdgeInsets.only(
                left: node.depth.clamp(0, 8) * 12.0,
                bottom: 4,
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () => load(offset, entryId: node.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 3,
                  ),
                  decoration: node.id == focusedId
                      ? BoxDecoration(
                          color: d.accentSoft,
                          borderRadius: BorderRadius.circular(5),
                        )
                      : null,
                  child: Row(
                    children: [
                      Icon(
                        node.role == 'volume'
                            ? Icons.folder_outlined
                            : Icons.article_outlined,
                        size: 15,
                        color: d.ink3,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          node.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ui(
                            12.5,
                            w:
                                other.indexWhere((n) => n.id == node.id) !=
                                        nodes.indexOf(node) ||
                                    !other.any(
                                      (n) =>
                                          n.id == node.id &&
                                          n.title == node.title &&
                                          n.depth == node.depth &&
                                          n.role == node.role,
                                    )
                                ? 650
                                : 420,
                            c: d.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return FutureBuilder<HistoryTrees>(
      future: pending,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DeskNote(
                deskErrorText(snapshot.error!, '章节快照读取失败或已过期，请重新选择记录。'),
                tone: Tone.pen,
              ),
              const SizedBox(height: 8),
              DeskButton(
                '重试',
                quiet: true,
                onPressed: () => load(offset, entryId: focusedId),
              ),
            ],
          );
        }
        final data = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done || data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final step = data.before.length > data.after.length
            ? data.before.length
            : data.after.length;
        final total = data.beforeTotal > data.afterTotal
            ? data.beforeTotal
            : data.afterTotal;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '修改前 ${data.beforeTotal} 项 · 修改后 ${data.afterTotal} 项',
              style: ui(12, c: d.ink3),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final before = tree(
                    '修改前',
                    data.before,
                    data.after,
                    data.beforeOffset,
                    data.beforeFound,
                  );
                  final after = tree(
                    '修改后',
                    data.after,
                    data.before,
                    data.afterOffset,
                    data.afterFound,
                  );
                  if (c.maxWidth >= 640) {
                    return SingleChildScrollView(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: before),
                          const SizedBox(width: 10),
                          Expanded(child: after),
                        ],
                      ),
                    );
                  }
                  return ListView(
                    children: [before, const SizedBox(height: 10), after],
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Text('点击节点定位两个版本；粗体仅表示本页对照中的差异。', style: ui(11.5, c: d.ink3)),
            if (focusedId != null)
              Align(
                alignment: Alignment.centerLeft,
                child: DeskButton(
                  '返回顺序分页',
                  quiet: true,
                  onPressed: () {
                    previous.clear();
                    load(0);
                  },
                ),
              )
            else
              Row(
                children: [
                  DeskButton(
                    '上一页',
                    quiet: true,
                    onPressed: previous.isEmpty
                        ? null
                        : () => load(previous.removeLast()),
                  ),
                  const Spacer(),
                  Text('从第 ${offset + 1} 项', style: ui(12, c: d.ink2)),
                  const Spacer(),
                  DeskButton(
                    '下一页',
                    quiet: true,
                    onPressed: step == 0 || offset + step >= total
                        ? null
                        : () {
                            previous.add(offset);
                            load(offset + step);
                          },
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
