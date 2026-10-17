// 目录与当前书稿对应（CH-208–214）：对应表（本地章节 / 参考目录 / 对应情况）、搜索、
// 选中行的书稿片段与人工对应，进入组合预览。只读：人工对应只重算预览，不改书稿。
// 逻辑沿用 V3 前的 CatalogAlignmentPanel；设计：design_review_v37/d2_catalog.dart（D2-K）。
import 'package:flutter/material.dart';

import '../../application/catalog_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

class CatalogAlignmentPanel extends StatefulWidget {
  const CatalogAlignmentPanel({
    super.key,
    required this.alignment,
    required this.onReturn,
    required this.onChoose,
    required this.readEvidence,
    required this.onComposition,
    this.busy = false,
    this.onRepairSelection,
  });
  final CatalogAlignment alignment;
  final VoidCallback onReturn;
  final VoidCallback onComposition;
  final void Function(Set<String>)? onRepairSelection;
  final void Function(int, String?) onChoose;
  final Future<String> Function(CatalogAlignmentRow) readEvidence;
  final bool busy;
  @override
  State<CatalogAlignmentPanel> createState() => _CatalogAlignmentPanelState();
}

class _CatalogAlignmentPanelState extends State<CatalogAlignmentPanel> {
  String query = '';
  List<CatalogAlignmentRow> visibleRows = const [];
  CatalogAlignmentRow? selected;
  Future<String>? evidence;

  @override
  void initState() {
    super.initState();
    _rebuildRows();
  }

  void _rebuildRows() {
    final needle = query;
    visibleRows = needle.isEmpty
        ? List<CatalogAlignmentRow>.of(widget.alignment.rows)
        : widget.alignment.rows
              .where(
                (row) => '${row.localTitle} ${row.referenceTitle} ${row.status}'
                    .contains(needle),
              )
              .toList(growable: false);
  }

  void loadEvidence() {
    evidence = selected?.line == null ? null : widget.readEvidence(selected!);
  }

