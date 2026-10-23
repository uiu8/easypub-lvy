// 编辑台弹窗部件（设计来源 design_review_v37/kit.dart DialogFrame 与 d2_chapters 弹窗共用件）：
// 弹窗框架、带标签输入、影响说明、行号正文行、翻页条。
// 忙碌时框架禁止返回键/遮罩关闭，关闭按钮置灰；尺寸随窗口收缩，内容区可滚动。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

class DeskDialog extends StatelessWidget {
  const DeskDialog({
    super.key,
    required this.title,
    required this.closeTooltip,
    required this.child,
    this.subtitle,
    this.actions = const [],
    this.footerLeft,
    this.width = 480,
    this.height,
    this.busy = false,
    this.onClose,
    this.scrollBody = true,
    this.escapeCloses = false,
  });
  final String title, closeTooltip;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;
  final Widget? footerLeft;
  final double width;

  /// 给出时弹窗为固定高度（列表类弹窗）；否则按内容收缩。
  final double? height;
  final bool busy, scrollBody;

  /// 默认关闭当前路由；忙碌时不可用。
  final VoidCallback? onClose;

  /// 以 `barrierDismissible: false` 打开时 Flutter 不让 Esc 关闭；为 true 时由弹窗自己处理
  /// Esc（忙碌时除外），与关闭按钮相同（R5-03）。
  final bool escapeCloses;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final screen = MediaQuery.sizeOf(context);
    final w = width.clamp(0.0, screen.width - 32);
    final maxH = screen.height - 32;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: child,
    );
    final close = onClose ?? () => Navigator.pop(context);
    final dialog = PopScope(
      canPop: !busy,
      child: Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          width: w,
          height: height?.clamp(0.0, maxH),
          constraints: BoxConstraints(maxHeight: maxH),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: d.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: d.shadow3,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 10, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: ui(15.5, w: 650, c: d.ink)),
                            if (subtitle != null) ...[
                              const SizedBox(height: 3),
                              Text(subtitle!, style: ui(12, c: d.ink2, h: 1.5)),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: closeTooltip,
                        visualDensity: VisualDensity.compact,
                        onPressed: busy ? null : close,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 2,
                  child: busy
                      ? const LinearProgressIndicator(minHeight: 2)
                      : null,
                ),
                if (height != null)
                  Expanded(child: body)
                else
                  Flexible(
                    child: scrollBody
                        ? SingleChildScrollView(child: body)
                        : body,
                  ),
                if (actions.isNotEmpty || footerLeft != null)
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: d.line)),
                    ),
                    child: Row(
                      children: [
                        if (footerLeft != null)
                          Expanded(child: footerLeft!)
                        else
                          const Spacer(),
                        for (var i = 0; i < actions.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          actions[i],
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!escapeCloses) return dialog;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!busy) close();
        },
      },
      child: Focus(autofocus: true, child: dialog),
    );
  }
}

/// 与 AlertDialog 参数相同的统一弹窗（V15）：标题、内容、按钮，外框与 [DeskDialog] 一致。
/// 宽度和 AlertDialog 一样随内容（IntrinsicWidth）；不加关闭按钮，
/// 需要明确选择的确认框（如离开工作区前保存）行为不变。
class DeskAlert extends StatelessWidget {
  const DeskAlert({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.scrollable = false,
    this.backgroundColor,
  });
  final Widget? title, content;
  final List<Widget> actions;
  final bool scrollable;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final screen = MediaQuery.sizeOf(context);
    Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: DefaultTextStyle.merge(
        style: ui(13, c: d.ink2, h: 1.6),
        child: content ?? const SizedBox.shrink(),
      ),
    );
    if (scrollable) body = SingleChildScrollView(child: body);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 360.0.clamp(0.0, screen.width - 32),
          maxWidth: screen.width - 32,
          maxHeight: screen.height - 32,
        ),
        child: IntrinsicWidth(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: backgroundColor ?? d.surface,
              borderRadius: BorderRadius.circular(14),
              boxShadow: d.shadow3,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                      child: DefaultTextStyle.merge(
                        style: ui(15.5, w: 650, c: d.ink),
                        child: title!,
                      ),
                    ),
                  Flexible(child: body),
                  if (actions.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: d.line)),
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: actions,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 小节标签（灰、半粗）。
class DeskLabel extends StatelessWidget {
  const DeskLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: ui(12, w: 600, c: context.desk.ink2)),
  );
}

/// 只读字段：灰底显示原值，可选择复制。
class DeskReadonlyField extends StatelessWidget {
  const DeskReadonlyField({
    super.key,
    required this.label,
    required this.value,
  });
  final String label, value;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DeskLabel(label),
        Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: d.sunken,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: d.line),
          ),
          child: SelectableText(value, style: ui(13, c: d.ink2)),
        ),
      ],
    );
  }
}

