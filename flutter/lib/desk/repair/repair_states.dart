// 修复方案的结果与异常状态（CH-157–172、CH-228–232）：复查剩余问题列表、方案过期、
// 应用/复查失败、零问题，以及另存修订 TXT 的回执。四种状态彼此独立，恢复按钮不会重复提交旧方案。
// 设计：design_review_v37/d2_repair.dart（D2-G/H 与 D2RepairStatesBoard）。
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../chapters/issue_marks.dart' show severityTone;
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 另存修订 TXT（含配套项目），完成后给出回执；原始文件与当前编辑稿不变。
Future<ChapterCopyReceipt?> saveRepairCopy(
  BuildContext context,
  ChapterSession session,
  ChapterEditPreview preview,
) async {
  if (session is! ChapterCopySession) return null;
  final target = await getSaveLocation(
    suggestedName: '修订书稿.txt',
    acceptedTypeGroups: const [
      XTypeGroup(label: 'TXT 书稿', extensions: ['txt']),
    ],
  );
  if (target == null) return null;
  final receipt = await (session as ChapterCopySession).exportCopy(
    preview,
    target.path,
  );
  if (context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (context) => DeskDialog(
        title: '修订副本已保存',
        closeTooltip: '关闭',
        width: 520,
        actions: [
          DeskButton(
            '知道了',
            primary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        child: SelectableText(
          'TXT：${receipt.textPath}\n\n配套项目：${receipt.projectPath}\n\n复查还有 ${receipt.remainingIssues} 项提示。打开配套项目可保留章节层级、标题识别和排版设置；原始文件与当前编辑稿均未改动。',
          style: ui(12.5, c: context.desk.ink2, h: 1.6),
        ),
      ),
    );
  }
  return receipt;
}

/// 状态卡：标题 + 标签 + 说明 + 键值行 + 操作；居中、最宽 640。
class RepairStateCard extends StatelessWidget {
  const RepairStateCard({
    super.key,
    required this.title,
    required this.tag,
    required this.body,
    this.rows = const [],
    this.actions = const [],
    this.icon = Icons.error_outline_rounded,
    this.tone = Tone.pen,
    this.extra,
  });
  final String title, body;
  final Widget tag;
  final List<(String, String)> rows;
  final List<Widget> actions;
  final IconData icon;
  final Tone tone;
  final Widget? extra;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (fg, bg) = d.tone(tone);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Container(
            padding: const EdgeInsets.all(20),
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
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: bg,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, size: 18, color: fg),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(title, style: ui(16, w: 650, c: d.ink)),
                    ),
                    const SizedBox(width: 10),
                    tag,
                  ],
                ),
                const SizedBox(height: 10),
                Text(body, style: ui(12.5, c: d.ink2, h: 1.6)),
                if (rows.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final (k, v) in rows)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: d.line)),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 120,
                            child: Text(k, style: ui(12, c: d.ink3)),
                          ),
                          Expanded(
                            child: Text(v, style: ui(12.5, c: d.ink)),
                          ),
                        ],
                      ),
                    ),
                ],
                if (extra != null) ...[const SizedBox(height: 10), extra!],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 书稿已变化：原方案只读展示，停用应用（CH-164/165）。
