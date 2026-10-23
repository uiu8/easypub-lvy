import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';
import 'choice.dart';

export 'choice.dart';
export 'select_all.dart';

// 编辑台表单控件（V8 由 Paper 兼容层迁入并改名）：按钮、文字、表单栅格、滚动区、可调分栏与 Material 主题。
// 控件颜色一律取 context.desk 令牌；主题按“宣纸 / 夜墨 / 高对比”取对应令牌并换上所选主题色（V69、V79）。

/// 编辑台 Material 主题；[compact] 为紧凑密度，[accent] 为主题色编号（见 deskAccents）。
ThemeData deskTheme({
  bool compact = false,
  String? accent,
  String mode = 'paper',
}) => _Ink.themeFor(
  compact: compact,
  d: deskTokens(mode, deskAccentOf(accent)),
  mode: mode,
);

/// 主题构造（V79 起按所选主题的令牌）。
abstract final class _Ink {
  static ThemeData themeFor({
    bool compact = false,
    required Desk d,
    required String mode,
  }) {
    // 浮层悬停凹底：中性色，不随主题色变化（V79 起按主题取值）。
    final selected = switch (mode) {
      'night' => Color(0xFF2E2C29),
      'silver' => Color(0xFFE4E2E5),
      'contrast' => Color(0xFFDDDDDD),
      _ => Color(0xFFECE9E4),
    };
    final control = ColorScheme.fromSeed(
      seedColor: d.accent,
      brightness: d.dark ? Brightness.dark : Brightness.light,
      surface: d.surface,
    );
    return ThemeData(
      brightness: d.dark ? Brightness.dark : Brightness.light,
      useMaterial3: true,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      fontFamily: sansFamily,
      fontFamilyFallback: deskFallback,
      extensions: [d],
      scaffoldBackgroundColor: d.canvas,
      dividerColor: d.line,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: d.accent,
            brightness: d.dark ? Brightness.dark : Brightness.light,
          ).copyWith(
            primary: d.accent,
            onPrimary: d.accentInk,
            error: d.pen,
            surface: d.surface,
            onSurface: d.ink,
            onSurfaceVariant: d.ink2,
            outline: d.line,
            secondaryContainer: d.accentSoft,
            // 开关关闭时的底色等：夜墨与高对比用令牌里的中性灰，避免种子色带出色偏（V79）。
            surfaceContainerHighest: mode == 'paper' ? null : d.sunken,
          ),
      textTheme: TextTheme(
        bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: d.ink),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled) ||
              states.contains(WidgetState.selected)) {
            return null;
          }
          return states.any(
                {
                  WidgetState.hovered,
                  WidgetState.focused,
                  WidgetState.pressed,
                }.contains,
              )
              ? control.onSurfaceVariant
              : control.outline;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled) ||
              states.contains(WidgetState.selected)) {
            return null;
          }
          return control.outline;
        }),
      ),
      splashFactory: NoSplash.splashFactory,
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: d.ink,
          minimumSize: Size(0, compact ? 30 : 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(0, compact ? 30 : 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      // V7：下拉与菜单统一为编辑台浮层——表面色、10 圆角、细边与柔和阴影，悬停凹底。
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, compact ? 32 : 38)),
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 14)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? d.ink2.withValues(alpha: .6)
                : d.ink,
          ),
          iconColor: WidgetStatePropertyAll(d.ink2),
          overlayColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.any(
                  {
                    WidgetState.hovered,
                    WidgetState.focused,
                    WidgetState.pressed,
                  }.contains,
                )
                ? selected
                : null,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ),
      // V94：弹出菜单一律在按钮下方展开，不盖住按钮本身。
      popupMenuTheme: PopupMenuThemeData(
        position: PopupMenuPosition.under,
        color: d.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: .35),
        menuPadding: EdgeInsets.symmetric(vertical: 4),
        textStyle: TextStyle(fontSize: 14, color: d.ink),
        iconColor: d.ink2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: d.line),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(d.surface),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          elevation: WidgetStatePropertyAll(6),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: .35),
          ),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: d.line),
            ),
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(d.surface),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(6),
        radius: Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(d.ink2.withValues(alpha: .42)),
        crossAxisMargin: 2,
      ),
      // V8：系统 AlertDialog 与编辑台弹窗同一外观（14 圆角、深阴影、标题 15.5 半粗、正文次墨）。
      dialogTheme: DialogThemeData(
        barrierColor: Colors.black.withValues(alpha: .22),
        backgroundColor: d.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: .45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        titleTextStyle: TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          color: d.ink,
          height: 1.4,
        ),
        contentTextStyle: TextStyle(fontSize: 13, color: d.ink2, height: 1.55),
        actionsPadding: EdgeInsets.fromLTRB(20, 4, 16, 14),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: d.surface,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: d.lineStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: d.lineStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: d.accent, width: 1.4),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: d.ink.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(fontSize: 12, color: d.canvas, height: 1.4),
        waitDuration: Duration(milliseconds: 400),
      ),
    );
  }
}

