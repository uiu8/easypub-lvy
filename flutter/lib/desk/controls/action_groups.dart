import 'package:flutter/material.dart';

import 'controls.dart';
import '../tokens.dart';

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
  final anchor = (anchorContext ?? context).findRenderObject() as RenderBox;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
  return showMenu<String>(
    context: context,
    requestFocus: true,
    semanticLabel: title,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(
        origin.dx,
        origin.dy + anchor.size.height,
        anchor.size.width,
        0,
      ),
      Offset.zero & overlay.size,
    ),
    constraints: const BoxConstraints(minWidth: 220, maxWidth: 380),
    items: [
      for (final group in groups) ...[
        PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: DeskText(group.title, size: 11, color: context.desk.ink2),
        ),
        for (final action in group.actions)
          PopupMenuItem<String>(
            value: action.value,
            enabled: action.enabled,
            height: 36,
            child: Row(
              children: [
                Icon(
                  action.icon,
                  size: 18,
                  color: action.enabled ? context.desk.ink : context.desk.ink2,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    action.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (action.selected)
                  Icon(Icons.check, size: 17, color: context.desk.accent),
              ],
            ),
          ),
        if (group != groups.last) const PopupMenuDivider(),
      ],
    ],
  );
}
