// 手工标注块（V53，LAY-123）：章节页行号栏框选、浮动工具条、已有标注的括号与类型标签、失效提示。
// 数据与输出由 V52 的 BlockAnnotationSession 提供；所有写入先预览、再确认，进入“制作”变更记录。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/block_annotation_service.dart';
import '../../application/layout_service.dart' show insetTypes;
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 工具条与菜单里可选的类别（`none` 显示为“取消识别”：此范围不参与自动识别）。
/// 系统提示可指定样式（V78，LAY-134）：按行数（一行单行提示、多行面板）、单行提示、面板。
const blockMarkChoices = <(BlockAnnotationKind, String?, String)>[
  (BlockAnnotationKind.letter, null, '书信'),
  (BlockAnnotationKind.quote, null, '引文'),
  (BlockAnnotationKind.verse, null, '诗词'),
  (BlockAnnotationKind.system, null, '系统提示'),
  (BlockAnnotationKind.system, 'note', '系统提示 · 单行'),
  (BlockAnnotationKind.system, 'panel', '系统提示 · 面板'),
  (BlockAnnotationKind.none, null, '取消识别'),
];

/// 场景（V81，LAY-135）：工具条与菜单里收在“场景”下面，九种场景各一项。
final insetMarkChoices = <(BlockAnnotationKind, String?, String)>[
  for (final e in insetTypes.entries)
    (BlockAnnotationKind.inset, e.key, '场景 · ${e.value}'),
];

String blockMarkLabel(BlockAnnotationKind kind, [String? variant]) => [
  ...blockMarkChoices,
  ...insetMarkChoices,
].firstWhere((c) => c.$1 == kind && c.$2 == variant).$3;

/// 按钮与菜单项的标识：没有样式时沿用类别名。
String blockMarkKey(BlockAnnotationKind kind, String? variant) =>
    variant == null ? kind.name : '${kind.name}-$variant';

/// 场景各角色的名称（V82，LAY-138）。
const insetRoleLabels = {
  'head': '标题',
  'body': '正文',
  'end': '落款',
  'say': '发言',
  'time': '时间',
  'date': '日期',
  'floor': '楼层',
  'count': '转评赞',
  'reply': '回复',
  'mast': '报头',
  'headline': '大标题',
  'by': '署名',
};

/// 每种场景能用的角色：与 Rust `insets::allowed_roles` 一致。
const insetAllowedRoles = {
  'chat': ['head', 'time', 'say', 'body'],
  'post': ['head', 'body', 'count', 'reply'],
  'forum': ['floor', 'body'],
  'diary': ['date', 'body'],
  'classic': ['head', 'body', 'end'],
  'edict': ['head', 'body', 'end'],
  'scroll': ['head', 'body', 'end'],
  'notice': ['head', 'body', 'end'],
  'news': ['mast', 'headline', 'by', 'body'],
};

/// 逐行设置对话框：每个非空行选“自动”或一个角色；返回新的逐行角色，取消为 null。
Future<Map<int, String>?> showInsetRolesDialog(
  BuildContext context,
  BlockAnnotationView view,
) => showDialog<Map<int, String>>(
  context: context,
  builder: (_) => _RolesDialog(view: view),
);

class _RolesDialog extends StatefulWidget {
  const _RolesDialog({required this.view});
  final BlockAnnotationView view;
  @override
  State<_RolesDialog> createState() => _RolesDialogState();
}

