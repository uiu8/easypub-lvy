// 转换任务（D4-G，V8 按设计重写视图）：任务流、停止、按原批次重试与详情逻辑沿用原实现。
// V16：标题与筛选、任务行封面与大小、详情精简、空状态（TASK-024–027）。
import 'dart:io';

import 'package:path/path.dart' as paths;

import '../library/generated_cover.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../dialogs.dart';
import '../metadata/cover_preview.dart';

import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/conversion_desktop.dart';
import '../../application/conversion_service.dart';
import '../controls/controls.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({
    super.key,
    required this.session,
    required this.desktop,
    required this.onAdd,
    required this.onRetry,
    required this.onHistory,
    this.historyButton = true,
    required this.onOutput,
  });
  final ConversionSession session;
  final ConversionDesktop desktop;
  final VoidCallback onAdd;
  final VoidCallback onHistory;

  /// 页头的“转换历史”按钮；程序里由顶部切换条代替（V109），单独使用时保留。
  final bool historyButton;
  final void Function(String taskId) onOutput;
  final void Function(List<String> bookIds) onRetry;
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  String filter = '全部', message = '';
  String? selected;
  String identity(ConversionOutput item) =>
      item.taskId ?? '${item.bookId}\u0000${item.format}\u0000${item.path}';
  bool stopping = false, retrying = false;

  /// 成品文件的大小与修改时间：只读一次磁盘，读不到就不显示（TASK-025）。
  final _stats = <String, FileStat?>{};
  FileStat? statOf(ConversionOutput item) {
    if (!item.complete || item.path.isEmpty) return null;
    return probeOutputStat(item.path, _stats);
  }

  @override
  void initState() {
    super.initState();
    final feed = widget.session;
    if (feed is ConversionTaskFeed) {
      loadFeed(feed as ConversionTaskFeed);
    }
  }

  @override
  void didUpdateWidget(TasksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      selected = null;
      message = '';
      final feed = widget.session;
      if (feed is ConversionTaskFeed) loadFeed(feed as ConversionTaskFeed);
    }
  }

  Future<void> loadFeed(ConversionTaskFeed feed) async {
    try {
      await feed.loadTaskFeed();
      if (mounted && identical(widget.session, feed)) {
        setState(
          () => message = feed.taskFeedStatus.contains('失败')
              ? feed.taskFeedStatus
              : '',
        );
      }
    } catch (_) {
      if (mounted && identical(widget.session, feed)) {
        setState(() => message = '历史任务读取失败，当前任务仍可查看。');
      }
    }
  }

  Future<void> stop() async {
    setState(() => stopping = true);
    try {
      await widget.session.cancel();
    } catch (_) {
      if (mounted) setState(() => message = '停止请求未完成，请核对任务状态。');
    } finally {
      if (mounted) setState(() => stopping = false);
    }
  }

  Future<void> retryTasks(List<ConversionOutput> chosen) async {
    if (retrying || widget.session.busy) return;
    final session = widget.session;
    if (session is! ConversionRetryService) {
      widget.onRetry(chosen.map((i) => i.bookId).toList());
      return;
    }
    setState(() {
      retrying = true;
      message = '正在恢复原批次配置并重新核对…';
    });
    var submitting = false;
    try {
      if (chosen.any((i) => i.taskId == null)) {
        throw const FormatException('所选书尚未开始执行，没有任务回执；可使用当前书稿重新配置。');
      }
      final plan = await (session as ConversionRetryService).previewRetry(
        chosen.map((i) => i.taskId!).toList(),
      );
      if (!mounted) return;
      if (!plan.previewed || plan.blocked) {
        throw FormatException(
          plan.findings
              .where((f) => f.level == 'blocking')
              .map((f) => f.detail)
              .join('\n'),
        );
      }
      final request = session.request!;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => DeskAlert(
          title: const Text('按原批次配置重试'),
          scrollable: true,
          content: Text(
            '所选 ${plan.outputs.length} 本 · ${request.format}\n输出目录：${request.directory}\n'
            '使用原任务的制作设置、语言、封面与目标文件名。\n'
            '${plan.needsAcknowledgement ? '检查仍有提醒，请核对后继续。\n' : ''}'
            '${plan.outputs.map((o) => o.title).join('、')}\n'
            '${plan.findings.where((f) => f.level == 'warning').map((f) => '${f.title}：${f.detail}').join('\n')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认重试'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        await session.cancel();
        if (mounted) setState(() => message = '已取消重试预览，没有生成成品。');
        return;
      }
      submitting = true;
      await session.commit(plan, acknowledgeWarnings: true);
      if (mounted) setState(() => message = '重试批次已结束，请核对任务结果。');
    } catch (error) {
      if (!mounted) return;
      final detail = deskErrorText(error, '无法恢复原批次，请核对记录或重新配置转换。');
      setState(() => message = detail);
      if (submitting) return; // A commit may already have produced files: inspect results first.
      final configure = await showDialog<bool>(
        context: context,
        builder: (context) => DeskAlert(
          title: const Text('无法按原配置重试'),
          scrollable: true,
          content: Text('$detail\n\n本次没有提交转换。重新配置将读取当前默认值并创建新批次，不会覆盖旧成品。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回任务'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('使用当前书稿重新配置'),
            ),
          ],
        ),
      );
      if (configure == true && mounted && !session.busy) {
        await session.cancel();
        if (mounted) {
          widget.onRetry(chosen.map((i) => i.bookId).toSet().toList());
        }
      }
    } finally {
      if (mounted) setState(() => retrying = false);
    }
  }

  Future<void> openDirectory(ConversionOutput item) async {
    final path = item.path.replaceAll('\\', '/');
    if (!path.contains('/')) return;
    var directory = path.substring(0, path.lastIndexOf('/'));
    if (RegExp(r'^[A-Za-z]:$').hasMatch(directory)) directory += '/';
    try {
      await widget.desktop.openDirectory(directory);
    } catch (e) {
      if (mounted) {
        setState(() => message = deskErrorText(e, '无法打开成品目录，请检查路径。'));
      }
    }
  }

  Tone tone(ConversionOutput item) => item.failed
      ? Tone.pen
      : item.complete
      ? Tone.ok
      : item.running
      ? Tone.neutral
      : Tone.neutral;
  bool matches(ConversionOutput item, String tab) => switch (tab) {
    '进行中' => item.running,
    '等待' => item.phase == 'waiting' || item.phase == 'blocked',
    '已完成' => item.complete,
    '失败' => item.failed,
    '已取消' => item.phase == 'cancelled',
    _ => true,
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session.changes,
    builder: (context, _) {
      final d = context.desk;
      final session = widget.session;
      final stopPending = session.outputs.any(
        (item) =>
            item.running &&
            (item.cancelRequested || item.waitingForCurrentFile),
      );
      final items = session is ConversionTaskFeed
          ? (session as ConversionTaskFeed).taskFeed
          : session.outputs;
      const tabs = ['全部', '进行中', '等待', '已完成', '失败', '已取消'];
      final tabCounts = {
        for (final tab in tabs)
          tab: items.where((item) => matches(item, tab)).length,
      };
      final visible = items.where((item) => matches(item, filter)).toList();
      final current =
          visible.where((item) => identity(item) == selected).firstOrNull ??
          visible.firstOrNull;
      final batchFailures = current?.batchId == null
          ? <ConversionOutput>[]
          : items
                .where(
                  (i) => i.batchId == current!.batchId && i.phase == 'failed',
                )
                .toList();
      final historical = items.any((item) => item.historical);
      // 最近一批的概况，例如“最近一批 · 2 本已完成”。
      final latestBatch = items.firstOrNull?.batchId;
      final batch = latestBatch == null
          ? const <ConversionOutput>[]
          : items.where((i) => i.batchId == latestBatch).toList();
      final summary = [
        for (final (label, count) in [
          ('进行中', batch.where((i) => i.running).length),
          ('已完成', batch.where((i) => i.complete).length),
          ('失败', batch.where((i) => i.failed).length),
          ('已取消', batch.where((i) => i.phase == 'cancelled').length),
        ])
          if (count > 0) '$count 本$label',
      ].join(' · ');
      final running = widget.session.busy || stopping || stopPending;
      return DeskPageFrame(
        header: DeskPageHeader(
          title: '转换任务',
          subtitle: summary.isEmpty ? null : '最近一批 · $summary',
          actions: [
            if (widget.historyButton)
              DeskButton(
                '转换历史',
                icon: Icons.history_rounded,
                quiet: true,
                onPressed: widget.onHistory,
              ),
            DeskButton(
              '新建转换',
              icon: Icons.add_rounded,
              quiet: true,
              onPressed: widget.onAdd,
            ),
            if (batchFailures.isNotEmpty)
              DeskButton(
                '重试本批次失败项',
                onPressed: widget.session.busy || retrying
                    ? null
                    : () => retryTasks(batchFailures),
              ),
            // 没有运行中的任务时不显示“停止队列”。
            if (running)
              DeskButton(
                stopping || stopPending ? '等待停止完成' : '停止队列',
                icon: Icons.stop_rounded,
                onPressed: !widget.session.busy || stopping || stopPending
                    ? null
                    : stop,
              ),
          ],
        ),
        child: items.isEmpty
            ? emptyState(context)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // 只显示有数量的分类；“全部”和当前选中的分类始终显示。
                        DeskSegmented<String>(
                          value: filter,
                          options: {
                            for (final tab in tabs)
                              if (tab == '全部' ||
                                  tab == filter ||
                                  (tabCounts[tab] ?? 0) > 0)
                                tab: '$tab ${tabCounts[tab]}',
                          },
                          onChanged: (tab) => setState(() => filter = tab),
                        ),
                        if (historical)
                          Text(
                            '含当前批次及最近50条历史任务；更多记录见转换历史。',
                            style: ui(11.5, c: d.ink3),
                          ),
                      ],
                    ),
                  ),
                  if (message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: DeskInfoBar(message),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 16, 12),
                      child: DeskSplitView(
                        leadingLabel: '任务列表',
                        trailingLabel: '任务详情',
                        breakpoint: 760,
                        leadingWidth: 400,
                        leading: visible.isEmpty
                            ? const DeskEmptyState(
                                '此分类暂无任务。',
                                icon: Icons.playlist_play_rounded,
                              )
                            : DeskScrollArea(
                                builder: (controller) => ListView.builder(
                                  controller: controller,
                                  itemCount: visible.length,
                                  itemBuilder: (context, index) => taskRow(
                                    context,
                                    visible[index],
                                    current != null &&
                                        identity(current) ==
                                            identity(visible[index]),
                                  ),
                                ),
                              ),
                        trailing: current == null
                            ? Center(
                                child: Text(
                                  '选择任务查看详情',
                                  style: ui(12.5, c: d.ink3),
                                ),
                              )
                            : detail(context, current),
                      ),
                    ),
                  ),
                ],
              ),
      );
    },
  );

  Widget taskRow(BuildContext context, ConversionOutput item, bool on) {
    final d = context.desk;
    final t = tone(item);
    final stat = statOf(item);
    final sub = (item.detail.isNotEmpty && !item.complete) || item.running
        ? (item.detail.isNotEmpty ? item.detail : taskPhaseSummary(item))
        : [
            item.format == 'AZW3' ? 'Kindle AZW3' : item.format,
            if (stat != null) ...[
              taskTime(stat.modified),
              formatFileSize(stat.size),
            ],
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: on ? d.surface : Colors.transparent,
        elevation: on ? 1 : 0,
        shadowColor: d.shadowInk.withValues(alpha: .25),
        borderRadius: BorderRadius.circular(9),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('task-row-${identity(item)}'),
          onTap: () => setState(() => selected = identity(item)),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: on ? d.ink2 : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    TaskCover(item, width: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(13, w: 600, c: d.ink),
                          ),
                          Text(
                            sub,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: ui(
                              11.5,
                              c: item.failed ? d.tone(Tone.pen).$1 : d.ink3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 失败时状态是“失败：详情”，可能很长：限宽单行省略，
                    // 悬停看全文，不把标题挤出行外。
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Tooltip(
                        message: taskStatusLabel(item),
                        child: DeskTag(
                          taskStatusLabel(item),
                          t,
                          singleLine: true,
                        ),
                      ),
                    ),
                  ],
                ),
                if (item.running) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(minHeight: 3),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget detail(BuildContext context, ConversionOutput current) {
    final d = context.desk;
    final path = current.path.isEmpty ? '' : paths.normalize(current.path);
    final name = path.isEmpty ? current.title : paths.basename(path);
    final stat = statOf(current);
    return DeskCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DeskScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Tooltip(
                          message: current.coverThumbnail != null
                              ? '本次任务保存的封面缩略快照；成品内容请在成品验收中核对'
                              : current.historical
                              ? '此记录未保存封面快照'
                              : '本次转换设置中的封面；成品内容请在成品验收中核对',
                          child: TaskCover(current, width: 50),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Tooltip(
                                message: current.title,
                                child: Text(
                                  name,
                                  key: const ValueKey('task-detail-title'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: ui(15, w: 650, c: d.ink),
                                ),
                              ),
                              const SizedBox(height: 6),
                              DeskTag(
                                [
                                  current.format,
                                  taskStatusLabel(current),
                                  if (stat != null) formatFileSize(stat.size),
                                ].join(' · '),
                                tone(current),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TaskStages(output: current),
                    const SizedBox(height: 10),
                    _TaskFact(
                      '转换前检查',
                      current.checksEnabled == null
                          ? '未记录检查策略'
                          : current.checksEnabled!
                          ? '已启用 · 质量问题不限制转换'
                          : '未启用 · 直接转换',
                    ),
                    _TaskFact(
                      '位置',
                      path.isEmpty ? '尚未确定' : paths.dirname(path),
                    ),
                    if (current.detail.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      DeskNote(
                        current.detail,
                        tone: current.failed ? Tone.pen : Tone.neutral,
                      ),
                    ],
                    if (current.running) ...[
                      const SizedBox(height: 10),
                      DeskNote(
                        !current.statusAvailable
                            ? '显示最后已知阶段；正在重连，不会自动重启任务。'
                            : current.waitingForCurrentFile
                            ? '等待当前文件处理结束，后续书籍不再开始；已生成成品保留。'
                            : current.cancelRequested
                            ? '已请求取消，等待后台确认退出；尚未标记为已取消。'
                            : '正在执行，当前阶段未提供可计量的百分比。',
                        tone: current.cancelRequested
                            ? Tone.warn
                            : Tone.neutral,
                      ),
                    ],
                    if (current.failed || current.phase == 'cancelled') ...[
                      const SizedBox(height: 10),
                      Text(
                        '重试会先恢复原批次配置并重新核对；需要修改设置时，请重新配置转换。',
                        style: ui(11.5, c: d.ink3, h: 1.5),
                      ),
                    ],
                  ],
                ),
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
              alignment: WrapAlignment.end,
              children: [
                DeskButton(
                  '打开成品目录',
                  icon: Icons.folder_open_outlined,
                  onPressed: current.complete
                      ? () => openDirectory(current)
                      : null,
                ),
                if (current.complete && current.taskId != null)
                  DeskButton(
                    '成品验收',
                    icon: Icons.verified_outlined,
                    primary: true,
                    onPressed: () => widget.onOutput(current.taskId!),
                  ),
                if (current.failed || current.phase == 'cancelled')
                  DeskButton(
                    '重试此项',
                    icon: Icons.refresh_rounded,
                    onPressed: widget.session.busy || retrying
                        ? null
                        : () => retryTasks([current]),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension on _TasksPageState {
  /// 还没有任何转换任务时：居中说明与入口，不再显示两块空白（TASK-027）。
  Widget emptyState(BuildContext context) {
    final d = context.desk;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          key: const ValueKey('tasks-empty'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.checklist_rounded, size: 36, color: d.ink3),
            const SizedBox(height: 12),
            Text('还没有转换任务', style: ui(15, w: 650, c: d.ink)),
            const SizedBox(height: 6),
            Text(
              '在转换页选好书稿和格式后开始转换，进度和成品都会出现在这里。',
              textAlign: TextAlign.center,
              style: ui(12.5, c: d.ink2, h: 1.5),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                DeskButton(
                  '去转换',
                  icon: Icons.arrow_forward_rounded,
                  primary: true,
                  onPressed: widget.onAdd,
                ),
                DeskButton(
                  '转换历史',
                  icon: Icons.history_rounded,
                  onPressed: widget.onHistory,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 任务的封面：优先用本次任务保存的封面缩略快照，其次用本次设置的封面，
/// 都没有时用与书库一致的生成封面（TASK-025）。
class TaskCover extends StatelessWidget {
  const TaskCover(this.item, {super.key, required this.width});
  final ConversionOutput item;
  final double width;
  @override
  Widget build(BuildContext context) {
    final height = width * 4 / 3;
    final generated = CustomPaint(
      size: Size(width, height),
      painter: GeneratedCoverPainter.desk(
        context.desk,
        title: item.title,
        author: '',
      ),
    );
    return Tooltip(
      message: item.coverThumbnail != null
          ? '本次任务保存的封面缩略快照；成品内容请在成品验收中核对'
          : item.coverPath != null
          ? '本次转换设置中的封面；成品内容请在成品验收中核对'
          : '此记录未保存封面快照，显示书库的生成封面',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          width: width,
          height: height,
          child: item.coverThumbnail != null
              ? Image.memory(
                  item.coverThumbnail!,
                  cacheWidth: (width * 3).round(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => generated,
                )
              : item.coverPath != null
              ? CoverPreview(
                  path: item.coverPath!,
                  crop: item.coverCrop,
                  decodeWidth: (width * 3).round(),
                )
              : generated,
        ),
      ),
    );
  }
}

/// 文件时间：今天只写时分，其余写月日。
String taskTime(DateTime when) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(when.hour)}:${two(when.minute)}';
  return when.year == now.year && when.month == now.month && when.day == now.day
      ? time
      : '${when.month} 月 ${when.day} 日 $time';
}

class _TaskFact extends StatelessWidget {
  const _TaskFact(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: SelectableText(value, style: ui(12.5, c: d.ink)),
          ),
        ],
      ),
    );
  }
}

/// Reports only stages established by the task phase. Failed/interrupted tasks
/// do not carry their last successful stage, so those stages remain unknown.
class TaskStages extends StatelessWidget {
  const TaskStages({super.key, required this.output});
  final ConversionOutput output;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final active = switch (output.phase) {
      'preparing' => 0,
      'prepared' || 'converting' => 1,
      'checking' || 'publishing' => 2,
      'complete' => 3,
      'waiting' => -1,
      _ => -2,
    };
    const labels = ['准备书稿与设置', '生成成品', '核验输出'];
    return Row(
      key: const ValueKey('task-stages'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0)
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                // 阶段之间的进度槽：走到下一阶段才填满（V105 视觉语言）。
                child: DeskProgressTrack(
                  value: active >= i ? 1 : 0,
                  color: d.add,
                  height: 3,
                ),
              ),
            ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  active > i
                      ? Icons.check_circle_outline_rounded
                      : active == i
                      ? Icons.sync_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: active > i
                      ? d.add
                      : active == i
                      ? d.accent
                      : d.ink3,
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(12.5, c: d.ink),
                ),
                Text(
                  active == -2
                      ? '未记录阶段结果'
                      : active > i
                      ? '已完成'
                      : active == i
                      ? (!output.statusAvailable
                            ? '等待状态更新'
                            : output.waitingForCurrentFile
                            ? '当前文件完成后停止'
                            : output.cancelRequested
                            ? '等待取消结果'
                            : output.phase == 'publishing'
                            ? '校验完成，正在保存'
                            : '正在处理')
                      : '等待处理',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(11.5, c: d.ink3),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

String taskStatusLabel(ConversionOutput output) {
  if (!output.statusAvailable && output.running) return '状态暂不可用';
  if (output.waitingForCurrentFile) return '当前文件完成后停止';
  if (output.cancelRequested && output.running) return '正在取消';
  if (output.stopRequested && output.running) return '已停止排队';
  return output.status;
}

String taskPhaseSummary(ConversionOutput output) {
  if (!output.statusAvailable) return '等待状态更新 · 不会自动重启任务';
  if (output.waitingForCurrentFile) return '当前文件完成后停止';
  if (output.cancelRequested && output.running) return '已请求取消 · 等待后台确认';
  return switch (output.phase) {
    'preparing' => '1 / 3 步 · 准备书稿与设置',
    'prepared' || 'converting' => '2 / 3 步 · 完成后自动核验',
    'checking' || 'publishing' => '3 / 3 步 · 核验并保存成品',
    _ => '正在执行 · 等待处理阶段',
  };
}
