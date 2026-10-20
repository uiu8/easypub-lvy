part of 'rewrite_app.dart';

/// 页面路由表，自 rewrite_app.dart 拆出；各页回调仍读写应用状态。
extension _Routes on _RewriteAppState {
  GoRouter createRouter(String location) => GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/tools/:page',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: bookToolTitles[state.pathParameters['page']] ?? '书稿工具',
          child:
              state.pathParameters['page'] == 'layout' &&
                  widget.library is SettingsService
              ? GlobalLayoutPresetsPanel(
                  settings: widget.library as SettingsService,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 40,
                        color: context.desk.lineStrong,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '选择一本书，开始使用这个工具',
                        style: serif(20, w: 600, c: context.desk.ink),
                      ),
                      const SizedBox(height: 8),
                      DeskText('从左侧书卡选择或切换书稿。', color: context.desk.ink2),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 12,
                        children: [
                          DeskButton(
                            '选择书稿',
                            primary: true,
                            onPressed: () => chooseBook(context),
                          ),
                          DeskButton(
                            '导入书稿',
                            onPressed: () async {
                              final paths = await widget.picker.chooseBooks();
                              if (paths.isEmpty || !mounted) return;
                              await widget.library.importFiles(paths);
                              if (context.mounted) await chooseBook(context);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '记录',
          child: ChangeHistoryPage(
            library: widget.library,
            history: widget.library.openChangeHistory(),
            openEditor: (id, page) {
              widget.library.selectBook(id);
              context.go(bookPageLocation(id, page));
            },
          ),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) {
          final service = widget.library is SettingsService
              ? widget.library as SettingsService
              : null;
          return _Workspace(
            library: widget.library,
            picker: widget.picker,
            title: '设置',
            titleListenable: settingsPageTitle,
            child: service == null
                ? const Center(child: DeskText('当前运行环境未提供设置服务。'))
                : SettingsPage(
                    pickLegacyFile: () async => (await files.openFile(
                      acceptedTypeGroups: [
                        const files.XTypeGroup(
                          label: 'EasyPub 设置',
                          extensions: ['xml', 'json'],
                        ),
                      ],
                    ))?.path,
                    settings: service,
                    desktop: conversionDesktop,
                    picker: widget.picker,
                    library: widget.library,
                    openFavorites: () => context.go('/folders'),
                    pageTitle: settingsPageTitle,
                    performanceScrollController:
                        widget.performanceScrollController,
                  ),
          );
        },
      ),
      GoRoute(
        path: '/tasks/output/:taskId',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '成品验收',
          child: OutputAcceptancePage(
            key: ValueKey(state.uri.toString()),
            history: widget.library.openOutputHistory(),
            desktop: conversionDesktop,
            taskId: state.pathParameters['taskId']!,
            onBack: () => context.go('/tasks'),
          ),
        ),
      ),
      GoRoute(
        path: '/tasks/history',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '转换历史',
          child: OutputHistoryPage(
            history: widget.library.openOutputHistory(),
            desktop: conversionDesktop,
            onBack: () => context.go('/tasks'),
            onOpenBook: (id) {
              widget.library.selectBook(id);
              context.go('/');
            },
          ),
        ),
      ),
      GoRoute(
        path: '/tasks',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '任务',
          child: TasksPage(
            session: conversion,
            desktop: conversionDesktop,
            onAdd: () => context.go('/conversion'),
            onHistory: () => context.go('/tasks/history'),
            onOutput: (id) =>
                context.go('/tasks/output/${Uri.encodeComponent(id)}'),
            onRetry: (ids) => context.go(
              Uri(
                path: '/conversion',
                queryParameters: {'retry': ids},
              ).toString(),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/overview',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '书稿概览',
          child: BookOverviewPage(
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            picker: widget.picker,
            onRevealSource: conversionDesktop is BookSourceDesktop
                ? (conversionDesktop as BookSourceDesktop).revealSource
                : null,
            bookId: state.pathParameters['bookId']!,
          ),
        ),
      ),
      GoRoute(
        path: '/conversion',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '转换设置',
          reviewState: conversionDraft.reviewing,
          child: ConversionPage(
            showActions: false,
            draft: conversionDraft,
            key: ValueKey(state.uri.toString()),
            retryBooks: state.uri.queryParametersAll['retry'],
            initialBooks: state.uri.queryParametersAll['books'],
            recheckOnOpen: state.uri.queryParameters['recheck'] == 'true',
            desktop: conversionDesktop,
            session: conversion,
            library: widget.library,
            picker: widget.picker,
            openRepair: openConversionRepair,
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/resources',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '图片与资源',
          child: ResourcesPage(
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            bookId: state.pathParameters['bookId']!,
            pickImage: pickCoverImage,
            pickFolder: widget.picker.chooseFolder,
            openChapter: (location) => context.go(
              bookDestination(
                state,
                'chapters',
                query: {
                  'node': location.nodeId!,
                  'offset': '${location.nodeOffset!}',
                },
              ),
            ),
            openCss: () => context.go(
              bookDestination(state, 'layout', query: {'css': 'true'}),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/layout',
        onExit: (_, _) => layoutNavigation.canLeave(),
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '排版',
          child: LayoutPage(
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            bookId: state.pathParameters['bookId']!,
            navigation: layoutNavigation,
            pickPresetFile: pickPresetFile,
            pickPresetDestination: pickPresetDestination,
            importCss: importCssFile,
            pickImage: pickCoverImage,
            pickStylePack: pickStylePackFile,
            pickStylePackDestination: pickStylePackDestination,
            openCssOnStart: state.uri.queryParameters['css'] == 'true',
            initialTab:
                int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 0,
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/information',
        onExit: (_, _) => informationNavigation.canLeave(),
        builder: (context, state) => _InformationWorkspace(
          key: ValueKey(state.uri.toString()),
          library: widget.library,
          picker: widget.picker,
          bookId: state.pathParameters['bookId']!,
          navigation: informationNavigation,
          initialCoverAction: state.uri.queryParameters['cover'],
          fromConversion: state.uri.queryParameters['from'] == 'conversion',
        ),
      ),
      GoRoute(
        path: '/books/:bookId/cleanup',
        onExit: (_, _) => cleanupNavigation.canLeave(),
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '文本清理',
          child: CleanupPage(
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            bookId: state.pathParameters['bookId']!,
            navigation: cleanupNavigation,
            inspectOnOpen: state.uri.queryParameters['inspect'] == 'true',
            inspectLine: int.tryParse(state.uri.queryParameters['line'] ?? ''),
            onChecks: () => context.go(bookDestination(state, 'checks')),
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/rules',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '识别与检查规则',
          child: widget.library is RuleCatalogLibrary
              ? RulesPage(
                  key: ValueKey(state.uri.toString()),
                  library: widget.library as RuleCatalogLibrary,
                  bookId: state.pathParameters['bookId']!,
                  focusRule: state.uri.queryParameters['rule'],
                  onBack: () => context.go(bookDestination(state, 'checks')),
                  onOpenLocation: (at) => context.go(
                    bookDestination(
                      state,
                      'chapters',
                      query: {
                        'node': at.entryId,
                        'offset': '0',
                        'body':
                            '${at.heading ? 0 : (at.firstLine - 1).clamp(0, 1 << 30)}',
                        'line': '${at.sourceLine}',
                      },
                    ),
                  ),
                  onOpenSettings: (page) => context.go(
                    bookDestination(
                      state,
                      page,
                      query: {if (page == 'layout') 'tab': '2'},
                    ),
                  ),
                )
              : const Center(child: Text('当前书库不支持规则统计。')),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/checks',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '检查与修复',
          child: BookChecksPage(
            viewState: checksView(state.pathParameters['bookId']!),
            onRules: widget.library is RuleCatalogLibrary
                ? (rule) => context.go(
                    bookDestination(state, 'rules', query: {'rule': ?rule}),
                  )
                : null,
            onOpenDomain: (domain) => context.go(
              domain == 'output'
                  ? Uri(
                      path: '/conversion',
                      queryParameters: {
                        if (state.uri.queryParameters['from'] == 'conversion')
                          'recheck': 'true'
                        else
                          'books': [state.pathParameters['bookId']!],
                      },
                    ).toString()
                  : bookDestination(
                      state,
                      switch (domain) {
                        'metadata' => 'information',
                        'cover' => 'information',
                        'resources' => 'resources',
                        _ => 'chapters',
                      },
                      query: {
                        if (domain == 'cover') 'cover': 'select',
                        if (domain != 'metadata' &&
                            domain != 'cover' &&
                            domain != 'resources')
                          'issues': 'true',
                      },
                    ),
            ),
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            bookId: state.pathParameters['bookId']!,
            onRepairIssue: (issue) => context.go(
              bookDestination(
                state,
                'repairs',
                query: {
                  'mode': 'guided',
                  'issue': issue.id,
                  'category': issue.category,
                },
              ),
            ),
            onRepair: (guided) => context.go(
              bookDestination(
                state,
                'repairs',
                query: {'mode': guided ? 'guided' : 'auto'},
              ),
            ),
            onCatalog: () => context.go(bookDestination(state, 'catalog')),
            onCatalogRepair: () => context.go(
              bookDestination(state, 'catalog', query: {'quick': '1'}),
            ),
            onCleanup: () => context.go(
              bookDestination(state, 'cleanup', query: {'inspect': 'true'}),
            ),
            onCleanupLine: (line) => context.go(
              bookDestination(
                state,
                'cleanup',
                query: {'inspect': 'true', 'line': '$line'},
              ),
            ),
            onChapter: (issue) => context.go(
              bookDestination(
                state,
                'chapters',
                query: {
                  'node': issue?.entryId ?? '',
                  'offset': '${issue?.nodeOffset ?? 0}',
                  'body': '${issue?.bodyOffset ?? 0}',
                  'line': '${issue?.focusLine ?? 0}',
                },
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/catalog',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '参考目录',
          child: CatalogPage(
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            bookId: state.pathParameters['bookId']!,
            pickFile: pickCatalogFile,
            pickBookSourceFile: pickBookSourceFile,
            quick: state.uri.queryParameters['quick'] == '1',
            onReturn: () => context.go(bookDestination(state, 'chapters')),
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/chapters',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '章节编辑',
          child: ChapterWorkspace(
            viewState: chaptersView(state.pathParameters['bookId']!),
            initialIssues: state.uri.queryParameters['issues'] == 'true',
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            bookId: state.pathParameters['bookId']!,
            onCatalog: () => context.go(bookDestination(state, 'catalog')),
            onCatalogRepair: () => context.go(
              bookDestination(state, 'catalog', query: {'quick': '1'}),
            ),
            onNumericHeadings: () => context.go(
              bookDestination(
                state,
                'repairs',
                query: {'mode': 'auto', 'category': 'unrecognized-heading'},
              ),
            ),
            initialNodeId: state.uri.queryParameters['node'],
            initialBodyOffset:
                int.tryParse(state.uri.queryParameters['body'] ?? '') ?? 0,
            initialFocusLine: int.tryParse(
              state.uri.queryParameters['line'] ?? '',
            ),
            initialOffset:
                int.tryParse(state.uri.queryParameters['offset'] ?? '') ?? 0,
            onRepairIssue: (issue) => context.go(
              bookDestination(
                state,
                'repairs',
                query: {
                  'mode': 'guided',
                  'issue': issue.id,
                  'category': issue.category,
                },
              ),
            ),
            onRepair: (guided) => context.go(
              bookDestination(
                state,
                'repairs',
                query: {'mode': guided ? 'guided' : 'auto'},
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/books/:bookId/repairs',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '章节修复',
          child: ChapterRepairPage(
            key: ValueKey(state.uri.toString()),
            library: widget.library,
            bookId: state.pathParameters['bookId']!,
            guided: state.uri.queryParameters['mode'] == 'guided',
            initialIssueId: state.uri.queryParameters['issue'],
            initialCategory: state.uri.queryParameters['category'],
            onCatalog: () => context.go(bookDestination(state, 'catalog')),
            onReturn: () => context.go(bookDestination(state, 'chapters')),
            onEdit: (issue) => context.go(
              bookDestination(
                state,
                'chapters',
                query: {
                  'node': issue.entryId ?? '',
                  'offset': '${issue.nodeOffset ?? 0}',
                  'body': '${issue.bodyOffset}',
                  'line': '${issue.focusLine ?? 0}',
                },
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/folders/mapping',
        onExit: (context, state) => mappingNavigation.canLeave(),
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          folders: true,
          title: '元数据映射',
          child: MetadataMappingPage(
            library: widget.library,
            picker: widget.picker,
            navigation: mappingNavigation,
          ),
        ),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          child: ListenableBuilder(
            listenable: Listenable.merge([quickActivity, conversion.changes]),
            builder: (_, _) => LibraryPage(
              showConversionActions: false,
              viewState: libraryView,
              conversionBusy:
                  quickActivity.value || (_conversion?.busy ?? false),
              library: widget.library,
              picker: widget.picker,
              onRevealSource: conversionDesktop is BookSourceDesktop
                  ? (conversionDesktop as BookSourceDesktop).revealSource
                  : null,
              outputs: widget.library.openOutputHistory(),
              onRevealOutput: (record) =>
                  revealOutput(conversionDesktop, record),
              onOutputHistory: () => context.go('/tasks/history'),
              onConvert: () => quickConvert(context),
              onConvertBook: (id) => quickConvert(context, bookId: id),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/plugins',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '插件',
          child: PluginsPage(
            registry: PluginRegistry.instance,
            chooseFolder: widget.picker.chooseFolder,
            onOpen: (id) => context.go('/plugins/$id'),
          ),
        ),
      ),
      GoRoute(
        path: '/plugins/booksource',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          title: '书源下载',
          child: BookSourcePage(
            openApi: () => PluginBookSourceApi.open(PluginRegistry.instance),
            settingsPath:
                '${PluginRegistry.instance.dataDirectory('booksource')}${Platform.pathSeparator}ui.json',
            chooseFolder: widget.picker.chooseFolder,
            chooseSourceFile: () async => (await files.openFile(
              acceptedTypeGroups: [
                const files.XTypeGroup(
                  label: '书源',
                  extensions: ['json', 'txt', 'js'],
                ),
              ],
            ))?.path,
            importToLibrary: (path) async {
              final out = await widget.library.importFiles([path]);
              final failed = out.where((o) => !o.succeeded && !o.skipped);
              return failed.isEmpty ? null : failed.first.message;
            },
            openFolder: (path) =>
                Process.start('explorer.exe', ['/select,', path]),
            openPlugins: () => context.go('/plugins'),
          ),
        ),
      ),
      GoRoute(
        path: '/folders',
        builder: (context, state) => _Workspace(
          library: widget.library,
          picker: widget.picker,
          folders: true,
          child: FoldersPage(
            library: widget.library,
            picker: widget.picker,
            initialFolder: state.uri.queryParameters['path'],
          ),
        ),
      ),
    ],
  );
}
