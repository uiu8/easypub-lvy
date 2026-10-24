// 编辑台基础小件：按键提示、状态点、分段选择。设计来源 design_review_v37/widgets.dart。
import 'package:flutter/material.dart';

import 'tokens.dart';

class Kbd extends StatelessWidget {
  const Kbd(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? context.desk.ink2;
    final side = BorderSide(color: c.withValues(alpha: .3));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      height: 17,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border(
          top: side,
          left: side,
          right: side,
          bottom: side.copyWith(width: 2),
        ),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(text, style: mono(10.5, c: c)),
      ),
    );
  }
}

class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 7});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 分段选择：每段是独立可聚焦按钮，选中段带浮起底色；不可用时整组变淡。
class DeskSegmented<T> extends StatelessWidget {
  const DeskSegmented({
    super.key,
    required this.value,
    required this.options,
    this.onChanged,
    this.badges = const {},
  });
  final T value;
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;

  /// 段名后的小字（R3-03，例如问题数）；“!”表示读取失败，用朱色。
  final Map<T, String> badges;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    // 窄栏或大字号时整组按比例缩小，不溢出；宽度足够时原样显示。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: _segments(d),
    );
  }

  Widget _segments(Desk d) {
    return Opacity(
      opacity: onChanged == null ? .55 : 1,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: d.sunken,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: d.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in options.entries)
              Semantics(
                selected: entry.key == value,
                button: true,
                child: TextButton(
                  onPressed: onChanged == null
                      ? null
                      : () => onChanged!(entry.key),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    backgroundColor: entry.key == value ? d.surface : null,
                    foregroundColor: entry.key == value ? d.ink : d.ink2,
                    disabledForegroundColor: entry.key == value
                        ? d.ink
                        : d.ink2,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    textStyle: ui(12.5, w: entry.key == value ? 600 : 520),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: badges[entry.key] == null
                      ? Text(entry.value)
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(entry.value),
                            const SizedBox(width: 4),
                            Text(
                              badges[entry.key]!,
                              key: ValueKey('segment-badge-${entry.key}'),
                              style: mono(
                                11,
                                w: 600,
                                c: badges[entry.key] == '!' ? d.pen : d.warn,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 书无封面图时的书脊式占位：低饱和底色 + 书名前两个字。
class BookMonogram extends StatelessWidget {
  const BookMonogram(this.title, {super.key, this.w = 30, this.h = 42});
  final String title;
  final double w, h;
  static const _pairs = [
    (Color(0xFF5B6B63), Color(0xFF414D47)),
    (Color(0xFF7D6A58), Color(0xFF5E4F41)),
    (Color(0xFF5E6573), Color(0xFF454B57)),
    (Color(0xFF75626A), Color(0xFF574850)),
    (Color(0xFF8A8370), Color(0xFF6A6455)),
  ];
  @override
  Widget build(BuildContext context) {
    final (a, b) = _pairs[title.hashCode.abs() % _pairs.length];
    final chars = title.trim().characters.take(2).toList();
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [a, b],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.horizontal(
          left: Radius.circular(2),
          right: Radius.circular(4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .18),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: w * .08,
            child: ColoredBox(color: Colors.black.withValues(alpha: .2)),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in chars)
                  Text(
                    c,
                    style: serif(
                      w / 3.6,
                      w: 600,
                      c: const Color(0xFFEDE8DC),
                      h: 1.15,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 说明问号：悬停（或长按）显示用途与写法；不占用界面结构。
class DeskHelp extends StatelessWidget {
  const DeskHelp(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Tooltip(
      message: message,
      preferBelow: true,
      waitDuration: const Duration(milliseconds: 250),
      showDuration: const Duration(seconds: 30),
      triggerMode: TooltipTriggerMode.tap,
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(
          Icons.help_outline_rounded,
          size: 15,
          color: d.ink3,
          semanticLabel: '说明',
        ),
      ),
    );
  }
}

/// 小标签：语义色浅底 + 等宽小字（新增 / 移除 / 待核对等）。中性时用凹底次墨。
class DeskTag extends StatelessWidget {
  const DeskTag(this.text, this.tone, {super.key, this.singleLine = false});
  final String text;
  final Tone tone;

  /// 放不下时单行省略，而不是折行（宽度由外层限制）。
  final bool singleLine;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (fg, bg) = tone == Tone.neutral ? (d.ink2, d.sunken) : d.tone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        maxLines: singleLine ? 1 : null,
        overflow: singleLine ? TextOverflow.ellipsis : null,
        style: ui(11, c: fg, w: 600),
      ),
    );
  }
}

/// 文件大小：不足 1 KB 写字节数，其余写 KB / MB（一位小数）（TASK-025、TASK-028）。
String formatFileSize(int bytes) => bytes < 1024
    ? '$bytes 字节'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
