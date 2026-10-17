// 修复方案影响（设计 D2 修复方案“目录节点 A → B / 预计减少问题”）：
// 对当前编辑稿与候选编辑稿各运行一次只读检查，显示真实的前后数量；会话不支持时不显示。
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import '../tokens.dart';

class RepairImpactLine extends StatefulWidget {
  const RepairImpactLine({
    super.key,
    required this.session,
    required this.plan,
  });
  final ChapterSession session;
  final ChapterRepairPlan plan;
  @override
  State<RepairImpactLine> createState() => _RepairImpactLineState();
}

class _RepairImpactLineState extends State<RepairImpactLine> {
  Future<ChapterRepairImpact>? impact;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RepairImpactLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.plan, widget.plan)) _load();
  }

  void _load() {
    final session = widget.session;
    impact = session is ChapterRepairImpactSession
        ? (session as ChapterRepairImpactSession).repairImpact(widget.plan)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    if (impact == null) return const SizedBox.shrink();
    return FutureBuilder<ChapterRepairImpact>(
      future: impact,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('影响统计读取失败，不影响预览与应用。', style: ui(11.5, c: d.ink3));
        }
        final value = snapshot.data;
        if (value == null) {
          return Text('正在计算应用后的目录与问题数…', style: ui(11.5, c: d.ink3));
        }
        Widget stat(String label, String text, {Color? color}) => Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: ui(11.5, c: d.ink3)),
              Text(text, style: ui(15, w: 650, c: color ?? d.ink)),
            ],
          ),
        );
        final resolved = value.resolved;
        return Wrap(
          key: const ValueKey('repair-impact'),
          runSpacing: 6,
          children: [
            stat('目录节点', '${value.nodesBefore} → ${value.nodesAfter}'),
            stat('待处理问题', '${value.openBefore} → ${value.openAfter}'),
            stat(
              resolved >= 0 ? '应用后减少问题' : '应用后新增问题',
              resolved >= 0 ? '−$resolved' : '+${-resolved}',
              color: resolved >= 0 ? d.tone(Tone.ok).$1 : d.tone(Tone.warn).$1,
            ),
          ],
        );
      },
    );
  }
}
