// 参考目录（CH-173–179）：目录身份核对（书名、作者、来源、完整性、条目）→ 与当前书稿对应 → 组合预览。
// 获取与保存都不改正文；目录修复只在组合预览中核对后整批应用，可撤销。
// 一键流程（CH-246，quick）：取得目录 → 身份核对弹窗 → 对齐 → 有推荐修改时打开组合预览；每步可取消。
// 逻辑沿用 V3 前的 CatalogPage；设计：design_review_v37/d2_catalog.dart（D2-I）。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/catalog_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'alignment_panel.dart';
import 'composition_dialog.dart';
import 'quick_identity_dialog.dart';
import 'source_dialog.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.onReturn,
    required this.pickFile,
    this.pickBookSourceFile,
    this.quick = false,
  });
  final LibraryService library;
  final String bookId;
  final VoidCallback onReturn;
  final Future<String?> Function() pickFile;

  /// 选择“阅读”书源 JSON（V45）；不提供时书源页签不能导入。
  final Future<String?> Function()? pickBookSourceFile;

  /// 从“一键目录修复…”进入：打开页面后自动走一键流程。
  final bool quick;
  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  late var session = widget.library.openCatalog(widget.bookId);
  late CatalogSnapshot? snapshot = session.saved;
  String error = '';
  bool busy = false, identity = false, candidate = false, reorder = false;
  CatalogAlignment? alignment;
  CatalogRepairDraft? applied;

  // ---------------------------------------------------------------- 流程（逐行沿用）

  @override
  void initState() {
    super.initState();
    if (widget.quick) {
      WidgetsBinding.instance.addPostFrameCallback((_) => quickRepair());
    }
  }

  /// 一键目录修复：没有目录先获取；身份核对必须由用户勾选；对齐后有推荐修改才打开组合预览，
  /// 应用仍在组合预览中确认。任一步取消都停在本页。
  Future<void> quickRepair() async {
    if (!mounted || busy) return;
    if (snapshot == null) await chooseSource();
    if (!mounted || snapshot == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          CatalogQuickIdentityDialog(snapshot: snapshot!, candidate: candidate),
    );
    if (!mounted || confirmed != true) return;
    setState(() => identity = true);
    await preview();
    final result = alignment;
    if (!mounted || result == null) return;
    if (result.changes.isEmpty) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('目录与当前书稿已对应，没有推荐的目录修复。')));
      return;
    }
    await reviewComposition();
  }

  Future<void> reviewComposition([Set<String>? selected]) async {
    final result = await showDialog<CatalogRepairDraft>(
      context: context,
      builder: (_) => CatalogCompositionDialog(
        session: session,
        alignment: alignment!,
        initialSelection: selected,
      ),
    );
    if (mounted && result != null) {
      setState(() {
        applied = result;
        alignment = null;
        error = '';
      });
      await preview();
    }
  }

  Future<void> undoRepair() async {
    final draft = applied;
    if (draft == null) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await draft.session.undoConfirmed(draft.preview);
      if (mounted) {
        setState(() {
          applied = null;
          alignment = null;
        });
        await preview();
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '撤销未完成，请核对章节历史。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose(int line, String? id) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await session.choose(alignment!, line, id);
      if (mounted) setState(() => alignment = result);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '人工对应未完成。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> preview() async {
    setState(() {
      busy = true;
      error = '';
      alignment = null;
    });
    try {
      final result = await session.preview(
        snapshot!,
        identityConfirmed: identity,
        reorder: reorder,
      );
      if (mounted) setState(() => alignment = result);
    } catch (e) {
      if (mounted) {
        setState(() => error = deskErrorText(e, '目录对齐未完成。'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    session.cancel();
    super.dispose();
  }

  Future<void> chooseSource() async {
    final nextSession = widget.library.openCatalog(widget.bookId);
    setState(() => busy = true);
    final next = await showDialog<CatalogSnapshot>(
      context: context,
      builder: (_) => CatalogSourceDialog(
        session: nextSession,
        pickFile: widget.pickFile,
        pickBookSourceFile: widget.pickBookSourceFile,
      ),
    );
    if (!mounted) {
      nextSession.cancel();
      return;
    }
    setState(() {
      busy = false;
      if (next != null) {
        session.cancel();
        session = nextSession;
        snapshot = next;
        identity = false;
        candidate = true;
        alignment = null;
        reorder = false;
        error = '';
      }
    });
  }

  void accept() {
    try {
      session.accept(snapshot!);
      setState(() {
        candidate = false;
        identity = false;
        error = '';
      });
    } catch (e) {
      setState(() => error = deskErrorText(e, '未保存目录候选。'));
    }
  }

  // ---------------------------------------------------------------- 视图

  Widget header() {
    final d = context.desk;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: d.canvas,
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Text('参考目录', style: ui(16, w: 650, c: d.ink)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '依据目录修复 · 不改写原稿',
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: d.ink3),
            ),
          ),
          DeskButton(
            snapshot == null ? '获取参考目录' : '更换来源',
            icon: snapshot == null
                ? Icons.download_rounded
                : Icons.swap_horiz_rounded,
            onPressed: busy ? null : chooseSource,
          ),
          const SizedBox(width: 6),
          DeskButton(
            '返回章节编辑',
            quiet: true,
            icon: Icons.arrow_back_rounded,
            onPressed: busy ? null : widget.onReturn,
          ),
        ],
      ),
    );
  }

  Widget kv(String k, String v, {Widget? tail}) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(k, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: Text(v, style: ui(12.5, c: d.ink)),
          ),
          ?tail,
        ],
      ),
    );
  }

  Widget identityCard() {
    final d = context.desk;
    final s = snapshot!;
    final completeness = switch (s.completeness) {
      'complete' => ('声明范围完整', Tone.ok),
      'partial' => ('目录不完整', Tone.warn),
      _ => ('完整性未确认', Tone.warn),
    };
    final volumes = {
      for (final e in s.entries)
        if (e.volume.isNotEmpty) e.volume,
    };
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${s.title} · ${s.author.isEmpty ? '作者未提供' : s.author}',
                  style: ui(15, w: 650, c: d.ink),
                ),
              ),
              if (candidate)
                const DeskTag('新来源 · 未保存', Tone.warn)
              else
                const DeskTag('本书目录快照已保存', Tone.ok),
            ],
          ),
          const SizedBox(height: 14),
          kv('书名', s.title),
          kv('作者', s.author.isEmpty ? '作者未提供' : s.author),
          kv('来源', s.origin == 'paste' ? '粘贴文本' : s.origin),
          kv(
            '卷章分组',
            volumes.isEmpty
                ? '${s.entries.length} 条目录 · 未提供分组'
                : '${s.entries.length} 条目录 · ${volumes.length} 个分组',
          ),
          kv(
            '完整性',
            '${s.entries.length} 条目录 · ${completeness.$1}',
            tail: DeskTag(completeness.$1, completeness.$2),
          ),
          const SizedBox(height: 4),
          Divider(height: 1, color: d.line),
          const SizedBox(height: 10),
          InkWell(
            onTap: busy ? null : () => setState(() => identity = !identity),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                Checkbox(
                  key: const ValueKey('catalog-identity'),
                  value: identity,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => identity = value == true),
                ),
                Expanded(
                  child: Text(
                    '已核对书名、作者、来源和目录范围',
                    style: ui(13, w: 560, c: d.ink),
                  ),
                ),
              ],
            ),
          ),
          InkWell(
            onTap: busy
                ? null
                : () => setState(() {
                    reorder = !reorder;
                    alignment = null;
                  }),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                Switch(
                  key: const ValueKey('catalog-reorder'),
                  value: reorder,
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                          reorder = value;
                          alignment = null;
                        }),
                ),
                const SizedBox(width: 8),
                Text('按参考目录整章归位', style: ui(13, c: d.ink)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('正文随章节移动；需要完整目录和唯一对应', style: ui(12, c: d.ink3)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                candidate ? '保存快照或对齐前先勾选核对。' : '随项目保存；重开后需重新确认目录身份。此处尚未应用目录修复。',
                style: ui(11.5, c: d.ink3),
              ),
              if (candidate)
                DeskButton(
                  '保存目录快照',
                  icon: Icons.bookmark_add_outlined,
                  disabledReason: '先勾选“已核对书名、作者、来源和目录范围”',
                  onPressed: busy || !identity ? null : accept,
                ),
              DeskButton(
                '核对当前书稿与目录',
                primary: true,
                icon: Icons.arrow_forward_rounded,
                disabledReason: '先勾选“已核对书名、作者、来源和目录范围”',
                onPressed: busy || !identity ? null : preview,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget entries() {
    final d = context.desk;
    final s = snapshot!;
    return Container(
      decoration: BoxDecoration(
        color: d.surface,
        border: Border(left: BorderSide(color: d.line)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('参考条目', style: ui(13, w: 650, c: d.ink)),
              const Spacer(),
              Text('${s.entries.length} 条', style: ui(12, c: d.ink3)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemExtent: 30,
              itemCount: s.entries.length,
              itemBuilder: (_, i) {
                final item = s.entries[i];
                return Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text('${i + 1}', style: mono(10.5, c: d.ink3)),
                    ),
                    if (item.volume.isNotEmpty)
                      SizedBox(
                        width: 120,
                        child: Tooltip(
                          message:
                              '${item.structural ? '结构分组' : '访问分组'}：${item.volume}',
                          child: Text(
                            item.volume,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(12, c: item.structural ? d.ink2 : d.ink3),
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(12.5, c: d.ink),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Text('参考目录只用于核对与修复建议；获取与保存不改正文。', style: ui(11.5, c: d.ink3)),
        ],
      ),
    );
  }

  Widget identityView(BoxConstraints c) {
    final d = context.desk;
    if (snapshot == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.list_alt_rounded, size: 26, color: d.ink3),
            const SizedBox(height: 10),
            Text('读取后核对书名、作者和章节目录', style: ui(14, w: 600, c: d.ink2)),
            const SizedBox(height: 12),
            DeskButton(
              '获取参考目录',
              primary: true,
              icon: Icons.download_rounded,
              onPressed: busy ? null : chooseSource,
            ),
          ],
        ),
      );
    }
    final main = ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      children: [
        identityCard(),
        if (!c.hasBoundedHeight || c.maxWidth < 900) ...[
          const SizedBox(height: 12),
          SizedBox(height: 360, child: entries()),
        ],
      ],
    );
    if (c.maxWidth < 900) return main;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: main),
        SizedBox(width: 400, child: entries()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Material(
      color: d.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: d.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header(),
          SizedBox(
            height: 2,
            child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          if (applied != null)
            Container(
              margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
              decoration: BoxDecoration(
                color: d.addSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    size: 16,
                    color: d.add,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '目录修复已应用到草稿；原稿不变。另存项目可保留，章节页可继续编辑。',
                      style: ui(12.5, c: d.ink),
                    ),
                  ),
                  DeskButton(
                    '撤销本次目录修复',
                    icon: Icons.undo_rounded,
                    onPressed: busy ? null : undoRepair,
                  ),
                ],
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: DeskNote(error, title: '目录操作未完成', tone: Tone.pen),
            ),
          Expanded(
            child: alignment != null
                ? CatalogAlignmentPanel(
                    alignment: alignment!,
                    busy: busy,
                    onChoose: choose,
                    readEvidence: (row) => session.evidence(alignment!, row),
                    onComposition: reviewComposition,
                    onRepairSelection: reviewComposition,
                    onReturn: () => setState(() => alignment = null),
                  )
                : LayoutBuilder(builder: (context, c) => identityView(c)),
          ),
        ],
      ),
    );
  }
}
