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

  Future<void> open(BuildContext context) async {
    final id = library.selection.value.current;
    final uri = GoRouterState.of(context).uri;
    DeskMenuAction route(String path, String label, IconData icon) =>
        DeskMenuAction(path, label, icon, selected: uri.path == path);
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
        DeskActionGroup('书库与文件', [
          route('/', '书库', Icons.library_books_outlined),
          route('/folders', '文件夹与收藏', Icons.folder_outlined),
          route('/folders/mapping', '文件夹元数据映射', Icons.account_tree_outlined),
        ]),
        DeskActionGroup('章节与检查', [
          book('checks', '检查与修复', Icons.fact_check_outlined),
          book('chapters', '章节编辑', Icons.account_tree_outlined),
          book('catalog', '参考目录', Icons.list_alt),
          book('cleanup', '文本清理', Icons.cleaning_services_outlined),
        ]),
        DeskActionGroup('书籍制作', [
          book('information', '书籍信息与封面', Icons.menu_book_outlined),
          book('resources', '图片与资源', Icons.photo_library_outlined),
          book('layout', '排版', Icons.text_fields),
        ]),
        DeskActionGroup('转换与记录', [
          route('/conversion', '转换设置', Icons.output),
          route('/tasks', '转换任务', Icons.task_alt),
          route('/tasks/history', '转换历史', Icons.history),
          route('/history', '变更记录', Icons.edit_note),
        ]),
      ],
    );
    if (context.mounted && path != null) context.go(path);
  }
}
