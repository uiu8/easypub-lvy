part of 'rewrite_app.dart';

/// 标题栏保存状态：读取工作区自动保存服务；没有服务时显示“当前会话”。
class _SaveStatus extends StatelessWidget {
  const _SaveStatus({required this.library});
  final LibraryService library;
  @override
  Widget build(BuildContext context) {
    final autosave = library is WorkspaceAutosaveService
        ? library as WorkspaceAutosaveService
        : null;
    final compact =
        MediaQuery.sizeOf(context).width /
            MediaQuery.textScalerOf(context).scale(1) <
        1000;
    if (autosave == null) {
      return DeskSaveBadge(state: DeskSaveState.session, compact: compact);
    }
    return ValueListenableBuilder<WorkspaceSaveStatus>(
      valueListenable: autosave.workspaceSave,
      builder: (context, save, _) => DeskSaveBadge(
        state: switch (save.phase) {
          WorkspaceSavePhase.pending => DeskSaveState.pending,
          WorkspaceSavePhase.saving => DeskSaveState.saving,
          WorkspaceSavePhase.error => DeskSaveState.failed,
          _ => DeskSaveState.saved,
        },
        message: save.message,
        savedAt: save.savedAt,
        compact: compact,
        onTap: () => autosave.flushWorkspace(),
      ),
    );
  }
}