  @override
  void didUpdateWidget(covariant CatalogAlignmentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.alignment, widget.alignment) && selected != null) {
      selected = widget.alignment.rows
          .where((r) => r.line == selected!.line)
          .firstOrNull;
      loadEvidence();
    }
    if (!identical(oldWidget.alignment, widget.alignment)) _rebuildRows();
  }

  /// 对应情况文字来自 Rust，这里只按常见措辞挑颜色；未知措辞用中性。
  Tone statusTone(CatalogAlignmentRow row) {
    final s = row.status;
    if (s.contains('未找到') || s.contains('缺')) return Tone.pen;
    if (s.contains('待') ||
        s.contains('不同') ||
        s.contains('建议') ||
        s.contains('修')) {
      return Tone.warn;
    }
    if (s.contains('对应') || s.contains('一致')) return Tone.ok;
    return Tone.neutral;
  }

  Widget table() {
    final d = context.desk;
    final rows = visibleRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('目录与当前书稿对应', style: ui(14, w: 650, c: d.ink)),
                  const SizedBox(width: 6),
                  DeskTag('已对应 ${widget.alignment.matched}', Tone.ok),
                  DeskTag('待核对 ${widget.alignment.unresolved}', Tone.warn),
                  DeskTag(
                    '建议修改 ${widget.alignment.proposedEdits}',
                    Tone.neutral,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '已包含当前人工编辑与文本清理。标题对应、待修复和未找到的内容分别列出；未找到正文时不会补写。',
                style: ui(12, c: d.ink2, h: 1.5),
              ),
              if (widget.alignment.reorder) ...[
                const SizedBox(height: 6),
                Text(
                  widget.alignment.relocatedChapters > 0
                      ? '整章归位：${widget.alignment.relocatedChapters} 章，正文随章保留；请核对组合预览。'
                      : '尚未生成整章归位方案，请核对完整性与章节对应。',
                  style: ui(12.5, w: 600, c: d.ink),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                style: ui(13, c: d.ink),
                decoration: deskInput(context, hint: '搜索参考标题或本地章节').copyWith(
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: d.ink3,
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32),
                ),
                onChanged: (value) => setState(() {
                  query = value;
                  _rebuildRows();
                }),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 4, 28, 6),
          child: Row(
            children: [
              Expanded(
                child: Text('参考目录', style: ui(11.5, w: 600, c: d.ink3)),
              ),
              Expanded(
                child: Text('本地章节', style: ui(11.5, w: 600, c: d.ink3)),
              ),
              SizedBox(
                width: 120,
                child: Text(
                  '对应情况',
                  textAlign: TextAlign.right,
                  style: ui(11.5, w: 600, c: d.ink3),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 16, 8),
            decoration: BoxDecoration(
              color: d.surface,
              borderRadius: BorderRadius.circular(10),
              boxShadow: d.shadow1,
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (_, index) {
                  final row = rows[index];
                  final on = identical(selected, row);
                  return InkWell(
                    onTap: widget.busy
                        ? null
                        : () => setState(() {
                            selected = row;
                            loadEvidence();
                          }),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 38),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: on ? d.accentSoft : null,
                        border: Border(bottom: BorderSide(color: d.line)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.referenceTitle.isEmpty
                                  ? '—'
                                  : row.referenceTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: ui(12.5, c: d.ink2),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              row.localTitle.isEmpty ? '—' : row.localTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: ui(12.5, w: on ? 600 : 420, c: d.ink),
                            ),
                          ),
                          SizedBox(
                            width: 120,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: DeskTag(row.status, statusTone(row)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
          child: Text(
            '显示 ${rows.length} 项 · 当前书稿位置 · 未应用修改',
            style: ui(11.5, c: d.ink3),
          ),
        ),
      ],
    );
  }

  Widget side() {
    final d = context.desk;
    final row = selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(row?.status ?? '选择对应项查看详情', style: ui(14, w: 650, c: d.ink)),
              const SizedBox(height: 6),
              SelectableText(
                row?.line == null ? '无本地定位' : '第 ${row!.line} 行',
                style: ui(12, c: d.ink3),
              ),
              if (row != null) ...[
                const SizedBox(height: 10),
                Text(row.localTitle, style: ui(13, w: 600, c: d.ink)),
                const SizedBox(height: 4),
                Text(row.referenceTitle, style: ui(12.5, c: d.ink2)),
              ],
              if (row?.candidates.isNotEmpty == true) ...[
                const SizedBox(height: 14),
                const DeskLabel('选择参考章节'),
                DropdownButtonFormField<String>(
                  key: ValueKey('${row!.line}:${row.chosenId}'),
                  initialValue: row.chosenId,
                  isExpanded: true,
                  decoration: deskInput(context).copyWith(labelText: '选择参考章节'),
                  hint: Text('保留待核对', style: ui(13, c: d.ink3)),
                  items: [
                    for (final choice in row.candidates)
                      DropdownMenuItem(
                        value: choice.id,
                        child: Text(
                          '${choice.volume} · ${choice.title}',
                          overflow: TextOverflow.ellipsis,
                          style: ui(13, c: d.ink),
                        ),
                      ),
                  ],
                  onChanged: widget.busy
                      ? null
                      : (value) => widget.onChoose(row.line!, value),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择后重新计算预览，尚未修改书稿。',
                        style: ui(11.5, c: d.ink3),
                      ),
                    ),
                    if (row.chosenId != null)
                      DeskButton(
                        '清除人工对应',
                        quiet: true,
                        onPressed: widget.busy
                            ? null
                            : () => widget.onChoose(row.line!, null),
                      ),
                  ],
                ),
              ],
              if (evidence != null) ...[
                const SizedBox(height: 14),
                const DeskLabel('当前书稿片段 · 最多 12 行'),
                FutureBuilder<String>(
                  key: ObjectKey(evidence),
                  future: evidence,
                  builder: (context, result) {
                    if (result.hasError) {
                      return Text(
                        '内容读取失败或对齐已过期，请重新预览。',
                        style: ui(12, c: d.pen),
                      );
                    }
                    if (!result.hasData) {
                      return Text('正在读取内容…', style: ui(12, c: d.ink3));
                    }
                    return Container(
                      constraints: const BoxConstraints(maxHeight: 220),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: d.paper,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: d.line),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          result.data!,
                          style: serif(13, c: d.ink, h: 1.8),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        if (row != null &&
            widget.onRepairSelection != null &&
            widget.alignment.changes.any((c) => c.line == row.line))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: DeskButton(
              '处理选中的这一项',
              icon: Icons.build_outlined,
              onPressed: widget.busy
                  ? null
                  : () => widget.onRepairSelection!(
                      widget.alignment.changes
                          .where((c) => c.line == row.line)
                          .map((c) => c.id)
                          .toSet(),
                    ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: table()),
                        Container(
                          width: 360,
                          decoration: BoxDecoration(
                            color: d.surface,
                            border: Border(left: BorderSide(color: d.line)),
                          ),
                          child: side(),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 3, child: table()),
                        Container(height: 1, color: d.line),
                        Expanded(flex: 2, child: side()),
                      ],
                    ),
            ),
            Container(
              constraints: const BoxConstraints(minHeight: 58),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: d.surface,
                border: Border(top: BorderSide(color: d.line)),
              ),
              child: Row(
                children: [
                  DeskButton(
                    '返回目录身份核对',
                    quiet: true,
                    icon: Icons.arrow_back_rounded,
                    onPressed: widget.busy ? null : widget.onReturn,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '人工对应先重算预览；核对组合结果后再确认应用到草稿。',
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ui(12, c: d.ink3),
                    ),
                  ),
                  const SizedBox(width: 12),
                  DeskButton(
                    '目录一键修复预览',
                    primary: true,
                    icon: Icons.auto_fix_high_outlined,
                    onPressed: widget.busy ? null : widget.onComposition,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
