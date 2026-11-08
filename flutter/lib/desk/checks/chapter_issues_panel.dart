// 章节工作区“问题”页签：与检查页共用问题浏览器（筛选、上下文、审阅、单项方案）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import 'check_view_state.dart';
import 'issue_browser.dart';

class ChapterIssuesPanel extends StatelessWidget {
  const ChapterIssuesPanel({
    super.key,
    required this.session,
    required this.structure,
    required this.onBody,
    this.onChapter,
    this.enabled = true,
    this.viewState,
    this.onChanged,
    this.onAddNonHeading,
    this.jump,
    this.onSelected,
  });
  final ChapterSession session;
  final ChapterPage structure;
  final VoidCallback onBody;
  final void Function(ChapterIssue)? onChapter;
  final bool enabled;
  final IssueViewState? viewState;
  final Future<void> Function()? onChanged;
  final Future<void> Function(String phrase)? onAddNonHeading;
  final ValueListenable<IssueJump?>? jump;
  final void Function(ChapterIssue issue, int offset)? onSelected;
  @override
  Widget build(BuildContext context) => CheckIssueBrowser(
    viewState: viewState,
    onChanged: onChanged,
    session: session,
    revision: structure.guard,
    enabled: enabled,
    onChapter: onChapter ?? (_) => onBody(),
    onAddNonHeading: onAddNonHeading,
    jump: jump,
    onSelected: onSelected,
  );
}
