// 设置 · 数据与迁移 · 存储位置（V104，SET-108–112）：软件数据位置与搬家、缓存位置与按类清理、
// 封面和插图的存放方式与已有图片迁入。只调后端协议，不自己读写这些目录。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/storage_settings_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

class StorageSettingsGroup extends StatefulWidget {
  const StorageSettingsGroup({
    super.key,
    required this.service,
    required this.chooseFolder,
    required this.restart,
    this.bookTitle,
    this.pollInterval = const Duration(milliseconds: 300),
  });
  final StorageSettingsService service;

  /// 选文件夹；取消时为空。
  final Future<String?> Function() chooseFolder;

  /// 重启软件（先走离开保护）；返回不能重启的原因，已退出时返回 null。
  final Future<String?> Function() restart;

  /// 由书 id 找书名（图片迁入结果用）。
  final String Function(String bookId)? bookTitle;
  final Duration pollInterval;

  @override
  State<StorageSettingsGroup> createState() => _StorageSettingsGroupState();
}

class _StorageSettingsGroupState extends State<StorageSettingsGroup> {
  Map<String, dynamic>? status, stats;
  String error = '', notice = '';
  bool busy = false;

  /// 正在进行的搬家：job_id 与最近一次进度。
  String? moveJob;
  Map<String, dynamic>? moveProgress;
  Timer? _poll;

