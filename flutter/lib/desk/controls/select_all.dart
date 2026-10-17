// 列表勾选的统一做法（V23，G-067/068）：
// · SelectAllHeader：表头三态勾选框（全选 / 部分 / 全不选）与“已选 / 可选”计数，放进列表原有的表头位置；
// · SelectionKeys：焦点在列表内时 Ctrl+A 全选；有勾选时 Esc 清空（没有勾选时 Esc 照常关闭弹窗）；
// · RangeSelection：按住 Shift 点击，把上一次点击到这一行之间的可勾选行统一设成同一状态。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

const selectAllHint = '全选（Ctrl+A）· Shift+点击选一段 · Esc 清空';

class SelectAllHeader extends StatelessWidget {
  const SelectAllHeader({
    super.key,
    required this.selected,
    required this.total,
    required this.onChanged,
    this.note,
    this.trailing = const [],
    this.height = 30,
    this.padding = const EdgeInsets.only(right: 8),
    this.showCount = true,
    this.body,
    this.compact = true,
  });

  /// 已勾选数与可勾选总数（不可勾选的行不计入）。
  final int selected, total;

  /// true 为全选，false 为清空；为空时不可点。
  final ValueChanged<bool>? onChanged;
  final String? note;
  final List<Widget> trailing;
  final double height;
  final EdgeInsetsGeometry padding;
  final bool showCount;

  /// 列表原有的表头（列名等）：给出时放在勾选框右侧，取代计数、说明与右侧控件。
  final Widget? body;

  /// 与行内勾选框的密度一致（行内为默认密度时传 false）。
  final bool compact;

  bool get all => total > 0 && selected >= total;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final enabled = onChanged != null && total > 0;
    return SizedBox(
      height: height,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            Tooltip(
              message: all ? '取消全选（Esc）' : selectAllHint,
              child: Checkbox(
                key: const ValueKey('select-all'),
                tristate: true,
                value: selected == 0 ? false : (all ? true : null),
                visualDensity: compact ? VisualDensity.compact : null,
                onChanged: enabled ? (_) => onChanged!(!all) : null,
              ),
            ),
            if (body != null) Expanded(child: body!),
            if (body == null && showCount) ...[
              const SizedBox(width: 2),
              Text(
                '$selected / $total',
                key: const ValueKey('select-all-count'),
                style: ui(12, w: 600, c: d.ink2),
              ),
            ],
            if (body == null && note != null && note!.isNotEmpty) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '· $note',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(11.5, c: d.ink3),
                ),
              ),
            ],
            if (body == null) const Spacer(),
            ...trailing,
          ],
        ),
      ),
    );
  }
}

/// 列表区域的勾选快捷键。点击区域内任意处即获得焦点（不抢输入框的焦点）。
class SelectionKeys extends StatefulWidget {
  const SelectionKeys({
    super.key,
    required this.child,
    this.onSelectAll,
    this.onClear,
    this.hasSelection = false,
  });

  final Widget child;
  final VoidCallback? onSelectAll, onClear;

  /// 有勾选时 Esc 才清空并被消费；否则交给上层（如关闭弹窗）。
  final bool hasSelection;

  @override
  State<SelectionKeys> createState() => _SelectionKeysState();
}

class _SelectionKeysState extends State<SelectionKeys> {
  final focus = FocusNode(debugLabel: 'selection-keys');

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  KeyEventResult key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyA &&
        keys.isControlPressed &&
        !keys.isShiftPressed &&
        !keys.isAltPressed &&
        widget.onSelectAll != null) {
      widget.onSelectAll!();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        widget.hasSelection &&
        widget.onClear != null) {
      widget.onClear!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: key,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!focus.hasFocus) focus.requestFocus();
      },
      child: widget.child,
    ),
  );
}

/// Shift+点击选一段：记住上一次点击的行，按住 Shift 时返回两次点击之间的所有行。
class RangeSelection {
  int? anchor;

  /// 返回这次点击应设成同一状态的行序号（含本行）。
  List<int> span(int index) {
    final from = anchor;
    anchor = index;
    if (from == null || !HardwareKeyboard.instance.isShiftPressed) {
      return [index];
    }
    final lo = math.min(from, index), hi = math.max(from, index);
    return [for (var i = lo; i <= hi; i++) i];
  }

  void reset() => anchor = null;
}
