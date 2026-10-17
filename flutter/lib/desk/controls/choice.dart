import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controls.dart';
import '../tokens.dart';

/// A selection field, not an editable text field. Long lists expose search in
/// the anchored menu; typing never leaves an uncommitted value in the field.
class DeskChoice<T> extends StatefulWidget {
  const DeskChoice({
    super.key,
    this.value,
    this.initialValue,
    required this.items,
    required this.onChanged,
    this.decoration,
    this.hint,
    this.isExpanded = true,
    this.isDense = true,
    this.iconSize = 18,
    this.style,
    this.compact = false,
    this.searchable,
    this.disabledReason,
    this.underline,
    this.searchText,
    this.icon,
    this.selectedLabel,
  });
  final T? value, initialValue;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;
  final Widget? hint, underline, icon;
  final bool isExpanded, isDense, compact;
  final bool? searchable;
  final double iconSize;
  final TextStyle? style;
  final String? disabledReason;
  final String Function(T value)? searchText;

  /// 选择框里显示的文字（例如机型短名）；为 null 时与菜单项相同（LAY-102）。
  final Widget Function(T value)? selectedLabel;
  @override
  State<DeskChoice<T>> createState() => _DeskChoiceState<T>();
}

class _DeskChoiceState<T> extends State<DeskChoice<T>> {
  final menu = MenuController();
  final focus = FocusNode();
  final query = TextEditingController();
  String filter = '';
  @override
  void initState() {
    super.initState();
    focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    focus.dispose();
    query.dispose();
    super.dispose();
  }

