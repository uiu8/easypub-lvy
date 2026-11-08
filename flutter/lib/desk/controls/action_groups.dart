import 'package:flutter/material.dart';

import 'controls.dart';
import '../tokens.dart';

// 分组菜单（页面导航、章节“更多”、目录行菜单）。R1 起与命令菜单同一面板：贴着按钮下方展开、
// 放不下时翻到上方，120ms 入场；条目 32 高、13 号字，带图标与当前项的勾；点外面或按 Esc 关闭。

class DeskMenuAction {
  const DeskMenuAction(
    this.value,
    this.label,
    this.icon, {
    this.enabled = true,
    this.selected = false,
  });
  final String value, label;
  final IconData icon;
  final bool enabled, selected;
}

class DeskActionGroup {
  const DeskActionGroup(this.title, this.actions);
  final String title;
  final List<DeskMenuAction> actions;
}

Future<String?> showDeskActionGroups(
  BuildContext context, {
  required String title,
  required List<DeskActionGroup> groups,
  BuildContext? anchorContext,
}) {
  final navigator = Navigator.of(context);
  final anchor = (anchorContext ?? context).findRenderObject() as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
  final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
  return navigator.push(
    _ActionGroupsRoute(
      title: title,
      groups: groups,
      anchor: origin & anchor.size,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
    ),
  );
}

class _ActionGroupsRoute extends PopupRoute<String> {
  _ActionGroupsRoute({
    required this.title,
    required this.groups,
    required this.anchor,
    required this.capturedThemes,
  });
  final String title;
  final List<DeskActionGroup> groups;
  final Rect anchor;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => '关闭菜单';
  // 入场动画由面板自己负责（与命令菜单相同的 120ms），路由本身不再淡入。
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => capturedThemes.wrap(
    Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: CustomSingleChildLayout(
        delegate: _BelowAnchor(anchor),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 220, maxWidth: 380),
          child: IntrinsicWidth(child: _Panel(groups: groups)),
        ),
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.groups});
  final List<DeskActionGroup> groups;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskMenuSurface(
      // 分组菜单可以很长（章节“更多”约 20 项）：最高到窗口高度，放不下时才在面板里滚动。
      maxHeight:
          MediaQuery.sizeOf(context).height -
          2 * _BelowAnchor.margin -
          2 * _BelowAnchor.gutter,
      children: [
        Column(
          key: deskMenuPanelKey,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final group in groups) ...[
              if (group != groups.first) const Divider(height: 9),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
                child: Text(group.title, style: ui(11, w: 650, c: d.ink3)),
              ),
              for (final action in group.actions)
                DeskMenuRow(
                  key: ValueKey('desk-action-${action.value}'),
                  onTap: action.enabled
                      ? () => Navigator.pop(context, action.value)
                      : null,
                  child: Row(
                    children: [
                      Icon(action.icon, size: 16),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          action.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (action.selected) ...[
                        const SizedBox(width: 10),
                        Icon(Icons.check_rounded, size: 16, color: d.accent),
                      ],
                    ],
                  ),
                ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 面板贴着按钮左下角展开（面板四周留有阴影位，向左上各让出一段）；下方放不下时翻到按钮上方，
/// 左右不超出窗口。
class _BelowAnchor extends SingleChildLayoutDelegate {
  const _BelowAnchor(this.anchor);
  final Rect anchor;
  static const gutter = 10.0, gap = 4.0, margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          constraints.maxWidth - 2 * margin,
          constraints.maxHeight - 2 * margin,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = anchor.left - gutter;
    var y = anchor.bottom + gap;
    if (y + child.height > size.height - margin &&
        anchor.top - gap - child.height + gutter >= margin) {
      y = anchor.top - gap - child.height + gutter;
    }
    x = x.clamp(
      margin,
      (size.width - child.width - margin).clamp(margin, size.width),
    );
    y = y.clamp(
      margin,
      (size.height - child.height - margin).clamp(margin, size.height),
    );
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_BelowAnchor oldDelegate) => oldDelegate.anchor != anchor;
}
