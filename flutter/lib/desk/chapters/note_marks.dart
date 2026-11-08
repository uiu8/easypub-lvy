// 章节页手工注释（V62，LAY-128）：行号工具条“注释…”、注释对话框（补配对 / 新写注释）、
// 正文中的注释标签与失效提示。数据与输出由 V58 的 ManualNoteSession 提供；
// 所有写入先预览、再确认，与本书其他制作修改共用一条变更记录。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/manual_note_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 正文某行上的一个注释标签：引用行（[definition] 为假）或补配对的注释行。
typedef NoteLineTag = ({ManualNoteView view, bool definition});

String noteMessage(Object error) =>
    error is ManualNoteException ? error.message : '无法处理注释，请稍后重试。';

/// 一本书的手工注释状态。章节页创建并释放；正文组件监听它重绘。
class NoteMarkController extends ChangeNotifier {
  NoteMarkController(this.session) {
    session.changes.addListener(_onChanged);
    unawaited(refresh());
  }
  final ManualNoteSession session;
  ManualNoteSnapshot? snapshot;
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
      snapshot = next;
      error = '';
    } on ManualNoteException catch (e) {
      if (_disposed || generation != _generation) return;
      if (e.reason != 'note_stale') error = e.message;
    }
    if (!_disposed) notifyListeners();
  }

  /// 手工注释（不含自动识别的候选）。
  Iterable<ManualNoteView> get manual =>
      (snapshot?.notes ?? const <ManualNoteView>[]).where(
        (n) => n.kind != ManualNoteKind.automatic,
      );

  List<ManualNoteView> get invalid =>
      manual.where((n) => !n.valid).toList(growable: false);

  /// 某分节内每行（正文行号，从 1 开始）的注释标签。
  Map<int, List<NoteLineTag>> tagsFor(String entry) {
    final result = <int, List<NoteLineTag>>{};
    for (final view in manual) {
      if (!view.valid) continue;
      final at = view.location;
      if (at != null && at.entryId == entry) {
        (result[at.line] ??= []).add((view: view, definition: false));
      }
      final def = view.definitionLocation;
      if (def != null && def.entryId == entry) {
        (result[def.line] ??= []).add((view: view, definition: true));
      }
    }
    return result;
  }

  Future<void> confirm(ManualNotePreview preview) async {
    await session.confirm(preview);
    await refresh();
  }

  void report(String message) {
    error = message;
    notifyListeners();
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

/// 打开注释对话框所需的本章上下文。
class NoteContext {
  const NoteContext({
    required this.entryId,
    required this.line,
    required this.lineText,
    required this.chapterLines,
    required this.lineLabel,
  });
  final String entryId;

  /// 本节正文行号（从 1 开始）与该行文字。
  final int line;
  final String lineText;

  /// 本章已读入的正文行（行号、文字），用于选择补配对的注释行。
  final List<(int, String)> chapterLines;

  /// 正文行号对应的显示行号，例如“第 13 行”。
  final String Function(int line) lineLabel;
}

Future<bool> showNoteDialog(
  BuildContext context,
  NoteMarkController controller,
  NoteContext at, {
  ManualNoteView? existing,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          ManualNoteDialog(controller: controller, at: at, existing: existing),
    ) ==
    true;

/// 添加或修改一条手工注释：选方式与位置 → 预览变更 → 确认。
class ManualNoteDialog extends StatefulWidget {
  const ManualNoteDialog({
    super.key,
    required this.controller,
    required this.at,
    this.existing,
  });
  final NoteMarkController controller;
  final NoteContext at;
  final ManualNoteView? existing;
  @override
  State<ManualNoteDialog> createState() => _ManualNoteDialogState();
}

class _ManualNoteDialogState extends State<ManualNoteDialog> {
  late bool pair = widget.existing?.kind != ManualNoteKind.newNote;
  late final line = TextEditingController(text: widget.at.lineText);
  late final text = TextEditingController(
    text: widget.existing?.kind == ManualNoteKind.newNote
        ? widget.existing!.text
        : '',
  );
  late int? definition = widget.existing?.definitionLocation?.line;
  ManualNotePreview? preview;
  String error = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final at = widget.existing?.location;
    if (at != null && at.line == widget.at.line) {
      line.selection = TextSelection(
        baseOffset: at.utf16Start.clamp(0, widget.at.lineText.length),
        extentOffset: at.utf16End.clamp(0, widget.at.lineText.length),
      );
    }
    line.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    line.removeListener(_changed);
    line.dispose();
    text.dispose();
    super.dispose();
  }

  TextSelection get selection => line.selection;

  /// 现在能否预览；不能时给出原因。
  String? get missing {
    final s = selection;
    if (pair) {
      if (!s.isValid || s.isCollapsed) return '先在本行选中标记文字';
      if (definition == null) return '再选本章的注释行';
      return null;
    }
    if (!s.isValid) return '先在本行点一下插入位置';
    if (text.text.trim().isEmpty) return '写上注释文字';
    return null;
  }

  Future<void> makePreview() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final c = widget.controller;
      final snap = await c.session.list();
      final s = selection;
      final start = pair ? s.start : s.end;
      final reference = await c.session.resolvePosition(
        snap,
        entryId: widget.at.entryId,
        line: widget.at.line,
        utf16Start: start,
        utf16End: pair ? s.end : start,
      );
      final draft = pair
          ? ManualNoteDraft.pair(
              reference,
              await c.session.resolvePosition(
                snap,
                entryId: widget.at.entryId,
                line: definition!,
                utf16Start: 0,
                utf16End: 0,
              ),
            )
          : ManualNoteDraft.newText(reference, text.text);
      final existing = widget.existing;
      final next = existing == null
          ? await c.session.previewAdd(snap, draft)
          : await c.session.previewUpdate(snap, existing.id, draft);
      if (mounted) setState(() => preview = next);
    } catch (e) {
      if (mounted) setState(() => error = noteMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirm() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.controller.confirm(preview!);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = noteMessage(e);
          busy = false;
        });
      }
    }
  }

  /// 预览里改动后的那条注释。
  ManualNoteView? get changed {
    final p = preview;
    if (p == null) return null;
    final before = {for (final n in p.before.notes) n.id};
    final id = widget.existing?.id;
    return p.after.notes
        .where(
          (n) =>
              n.kind != ManualNoteKind.automatic &&
              (id == null ? !before.contains(n.id) : n.id == id),
        )
        .firstOrNull;
  }

  Widget form() {
    final d = context.desk;
    final s = selection;
    final candidates = widget.at.chapterLines
        .where((l) => l.$1 != widget.at.line && l.$2.trim().isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(
          key: const ValueKey('note-mode'),
          child: DeskSegmented<bool>(
            value: pair,
            options: const {true: '补配对', false: '新写注释'},
            onChanged: busy ? null : (v) => setState(() => pair = v),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          pair
              ? '原文里已经有注释，只是写法没被自动识别：选中正文里的标记，再指出注释写在哪一行。'
              : '原文里没有注释：在正文里点出标记位置，再写注释文字。编号按本章出现顺序生成，注释放到本章末尾。',
          style: ui(12, c: d.ink2, h: 1.5),
        ),
        DeskLabel(pair ? '1. 在这一行里选中标记文字' : '1. 在这一行里点一下插入位置'),
        TextField(
          key: const ValueKey('note-line-text'),
          controller: line,
          readOnly: true,
          showCursor: true,
          minLines: 1,
          maxLines: 4,
          style: ui(14, c: d.ink, h: 1.6),
          decoration: deskInput(context),
        ),
        const SizedBox(height: 4),
        Text(
          !s.isValid
              ? '还没有选择位置'
              : s.isCollapsed
              ? '插入位置：第 ${s.start} 个字之后'
              : '已选中“${line.text.substring(s.start, s.end)}”',
          style: ui(11.5, c: d.ink3),
        ),
        if (pair) ...[
          const DeskLabel('2. 选择本章里的注释行'),
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              border: Border.all(color: d.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: candidates.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      '本章已读入的正文里没有其他行。可以先在正文中往下滚动，读入更多内容后再试。',
                      style: ui(12, c: d.ink3),
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (no, content) in candidates)
                        Material(
                          color: definition == no ? d.accentSoft : d.surface,
                          child: InkWell(
                            key: ValueKey(('note-definition', no)),
                            onTap: busy
                                ? null
                                : () => setState(() => definition = no),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    definition == no
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    size: 14,
                                    color: definition == no ? d.ink : d.ink3,
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 64,
                                    child: Text(
                                      widget.at.lineLabel(no),
                                      style: mono(11, c: d.ink3),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      content.trim(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ui(12.5, c: d.ink),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ] else ...[
          Row(
            children: [
              const Expanded(child: DeskLabel('2. 注释文字（纯文字，可分段）')),
              Text(
                '${text.text.runes.length} / 20,000 字',
                style: ui(
                  11.5,
                  c: text.text.runes.length > 20000 ? d.pen : d.ink3,
                ),
              ),
            ],
          ),
          TextField(
            key: const ValueKey('note-text'),
            controller: text,
            enabled: !busy,
            minLines: 4,
            maxLines: 10,
            onChanged: (_) => setState(() {}),
            style: ui(13, c: d.ink, h: 1.5),
            decoration: deskInput(context),
          ),
        ],
      ],
    );
  }

  Widget previewBody() {
    final d = context.desk;
    final n = changed;
    final label = widget.at.lineLabel;
    return Column(
      key: const ValueKey('note-preview-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (n == null)
          Text('预览中没有找到这条注释，请返回修改。', style: ui(13, c: d.pen))
        else ...[
          Text(
            pair
                ? '${label(widget.at.line)}的“${n.marker}”将链接到'
                      '${label(n.definitionLocation?.line ?? definition ?? 0)}的注释。'
                : '将在${label(widget.at.line)}插入注释标记，注释放到本章末尾。',
            style: ui(13, c: d.ink),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: d.paper,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: d.line),
            ),
            child: SingleChildScrollView(
              child: Text(n.text, style: ui(13, c: d.ink, h: 1.6)),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text('确认前不会写入本书；原稿不改。确认后可在“记录”中撤销。', style: ui(11.5, c: d.ink3)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final reason = missing;
    return DeskDialog(
      title:
          '${editing ? '修改注释' : '添加注释'} · ${widget.at.lineLabel(widget.at.line)}',
      subtitle: preview == null ? null : '预览：确认后写入本书',
      closeTooltip: '取消',
      width: 560,
      busy: busy,
      onClose: () => Navigator.pop(context, false),
      footerLeft: error.isEmpty
          ? null
          : Text(
              error,
              key: const ValueKey('note-error'),
              style: ui(12, c: context.desk.pen),
            ),
      actions: preview == null
          ? [
              DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
              DeskButton(
                '预览变更',
                key: const ValueKey('note-preview'),
                primary: true,
                disabledReason: reason,
                onPressed: busy || reason != null ? null : makePreview,
              ),
            ]
          : [
              DeskButton(
                '返回修改',
                key: const ValueKey('note-back'),
                onPressed: busy ? null : () => setState(() => preview = null),
              ),
              DeskButton(
                '确认',
                key: const ValueKey('note-confirm'),
                primary: true,
                onPressed: busy || changed == null ? null : confirm,
              ),
            ],
      child: preview == null ? form() : previewBody(),
    );
  }
}

/// 正文行末的注释标签；点开可编辑或删除，均先确认。
class NoteTag extends StatelessWidget {
  const NoteTag({
    super.key,
    required this.controller,
    required this.tag,
    required this.lineLabel,
    required this.onEdit,
  });
  final NoteMarkController controller;
  final NoteLineTag tag;
  final String Function(int line) lineLabel;
  final VoidCallback onEdit;

  String get label {
    final v = tag.view;
    if (tag.definition) {
      return '注释正文 · 对应${lineLabel(v.location?.line ?? 0)}';
    }
    return v.kind == ManualNoteKind.pair
        ? '注 · 配对 → ${lineLabel(v.definitionLocation?.line ?? 0)}'
        : '注 · 新写';
  }

  Future<void> _delete(BuildContext context) async {
    ManualNotePreview preview;
    try {
      preview = await controller.session.previewDelete(tag.view.id);
    } catch (e) {
      controller.report(noteMessage(e));
      return;
    }
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DeskDialog(
        title: '删除手工注释',
        closeTooltip: '取消',
        actions: [
          DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
          DeskButton(
            '删除',
            key: const ValueKey('note-delete-confirm'),
            dangerous: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        child: Text(
          tag.view.kind == ManualNoteKind.pair
              ? '删除后，“${tag.view.marker}”不再链接到注释，两行都按原文输出（仍参与自动识别）。确认后记入变更记录，可撤销。'
              : '删除这条新写的注释，正文里的注释标记也会去掉。确认后记入变更记录，可撤销。',
          style: ui(13, c: context.desk.ink),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await controller.confirm(preview);
    } catch (e) {
      controller.report(noteMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return SelectionContainer.disabled(
      child: MenuAnchor(
        menuChildren: [
          MenuItemButton(
            key: ValueKey(('note-tag-edit', tag.view.id, tag.definition)),
            onPressed: onEdit,
            child: const Text('编辑注释'),
          ),
          MenuItemButton(
            key: ValueKey(('note-tag-delete', tag.view.id, tag.definition)),
            onPressed: () => _delete(context),
            child: Text('删除注释', style: ui(13, c: d.pen)),
          ),
        ],
        builder: (context, menu, _) => Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Tooltip(
            message: '手工注释：点开可编辑或删除',
            child: InkWell(
              key: ValueKey(('note-tag', tag.view.id, tag.definition)),
              borderRadius: BorderRadius.circular(5),
              onTap: () => menu.isOpen ? menu.close() : menu.open(),
              child: DeskTag(label, Tone.info),
            ),
          ),
        ),
      ),
    );
  }
}

/// 失效注释提示条与列表：失效项不进成品，可删除后重新添加。
class NoteInvalidBanner extends StatelessWidget {
  const NoteInvalidBanner({super.key, required this.controller});
  final NoteMarkController controller;

  Future<void> _show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final d = context.desk;
        final invalid = controller.invalid;
        return DeskDialog(
          title: '失效的手工注释',
          subtitle: '书稿改动后对不上原位置的注释，不再进入成品，也不会自动挪到别处',
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
              ? Text('没有失效的注释。', style: ui(13, c: d.ink2))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final view in invalid)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            DeskTag(
                              view.kind == ManualNoteKind.pair ? '配对' : '新写',
                              Tone.warn,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${view.marker.isEmpty ? '' : '“${view.marker}” '}'
                                '${view.reasonText ?? '原位置已改变。'}',
                                style: ui(12.5, c: d.ink),
                              ),
                            ),
                            DeskButton(
                              '删除',
                              key: ValueKey(('note-invalid-delete', view.id)),
                              dangerous: true,
                              quiet: true,
                              onPressed: () async {
                                try {
                                  await controller.confirm(
                                    await controller.session.previewDelete(
                                      view.id,
                                    ),
                                  );
                                } catch (e) {
                                  controller.report(noteMessage(e));
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    Text(
                      '删除后，点行号选中一行，用“注释…”重新添加。删除记入变更记录。',
                      style: ui(12, c: d.ink2),
                    ),
                  ],
                ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _bar(context),
  );

  Widget _bar(BuildContext context) {
    final d = context.desk;
    final count = controller.invalid.length;
    if (count == 0 && controller.error.isEmpty) return const SizedBox.shrink();
    final (fg, bg) = d.tone(Tone.warn);
    return Container(
      key: const ValueKey('note-invalid-banner'),
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
              count == 0
                  ? controller.error
                  : '本书有 $count 条手工注释因书稿改动已失效，成品中不再生效。',
              style: ui(12.5, c: d.ink),
            ),
          ),
          if (count > 0)
            TextButton(
              key: const ValueKey('note-invalid-show'),
              onPressed: () => _show(context),
              child: const Text('查看'),
            ),
        ],
      ),
    );
  }
}
