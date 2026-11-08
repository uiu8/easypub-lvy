import 'package:flutter/foundation.dart';

class ChangeRecord {
  const ChangeRecord(
    this.id,
    this.bookId,
    this.domain,
    this.title,
    this.version,
    this.applied,
    this.canUndo,
    this.destination, {
    this.category = '',
    this.canRedo = false,
    this.time,
  });
  final String id, bookId, domain, title, destination, category;

  /// 这一版本首次成为当前版本的时间；登记开始前已有的旧版本为 null（时间未记录）。
  final DateTime? time;
  final int version;
  final bool applied, canUndo, canRedo;
}

class ChangedField {
  const ChangedField(this.label, this.before, this.after);
  final String label, before, after;
}

class ChangeDetail {
  ChangeDetail(
    this.record,
    List<ChangedField> fields,
    this.guard, {
    List<ChangedField> technical = const [],
  }) : fields = List.unmodifiable(fields),
       technical = List.unmodifiable(technical);
  final ChangeRecord record;

  /// 给人看的修改前后；[technical] 是逐字段的原始差异，界面默认折叠（R4-01）。
  final List<ChangedField> fields, technical;
  final String guard;
}

abstract class ChangeHistoryService {
  Listenable get changes;
  List<ChangeRecord> records(String bookId);
  ChangeDetail detail(ChangeRecord record);
  Future<HistoryTrees> chapterTrees(
    ChangeDetail detail,
    int offset, {
    String? entryId,
  });
  Future<void> undo(ChangeDetail preview);
}

abstract interface class RedoChangeHistoryService {
  Future<void> redo(ChangeDetail preview);
}

class HistoryTreeNode {
  const HistoryTreeNode(this.id, this.title, this.depth, this.role);
  final String id, title, role;
  final int depth;
}

class HistoryTrees {
  HistoryTrees(
    List<HistoryTreeNode> before,
    List<HistoryTreeNode> after,
    this.beforeTotal,
    this.afterTotal,
    this.offset, {
    this.beforeOffset = 0,
    this.afterOffset = 0,
    this.entryId,
    this.beforeFound = false,
    this.afterFound = false,
  }) : before = List.unmodifiable(before),
       after = List.unmodifiable(after);
  final List<HistoryTreeNode> before, after;
  final int beforeTotal, afterTotal, offset;
  final int beforeOffset, afterOffset;
  final String? entryId;
  final bool beforeFound, afterFound;
}
