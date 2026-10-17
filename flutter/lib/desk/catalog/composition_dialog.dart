// 目录修复 · 组合预览（CH-215–227）：勾选目录方案（含依赖）、在“当前有效草稿”与“按勾选方案修复后”
// 之间切换浏览结构与正文；核对后整批确认应用，或另存修订 TXT。冲突阻止预览，不自动丢弃旧编辑。
// 逻辑沿用 V3 前的 CatalogCompositionDialog；设计：design_review_v37/d2_catalog.dart（D2-L）。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/catalog_service.dart';
import '../../application/chapter_service.dart';
import '../controls/controls.dart'
    show DeskButton, SelectAllHeader, SelectionKeys;
import '../dialogs.dart';
import '../repair/repair_states.dart' show saveRepairCopy;
import '../tokens.dart';
import '../widgets.dart';

class CatalogCompositionDialog extends StatefulWidget {
  const CatalogCompositionDialog({
    super.key,
    required this.session,
    required this.alignment,
    this.initialSelection,
  });
  final CatalogSession session;
  final CatalogAlignment alignment;
  final Set<String>? initialSelection;
  @override
  State<CatalogCompositionDialog> createState() =>
      _CatalogCompositionDialogState();
}

class _CatalogCompositionDialogState extends State<CatalogCompositionDialog> {
  ChapterPage? page;
  late Set<String> selected =
      widget.initialSelection ??
      widget.alignment.changes
          .where((c) => c.recommended)
          .map((c) => c.id)
          .toSet();
  CatalogRepairDraft? draft;
  void select(String id, bool value) {
    setState(() {
      if (value) {
        selected.add(id);
        selected.addAll(
          widget.alignment.changes.firstWhere((c) => c.id == id).requires,
        );
      } else {
        selected.remove(id);
        selected.removeAll(
          widget.alignment.changes
              .where((c) => c.requires.contains(id))
              .map((c) => c.id),
        );
      }
      draft = null;
    });
    load(0);
  }

  /// 全选 / 清空（表头三态与 Ctrl+A、Esc；G-067）。全选时依赖自然满足。
  void selectAll(bool value) {
    setState(() {
      selected = value
          ? widget.alignment.changes.map((c) => c.id).toSet()
          : <String>{};
      draft = null;
    });
    load(0);
  }

  bool after = true, busy = false, confirmed = false;
  String error = '';
  int generation = 0;

  @override
  void initState() {
    super.initState();
    load(0);
  }

