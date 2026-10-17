// 前后附页卡片（V56，META-048）：书籍信息页左栏，按正文前 / 正文后分组列出本书附页。
// 新增、编辑、删除、套用模板先预览再确认；拖动排序在列表中预览，确认后写入；
// 撤销与本书其他制作修改共用一条历史，走统一变更记录。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/supplemental_page_service.dart';
import '../controls/controls.dart' show DeskButton;
import '../dialogs.dart';
import '../errors.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'supplemental_templates_dialog.dart';

const supplementalPositionLabels = {
  SupplementalPagePosition.front: '正文前',
  SupplementalPagePosition.back: '正文后',
};

/// 空标题时目录里显示的名字（与成品一致：自定义显示“附页”）。
String supplementalTocName(SupplementalPageKind kind) =>
    kind == SupplementalPageKind.custom ? '附页' : supplementalPageLabels[kind]!;

String supplementalError(Object error) => error is SupplementalPageException
    ? error.message
    : deskErrorText(error, '无法处理附页');

String _count(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

class SupplementalPagesCard extends StatefulWidget {
  const SupplementalPagesCard({
    super.key,
    required this.library,
    required this.bookId,
  });
  final SupplementalPageLibrary library;
  final String bookId;
  @override
  State<SupplementalPagesCard> createState() => _SupplementalPagesCardState();
}

class _SupplementalPagesCardState extends State<SupplementalPagesCard> {
  late final SupplementalPageSession session;
  SupplementalPageSnapshot? snapshot;
  SupplementalTemplateSnapshot? templates;
  String message = '';
  bool busy = false;

  /// 拖动后待确认的排列（含两个分组标记），以及对应预览。
  List<String>? pendingOrder;
  SupplementalPagePreview? pendingPreview;
  Timer? _reload;

  @override
  void initState() {
    super.initState();
    session = widget.library.openSupplementalPages(widget.bookId);
    session.changes.addListener(_changed);
    // 首帧之后再读：读取会经由工作区状态发通知，不能发生在构建期间。
    // 模板只在点开“从模板添加”时读，打开书籍信息页不重读全局设置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(refresh());
    });
  }

  @override
  void dispose() {
    _reload?.cancel();
    session.changes.removeListener(_changed);
    session.dispose();
    super.dispose();
  }

  void _changed() {
    _reload?.cancel();
    _reload = Timer(const Duration(milliseconds: 150), refresh);
  }

  Future<void> refresh() async {
    if (busy) return;
    try {
      final next = await session.list();
      if (!mounted) return;
      setState(() {
        snapshot = next;
        if (pendingOrder != null &&
            pendingOrder!.where((e) => !e.startsWith('#')).toSet().length !=
                next.pages.length) {
          pendingOrder = null;
          pendingPreview = null;
        }
      });
    } catch (error) {
      if (mounted) setState(() => message = supplementalError(error));
    }
  }

  Future<void> loadTemplates() async {
    try {
      final next = await widget.library.supplementalTemplates.list();
      if (mounted) setState(() => templates = next);
    } catch (_) {
      // 模板读不了时菜单显示“暂无模板”，不影响本书附页。
    }
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      return await action();
    } catch (error) {
      if (mounted) setState(() => message = supplementalError(error));
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit({
    SupplementalPage? page,
    SupplementalPageKind? kind,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SupplementalPageEditor(
        session: session,
        page: page,
        kind: kind ?? page?.content.kind ?? SupplementalPageKind.custom,
      ),
    );
    if (saved == true) {
      setState(() => message = page == null ? '已添加附页' : '已修改附页');
      await refresh();
    }
  }

  Future<void> delete(SupplementalPage page) async {
    final preview = await _run(() => session.previewDelete(page.id));
    if (preview == null || !mounted) return;
    final name = page.content.title.isEmpty
        ? supplementalPageLabels[page.content.kind]!
        : page.content.title;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DeskAlert(
        title: const Text('删除附页'),
        content: Text(
          '删除“$name”（${supplementalPositionLabels[page.content.position]}）后，'
          '本书剩 ${preview.after.pages.length} 条附页。可在“记录”中撤销。',
        ),
        actions: [
          DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
          DeskButton(
            '删除',
            key: const ValueKey('supplemental-delete-confirm'),
            dangerous: true,
            primary: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (await _run(() => session.confirm(preview).then((_) => true)) == true) {
      setState(() => message = '已删除附页');
      await refresh();
    }
  }

  Future<void> applyTemplate(SupplementalTemplate template) async {
    final preview = await _run(() => session.previewApplyTemplate(template));
    if (preview == null || !mounted) return;
    final before = preview.before.pages.map((p) => p.id).toSet();
    final added = preview.after.pages.firstWhere((p) => !before.contains(p.id));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => DeskDialog(
        title: '从模板添加：${template.name}',
        subtitle: '占位符已换成本书信息；之后改模板或书籍信息不会改变这条附页。',
        closeTooltip: '取消',
        width: 520,
        actions: [
          DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
          DeskButton(
            '确认添加',
            key: const ValueKey('supplemental-template-confirm'),
            primary: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        child: SupplementalPagePreviewBody(page: added, preview: preview),
      ),
    );
    if (ok != true) return;
    if (await _run(() => session.confirm(preview).then((_) => true)) == true) {
      setState(() => message = '已从模板添加附页');
      await refresh();
    }
  }

  Future<void> manageTemplates() async {
    await showDialog<void>(
      context: context,
      builder: (_) => SupplementalTemplatesDialog(
        service: widget.library.supplementalTemplates,
      ),
    );
  }

  // ------------------------------------------------------------ 拖动排序

  List<String> get order {
    final pages = snapshot?.pages ?? const [];
    return pendingOrder ??
        [
          '#front',
          for (final p in pages)
            if (p.content.position == SupplementalPagePosition.front) p.id,
          '#back',
          for (final p in pages)
            if (p.content.position == SupplementalPagePosition.back) p.id,
        ];
  }

  /// [to] 是去掉被拖项之后的位置（onReorderItem 语义）。
  Future<void> reorder(int from, int to) async {
    final entries = [...order];
    final id = entries.removeAt(from);
    if (id.startsWith('#')) return;
    entries.insert(to < 1 ? 1 : to, id);
    final split = entries.indexOf('#back');
    final ids = entries.where((e) => !e.startsWith('#')).toList();
    final position = entries.indexOf(id) > split
        ? SupplementalPagePosition.back
        : SupplementalPagePosition.front;
    final page = snapshot!.pages.firstWhere((p) => p.id == id);
    final moved = position != page.content.position;
    final saved = snapshot!.pages.map((p) => p.id).join('\n');
    if (!moved && ids.join('\n') == saved) {
      // 拖回原样：撤掉待确认的顺序。
      cancelOrder();
      return;
    }
    setState(() {
      pendingOrder = entries;
      pendingPreview = null;
    });
    final preview = await _run(
      () => moved
          ? session.previewMove(id, position, ids)
          : session.previewReorder(ids),
    );
    if (!mounted || !identical(pendingOrder, entries)) return;
    if (preview == null) {
      cancelOrder();
      return;
    }
    setState(() => pendingPreview = preview);
  }

  Future<void> confirmOrder() async {
    final preview = pendingPreview;
    if (preview == null) return;
    if (await _run(() => session.confirm(preview).then((_) => true)) == true) {
      setState(() {
        pendingOrder = null;
        pendingPreview = null;
        message = '已调整附页顺序';
      });
      await refresh();
    }
  }

  void cancelOrder() => setState(() {
    pendingOrder = null;
    pendingPreview = null;
  });

  // ------------------------------------------------------------ 视图

  Widget header(String text, String note) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: text,
              style: ui(12, w: 600, c: d.ink2),
            ),
            TextSpan(
              text: ' · $note',
              style: ui(11.5, c: d.ink3),
            ),
          ],
        ),
      ),
    );
  }

  Widget row(SupplementalPage page, int index) {
    final d = context.desk;
    final c = page.content;
    return Material(
      key: ValueKey(('supplemental-row', page.id)),
      color: d.surface,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: d.line)),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              // 一次只预览一处改动：确认或取消后再拖下一条。
              enabled: !busy && pendingOrder == null,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Tooltip(
                  message: '拖动调整顺序；拖到另一组即改为正文前或正文后',
                  child: Padding(
                    key: ValueKey(('supplemental-drag', page.id)),
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 16,
                      color: d.ink3,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            DeskTag(supplementalPageLabels[c.kind]!, Tone.neutral),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                c.title.isEmpty ? '（无标题）' : c.title,
                overflow: TextOverflow.ellipsis,
                style: ui(13, c: c.title.isEmpty ? d.ink3 : d.ink),
              ),
            ),
            Text(
              '${_count(c.body.runes.length)} 字',
              style: ui(11.5, c: d.ink3),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 64,
              child: Text(
                c.includeToc ? '进目录' : '不进目录',
                style: ui(11.5, c: c.includeToc ? d.ink2 : d.ink3),
              ),
            ),
            IconButton(
              key: ValueKey(('supplemental-edit', page.id)),
              tooltip: '编辑',
              visualDensity: VisualDensity.compact,
              onPressed: busy || pendingOrder != null
                  ? null
                  : () => edit(page: page),
              icon: const Icon(Icons.edit_outlined, size: 16),
            ),
            IconButton(
              key: ValueKey(('supplemental-delete', page.id)),
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              onPressed: busy || pendingOrder != null
                  ? null
                  : () => delete(page),
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget list() {
    final d = context.desk;
    final pages = {for (final p in snapshot!.pages) p.id: p};
    final entries = order;
    final split = entries.indexOf('#back');
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: entries.length,
      onReorderItem: (from, to) => unawaited(reorder(from, to)),
      proxyDecorator: (child, _, _) =>
          Material(color: d.surface, elevation: 2, child: child),
      itemBuilder: (context, i) {
        final entry = entries[i];
        if (entry == '#front' || entry == '#back') {
          final front = entry == '#front';
          final empty = front ? split == 1 : split == entries.length - 1;
          return Column(
            key: ValueKey(('supplemental-group', entry)),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header(front ? '正文前' : '正文后', front ? '书名页之后、目录之前' : '最后一章之后'),
              if (empty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 2, 0, 6),
                  child: Text('暂无', style: ui(12, c: d.ink3)),
                ),
            ],
          );
        }
        return row(pages[entry]!, i);
      },
    );
  }

  Widget orderBar() {
    final d = context.desk;
    return Container(
      key: const ValueKey('supplemental-order-bar'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: d.accentSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              pendingPreview == null ? '正在预览新顺序…' : '顺序已改动，确认后写入本书。',
              style: ui(12, c: d.ink),
            ),
          ),
          DeskButton(
            '取消',
            key: const ValueKey('supplemental-order-cancel'),
            quiet: true,
            onPressed: busy ? null : cancelOrder,
          ),
          const SizedBox(width: 6),
          DeskButton(
            '确认顺序',
            key: const ValueKey('supplemental-order-confirm'),
            primary: true,
            onPressed: busy || pendingPreview == null ? null : confirmOrder,
          ),
        ],
      ),
    );
  }

  Widget addMenu() => MenuAnchor(
    menuChildren: [
      for (final kind in SupplementalPageKind.values)
        MenuItemButton(
          key: ValueKey(('supplemental-add', kind.name)),
          onPressed: () => edit(kind: kind),
          child: Text(supplementalPageLabels[kind]!),
        ),
    ],
    builder: (context, menu, _) => DeskButton(
      '添加附页',
      key: const ValueKey('supplemental-add'),
      icon: Icons.add_rounded,
      onPressed: busy || pendingOrder != null
          ? null
          : () => menu.isOpen ? menu.close() : menu.open(),
    ),
  );

  Widget templateMenu() {
    final list = templates?.templates ?? const [];
    return MenuAnchor(
      menuChildren: [
        if (list.isEmpty)
          const MenuItemButton(onPressed: null, child: Text('暂无模板')),
        for (final t in list)
          MenuItemButton(
            key: ValueKey(('supplemental-template', t.id)),
            onPressed: () => applyTemplate(t),
            child: Text(
              '${t.name}（${supplementalPageLabels[t.content.kind]} · '
              '${supplementalPositionLabels[t.content.position]}）',
            ),
          ),
      ],
      builder: (context, menu, _) => DeskButton(
        '从模板添加',
        key: const ValueKey('supplemental-template-add'),
        icon: Icons.post_add_rounded,
        onPressed: busy || pendingOrder != null
            ? null
            : () async {
                if (menu.isOpen) return menu.close();
                await loadTemplates();
                if (mounted) menu.open();
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Container(
      key: const ValueKey('supplemental-card'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('前后附页', style: ui(13.5, w: 650, c: d.ink)),
              Text('版权页、献词、后记等；只进成品，不改原文。', style: ui(11.5, c: d.ink3)),
              addMenu(),
              templateMenu(),
              DeskButton(
                '管理模板…',
                key: const ValueKey('supplemental-manage-templates'),
                quiet: true,
                onPressed: busy ? null : manageTemplates,
              ),
            ],
          ),
          if (snapshot == null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                message.isEmpty ? '正在读取附页…' : message,
                style: ui(12, c: d.ink3),
              ),
            )
          else ...[
            list(),
            if (pendingOrder != null) orderBar(),
            const SizedBox(height: 8),
            Text(
              '拖动左侧手柄调整顺序；新增、修改、删除先预览再确认，可在“记录”中撤销。',
              style: ui(11.5, c: d.ink3),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: DeskTag(
                  message,
                  message.startsWith('已') ? Tone.ok : Tone.warn,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 预览阶段显示一条附页的最终内容与警告。
class SupplementalPagePreviewBody extends StatelessWidget {
  const SupplementalPagePreviewBody({
    super.key,
    required this.page,
    required this.preview,
  });
  final SupplementalPage page;
  final SupplementalPagePreview preview;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final c = page.content;
    final group = preview.after.at(c.position);
    return Column(
      key: const ValueKey('supplemental-preview-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${supplementalPageLabels[c.kind]} · ${supplementalPositionLabels[c.position]}'
          '第 ${group.indexWhere((p) => p.id == page.id) + 1} 条 · '
          '${c.includeToc ? '进目录' : '不进目录'} · ${_count(c.body.runes.length)} 字',
          style: ui(12, c: d.ink2),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(
            color: d.paper,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: d.line),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (c.title.isNotEmpty) ...[
                  Text(
                    c.title,
                    textAlign: TextAlign.center,
                    style: ui(14, w: 650, c: d.ink),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(c.body, style: ui(12.5, c: d.ink, h: 1.6)),
              ],
            ),
          ),
        ),
        for (final w in preview.warnings) ...[
          const SizedBox(height: 8),
          DeskNote(w.message, tone: Tone.warn),
        ],
        const SizedBox(height: 8),
        Text(
          '确认前不会写入本书；本书附页 ${preview.before.pages.length} → ${preview.after.pages.length} 条。',
          style: ui(11.5, c: d.ink3),
        ),
      ],
    );
  }
}

/// 新增或编辑附页：先填写，再“预览变更”，确认后写入。
class SupplementalPageEditor extends StatefulWidget {
  const SupplementalPageEditor({
    super.key,
    required this.session,
    required this.kind,
    this.page,
  });
  final SupplementalPageSession session;
  final SupplementalPageKind kind;
  final SupplementalPage? page;
  @override
  State<SupplementalPageEditor> createState() => _SupplementalPageEditorState();
}

class _SupplementalPageEditorState extends State<SupplementalPageEditor> {
  late SupplementalPageKind kind = widget.kind;
  late SupplementalPagePosition position =
      widget.page?.content.position ??
      (kind == SupplementalPageKind.afterword ||
              kind == SupplementalPageKind.aboutAuthor
          ? SupplementalPagePosition.back
          : SupplementalPagePosition.front);
  late bool includeToc = widget.page?.content.includeToc ?? true;
  late final title = TextEditingController(
    text: widget.page?.content.title ?? supplementalPageLabels[kind],
  );
  late final body = TextEditingController(
    text: widget.page?.content.body ?? '',
  );
  SupplementalPagePreview? preview;
  String error = '';
  bool busy = false;

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  SupplementalPageContent get content => SupplementalPageContent(
    kind: kind,
    position: position,
    title: title.text,
    body: body.text,
    includeToc: includeToc,
  );

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = supplementalError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> makePreview() => run(() async {
    final page = widget.page;
    final next = page == null
        ? await widget.session.previewAdd(content)
        : await widget.session.previewUpdate(page.id, content);
    if (mounted) setState(() => preview = next);
  });

  Future<void> confirm() => run(() async {
    await widget.session.confirm(preview!);
    if (mounted) Navigator.pop(context, true);
  });

  Widget form() {
    final d = context.desk;
    final count = body.text.runes.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DeskLabel('类型'),
        DeskSegmented<SupplementalPageKind>(
          key: const ValueKey('supplemental-kind'),
          value: kind,
          options: supplementalPageLabels,
          onChanged: busy
              ? null
              : (v) => setState(() {
                  if (title.text == supplementalPageLabels[kind]) {
                    title.text = supplementalPageLabels[v]!;
                  }
                  kind = v;
                }),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const DeskLabel('位置'),
                DeskSegmented<SupplementalPagePosition>(
                  key: const ValueKey('supplemental-position'),
                  value: position,
                  options: supplementalPositionLabels,
                  onChanged: busy ? null : (v) => setState(() => position = v),
                ),
              ],
            ),
            const SizedBox(width: 20),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Row(
                children: [
                  Checkbox(
                    key: const ValueKey('supplemental-toc'),
                    value: includeToc,
                    visualDensity: VisualDensity.compact,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => includeToc = v ?? false),
                  ),
                  Text('进目录', style: ui(12.5, c: d.ink)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        DeskLabel('标题（可空，空时目录显示“${supplementalTocName(kind)}”）'),
        TextField(
          key: const ValueKey('supplemental-title'),
          controller: title,
          enabled: !busy,
          maxLines: 1,
          style: ui(13, c: d.ink),
          decoration: deskInput(context),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(child: DeskLabel('正文（纯文字，空行保留）')),
            Text(
              '${_count(count)} / 20,000 字',
              style: ui(11.5, c: count > 20000 ? d.pen : d.ink3),
            ),
          ],
        ),
        TextField(
          key: const ValueKey('supplemental-body'),
          controller: body,
          enabled: !busy,
          minLines: 8,
          maxLines: 14,
          onChanged: (_) => setState(() {}),
          style: ui(13, c: d.ink, h: 1.5),
          decoration: deskInput(context),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = preview == null
        ? null
        : widget.page != null
        ? preview!.after.pages.firstWhere((p) => p.id == widget.page!.id)
        : preview!.after.pages.firstWhere(
            (p) => !preview!.before.pages.any((b) => b.id == p.id),
          );
    return DeskDialog(
      title: widget.page == null ? '添加附页' : '编辑附页',
      subtitle: preview == null ? null : '预览：确认后写入本书，可在“记录”中撤销。',
      closeTooltip: '取消',
      width: 560,
      busy: busy,
      onClose: () => Navigator.pop(context, false),
      footerLeft: error.isEmpty
          ? null
          : Text(error, style: ui(12, c: context.desk.pen)),
      actions: preview == null
          ? [
              DeskButton('取消', onPressed: () => Navigator.pop(context, false)),
              DeskButton(
                '预览变更',
                key: const ValueKey('supplemental-preview'),
                primary: true,
                disabledReason: '正文不能为空',
                onPressed: busy || body.text.trim().isEmpty
                    ? null
                    : makePreview,
              ),
            ]
          : [
              DeskButton(
                '返回修改',
                key: const ValueKey('supplemental-back'),
                onPressed: busy ? null : () => setState(() => preview = null),
              ),
              DeskButton(
                '确认',
                key: const ValueKey('supplemental-confirm'),
                primary: true,
                onPressed: busy ? null : confirm,
              ),
            ],
      child: page == null
          ? form()
          : SupplementalPagePreviewBody(page: page, preview: preview!),
    );
  }
}
