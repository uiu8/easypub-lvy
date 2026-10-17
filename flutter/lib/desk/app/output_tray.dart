part of 'rewrite_app.dart';

class _WorkspaceControls extends InheritedWidget {
  const _WorkspaceControls({required this.owner, required super.child});
  final _RewriteAppState owner;
  static _RewriteAppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WorkspaceControls>()!.owner;
  @override
  bool updateShouldNotify(_WorkspaceControls oldWidget) => true;
}

class _WorkspaceBottomBar extends StatefulWidget {
  const _WorkspaceBottomBar();
  @override
  State<_WorkspaceBottomBar> createState() => _WorkspaceBottomBarState();
}

/// 底部输出托盘（G-031–047、G-061）：左侧是待应用预览与本次输出范围，右侧是格式、排版、位置与主操作。
/// 保存状态已移到标题栏（G-030）。
class _WorkspaceBottomBarState extends State<_WorkspaceBottomBar> {
  _RewriteAppState? owner;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _WorkspaceControls.of(context);
    if (identical(owner, next)) return;
    owner = next;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await next.ensureOutputDraft();
      } catch (e) {
        next.outputMessage = deskErrorText(e, '输出设置读取失败。');
        next.conversionDraft.changed();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = owner!,
        library = app.widget.library,
        draft = app.conversionDraft;
    return AnimatedBuilder(
      animation: Listenable.merge([
        library.books,
        library.selection,
        draft,
        app.quickActivity,
        app.conversion.changes,
      ]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final d = context.desk;
          final effectiveWidth =
              constraints.maxWidth /
              MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
          final wide = effectiveWidth >= 1360;
          final mid = effectiveWidth >= 1100;
          final compact = effectiveWidth < 1000;
          final tiny = effectiveWidth < 780;
          final book = library.books.value
              .where((b) => b.id == library.selection.value.current)
              .firstOrNull;
          final checked = library.selection.value.selected;
          final preset = app.presetLabels[book?.id];
          final presetLabel =
              preset != null && preset.version == book?.contentVersion
              ? preset.label
              : '沿用本书排版';
          final conversionPage =
              GoRouterState.of(context).uri.path == '/conversion';
          final libraryPage = GoRouterState.of(context).uri.path == '/';
          final batch =
              !conversionPage &&
              checked.isNotEmpty &&
              (libraryPage ? app.libraryConvertChecked : app.convertChecked);
          final count = conversionPage
              ? draft.selected.length
              : batch
              ? checked.length
              : book == null
              ? 0
              : 1;
          final outputBooks = conversionPage
              ? draft.selected
              : batch
              ? checked
              : {if (book != null) book.id};
          final multipleBooks = outputBooks.length > 1;
          final busy =
              app.quickActivity.value ||
              app.conversion.busy ||
              app.preparingOutput ||
              !draft.initialized;
          final startText = conversionPage
              ? (draft.confirming ? '确认转换 $count 本' : '开始转换 $count 本')
              : batch
              ? '转换所选 $count 本'
              : '转换当前书';
          const formats = ['EPUB', 'AZW3', 'MOBI', 'KFX'];
          final scope = conversionPage
              ? '转换页 · $count 本'
              : batch
              ? '已勾选 $count 本'
              : book == null
              ? '未选择书稿'
              : '当前书 · ${book.title}';
          return Container(
            key: const ValueKey('workspace-output-bar'),
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: d.surface,
              border: Border(top: BorderSide(color: d.line)),
            ),
            child: Row(
              children: [
                PendingTrayButton(
                  registry: app.pendingChanges,
                  onOpen: (location) {
                    if (GoRouterState.of(context).uri.toString() != location) {
                      app.router.go(location);
                    }
                  },
                ),
                if (!conversionPage && checked.isNotEmpty)
                  DeskCommandMenu<bool>(
                    tooltip: '转换范围',
                    enabled: !busy,
                    initialValue: batch,
                    onSelected: busy
                        ? null
                        : (value) {
                            if (libraryPage) {
                              app.libraryConvertChecked = value;
                            } else {
                              app.convertChecked = value;
                            }
                            draft.changed();
                          },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: false,
                        enabled: book != null,
                        child: const Text('当前书'),
                      ),
                      PopupMenuItem(
                        value: true,
                        child: Text('已勾选 ${checked.length} 本'),
                      ),
                    ],
                    child: _TrayChip(
                      batch ? '已勾选 $count 本' : '当前书',
                      maxWidth: compact ? 120 : 220,
                    ),
                  )
                else if (!tiny)
                  Flexible(
                    child: Text(
                      scope,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(12, c: d.ink3),
                    ),
                  ),
                const Spacer(),
                // 转换页内已有格式、排版与输出位置（OUT-067），托盘不重复。
                if (!conversionPage) ...[
                  if (!tiny) ...[
                    Text('输出', style: ui(12, c: d.ink3)),
                    const SizedBox(width: 8),
                  ],
                  if (mid)
                    KeyedSubtree(
                      key: ValueKey('quick-format-${draft.format}'),
                      child: DeskSegmented<String>(
                        value: draft.format,
                        options: {for (final f in formats) f: f},
                        onChanged: busy ? null : app.updateOutputFormat,
                      ),
                    )
                  else
                    SizedBox(
                      width: MediaQuery.textScalerOf(context).scale(104),
                      child: DeskChoice<String>(
                        key: ValueKey('quick-format-${draft.format}'),
                        initialValue: draft.format,
                        isDense: true,
                        isExpanded: true,
                        iconSize: 18,
                        style: ui(13, c: d.ink),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                        ),
                        items: [
                          for (final format in formats)
                            DropdownMenuItem(
                              value: format,
                              child: Text(format),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) {
                                if (value != null) {
                                  app.updateOutputFormat(value);
                                }
                              },
                      ),
                    ),
                  const SizedBox(width: 8),
                  if (!tiny)
                    Tooltip(
                      message: multipleBooks ? '本次书稿批量排版' : '本次书稿排版预设',
                      child: InkWell(
                        onTap: busy || outputBooks.isEmpty
                            ? null
                            : () =>
                                  app.chooseLayout(context, books: outputBooks),
                        borderRadius: BorderRadius.circular(7),
                        child: _TrayChip(
                          multipleBooks
                              ? '沿用各书排版'
                              : outputBooks.contains(book?.id)
                              ? presetLabel
                              : '沿用本书排版',
                          icon: Icons.text_fields_rounded,
                          maxWidth: compact ? 120 : 176,
                          enabled: !busy && outputBooks.isNotEmpty,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        '输出位置：${draft.directory.isEmpty ? '尚未设置' : draft.directory}',
                    child: wide && draft.directory.isNotEmpty
                        ? TextButton.icon(
                            onPressed: busy ? null : app.chooseOutputDirectory,
                            icon: const Icon(Icons.folder_outlined, size: 17),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: Text(
                                draft.directory,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ui(12, c: d.ink2),
                              ),
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: d.ink2,
                              minimumSize: const Size(0, 30),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                          )
                        : IconButton(
                            tooltip: '输出位置',
                            onPressed: busy ? null : app.chooseOutputDirectory,
                            icon: Icon(
                              Icons.folder_outlined,
                              size: 19,
                              color: d.ink2,
                            ),
                          ),
                  ),
                  if (wide)
                    IconButton(
                      tooltip: '打开输出文件夹',
                      onPressed: draft.directory.isEmpty
                          ? null
                          : app.openOutputDirectory,
                      icon: Icon(
                        Icons.open_in_new_rounded,
                        size: 17,
                        color: d.ink2,
                      ),
                    ),
                ],
                if (app.outputMessage.isNotEmpty)
                  Tooltip(
                    message: app.outputMessage,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.error_outline_rounded,
                        color: d.pen,
                        size: 18,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                if (conversionPage && !tiny) ...[
                  DeskButton(
                    '检查书稿',
                    quiet: true,
                    onPressed: busy || count == 0
                        ? null
                        : draft.checkConversion,
                  ),
                  const SizedBox(width: 6),
                ],
                if (app.conversion.busy) ...[
                  if (!compact)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '${app.conversion.outputs.where((o) => o.complete).length}'
                        ' / ${app.conversion.outputs.length} 已完成',
                        style: ui(12, c: d.ink2),
                      ),
                    ),
                  DeskButton(
                    '查看任务',
                    icon: Icons.checklist_rounded,
                    onPressed: () => app.router.go('/tasks'),
                  ),
                ] else
                  DeskButton(
                    startText,
                    primary: true,
                    icon: Icons.arrow_forward_rounded,
                    busy: busy,
                    disabledReason: count == 0
                        ? '先选择要转换的书籍'
                        : busy
                        ? '等待当前操作完成'
                        : '请先检查并确认本次输出设置',
                    onPressed:
                        busy ||
                            count == 0 ||
                            (conversionPage && !draft.actionEnabled)
                        ? null
                        : () {
                            if (conversionPage) {
                              draft.startConversion?.call();
                            } else {
                              app.quickConvert(
                                context,
                                bookId: batch ? null : book!.id,
                              );
                            }
                          },
                  ),
                const SizedBox(width: 2),
                DeskCommandMenu<String>(
                  tooltip: '快捷操作',
                  icon: Icon(Icons.more_horiz_rounded, size: 20, color: d.ink2),
                  onSelected: (value) async {
                    switch (value) {
                      case 'layout':
                        await app.chooseLayout(context, books: outputBooks);
                      case 'output':
                        await app.chooseOutputDirectory();
                      case 'open':
                        if (draft.directory.isNotEmpty) {
                          await app.openOutputDirectory();
                        }
                      case 'check':
                        await draft.checkConversion?.call();
                      case 'settings':
                        app.router.go('/conversion');
                      case 'tasks':
                        app.router.go('/tasks');
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'layout',
                      enabled: !busy && outputBooks.isNotEmpty,
                      child: Text(multipleBooks ? '本次书稿批量排版' : '本次书稿排版预设'),
                    ),
                    PopupMenuItem(
                      value: 'output',
                      enabled: !busy,
                      child: const Text('更改输出位置'),
                    ),
                    PopupMenuItem(
                      value: 'open',
                      enabled: draft.directory.isNotEmpty,
                      child: const Text('打开输出文件夹'),
                    ),
                    const PopupMenuDivider(),
                    if (conversionPage)
                      PopupMenuItem(
                        value: 'check',
                        enabled:
                            !busy &&
                            count != 0 &&
                            draft.checkConversion != null,
                        child: const Text('检查本次书稿'),
                      ),
                    const PopupMenuItem(value: 'settings', child: Text('转换设置')),
                    const PopupMenuItem(value: 'tasks', child: Text('转换任务')),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 托盘里的带边框小芯片：范围与排版预设。
class _TrayChip extends StatelessWidget {
  const _TrayChip(
    this.text, {
    this.icon,
    this.maxWidth = 200,
    this.enabled = true,
  });
  final String text;
  final IconData? icon;
  final double maxWidth;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final fg = enabled ? d.ink2 : d.ink3;
    return Container(
      height: 28,
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: d.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12.5, w: 520, c: fg),
            ),
          ),
          const SizedBox(width: 3),
          Icon(Icons.expand_more_rounded, size: 15, color: fg),
        ],
      ),
    );
  }
}
