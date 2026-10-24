// 迁入 desk（library，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
/// Presentation state owned by one workspace, never serialized as book data.
class LibraryViewState {
  String search = '', filter = '全部书稿', format = '全部格式';

  /// 显示范围（V84：'' 全部、'c:<收藏夹>'、'k:<类别>'）与排序。
  String scope = '', sort = 'default';
  bool descending = false;

  /// 左栏收成图标条与左栏宽度（V84b，可拖动伸缩）。
  bool railCollapsed = false;
  double railWidth = 184;

  /// 收藏夹模式与收藏夹的排列顺序（V104：'custom' 创建顺序、'name'、'count'）。
  bool folders = false;
  String folderOrder = 'custom';
  bool compact = false, onlySelected = false;
  String? topBookId, rangeAnchor;
  int topIndex = 0;
  double fraction = 0;
}
