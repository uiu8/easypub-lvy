// 转换历史（D4-G，V8 按设计重写视图）：分页、核验、事务恢复预览与确认逻辑沿用原实现。
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;

import '../errors.dart';

import '../dialogs.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/output_history_service.dart';
import '../../application/conversion_desktop.dart';
import '../controls/controls.dart';

class OutputHistoryPage extends StatefulWidget {
  const OutputHistoryPage({
    super.key,
    required this.history,
    required this.desktop,
    required this.onBack,
    this.onOpenBook,
  });
  final OutputHistoryService history;
  final ConversionDesktop desktop;
  final VoidCallback onBack;

  /// 在书库中查看这条记录对应的书（OUT-076）；为 null 时不显示入口。
  final void Function(String bookId)? onOpenBook;
  @override
  State<OutputHistoryPage> createState() => _OutputHistoryPageState();
}

class _OutputHistoryPageState extends State<OutputHistoryPage> {
  bool loading = true;
  int offset = 0;
  String? selected;
  String message = '';
  bool recovering = false;
  int loadGeneration = 0;
  Future<void> recover(String id) async {
    if (recovering) return;
    setState(() => recovering = true);
    final history = widget.history;
    OutputRecoveryPreview? plan;
    try {
      plan = await history.previewRecovery(id);
      if (!mounted) return;
      final preview = plan;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          final d = context.desk;
          return DeskDialog(
            title: '恢复输出事务',
            subtitle: preview.publishesStaged ? '发布已核验的暂存成品' : '补齐已发布成品的完成记录',
            closeTooltip: '取消',
            width: 600,
            onClose: () => Navigator.pop(context, false),
            actions: [
              DeskButton(
                '取消',
                quiet: true,
                onPressed: () => Navigator.pop(context, false),
              ),
              DeskButton(
                '确认恢复',
                primary: true,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const DeskLabel('成品'),
                SelectableText(
                  paths.normalize(preview.outputPath),
                  style: mono(11.5, c: d.ink),
                ),
                const SizedBox(height: 10),
                const DeskLabel('事务依据'),
                SelectableText(
                  preview.transactionDirectory,
                  style: mono(11.5, c: d.ink2),
                ),
                const SizedBox(height: 12),
                const DeskNote('确认时重新核对原稿、备份、事务证据与成品。不重新运行转换器，不覆盖不同内容的文件。'),
              ],
            ),
          );
        },
      );
      if (confirmed == true && mounted) {
        await history.recover(plan);
        // Recovery may be persisted without notifying the current service;
        // reload so the row leaves the interrupted state immediately.
        await history.load();
        if (mounted) setState(() => selected = id);
      }
    } catch (e) {
      if (mounted) {
        setState(() => message = deskErrorText(e, '无法恢复，请重新核对成品和事务文件。'));
      }
    } finally {
      if (plan != null) history.cancelRecovery(plan);
      if (mounted) setState(() => recovering = false);
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(OutputHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.history, widget.history)) {
      offset = 0;
      selected = null;
      load();
    }
  }

  Future<void> load() async {
    final ticket = ++loadGeneration;
    final history = widget.history;
    setState(() {
      loading = true;
      message = '';
    });
    try {
      await history.load();
    } catch (_) {
      if (mounted && ticket == loadGeneration) {
        setState(() => message = '无法读取转换历史，请重试。');
      }
    } finally {
      if (mounted && ticket == loadGeneration) setState(() => loading = false);
    }
  }

  Future<void> act(Future<void> Function() action) async {
    setState(() => message = '');
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => message = deskErrorText(e, '操作未完成，请检查记录或文件路径。'));
      }
    }
  }

  String time(DateTime value) => value.toLocal().toString().substring(0, 16);

  Tone toneOf(OutputRecord row) => row.interrupted
      ? Tone.warn
      : row.status.contains('失败')
      ? Tone.pen
      : row.status.contains('完成')
      ? Tone.ok
      : Tone.neutral;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.history.changes,
    builder: (context, _) {
      final d = context.desk;
      final count = widget.history.count;
      // A refreshed history can shrink while the user is on its last page.
      if (offset >= count) offset = count == 0 ? 0 : ((count - 1) ~/ 50) * 50;
      final rows = widget.history.page(offset);
      final current =
          rows.where((r) => r.id == selected).firstOrNull ?? rows.firstOrNull;
      return DeskPageFrame(
        header: DeskPageHeader(
          title: '转换历史',
          subtitle: '转换记录 ${widget.history.count} 条 · 每页 50 条',
          actions: [
            DeskButton(
              '返回本次任务',
              quiet: true,
              icon: Icons.arrow_back_rounded,
              onPressed: widget.onBack,
            ),
            DeskButton(
              '刷新记录',
              icon: Icons.refresh_rounded,
              quiet: true,
              onPressed: loading || recovering ? null : load,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: DeskInfoBar(message, tone: Tone.warn),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 6, child: list(context, rows, current)),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 5,
                      child: DeskCard(
                        child: current == null
                            ? Center(
                                child: Text(
                                  '选择记录查看成品信息',
                                  style: ui(12.5, c: d.ink3),
                                ),
                              )
                            : detail(context, current),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget list(
    BuildContext context,
    List<OutputRecord> rows,
    OutputRecord? current,
  ) {
    final d = context.desk;
    return DeskCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Row(
              children: const [
                SizedBox(width: 128, child: DeskColumnLabel('时间')),
                Expanded(child: DeskColumnLabel('书稿 / 格式')),
                DeskColumnLabel('记录状态'),
              ],
            ),
          ),
          Divider(height: 1, color: d.line),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : rows.isEmpty
                ? Center(
                    child: Text('暂无转换记录', style: ui(12.5, c: d.ink3)),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final on = row.id == current?.id;
                      return Material(
                        color: on ? d.sunken : Colors.transparent,
                        child: InkWell(
                          onTap: () => setState(() => selected = row.id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: d.line)),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 128,
                                  child: Text(
                                    time(row.startedAt),
                                    style: mono(11, c: d.ink3),
                                  ),
                                ),
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          '${row.title} · ${row.format}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: ui(13, c: d.ink),
                                        ),
                                      ),
                                      if (row.bookMatch ==
                                          OutputBookMatch.missing) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          key: ValueKey(
                                            'output-history-unmatched-${row.id}',
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            border: Border.all(color: d.line),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            '无法对应',
                                            style: ui(11, c: d.ink3),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  flex: 0,
                                  child: DeskTag(row.status, toneOf(row)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 12, 8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: d.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 只有一页时不显示翻页（TASK-028）。
                if (widget.history.count > 50)
                  Row(
                    children: [
                      DeskButton(
                        '上一页',
                        quiet: true,
                        onPressed: offset == 0
                            ? null
                            : () => setState(() {
                                offset = (offset - 50).clamp(0, offset);
                                selected = null;
                              }),
                      ),
                      DeskButton(
                        '下一页',
                        quiet: true,
                        onPressed: offset + 50 >= widget.history.count
                            ? null
                            : () => setState(() {
                                offset += 50;
                                selected = null;
                              }),
                      ),
                      const Spacer(),
                      Text(
                        '${offset ~/ 50 + 1} / ${(widget.history.count + 49) ~/ 50}',
                        style: mono(11, c: d.ink3),
                      ),
                    ],
                  ),
                if (widget.history.status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: Text(
                      widget.history.status,
                      style: ui(11.5, c: d.ink3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 这条记录对应书库中的哪本书（OUT-076/077）。
  Widget book(BuildContext context, OutputRecord current) {
    final d = context.desk;
    if (current.bookMatch == OutputBookMatch.missing) {
      return Text(
        '无法对应：书库中没有这本书（可能已移出书库，或原稿换了位置）。',
        key: const ValueKey('output-history-book'),
        style: ui(12.5, c: d.ink2, h: 1.55),
      );
    }
    final older = current.bookMatch == OutputBookMatch.olderSource;
    return Wrap(
      key: const ValueKey('output-history-book'),
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        Text(
          older ? '${current.bookTitle}（此成品来自旧版原稿）' : current.bookTitle,
          style: ui(12.5, c: d.ink, h: 1.55),
        ),
        if (widget.onOpenBook != null)
          InkWell(
            key: const ValueKey('output-history-open-book'),
            onTap: () => widget.onOpenBook!(current.bookId),
            borderRadius: BorderRadius.circular(4),
            child: Text(
              '在书库中查看 →',
              style: ui(12, c: d.ink2).copyWith(
                decoration: TextDecoration.underline,
                decorationColor: d.ink3,
              ),
            ),
          ),
      ],
    );
  }

  Widget detail(BuildContext context, OutputRecord current) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${current.title} · ${current.format} · ${current.status}',
                  style: ui(14.5, w: 650, c: d.ink),
                ),
                const SizedBox(height: 12),
                const DeskLabel('书库中的书'),
                book(context, current),
                const SizedBox(height: 12),
                const DeskLabel('输出路径'),
                SelectableText(
                  paths.normalize(current.path),
                  style: mono(11.5, c: d.ink),
                ),
                const SizedBox(height: 12),
                const DeskLabel('历史记录'),
                Text(current.detail, style: ui(12.5, c: d.ink2, h: 1.55)),
                const SizedBox(height: 12),
                const DeskLabel('本次文件核验'),
                Text(
                  current.busy
                      ? '正在核验…'
                      : current.verification.isEmpty
                      ? '尚未核验当前文件。'
                      : current.verification,
                  style: ui(12.5, c: d.ink2, h: 1.55),
                ),
                const SizedBox(height: 14),
                const DeskNote('文件与回执一致不代表已经通过 Kindle 真机阅读验收。'),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: d.line)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (current.interrupted)
                DeskButton(
                  '预览恢复',
                  onPressed: current.busy || recovering
                      ? null
                      : () => recover(current.id),
                ),
              DeskButton(
                '核验文件',
                primary: true,
                icon: Icons.fact_check_outlined,
                onPressed: loading || current.busy || !current.terminal
                    ? null
                    : () => act(() => widget.history.verify(current.id)),
              ),
              DeskButton(
                '所在文件夹',
                icon: Icons.folder_open_outlined,
                onPressed: () =>
                    act(() => widget.desktop.openDirectory(current.directory)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