class _RolesDialogState extends State<_RolesDialog> {
  late final roles = Map<int, String>.of(widget.view.roles);

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final view = widget.view;
    final lines = view.lines ?? const <String>[];
    final auto = view.autoRoles ?? const <String>[];
    final allowed = insetAllowedRoles[view.variant] ?? const <String>[];
    return DeskDialog(
      title: '逐行设置：${blockMarkLabel(view.kind, view.variant)}',
      closeTooltip: '取消',
      width: 720,
      actions: [
        DeskButton(
          '全部改回自动',
          key: const ValueKey('inset-roles-reset'),
          quiet: true,
          onPressed: roles.isEmpty ? null : () => setState(roles.clear),
        ),
        DeskButton('取消', onPressed: () => Navigator.pop(context)),
        DeskButton(
          '应用',
          key: const ValueKey('inset-roles-apply'),
          primary: true,
          onPressed: () => Navigator.pop(context, Map.of(roles)),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, text) in lines.indexed)
                if (text.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          child: Text('${i + 1}', style: ui(12, c: d.ink3)),
                        ),
                        Expanded(
                          child: Text(
                            text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(
                              13,
                              c: d.ink,
                              w: roles.containsKey(i) ? 600 : 400,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        DropdownButton<String?>(
                          key: ValueKey(('inset-role', i)),
                          value: roles[i],
                          isDense: true,
                          items: [
                            DropdownMenuItem(
                              value: null,
                              child: Text(
                                '自动（${insetRoleLabels[i < auto.length ? auto[i] : 'body'] ?? '正文'}）',
                                style: ui(12.5, c: d.ink2),
                              ),
                            ),
                            for (final r in allowed)
                              DropdownMenuItem(
                                value: r,
                                child: Text(
                                  insetRoleLabels[r]!,
                                  style: ui(12.5, c: d.ink),
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() {
                            if (v == null) {
                              roles.remove(i);
                            } else {
                              roles[i] = v;
                            }
                          }),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 6),
              Text(
                '改过的行显示为粗体；空行不能指定。改场景类型时逐行设置会清空。',
                style: ui(11.5, c: d.ink3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一行在某条标注中的位置。
typedef BlockMarkLine = ({BlockAnnotationView view, bool first, bool last});

/// 一本书的标注状态。章节页创建并释放；正文组件监听它重绘。
class BlockMarkController extends ChangeNotifier {
  BlockMarkController(this.session) {
    session.changes.addListener(_onChanged);
    unawaited(refresh());
  }
  final BlockAnnotationSession session;
  BlockAnnotationSnapshot? snapshot;

  /// 选区：分节 ID 与本节正文行号（从 1 开始，两端包含）。
  String? entryId;
  int? anchor, first, last;

  /// 工具条进入确认步骤时的预览与类型。
  BlockAnnotationPreview? pending;
  BlockAnnotationKind? pendingKind;
  String? pendingVariant;
  bool busy = false;
  String error = '';
  Timer? _debounce;
  int _generation = 0;
  bool _disposed = false;

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed) unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    try {
      final next = await session.list();
      if (_disposed || generation != _generation) return;
      // 书稿变了：旧选区与预览作废，避免沿用过期的行号。
      if (snapshot != null && snapshot!.contentId != next.contentId) {
        _clearSelection();
      }
      snapshot = next;
    } on BlockAnnotationException catch (e) {
      if (_disposed || generation != _generation) return;
      if (e.reason != 'block_annotation_stale') error = e.message;
    }
    notifyListeners();
  }

  /// 某分节内每行所属的有效标注。
  Map<int, BlockMarkLine> linesFor(String entry) {
    final result = <int, BlockMarkLine>{};
    for (final view in snapshot?.annotations ?? const <BlockAnnotationView>[]) {
      final (a, b) = (view.firstLine, view.lastLine);
      if (!view.valid || view.entryId != entry || a == null || b == null) {
        continue;
      }
      for (var line = a; line <= b; line++) {
        result[line] = (view: view, first: line == a, last: line == b);
      }
    }
    return result;
  }

  bool selected(String entry, int line) =>
      entryId == entry && first != null && line >= first! && line <= last!;

  /// 点行号：单击选一行，再点同一行取消；按住 Shift 从上次的行扩展到这一行。
  void tapLine(String entry, int line, {required bool extend}) {
    if (busy) return;
    pending = null;
    pendingKind = null;
    pendingVariant = null;
    error = '';
    if (extend && entryId == entry && anchor != null) {
      first = line < anchor! ? line : anchor;
      last = line < anchor! ? anchor : line;
    } else if (entryId == entry && first == line && last == line) {
      _clearSelection();
    } else {
      entryId = entry;
      anchor = first = last = line;
    }
    notifyListeners();
  }

  void _clearSelection() {
    entryId = anchor = first = last = null;
    pending = null;
    pendingKind = null;
  }

  void clearSelection() {
    if (busy) return;
    _clearSelection();
    error = '';
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) async {
    busy = true;
    error = '';
    notifyListeners();
    try {
      await action();
    } on BlockAnnotationException catch (e) {
      error = e.message;
    } catch (_) {
      error = '无法处理标注，请稍后重试。';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 工具条第一步：解析选区并预览新增，进入确认步骤。
  Future<void> choose(BlockAnnotationKind kind, [String? variant]) =>
      _run(() async {
        final snap = snapshot ?? await session.list();
        final range = await session.resolveLines(
          snap,
          entryId: entryId!,
          firstLine: first!,
          lastLine: last!,
        );
        pending = await session.previewAdd(
          snap,
          start: range.start,
          end: range.end,
          kind: kind,
          variant: variant,
        );
        pendingKind = kind;
        pendingVariant = variant;
      });

  /// 工具条第二步：确认写入，完成后清除选区。
  Future<void> confirmPending() => _run(() async {
    await session.confirm(pending!);
    _clearSelection();
    await refresh();
  });

  void report(String message) {
    error = message;
    notifyListeners();
  }

  void back() {
    if (busy) return;
    pending = null;
    pendingKind = null;
    pendingVariant = null;
    error = '';
    notifyListeners();
  }

  Future<BlockAnnotationPreview> previewChange(
    BlockAnnotationView view,
    BlockAnnotationKind kind, [
    String? variant,
    Map<int, String>? roles,
  ]) async {
    final snap = snapshot ?? await session.list();
    return session.previewUpdate(
      snap,
      view.id,
      start: view.start,
      end: view.end,
      kind: kind,
      variant: variant,
      roles: roles,
    );
  }

  Future<void> confirm(BlockAnnotationPreview preview) async {
    await session.confirm(preview);
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    session.changes.removeListener(_onChanged);
    session.dispose();
    super.dispose();
  }
}

/// 行号栏右侧 10 像素的括号：首行画上横，末行画下横。
class BlockBracket extends StatelessWidget {
  const BlockBracket(this.line, {super.key});
  final BlockMarkLine? line;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final l = line;
    final side = BorderSide(color: d.ink3, width: 2);
    return SizedBox(
      width: 10,
      child: l == null
          ? null
          : Container(
              margin: EdgeInsets.only(
                top: l.first ? 8 : 0,
                bottom: l.last ? 8 : 0,
                right: 2,
              ),
              decoration: BoxDecoration(
                border: Border(
                  left: side,
                  top: l.first ? side : BorderSide.none,
                  bottom: l.last ? side : BorderSide.none,
                ),
              ),
            ),
    );
  }
}

/// 标注首行末尾的类型标签；点开可改类型或删除，均先确认。
class BlockTag extends StatelessWidget {
  const BlockTag({
    super.key,
    required this.controller,
    required this.view,
    required this.lines,
  });
  final BlockMarkController controller;
  final BlockAnnotationView view;

  /// 显示用的绝对行号范围，例如“第 13–15 行”。
  final String lines;

  Future<void> _act(
    BuildContext context,
    BlockAnnotationKind? kind, [
    String? variant,
  ]) async {
    final title = kind == null ? '删除手工标注' : '修改手工标注';
    final from = blockMarkLabel(view.kind, view.variant);
    final text = kind == null
        ? (view.kind == BlockAnnotationKind.none
              ? '删除$lines的“取消识别”后，这几行恢复自动识别。'
              : '删除$lines的“$from”标注后，这几行按普通正文输出（仍参与自动识别）。')
        : '把$lines的标注从“$from”改为“${blockMarkLabel(kind, variant)}”。';
    BlockAnnotationPreview preview;
    try {
      preview = kind == null
          ? await controller.session.previewDelete(view.id)
          : await controller.previewChange(view, kind, variant);
    } on BlockAnnotationException catch (e) {
      if (!context.mounted) return;
      await _message(context, title, e.message);
      return;
    }
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DeskDialog(
        title: title,
        closeTooltip: '取消',
        actions: [
          DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
          DeskButton(
            kind == null ? '删除' : '确认',
            primary: kind != null,
            dangerous: kind == null,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        child: Text(
          '$text确认后记入变更记录，可在变更记录中撤销。',
          style: ui(13, c: context.desk.ink),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await controller.confirm(preview);
    } on BlockAnnotationException catch (e) {
      if (context.mounted) await _message(context, title, e.message);
    }
  }

  /// 场景逐行设置（V82，LAY-138）：对话框本身就是确认，应用后记入变更记录。
  Future<void> _roles(BuildContext context) async {
    final roles = await showInsetRolesDialog(context, view);
    if (roles == null || !context.mounted) return;
    try {
      await controller.confirm(
        await controller.previewChange(view, view.kind, view.variant, roles),
      );
    } on BlockAnnotationException catch (e) {
      if (context.mounted) await _message(context, '逐行设置', e.message);
    }
  }

  Future<void> _message(BuildContext context, String title, String text) =>
      showDialog<void>(
        context: context,
        builder: (context) => DeskDialog(
          title: title,
          closeTooltip: '关闭',
          actions: [
            DeskButton(
              '知道了',
              primary: true,
              onPressed: () => Navigator.pop(context),
            ),
          ],
          child: Text(text, style: ui(13, c: context.desk.ink)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return SelectionContainer.disabled(
      child: MenuAnchor(
        menuChildren: [
          for (final (kind, variant, label) in blockMarkChoices)
            if (kind != view.kind || variant != view.variant)
              MenuItemButton(
                key: ValueKey((
                  'block-tag-change',
                  view.id,
                  blockMarkKey(kind, variant),
                )),
                onPressed: () => _act(context, kind, variant),
                child: Text('改为$label'),
              ),
          if (view.kind == BlockAnnotationKind.inset && view.lines != null)
            MenuItemButton(
              key: ValueKey(('block-tag-roles', view.id)),
              onPressed: () => _roles(context),
              child: const Text('逐行设置…'),
            ),
          SubmenuButton(
            key: ValueKey(('block-tag-change-inset', view.id)),
            menuChildren: [
              for (final (kind, variant, label) in insetMarkChoices)
                if (kind != view.kind || variant != view.variant)
                  MenuItemButton(
                    key: ValueKey((
                      'block-tag-change',
                      view.id,
                      blockMarkKey(kind, variant),
                    )),
                    onPressed: () => _act(context, kind, variant),
                    child: Text(label.substring(5)),
                  ),
            ],
            child: const Text('改为场景'),
          ),
          MenuItemButton(
            key: ValueKey(('block-tag-delete', view.id)),
            onPressed: () => _act(context, null),
            child: Text('删除标注', style: ui(13, c: d.pen)),
          ),
        ],
        builder: (context, menu, _) => Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Tooltip(
            message: '手工标注：点开可改类型或删除',
            child: InkWell(
              key: ValueKey(('block-tag', view.id)),
              borderRadius: BorderRadius.circular(5),
              onTap: () => menu.isOpen ? menu.close() : menu.open(),
              child: DeskTag(
                '${blockMarkLabel(view.kind, view.variant)} · 手工'
                '${view.roles.isEmpty ? '' : ' · 逐行 ${view.roles.length}'}',
                Tone.neutral,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 选区最后一行下方的浮动工具条：先选类型（预览），再确认写入。
class BlockMarkBar extends StatelessWidget {
  const BlockMarkBar({
    super.key,
    required this.controller,
    required this.lines,
    this.onNote,
  });
  final BlockMarkController controller;
  final String lines;

  /// 选中单行时的“注释…”（V62，LAY-128）；书库不提供注释能力或选了多行时为空。
  final VoidCallback? onNote;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final c = controller;
    final kind = c.pendingKind;
    final variant = c.pendingVariant;
    return SelectionContainer.disabled(
      child: Container(
        key: const ValueKey('block-mark-bar'),
        margin: const EdgeInsets.fromLTRB(0, 4, 0, 8),
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          color: d.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: d.line),
          boxShadow: d.shadow1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (kind == null) ...[
                  Text('$lines标为', style: ui(12.5, c: d.ink2)),
                  for (final (k, v, label) in blockMarkChoices)
                    DeskButton(
                      label,
                      key: ValueKey(('block-mark-choose', blockMarkKey(k, v))),
                      quiet: true,
                      busy: c.busy,
                      onPressed: c.busy ? null : () => c.choose(k, v),
                    ),
                  // 场景（V81）：九种收在一个菜单里。
                  MenuAnchor(
                    menuChildren: [
                      for (final (k, v, label) in insetMarkChoices)
                        MenuItemButton(
                          key: ValueKey((
                            'block-mark-choose',
                            blockMarkKey(k, v),
                          )),
                          onPressed: c.busy ? null : () => c.choose(k, v),
                          child: Text(label.substring(5)),
                        ),
                    ],
                    builder: (context, menu, _) => DeskButton(
                      '场景…',
                      key: const ValueKey('block-mark-inset'),
                      quiet: true,
                      busy: c.busy,
                      onPressed: c.busy
                          ? null
                          : () => menu.isOpen ? menu.close() : menu.open(),
                    ),
                  ),
                  if (onNote != null)
                    DeskButton(
                      '注释…',
                      key: const ValueKey('note-open'),
                      icon: Icons.sticky_note_2_outlined,
                      onPressed: c.busy ? null : onNote,
                    ),
                  DeskButton(
                    '取消',
                    key: const ValueKey('block-mark-cancel'),
                    quiet: true,
                    onPressed: c.busy ? null : c.clearSelection,
                  ),
                ] else ...[
                  Text(
                    kind == BlockAnnotationKind.none
                        ? '确认让$lines不参与自动识别？'
                        : '确认将$lines标为${blockMarkLabel(kind, variant)}？',
                    style: ui(12.5, c: d.ink, w: 600),
                  ),
                  DeskButton(
                    '确认',
                    key: const ValueKey('block-mark-confirm'),
                    primary: true,
                    busy: c.busy,
                    onPressed: c.busy ? null : c.confirmPending,
                  ),
                  DeskButton(
                    '返回',
                    key: const ValueKey('block-mark-back'),
                    quiet: true,
                    onPressed: c.busy ? null : c.back,
                  ),
                ],
              ],
            ),
            if (c.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  c.error,
                  key: const ValueKey('block-mark-error'),
                  style: ui(12, c: d.pen),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 失效标注提示条与列表：失效项不进成品，可删除后重新框选。
class BlockInvalidBanner extends StatelessWidget {
  const BlockInvalidBanner({super.key, required this.controller});
  final BlockMarkController controller;

  Future<void> _show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final d = context.desk;
        final invalid =
            controller.snapshot?.invalidAnnotations ??
            const <BlockAnnotationView>[];
        return DeskDialog(
          title: '失效的手工标注',
          subtitle: '书稿改动后对不上原位置的标注，不再进入成品，也不会自动挪到别处',
          closeTooltip: '关闭',
          width: 520,
          actions: [
            DeskButton(
              '关闭',
              primary: true,
              onPressed: () => Navigator.pop(context),
            ),
          ],
          child: invalid.isEmpty
              ? Text('没有失效的标注。', style: ui(13, c: d.ink2))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final view in invalid)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            DeskTag(
                              blockMarkLabel(view.kind, view.variant),
                              Tone.warn,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                view.reasonText ?? '原位置已改变。',
                                style: ui(12.5, c: d.ink),
                              ),
                            ),
                            DeskButton(
                              '删除',
                              key: ValueKey(('block-invalid-delete', view.id)),
                              dangerous: true,
                              quiet: true,
                              onPressed: () async {
                                try {
                                  await controller.confirm(
                                    await controller.session.previewDelete(
                                      view.id,
                                    ),
                                  );
                                } on BlockAnnotationException catch (e) {
                                  controller.report(e.message);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    Text(
                      '删除后，在正文中点行号重新框选即可再次标注。删除记入变更记录。',
                      style: ui(12, c: d.ink2),
                    ),
                  ],
                ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final count = controller.snapshot?.invalidAnnotations.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    final (fg, bg) = d.tone(Tone.warn);
    return Container(
      key: const ValueKey('block-invalid-banner'),
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '本书有 $count 条手工标注因书稿改动已失效，成品中不再生效。',
              style: ui(12.5, c: d.ink),
            ),
          ),
          TextButton(
            key: const ValueKey('block-invalid-show'),
            onPressed: () => _show(context),
            child: const Text('查看'),
          ),
        ],
      ),
    );
  }
}

/// 行号上按住 Shift 点击时扩展选区。
bool blockMarkExtending() => HardwareKeyboard.instance.isShiftPressed;