class DeskScrollBehavior extends MaterialScrollBehavior {
  const DeskScrollBehavior();
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final vertical = axisDirectionToAxis(details.direction) == Axis.vertical;
    return Scrollbar(
      controller: details.controller,
      child: Padding(
        padding: vertical
            ? const EdgeInsets.only(right: 12)
            : const EdgeInsets.only(bottom: 12),
        child: child,
      ),
    );
  }
}

class DeskText extends StatelessWidget {
  const DeskText(
    this.text, {
    super.key,
    this.size = 14,
    this.bold = false,
    this.color,
    this.lines,
  });
  final String text;
  final double size;
  final bool bold;
  final Color? color;
  final int? lines;
  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: lines,
    overflow: lines == null ? null : TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: size,
      height: 1.45,
      color: color ?? context.desk.ink,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
    ),
  );
}

/// Form fields keep a readable width when the window or text scale changes.
class DeskFormGrid extends StatelessWidget {
  const DeskFormGrid({
    super.key,
    required this.children,
    this.columns = 2,
    this.minColumnWidth = 170,
    this.spacing = 12,
  });
  final List<Widget> children;
  final int columns;
  final double minColumnWidth, spacing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final minimum =
          minColumnWidth * MediaQuery.textScalerOf(context).scale(1);
      final count = ((bounds.maxWidth + spacing) / (minimum + spacing))
          .floor()
          .clamp(1, columns);
      final width = (bounds.maxWidth - spacing * (count - 1)) / count;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

class DeskButton extends StatelessWidget {
  const DeskButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.quiet = false,
    this.busy = false,
    this.dangerous = false,
    this.disabledReason,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary, quiet;
  final bool busy, dangerous, autofocus;
  final String? disabledReason, tooltip;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) {
    final message = busy || onPressed == null
        ? disabledReason ?? tooltip ?? label
        : tooltip ?? label;
    // 提示与按钮文字相同就不弹出：避免悬停时出现一个重复的文字块压住下方内容（V12）。
    return Tooltip(
      message: message,
      triggerMode: message == label ? TooltipTriggerMode.manual : null,
      waitDuration: message == label ? const Duration(days: 1) : null,
      child: _button(context),
    );
  }

  Widget _button(BuildContext context) => _PressBounce(
    enabled: !busy && onPressed != null,
    child: _plainButton(context),
  );

  Widget _plainButton(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      minHeight:
          (Theme.of(context).visualDensity == VisualDensity.compact ? 30 : 36) *
          MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
    ),
    child: TextButton(
      onPressed: busy ? null : onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      style: TextButton.styleFrom(
        foregroundColor: primary
            ? context.desk.accentInk
            : dangerous
            ? context.desk.pen
            : context.desk.ink,
        // 主按钮不可用时用凹陷浅底与灰字，而不是半透明，便于与可用态区分（G-060）。
        disabledForegroundColor: context.desk.ink2,
        disabledBackgroundColor: primary ? context.desk.sunken : null,
        backgroundColor: primary
            ? dangerous
                  ? context.desk.pen
                  : context.desk.accent
            : quiet
            ? Colors.transparent
            : context.desk.surface,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(
            color: primary || quiet
                ? Colors.transparent
                : context.desk.lineStrong,
          ),
        ),
        textStyle: const TextStyle(
          fontFamily: sansFamily,
          fontFamilyFallback: deskFallback,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: 17),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    ),
  );
}

/// 按钮按下时缩到 97%，松开后带轻微回弹复位（V41，G-070）：按下用 [DeskMotion.fast]，
/// 复位用 [DeskMotion.snap] + [DeskMotion.overshoot]。只改绘制比例，不影响布局与点击区域。
class _PressBounce extends StatefulWidget {
  const _PressBounce({required this.enabled, required this.child});
  final bool enabled;
  final Widget child;
  @override
  State<_PressBounce> createState() => _PressBounceState();
}

class _PressBounceState extends State<_PressBounce> {
  bool pressed = false;
  void set(bool value) {
    if (pressed != value && mounted) setState(() => pressed = value);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: widget.enabled ? (_) => set(true) : null,
    onPointerUp: (_) => set(false),
    onPointerCancel: (_) => set(false),
    child: AnimatedScale(
      scale: pressed ? .97 : 1,
      duration: DeskMotion.of(
        context,
        pressed ? DeskMotion.fast : DeskMotion.snap,
      ),
      curve: pressed ? DeskMotion.easeOut : DeskMotion.overshoot,
      child: widget.child,
    ),
  );
}

