import 'book_information_service.dart';
import 'chapter_service.dart';

class ResourceParagraph {
  const ResourceParagraph(this.text, this.originalLine, this.offset);
  final String text;
  final int? originalLine;
  final int offset;
}

class ResourceParagraphPage {
  const ResourceParagraphPage(this.rows, this.offset, this.total);
  final List<ResourceParagraph> rows;
  final int offset, total;
}

abstract interface class ResourcePlacementSession {
  Future<List<ChapterNode>> placementChapters();
  Future<ResourceParagraphPage> placementParagraphs(String nodeId, int offset);
}

/// 插图版式（V54，RES-050）：值与 Rust `ILLUSTRATION_LAYOUTS` 一一对应。
const illustrationLayouts = {
  'inline': '随正文',
  'full_page': '整页',
  'chapter_head': '章首图',
};

class BookResource {
  const BookResource({
    required this.index,
    required this.path,
    required this.caption,
    required this.alt,
    required this.sourceLine,
    this.image,
    this.error = '',
    this.kind = 'image',
    this.usage,
    this.status,
    this.byteLength,
    this.alreadyIllustrated = false,
    this.layout = 'inline',
  });

  /// 插图版式（V54，RES-050），见 [illustrationLayouts]。
  final String layout;

  /// -1 denotes the cover; nonnegative values address illustrations.
  /// Values below -1 identify read-only inventory entries within one scan.
  final int index;
  final String path, caption, alt, error;
  final int? sourceLine;
  final CoverImageEvidence? image;
  final String kind;
  final String? usage, status;
  final int? byteLength;
  final bool alreadyIllustrated;
  bool get editable => kind == 'image';
  String get name => path.replaceAll('\\', '/').split('/').last;
  String get location =>
      usage ??
      (index == -1
          ? '封面'
          : sourceLine == null
          ? '未定位插图'
          : '原稿第 $sourceLine 行之后');
}

abstract class ResourceSession {
  Future<Map<int, CoverImageEvidence?>> inspectRelink(Map<int, String> paths);
  Future<BookInformationPreview> relink(Map<int, String> replacements);
  Future<ResourceLocation> locate(int index);
  Future<List<BookResource>> read();
  Future<BookInformationPreview> change({
    required int? index,
    required String? path,
    String caption = '',
    String alt = '',
    int? sourceLine,
    String layout = 'inline',
  });
  Future<void> apply(BookInformationPreview plan);
  void dispose();
}

class ResourceLocation {
  const ResourceLocation(
    this.nodeId,
    this.nodeOffset,
    this.heading,
    this.message, {
    this.outputLine,
  });
  final String? nodeId;
  final int? nodeOffset;
  final String heading, message;

  /// 插在成品文本第几行之后；未定位或需要重新定位时为空（R5-01）。
  final int? outputLine;
}

/// 一次读出全部插图的位置（R5-01、R5-05）：排版预览按它放图，资源页按它写章节与段落。
abstract interface class ResourceLocator {
  Future<List<ResourceLocation>> locateAll();
}