  String textOf(Widget child) => switch (child) {
    Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText() ?? '',
    DeskText(:final text) => text,
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final value = widget.value ?? widget.initialValue;
    final items = widget.items ?? <DropdownMenuItem<T>>[];
    final selected = items.where((item) => item.value == value).firstOrNull;
    final enabled = widget.onChanged != null && items.isNotEmpty;
    final searchable = widget.searchable ?? items.length > 8;
    final choices = items.where((item) {
      final label = item.value == null
          ? textOf(item.child)
          : widget.searchText?.call(item.value as T) ?? textOf(item.child);
      return label.toLowerCase().contains(filter.toLowerCase());
    }).toList();
    final label = selected == null ? '' : textOf(selected.child);
    final shown = selected == null
        ? null
        : widget.selectedLabel?.call(selected.value as T) ?? selected.child;
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = bounds.maxWidth.isFinite ? bounds.maxWidth : 260.0;
        // V42（G-071）：外壳透明、不裁剪，由 _MenuEntrance 画出原来的面板并负责入场动画；
        // 四周留出阴影的位置，再用 alignmentOffset 抵消，面板位置与原来相同。
        return MenuAnchor(
          controller: menu,
          childFocusNode: focus,
          clipBehavior: Clip.none,
          alignmentOffset: const Offset(-_MenuEntrance.gutter, 0),
          style: MenuStyle(
            minimumSize: WidgetStatePropertyAll(
              Size(width.clamp(160, 420) + 2 * _MenuEntrance.gutter, 0),
            ),
            maximumSize: WidgetStatePropertyAll(
              Size(
                width.clamp(260, 520) + 2 * _MenuEntrance.gutter,
                420 + _MenuEntrance.gutter,
              ),
            ),
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(0),
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          ),
          onClose: () {
            if (mounted) {
              setState(() {
                filter = '';
                query.clear();
              });
            }
          },
          menuChildren: [
            _MenuEntrance(
              children: [
                if (searchable)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                    child: SizedBox(
                      width: width.clamp(220, 440),
                      child: TextField(
                        controller: query,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: '搜索选项',
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                        onChanged: (value) => setState(() => filter = value),
                      ),
                    ),
                  ),
                if (choices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('没有匹配的选项'),
                  ),
                for (final item in choices)
                  MenuItemButton(
                    onPressed: !item.enabled
                        ? null
                        : () => widget.onChanged?.call(item.value),
                    trailingIcon: item.value == value
                        ? const Icon(Icons.check, size: 17)
                        : null,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: DefaultTextStyle.merge(
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        child: item.child,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          builder: (context, controller, child) {
            final trigger = TextButton(
              focusNode: focus,
              onPressed: !enabled
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
              style: TextButton.styleFrom(
                foregroundColor: context.desk.ink,
                padding: EdgeInsets.symmetric(
                  horizontal: widget.compact ? 8 : 0,
                ),
                minimumSize: Size(0, widget.compact ? 32 : 22),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: DefaultTextStyle.merge(
                style: widget.style ?? const TextStyle(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: Row(
                  mainAxisSize: widget.isExpanded && bounds.maxWidth.isFinite
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  children: [
                    if (widget.isExpanded && bounds.maxWidth.isFinite)
                      Expanded(child: shown ?? widget.hint ?? const Text('请选择'))
                    else
                      shown ?? widget.hint ?? const Text('请选择'),
                    const SizedBox(width: 8),
                    widget.icon ??
                        Icon(
                          Icons.expand_more_rounded,
                          size: widget.iconSize,
                          color: enabled
                              ? context.desk.ink2
                              : context.desk.lineStrong,
                        ),
                  ],
                ),
              ),
            );
            return Tooltip(
              message: !enabled && widget.disabledReason != null
                  ? widget.disabledReason!
                  : label,
              child: widget.compact || !bounds.maxWidth.isFinite
                  ? trigger
                  : InputDecorator(
                      isFocused: focus.hasFocus,
                      decoration: (widget.decoration ?? const InputDecoration())
                          .copyWith(enabled: enabled),
                      child: trigger,
                    ),
            );
          },
        );
      },
    );
  }
}

/// Compact, clearable choices for list filters.
class DeskFilter<T> extends StatelessWidget {
  const DeskFilter({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.onClear,
    this.label,
  });
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final VoidCallback? onClear;
  final String? label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: DeskChoice<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          compact: true,
          isExpanded: false,
          hint: label == null ? null : Text(label!),
        ),
      ),
      if (onClear != null)
        IconButton(
          tooltip: '清除筛选',
          onPressed: onClear,
          icon: const Icon(Icons.close, size: 16),
          visualDensity: VisualDensity.compact,
        ),
    ],
  );
}

/// Commands retain native anchored-menu keyboard traversal and focus return.
class DeskCommandMenu<T> extends StatelessWidget {
  const DeskCommandMenu({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.onCanceled,
    this.onOpened,
    this.initialValue,
    this.tooltip,
    this.enabled = true,
    this.icon,
    this.child,
    this.disabledReason,
    this.offset = Offset.zero,
  });
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final VoidCallback? onCanceled, onOpened;
  final T? initialValue;
  final String? tooltip, disabledReason;
  final bool enabled;
  final Widget? icon, child;
  final Offset offset;
  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    itemBuilder: itemBuilder,
    onSelected: onSelected,
    onCanceled: onCanceled,
    onOpened: onOpened,
    initialValue: initialValue,
    tooltip: !enabled ? disabledReason ?? tooltip : tooltip,
    enabled: enabled,
    icon: icon,
    offset: offset,
    position: PopupMenuPosition.under,
    requestFocus: true,
    constraints: const BoxConstraints(minWidth: 180, maxWidth: 380),
    child: child,
  );
}

