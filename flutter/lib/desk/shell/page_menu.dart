import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../application/library_service.dart';
import '../controls/action_groups.dart';
import '../tokens.dart';

String bookPageLocation(
  String? bookId,
  String page, {
  Uri? origin,
  Map<String, String> query = const {},
}) => Uri(
  pathSegments: bookId == null
      ? ['', 'tools', page]
      : ['', 'books', bookId, page],
  queryParameters: {
    if (origin?.queryParameters['from'] == 'conversion') 'from': 'conversion',
    ...query,
  },
).toString();

const bookToolTitles = <String, String>{
  'overview': '书稿概览',
  'checks': '检查与修复',
  'chapters': '章节编辑',
  'information': '书籍信息',
  'layout': '排版',
  'cleanup': '文本清理',
  'resources': '图片与资源',
  'catalog': '参考目录',
  'repairs': '章节修复',
  'rules': '识别与检查规则',
};

/// 最近访问的页面（R1，G-023–026）：每次路由变化时记录，最近的在前，按路径去重，最多 8 个。
final recentPages = ValueNotifier<List<String>>(const []);

void rememberPage(Uri uri) {
  final path = uri.path;
  recentPages.value = [
    path,
    ...recentPages.value.where((p) => p != path),
  ].take(8).toList();
}

/// 页面名称：书稿页面带书名；书已不在书库或不认识的路径返回 null（不列出）。
String? pageLabel(String path, LibraryService library) {
  final s = Uri.parse(path).pathSegments;
  if (s.length == 3 && s.first == 'books') {
    final page = bookToolTitles[s[2]];
    final title = library.books.value
        .where((b) => b.id == s[1])
        .firstOrNull
        ?.title;
    return page == null || title == null ? null : '$page · $title';
  }
  return const {
    '/': '书库',
    '/folders': '文件夹与收藏',
    '/folders/mapping': '文件夹元数据映射',
    '/plugins': '插件',
    '/plugins/booksource': '书源下载',
    '/conversion': '转换设置',
    '/tasks': '转换任务',
    '/tasks/history': '转换历史',
    '/history': '变更记录',
    '/settings': '设置',
  }[path];
}

IconData _pageIcon(String path) {
  final s = Uri.parse(path).pathSegments;
  final key = s.length == 3 && s.first == 'books' ? s[2] : path;
  return switch (key) {
    'overview' => Icons.space_dashboard_outlined,
    'chapters' => Icons.account_tree_outlined,
    'checks' => Icons.fact_check_outlined,
    'catalog' => Icons.list_alt,
    'repairs' => Icons.build_outlined,
    'rules' => Icons.tune_rounded,
    'cleanup' => Icons.cleaning_services_outlined,
    'information' => Icons.menu_book_outlined,
    'resources' => Icons.photo_library_outlined,
    'layout' => Icons.text_fields,
    '/' => Icons.library_books_outlined,
    '/folders' || '/folders/mapping' => Icons.folder_outlined,
    '/plugins' => Icons.extension_outlined,
    '/plugins/booksource' => Icons.travel_explore_outlined,
    '/conversion' => Icons.output,
    '/tasks' => Icons.task_alt,
    '/tasks/history' => Icons.history,
    '/history' => Icons.edit_note,
    '/settings' => Icons.settings_outlined,
    _ => Icons.chevron_right_rounded,
  };
}

/// Product counterpart of the review-only scene selector.
/// Routes are real destinations; GoRouter retains each editor's leave guard.
/// 标题栏面包屑末段传入 [child] 作为触发器；未传时显示独立图标按钮。
class WorkspacePageMenu extends StatelessWidget {
  const WorkspacePageMenu({super.key, required this.library, this.child});
  final LibraryService library;
  final Widget? child;
  @override
  Widget build(BuildContext context) => child == null
      ? IconButton(
          tooltip: '页面导航',
          icon: Icon(Icons.grid_view, size: 20, color: context.desk.ink2),
          onPressed: () => open(context),
        )
      : Tooltip(
          message: '页面导航',
          child: InkWell(
            onTap: () => open(context),
            borderRadius: BorderRadius.circular(6),
            child: child,
          ),
        );

  /// R1：只列“最近访问”与“当前书”的页面；书库、转换等全局页面在左侧导航和命令面板里，
  /// 菜单不再整份重复。
  Future<void> open(BuildContext context) async {
    final id = library.selection.value.current;
    final uri = GoRouterState.of(context).uri;
    final title = library.books.value
        .where((b) => b.id == id)
        .firstOrNull
        ?.title;
    final recent = [
      for (final path in recentPages.value)
        if (path != uri.path)
          if (pageLabel(path, library) case final label?)
            DeskMenuAction(path, label, _pageIcon(path)),
    ].take(5).toList();
    DeskMenuAction book(String page, String label, IconData icon) {
      final path = bookPageLocation(id, page, origin: uri);
      return DeskMenuAction(
        path,
        label,
        icon,
        selected: path.isNotEmpty && Uri.parse(path).path == uri.path,
      );
    }

    final path = await showDeskActionGroups(
      context,
      title: '页面导航',
      groups: [
        if (recent.isNotEmpty) DeskActionGroup('最近访问', recent),
        DeskActionGroup(title == null ? '当前书（未选择）' : '当前书 · $title', [
          book('overview', '书稿概览', Icons.space_dashboard_outlined),
          book('chapters', '章节编辑', Icons.account_tree_outlined),
          book('checks', '检查与修复', Icons.fact_check_outlined),
          book('catalog', '参考目录', Icons.list_alt),
          book('cleanup', '文本清理', Icons.cleaning_services_outlined),
          book('information', '书籍信息与封面', Icons.menu_book_outlined),
          book('resources', '图片与资源', Icons.photo_library_outlined),
          book('layout', '排版', Icons.text_fields),
        ]),
      ],
    );
    if (context.mounted && path != null) context.go(path);
  }
}