class ChapterRepairStale extends StatelessWidget {
  const ChapterRepairStale({
    super.key,
    required this.changes,
    required this.issueCount,
    required this.onRefresh,
    required this.onReturn,
  });
  final List<ChapterRepairChange> changes;
  final int issueCount;
  final VoidCallback? onRefresh, onReturn;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return RepairStateCard(
      title: '修复方案已过期',
      tag: const DeskTag('旧方案未提交', Tone.warn),
      icon: Icons.update_rounded,
      tone: Tone.warn,
      body: '书稿状态已变化，原计划不能继续应用。请重新检测并核对新方案。重新检测会生成新结果，并保留既有草稿和历史；不会拿旧行号修改当前正文。',
      rows: [
        ('草稿状态', '已检查的快照 → 已变化'),
        ('安全修复方案', '${changes.length} 项 → 需要重新计算'),
        ('待核对问题', '$issueCount 项 → 需要重新定位'),
        ('原计划', '仅供查看，已停用应用按钮'),
      ],
      extra: changes.isEmpty
          ? null
          : Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: d.sunken,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: changes.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: Text(
                          '${changes[i].line} 行',
                          style: mono(11, c: d.ink3),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          changes[i].title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ui(12, c: d.ink2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      actions: [
        DeskButton('返回章节', quiet: true, onPressed: onReturn),
        DeskButton(
          '重新检测并生成方案',
          primary: true,
          icon: Icons.refresh_rounded,
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

/// 应用未完成（未采用）或已应用但复查未完成（CH-166–168）。重试分别为重新检测或仅复查。
class ChapterRepairFailure extends StatefulWidget {
  const ChapterRepairFailure({
    super.key,
    required this.applied,
    required this.phase,
    required this.detail,
    required this.changeCount,
    required this.onRetry,
    required this.onReturn,
  });
  final bool applied;
  final String phase, detail;
  final int changeCount;
  final VoidCallback? onRetry, onReturn;
  @override
  State<ChapterRepairFailure> createState() => _ChapterRepairFailureState();
}

class _ChapterRepairFailureState extends State<ChapterRepairFailure> {
  bool details = false;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final applied = widget.applied;
    return RepairStateCard(
      title: applied ? '修复已应用，复查未完成' : '修复应用未完成',
      tag: DeskTag(
        applied ? '只需重试复查' : '需要重新检测',
        applied ? Tone.warn : Tone.pen,
      ),
      tone: applied ? Tone.warn : Tone.pen,
      body: applied
          ? '草稿已收到本次修改。重试只执行复查，不再次提交修复。'
          : '本次应用未返回成功。请重新检测当前草稿并核对新方案，不重复提交旧方案。',
      rows: [
        ('修复方案', '${widget.changeCount} 项已生成'),
        ('失败阶段', widget.phase),
        ('原始书稿', '修复操作不覆盖原始文件'),
        ('会话草稿', applied ? '本次修复已提交，保留已提交的修改' : '需要重新检测当前状态'),
        ('变更历史', '不会通过清空历史恢复错误'),
        ('后续处理', applied ? '直接复查当前版本，无需再次确认旧方案' : '重新检测后查看新差异，由你再次确认'),
      ],
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => details = !details),
              icon: Icon(
                details
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded,
                size: 18,
              ),
              label: const Text('查看技术详情'),
            ),
          ),
          if (details)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: d.sunken,
                borderRadius: BorderRadius.circular(7),
              ),
              child: SelectableText(
                widget.detail,
                style: mono(11.5, c: d.ink2),
              ),
            ),
          const SizedBox(height: 6),
          Text('项目文件未因本次修复自动另存；会话草稿与项目文件分别保存。', style: ui(11.5, c: d.ink3)),
        ],
      ),
      actions: [
        DeskButton('返回章节', quiet: true, onPressed: widget.onReturn),
        DeskButton(
          applied ? '重试复查' : '重新检测后重试',
          primary: true,
          icon: Icons.refresh_rounded,
          onPressed: widget.onRetry,
        ),
      ],
    );
  }
}

/// 当前编辑稿结构检查为 0 项（CH-169–172）；只说明本次范围，不代表设备验收。
class ChapterCheckClean extends StatelessWidget {
  const ChapterCheckClean({
    super.key,
    required this.nodeCount,
    required this.onReturn,
    required this.onRefresh,
  });
  final int nodeCount;
  final VoidCallback? onReturn, onRefresh;
  @override
  Widget build(BuildContext context) => RepairStateCard(
    title: '未发现需要处理的章节问题',
    tag: const DeskTag('检测完成', Tone.ok),
    icon: Icons.verified_outlined,
    tone: Tone.ok,
    body:
        '当前检查规则与本次书稿范围内，结果为 0 项。结果与当前书稿版本绑定：修改书稿或检查规则后，需要重新检测。此结果仅表示本次检查未发现问题。',
    rows: [
      ('章节结构', '$nodeCount 个有效结构节点 · 已检查'),
      ('标题识别', '本次规则未报告标题问题 · 无问题'),
      ('章节编号', '按当前规则未发现待核对项 · 无问题'),
      ('正文保护', '检测没有改写原稿 · 只读'),
    ],
    extra: Text(
      '书稿或规则变化后需要重检。结构检查不能替代完整性校对与设备阅读验收。',
      style: ui(11.5, c: context.desk.ink3),
    ),
    actions: [
      DeskButton('重新检测', icon: Icons.refresh_rounded, onPressed: onRefresh),
      DeskButton('返回章节', primary: true, onPressed: onReturn),
    ],
  );
}