class DeskModeSwitch<T> extends StatelessWidget {
  const DeskModeSwitch({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final T value;
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 2,
    runSpacing: 4,
    children: [
      for (final entry in options.entries)
        Semantics(
          selected: entry.key == value,
          child: TextButton(
            onPressed: onChanged == null ? null : () => onChanged!(entry.key),
            style: TextButton.styleFrom(
              foregroundColor: entry.key == value
                  ? context.desk.accent
                  : context.desk.ink2,
              backgroundColor: entry.key == value
                  ? context.desk.accentSoft
                  : Colors.transparent,
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            child: Text(entry.value),
          ),
        ),
    ],
  );
}

/// Routes shell-level search to the visible page even while a navigation or
/// footer control has focus. Local page shortcuts retain their precedence.
class DeskSearchHost extends StatefulWidget {
  const DeskSearchHost({super.key, required this.child});
  final Widget child;
  @override
  State<DeskSearchHost> createState() => _DeskSearchHostState();
}

class _DeskSearchHostState extends State<DeskSearchHost> {
  FocusNode? target;
  VoidCallback? search;
  @override
  Widget build(BuildContext context) => _SearchTarget(
    host: this,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            search?.call(),
      },
      child: widget.child,
    ),
  );
}

class _SearchTarget extends InheritedWidget {
  const _SearchTarget({required this.host, required super.child});
  final _DeskSearchHostState host;
  @override
  bool updateShouldNotify(_SearchTarget oldWidget) => host != oldWidget.host;
}

/// Ctrl+F belongs to the visible workspace, while editable fields keep their
/// own undo/copy/selection bindings.
class DeskSearchScope extends StatefulWidget {
  const DeskSearchScope({
    super.key,
    required this.focusNode,
    required this.child,
    this.onSearch,
  });
  final FocusNode focusNode;
  final Widget child;
  final VoidCallback? onSearch;
  @override
  State<DeskSearchScope> createState() => _DeskSearchScopeState();
}

class _DeskSearchScopeState extends State<DeskSearchScope> {
  _DeskSearchHostState? host;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    host = context.dependOnInheritedWidgetOfExactType<_SearchTarget>()?.host;
    host?.target = widget.focusNode;
    host?.search = widget.onSearch ?? widget.focusNode.requestFocus;
  }

  @override
  void didUpdateWidget(covariant DeskSearchScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    host?.target = widget.focusNode;
    host?.search = widget.onSearch ?? widget.focusNode.requestFocus;
  }

  @override
  void dispose() {
    if (host?.target == widget.focusNode) {
      host?.target = null;
      host?.search = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyF, control: true):
          widget.onSearch ?? widget.focusNode.requestFocus,
    },
    child: widget.child,
  );
}

/// 下拉菜单面板（V42，G-071）：外观与主题里的菜单相同（表面色、10 圆角、细边、6 级阴影、4 内边距），
/// 打开时淡入并下滑 4 像素，[DeskMotion.snap] + [DeskMotion.easeOut]；减少动效时直接出现。
/// 关闭仍由 MenuAnchor 立即移除。
class _MenuEntrance extends StatefulWidget {
  const _MenuEntrance({required this.children});
  final List<Widget> children;

  /// 面板四周留给阴影的宽度。
  static const gutter = 10.0;

  @override
  State<_MenuEntrance> createState() => _MenuEntranceState();
}

class _MenuEntranceState extends State<_MenuEntrance>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(vsync: this);
  late final curve = CurvedAnimation(
    parent: controller,
    curve: DeskMotion.easeOut,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = DeskMotion.of(context, DeskMotion.snap);
    if (controller.duration == null) {
      controller.duration = duration;
      duration == Duration.zero ? controller.value = 1 : controller.forward();
    }
  }

  @override
  void dispose() {
    curve.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _MenuEntrance.gutter,
        0,
        _MenuEntrance.gutter,
        _MenuEntrance.gutter,
      ),
      child: AnimatedBuilder(
        animation: curve,
        builder: (context, child) => Opacity(
          opacity: curve.value,
          child: Transform.translate(
            offset: Offset(0, -4 * (1 - curve.value)),
            child: child,
          ),
        ),
        child: Material(
          color: d.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 6,
          shadowColor: Colors.black.withValues(alpha: .35),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: d.line),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              primary: false,
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
