// 自动更新的界面（V68，SET-071–073）：控制器、顶栏提示、更新对话框与设置页“版本与更新”。
// 检查只访问 GitHub 发布页；下载在后台，校验通过才可以“重启并更新”；重启前先走离开保护。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../application/app_update_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../errors.dart';
import '../tokens.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  skipped,
  downloading,
  ready,
  failed,
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.service,
    required this.readConfig,
    required this.saveConfig,
    required this.blockedByTasks,
    Future<void> Function()? exitApp,
    this.pollInterval = const Duration(milliseconds: 300),
  }) : exitApp = exitApp ?? windowManager.destroy;
  final AppUpdateService service;
  final Map<String, dynamic> Function() readConfig;
  final Future<bool> Function(Map<String, dynamic> patch) saveConfig;
  final bool Function() blockedByTasks;
  final Future<void> Function() exitApp;
  final Duration pollInterval;

  UpdateStatus? status;
  UpdatePhase phase = UpdatePhase.idle;
  UpdateRelease? latest;
  UpdateProgress? progress;
  String error = '';
  DateTime? checkedAt;
  bool _disposed = false;

  /// 失败发生在下载阶段（重试时直接重新下载，不必再检查）。
  bool _downloadFailed = false;

  bool get autoCheck => readConfig()['update_check_on_start'] != false;
  int? get skippedRelease => readConfig()['update_skipped_release'] as int?;

  /// 顶栏提示：有新版本（未跳过）、下载中、待重启。
  bool get showsPill => const {
    UpdatePhase.available,
    UpdatePhase.downloading,
    UpdatePhase.ready,
  }.contains(phase);

  void _set(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  /// 启动时调用：读状态；发布包运行且开着“启动时检查”时，稍后静默检查一次。
  Future<void> start({Duration delay = const Duration(seconds: 4)}) async {
    await refresh();
    if (status?.packaged != true || !autoCheck || phase == UpdatePhase.ready) {
      return;
    }
    await Future<void>.delayed(delay);
    if (!_disposed) await check(manual: false);
  }

  Future<void> refresh() async {
    try {
      final next = await service.status();
      _set(() {
        status = next;
        if (next.ready case final ready?) {
          latest = ready;
          phase = UpdatePhase.ready;
        }
      });
    } catch (_) {
      // 读不到状态时按开发版本处理，不影响使用。
    }
  }

  /// [manual] 为 false（启动时自动检查）时：失败不打扰，已跳过的版本不提示。
  Future<void> check({bool manual = true}) async {
    if (phase == UpdatePhase.checking ||
        phase == UpdatePhase.downloading ||
        phase == UpdatePhase.ready) {
      return;
    }
    _set(() {
      phase = UpdatePhase.checking;
      error = '';
    });
    try {
      final result = await service.check();
      _set(() {
        checkedAt = DateTime.now();
        latest = result.latest;
        phase = !result.available
            ? UpdatePhase.upToDate
            : (!manual && skippedRelease == result.latest.release)
            ? UpdatePhase.skipped
            : UpdatePhase.available;
      });
    } catch (e) {
      _set(() {
        checkedAt = DateTime.now();
        error = deskErrorText(e, '检查更新失败，请稍后重试。');
        phase = manual ? UpdatePhase.failed : UpdatePhase.idle;
      });
    }
  }

  Future<void> skip() async {
    final release = latest?.release;
    if (release == null) return;
    await saveConfig({'update_skipped_release': release});
    _set(() => phase = UpdatePhase.skipped);
  }

  Future<void> setAutoCheck(bool value) async {
    await saveConfig({'update_check_on_start': value});
    _set(() {});
  }

  Future<void> download() async {
    final release = latest?.release;
    if (release == null || phase == UpdatePhase.downloading) return;
    try {
      final started = await service.download(release);
      _set(() {
        progress = started;
        phase = UpdatePhase.downloading;
        error = '';
        _downloadFailed = false;
      });
      while (!_disposed) {
        await Future<void>.delayed(pollInterval);
        final next = await service.poll(started.jobId);
        _set(() => progress = next);
        if (next.active) continue;
        if (next.phase == 'completed') {
          await refresh();
        } else if (next.phase == 'cancelled') {
          _set(() => phase = UpdatePhase.available);
        } else {
          _set(() {
            error = deskErrorReason(next.error ?? '') ?? '下载失败，请稍后重试。';
            phase = UpdatePhase.failed;
            _downloadFailed = true;
          });
        }
        return;
      }
    } catch (e) {
      _set(() {
        error = deskErrorText(e, '下载失败，请稍后重试。');
        phase = UpdatePhase.failed;
        _downloadFailed = true;
      });
    }
  }

  Future<void> retry() async {
    if (_downloadFailed && latest != null) {
      _set(() => phase = UpdatePhase.available);
      await download();
    } else {
      _set(() => phase = UpdatePhase.idle);
      await check();
    }
  }

  Future<void> cancel() async {
    final id = progress?.jobId;
    if (id == null || phase != UpdatePhase.downloading) return;
    try {
      await service.cancel(id);
    } catch (_) {
      // 下载已结束时忽略。
    }
  }

  /// 重启并更新（[mode] = update）或回退到上一版（rollback）。
  /// [leave] 走工作区离开保护；返回 null 表示已退出程序，否则返回不能重启的原因。
  Future<String?> restart(String mode, Future<bool> Function() leave) async {
    if (blockedByTasks()) return '有任务正在进行。等它完成后再重启更新。';
    if (!await leave()) return '已取消。';
    try {
      await service.launch(mode);
    } catch (e) {
      return deskErrorText(e, '无法启动更新程序。');
    }
    await exitApp();
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 向下提供更新控制器（顶栏与设置页共用）。
class AppUpdateScope extends InheritedNotifier<AppUpdateController> {
  const AppUpdateScope({
    super.key,
    required AppUpdateController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppUpdateController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUpdateScope>()?.notifier;
}

String _size(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// 顶栏的版本提示：有新版本 / 下载进度 / 重启以更新。
class UpdatePill extends StatelessWidget {
  const UpdatePill({super.key, required this.controller, required this.leave});
  final AppUpdateController controller;
  final Future<bool> Function() leave;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.showsPill) return const SizedBox.shrink();
        final p = controller.progress;
        final text = switch (controller.phase) {
          UpdatePhase.downloading when p != null && p.total > 0 =>
            '正在下载 ${(p.received * 100 / p.total).floor()}%',
          UpdatePhase.downloading => '正在下载',
          UpdatePhase.ready => '重启以更新',
          _ => '新版本 V${controller.latest?.release ?? ''}',
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Material(
            key: const ValueKey('update-pill'),
            color: d.accentSoft,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => showUpdateDialog(context, controller, leave),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_circle_up_rounded, size: 15, color: d.ink),
                    const SizedBox(width: 5),
                    Text(text, style: ui(12, w: 600, c: d.ink)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showUpdateDialog(
  BuildContext context,
  AppUpdateController controller,
  Future<bool> Function() leave,
) => showDialog<void>(
  context: context,
  builder: (_) => UpdateDialog(controller: controller, leave: leave),
);

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.controller,
    required this.leave,
  });
  final AppUpdateController controller;
  final Future<bool> Function() leave;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  String restartNote = '';
  bool restarting = false;

  AppUpdateController get c => widget.controller;

  Future<void> restart() async {
    setState(() => restarting = true);
    final why = await c.restart('update', widget.leave);
    if (mounted) {
      setState(() {
        restarting = false;
        restartNote = why ?? '';
      });
    }
  }

  Widget notes(Desk d, UpdateRelease r) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(maxHeight: 220),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: d.sunken,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SingleChildScrollView(
      child: Text(
        r.notes.trim().isEmpty ? '（这个版本没有附更新说明）' : r.notes.trim(),
        key: const ValueKey('update-notes'),
        style: ui(12.5, c: d.ink2, h: 1.6),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final r = c.latest;
        final current = c.status?.currentRelease;
        final close = DeskButton('关闭', onPressed: () => Navigator.pop(context));
        final (
          String title,
          String? subtitle,
          Widget body,
          List<Widget> actions,
        ) = switch (c.phase) {
          UpdatePhase.checking => (
            '正在检查更新',
            null,
            const LinearProgressIndicator(),
            [close],
          ),
          UpdatePhase.available || UpdatePhase.skipped when r != null => (
            '发现新版本 V${r.release}',
            '当前 V${current ?? '?'} · ${r.date} · 下载约 ${_size(r.bytes)}',
            notes(d, r),
            [
              DeskButton('以后再说', onPressed: () => Navigator.pop(context)),
              if (c.phase == UpdatePhase.available)
                DeskButton(
                  '跳过这个版本',
                  key: const ValueKey('update-skip'),
                  onPressed: () async {
                    await c.skip();
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              DeskButton(
                '下载更新',
                key: const ValueKey('update-download'),
                primary: true,
                onPressed: c.status?.writable == false
                    ? null
                    : () => unawaited(c.download()),
              ),
            ],
          ),
          UpdatePhase.downloading => (
            '正在下载 V${r?.release ?? ''}',
            '可以继续使用，下载在后台进行',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  key: const ValueKey('update-progress'),
                  value: switch (c.progress) {
                    final p? when p.total > 0 && p.phase == 'downloading' =>
                      p.received / p.total,
                    _ => null,
                  },
                ),
                const SizedBox(height: 8),
                Text(switch (c.progress) {
                  final p? when p.phase == 'extracting' => '正在解压…',
                  final p? when p.phase == 'verifying' => '正在逐个核对文件…',
                  final p? => '${_size(p.received)} / ${_size(p.total)}',
                  null => '',
                }, style: ui(12, c: d.ink2)),
              ],
            ),
            [
              DeskButton(
                '取消下载',
                key: const ValueKey('update-cancel'),
                onPressed: () => unawaited(c.cancel()),
              ),
              DeskButton('后台下载', onPressed: () => Navigator.pop(context)),
            ],
          ),
          UpdatePhase.ready when r != null => (
            'V${r.release} 已下载并校验',
            '大小、SHA-256 与发布签名都已核对',
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                notes(d, r),
                const SizedBox(height: 10),
                const DeskNote(
                  '重启时程序先退出，替换文件后自动打开新版本；书库、设置与草稿不受影响。'
                  '替换失败会自动恢复旧版本。上一版保留一份，可以在设置里回退。',
                ),
                if (restartNote.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    restartNote,
                    key: const ValueKey('update-restart-note'),
                    style: ui(12.5, c: d.warn),
                  ),
                ],
              ],
            ),
            [
              DeskButton('稍后', onPressed: () => Navigator.pop(context)),
              DeskButton(
                '重启并更新',
                key: const ValueKey('update-restart'),
                primary: true,
                busy: restarting,
                onPressed: restarting ? null : () => unawaited(restart()),
              ),
            ],
          ),
          UpdatePhase.upToDate => (
            '已是最新版本',
            '当前 V${current ?? '?'}',
            const SizedBox.shrink(),
            [close],
          ),
          _ => (
            c.phase == UpdatePhase.failed ? '没有完成' : '检查更新',
            null,
            Text(
              c.error.isEmpty ? '还没有检查过更新。' : c.error,
              key: const ValueKey('update-error'),
              style: ui(13, c: d.ink2, h: 1.6),
            ),
            [
              if ((c.status?.releasesUrl ?? '').isNotEmpty)
                DeskButton(
                  '打开发布页',
                  onPressed: () => unawaited(
                    Process.start('explorer.exe', [c.status!.releasesUrl]),
                  ),
                ),
              DeskButton(
                '重试',
                key: const ValueKey('update-retry'),
                primary: true,
                onPressed: () => unawaited(c.retry()),
              ),
            ],
          ),
        };
        return DeskDialog(
          title: title,
          subtitle: subtitle,
          closeTooltip: '关闭',
          width: 480,
          actions: actions,
          child: body,
        );
      },
    );
  }
}