/// 标题栏面包屑：当前书（书稿页面）+ 页面名；末段打开页面导航（G-023–026）。
class _Crumbs extends StatelessWidget {
  const _Crumbs({
    required this.library,
    required this.title,
    required this.page,
    this.titleListenable,
    this.reviewState,
  });
  final LibraryService library;
  final String? title;
  final String page;
  final ValueListenable<String>? titleListenable;
  final ValueNotifier<bool>? reviewState;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final bookPage = bookToolTitles.values.contains(title);
    Widget last(String text) => WorkspacePageMenu(
      library: library,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(12.5, w: 620, c: d.ink),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.unfold_more_rounded, size: 15, color: d.ink3),
          ],
        ),
      ),
    );
    final Widget current = reviewState != null
        ? ValueListenableBuilder<bool>(
            valueListenable: reviewState!,
            builder: (_, reviewing, _) => last(reviewing ? '转换前自动检查' : page),
          )
        : titleListenable != null
        ? ValueListenableBuilder<String>(
            valueListenable: titleListenable!,
            builder: (_, value, _) => last('$page / $value'),
          )
        : last(page);
    return Row(
      key: const ValueKey('workspace-page-header'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (bookPage) ...[
          Flexible(
            child: AnimatedBuilder(
              animation: Listenable.merge([library.books, library.selection]),
              builder: (context, _) {
                final book = library.books.value
                    .where((b) => b.id == library.selection.value.current)
                    .firstOrNull;
                return Tooltip(
                  message: book?.title ?? '未选择书稿',
                  child: Text(
                    book?.title ?? '未选择书稿',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12.5, w: 450, c: d.ink2),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('/', style: ui(12.5, c: d.ink3)),
          ),
        ],
        Flexible(child: current),
      ],
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({
    required this.child,
    required this.library,
    required this.picker,
    this.folders = false,
    this.title,
    this.displayTitle,
    this.titleListenable,
    this.reviewState,
  });
  final String? title;
  final String? displayTitle;
  final ValueListenable<String>? titleListenable;
  final ValueNotifier<bool>? reviewState;
  final bool folders;
  final LibraryService library;
  final BookFilePicker picker;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = _WorkspaceControls.of(context);
    final d = context.desk;
    final page = displayTitle ?? title ?? (folders ? '文件夹与收藏' : '书库');
    return Scaffold(
      backgroundColor: d.canvas,
      body: PaperGround(
        color: d.canvas,
        child: Column(
          children: [
            DeskTitleBar(
              onClose: () => confirmWorkspaceLeave(
                context,
                library,
                picker,
                action: '关闭软件',
              ),
              crumbs: _Crumbs(
                library: library,
                title: title,
                page: page,
                titleListenable: titleListenable,
                reviewState: reviewState,
              ),
              onSearch: () => app.openCommandPalette(context),
              status: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 自动更新（V68）：有新版本 / 下载中 / 待重启时出现。
                  if (AppUpdateScope.maybeOf(context) case final updates?)
                    UpdatePill(
                      controller: updates,
                      leave: () => confirmWorkspaceLeave(
                        context,
                        library,
                        picker,
                        action: '重启更新',
                      ),
                    ),
                  _SaveStatus(library: library),
                ],
              ),
              trailing: ProjectMenu(
                library: library,
                picker: picker,
                anchored: true,
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _rail(context, app),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (GoRouterState.of(context)
                                    .uri
                                    .queryParameters['from'] ==
                                'conversion' &&
                            title != '书籍信息')
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: DeskButton(
                                '返回转换并重新检查',
                                icon: Icons.arrow_back_rounded,
                                onPressed: () =>
                                    context.go('/conversion?recheck=true'),
                              ),
                            ),
                          ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                            child: _AccessibleCanvas(child: child),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const _WorkspaceBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _rail(BuildContext context, _RewriteAppState app) => AnimatedBuilder(
    animation: Listenable.merge([
      library.selection,
      library.books,
      app.conversion.changes,
      app.navExpanded,
    ]),
    builder: (context, _) {
      final selection = library.selection.value;
      final book = library.books.value
          .where((b) => b.id == selection.current)
          .firstOrNull;
      final origin = GoRouterState.of(context).uri;
      void openBook(String page) =>
          context.go(bookPageLocation(selection.current, page, origin: origin));
      final running = app.conversion.busy
          ? app.conversion.outputs.where((o) => !o.complete).length
          : 0;
      return DeskRail(
        expanded: app.navExpanded.value,
        onToggleExpanded: () => app.navExpanded.value = !app.navExpanded.value,
        top: [
          DeskRailEntry(
            label: '书库',
            icon: Icons.library_books_outlined,
            shortcut: 'Alt 1',
            // 只有书库页本身（没有页面标题）才高亮；书源、插件等页不再连带点亮书库（V94）。
            selected: !folders && title == null,
            onTap: () => context.go('/'),
          ),
          DeskRailEntry(
            label: '文件夹',
            icon: Icons.folder_outlined,
            shortcut: 'Alt 2',
            selected: folders,
            onTap: () => context.go('/folders'),
          ),
          // 书源下载插件启用后才出现。
          if (PluginRegistry.instance.isActive('booksource'))
            DeskRailEntry(
              label: '书源',
              icon: Icons.travel_explore_outlined,
              selected: title == '书源下载',
              onTap: () => context.go('/plugins/booksource'),
            ),
        ],
        book: (expanded) => DeskBookSwitch(
          expanded: expanded,
          title: book?.title,
          subtitle: book == null
              ? '点此选择'
              : [
                  book.author.isNotEmpty ? book.author : '未填作者',
                  book.format.toUpperCase(),
                ].join(' · '),
          onTap: () => app.chooseBook(context),
        ),
        bookEntries: [
          DeskRailEntry(
            label: '概览',
            icon: Icons.space_dashboard_outlined,
            selected: title == '书稿概览',
            onTap: () => openBook('overview'),
          ),
          DeskRailEntry(
            label: '章节',
            icon: Icons.account_tree_outlined,
            shortcut: 'Alt 3',
            selected: title == '章节编辑' || title == '章节修复' || title == '参考目录',
            onTap: () => openBook('chapters'),
          ),
          DeskRailEntry(
            label: '检查与修复',
            shortLabel: '检查',
            icon: Icons.fact_check_outlined,
            shortcut: 'Alt 4',
            // 规则页从检查页进入（V64，CH-279），左栏不单列，打开时仍高亮“检查”。
            selected: title == '检查与修复' || title == '识别与检查规则',
            onTap: () => openBook('checks'),
            // 状态点取自书稿的缓存检查状态（BookSummary.status），不触发新的检查。
            dot: switch (book?.status) {
              '检查完成 · 有待核对项' => Tone.warn,
              '检查未完成' => Tone.pen,
              '检查已过期' || '检查中…' => Tone.neutral,
              _ => null,
            },
            dotNote: switch (book?.status) {
              final s? when s.startsWith('检查') => s,
              _ => null,
            },
          ),
          DeskRailEntry(
            label: '文本清理',
            shortLabel: '清理',
            icon: Icons.cleaning_services_outlined,
            selected: title == '文本清理',
            onTap: () => openBook('cleanup'),
          ),
          DeskRailEntry(
            label: '书籍信息',
            icon: Icons.info_outline_rounded,
            selected: title == '书籍信息',
            onTap: () => openBook('information'),
          ),
          DeskRailEntry(
            label: '排版',
            icon: Icons.text_fields_rounded,
            selected: title == '排版',
            onTap: () => openBook('layout'),
          ),
          DeskRailEntry(
            label: '图片与资源',
            shortLabel: '图片资源',
            icon: Icons.image_outlined,
            selected: title == '图片与资源',
            onTap: () => openBook('resources'),
          ),
        ],
        output: [
          DeskRailEntry(
            label: '转换',
            icon: Icons.output_rounded,
            shortcut: 'Alt 5',
            selected: title == '转换设置',
            onTap: () => context.go('/conversion'),
          ),
          DeskRailEntry(
            label: '任务',
            icon: Icons.checklist_rounded,
            shortcut: 'Alt 6',
            badge: running > 0 ? '$running' : null,
            badgeTone: Tone.accent,
            selected: title == '任务' || title == '转换历史' || title == '成品验收',
            onTap: () => context.go('/tasks'),
          ),
        ],
        bottom: [
          DeskRailEntry(
            label: '记录',
            icon: Icons.history_rounded,
            selected: title == '记录',
            onTap: () => context.go('/history'),
          ),
          DeskRailEntry(
            label: '插件',
            icon: Icons.extension_outlined,
            selected: title == '插件',
            onTap: () => context.go('/plugins'),
          ),
          DeskRailEntry(
            label: '设置',
            icon: Icons.settings_outlined,
            selected: title == '设置',
            onTap: () => context.go('/settings'),
          ),
        ],
      );
    },
  );
}

class _InformationWorkspace extends StatefulWidget {
  const _InformationWorkspace({
    super.key,
    required this.library,
    required this.picker,
    required this.bookId,
    required this.navigation,
    this.initialCoverAction,
    this.fromConversion = false,
  });
  final LibraryService library;
  final BookFilePicker picker;
  final String bookId;
  final String? initialCoverAction;
  final bool fromConversion;
  final InformationNavigationGuard navigation;
  @override
  State<_InformationWorkspace> createState() => _InformationWorkspaceState();
}

class _InformationWorkspaceState extends State<_InformationWorkspace> {
  bool editingCover = false;
  @override
  Widget build(BuildContext context) => _Workspace(
    library: widget.library,
    picker: widget.picker,
    title: '书籍信息',
    displayTitle: editingCover ? '封面调整' : '书籍信息',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.fromConversion)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DeskButton(
                '返回转换并重新检查',
                icon: Icons.arrow_back,
                onPressed: () => context.go('/conversion?recheck=true'),
              ),
            ),
          ),
        Expanded(
          child: BookInformationPage(
            initialCoverAction: widget.initialCoverAction,
            library: widget.library,
            bookId: widget.bookId,
            navigation: widget.navigation,
            pickImage: pickCoverImage,
            onEditorChanged: (value) {
              if (mounted && editingCover != value) {
                setState(() => editingCover = value);
              }
            },
          ),
        ),
      ],
    ),
  );
}

// Pages own their vertical scrolling; typography never adds a second outer
// vertical viewport that pushes the page's primary controls off screen.
class _AccessibleCanvas extends StatelessWidget {
  const _AccessibleCanvas({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}