/// Reserves a gutter so the desktop scrollbar never covers form controls.
class DeskScrollArea extends StatefulWidget {
  const DeskScrollArea({super.key, required this.builder, this.controller});
  final Widget Function(ScrollController controller) builder;
  final ScrollController? controller;
  @override
  State<DeskScrollArea> createState() => _DeskScrollAreaState();
}

class _DeskScrollAreaState extends State<DeskScrollArea> {
  final _owned = ScrollController();
  @override
  void dispose() {
    _owned.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller ?? _owned;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: widget.builder(controller),
        ),
      ),
    );
  }
}

class DeskScrollView extends StatelessWidget {
  const DeskScrollView({
    super.key,
    required this.child,
    this.controller,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => DeskScrollArea(
    controller: controller,
    builder: (scroll) => SingleChildScrollView(
      controller: scroll,
      padding: padding,
      child: child,
    ),
  );
}

/// Keeps a useful panel width; small windows switch between the same two panes.
class DeskSplitView extends StatefulWidget {
  const DeskSplitView({
    super.key,
    required this.leading,
    required this.trailing,
    required this.leadingLabel,
    required this.trailingLabel,
    this.leadingWidth,
    this.trailingWidth,
    this.breakpoint = 760,
    this.initialIndex = 0,
  });
  final Widget leading, trailing;
  final String leadingLabel, trailingLabel;
  final double? leadingWidth, trailingWidth;
  final double breakpoint;
  final int initialIndex;
  @override
  State<DeskSplitView> createState() => _DeskSplitViewState();
}

class _DeskSplitViewState extends State<DeskSplitView> {
  late int selected = widget.initialIndex;
  double? adjustedLeadingWidth;
  bool dividerFocused = false;

  /// 拖动开始时的左栏宽度与指针横坐标：宽度 = 起始宽度 + 指针总位移，
  /// 一帧内来多个移动事件也不会丢位移（V83）。
  double? dragWidth, dragOrigin;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      if (bounds.maxWidth < widget.breakpoint) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DeskModeSwitch<int>(
              value: selected,
              options: {0: widget.leadingLabel, 1: widget.trailingLabel},
              onChanged: (value) => setState(() => selected = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: IndexedStack(
                index: selected,
                children: [widget.leading, widget.trailing],
              ),
            ),
          ],
        );
      }
      final available = bounds.maxWidth - 18;
      final initial =
          widget.leadingWidth ??
          (widget.trailingWidth == null
              ? available / 2
              : available - widget.trailingWidth!);
      final leading = (adjustedLeadingWidth ?? initial).clamp(
        180.0,
        available - 180,
      );
      double fit(double width) => width.clamp(180.0, available - 180);
      // 键盘连按同样从最新宽度累加，而不是上一帧排出来的宽度。
      void resize(double delta) => setState(
        () => adjustedLeadingWidth = fit(
          fit(adjustedLeadingWidth ?? initial) + delta,
        ),
      );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: leading, child: widget.leading),
          Focus(
            onFocusChange: (value) => setState(() => dividerFocused = value),
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                resize(-20);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                resize(20);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Semantics(
              label: '调整分栏宽度',
              value: '${(leading / available * 100).round()}%',
              increasedValue:
                  '${((leading + 20).clamp(180, available - 180) / available * 100).round()}%',
              decreasedValue:
                  '${((leading - 20).clamp(180, available - 180) / available * 100).round()}%',
              onIncrease: () => resize(20),
              onDecrease: () => resize(-20),
              child: Tooltip(
                message: '拖动调整；聚焦后用左右方向键',
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onHorizontalDragStart: (details) {
                      dragWidth = leading;
                      dragOrigin = details.globalPosition.dx;
                    },
                    onHorizontalDragUpdate: (details) => setState(
                      () => adjustedLeadingWidth = fit(
                        (dragWidth ?? leading) +
                            details.globalPosition.dx -
                            (dragOrigin ?? details.globalPosition.dx),
                      ),
                    ),
                    onHorizontalDragEnd: (_) => dragWidth = dragOrigin = null,
                    onHorizontalDragCancel: () => dragWidth = dragOrigin = null,
                    child: SizedBox(
                      width: 18,
                      child: Center(
                        child: Container(
                          width: dividerFocused ? 3 : 1,
                          color: dividerFocused
                              ? context.desk.accent
                              : context.desk.line,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: widget.trailing),
        ],
      );
    },
  );
}
