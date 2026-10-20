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
      update(() => sourceMessage = '$e');
    }
  }

  Future<void> _import(DownloadTask t) async {
    if (t.path == null || t.imported || !importing.add(t.id)) return;
    final error = await widget.importToLibrary(t.path!);
    importing.remove(t.id);
    update(() {
      t.imported = error == null;
      if (error != null) t.error = '加入书库失败：$error';
    });
  }

  Widget _downloadsTab(BuildContext context) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DeskText(
                '同时下载 ${settings.maxBooks} 本 · 每本上限 ${settings.threads} 章',
                color: d.ink2,
                size: 12,
              ),
              DeskButton(
                '下载设置',
                quiet: true,
                onPressed: () => update(() => tab = 'settings'),
              ),
              DeskButton(
                '清除已结束',
                key: const ValueKey('booksource-clear-done'),
                quiet: true,
                onPressed: () => _queueAction('queue.clearDone'),
              ),
              DeskButton('刷新队列', quiet: true, onPressed: _loadQueue),
            ],
          ),
          const SizedBox(height: 10),
          if (sourceMessage != null) DeskNote(sourceMessage!),
          if (tasks.isEmpty) const DeskNote('还没有下载。在“搜索”里选书，或粘贴书名清单加入下载。'),
          Expanded(
            child: ListView.builder(
              itemCount: tasks.length,
              itemBuilder: (context, index) {
                final t = tasks[index];
                return Container(
                  key: ValueKey('booksource-task-${t.id}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: d.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: d.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DeskText(
                              '${t.title}（${t.sourceName}）',
                              bold: true,
                              lines: 1,
                            ),
                          ),
                          DeskText(
                            t.total > 0 ? '${t.done}/${t.total}' : '',
                            size: 12,
                            color: d.ink2,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: t.total > 0
                            ? (t.done / t.total).clamp(0, 1)
                            : (t.status == 'running' ? null : 0),
                      ),
                      const SizedBox(height: 6),
                      DeskText(
                        t.error ?? t.stage,
                        size: 12,
                        color: t.error != null ? d.pen : d.ink2,
                      ),
                      if (t.sourceCount > 1)
                        DeskText('由 ${t.sourceCount} 个书源分担', size: 12),
                      if (t.status == 'running')
                        DeskText(
                          '${t.speed.toStringAsFixed(2)} 章/秒 · ${t.eta == null ? '正在估算剩余时间' : '预计剩余 ${_eta(t.eta!)}'}'
                          ' · 并发 ${t.concurrency} · 补抓 ${t.retrying}${t.throttled ? ' · 限流中，已自动降速' : ''}',
                          size: 12,
                          color: d.ink2,
                        ),
                      if (t.failures.isNotEmpty)
                        DeskText(
                          '未取到：${t.failures.take(5).map((f) => '${f['title']}（${_sourceCauses[f['cause']] ?? ''} ${f['reason']}）').join('；')}'
                          '${t.failures.length > 5 ? ' 等' : ''}',
                          size: 12,
                          color: d.ink2,
                          lines: 3,
                        ),
                      if (t.total > 0 && t.duplicateHeadings / t.total > 0.01)
                        DeskNote(
                          '质量提示：仍有 ${t.duplicateHeadings} 处同名章节，请检查；可从缓存重新整理。',
                          tone: Tone.warn,
                        ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          DeskButton(
                            '诊断',
                            key: ValueKey('booksource-diagnose-${t.id}'),
                            quiet: true,
                            onPressed: () => _diagnose(t),
                          ),
                          if (t.failures.isNotEmpty ||
                              t.chapters.any((c) => c['status'] == 'failed'))
                            DeskButton(
                              '按原因查看',
                              quiet: true,
                              onPressed: () => _failureCauses(t.failures),
                            ),
                          if (t.failures.isNotEmpty ||
                              t.chapters.any((c) => c['status'] == 'failed'))
                            DeskButton(
                              '只重试失败章节',
                              key: ValueKey('booksource-retry-failed-${t.id}'),
                              quiet: true,
                              onPressed: t.status == 'running'
                                  ? null
                                  : () => _queueAction('queue.retryFailed', {
                                      'taskId': t.id,
                                    }),
                            ),
                          if (['running', 'queued'].contains(t.status))
                            DeskButton(
                              '暂停',
                              key: ValueKey('booksource-pause-${t.id}'),
                              quiet: true,
                              onPressed: () =>
                                  _queueAction('queue.pause', {'taskId': t.id}),
                            ),
                          if ([
                            'paused',
                            'failed',
                            'cancelled',
                          ].contains(t.status))
                            DeskButton(
                              '继续',
                              key: ValueKey('booksource-resume-${t.id}'),
                              quiet: true,
                              onPressed: () => _queueAction('queue.resume', {
                                'taskId': t.id,
                              }),
                            ),
                          if (!t.finished)
                            DeskButton(
                              '取消',
                              quiet: true,
                              onPressed: () => _queueAction('queue.cancel', {
                                'taskId': t.id,
                              }),
                            ),
                          if (!t.finished) ...[
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
                          if (t.path != null && widget.openFolder != null)
                            DeskButton(
                              '打开文件夹',
                              quiet: true,
                              onPressed: () => widget.openFolder!(t.path!),
                            ),
                          if (t.path != null &&
                              !t.cancelled &&
                              !t.outputPreserved &&
                              !t.imported)
                            DeskButton(
                              '加入书库',
                              key: ValueKey('booksource-import-${t.id}'),
                              quiet: true,
                              onPressed: () => _import(t),
                            ),
                          if (t.imported) const DeskTag('已加入书库', Tone.ok),
                          if (t.libraryKey != null && t.finished)
                            DeskButton(
                              '重新整理',
                              quiet: true,
                              onPressed: () => _rebuild(t.libraryKey!),
                            ),
                        ],
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

String _eta(int seconds) =>
    seconds < 60 ? '$seconds 秒' : '${seconds ~/ 60} 分 ${seconds % 60} 秒';
