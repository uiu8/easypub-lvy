// 迁入 desk（library，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../../application/library_service.dart';
import '../tokens.dart';

class BookStructureCounts extends StatefulWidget {
  const BookStructureCounts({
    super.key,
    required this.library,
    required this.book,
    this.compact = false,
    this.prefix = '',
    this.style,
  });
  final LibraryService library;
  final BookSummary book;
  final bool compact;
  final String prefix;

  /// 指定时替换默认字号与颜色，便于与同一行的其他文字对齐（LIB-105）。
  final TextStyle? style;
  @override
  State<BookStructureCounts> createState() => _BookStructureCountsState();
}

class _BookStructureCountsState extends State<BookStructureCounts> {
  Future<Map<String, dynamic>>? value;
  void read() {
    final service = widget.library;
    value = service is BookStatisticsService
        ? (service as BookStatisticsService).statistics(widget.book.id)
        : null;
  }

  @override
  void initState() {
    super.initState();
    read();
  }

  @override
  void didUpdateWidget(BookStructureCounts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library ||
        oldWidget.book.id != widget.book.id ||
        oldWidget.book.contentVersion != widget.book.contentVersion) {
      read();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    key: ValueKey((widget.book.id, widget.book.contentVersion)),
    future: value,
    builder: (_, snapshot) {
      if (snapshot.hasError) {
        return InkWell(
          onTap: () => setState(read),
          child: Text(
            '统计读取失败，点击重试',
            style: TextStyle(fontSize: 12, color: context.desk.accent),
          ),
        );
      }
      final data = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null;
      return Text(
        data == null
            ? (value == null ? '统计不可用' : '统计读取中…')
            // 没有分卷时不显示“0 卷”（V12）。
            : data['volumes'] == 0
            ? '${widget.prefix}${data['chapters']} 章'
            : '${widget.prefix}${data['volumes']} 卷 · ${data['chapters']} 章',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            widget.style ??
            TextStyle(
              fontSize: widget.compact ? 12 : 14,
              color: context.desk.ink2,
            ),
      );
    },
  );
}
