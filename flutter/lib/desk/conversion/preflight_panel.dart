// 转换前检查（D4-F，V8 按设计重写视图）：分组、逐项选择、提醒确认与阻止弹窗逻辑沿用原实现。
import 'package:flutter/material.dart';

import '../dialogs.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/conversion_service.dart';
import '../controls/controls.dart';

class PreflightPanel extends StatefulWidget {
  const PreflightPanel({
    super.key,
    required this.plan,
    required this.current,
    required this.onBack,
    required this.openRepair,
  });
  final ConversionPreview plan;
  final bool current;
  final VoidCallback onBack;
  final void Function(String, String) openRepair;
  @override
  State<PreflightPanel> createState() => _PreflightPanelState();
}

class _PreflightPanelState extends State<PreflightPanel> {
  ConversionFinding? selected;
  bool warningsOnly = false, detailsExpanded = false;
  ConversionFinding? initialFinding() =>
      widget.plan.findings.where((f) => f.level == 'blocking').firstOrNull ??
      widget.plan.findings.where((f) => f.level == 'warning').firstOrNull;
  @override
  void initState() {
    super.initState();
    selected = initialFinding();
  }

  @override
  void didUpdateWidget(PreflightPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.plan, widget.plan)) {
      selected = initialFinding();
      warningsOnly = false;
      detailsExpanded = false;
    }
  }

  Tone toneOf(String level) => switch (level) {
    'blocking' => Tone.pen,
    'warning' => Tone.warn,
    'pass' => Tone.ok,
    _ => Tone.neutral,
  };

  int count(String level) =>
      widget.plan.findings.where((f) => f.level == level).length;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final plan = widget.plan;
    final groups = plan.groups
        .where((g) => !warningsOnly || g.items.any((f) => f.level == 'warning'))
        .toList();
    return DeskCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('转换前检查', style: ui(14, w: 650, c: d.ink)),
                DeskTag('通过 ${count('pass')}', Tone.ok),
                DeskTag('提醒 ${count('warning')}', Tone.warn),
                DeskTag('阻止 ${count('blocking')}', Tone.pen),
                if (plan.needsAcknowledgement) ...[
                  DeskButton(
                    warningsOnly ? '查看全部检查' : '查看 ${count('warning')} 项提醒',
                    quiet: true,
                    onPressed: () => setState(() {
                      warningsOnly = !warningsOnly;
                      detailsExpanded = warningsOnly;
                      selected = warningsOnly
                          ? plan.findings
                                .where((f) => f.level == 'warning')
                                .firstOrNull
                          : initialFinding();
                    }),
                  ),
                  DeskTag(widget.current ? '可保留并转换' : '需要重新生成输出计划', Tone.warn),
                ],
              ],
            ),
          ),
          if (!widget.current)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: DeskNote(
                '书稿已变化，请返回设置重新检查。',
                title: '检查结果已失效',
                tone: Tone.warn,
              ),
            ),
          Divider(height: 1, color: d.line),
          Expanded(
            child: ListView.builder(
              itemCount: groups.length,
              itemBuilder: (context, index) => groupRow(context, groups[index]),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: d.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '自动检查不会悄悄删除正文、补章或改变阅读顺序。启动前再次核对书稿版本；源文件或设置变化后需重新生成输出计划。',
                    style: ui(11.5, c: d.ink3, h: 1.5),
                  ),
                ),
                const SizedBox(width: 8),
                DeskButton('返回设置', onPressed: widget.onBack, quiet: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget groupRow(BuildContext context, ConversionCheckGroup group) {
    final d = context.desk;
    final plan = widget.plan;
    final finding = group.primary;
    final bookCount = group.items.map((f) => f.bookId).toSet().length;
    final formats = plan.outputs
        .map((o) => o.format)
        .where((f) => f.isNotEmpty)
        .toSet();
    final scope = group.key == 'destination' && plan.outputs.isNotEmpty
        ? '${plan.outputs.length} 个成品'
        : group.key == 'converter' && formats.isNotEmpty
        ? formats.join(' / ')
        : bookCount > 1
        ? '$bookCount 本'
        : plan.bookTitle(finding.bookId);
    final tone = toneOf(finding.level);
    final open = group.items.contains(selected);
    final result = switch (finding.level) {
      'pass' => '通过',
      'warning' =>
        '${group.items.where((f) => f.level == 'warning').length} 项提醒',
      'blocking' => '必须处理',
      _ => '提示',
    };
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: open ? d.sunken : Colors.transparent,
            child: InkWell(
              onTap: () => setState(() {
                selected = finding;
                detailsExpanded = true;
              }),
              child: Container(
                constraints: const BoxConstraints(minHeight: 46),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    // 状态色条：必须处理朱、提醒赭、通过苔（与问题队列同一写法）。
                    DeskStripe(
                      tone == Tone.neutral ? d.lineStrong : d.tone(tone).$1,
                      height: 28,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 3,
                      child: Text(
                        group.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ui(13, w: 600, c: d.ink),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        scope,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(12, c: d.ink3),
                      ),
                    ),
                    DeskTag(result, tone),
                    const SizedBox(width: 4),
                    Icon(
                      open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: d.ink3,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open) details(context, group),
        ],
      ),
    );
  }

  Widget details(BuildContext context, ConversionCheckGroup group) {
    final plan = widget.plan;
    final finding = selected!;
    final summary = !detailsExpanded && group.items.length > 1;
    final tone = toneOf(finding.level);
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (detailsExpanded && group.items.length > 1) ...[
            DeskChoice<ConversionFinding>(
              key: ValueKey(selected),
              initialValue: selected,
              isExpanded: true,
              items: [
                for (final (index, item) in group.items.indexed)
                  DropdownMenuItem(
                    value: item,
                    child: Text(
                      '${plan.bookTitle(item.bookId)} · ${item.title}'
                      '${group.items.where((other) => other.bookId == item.bookId && other.title == item.title).length > 1 ? ' · 第 ${index + 1} 项' : ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => selected = value),
            ),
            const SizedBox(height: 8),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 130),
            child: SingleChildScrollView(
              child: DeskNote(
                summary
                    ? finding.level == 'warning'
                          ? '点击检查项可逐项查看证据和修复入口。建议核对提醒；不会自动补章、删除正文或调整顺序。'
                          : '点击检查项可逐项查看本组各书的检查结果与证据。'
                    : finding.detail,
                title: summary
                    ? '${group.title} · ${group.items.where((f) => f.level == finding.level).length} ${finding.level == 'warning' ? '项提醒' : '项检查'}'
                    : finding.title,
                tone: tone == Tone.ok ? Tone.neutral : tone,
              ),
            ),
          ),
          if (finding.repairPage != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: DeskButton(
                '前往处理',
                icon: Icons.arrow_forward_rounded,
                onPressed: () =>
                    widget.openRepair(finding.bookId, finding.repairPage!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PreflightBlockedDialog extends StatelessWidget {
  const PreflightBlockedDialog({
    super.key,
    required this.plan,
    required this.openRepair,
  });
  final ConversionPreview plan;
  final void Function(String, String) openRepair;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final issues = [
      ...plan.findings.where((f) => f.level == 'blocking'),
      ...plan.findings.where((f) => f.level == 'warning'),
    ];
    return DeskDialog(
      title: '转换前检查 · 需要处理',
      closeTooltip: '关闭',
      width: 680,
      height: 540,
      onClose: () => Navigator.pop(context, false),
      footerLeft: Text('自动检查不会悄悄删除正文、补章或改变阅读顺序。', style: ui(12, c: d.ink3)),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: () => Navigator.pop(context, false),
        ),
        DeskButton(
          '重新检查',
          primary: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeskNote(
            '本批次尚未开始，不会留下不完整成品。',
            title:
                '有 ${issues.where((f) => f.level == 'blocking').length} 个问题阻止转换',
            tone: Tone.pen,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: issues.length,
              itemBuilder: (context, index) {
                final issue = issues[index];
                final title = plan.bookTitle(issue.bookId);
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: index < issues.length - 1
                        ? Border(bottom: BorderSide(color: d.line))
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            issue.isCoverIssue
                                ? Icons.image_outlined
                                : issue.level == 'blocking'
                                ? Icons.error_outline_rounded
                                : Icons.format_list_numbered,
                            size: 18,
                            color: d.ink2,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  issue.title,
                                  style: ui(13, w: 600, c: d.ink),
                                ),
                                Text(
                                  '$title · ${issue.detail}',
                                  style: ui(12, c: d.ink3, h: 1.5),
                                ),
                              ],
                            ),
                          ),
                          if (issue.level == 'blocking')
                            const DeskTag('必须处理', Tone.pen),
                        ],
                      ),
                      if (issue.isCoverIssue)
                        Padding(
                          padding: const EdgeInsets.only(top: 10, left: 30),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              DeskButton(
                                '重新选择封面',
                                onPressed: () =>
                                    openRepair(issue.bookId, 'cover-select'),
                              ),
                              DeskButton(
                                '生成文字封面',
                                onPressed: () =>
                                    openRepair(issue.bookId, 'cover-generate'),
                              ),
                            ],
                          ),
                        )
                      else if (issue.level == 'blocking' &&
                          issue.repairPage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10, left: 30),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: DeskButton(
                              '前往处理',
                              key: ValueKey(
                                'blocked-repair-${issue.bookId}-${issue.title}',
                              ),
                              onPressed: () =>
                                  openRepair(issue.bookId, issue.repairPage!),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
