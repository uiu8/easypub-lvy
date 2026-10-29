part of '../booksource_page.dart';

extension _BookSourceQueue on _BookSourcePageState {
  Future<void> _loadQueue() async {
    final value = await api!.call('queue.list');
    if (mounted) update(() => _applyQueue(value));
  }

  void _applyQueue(dynamic value) {
    if (value is! Map || value['tasks'] is! List) return;
    final next = <DownloadTask>[];
    for (final raw in value['tasks'] as List) {
      final item = raw as Map;
      final task =
          _task(item['id']) ??
          DownloadTask(
            '${item['id']}',
            '${item['title']}',
            '${item['sourceName']}',
          );
      task.chapters = [
        for (final c in item['chapters'] as List? ?? [])
          Map<String, dynamic>.from(c as Map),
      ];
      task.status = '${item['status']}';
      task.finished = ['done', 'failed', 'cancelled'].contains(task.status);
      task.cancelled = task.status == 'cancelled';
      task.error = item['error']?.toString();
      task.stage = switch (task.status) {
        'queued' => '排队中',
        'paused' => '已暂停（已取到的章节保留）',
        'cancelled' => '已取消（已取到的章节保留）',
        'done' => '完成',
        'failed' => '失败',
        _ => '下载章节',
      };
      task.applyProgress(item['progress'] as Map? ?? {});
      if (item['result'] is Map) task.applyResult(item['result'] as Map);
      next.add(task);
    }
    tasks
      ..clear()
      ..addAll(next);
  }