/// 输入框装饰：出错时朱色描边并在下方给原因。
InputDecoration deskInput(BuildContext context, {String? error, String? hint}) {
  final d = context.desk;
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(7),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: ui(13, c: d.ink3),
    errorText: error,
    errorStyle: ui(11.5, c: d.pen),
    filled: true,
    fillColor: d.surface,
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    border: border(d.lineStrong),
    enabledBorder: border(d.lineStrong),
    focusedBorder: border(d.accent, 1.4),
    errorBorder: border(d.pen, 1.4),
    focusedErrorBorder: border(d.pen, 1.4),
    disabledBorder: border(d.line),
  );
}

/// 影响说明 / 提示：灰底小字。[tone] 为朱时用于错误。
class DeskNote extends StatelessWidget {
  const DeskNote(this.text, {super.key, this.tone = Tone.neutral, this.title});
  final String text;
  final String? title;
  final Tone tone;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final error = tone == Tone.pen || tone == Tone.warn;
    final (fg, bg) = tone == Tone.neutral ? (d.ink3, d.sunken) : d.tone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 14,
              color: fg,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: ui(12, w: 620, c: error ? fg : d.ink2, h: 1.5),
                  ),
                Text(text, style: ui(11.5, c: error ? d.ink : d.ink2, h: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 带行号的正文行：选中（灰墨浅底 + 箭头）或范围（朱色浅底，用于删除）。
class DeskLineRow extends StatelessWidget {
  const DeskLineRow({
    super.key,
    required this.number,
    required this.text,
    this.selected = false,
    this.inRange = false,
    this.onTap,
  });
  final int number;
  final String text;
  final bool selected, inRange;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final on = selected || inRange;
    final empty = text.isEmpty;
    return Semantics(
      selected: on,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(vertical: 5),
          color: inRange ? d.delSoft : (selected ? d.accentSoft : null),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 60,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '$number',
                    textAlign: TextAlign.right,
                    style: mono(10.5, c: on ? d.ink2 : d.ink3),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 16,
                child: selected && !inRange
                    ? Icon(
                        Icons.subdirectory_arrow_right_rounded,
                        size: 14,
                        color: d.ink,
                      )
                    : null,
              ),
              Expanded(
                child: Text(
                  empty ? '（空行）' : text,
                  style: serif(
                    13.5,
                    c: empty ? d.ink3 : (on ? d.ink : d.ink2),
                    h: 1.6,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表容器：纸色底、细边框，内容自身滚动。
class DeskListBox extends StatelessWidget {
  const DeskListBox({super.key, required this.child, this.paper = true});
  final Widget child;
  final bool paper;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Material(
      color: paper ? d.paper : d.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: d.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 翻页条：前/后两个按钮 + 右侧位置说明。
class DeskPager extends StatelessWidget {
  const DeskPager({
    super.key,
    required this.previous,
    required this.next,
    required this.onPrevious,
    required this.onNext,
    required this.info,
    this.iconOnly = false,
  });
  final String previous, next, info;
  final VoidCallback? onPrevious, onNext;

  /// 只显示图标（提示文字仍为按钮名）。
  final bool iconOnly;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    Widget button(String label, IconData icon, VoidCallback? onPressed) =>
        iconOnly
        ? IconButton(
            tooltip: label,
            visualDensity: VisualDensity.compact,
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
          )
        : TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              foregroundColor: d.ink2,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16),
                const SizedBox(width: 4),
                Text(label),
              ],
            ),
          );
    return Row(
      children: [
        button(previous, Icons.keyboard_arrow_up_rounded, onPrevious),
        const SizedBox(width: 4),
        button(next, Icons.keyboard_arrow_down_rounded, onNext),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            info,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui(11.5, c: d.ink3),
          ),
        ),
      ],
    );
  }
}

/// 单选目标行（合并 / 移动 / 预览结构）。
class DeskChoiceRow extends StatelessWidget {
  const DeskChoiceRow({
    super.key,
    required this.title,
    this.detail,
    this.selected = false,
    this.disabledNote,
    this.onTap,
    this.radio = true,
  });
  final String title;
  final String? detail, disabledNote;
  final bool selected, radio;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final disabled = disabledNote != null;
    return Semantics(
      selected: selected,
      enabled: onTap != null,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? d.accentSoft : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              if (radio) ...[
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 15,
                  color: disabled ? d.line : (selected ? d.accent : d.ink3),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(
                    12.5,
                    w: selected ? 600 : 420,
                    c: disabled ? d.ink3 : d.ink,
                  ),
                ),
              ),
              if (disabledNote != null || detail != null) ...[
                const SizedBox(width: 8),
                Text(disabledNote ?? detail!, style: ui(11, c: d.ink3)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
