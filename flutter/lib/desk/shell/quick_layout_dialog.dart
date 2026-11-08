import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/book_information_service.dart';
import '../../application/layout_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../layout/batch_field_dialog.dart'
    show batchFieldLabels, describeBatchValue;
import '../tokens.dart';

// 快速排版（G-032–034；R1 改用编辑台弹窗）：列出出厂默认、本项目、全局预设，每个预设显示要点；
// 点选后先列出与本书当前排版的不同，确认后才应用（走正常的排版事务，可在历史里回退）。
// 预设读取中也可以关闭；只有应用时不能关闭。

/// Applies an existing preset to the named book through the normal layout transaction.
class QuickLayoutDialog extends StatefulWidget {
  const QuickLayoutDialog({
    super.key,
    required this.library,
    required this.book,
  });
  final LibraryService library;
  final BookSummary book;
  @override
  State<QuickLayoutDialog> createState() => _QuickLayoutDialogState();
}

typedef _Entry = ({String group, LayoutPreset preset});

class _QuickLayoutDialogState extends State<QuickLayoutDialog> {
  late final session = widget.library.openLayout(widget.book.id);
  final entries = <_Entry>[];
  bool loading = true, applying = false, previewing = false;
  String message = '';

  /// 选中的预设与它相对本书当前排版的预览；为 null 时显示预设列表。
  _Entry? chosen;
  BookInformationPreview? plan;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      entries.add((group: '出厂默认', preset: await session.builtinPreset()));
      entries.addAll(session.presets.map((p) => (group: '本项目预设', preset: p)));
      entries.addAll(
        (await session.readGlobalPresets()).map(
          (p) => (group: '全局预设', preset: p),
        ),
      );
    } catch (e) {
      message = deskErrorText(e, '没能读取排版预设，本书排版没有改动。可以重新打开这个窗口，或到“排版”页的预设库查看。');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> choose(_Entry entry) async {
    setState(() {
      chosen = entry;
      plan = null;
      previewing = true;
      message = '';
    });
    try {
      final next = entry.group == '本项目预设'
          ? await session.previewPreset(entry.preset.name)
          : await session.preview(
              Map.fromEntries(
                entry.preset.values.entries.where(
                  (e) => layoutFields.contains(e.key),
                ),
              ),
            );
      if (mounted && chosen == entry) setState(() => plan = next);
    } catch (e) {
      if (mounted) {
        setState(() {
          chosen = null;
          message = deskErrorText(
            e,
            '没能比较这个预设与本书当前排版，本书排版没有改动。可以换一个预设，或到“排版”页手动调整。',
          );
        });
      }
    }
    if (mounted) setState(() => previewing = false);
  }

  Future<void> apply() async {
    final entry = chosen, next = plan;
    if (entry == null || next == null) return;
    setState(() {
      applying = true;
      message = '';
    });
    try {
      await session.apply(next);
      if (mounted) {
        Navigator.pop(
          context,
          entry.group == '出厂默认' ? '出厂默认排版' : entry.preset.name,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          applying = false;
          message = deskErrorText(e, '排版没有应用，本书排版保持不变。可以再试一次，或到“排版”页手动调整。');
        });
      }
    }
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  String entryName(_Entry e) => e.group == '出厂默认' ? '出厂默认排版' : e.preset.name;

  /// 预设要点：字号、行距、段首空格、标题样式。
  String summary(LayoutPreset preset) {
    final v = preset.values;
    final size = v['font_size'];
    final unit = v['font_size_unit'] == '%' ? '%' : 'px';
    return [
      if (size is num) '字号 ${_num(size)}$unit',
      if (v['line_height'] is num) '行距 ${_num(v['line_height'] as num)}',
      if (v['fullwidth_indent'] is num)
        (v['fullwidth_indent'] as num) == 0
            ? '段首不空格'
            : '段首 ${(v['fullwidth_indent'] as num).toInt()} 个全角空格',
      if (v['heading_style'] is String)
        '标题：${headingStyles[v['heading_style']] ?? v['heading_style']}',
    ].join(' · ');
  }

  static String _num(num value) =>
      value == value.roundToDouble() ? '${value.toInt()}' : '$value';

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final entry = chosen;
    return DeskDialog(
      title: entry == null ? '选择排版' : '应用“${entryName(entry)}”',
      subtitle: '只应用到《${widget.book.title}》，其他书保持各自的排版。',
      closeTooltip: '关闭',
      width: 560,
      busy: applying,
      actions: entry == null
          ? const []
          : [
              DeskButton(
                '返回',
                key: const ValueKey('quick-layout-back'),
                quiet: true,
                onPressed: applying
                    ? null
                    : () => setState(() {
                        chosen = null;
                        plan = null;
                      }),
              ),
              DeskButton(
                '应用到本书',
                key: const ValueKey('quick-layout-apply'),
                primary: true,
                onPressed:
                    applying ||
                        plan == null ||
                        !plan!.changed.any(batchFieldLabels.containsKey)
                    ? null
                    : apply,
              ),
            ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message.isNotEmpty) ...[
            DeskNote(message, tone: Tone.pen),
            const SizedBox(height: 10),
          ],
          if (entry == null) ...presetList(d) else ...difference(d),
        ],
      ),
    );
  }

  List<Widget> presetList(Desk d) {
    if (loading) {
      // 读取中显示占位行，窗口可以随时关闭。
      return [
        for (var i = 0; i < 3; i++)
          Container(
            height: 52,
            margin: const EdgeInsets.only(bottom: 4),
            decoration: BoxDecoration(
              color: d.sunken,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
      ];
    }
    final rows = <Widget>[];
    String? group;
    for (final e in entries) {
      if (e.group != group) {
        group = e.group;
        rows.add(
          Padding(
            padding: EdgeInsets.fromLTRB(4, rows.isEmpty ? 0 : 10, 4, 4),
            child: Text(group, style: ui(11.5, w: 650, c: d.ink3)),
          ),
        );
      }
      rows.add(
        Material(
          key: ValueKey('quick-layout-${e.group}-${e.preset.name}'),
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => choose(e),
            hoverColor: d.sunken,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  Icon(Icons.text_fields_rounded, size: 18, color: d.ink2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entryName(e), style: ui(13.5, w: 600, c: d.ink)),
                        const SizedBox(height: 2),
                        Text(
                          summary(e.preset),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(12, c: d.ink2),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18, color: d.ink3),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (entries.length == 1) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            '还没有自己的预设：在“排版”页调好后点“另存为预设”，就会出现在这里。',
            style: ui(12, c: d.ink3),
          ),
        ),
      );
    }
    return rows;
  }

  List<Widget> difference(Desk d) {
    final next = plan;
    if (previewing || next == null) {
      return [
        Container(
          height: 80,
          alignment: Alignment.center,
          child: Text('正在比较…', style: ui(12.5, c: d.ink2)),
        ),
      ];
    }
    // 只列用户看得到的排版字段；设置来源（layout_origins）等内部记录不列出。
    final changed = [
      for (final f in next.changed)
        if (batchFieldLabels.containsKey(f)) f,
    ];
    if (changed.isEmpty) {
      return [DeskNote('这个预设与本书当前的排版相同，不需要应用。')];
    }
    const limit = 12;
    return [
      Text('将改动 ${changed.length} 项：', style: ui(12.5, w: 600, c: d.ink)),
      const SizedBox(height: 6),
      for (final field in changed.take(limit))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: Text(
                  batchFieldLabels[field] ?? field,
                  style: ui(12.5, c: d.ink2),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: describeBatchValue(field, next.before[field]),
                        style: ui(12.5, c: d.ink3),
                      ),
                      TextSpan(
                        text: '  →  ',
                        style: ui(12.5, c: d.ink3),
                      ),
                      TextSpan(
                        text: describeBatchValue(field, next.after[field]),
                        style: ui(12.5, w: 600, c: d.ink),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      if (changed.length > limit)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '…另有 ${changed.length - limit} 项',
            style: ui(12, c: d.ink3),
          ),
        ),
      const SizedBox(height: 8),
      Text('应用后会记入“记录”，可以在那里撤销。', style: ui(12, c: d.ink3)),
    ];
  }
}
