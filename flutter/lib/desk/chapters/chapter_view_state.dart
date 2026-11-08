import '../checks/check_view_state.dart';

class ChapterViewState {
  String? nodeId;
  int offset = 0, bodyOffset = 0, tab = 0;
  double bodyScrollOffset = 0;
  bool showIssueNotes = true;

  /// 正文用排版视图显示（V104，LAY-149）。
  bool layoutView = false;
  final issues = IssueViewState();
  final tree = ChapterTreeViewState();
}

class ChapterTreeViewState {
  String query = '';
  final collapsed = <String>{};
  double scrollOffset = 0;
  int loadedNodes = 0;
}
