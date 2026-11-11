// 迁入 desk（library）：逻辑与布局沿用早先的同名文件；公共弹窗框架样式后来统一。
/// Presentation state owned by one workspace, never serialized as book data.
class LibraryViewState {
  String search = '', filter = '全部书稿', format = '全部格式';

  /// 显示范围（'' 全部、'c:<收藏夹>'、'k:<类别>'）与排序。
  String scope = '', sort = 'default';
  bool descending = false;

  /// 左栏收成图标条与左栏宽度（可拖动伸缩）。
  /// 收藏夹栏默认收起。
  bool railCollapsed = true;
  double railWidth = 184;

  /// 收藏夹模式与收藏夹的排列顺序（'custom' 创建顺序、'name'、'count'）。
  bool folders = false;
  String folderOrder = 'custom';
  bool compact = false, onlySelected = false;
  String? topBookId, rangeAnchor;
  int topIndex = 0;
  double fraction = 0;
}
