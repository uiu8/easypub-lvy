import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';
import 'choice.dart';

export 'choice.dart';
export 'select_all.dart';

// 编辑台表单控件（V8 由 Paper 兼容层迁入并改名）：按钮、文字、表单栅格、滚动区、可调分栏与 Material 主题。
// 控件颜色一律取 context.desk 令牌；主题只有浅色一套，取值即 Desk.light。

/// 编辑台 Material 主题；[compact] 为紧凑密度。
ThemeData deskTheme({bool compact = false}) => _Ink.themeFor(compact: compact);

/// 主题内部用的浅色值（与 Desk.light 相同，常量形式供主题构造）。
abstract final class _Ink {
  static const canvas = Color(0xFFF6F4EF), surface = Color(0xFFFCFBF8);
  static const ink = Color(0xFF1F1E1B), muted = Color(0xFF5E5A53);
  static const line = Color(0xFFE4E0D7), lineStrong = Color(0xFFD3CEC3);
  static const accent = Color(0xFF6F6A63), onAccent = Color(0xFFF7F5F0);
  static const selected = Color(0xFFECE9E4);
  static const pen = Color(0xFFA94434);
  static final _controlScheme = ColorScheme.fromSeed(
    seedColor: accent,
    surface: surface,
  );
  static ThemeData themeFor({bool compact = false}) => ThemeData(
    useMaterial3: true,
    visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    fontFamily: sansFamily,
    fontFamilyFallback: deskFallback,
    extensions: const [Desk.light],
    scaffoldBackgroundColor: canvas,
    dividerColor: line,
    colorScheme: ColorScheme.fromSeed(seedColor: accent).copyWith(
      primary: accent,
      onPrimary: onAccent,
      error: pen,
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: line,
      secondaryContainer: selected,
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: ink),
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
            ? _controlScheme.onSurfaceVariant
            : _controlScheme.outline;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled) ||
            states.contains(WidgetState.selected)) {
          return null;
        }
        return _controlScheme.outline;
      }),
    ),
    splashFactory: NoSplash.splashFactory,
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ink,
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
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 14)),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? muted.withValues(alpha: .6)
              : ink,
        ),
        iconColor: const WidgetStatePropertyAll(muted),
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
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: .35),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      textStyle: const TextStyle(fontSize: 14, color: ink),
      iconColor: muted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: line),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(6),
        shadowColor: WidgetStatePropertyAll(
          Colors.black.withValues(alpha: .35),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: line),
          ),
        ),
      ),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(muted.withValues(alpha: .42)),
      crossAxisMargin: 2,
    ),
    // V8：系统 AlertDialog 与编辑台弹窗同一外观（14 圆角、深阴影、标题 15.5 半粗、正文次墨）。
    dialogTheme: DialogThemeData(
      barrierColor: Colors.black.withValues(alpha: .22),
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: .45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: const TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        color: ink,
        height: 1.4,
      ),
      contentTextStyle: const TextStyle(
        fontSize: 13,
        color: muted,
        height: 1.55,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 16, 14),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: lineStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: lineStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: accent, width: 1.4),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: ink.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(fontSize: 12, color: onAccent, height: 1.4),
      waitDuration: const Duration(milliseconds: 400),
    ),
  );
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
      void resize(double delta) => setState(
        () => adjustedLeadingWidth = (leading + delta).clamp(
          180.0,
          available - 180,
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
                    onHorizontalDragUpdate: (details) =>
                        resize(details.delta.dx),
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
