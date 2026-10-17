import 'package:flutter/foundation.dart';

enum SupplementalPageKind {
  copyright,
  dedication,
  authorNote,
  afterword,
  aboutAuthor,
  custom,
}

enum SupplementalPagePosition { front, back }

const supplementalPageLabels = {
  SupplementalPageKind.copyright: '版权页',
  SupplementalPageKind.dedication: '献词',
  SupplementalPageKind.authorNote: '作者的话',
  SupplementalPageKind.afterword: '后记',
  SupplementalPageKind.aboutAuthor: '关于作者',
  SupplementalPageKind.custom: '自定义',
};
const supplementalPageReasons = {
  'supplemental_page_invalid': '附页数据无效，请检查类型、位置和文本。',
  'supplemental_page_limit': '每本书最多 20 条附页，请先删除不需要的附页。',
  'supplemental_body_too_long': '附页正文最多 2 万字，请缩短后重试；内容未被截断。',
  'supplemental_title_too_long': '附页标题须为单行，最多 200 字。',
  'supplemental_page_missing': '这条附页已不存在，请刷新列表。',
  'supplemental_page_stale': '书籍或制作设置已改变，请重新预览。',
  'supplemental_order_invalid': '附页列表已改变，请刷新后重新排序。',
  'supplemental_template_invalid': '模板名称须为单行，不能为空，最多 128 字。',
  'supplemental_template_duplicate': '已有同名模板，请换一个名称。',
  'supplemental_template_missing': '这份模板已不存在，请刷新列表。',
  'supplemental_template_stale': '软件设置已改变，请刷新模板后重试。',
  'supplemental_template_save_failed': '模板保存失败，请检查设置目录并刷新后重试。',
  'supplemental_unknown_placeholder': '未知占位符将原样保留。',
  'reduce_batch_history_size': '软件设置总量超过 4 MiB，请减少模板或输出历史。',
};

class SupplementalPageException implements Exception {
  const SupplementalPageException(this.reason);
  final String reason;
  String get message => supplementalPageReasons[reason] ?? '无法处理附页，请检查书籍和制作资源。';
  @override
  String toString() => message;
}

class SupplementalPageContent {
  SupplementalPageContent({
    required this.kind,
    SupplementalPagePosition? position,
    this.title = '',
    required this.body,
    this.includeToc = false,
  }) : position =
           position ??
           switch (kind) {
             SupplementalPageKind.afterword ||
             SupplementalPageKind.aboutAuthor => SupplementalPagePosition.back,
             SupplementalPageKind.custom => throw ArgumentError(
               '自定义附页需要指定前后位置',
             ),
             _ => SupplementalPagePosition.front,
           };
  factory SupplementalPageContent.fromJson(Map value) =>
      SupplementalPageContent(
        kind: SupplementalPageKind.values.firstWhere(
          (k) => _wireKind(k) == value['kind'],
        ),
        position: SupplementalPagePosition.values.byName(
          value['position'] as String,
        ),
        title: value['title'] as String,
        body: value['body'] as String,
        includeToc: value['include_toc'] as bool,
      );
  final SupplementalPageKind kind;
  final SupplementalPagePosition position;
  final String title, body;
  final bool includeToc;
  static String _wireKind(SupplementalPageKind kind) => switch (kind) {
    SupplementalPageKind.authorNote => 'author_note',
    SupplementalPageKind.aboutAuthor => 'about_author',
    _ => kind.name,
  };
  Map<String, Object?> toJson() => {
    'kind': _wireKind(kind),
    'position': position.name,
    'title': title,
    'body': body,
    'include_toc': includeToc,
  };
}

class SupplementalPage {
  SupplementalPage.fromJson(Map value)
    : id = value['id'] as String,
      content = SupplementalPageContent.fromJson(value['content'] as Map);
  final String id;
  final SupplementalPageContent content;
}

class SupplementalPageSnapshot {
  SupplementalPageSnapshot.fromJson(List value)
    : pages = List.unmodifiable(
        value.cast<Map>().map(SupplementalPage.fromJson),
      );
  final List<SupplementalPage> pages;

  /// 成品按前、后分组；各组保留列表内顺序。
  List<SupplementalPage> at(SupplementalPagePosition position) =>
      List.unmodifiable(pages.where((p) => p.content.position == position));
}

class SupplementalPageWarning {
  SupplementalPageWarning.fromJson(Map value)
    : reason = value['reason'] as String,
      placeholder = value['placeholder'] as String;
  final String reason, placeholder;
  String get message =>
      '$placeholder：${supplementalPageReasons[reason] ?? reason}';
}

class SupplementalPagePreview {
  const SupplementalPagePreview(this.before, this.after, this.warnings);
  final SupplementalPageSnapshot before, after;
  final List<SupplementalPageWarning> warnings;
}

class SupplementalTemplate {
  SupplementalTemplate.fromJson(Map value)
    : id = value['id'] as String,
      name = value['name'] as String,
      content = SupplementalPageContent.fromJson(value['content'] as Map);
  final String id, name;
  final SupplementalPageContent content;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'content': content.toJson(),
  };
}

class SupplementalTemplateSnapshot {
  SupplementalTemplateSnapshot(this.token, List value)
    : templates = List.unmodifiable(
        value.cast<Map>().map(SupplementalTemplate.fromJson),
      );
  final String? token;
  final List<SupplementalTemplate> templates;
}

abstract interface class SupplementalPageLibrary {
  SupplementalPageSession openSupplementalPages(String bookId);
  SupplementalTemplateService get supplementalTemplates;
}

abstract interface class SupplementalPageSession {
  Listenable get changes;
  Future<SupplementalPageSnapshot> list();
  Future<SupplementalPagePreview> previewAdd(SupplementalPageContent content);
  Future<SupplementalPagePreview> previewUpdate(
    String id,
    SupplementalPageContent content,
  );
  Future<SupplementalPagePreview> previewDelete(String id);
  Future<SupplementalPagePreview> previewReorder(List<String> ids);

  /// 拖到另一组：改为 [position] 并按 [ids]（全部现存附页）重排，一步历史。
  Future<SupplementalPagePreview> previewMove(
    String id,
    SupplementalPagePosition position,
    List<String> ids,
  );

  /// 使用预览时本书元信息和本地年份展开，确认后不再跟随元信息或模板变化。
  Future<SupplementalPagePreview> previewApplyTemplate(
    SupplementalTemplate template,
  );

  /// 与本书其他制作修改共用撤销/重做链。
  Future<SupplementalPagePreview> previewUndo();
  Future<SupplementalPagePreview> previewRedo();
  Future<void> confirm(SupplementalPagePreview preview);
  void dispose();
}

abstract interface class SupplementalTemplateService {
  Future<SupplementalTemplateSnapshot> list();
  Future<SupplementalTemplateSnapshot> save(
    SupplementalTemplateSnapshot snapshot, {
    String? id,
    required String name,
    required SupplementalPageContent content,
  });
  Future<SupplementalTemplateSnapshot> delete(
    SupplementalTemplateSnapshot snapshot,
    String id,
  );
}
