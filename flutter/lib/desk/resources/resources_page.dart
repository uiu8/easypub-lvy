// 图片与资源（D3-M，V8 按设计重写视图）：读取、编辑、定位、重新关联逻辑沿用原实现。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../dialogs.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';

import '../../application/library_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../../application/resource_service.dart';
import '../../application/book_information_service.dart';
import '../controls/controls.dart';
import '../metadata/cover_preview.dart';
import 'resource_relink_dialog.dart';
import 'resource_position_dialog.dart';

class ResourcesPage extends StatefulWidget {
  const ResourcesPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.pickImage,
    required this.pickFolder,
    required this.openCss,
    required this.openChapter,
  });
  final LibraryService library;
  final String bookId;
  final Future<String?> Function() pickImage;
  final Future<String?> Function() pickFolder;
  final VoidCallback openCss;
  final void Function(ResourceLocation) openChapter;
  @override
  State<ResourcesPage> createState() => _ResourcesPageState();
}

class _ResourcesPageState extends State<ResourcesPage> {
  late final session = widget.library.openResources(widget.bookId);
  List<BookResource> resources = [];
  List<BookResource> visibleResources = [];
  BookResource? selected;
  final search = TextEditingController();
  final searchFocus = FocusNode();
  String query = '', error = '';
  bool busy = false;

