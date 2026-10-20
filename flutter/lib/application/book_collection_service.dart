// 书库收藏夹（V84，LIB-118–126）：把书分组；可带一份“预设信息”，书加入时按它补全或改写
// 书籍信息。加入/移出只改分组；改书籍信息一律先预览（或在收藏夹开了“加入后自动套用”时
// 预览后立刻应用并可撤销），走与书籍信息相同的制作历史。
import 'package:flutter/foundation.dart';

/// 预设信息可用的字段（与元数据映射同一套字段与应用方式）。
const collectionTemplateFields = <String, String>{
  'author': '作者',
  'translator': '译者',
  'publisher': '出版社',
  'category': '类别',
  'series': '系列',
  'subjects': '主题 / 标签',
  'language': '语言',
};

@immutable
class BookCollection {
  BookCollection({
    required this.id,
    required this.name,
    List<String> books = const [],
    Map<String, Map<String, String>> template = const {},
    this.autoApply = false,
  }) : books = List.unmodifiable(books),
       template = Map.unmodifiable(
         template.map(
           (k, v) => MapEntry(k, Map<String, String>.unmodifiable(v)),
         ),
       );
  final String id, name;

  /// 成员书 id（加入顺序）。可能含已从书库移除的书，界面只显示仍在书库的。
  final List<String> books;

  /// 字段 → {op: set / fill_empty / clear, value}；为空时加入不改书籍信息。
  final Map<String, Map<String, String>> template;
  final bool autoApply;

  bool get hasTemplate => template.values.any((e) => e['op'] != 'keep');

  BookCollection copyWith({
    String? name,
    List<String>? books,
    Map<String, Map<String, String>>? template,
    bool? autoApply,
  }) => BookCollection(
    id: id,
    name: name ?? this.name,
    books: books ?? this.books,
    template: template ?? this.template,
    autoApply: autoApply ?? this.autoApply,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (books.isNotEmpty) 'books': books,
    if (template.isNotEmpty) 'template': template,
    'auto_apply': autoApply,
  };

  factory BookCollection.fromJson(Map value) => BookCollection(
    id: value['id'] as String,
    name: value['name'] as String,
    books: [for (final b in value['books'] as List? ?? const []) b as String],
    template: {
      for (final e in (value['template'] as Map? ?? const {}).entries)
        e.key as String: {
          for (final f in (e.value as Map).entries)
            f.key as String: '${f.value}',
        },
    },
    autoApply: value['auto_apply'] == true,
  );
}

/// 一本书的信息变化（预览结果，只读）。
@immutable
class BookFieldChange {
  const BookFieldChange({
    required this.bookId,
    required this.title,
    required this.before,
    required this.after,
    required this.changed,
  });
  final String bookId, title;
  final Map<String, Object?> before, after;
  final List<String> changed;
}

/// 套用预设信息或批量设类别的预览；只能由生成它的服务应用一次。
class BookFieldPreview {
  BookFieldPreview(List<BookFieldChange> items, {this.label = ''})
    : items = List.unmodifiable(items);
  final List<BookFieldChange> items;
  final String label;
  int get changedBooks => items.where((i) => i.changed.isNotEmpty).length;
}

/// 已应用的一批改动，可整批撤销（每本书撤回各自的上一步制作设置）。
class BookFieldApplied {
  const BookFieldApplied(this.token, this.books, this.message);
  final Object token;
  final List<String> books;
  final String message;
}

abstract interface class BookCollectionService {
  ValueListenable<List<BookCollection>> get collections;

  /// 新建收藏夹；名称去掉首尾空白后不能为空或与已有重名（不分大小写）。
  BookCollection createCollection(
    String name, {
    Map<String, Map<String, String>> template = const {},
    bool autoApply = false,
  });

  /// 改名、改预设信息或自动套用开关（成员不变）。
  void updateCollection(BookCollection collection);

  /// 删除收藏夹本身；书仍在书库，书籍信息不变。
  void deleteCollection(String id);

  /// 加入书；返回这次新加入的书（已在收藏夹里的不重复加入）。
  List<String> addToCollection(String id, Iterable<String> bookIds);
  void removeFromCollection(String id, Iterable<String> bookIds);

  /// 由原文件路径找到书库里的书（拖入或导入后加入收藏夹用）。
  String? bookIdForPath(String path);

  /// 书库里已用过的类别（去重、按次数排序），供批量设类别时选择。
  List<String> knownCategories();

  /// 预览按字段改写多本书（预设信息、批量设类别）。
  Future<BookFieldPreview> previewFields(
    Map<String, Map<String, String>> fields,
    List<String> bookIds, {
    String label = '',
  });

  /// 应用上一次预览；预览后书籍有改动则拒绝并要求重新预览。
  Future<BookFieldApplied> applyFields(BookFieldPreview preview);

  /// 撤销刚应用的一批；任何一本在此之后又改过则拒绝，书籍信息不变。
  Future<String> undoFields(BookFieldApplied applied);
}

/// 收藏夹名称校验（与 Rust 端一致）：返回错误说明，合格时返回 null。
String? collectionNameError(
  String name,
  Iterable<BookCollection> existing, {
  String? exceptId,
}) {
  final value = name.trim();
  if (value.isEmpty) return '请输入收藏夹名称';
  if (value.runes.length > 64) return '名称最多 64 个字';
  if (existing.any(
    (c) => c.id != exceptId && c.name.toLowerCase() == value.toLowerCase(),
  )) {
    return '已有同名收藏夹';
  }
  return null;
}
