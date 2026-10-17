part of 'rewrite_app.dart';

/// 命令面板（G-062），自 rewrite_app.dart 拆出。
extension _CommandPalette on _RewriteAppState {
  /// 命令面板（G-062）：页面跳转与既有入口；不包含任何直接修改书稿的应用动作。
  Future<void> openCommandPalette([BuildContext? from]) async {
    final context = from ?? router.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final current = widget.library.selection.value.current;
    final uri = router.routerDelegate.currentConfiguration.uri;
    final autosave = widget.library is WorkspaceAutosaveService
        ? widget.library as WorkspaceAutosaveService
        : null;
    final busy = quickActivity.value || conversion.busy || preparingOutput;
    void go(String path) => router.go(path);
    void book(String page) =>
        router.go(bookPageLocation(current, page, origin: uri));
    DeskCommand page(
      String id,
      String label,
      String initials,
      IconData icon,
      VoidCallback run, {
      String? shortcut,
    }) => DeskCommand(
      id: id,
      label: label,
      group: '页面',
      initials: initials,
      icon: icon,
      shortcut: shortcut,
      run: run,
    );
    await showDeskCommandPalette(context, [
      page(
        'G-005',
        '书库',
        'sk',
        Icons.library_books_outlined,
        () => go('/'),
        shortcut: 'Alt 1',
      ),
      page(
        'G-006',
        '文件夹与收藏',
        'wjjysc',
        Icons.folder_outlined,
        () => go('/folders'),
        shortcut: 'Alt 2',
      ),
      page(
        'G-023',
        '文件夹元数据映射',
        'wjjysjys',
        Icons.account_tree_outlined,
        () => go('/folders/mapping'),
      ),
      page(
        'G-007',
        '书稿概览',
        'sggl',
        Icons.space_dashboard_outlined,
        () => book('overview'),
      ),
      page(
        'G-009',
        '章节编辑',
        'zjbj',
        Icons.account_tree_outlined,
        () => book('chapters'),
        shortcut: 'Alt 3',
      ),
      page(
        'G-008',
        '检查与修复',
        'jcyxf',
        Icons.fact_check_outlined,
        () => book('checks'),
        shortcut: 'Alt 4',
      ),
      page(
        'G-024',
        '参考目录',
        'ckml',
        Icons.list_alt_rounded,
        () => book('catalog'),
      ),
      page(
        'G-012',
        '文本清理',
        'wbql',
        Icons.cleaning_services_outlined,
        () => book('cleanup'),
      ),
      page(
        'G-010',
        '书籍信息与封面',
        'sjxxyfm',
        Icons.info_outline_rounded,
        () => book('information'),
      ),
      page(
        'G-011',
        '排版',
        'pb',
        Icons.text_fields_rounded,
        () => book('layout'),
      ),
      page(
        'G-013',
        '图片与资源',
        'tpyzy',
        Icons.image_outlined,
        () => book('resources'),
      ),
      page(
        'G-014',
        '转换设置',
        'zhsz',
        Icons.output_rounded,
        () => go('/conversion'),
        shortcut: 'Alt 5',
      ),
      page(
        'G-015',
        '转换任务',
        'zhrw',
        Icons.checklist_rounded,
        () => go('/tasks'),
        shortcut: 'Alt 6',
      ),
      page(
        'G-026',
        '转换历史',
        'zhls',
        Icons.history_rounded,
        () => go('/tasks/history'),
      ),
      page(
        'G-016',
        '变更记录',
        'bgjl',
        Icons.edit_note_rounded,
        () => go('/history'),
      ),
      page('G-017', '设置', 'sz', Icons.settings_outlined, () => go('/settings')),
      DeskCommand(
        id: 'G-018',
        label: '选择书稿…',
        group: '操作',
        initials: 'xzsg',
        icon: Icons.menu_book_outlined,
        run: () => chooseBook(context),
      ),
      DeskCommand(
        id: 'G-028',
        label: '导入书稿…',
        group: '操作',
        initials: 'drsg',
        icon: Icons.file_open_outlined,
        run: () async {
          final paths = await widget.picker.chooseBooks();
          if (paths.isEmpty || !mounted) return;
          await widget.library.importFiles(paths);
        },
      ),
      DeskCommand(
        id: 'G-038',
        label: '转换当前书…',
        group: '操作',
        initials: 'zhdqs',
        keywords: '输出 epub azw3 mobi kfx',
        icon: Icons.arrow_forward_rounded,
        disabledReason: current == null
            ? '先选择书稿'
            : busy
            ? '等待当前操作完成'
            : null,
        run: () => quickConvert(context, bookId: current),
      ),
      DeskCommand(
        id: 'G-032',
        label: '本次书稿排版预设…',
        group: '操作',
        initials: 'bcsgpbys',
        icon: Icons.text_fields_rounded,
        disabledReason: current == null
            ? '先选择书稿'
            : busy
            ? '等待当前操作完成'
            : null,
        run: () => chooseLayout(context),
      ),
      DeskCommand(
        id: 'G-035',
        label: '更改输出位置…',
        group: '操作',
        initials: 'ggscwz',
        icon: Icons.folder_outlined,
        disabledReason: busy ? '等待当前操作完成' : null,
        run: chooseOutputDirectory,
      ),
      DeskCommand(
        id: 'G-036',
        label: '打开输出文件夹',
        group: '操作',
        initials: 'dkscwjj',
        icon: Icons.open_in_new_rounded,
        disabledReason: conversionDraft.directory.isEmpty ? '尚未设置输出位置' : null,
        run: openOutputDirectory,
      ),
      DeskCommand(
        id: 'G-030',
        label: '立即保存工作区',
        group: '操作',
        initials: 'ljbcgzq',
        icon: Icons.save_outlined,
        disabledReason: autosave == null ? '当前运行环境没有自动保存服务' : null,
        run: () => autosave?.flushWorkspace(),
      ),
    ]);
  }
}
