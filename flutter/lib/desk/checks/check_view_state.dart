/// Navigation preferences only. Reports and source text are always read afresh.
class CheckViewState {
  String domain = 'chapters';
  final issues = IssueViewState();
}

class IssueViewState {
  String? category, severity, issueId;
  bool effective = true, listOpen = true;
  String comparison = 'evidence';
  int offset = 0, anchor = 0;
}
