// 清理问题与原稿上下文（CLEAN-073–080）：复查结果分页列表 + 证据；广告候选只生成待确认的排除方案，
// 其他问题定位到对应清理规则。不直接修改草稿或原文件。逻辑沿用 V4 前的 CleanupInspectionDialog。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/cleanup_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

sealed class CleanupInspectionResult {}

class CleanupRemovalPreview extends CleanupInspectionResult {
  CleanupRemovalPreview(this.preview);
  final CleanupPreview preview;
}

class CleanupRuleLocation extends CleanupInspectionResult {
  CleanupRuleLocation(this.kind);
  final String kind;
}

class CleanupInspectionDialog extends StatefulWidget {
  const CleanupInspectionDialog({
    super.key,
    required this.session,
    required this.inspection,
    this.initialLine,
  });
  final CleanupSession session;
  final CleanupInspection inspection;

  /// 先选中这一行的检测结果；本页没有时选第一条。
  final int? initialLine;
  @override
  State<CleanupInspectionDialog> createState() => _InspectionState();
}

class _InspectionState extends State<CleanupInspectionDialog> {
  late CleanupInspection page = widget.inspection;
  CleanupInspectionFinding? selected;
  String excerpt = '', error = '';
  bool busy = false;
  int generation = 0;
  bool get current => widget.session.isInspectionCurrent(page);
  @override
  void initState() {
    super.initState();
    widget.session.changes.addListener(refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && page.findings.isNotEmpty) {
        choose(
          page.findings
                  .where((f) => f.line == widget.initialLine)
                  .firstOrNull ??
              page.findings.first,
        );
      }
    });
  }

  Future<void> choose(CleanupInspectionFinding finding) async {
    setState(() {
      selected = finding;
      excerpt = '';
    });
    if (finding.originalLine != null) await source();
  }

  void refresh() {
    if (!current) {
      generation++;
      setState(() {
        selected = null;
        excerpt = '';
        busy = false;
        error = '复查已过期，请返回重新复查。';
      });
    }
  }

  @override
  void dispose() {
    generation++;
    widget.session.changes.removeListener(refresh);
    super.dispose();
  }

  Future<void> run(Future<void> Function(int) action) async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action(ticket);
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          error = deskErrorText(e, '无法完成定位，请核对源范围和现有章节编辑。');
        });
      }
    } finally {
      if (mounted && ticket == generation) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> load(int offset) => run((ticket) async {
    final next = await widget.session.recheck(offset: offset);
    if (!mounted || ticket != generation) return;
    if (next.guard != page.guard) {
      throw const FormatException('复查版本已改变，请返回重新复查。');
    }
    final first = next.findings.firstOrNull;
    setState(() {
      page = next;
      selected = first;
      excerpt = '';
    });
    if (first?.originalLine != null) {
      final text = await widget.session.inspectionSource(next, first!);
      if (mounted && ticket == generation) setState(() => excerpt = text);
    }
  });
  Future<void> source() => run((ticket) async {
    final next = await widget.session.inspectionSource(page, selected!);
    if (mounted && ticket == generation) {
      setState(() {
        excerpt = next;
      });
    }
  });
  Future<void> remove() => run((ticket) async {
    final preview = await widget.session.previewInspectionRemoval(
      page,
      selected!,
    );
    if (mounted && ticket == generation) {
      Navigator.pop(context, CleanupRemovalPreview(preview));
    }
  });

  Widget evidence() {
    final d = context.desk;
    final s = selected!;
    final ad = s.kind == 'remove_ad_lines';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 8),
      children: [
        Row(
          children: [
            DeskTag(
              cleanupLabels[s.kind] ?? s.kind,
              ad ? Tone.warn : Tone.neutral,
            ),
            const SizedBox(width: 8),
            Text('有效稿第 ${s.line} 行', style: mono(11, c: d.ink3)),
          ],
        ),
        const SizedBox(height: 10),
        const DeskLabel('有效稿证据'),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: d.paper,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: d.line),
          ),
          child: SelectableText(s.before, style: serif(14, c: d.ink, h: 1.7)),
        ),
        if (s.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('长文本仅显示节选。', style: ui(11.5, c: d.ink3)),
          ),
        if (!ad)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              '检查建议：${s.after ?? '排除此空行'}',
              style: ui(12.5, c: d.ink2),
            ),
          ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(child: DeskLabel('原稿上下文')),
            DeskButton(
              '刷新原稿上下文',
              quiet: true,
              icon: Icons.refresh_rounded,
              onPressed: busy || s.originalLine == null ? null : source,
            ),
          ],
        ),
        if (excerpt.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: d.sunken,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(excerpt, style: serif(13, c: d.ink2, h: 1.7)),
          )
        else
          Text(
            s.originalLine == null
                ? '无唯一原稿映射，不能直接排除'
                : '原稿第 ${s.originalLine} 行',
            style: ui(12, c: d.ink3),
          ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: ad
              ? DeskButton(
                  '预览排除此候选',
                  primary: true,
                  disabledReason: s.originalLine == null
                      ? '无唯一原稿映射，不能直接排除'
                      : '此行受保护，不能排除',
                  onPressed: busy || s.originalLine == null || !s.selectable
                      ? null
                      : remove,
                )
              : DeskButton(
                  '定位清理规则',
                  onPressed: busy
                      ? null
                      : () =>
                            Navigator.pop(context, CleanupRuleLocation(s.kind)),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '清理问题与原稿上下文',
      subtitle: '坐标分别标明有效稿与原稿。排除广告只生成待确认方案；不会直接修改草稿或原文件。',
      closeTooltip: '关闭',
      width: 1000,
      height: math.min(680, MediaQuery.sizeOf(context).height - 80),
      footerLeft: Text(
        '第 ${page.offset ~/ 40 + 1} 页 · ${page.changes} 处空白变更 / ${page.candidates} 条广告候选',
        style: ui(12, c: d.ink3),
      ),
      actions: [
        DeskButton(
          '上一页',
          quiet: true,
          onPressed: busy || !current || page.offset == 0
              ? null
              : () => load(math.max(0, page.offset - 40)),
        ),
        DeskButton(
          '下一页',
          quiet: true,
          onPressed:
              busy ||
                  !current ||
                  page.offset + 40 >= math.max(page.changes, page.candidates)
              ? null
              : () => load(page.offset + 40),
        ),
        DeskButton('返回结果', onPressed: () => Navigator.pop(context)),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 2,
            child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          if (error.isNotEmpty) ...[
            DeskNote(error, tone: Tone.pen),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: !current
                ? Center(
                    child: Text('旧问题已失效', style: ui(13, c: d.ink2)),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 340,
                        child: Container(
                          decoration: BoxDecoration(
                            color: d.surface,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: d.line),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Material(
                            type: MaterialType.transparency,
                            child: ListView.builder(
                              itemCount: page.findings.length,
                              itemBuilder: (context, i) {
                                final finding = page.findings[i];
                                final on = identical(selected, finding);
                                return InkWell(
                                  onTap: busy ? null : () => choose(finding),
                                  child: Container(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      10,
                                      8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: on ? d.accentSoft : null,
                                      border: Border(
                                        bottom: BorderSide(color: d.line),
                                        left: BorderSide(
                                          color: on
                                              ? d.accent
                                              : Colors.transparent,
                                          width: 2.5,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${cleanupLabels[finding.kind]} · 有效稿第 ${finding.line} 行',
                                                style: ui(
                                                  12.5,
                                                  w: on ? 600 : 450,
                                                  c: d.ink,
                                                ),
                                              ),
                                              Text(
                                                finding.originalLine == null
                                                    ? '无唯一原稿映射，不能直接排除'
                                                    : '原稿第 ${finding.originalLine} 行',
                                                style: ui(11.5, c: d.ink3),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (finding.kind == 'remove_ad_lines')
                                          Icon(
                                            Icons.help_outline_rounded,
                                            size: 16,
                                            color: d.warn,
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
                      Expanded(
                        child: selected == null
                            ? Center(
                                child: Text(
                                  '选择一项查看证据',
                                  style: ui(12.5, c: d.ink3),
                                ),
                              )
                            : evidence(),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