/// 设置 · 关于与许可里的“版本与更新”。开发版本（未打包）只显示说明。
class UpdateSettingsGroup extends StatefulWidget {
  const UpdateSettingsGroup({super.key, required this.leave});
  final Future<bool> Function() leave;
  @override
  State<UpdateSettingsGroup> createState() => _UpdateSettingsGroupState();
}

class _UpdateSettingsGroupState extends State<UpdateSettingsGroup> {
  String note = '';

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final c = AppUpdateScope.maybeOf(context);
    if (c == null) return const SizedBox.shrink();
    final status = c.status;
    Widget row(String label, String detail, Widget trailing, {Key? key}) =>
        Container(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: d.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: ui(13, c: d.ink)),
                    if (detail.isNotEmpty)
                      Text(detail, style: ui(11.5, c: d.ink3, h: 1.5)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              trailing,
            ],
          ),
        );
    if (status == null || !status.packaged) {
      return row(
        '自动更新',
        '直接从源码运行的开发版本不检查更新；发布包里才有更新程序。',
        const SizedBox.shrink(),
        key: const ValueKey('update-settings-dev'),
      );
    }
    final last = c.checkedAt;
    return Column(
      key: const ValueKey('update-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          '启动时检查更新',
          '只访问 GitHub 上的发布页，不上传任何数据。',
          Switch(
            key: const ValueKey('update-auto-check'),
            value: c.autoCheck,
            onChanged: (v) => unawaited(c.setAutoCheck(v)),
          ),
        ),
        row(
          '检查更新',
          switch (c.phase) {
            UpdatePhase.checking => '正在检查…',
            UpdatePhase.upToDate => '已是最新版本',
            UpdatePhase.available || UpdatePhase.skipped =>
              '发现 V${c.latest?.release}${c.phase == UpdatePhase.skipped ? '（已跳过）' : ''}',
            UpdatePhase.downloading => '正在下载 V${c.latest?.release}',
            UpdatePhase.ready => 'V${c.latest?.release} 已下载，重启即可更新',
            UpdatePhase.failed => c.error,
            UpdatePhase.idle => last == null ? '本次启动还没有检查' : '',
          },
          DeskButton(
            c.phase == UpdatePhase.idle ||
                    c.phase == UpdatePhase.upToDate ||
                    c.phase == UpdatePhase.failed
                ? '检查更新'
                : '查看',
            key: const ValueKey('update-check'),
            onPressed: c.phase == UpdatePhase.checking
                ? null
                : () async {
                    if (const {
                      UpdatePhase.idle,
                      UpdatePhase.upToDate,
                      UpdatePhase.failed,
                    }.contains(c.phase)) {
                      await c.check();
                    }
                    if (context.mounted) {
                      await showUpdateDialog(context, c, widget.leave);
                    }
                  },
          ),
        ),
        if (!status.writable)
          row(
            '程序目录不能写入',
            '装在只读位置（例如 Program Files）时不能自动更新；请把程序解压到自己的文件夹，或到发布页手动下载。',
            const SizedBox.shrink(),
          ),
        if (status.backupRelease case final backup?)
          row(
            '回退到上一版',
            '上一版 V$backup 保留在程序目录的 .update 里；回退时程序会重启。'
                '${note.isEmpty ? '' : '\n$note'}',
            DeskButton(
              '回退到 V$backup…',
              key: const ValueKey('update-rollback'),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => DeskDialog(
                    title: '回退到 V$backup',
                    closeTooltip: '取消',
                    actions: [
                      DeskButton(
                        '取消',
                        onPressed: () => Navigator.pop(context, false),
                      ),
                      DeskButton(
                        '回退并重启',
                        key: const ValueKey('update-rollback-confirm'),
                        primary: true,
                        onPressed: () => Navigator.pop(context, true),
                      ),
                    ],
                    child: Text(
                      '程序会退出，换回 V$backup 后重新打开。书库、设置与草稿不受影响。',
                      style: ui(13, c: d.ink2, h: 1.6),
                    ),
                  ),
                );
                if (ok != true) return;
                final why = await c.restart('rollback', widget.leave);
                if (why != null && mounted) setState(() => note = why);
              },
            ),
          ),
        if (status.lastError case final e?)
          row(
            '上次更新没有完成',
            '${deskErrorReason(e) ?? e}；已自动恢复原来的版本。',
            const SizedBox.shrink(),
          ),
      ],
    );
  }
}