  StorageSettingsService get service => widget.service;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final next = await service.storageStatus();
      final usage = await service.storageStats();
      if (!mounted) return;
      setState(() {
        status = next;
        stats = usage;
        error = '';
      });
    } catch (e) {
      if (mounted) setState(() => error = storageErrorText(e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = storageErrorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
      await refresh();
    }
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => DeskDialog(
          title: title,
          closeTooltip: '取消',
          actions: [
            DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
            DeskButton(
              action,
              key: const ValueKey('storage-confirm'),
              primary: true,
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
          child: Text(text, style: ui(13, c: context.desk.ink, h: 1.6)),
        ),
      ) ==
      true;

  // ---------------------------------------------------------------- 搬家

  Future<void> moveData() async {
    final target = await widget.chooseFolder();
    if (target == null || !mounted) return;
    if (!await _confirm(
      '把软件数据搬到新位置？',
      '新位置：$target\n\n'
          '会先保存当前工作区并暂停书源插件，再把工作区、书库记录、复制进来的图片、插件和插件数据复制过去，逐个文件核对。'
          '核对无误后，重启软件才换到新位置；原位置的数据保留，不会删除。\n\n'
          '目标文件夹必须是空的。搬家期间请不要编辑书稿；重启前继续编辑的话，新副本会作废，下次仍用原位置。',
      '开始搬家',
    )) {
      return;
    }
    await _run(() async {
      final started = await service.moveStorage(target);
      moveJob = started['job_id'] as String;
      moveProgress = {'phase': 'queued'};
      _poll?.cancel();
      _poll = Timer.periodic(widget.pollInterval, (_) => _pollMove());
    });
  }

  Future<void> _pollMove({bool cancel = false}) async {
    final job = moveJob;
    if (job == null) return;
    try {
      final next = await service.storageMoveProgress(job, cancel: cancel);
      if (!mounted) return;
      final phase = next['phase'];
      setState(() => moveProgress = next);
      if (phase == 'ready' || phase == 'failed' || phase == 'cancelled') {
        _poll?.cancel();
        setState(() {
          moveJob = null;
          if (phase == 'failed') {
            error = storageErrorText('${next['error'] ?? 'storage_io_error'}');
          } else if (phase == 'cancelled') {
            notice = '搬家已取消，原位置没有改动。';
          }
        });
        await refresh();
      }
    } catch (e) {
      _poll?.cancel();
      if (mounted) {
        setState(() {
          moveJob = null;
          error = storageErrorText(e);
        });
      }
    }
  }

  // ---------------------------------------------------------------- 缓存

  Future<void> chooseCache({String? path}) async {
    final target = path ?? await widget.chooseFolder();
    if (target == null || !mounted) return;
    await _run(() async {
      await service.setCacheRoot(target);
      if (mounted) setState(() => notice = '缓存改放到 $target。旧缓存留在原处，可以在下面清理。');
    });
  }

  Future<void> clean(List<String> kinds, int bytes) async {
    if (!await _confirm(
      '清理缓存？',
      '清理${kinds.map((k) => '“${cacheKindLabels[k] ?? k}”').join('、')}，约 ${formatStorageBytes(bytes)}。'
          '这些都是可以重新生成的临时文件；正在使用的会跳过。',
      '清理',
    )) {
      return;
    }
    await _run(() async {
      final result = await service.cleanCache(kinds);
      var deleted = 0, skipped = 0;
      var previewOpen = false;
      for (final r
          in (result['categories'] as List? ?? const []).whereType<Map>()) {
        deleted += (r['deleted_bytes'] as num?)?.toInt() ?? 0;
        if (r['skipped'] == 'preview_open') {
          previewOpen = true;
        } else if (r['skipped'] != null) {
          skipped++;
        }
        skipped += (r['skipped_files'] as num?)?.toInt() ?? 0;
      }
      if (mounted) {
        setState(
          () => notice =
              '已清理 ${formatStorageBytes(deleted)}'
              '${skipped > 0 ? '；$skipped 项正在使用或无法删除，已跳过' : ''}'
              '${previewOpen ? '；真机预览窗口还开着，这一类没清理，关掉预览窗口后再清理' : ''}。',
        );
      }
    });
  }

  // ---------------------------------------------------------------- 图片

  Future<void> copyImages() async {
    if (!await _confirm(
      '把已有书引用的图片复制进软件？',
      '逐本检查封面和插图：还在外面的原图复制进软件，书改为引用复制件，原图不动。'
          '找不到或读不出的图会逐项列出，那些书仍保留原来的引用。确认后记入变更记录。',
      '复制',
    )) {
      return;
    }
    await _run(() async {
      final result = await service.copyReferencedImages();
      if (!mounted) return;
      final missing = (result['missing'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      setState(
        () => notice =
            '已复制 ${result['copied'] ?? 0} 处引用'
            '${missing.isEmpty ? '。' : '；${missing.length} 处找不到原图，见下方清单。'}',
      );
      if (missing.isNotEmpty) await _showMissing(missing);
    });
  }

  Future<void> _showMissing(List<Map> missing) => showDialog<void>(
    context: context,
    builder: (context) {
      final d = context.desk;
      return DeskDialog(
        title: '这些图片没有复制',
        subtitle: '原图找不到或读不出；书仍引用原来的位置，可以在书籍信息或图片资源里重新定位。',
        closeTooltip: '关闭',
        width: 560,
        actions: [
          DeskButton(
            '知道了',
            primary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              key: const ValueKey('storage-missing-images'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final m in missing)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${widget.bookTitle?.call('${m['book_id']}') ?? m['book_id']} · '
                      '${m['index'] == -1 ? '封面' : '第 ${(m['index'] as num) + 1} 张插图'} · '
                      '${m['reason'] == 'missing' ? '找不到' : '读不出'}\n${m['path']}',
                      style: ui(12, c: d.ink2, h: 1.5),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  // ---------------------------------------------------------------- 视图

  Widget row(String label, Widget value, [Widget? action]) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: ui(13, c: d.ink)),
          ),
          Expanded(child: value),
          if (action != null) ...[const SizedBox(width: 12), action],
        ],
      ),
    );
  }

  Widget pathText(String text, {String? detail, Key? key}) {
    final d = context.desk;
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Tooltip(
          message: text,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mono(11.5, c: d.ink),
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 2),
          Text(detail, style: ui(11.5, c: d.ink3, h: 1.45)),
        ],
      ],
    );
  }

  Widget banner(String text, {required bool warn, Widget? action, Key? key}) {
    final d = context.desk;
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: warn ? d.warnSoft : d.sunken,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            warn ? Icons.info_outline_rounded : Icons.check_circle_outline,
            size: 16,
            color: warn ? d.warn : d.ink2,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: ui(12.5, c: d.ink, h: 1.5)),
          ),
          ?action,
        ],
      ),
    );
  }

  Widget title(String text) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(text, style: ui(13, w: 650, c: d.ink2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final s = status;
    if (s == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          error.isEmpty ? '正在读取存储位置…' : error,
          style: ui(12.5, c: error.isEmpty ? d.ink3 : d.pen),
        ),
      );
    }
    final data = groupStorageRows(stats?['data'] as List? ?? const []);
    final cache = groupStorageRows(stats?['cache'] as List? ?? const []);
    final dataBytes = data.values.fold(0, (n, v) => n + v.$1);
    final cleanable = [
      for (final e in cache.entries)
        if (!protectedCacheKinds.contains(e.key) && e.value.$1 > 0) e.key,
    ];
    final cleanableBytes = cleanable.fold(0, (n, k) => n + cache[k]!.$1);
    final progress = moveProgress;
    final moving = moveJob != null;
    final unified = s['cache_layout'] == 'unified';
    final startup = s['startup_error'] as String?;
    return Column(
      key: const ValueKey('storage-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s['pending_restart'] == true)
          banner(
            '软件数据已复制到 ${s['pending_data_root']} 并核对无误，重启后生效。'
            '在那之前继续编辑的话，新副本会作废，下次启动仍用原位置。',
            warn: true,
            key: const ValueKey('storage-pending-restart'),
            action: DeskButton(
              '立即重启',
              key: const ValueKey('storage-restart'),
              onPressed: () async {
                final why = await widget.restart();
                if (why != null && mounted) setState(() => notice = why);
              },
            ),
          ),
        if (startup != null)
          banner(
            '上次启动时：${storageErrorText(startup)}',
            warn: true,
            key: const ValueKey('storage-startup-error'),
          ),
        if (error.isNotEmpty)
          banner(error, warn: true, key: const ValueKey('storage-error')),
        if (notice.isNotEmpty)
          banner(notice, warn: false, key: const ValueKey('storage-notice')),
        title('软件数据'),
        row(
          '位置',
          pathText(
            '${s['data_root']}',
            key: const ValueKey('storage-data-root'),
            detail:
                '工作区、书库记录、复制进来的图片、插件和插件数据 · 共 ${formatStorageBytes(dataBytes)}',
          ),
          DeskButton(
            '更改位置…',
            key: const ValueKey('storage-move'),
            onPressed: busy || moving || s['pending_restart'] == true
                ? null
                : moveData,
          ),
        ),
        if (moving || progress?['phase'] == 'ready')
          row(
            '搬家进度',
            Column(
              key: const ValueKey('storage-move-progress'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: switch ((progress?['done'], progress?['total'])) {
                    (final num done, final num total) when total > 0 =>
                      (done / total).clamp(0.0, 1.0).toDouble(),
                    _ => progress?['phase'] == 'ready' ? 1.0 : null,
                  },
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(3),
                ),
                const SizedBox(height: 4),
                Text(switch (progress?['phase']) {
                  'scan' => '正在清点要复制的文件…',
                  'copy' =>
                    '正在复制 ${formatStorageBytes((progress?['done'] as num?) ?? 0)} / '
                        '${formatStorageBytes((progress?['total'] as num?) ?? 0)} · 书源插件已暂停',
                  'verify' => '正在逐个文件核对…',
                  'ready' => '已复制并核对无误，重启后生效。',
                  _ => '正在准备…',
                }, style: ui(11.5, c: d.ink3)),
              ],
            ),
            moving
                ? DeskButton(
                    '取消',
                    key: const ValueKey('storage-move-cancel'),
                    onPressed: () => _pollMove(cancel: true),
                  )
                : null,
          ),
        title('缓存'),
        row(
          '位置',
          pathText(
            unified ? '${s['cache_root']}' : '分散在默认位置（兼容旧版）',
            key: const ValueKey('storage-cache-root'),
            detail: unified
                ? '预览、转换中间文件、解包与生成的封面都放在这里；改位置时旧缓存不搬，留在原处可以清理。'
                : '可以统一放到 ${s['suggested_cache_root']}，或另选一个空文件夹；旧缓存不搬，留在原处可以清理。',
          ),
          Wrap(
            spacing: 6,
            children: [
              if (!unified && s['suggested_cache_root'] != null)
                DeskButton(
                  '用建议位置',
                  key: const ValueKey('storage-cache-suggested'),
                  quiet: true,
                  onPressed: busy || moving
                      ? null
                      : () => chooseCache(path: '${s['suggested_cache_root']}'),
                ),
              DeskButton(
                '选择位置…',
                key: const ValueKey('storage-cache-choose'),
                onPressed: busy || moving ? null : () => chooseCache(),
              ),
            ],
          ),
        ),
        for (final kind in cacheKindLabels.keys)
          if (cache[kind] case (final bytes, final places))
            Container(
              key: ValueKey('storage-cache-$kind'),
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: d.line)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 104),
                  Expanded(
                    child: Tooltip(
                      message: places.join('\n'),
                      child: Text(
                        cacheKindLabels[kind]!,
                        style: ui(12.5, c: d.ink),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 84,
                    child: Text(
                      formatStorageBytes(bytes),
                      textAlign: TextAlign.right,
                      style: mono(11.5, c: d.ink2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 150,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: protectedCacheKinds.contains(kind)
                          ? const DeskTag('保留 · 书库可能在引用', Tone.neutral)
                          : DeskTag(
                              kind == 'kindle_preview'
                                  ? '可清理 · 预览开着时跳过'
                                  : '可清理',
                              Tone.ok,
                            ),
                    ),
                  ),
                ],
              ),
            ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '“保留”的几类这一版不清理：旧书可能还在引用解包文件与生成的封面。真机预览窗口开着时，这一类会跳过；正在用的也会自动跳过。'
                  '书源下载的章节缓存追更要用，在书源插件的设置里管理。',
                  style: ui(11.5, c: d.ink3, h: 1.45),
                ),
              ),
              const SizedBox(width: 12),
              DeskButton(
                cleanable.isEmpty
                    ? '没有可清理的'
                    : '清理可清理的 ${formatStorageBytes(cleanableBytes)}',
                key: const ValueKey('storage-clean'),
                onPressed: busy || moving || cleanable.isEmpty
                    ? null
                    : () => clean(cleanable, cleanableBytes),
              ),
            ],
          ),
        ),
        title('封面和插图'),
        row(
          '新加的图片',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyedSubtree(
                key: const ValueKey('storage-image-mode'),
                child: DeskSegmented<String>(
                  value: '${s['image_mode'] ?? 'copy'}',
                  options: const {'copy': '复制进软件（推荐）', 'reference': '只记原路径'},
                  onChanged: busy || moving
                      ? null
                      : (mode) => _run(() => service.setImageMode(mode)),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '复制进软件后，原图挪走、删掉也不影响；相同的图只存一份。只记原路径时，原图挪走后要“重新定位资源”。',
                style: ui(11.5, c: d.ink3, h: 1.45),
              ),
            ],
          ),
        ),
        row(
          '已有的书',
          Text(
            '书里引用的原图还在外面的，可以一次复制进来；找不到的原图会逐项列出，原引用保留。',
            style: ui(11.5, c: d.ink3, h: 1.45),
          ),
          DeskButton(
            '复制已有图片…',
            key: const ValueKey('storage-copy-images'),
            onPressed: busy || moving ? null : copyImages,
          ),
        ),
        const SizedBox(height: 4),
        Text('成品文件夹在“成品与输出”里设置，备份文件夹在本页下方设置。', style: ui(11.5, c: d.ink3)),
      ],
    );
  }
}
