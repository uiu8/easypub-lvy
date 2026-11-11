// 转换百分比显示：任务运行时每半秒按估算刷新一次。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/conversion_progress.dart';
import '../../application/conversion_service.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 按 [outputs]（一本或整批）显示“进度槽 + 约 xx%”；[compact] 时只显示文字。
class ConversionPercent extends StatefulWidget {
  const ConversionPercent({
    super.key,
    required this.outputs,
    this.compact = false,
    this.suffix = '',
  });
  final List<ConversionOutput> outputs;
  final bool compact;
  final String suffix;
  @override
  State<ConversionPercent> createState() => _ConversionPercentState();
}

class _ConversionPercentState extends State<ConversionPercent> {
  Timer? timer;

  bool get running => widget.outputs.any((o) => o.running);

  void schedule() {
    if (running) {
      timer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else {
      timer?.cancel();
      timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(ConversionPercent old) {
    super.didUpdateWidget(old);
    schedule();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final value = widget.outputs.length == 1
        ? ConversionProgress.instance.fraction(widget.outputs.single)
        : ConversionProgress.instance.batch(widget.outputs);
    if (value == null) return const SizedBox.shrink();
    final text = Text(
      '${ConversionProgress.label(value)}${widget.suffix}',
      key: const ValueKey('conversion-percent'),
      style: ui(12, w: 600, c: d.ink2),
    );
    if (widget.compact) return text;
    return Row(
      children: [
        Expanded(
          child: DeskProgressTrack(value: value, color: d.add, height: 4),
        ),
        const SizedBox(width: 10),
        text,
      ],
    );
  }
}
