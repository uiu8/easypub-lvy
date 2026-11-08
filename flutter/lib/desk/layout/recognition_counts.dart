// 排版页的识别数量（V104，LAY-147）：本书按已保存的设置识别到多少处系统提示、诗词；
// “查看位置”打开识别与检查规则页并定位到这条规则，在那里逐处跳到章节页。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../application/rule_catalog_service.dart';
import '../tokens.dart';

class RecognitionCounts extends StatefulWidget {
  const RecognitionCounts({
    super.key,
    required this.library,
    required this.bookId,
  });
  final RuleCatalogLibrary library;
  final String bookId;

  @override
  State<RecognitionCounts> createState() => _RecognitionCountsState();
}

class _RecognitionCountsState extends State<RecognitionCounts> {
  late final RuleCatalogService service = widget.library.openRuleCatalog(
    widget.bookId,
  );

  @override
  void initState() {
    super.initState();
    service.state.addListener(_changed);
    unawaited(_request());
  }

  Future<void> _request() async {
    try {
      await service.request();
    } catch (_) {
      // 失败时状态里有原因，界面只是不显示数量。
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    // 书稿或设置变了：旧数量作废，自动重新统计。
    if (service.state.value.phase == RuleStatisticsPhase.stale) {
      unawaited(_request());
    }
  }

  @override
  void dispose() {
    service.state.removeListener(_changed);
    service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final state = service.state.value;
    final rules = state.result?.rules;
    final router = GoRouter.maybeOf(context);
    Widget locate(String rule) => router == null
        ? const SizedBox.shrink()
        : TextButton(
            key: ValueKey('layout-locate-$rule'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            onPressed: () => router.go(
              '/books/${Uri.encodeComponent(widget.bookId)}/rules'
              '?rule=${Uri.encodeQueryComponent(rule)}',
            ),
            child: Text('查看位置', style: ui(12, c: d.accent)),
          );
    final children = <Widget>[];
    if (rules == null) {
      children.add(
        Text(switch (state.phase) {
          RuleStatisticsPhase.failed => '暂时统计不出本书的识别数量。',
          RuleStatisticsPhase.cancelled => '统计已取消。',
          _ => '正在统计本书的识别数量…',
        }, style: ui(12, c: d.ink3)),
      );
    } else {
      for (final (id, label) in const [
        ('layout.system', '系统提示'),
        ('layout.verse', '诗词'),
      ]) {
        final r = rules[id];
        if (r == null) continue;
        children.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                r.enabled ? '$label ${r.count} 处' : '$label 未开启识别',
                key: ValueKey('layout-count-$id'),
                style: ui(12, c: r.enabled ? d.ink2 : d.ink3),
              ),
              if (r.enabled && r.count > 0) locate(id),
              const SizedBox(width: 10),
            ],
          ),
        );
      }
    }
    final brackets = state.result?.brackets?.text;
    return Padding(
      key: const ValueKey('layout-recognition-counts'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('本书识别到（按已保存的设置）：', style: ui(12, c: d.ink3)),
              ...children,
            ],
          ),
          // 整行【】的判断（V121，LAY-169）。
          if (brackets != null)
            Text(
              brackets,
              key: const ValueKey('layout-brackets'),
              style: ui(12, c: d.ink3),
            ),
        ],
      ),
    );
  }
}
