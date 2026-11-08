// 完整范围 / 完整步骤对照（CLEAN-035、CLEAN-039–041）：两侧各自按 2000 字符分段读取，
// 字符位置不表示逐字对应。逻辑沿用 V4 前的 CleanupRegionDialog。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/cleanup_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../tokens.dart';

class CleanupRegionDialog extends StatefulWidget {
  const CleanupRegionDialog({
    super.key,
    required this.session,
    required this.preview,
    required this.change,
    required this.regionLine,
    required this.showWhitespace,
    this.stage = false,
  });
  final PairedCleanupContextSession session;
  final CleanupPreview preview;
  final CleanupChange change;
  final int regionLine;
  final bool showWhitespace;
  final bool stage;
  @override
  State<CleanupRegionDialog> createState() => _CleanupRegionDialogState();
}

class _CleanupRegionDialogState extends State<CleanupRegionDialog> {
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
        regionLine: widget.regionLine,
        stage: widget.stage,
        charOffset: offset,
      );
      if (mounted && ticket == generation) setState(() => page = next);
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() => error = deskErrorText(e, '读取失败，请重新预览。'));
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Widget side(String label, String key, String totalKey, bool after) {
    final d = context.desk;
    final text = page?[key] as String?;
    final offset = page?['char_offset'] as int? ?? 0;
    final total = page?[totalKey] as int? ?? 0;
    final shown = text == null
        ? '（已删除）'
        : offset >= total
        ? '（本侧已结束）'
        : text.trim().isEmpty
        ? '（空白字符）'
        : widget.showWhitespace
        ? text
              .replaceAll(' ', '·')
              .replaceAll('\t', '⇥')
              .replaceAll('\r', '␍')
              .replaceAll('\n', '↵\n')
        : text;
    final (fg, bg) = after ? (d.add, d.addSoft) : (d.del, d.delSoft);
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: d.paper,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: d.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                text == null
                    ? '$label · 已删除'
                    : offset >= total
                    ? '$label · 已读完，共 $total 字符'
                    : '$label · ${offset + 1}—${(offset + 2000).clamp(0, total)} / $total 字符',
                style: ui(11.5, w: 600, c: fg),
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              shown,
              key: ValueKey('cleanup-region-$key'),
              style: serif(14, c: d.ink, h: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: widget.stage ? '规则 ${widget.change.step + 1} · 完整步骤对照' : '完整范围对照',
      subtitle:
          '${widget.stage ? '对应原稿 ${widget.change.line}—${widget.change.end} 行，本步结果不等于最终结果。' : '原稿第 ${widget.regionLine} 行起。'} 两侧独立按字符分段，字符位置不表示逐字对应。',
      closeTooltip: '关闭完整对照',
      width: 1000,
      height: 680,
      footerLeft: Text(
        '第 ${(page?['char_offset'] as int? ?? 0) ~/ 2000 + 1} 段',
        style: ui(12, c: d.ink3),
      ),
      actions: [
        DeskButton(
          '前一段',
          quiet: true,
          icon: Icons.chevron_left_rounded,
          onPressed:
              busy ||
                  error.isNotEmpty ||
                  page == null ||
                  page!['char_offset'] == 0
              ? null
              : () => load((page!['char_offset'] as int) - 2000),
        ),
        DeskButton(
          '后一段',
          quiet: true,
          icon: Icons.chevron_right_rounded,
          onPressed: busy || error.isNotEmpty || page?['has_more'] != true
              ? null
              : () => load(page!['next_offset'] as int),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 2,
            child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(
            child: error.isNotEmpty
                ? Center(
                    child: DeskNote(error, title: '对照不可用', tone: Tone.pen),
                  )
                : page == null
                ? Center(
                    child: Text('正在读取…', style: ui(12.5, c: d.ink2)),
                  )
                : SingleChildScrollView(
                    key: ValueKey(page!['char_offset']),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        side(
                          widget.stage ? '步骤前' : '原稿',
                          'before',
                          'before_total',
                          false,
                        ),
                        side(
                          widget.stage ? '步骤后' : '清理后',
                          'after',
                          'after_total',
                          true,
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
