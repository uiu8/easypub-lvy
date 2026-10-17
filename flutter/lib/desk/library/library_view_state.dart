// 迁入 desk（library，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
/// Presentation state owned by one workspace, never serialized as book data.
class LibraryViewState {
  String search = '', filter = '全部书稿', format = '全部格式';
  bool compact = false, onlySelected = false;
  String? topBookId, rangeAnchor;
  int topIndex = 0;
  double fraction = 0;
}