  Future<void> _queueAction(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      await api!.call(method, params);
      await _loadQueue();
    } catch (e) {
      update(() => sourceMessage = bookSourceErrorText(e));
    }
  }

  Future<void> _import(DownloadTask t) async {
    if (t.path == null || t.imported || !importing.add(t.id)) return;
    final error = await widget.importToLibrary(t.path!);
    importing.remove(t.id);
    update(() {
      t.imported = error == null;
      if (error != null) t.error = '加入书库失败：$error';
      t.libraryOutdated =
          error == null && widget.outdatedInLibrary?.call(t.path!) == true;
    });
  }

  /// 书库里还是旧版本时“刷新来源”（V111）；采用后，下载格式为 EPUB 的接着生成。
  Future<void> _refreshLibrary(DownloadTask t) async {
    if (t.path == null || widget.refreshInLibrary == null) return;
    final fresh = await widget.refreshInLibrary!(t.path!);
    update(() => t.libraryOutdated = !fresh);
    if (fresh &&
        settings.downloadFormat == 'epub' &&
        widget.exportEpub != null &&
        !t.epubDone) {
      await _exportEpub(t);
    }
  }

  /// 单独清除一条下载记录（LIB-223）：文件与章节缓存保留；进行中的任务由插件拒绝并说明。
  Future<void> _removeTask(DownloadTask t) async {
    try {
      await api!.call('queue.remove', {'taskId': t.id});
      await _loadQueue();
      update(() => sourceMessage = '已清除《${t.title}》的下载记录，下载的文件保留。');
    } catch (e) {
      update(() => sourceMessage = bookSourceErrorText(e));
    }
  }

  Future<void> _exportEpub(DownloadTask t) async {
    if (t.path == null || t.epubBusy || widget.exportEpub == null) return;
    update(() {
      t.epubBusy = true;
      t.epubError = null;
    });
    final r = await widget.exportEpub!(t.path!);
    update(() {
      t.epubBusy = false;
      t.imported = t.imported || r.imported;
      t.epubDone = r.error == null;
      t.epubError = r.error;
      t.libraryOutdated =
          r.imported && widget.outdatedInLibrary?.call(t.path!) == true;
    });
  }

  (String, Tone) _taskState(DownloadTask t) {
    if (t.cancelled || t.status == 'cancelled') return ('已取消', Tone.info);
    if (t.finished) {
      return t.error != null || t.failures.isNotEmpty
          ? ('有未取到的章节', Tone.warn)
          : ('完成', Tone.ok);
    }
    return switch (t.status) {
      'queued' => ('排队中', Tone.info),
      'paused' => ('已暂停', Tone.warn),
      'failed' => ('失败', Tone.pen),
      _ => ('下载中', Tone.accent),
    };
  }

  Widget _downloadsTab(BuildContext context) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DeskText(
                '同时下载 ${settings.maxBooks} 本 · 每本上限 ${settings.threads} 章',
                color: d.ink2,
                size: 12,
              ),
              const Spacer(),
              DeskButton(
                '下载设置',
                quiet: true,
                icon: Icons.tune,
                onPressed: () => update(() => tab = 'settings'),
              ),
              DeskButton(
                '清除已结束',
                key: const ValueKey('booksource-clear-done'),
                quiet: true,
                onPressed: () => _queueAction('queue.clearDone'),
              ),
              IconButton(
                tooltip: '刷新队列',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _loadQueue,
              ),
            ],
          ),
          if (sourceMessage != null) ...[
            const SizedBox(height: 6),
            DeskNote(sourceMessage!),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: tasks.isEmpty
                ? const DeskEmptyState(
                    '还没有下载。在“搜索”里选书，或用“书名清单…”批量加入。',
                    icon: Icons.download_outlined,
                  )
                : ListView.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, index) => _taskCard(index),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _taskCard(int index) {
    final d = context.desk;
    final t = tasks[index];
    final (state, tone) = _taskState(t);
    final hasFailures =
        t.failures.isNotEmpty || t.chapters.any((c) => c['status'] == 'failed');
    // 状态标签已写明“已暂停 / 完成”时，阶段文字只留补充说明，不重复。
    final stage = t.stage.startsWith(state)
        ? t.stage
              .substring(state.length)
              .replaceAll(RegExp(r'^[（(]|[）)]$'), '')
              .trim()
        : t.stage;
    final info = [
      if (t.error != null) t.error! else stage,
      if (t.status == 'running')
        '${t.speed.toStringAsFixed(2)} 章/秒 · ${t.eta == null ? '正在估算剩余时间' : '预计剩余 ${_eta(t.eta!)}'}'
            ' · 并发 ${t.concurrency}${t.retrying > 0 ? ' · 补抓 ${t.retrying}' : ''}${t.throttled ? ' · 限流中，已自动降速' : ''}',
      if (t.sourceCount > 1) '由 ${t.sourceCount} 个书源分担',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Container(
      key: ValueKey('booksource-task-${t.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // R1c：左边进度环，中间书名、状态与说明、章节来源分布条，右边速度曲线。
          Row(
            children: [
              SizedBox(
                key: ValueKey('booksource-task-ring-${t.id}'),
                width: 46,
                height: 46,
                child: CustomPaint(
                  painter: _RingPainter(
                    t.total > 0 ? (t.done / t.total).clamp(0.0, 1.0) : 0,
                    track: d.line,
                    color: t.error != null || t.status == 'failed'
                        ? d.pen
                        : t.finished
                        ? d.add
                        : d.accent,
                  ),
                  child: Center(
                    child: Text(
                      t.total > 0
                          ? '${(t.done * 100 / t.total).floor()}%'
                          : '—',
                      style: mono(11, c: d.ink),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: DeskText(t.title, bold: true, lines: 1),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: DeskText(
                            t.sourceName,
                            size: 12,
                            color: d.ink2,
                            lines: 1,
                          ),
                        ),
                        const SizedBox(width: 8),
                        DeskTag(state, tone),
                        if (t.total > 0) ...[
                          const SizedBox(width: 8),
                          DeskText(
                            '${t.done}/${t.total}',
                            size: 12,
                            color: d.ink2,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    DeskText(
                      info,
                      size: 12,
                      color: t.error != null ? d.pen : d.ink2,
                      lines: 2,
                    ),
                    ?_sourceShare(t),
                  ],
                ),
              ),
              if (t.speeds.length >= 2) ...[
                const SizedBox(width: 12),
                Tooltip(
                  message: '最近 ${t.speeds.length} 次速度（章/秒）',
                  child: SizedBox(
                    key: ValueKey('booksource-task-spark-${t.id}'),
                    width: 96,
                    height: 32,
                    child: CustomPaint(
                      painter: _SparkPainter(t.speeds, d.accent),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Spacer(),
              if (['running', 'queued'].contains(t.status))
                IconButton(
                  key: ValueKey('booksource-pause-${t.id}'),
                  tooltip: '暂停',
                  icon: const Icon(Icons.pause, size: 18),
                  onPressed: () =>
                      _queueAction('queue.pause', {'taskId': t.id}),
                ),
              if (['paused', 'failed', 'cancelled'].contains(t.status))
                IconButton(
                  key: ValueKey('booksource-resume-${t.id}'),
                  tooltip: '继续',
                  icon: const Icon(Icons.play_arrow, size: 18),
                  onPressed: () =>
                      _queueAction('queue.resume', {'taskId': t.id}),
                ),
              if (!t.finished) ...[
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      _queueAction('queue.cancel', {'taskId': t.id}),
                ),
                IconButton(
                  tooltip: '上移',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: index == 0
                      ? null
                      : () => _queueAction('queue.move', {
                          'taskId': t.id,
                          'direction': 'up',
                        }),
                ),
                IconButton(
                  tooltip: '下移',
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: index + 1 == tasks.length
                      ? null
                      : () => _queueAction('queue.move', {
                          'taskId': t.id,
                          'direction': 'down',
                        }),
                ),
              ],
              if (t.path != null &&
                  !t.cancelled &&
                  !t.outputPreserved &&
                  !t.imported)
                DeskButton(
                  '加入书库',
                  key: ValueKey('booksource-import-${t.id}'),
                  primary: true,
                  onPressed: () => _import(t),
                ),
              if (t.imported && t.libraryOutdated) ...[
                const DeskTag('书库里是旧版本', Tone.warn),
                if (widget.refreshInLibrary != null) ...[
                  const SizedBox(width: 6),
                  DeskButton(
                    '刷新来源',
                    key: ValueKey('booksource-refresh-${t.id}'),
                    primary: true,
                    onPressed: () => _refreshLibrary(t),
                  ),
                ],
              ] else if (t.imported)
                const DeskTag('已加入书库', Tone.ok),
              if (t.epubBusy) ...[
                const SizedBox(width: 6),
                const DeskTag('正在生成 EPUB', Tone.accent),
              ],
              if (t.epubDone) ...[
                const SizedBox(width: 6),
                const DeskTag('已生成 EPUB', Tone.ok),
              ],
              if (t.path != null && widget.openFolder != null)
                IconButton(
                  tooltip: '打开文件夹',
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  onPressed: () => widget.openFolder!(t.path!),
                ),
              DeskMenuButton<VoidCallback>(
                key: ValueKey('booksource-task-menu-${t.id}'),
                tooltip: '更多操作',
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (f) => f(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    key: ValueKey('booksource-diagnose-${t.id}'),
                    value: () => _diagnose(t),
                    child: const Text('诊断（各站点限速、耗时）'),
                  ),
                  if (hasFailures)
                    PopupMenuItem(
                      value: () => _failureCauses(t.failures),
                      child: const Text('按原因查看未取到的章节'),
                    ),
                  if (hasFailures)
                    PopupMenuItem(
                      key: ValueKey('booksource-retry-failed-${t.id}'),
                      enabled: t.status != 'running',
                      value: () =>
                          _queueAction('queue.retryFailed', {'taskId': t.id}),
                      child: const Text('只重试失败章节'),
                    ),
                  if (t.libraryKey != null && t.finished)
                    PopupMenuItem(
                      value: () => _rebuild(t.libraryKey!),
                      child: const Text('不联网重新整理'),
                    ),
                  if (widget.exportEpub != null && t.path != null)
                    PopupMenuItem(
                      key: ValueKey('booksource-epub-${t.id}'),
                      enabled: !t.epubBusy && !t.cancelled,
                      value: () => _exportEpub(t),
                      child: Text(t.epubDone ? '重新生成 EPUB' : '生成 EPUB（全局默认排版）'),
                    ),
                  PopupMenuItem(
                    key: ValueKey('booksource-remove-${t.id}'),
                    enabled: t.finished || t.status == 'paused',
                    value: () => _removeTask(t),
                    child: const Text('清除这条记录（文件保留）'),
                  ),
                ],
              ),
            ],
          ),
          if (t.imported && t.libraryOutdated && t.epubError == null)
            DeskText(
              '书库里已有这本书，这次下载的内容变了，书库里的草稿没有动。点“刷新来源”对比后再采用新内容。',
              key: ValueKey('booksource-outdated-${t.id}'),
              size: 12,
              color: d.pen,
              lines: 2,
            ),
          if (t.epubError != null)
            DeskText(
              'EPUB：${t.epubError}',
              key: ValueKey('booksource-epub-error-${t.id}'),
              size: 12,
              color: d.pen,
              lines: 2,
            ),
          if (t.failures.isNotEmpty)
            DeskText(
              '未取到：${t.failures.take(5).map((f) => '${f['title']}（${_sourceCauses[f['cause']] ?? ''} ${f['reason']}）').join('；')}'
              '${t.failures.length > 5 ? ' 等' : ''}',
              size: 12,
              color: d.ink2,
              lines: 2,
            ),
          if (t.total > 0 && t.duplicateHeadings / t.total > 0.01)
            DeskNote(
              '质量提示：仍有 ${t.duplicateHeadings} 处同名章节，请检查；可从缓存重新整理。',
              tone: Tone.warn,
            ),
        ],
      ),
    );
  }

  /// 章节来源分布条（R1c）：已下载的章节各来自哪个书源；只有一个书源时不画。
  Widget? _sourceShare(DownloadTask t) {
    final d = context.desk;
    final counts = <String, int>{};
    for (final c in t.chapters) {
      if (c['status'] != 'completed') continue;
      final id = '${c['source'] ?? ''}';
      if (id.isEmpty) continue;
      counts.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
    if (counts.length < 2) return null;
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final colors = [d.accent, d.add, d.warn, d.ink3];
    String name(String id) =>
        '${sources.where((s) => '${s['id']}' == id).firstOrNull?['name'] ?? id}';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Tooltip(
        message: [for (final e in entries) '${name(e.key)}：${e.value} 章']
            .join('\n'),
        child: ClipRRect(
          key: ValueKey('booksource-task-share-${t.id}'),
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 5,
            width: 240,
            child: Row(
              children: [
                for (final (i, e) in entries.indexed)
                  Expanded(
                    flex: e.value,
                    child: ColoredBox(
                      color: colors[i.clamp(0, 3)],
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _eta(int seconds) =>
    seconds < 60 ? '$seconds 秒' : '${seconds ~/ 60} 分 ${seconds % 60} 秒';

/// 进度环（R1c）：自绘，不用 CircularProgressIndicator（页面“加载中”的判断靠它）。
class _RingPainter extends CustomPainter {
  _RingPainter(this.value, {required this.track, required this.color});
  final double value;
  final Color track, color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * value,
        false,
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.track != track;
}