  void _rebuildVisibleResources() {
    final needle = query.trim().toLowerCase();
    visibleResources = needle.isEmpty
        ? List<BookResource>.of(resources)
        : resources
              .where(
                (r) => '${r.name} ${r.location} ${r.caption}'
                    .toLowerCase()
                    .contains(needle),
              )
              .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    search.dispose();
    searchFocus.dispose();
    session.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await session.read();
      if (mounted) {
        setState(() {
          resources = result;
          _rebuildVisibleResources();
          final matches = result.where((r) => r.index == selected?.index);
          selected = matches.isNotEmpty ? matches.first : result.firstOrNull;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法检查资源，请重新读取书稿。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit(
    BookResource? resource, {
    bool remove = false,
    BookResource? original,
  }) async {
    final applied = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ResourceEdit(
        workspace: widget.library is WorkspaceAutosaveService
            ? widget.library as WorkspaceAutosaveService
            : null,
        draftKey: _resourceDraftKey(resource, original),
        session: session,
        resource: resource,
        original: original,
        remove: remove,
        picker: widget.pickImage,
      ),
    );
    if (mounted && applied == true) await refresh();
  }

  String _resourceDraftKey(BookResource? resource, BookResource? original) {
    final source = resource ?? original;
    if (source == null) return 'resource:${widget.bookId}:new';
    final stable = source.path.trim().isEmpty
        ? 'index:${source.index}'
        : source.path.trim().toLowerCase();
    return 'resource:${widget.bookId}:$stable';
  }

  Future<void> locate(BookResource resource) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final location = await session.locate(resource.index);
      if (!mounted) return;
      if (location.nodeId != null) {
        widget.openChapter(location);
      } else {
        setState(() => error = location.message);
      }
    } catch (_) {
      if (mounted) setState(() => error = '位置已变化，请重新检查资源后再定位。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> relink() async {
    final applied = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ResourceRelinkDialog(
        session: session,
        resources: resources,
        pickFolder: widget.pickFolder,
        pickImage: widget.pickImage,
      ),
    );
    if (mounted && applied == true) await refresh();
  }

  String sizeOf(BookResource r) {
    final bytes = r.image?.bytes ?? r.byteLength;
    if (bytes == null) return '—';
    return bytes >= 1024 * 1024
        ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  IconData iconOf(BookResource r) => r.kind.startsWith('css')
      ? Icons.code_rounded
      : r.image == null && r.editable
      ? Icons.broken_image_outlined
      : r.image == null
      ? Icons.inventory_2_outlined
      : Icons.image_outlined;

  @override
  Widget build(BuildContext context) => DeskSearchScope(
    focusNode: searchFocus,
    child: LayoutBuilder(builder: buildResources),
  );

  Widget buildResources(BuildContext context, BoxConstraints constraints) {
    final d = context.desk;
    final narrow = constraints.maxWidth < 760;
    final visible = visibleResources;
    final current = selected;
    final pending = resources.where((r) => r.error.isNotEmpty).length;
    return DeskPageFrame(
      header: DeskPageHeader(
        title: '图片与资源',
        status: pending == 0 ? null : DeskTag('需处理 $pending', Tone.pen),
        actions: [
          SizedBox(
            width: 240,
            child: TextField(
              controller: search,
              focusNode: searchFocus,
              style: ui(13, c: d.ink),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, size: 18),
                prefixIconConstraints: BoxConstraints(minWidth: 34),
                hintText: '搜索资源名称、用途',
              ),
              onChanged: (value) => setState(() {
                query = value;
                _rebuildVisibleResources();
              }),
            ),
          ),
          DeskButton(
            '重新检查',
            icon: Icons.refresh_rounded,
            quiet: true,
            busy: busy,
            onPressed: busy ? null : refresh,
          ),
          DeskButton(
            '重新定位…',
            icon: Icons.drive_file_move_outlined,
            quiet: true,
            onPressed: busy || !resources.any((r) => r.editable)
                ? null
                : relink,
          ),
          DeskButton(
            '添加 CSS',
            icon: Icons.code_rounded,
            onPressed: busy ? null : widget.openCss,
          ),
          DeskButton(
            '添加图片',
            icon: Icons.add_photo_alternate_outlined,
            primary: true,
            onPressed: busy ? null : () => edit(null),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    child: DeskInfoBar(error, tone: Tone.warn),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 12, 28, 6),
                  child: Row(
                    children: const [
                      SizedBox(width: 30),
                      Expanded(flex: 4, child: DeskColumnLabel('资源')),
                      Expanded(flex: 4, child: DeskColumnLabel('用途 / 位置')),
                      SizedBox(width: 84, child: DeskColumnLabel('大小')),
                      SizedBox(width: 72, child: DeskColumnLabel('状态')),
                    ],
                  ),
                ),
                Expanded(
                  child: busy
                      ? const Center(child: CircularProgressIndicator())
                      : visible.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.photo_library_outlined,
                                size: 34,
                                color: d.lineStrong,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                error.isNotEmpty
                                    ? error
                                    : resources.isEmpty
                                    ? '本书还没有图片或附加资源'
                                    : '没有找到匹配的资源',
                                style: ui(13, c: d.ink2),
                              ),
                              const SizedBox(height: 12),
                              DeskButton(
                                resources.isEmpty ? '添加图片' : '清除搜索',
                                onPressed: () {
                                  if (resources.isEmpty) {
                                    edit(null);
                                  } else {
                                    setState(() {
                                      query = '';
                                      search.clear();
                                      _rebuildVisibleResources();
                                    });
                                  }
                                },
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          itemCount: visible.length,
                          itemBuilder: (_, i) => resourceRow(visible[i]),
                        ),
                ),
                if (narrow && current != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DeskButton(
                        '查看资源详情',
                        icon: Icons.info_outline_rounded,
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => DeskDialog(
                            title: '资源详情',
                            closeTooltip: '关闭',
                            width: 540,
                            height: 620,
                            child: resourceDetails(current),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!narrow)
            Container(
              width: 400,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: d.line)),
              ),
              child: resourceDetails(current),
            ),
        ],
      ),
    );
  }

  Widget resourceRow(BookResource r) {
    final d = context.desk;
    final on = selected?.index == r.index;
    final status = r.status ?? (r.error.isEmpty ? '已读取' : '需处理');
    final tone = r.error.isNotEmpty
        ? Tone.pen
        : status == '已读取'
        ? Tone.ok
        : Tone.warn;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: on ? d.surface : Colors.transparent,
        elevation: on ? 1 : 0,
        shadowColor: Colors.black.withValues(alpha: .25),
        borderRadius: BorderRadius.circular(9),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => selected = r),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: on ? d.ink2 : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(iconOf(r), size: 17, color: d.ink2),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: Tooltip(
                    message: r.path,
                    child: Text(
                      r.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ui(13, w: 560, c: d.ink),
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    r.location,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12, c: d.ink2),
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: Text(sizeOf(r), style: mono(11, c: d.ink3)),
                ),
                SizedBox(
                  width: 72,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DeskTag(status, tone),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget detailRow(String label, String value) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: SelectableText(value, style: ui(12.5, c: d.ink)),
          ),
        ],
      ),
    );
  }

  Widget resourceDetails(BookResource? current) {
    final d = context.desk;
    if (current == null) {
      return Center(
        child: Text('选择资源查看详情', style: ui(12.5, c: d.ink3)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(current.name, style: ui(14, w: 650, c: d.ink)),
        const SizedBox(height: 10),
        Container(
          height: 180,
          decoration: BoxDecoration(
            color: d.sunken,
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: current.image == null
              ? Center(
                  child: Icon(
                    current.editable
                        ? Icons.broken_image_outlined
                        : current.kind.startsWith('css')
                        ? Icons.code_rounded
                        : Icons.inventory_2_outlined,
                    size: 42,
                    color: d.ink3,
                  ),
                )
              : CoverPreview(
                  key: ValueKey('${current.path}:${current.image!.sha256}'),
                  path: current.path,
                  decodeWidth: 600,
                ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: DeskScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                detailRow('位置', current.location),
                detailRow('替代文本', current.alt.isEmpty ? '未填写' : current.alt),
                detailRow(
                  '图注',
                  current.caption.isEmpty ? '未填写' : current.caption,
                ),
                detailRow(
                  current.image == null ? '状态' : '尺寸',
                  current.image == null
                      ? current.error.isEmpty
                            ? (current.status ?? '待复核')
                            : current.error
                      : '${sizeOf(current)} · ${current.image!.width} × ${current.image!.height}',
                ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (current.editable)
              DeskButton(
                '替换 / 编辑…',
                icon: Icons.edit_outlined,
                onPressed: busy ? null : () => edit(current),
              ),
            if (current.editable && current.index >= 0)
              DeskButton(
                '定位章节',
                icon: Icons.my_location_rounded,
                onPressed: busy ? null : () => locate(current),
              ),
            if (current.kind.startsWith('css'))
              DeskButton('编辑附加 CSS', onPressed: busy ? null : widget.openCss),
            if (current.kind == 'epub-images' || current.kind == 'epub-pending')
              DeskButton(
                current.alreadyIllustrated ? '已在插图列表中' : '作为插图…',
                onPressed: busy || current.alreadyIllustrated
                    ? null
                    : () => edit(null, original: current),
              ),
            if (current.editable)
              DeskButton(
                '移除引用',
                icon: Icons.link_off_rounded,
                quiet: true,
                dangerous: true,
                onPressed: busy ? null : () => edit(current, remove: true),
              ),
          ],
        ),
        if (current.editable) ...[
          const SizedBox(height: 6),
          Text('移除只删引用，原图片文件保留。', style: ui(11.5, c: d.ink3)),
        ],
      ],
    );
  }
}

class _ResourceEdit extends StatefulWidget {
  const _ResourceEdit({
    required this.session,
    required this.resource,
    required this.remove,
    required this.picker,
    this.original,
    required this.workspace,
    required this.draftKey,
  });
  final ResourceSession session;
  final WorkspaceAutosaveService? workspace;
  final String draftKey;
  final BookResource? resource;
  final BookResource? original;
  final bool remove;
  final Future<String?> Function() picker;
  @override
  State<_ResourceEdit> createState() => _ResourceEditState();
}

class _ResourceEditState extends State<_ResourceEdit> {
  Widget summary(Map<String, Object?> settings, {required bool after}) {
    if (after && widget.remove) return const Text('已移除引用，原文件保留。');
    if (!after && widget.resource == null) return const Text('尚未添加引用。');
    if (widget.resource?.index == -1) {
      return SelectableText('封面：${settings['cover_path']}');
    }
    final items = settings['illustrations'] as List;
    final entry = items[widget.resource?.index ?? items.length - 1] as Map;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText('图片：${entry['path']}'),
        Text(
          entry['source_line'] == null
              ? '位置：未定位'
              : '位置：原稿第 ${entry['source_line']} 行之后',
        ),
        Text('替代文本：${entry['alt']}'),
        Text('图注：${entry['caption']}'),
        Text(
          '版式：${illustrationLayouts[entry['layout'] ?? 'inline'] ?? entry['layout']}',
        ),
      ],
    );
  }

  late final path = TextEditingController(
    text: widget.resource?.path ?? widget.original?.path ?? '',
  );
  late final caption = TextEditingController(
    text: widget.resource?.caption ?? '',
  );
  late final alt = TextEditingController(text: widget.resource?.alt ?? '');
  late final line = TextEditingController(
    text: '${widget.resource?.sourceLine ?? ''}',
  );
  ResourcePositionChoice? position;

  /// 插图版式（V54，RES-050）。
  late String layout = widget.resource?.layout ?? 'inline';
  BookInformationPreview? plan;
  bool busy = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    if (widget.remove) return;
    final restored = widget.workspace?.readDraft(widget.draftKey);
    if (restored?['position'] case final Map savedPosition) {
      position = ResourcePositionChoice(
        savedPosition['sourceLine'] as int,
        savedPosition['chapter'] as String,
        savedPosition['text'] as String,
      );
    }
    for (final entry in fields.entries) {
      if (restored != null) entry.value.text = restored[entry.key] as String;
      entry.value.addListener(editDraft);
    }
  }

  Map<String, TextEditingController> get fields => {
    'path': path,
    'caption': caption,
    'alt': alt,
    'line': line,
  };
  void editDraft() {
    setState(() {
      if (position != null && '${position!.sourceLine}' != line.text.trim()) {
        position = null;
      }
      plan = null;
      error = '';
    });
    saveDraft();
  }

  void saveDraft() => widget.workspace?.writeDraft(widget.draftKey, {
    for (final entry in fields.entries) entry.key: entry.value.text,
    if (position != null && '${position!.sourceLine}' == line.text)
      'position': {
        'sourceLine': position!.sourceLine,
        'chapter': position!.chapter,
        'text': position!.text,
      },
  });
  @override
  void dispose() {
    for (final c in [path, caption, alt, line]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get missingImage =>
      !widget.remove && plan == null && path.text.trim().isEmpty;

  Future<void> act() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (plan == null) {
        final lineText = line.text.trim();
        final number = lineText.isEmpty ? null : int.tryParse(lineText);
        if (widget.original != null && number == null) {
          throw const FormatException('请先选择图片要插入的章节和段落。');
        }
        if (lineText.isNotEmpty && (number == null || number < 1)) {
          throw const FormatException('插入位置必须是有效的原稿行号。');
        }
        final next = await widget.session.change(
          index: widget.resource?.index,
          path: widget.remove ? null : path.text.trim(),
          caption: caption.text,
          alt: alt.text,
          sourceLine: number,
          layout: layout,
        );
        if (mounted) setState(() => plan = next);
      } else {
        await widget.session.apply(plan!);
        if (mounted) {
          widget.workspace?.writeDraft(widget.draftKey, null);
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = deskErrorText(e, '资源验证失败，请检查图片、位置与书稿状态。');
          plan = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: DeskAlert(
      title: Text(
        widget.remove
            ? '移除资源引用'
            : widget.original != null
            ? '将原书图片用作插图'
            : '资源重新定位 / 编辑',
      ),
      content: SizedBox(
        width: 620,
        height: 350,
        child: DeskScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.original != null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('新增当前书的插图引用；原 EPUB 和导入待处理记录保持不变。'),
                ),
              if (plan != null) ...[
                const Text('保存前'),
                summary(plan!.before, after: false),
                const Divider(),
                const Text('保存后'),
                summary(plan!.after, after: true),
              ] else if (widget.remove)
                Text('移除 ${widget.resource!.name} 的引用，不删除图片文件。')
              else ...[
                TextField(
                  controller: path,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '图片路径'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final value = await widget.picker();
                          if (mounted && value != null) {
                            setState(() => path.text = value);
                          }
                        },
                  child: const Text('浏览图片…'),
                ),
                if (widget.resource?.index != -1) ...[
                  if (widget.session is ResourcePlacementSession) ...[
                    const DeskText('插入位置', bold: true),
                    const SizedBox(height: 8),
                    DeskButton(
                      '选择章节和段落…',
                      icon: Icons.menu_book_outlined,
                      onPressed: busy
                          ? null
                          : () async {
                              final result =
                                  await showDialog<ResourcePositionChoice>(
                                    context: context,
                                    builder: (_) => ResourcePositionDialog(
                                      session:
                                          widget.session
                                              as ResourcePlacementSession,
                                    ),
                                  );
                              if (mounted && result != null) {
                                setState(() {
                                  line.text = '${result.sourceLine}';
                                  position = result;
                                  saveDraft();
                                });
                              }
                            },
                    ),
                    if (position != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '${position!.chapter}\n插在“${position!.text}”之后',
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    expansionAnimationStyle: AnimationStyle(
                      duration: DeskMotion.of(context, DeskMotion.base),
                      curve: DeskMotion.snapCurve,
                    ),
                    title: Text(
                      line.text.isEmpty
                          ? '高级：按原稿行号指定'
                          : '已绑定原稿第 ${line.text} 行之后',
                    ),
                    children: [
                      TextField(
                        controller: line,
                        enabled: !busy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '原稿行号（留空为未定位）',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: alt,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: '替代文本'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: caption,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: '图注'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const DeskText('版式', bold: true),
                      const DeskHelp(
                        '随正文：插在所选段落之后。整页：前后分页，图片铺满版面宽度，过高时由阅读器等比缩小。'
                        '章首图：放在这张插图所在章的标题上方，并代替这一章的统一章首图。',
                        key: ValueKey('resource-layout-help'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  KeyedSubtree(
                    key: const ValueKey('resource-layout'),
                    child: DeskSegmented<String>(
                      value: layout,
                      options: illustrationLayouts,
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              layout = value;
                              plan = null;
                              error = '';
                            }),
                    ),
                  ),
                ],
              ],
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: DeskNote(
                    error,
                    key: const ValueKey('resource-edit-error'),
                    title: '没有生成预览',
                    tone: Tone.pen,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy
              ? null
              : () {
                  widget.workspace?.writeDraft(widget.draftKey, null);
                  Navigator.pop(context, false);
                },
          child: const Text('取消'),
        ),
        if (plan != null)
          TextButton(
            onPressed: busy ? null : () => setState(() => plan = null),
            child: const Text('返回编辑'),
          ),
        // 没选图片时不可预览，并说明原因（RES-045）。
        Tooltip(
          message: missingImage ? '先点“浏览图片…”选择 PNG、JPG、WebP、GIF 或 BMP 图片' : '',
          child: FilledButton(
            key: const ValueKey('resource-edit-act'),
            onPressed: busy || missingImage ? null : act,
            child: Text(plan == null ? '预览变更' : '确认应用'),
          ),
        ),
      ],
    ),
  );
}
