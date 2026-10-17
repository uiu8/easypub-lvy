// 原稿与清理后按同一原稿范围对齐（CLEAN-036–038）：每页 30 个对应范围；截断的范围可打开完整对照。
// V15：改动范围只标出前后不同的那一段；改动的是空白时，只给这一段加空白标记（CLEAN-100）。
// 逻辑沿用 V4 前的 CleanupPairedContext。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/cleanup_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';
import 'inline_diff.dart';
import 'region_dialog.dart';

class CleanupPairedContext extends StatefulWidget {
  const CleanupPairedContext({
    super.key,
    required this.session,
    required this.preview,
    required this.change,
    required this.showWhitespace,
  });
  final PairedCleanupContextSession session;
  final CleanupPreview preview;
  final CleanupChange change;
  final bool showWhitespace;
  @override
  State<CleanupPairedContext> createState() => _CleanupPairedContextState();
}

class _CleanupPairedContextState extends State<CleanupPairedContext> {
  Map<String, dynamic>? page;
  String error = '';
  bool busy = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load(0);
  }

  Future<void> load(int offset) async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final next = await widget.session.pairedContext(
        widget.preview,
        widget.change,
        offset: offset,
      );
      if (mounted && generation == ticket) setState(() => page = next);
    } catch (e) {
      if (mounted && generation == ticket) {
        setState(() => error = deskErrorText(e, '无法读取清理对照，请重新预览。'));
      }
    } finally {
      if (mounted && generation == ticket) setState(() => busy = false);
    }
  }

  String visible(String text) {
    if (text.trim().isEmpty) return '（空行）';
    return widget.showWhitespace
        ? text
              .replaceAll(' ', '·')
              .replaceAll('\t', '⇥')
              .replaceAll('\n', '↵\n')
        : text;
  }

  /// 对照的一格。改动的范围只标出前后不同的那一段（CLEAN-100），整格不再着色，
  /// 左侧色条表示这一范围有改动；只改了空白时自动显示空白标记。
  Widget cell(
    String label,
    String? text,
    bool selected,
    bool after, {
    String? other,
  }) {
    final d = context.desk;
    final changed = selected;
    final tone = after ? d.add : d.del;
    final base = serif(14, c: text == null ? d.ink3 : d.ink, h: 1.7);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          border: Border(
            left: changed
                ? BorderSide(color: tone.withValues(alpha: .55), width: 2.5)
                : after
                ? BorderSide(color: d.line)
                : BorderSide.none,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: mono(10.5, c: d.ink3)),
            const SizedBox(height: 4),
            if (text == null ||
                !changed ||
                other == null ||
                text.trim().isEmpty)
              SelectableText(
                text == null ? '（已删除）' : visible(text),
                style: base,
              )
            else
              SelectableText.rich(
                inlineDiffSpan(
                  text,
                  other,
                  base: base,
                  changed: base.copyWith(
                    color: tone,
                    backgroundColor: after ? d.addSoft : d.delSoft,
                  ),
                  marks: widget.showWhitespace,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('原稿与清理后 · 按同一原稿范围对齐', style: ui(12, w: 600, c: d.ink2)),
        const SizedBox(height: 6),
        SizedBox(
          height: 2,
          child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        if (error.isNotEmpty)
          Expanded(
            child: Center(
              child: DeskNote(error, title: '对照不可用', tone: Tone.pen),
            ),
          )
        else
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: d.paper,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: d.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListView.builder(
                key: ValueKey('cleanup-context-${page?['offset'] ?? 0}'),
                itemCount: (page?['rows'] as List?)?.length ?? 0,
                itemBuilder: (_, i) {
                  final row = (page!['rows'] as List)[i] as Map;
                  final merged =
                      row['source_end_line'] != row['source_line'] &&
                      row['output_line'] == row['output_end_line'] &&
                      row['after'] != null;
                  return Container(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: d.line)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (row['truncated'] == true)
                          Align(
                            alignment: Alignment.centerRight,
                            child: DeskButton(
                              '查看完整范围',
                              quiet: true,
                              onPressed: busy
                                  ? null
                                  : () => showDialog<void>(
                                      context: context,
                                      builder: (_) => CleanupRegionDialog(
                                        session: widget.session,
                                        preview: widget.preview,
                                        change: widget.change,
                                        regionLine: row['source_line'] as int,
                                        showWhitespace: widget.showWhitespace,
                                      ),
                                    ),
                            ),
                          ),
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              cell(
                                '原稿 ${row['source_line']}—${row['source_end_line']} 行',
                                row['before'] as String,
                                row['selected'] == true,
                                false,
                                other: row['after'] as String? ?? '',
                              ),
                              cell(
                                row['after'] == null
                                    ? '清理后 · 删除'
                                    : '清理后 ${row['output_line']}—${row['output_end_line']} 行${merged ? ' · 合并' : ''}',
                                row['after'] as String?,
                                row['selected'] == true,
                                true,
                                other: row['before'] as String,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        if (page != null)
          Row(
            children: [
              DeskButton(
                '上段对照',
                quiet: true,
                icon: Icons.keyboard_arrow_up_rounded,
                onPressed: busy || (page!['offset'] as int) == 0
                    ? null
                    : () => load(
                        ((page!['offset'] as int) - 30).clamp(
                          0,
                          page!['total'] as int,
                        ),
                      ),
              ),
              const Spacer(),
              Text('${page!['total']} 个对应范围', style: ui(11.5, c: d.ink3)),
              const Spacer(),
              DeskButton(
                '下段对照',
                quiet: true,
                icon: Icons.keyboard_arrow_down_rounded,
                onPressed: busy || page!['has_more'] != true
                    ? null
                    : () => load((page!['offset'] as int) + 30),
              ),
            ],
          ),
      ],
    );
  }
}
