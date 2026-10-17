// 批量清理差异（CLEAN-091–096）：只读浏览本批已冻结的规则与选择，按 40 条分页；关闭不改变批量的确认步骤。
// 排版“应用到多本书”的清理部分也用它（.reader 构造）。逻辑沿用 V4 前的 CleanupBatchDifferenceDialog。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/cleanup_batch_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// Read-only drilldown of the frozen batch request. It cannot adopt or edit
/// settings, so closing it preserves the batch's explicit confirmation step.
class CleanupBatchDifferenceDialog extends StatefulWidget {
  const CleanupBatchDifferenceDialog({
    super.key,
    required this.session,
    required this.plan,
    required this.bookId,
    required this.title,
  }) : read = null,
       listenable = null,
       isCurrent = null;
  const CleanupBatchDifferenceDialog.reader({
    super.key,
    required this.read,
    required this.listenable,
    required this.isCurrent,
    required this.bookId,
    required this.title,
  }) : session = null,
       plan = null;
  final CleanupBatchSession? session;
  final CleanupBatchPreview? plan;
  final Future<CleanupBatchDifferencePage> Function(int offset)? read;
  final Listenable? listenable;
  final bool Function()? isCurrent;
  final String bookId, title;
  @override
  State<CleanupBatchDifferenceDialog> createState() => _DifferenceState();
}

class _DifferenceState extends State<CleanupBatchDifferenceDialog> {
  CleanupBatchDifferencePage? page;
  bool busy = true, candidates = false, whitespace = false;
  String error = '';
  int generation = 0;
  final scroll = ScrollController();
  bool get current =>
      widget.isCurrent?.call() ??
      widget.session!.canRead(widget.plan!, widget.bookId);
  Listenable get changes => widget.listenable ?? widget.session!.changes;
  @override
  void initState() {
    super.initState();
    changes.addListener(refresh);
    load(0);
  }

  void refresh() {
    if (!current) {
      generation++;
      setState(() {
        page = null;
        busy = false;
        error = '书稿或项目状态已改变，请返回重新预览。';
      });
    }
  }

  @override
  void dispose() {
    generation++;
    changes.removeListener(refresh);
    scroll.dispose();
    super.dispose();
  }

  Future<void> load(int offset) async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      page = null;
    });
    try {
      final next =
          await (widget.read?.call(offset) ??
              widget.session!.differences(
                widget.plan!,
                widget.bookId,
                offset: offset,
              ));
      if (!mounted || ticket != generation) return;
      setState(() {
        page = next;
      });
      if (scroll.hasClients) scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || ticket != generation) return;
      setState(() {
        error = deskErrorText(e, '无法读取差异，请返回重新预览。');
      });
    } finally {
      if (mounted && ticket == generation) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  String visible(String text) => whitespace
      ? text.replaceAll(' ', '·').replaceAll('\t', '⇥').replaceAll('\n', '↵\n')
      : text;

  Widget evidence(String label, String text, bool after) {
    final d = context.desk;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: after ? d.addSoft : d.delSoft,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: ui(11, w: 620, c: after ? d.add : d.del)),
          const SizedBox(height: 4),
          SelectableText(text, style: serif(13.5, c: d.ink, h: 1.6)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final total = candidates ? page?.candidateTotal ?? 0 : page?.total ?? 0;
    final count = candidates
        ? page?.candidates.length ?? 0
        : page?.actions.length ?? 0;
    final offset = page?.offset ?? 0;
    return DeskDialog(
      title: '${widget.title} · 批量清理差异',
      subtitle: '只读审阅本批已冻结的规则与选择。候选不等于删除；如需调整，请返回本书清理后重新预览。',
      closeTooltip: '返回批量预览',
      width: 960,
      height: math.min(660, MediaQuery.sizeOf(context).height - 80),
      footerLeft: Text(
        count == 0
            ? '共 $total 条'
            : '${offset + 1}–${offset + count} / $total 条',
        style: ui(12, c: d.ink3),
      ),
      actions: [
        DeskButton(
          '上一页',
          quiet: true,
          onPressed: !busy && current && offset > 0
              ? () => load(math.max(0, offset - 40))
              : null,
        ),
        DeskButton(
          '下一页',
          quiet: true,
          onPressed: !busy && current && offset + 40 < total
              ? () => load(offset + 40)
              : null,
        ),
        DeskButton(
          '返回批量预览',
          primary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DeskSegmented<bool>(
                value: candidates,
                options: const {false: '最终变更', true: '提示候选'},
                onChanged: busy || !current
                    ? null
                    : (value) {
                        setState(() {
                          candidates = value;
                        });
                        load(0);
                      },
              ),
              const SizedBox(width: 10),
              FilterChip(
                label: const Text('显示空白'),
                selected: whitespace,
                onSelected: (v) => setState(() {
                  whitespace = v;
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 2,
            child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          if (error.isNotEmpty) DeskNote(error, tone: Tone.pen),
          Expanded(
            child: page == null
                ? const SizedBox.shrink()
                : count == 0
                ? Center(
                    child: Text(
                      candidates ? '本页没有提示候选' : '本页没有文本变更',
                      style: ui(12.5, c: d.ink2),
                    ),
                  )
                : ListView.separated(
                    controller: scroll,
                    itemCount: count,
                    separatorBuilder: (_, _) =>
                        Divider(height: 20, color: d.line),
                    itemBuilder: (context, index) {
                      if (candidates) {
                        final item = page!.candidates[index];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '源行 ${item.line}',
                                  style: mono(11, c: d.ink3),
                                ),
                                const SizedBox(width: 8),
                                DeskTag(
                                  !item.selectable
                                      ? '受保护，不可删除'
                                      : item.selected
                                      ? '已选择删除'
                                      : '未选择删除',
                                  item.selected ? Tone.pen : Tone.neutral,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              visible(item.text),
                              style: serif(13.5, c: d.ink, h: 1.6),
                            ),
                            if (item.truncated)
                              Text('长候选文本已截断显示。', style: ui(11.5, c: d.ink3)),
                          ],
                        );
                      }
                      final item = page!.actions[index];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '源行 ${item.line}–${item.end} · 规则 ${item.step + 1}',
                            style: ui(12, w: 600, c: d.ink2),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: evidence(
                                  '原文',
                                  visible(item.before),
                                  false,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: evidence(
                                  '清理后',
                                  item.after == null
                                      ? '〔删除〕'
                                      : visible(item.after!),
                                  true,
                                ),
                              ),
                            ],
                          ),
                          if (item.truncated)
                            Text(
                              '长文本每侧最多显示 300 字符；此条差异内容已截断。',
                              style: ui(11.5, c: d.ink3),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
