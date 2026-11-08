import 'chapter_service.dart';

class CatalogSearchResult {
  const CatalogSearchResult(this.id, this.title, this.url);
  final String id, title, url;
}

/// V44：本机书源配置。supported 仅表示规则可执行，不代表站点已联网验收。
class BookSourceInfo {
  const BookSourceInfo({
    required this.id,
    required this.name,
    required this.url,
    required this.group,
    required this.supported,
    required this.reasonCode,
    required this.reason,
  });
  final String id, name, url, group, reasonCode, reason;
  final bool supported;
}

class BookSourceSearchResult extends CatalogSearchResult {
  const BookSourceSearchResult(
    super.id,
    super.title,
    super.url, {
    required this.sourceId,
    required this.author,
    required this.lastChapter,
  });
  final String sourceId, author, lastChapter;
}

/// 与 CatalogSession 共用取消、候选、确认和预览生命周期；不保存书源凭据。
abstract class BookSourceSession {
  Future<List<BookSourceInfo>> listBookSources();
  Future<List<BookSourceInfo>> importBookSources(String path);
  Future<void> clearBookSources();
  Future<List<BookSourceSearchResult>> searchBookSource(
    String sourceId,
    String query,
  );
  Future<CatalogSnapshot> acquireBookSource(
    BookSourceSearchResult book, {
    bool useCache = true,
  });
}

class CatalogDuplicateSegment {
  const CatalogDuplicateSegment(
    this.originalStart,
    this.start,
    this.length,
    this.firstTitle,
    this.lastTitle,
  );
  final int originalStart, start, length;
  final String firstTitle, lastTitle;
}

class CatalogEntry {
  const CatalogEntry(this.title, this.volume, this.structural);
  final String title, volume;
  final bool structural;
}

class CatalogSnapshot {
  const CatalogSnapshot(
    this.title,
    this.author,
    this.origin,
    this.completeness,
    this.entries, {
    this.duplicateSegments = const [],
    this.fromCache = false,
    this.cacheStale = false,
  });
  final String title, author, origin, completeness;
  final bool fromCache, cacheStale;
  final List<CatalogEntry> entries;
  final List<CatalogDuplicateSegment> duplicateSegments;
}

abstract class CatalogSession {
  Future<List<CatalogSearchResult>> search(String query, {String cookie = ''});
  Future<CatalogSnapshot> removeDuplicateSegments(
    CatalogSnapshot candidate,
    Set<int> starts,
  );
  Future<CatalogRepairDraft> prepareRepair(
    CatalogAlignment alignment, {
    Set<String>? selectedIds,
  });
  Future<ChapterPage> composition(
    CatalogAlignment alignment,
    int offset, {
    required bool withCatalog,
    String? nodeId,
    int bodyOffset = 0,
  });
  Future<String> evidence(CatalogAlignment alignment, CatalogAlignmentRow row);
  Future<CatalogAlignment> choose(
    CatalogAlignment previous,
    int line,
    String? entryId,
  );
  Future<CatalogAlignment> preview(
    CatalogSnapshot snapshot, {
    required bool identityConfirmed,
    bool reorder = false,
  });
  CatalogSnapshot? get saved;
  Future<CatalogSnapshot> acquire(
    String source,
    String input, {
    String cookie = '',
    int? declaredTotal,
    bool useCache = true,
  });
  void accept(CatalogSnapshot candidate);
  void cancel();
}

class CatalogRepairDraft {
  const CatalogRepairDraft(this.session, this.before, this.preview);
  final ChapterSession session;
  final ChapterPage before;
  final ChapterEditPreview preview;
}

class CatalogAlignmentRow {
  const CatalogAlignmentRow(
    this.localTitle,
    this.referenceTitle,
    this.line,
    this.status, {
    this.candidates = const [],
    this.chosenId,
  });
  final String localTitle, referenceTitle, status;
  final int? line;
  final List<CatalogChoice> candidates;
  final String? chosenId;
}

class CatalogChoice {
  const CatalogChoice(this.id, this.title, this.volume);
  final String id, title, volume;
}

class CatalogAlignment {
  const CatalogAlignment(
    this.rows,
    this.matched,
    this.unresolved,
    this.proposedEdits, {
    this.reorder = false,
    this.relocatedChapters = 0,
    this.changes = const [],
  });
  final List<CatalogAlignmentRow> rows;
  final int matched, unresolved, proposedEdits;
  final bool reorder;
  final int relocatedChapters;
  final List<ChapterRepairChange> changes;
}

/// Local credentials are independent of book/project state and never read back as text.
abstract class CatalogCredentialSession {
  bool get useSavedCredential;
  set useSavedCredential(bool value);
  Future<bool> credentialSaved();
  Future<void> saveCredential(String value);
  Future<void> clearCredential();
}
