import 'package:flutter/foundation.dart';

const bookInformationFields = <String, String>{
  'title': '书名',
  'author': '作者',
  'language': '语言',
  'publisher': '出版者',
  'translator': '译者',
  'isbn': 'ISBN',
  'publication_date': '出版日期',
  'category': '类别',
  'series': '系列',
  'series_index': '系列序号',
  'subjects': '主题 / 标签',
  'description': '简介',
};

class BookInformationPreview {
  BookInformationPreview(
    Map<String, Object?> before,
    Map<String, Object?> after,
    List<String> changed,
  ) : before = Map.unmodifiable(before),
      after = Map.unmodifiable(after),
      changed = List.unmodifiable(changed);
  final Map<String, Object?> before, after;
  final List<String> changed;
}

abstract class BookInformationSession {
  Future<CoverImageEvidence> inspectImage(String path);
  Future<CoverImageEvidence> storeGeneratedCover(Uint8List bytes);
  Listenable get changes;
  Map<String, Object?> get saved;

  /// 本书章节样式包里的封面背景图路径（V74b，LAY-130）；没有时为 null。
  String? get styleCoverBackground => null;
  Future<BookInformationPreview> preview(Map<String, Object?> values);
  Future<void> apply(BookInformationPreview preview);
  void dispose();
}

class CoverImageEvidence {
  const CoverImageEvidence(
    this.path,
    this.sha256,
    this.width,
    this.height,
    this.bytes,
    this.format,
  );
  final String path, sha256, format;
  final int width, height, bytes;
}