  Future<void> load(int offset, {String? nodeId, int bodyOffset = 0}) async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      confirmed = false;
    });
    try {
      if (after && draft == null) {
        draft = await widget.session.prepareRepair(
          widget.alignment,
          selectedIds: selected,
        );
      }
      final value = await widget.session.composition(
        widget.alignment,
        offset,
        withCatalog: after,
        nodeId: nodeId,
        bodyOffset: bodyOffset,
      );
      if (mounted && ticket == generation) setState(() => page = value);
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          page = null;
          error = deskErrorText(e, '目录方案与当前草稿无法组合。请核对人工编辑、清理及目录对应；现有草稿未改变。');
        });
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    if (!confirmed || !after || page == null || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final draft =
          this.draft ??
          await widget.session.prepareRepair(
            widget.alignment,
            selectedIds: selected,
          );
      if (!mounted) return;
      await draft.session.confirm(draft.preview);
      if (mounted) Navigator.pop(context, draft);
    } catch (e) {
      if (mounted) {
        setState(() {
          confirmed = false;
          error = deskErrorText(e, '未应用目录修复，请重新核对预览。');
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> exportCopy() async {
    if (draft == null || busy) return;
    setState(() => busy = true);
    try {
      await saveRepairCopy(context, draft!.session, draft!.preview);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '修订副本未保存，请检查目标路径。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------------------------------------------------------------- 视图

  Widget pager(
    String previousTip,
    String nextTip,
    String info,
    VoidCallback? onPrevious,
    VoidCallback? onNext,
  ) {
    final d = context.desk;
    return Row(
      children: [
        IconButton(
          tooltip: previousTip,
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left_rounded, size: 18),
        ),
        Expanded(
          child: Text(
            info,
            textAlign: TextAlign.center,
            style: ui(11.5, c: d.ink3),
          ),
        ),
        IconButton(
          tooltip: nextTip,
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right_rounded, size: 18),
        ),
      ],
    );
  }

  Widget panel(String title, Widget child) {
    final d = context.desk;
    return Container(
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Text(title, style: ui(12.5, w: 620, c: d.ink)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget preview() {
    final d = context.desk;
    final p = page!;
    final tree = panel(
      '有效章节树',
      Column(
        children: [
          Expanded(
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                itemCount: p.nodes.length,
                itemBuilder: (_, i) {
                  final node = p.nodes[i];
                  final on = node.id == p.bodyNodeId;
                  return InkWell(
                    onTap: busy ? null : () => load(p.offset, nodeId: node.id),
                    child: Container(
                      color: on ? d.accentSoft : null,
                      padding: EdgeInsets.fromLTRB(
                        10 + node.depth * 12.0,
                        6,
                        10,
                        6,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              node.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: ui(
                                12.5,
                                w: node.role == 'volume' || on ? 620 : 450,
                                c: d.ink,
                              ),
                            ),
                          ),
                          Text(
                            node.role == 'volume' ? '卷' : '章节',
                            style: ui(11, c: d.ink3),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          pager(
            '上一页结构',
            '下一页结构',
            '${p.total} 节点 · ${p.offset ~/ 30 + 1} 页',
            busy || p.offset == 0 ? null : () => load(p.offset - 30),
            busy || p.offset + 30 >= p.total ? null : () => load(p.offset + 30),
          ),
        ],
      ),
    );
    final body = panel(
      '有效正文',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ColoredBox(
              color: d.paper,
              child: SelectionArea(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: p.body?.lines.length ?? 0,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      p.body!.lines[i],
                      style: serif(14, c: d.ink, h: 1.8),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (p.body != null)
            pager(
              '上一段正文',
              '下一段正文',
              '正文片段 · ${p.body!.offset + 1} / ${p.body!.total}',
              busy || p.body!.offset == 0
                  ? null
                  : () => load(
                      p.offset,
                      nodeId: p.bodyNodeId,
                      bodyOffset: (p.body!.offset - 30).clamp(0, 0x7fffffff),
                    ),
              busy || !p.body!.more
                  ? null
                  : () => load(
                      p.offset,
                      nodeId: p.bodyNodeId,
                      bodyOffset: p.body!.offset + p.body!.rows.length,
                    ),
            ),
        ],
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: (MediaQuery.sizeOf(context).width * .3).clamp(180.0, 300.0),
          child: tree,
        ),
        const SizedBox(width: 12),
        Expanded(child: body),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final changes = widget.alignment.changes;
    final canConfirm = !(busy || !after || page == null || error.isNotEmpty);
    return DeskDialog(
      title: '目录修复 · 组合预览',
      subtitle: '组合包含当前人工编辑与文本清理；冲突会阻止预览，不会自动丢弃旧编辑。',
      closeTooltip: '关闭组合预览',
      width: 1120,
      height: 760,
      footerLeft: InkWell(
        onTap: canConfirm ? () => setState(() => confirmed = !confirmed) : null,
        borderRadius: BorderRadius.circular(6),
        child: Row(
          children: [
            Checkbox(
              key: const ValueKey('catalog-composition-confirm'),
              value: confirmed,
              onChanged: canConfirm
                  ? (value) => setState(() => confirmed = value == true)
                  : null,
            ),
            Flexible(
              child: Text(
                '已核对所选修改和预览',
                style: ui(12.5, c: canConfirm ? d.ink : d.ink3),
              ),
            ),
          ],
        ),
      ),
      actions: [
        DeskButton(
          '返回目录核对',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        if (draft?.session is ChapterCopySession)
          DeskButton(
            '另存修订 TXT',
            icon: Icons.save_alt_rounded,
            disabledReason: '先勾选“已核对所选修改和预览”',
            onPressed: busy || !confirmed || !after || error.isNotEmpty
                ? null
                : exportCopy,
          ),
        DeskButton(
          '确认应用目录修复',
          primary: true,
          icon: Icons.check_rounded,
          disabledReason: selected.isEmpty ? '至少勾选一项方案' : '先在“按勾选方案修复后”中核对并勾选',
          onPressed:
              busy || !confirmed || !after || page == null || selected.isEmpty
              ? null
              : apply,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KeyedSubtree(
                key: const ValueKey('catalog-composition-view'),
                child: DeskSegmented<bool>(
                  value: after,
                  options: const {false: '当前有效草稿', true: '按勾选方案修复后'},
                  onChanged: busy
                      ? null
                      : (value) {
                          setState(() {
                            after = value;
                            page = null;
                          });
                          load(0);
                        },
                ),
              ),
              Text('原稿不变 · 尚未应用', style: ui(12, c: d.ink3)),
            ],
          ),
          const SizedBox(height: 10),
          if (changes.isNotEmpty)
            SelectAllHeader(
              selected: selected.length,
              total: changes.length,
              height: 26,
              padding: const EdgeInsets.only(left: 4),
              onChanged: busy ? null : selectAll,
            ),
          if (changes.isNotEmpty)
            SelectionKeys(
              hasSelection: selected.isNotEmpty,
              onSelectAll: busy ? null : () => selectAll(true),
              onClear: busy ? null : () => selectAll(false),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 130),
                decoration: BoxDecoration(
                  color: d.sunken,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final change in changes)
                      DeskChoiceRow(
                        radio: false,
                        selected: selected.contains(change.id),
                        title: change.title,
                        detail: '${change.before} → ${change.after}',
                        onTap: busy
                            ? null
                            : () => select(
                                change.id,
                                !selected.contains(change.id),
                              ),
                      ),
                  ],
                ),
              ),
            ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 8),
            DeskNote(error, title: '组合预览未完成', tone: Tone.pen),
          ],
          SizedBox(
            height: 2,
            child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: page == null
                ? Center(
                    child: Text(
                      busy ? '正在生成有效结构…' : '没有可显示的预览',
                      style: ui(12.5, c: d.ink2),
                    ),
                  )
                : preview(),
          ),
        ],
      ),
    );
  }
}
