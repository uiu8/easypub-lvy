// 待应用登记（G-061）：各页已生成但尚未确认的预览。只登记、只读，不执行任何应用。
//
// 页面在 build 中用 [PendingReporter.reportPending] 报告当前预览；页面卸载时自动撤销。
// 依据版本取登记时书稿的 contentVersion，之后书稿版本变化即判为“已过期”。
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../tokens.dart';
import '../widgets.dart';

class PendingChange {
  const PendingChange({
    required this.token,
    required this.domain,
    required this.summary,
    required this.location,
    this.bookId,
    this.stale = false,
    this.discard,
    this.regenerate,
  });

  /// 预览对象本身；同一对象再次报告时保留登记时间与依据版本。
  final Object token;
  final String domain, summary, location;
  final String? bookId;

  /// 页面自己已知过期（例如复核发现书稿已变）。
  final bool stale;

  /// 放弃预览：只清除页面上的候选，不改动书稿。
  final VoidCallback? discard;

  /// 重新生成：按当前书稿与设置重新预览；仍需在页面上确认才会应用。
  final VoidCallback? regenerate;
}

class PendingEntry {
  PendingEntry(this.key, this.change, this.basis, this.created);
  final String key;
  final PendingChange change;
  final String? basis;
  final DateTime created;
}

class PendingChangeRegistry extends ChangeNotifier {
  PendingChangeRegistry({required this.version, this.bookTitle, this.versions});

  /// 读取书稿当前内容版本；书已不在书库时返回 null。
  final String? Function(String bookId) version;
  final String? Function(String bookId)? bookTitle;

  /// 书稿版本变化的通知源（书库列表），用于刷新有效/过期。
  final Listenable? versions;
  Listenable get display => Listenable.merge([this, ?versions]);
  final _entries = <String, PendingEntry>{};
  var _scheduled = false, _disposed = false;

  List<PendingEntry> get entries => _entries.values.toList(growable: false);

  /// true 有效，false 已过期，null 无法判断（未绑定单本书）。
  bool? isValid(PendingEntry entry) {
    if (entry.change.stale) return false;
    final id = entry.change.bookId;
    if (id == null || entry.basis == null) return null;
    return version(id) == entry.basis;
  }

  void report(String key, PendingChange? change) {
    final old = _entries[key];
    if (change == null) {
      if (_entries.remove(key) != null) _changed();
      return;
    }
    if (old != null && identical(old.change.token, change.token)) {
      if (old.change.stale == change.stale &&
          old.change.summary == change.summary) {
        // 只更新回调，不通知。
        _entries[key] = PendingEntry(key, change, old.basis, old.created);
        return;
      }
      _entries[key] = PendingEntry(key, change, old.basis, old.created);
    } else {
      final id = change.bookId;
      _entries[key] = PendingEntry(
        key,
        change,
        id == null ? null : version(id),
        DateTime.now(),
      );
    }
    _changed();
  }

  /// 报告常发生在 build 或卸载期间，通知推迟到本帧结束。
  void _changed() {
    if (_scheduled || _disposed) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class PendingScope extends InheritedWidget {
  const PendingScope({super.key, required this.registry, required super.child});
  final PendingChangeRegistry registry;
  static PendingChangeRegistry? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PendingScope>()?.registry;
  @override
  bool updateShouldNotify(PendingScope oldWidget) =>
      registry != oldWidget.registry;
}

/// 页面报告自己的预览；没有 [PendingScope]（单页测试）时不做任何事。
mixin PendingReporter<T extends StatefulWidget> on State<T> {
  PendingChangeRegistry? _pending;
  late final String _pendingKey = '$T#${identityHashCode(this)}';

  void reportPending(PendingChange? change) {
    _pending ??= PendingScope.maybeOf(context);
    _pending?.report(_pendingKey, change);
  }

  @override
  void dispose() {
    _pending?.report(_pendingKey, null);
    super.dispose();
  }
}

/// 托盘左侧“待应用 N”；没有登记时不占位。
class PendingTrayButton extends StatelessWidget {
  const PendingTrayButton({
    super.key,
    required this.registry,
    required this.onOpen,
  });
  final PendingChangeRegistry registry;
  final ValueChanged<String> onOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry.display,
    builder: (context, _) {
      final entries = registry.entries;
      if (entries.isEmpty) return const SizedBox.shrink();
      final d = context.desk;
      final expired = entries.where((e) => registry.isValid(e) == false);
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Tooltip(
          message: '已生成但尚未确认的预览',
          child: InkWell(
            key: const ValueKey('pending-tray'),
            borderRadius: BorderRadius.circular(7),
            onTap: () => showPendingList(context, registry, onOpen),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: d.sunken,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: d.line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Dot(expired.isEmpty ? d.ink2 : d.tone(Tone.warn).$1),
                  const SizedBox(width: 6),
                  Text(
                    '待应用 ${entries.length}',
                    style: ui(12.5, w: 600, c: d.ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<void> showPendingList(
  BuildContext context,
  PendingChangeRegistry registry,
  ValueChanged<String> onOpen,
) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭待应用列表',
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (dialogContext, _, _) => SafeArea(
    child: Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 50),
        child: PendingList(
          registry: registry,
          onOpen: (location) {
            Navigator.of(dialogContext).pop();
            onOpen(location);
          },
        ),
      ),
    ),
  ),
);

/// 待应用列表（设计 D1 PendingList）：领域、书、生成时间、有效/过期；可打开或放弃。
class PendingList extends StatelessWidget {
  const PendingList({super.key, required this.registry, required this.onOpen});
  final PendingChangeRegistry registry;
  final ValueChanged<String> onOpen;

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Material(
      key: const ValueKey('pending-list'),
      color: d.surface,
      elevation: 0,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 360),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: d.shadow2,
          border: Border.all(color: d.line),
          color: d.surface,
        ),
        child: ListenableBuilder(
          listenable: registry.display,
          builder: (context, _) {
            final entries = registry.entries;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                  child: Row(
                    children: [
                      Text(
                        '待应用 ${entries.length} 项',
                        style: ui(12.5, w: 650, c: d.ink),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '预览只是草稿；确认应用才会改动编辑稿',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(11.5, c: d.ink3),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: d.line),
                if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text('没有待应用的预览。', style: ui(12.5, c: d.ink3)),
                  ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [for (final e in entries) _row(context, e)],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(BuildContext context, PendingEntry entry) {
    final d = context.desk;
    final change = entry.change;
    final valid = registry.isValid(entry);
    final book = change.bookId == null
        ? null
        : registry.bookTitle?.call(change.bookId!);
    final parts = [
      ?book,
      change.summary,
      '生成于 ${_time(entry.created)}',
      if (valid == false) '之后书稿已修改',
      if (valid == null) '确认时复核',
    ];
    return Padding(
      key: ValueKey('pending-${entry.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        change.domain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(13, w: 600, c: d.ink),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (valid != null)
                      DeskTag(
                        valid ? '有效' : '已过期',
                        valid ? Tone.ok : Tone.warn,
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  parts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(11.5, c: d.ink3),
                ),
              ],
            ),
          ),
          if (valid != true && change.regenerate != null) ...[
            const SizedBox(width: 6),
            TextButton(
              onPressed: () {
                change.regenerate!();
                onOpen(change.location);
              },
              child: const Text('重新生成'),
            ),
          ],
          if (change.discard != null) ...[
            const SizedBox(width: 6),
            TextButton(onPressed: change.discard, child: const Text('放弃')),
          ],
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed: () => onOpen(change.location),
            child: const Text('打开'),
          ),
        ],
      ),
    );
  }
}