/// 复查后的剩余问题：按 50 条一页续读的连续列表，页读取失败可单独重试。
class RepairIssueList extends StatefulWidget {
  const RepairIssueList({
    super.key,
    required this.session,
    required this.structure,
    required this.initial,
    required this.onInspect,
    required this.onEdit,
    this.enabled = true,
  });
  final ChapterSession session;
  final ChapterPage structure;
  final ChapterIssuePage initial;
  final void Function(ChapterIssuePage, ChapterIssue) onInspect;
  final void Function(ChapterIssue) onEdit;
  final bool enabled;
  @override
  State<RepairIssueList> createState() => _RepairIssueListState();
}

class _RepairIssueListState extends State<RepairIssueList> {
  final pages = <int, ChapterIssuePage>{};
  final pending = <int>{};
  final errors = <int, String>{};

  @override
  void initState() {
    super.initState();
    pages[widget.initial.offset] = widget.initial;
  }

  void schedule(int offset) {
    if (pending.length >= 2) return;
    if (!pending.add(offset)) return;
    Future<void>(() async {
      try {
        final page = await widget.session.issues(
          widget.structure,
          offset,
          effective: true,
        );
        if (!mounted) return;
        if (page.total != widget.initial.total ||
            page.offset != offset ||
            page.items.length != (page.total - offset).clamp(0, 50)) {
          throw const FormatException('检查结果已变化，请重新复查。');
        }
        setState(() {
          pages[offset] = page;
          while (pages.length > 3) {
            pages.remove(pages.keys.first);
          }
          errors.remove(offset);
        });
      } catch (error) {
        if (mounted) {
          setState(() => errors[offset] = deskErrorText(error, '操作没有完成。'));
        }
      } finally {
        pending.remove(offset);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    if (widget.initial.total == 0) {
      return Center(
        child: Text('本次章节检查未发现剩余问题', style: ui(13, c: d.ink2)),
      );
    }
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return ListView.builder(
      key: const ValueKey('repair-result-issues'),
      itemCount: widget.initial.total,
      itemExtent: 96 * scale,
      itemBuilder: (_, index) {
        final offset = index ~/ 50 * 50;
        final page = pages.remove(offset);
        if (page != null) pages[offset] = page;
        if (page == null) {
          if (!errors.containsKey(offset)) schedule(offset);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: errors.containsKey(offset) ? d.penSoft : null,
              border: Border(top: BorderSide(color: d.line)),
            ),
            child: errors.containsKey(offset)
                ? Row(
                    children: [
                      Icon(Icons.error_outline_rounded, size: 15, color: d.pen),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          errors[offset]!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: ui(12, c: d.pen),
                        ),
                      ),
                      DeskButton(
                        '重试加载问题',
                        quiet: true,
                        icon: Icons.refresh_rounded,
                        onPressed: () => setState(() {
                          errors.remove(offset);
                        }),
                      ),
                    ],
                  )
                : Center(
                    child: Text('正在读取问题…', style: ui(12, c: d.ink3)),
                  ),
          );
        }
        final issue = page.items[index - offset];
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: d.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Dot(severityTone(d, issue.severity).$1),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      issue.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(12.5, w: 600, c: d.ink),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${issue.categoryLabel} · 待核对',
                    style: ui(11.5, c: d.ink2),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Expanded(
                child: Text(
                  issue.evidence,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ui(12, c: d.ink3, h: 1.45),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '有效文本 ${issue.lines.join('、')} 行',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(11, c: d.ink3),
                    ),
                  ),
                  if (issue.entryId != null)
                    DeskButton(
                      '定位',
                      quiet: true,
                      icon: Icons.my_location_rounded,
                      onPressed: widget.enabled
                          ? () => widget.onEdit(issue)
                          : null,
                    ),
                  const SizedBox(width: 4),
                  DeskButton(
                    '查看依据',
                    quiet: true,
                    onPressed: widget.enabled
                        ? () => widget.onInspect(page, issue)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
