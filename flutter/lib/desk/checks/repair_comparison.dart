// 修复对照（CHK-046、CHK-048、CHK-049）：未发布候选与其前一版本逐段对照。
// 首次读取失败显示“重试对照”；续读失败只重读失败一侧（“重试后续内容”），已读内容保留。
// 首次读取成功后才回调 onReady，调用方据此放开“应用修改”。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/chapter_service.dart';
import '../dialogs.dart';
import '../tokens.dart';
import 'comparison.dart';

class RepairComparisonView extends StatefulWidget {
  const RepairComparisonView({
    super.key,
    required this.session,
    required this.plan,
    required this.change,
    required this.onReady,
  });
  final ChapterRepairComparisonSession session;
  final ChapterRepairPlan plan;
  final ChapterRepairChange change;
  final VoidCallback onReady;
  @override
  State<RepairComparisonView> createState() => _RepairComparisonViewState();
}

class _RepairComparisonViewState extends State<RepairComparisonView> {
  final rows = [<ChapterContextRow>[], <ChapterContextRow>[]];
  final loading = [false, false];
  final sides = <ChapterComparisonSide?>[null, null];
  ChapterRepairComparison? comparison;
  String error = '';
  int? failedSide;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load([int? side]) async {
    if (side != null && loading[side]) return;
    setState(() {
      error = '';
      if (side == null) {
        loading[0] = true;
        loading[1] = true;
      } else {
        loading[side] = true;
      }
    });
    try {
      final next = await widget.session.previewComparison(
        widget.plan,
        widget.change,
        beforeOffset: side == 0 ? sides[0]!.nextOffset! : 0,
        afterOffset: side == 1 ? sides[1]!.nextOffset! : 0,
        beforeCharOffset: side == 0 ? sides[0]!.nextCharOffset : 0,
        afterCharOffset: side == 1 ? sides[1]!.nextCharOffset : 0,
      );
      if (!mounted) return;
      setState(() {
        comparison = next;
        if (side == null) {
          rows[0].clear();
          rows[1].clear();
        }
        if (side == null || side == 0) append(0, next.before);
        if (side == null || side == 1) append(1, next.after);
      });
      widget.onReady();
    } catch (e) {
      if (mounted) {
        setState(() {
          failedSide = side;
          error = deskErrorText(e, '无法读取修改对照，请重新生成方案。');
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          if (side == null) {
            loading[0] = false;
            loading[1] = false;
          } else {
            loading[side] = false;
          }
        });
      }
    }
  }

  /// 同一行的续段合并回一行，不把长段落切成看不懂的几段。
  void append(int side, ChapterComparisonSide data) {
    sides[side] = data;
    for (final row in data.rows) {
      if (row.line != null &&
          rows[side].isNotEmpty &&
          rows[side].last.line == row.line) {
        final previous = rows[side].removeLast();
        rows[side].add(
          ChapterContextRow(
            previous.text + row.text,
            line: row.line,
            originalLine: row.originalLine,
            anchor: row.anchor,
            truncated: row.truncated,
          ),
        );
      } else {
        rows[side].add(row);
      }
    }
  }

  Widget retry(String message, String label, VoidCallback onPressed) => Row(
    children: [
      Expanded(child: DeskNote(message, tone: Tone.pen)),
      const SizedBox(width: 6),
      TextButton(onPressed: onPressed, child: Text(label)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final value = comparison;
    if (value == null) {
      return error.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: retry('对照读取失败：$error', '重试对照', load),
              ),
            );
    }
    ComparisonContent content(int side, ChapterComparisonSide data) =>
        ComparisonContent(
          label: side == 0
              ? '修改前'
              : value.retainedCopy
              ? '修改后 · 保留内容'
              : '修改后',
          title: data.title,
          nodes: data.nodes,
          rows: rows[side],
          focusLine: data.focusLine,
          loading: loading[side],
          onMore: data.nextOffset != null && error.isEmpty
              ? () => load(side)
              : null,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: retry('后续内容读取失败：$error', '重试后续内容', () => load(failedSide)),
          ),
        Expanded(
          child: ComparisonWorkspace(
            versions: true,
            left: content(0, sides[0]!),
            right: content(1, sides[1]!),
          ),
        ),
      ],
    );
  }
}
