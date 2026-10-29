import 'change_history_service.dart';

import 'package:flutter/foundation.dart';

import 'output_history_service.dart';

import 'cleanup_service.dart';
import 'book_information_service.dart';
import 'layout_service.dart';
import 'layout_batch_service.dart';
import 'book_batch_service.dart';
import 'conversion_service.dart';
import 'resource_service.dart';
import 'cleanup_batch_service.dart';

import 'metadata_mapping_service.dart';
import 'chapter_service.dart';
import 'catalog_service.dart';
import 'book_check_service.dart';

@immutable
class BookSelection {
  BookSelection(this.current, Set<String> selected)
    : selected = Set.unmodifiable(selected);
  final String? current;
  final Set<String> selected;
}

@immutable
class BookSummary {
  const BookSummary({
    required this.id,
    required this.title,
    required this.author,
    required this.path,
    required this.format,
    required this.chapters,
    required this.status,
    this.coverPath,
    this.coverFit = 'contain',
    this.coverCrop,
    this.coverDesign,
    this.contentVersion = '',
    this.bytes,
    this.pending,
    this.category = '',
    this.series = '',
  });

  /// 书籍信息里的类别与系列（V84，书库按类别筛选、排序用）。
  final String category, series;
  final String id, title, author, path, format, status;

  /// 最近一次检查（当前稿）的待处理数量；没有当前稿的检查报告时为 null。
  final BookPendingSummary? pending;

  /// 原文件大小（字节）；文件不可读时为 null，界面显示“—”。
  final int? bytes;
  final int chapters;
  final String contentVersion;
  final String? coverPath;
  final String coverFit;
  final Map<String, dynamic>? coverCrop, coverDesign;
}

/// 检查报告中的待处理数量，不另行推算。
@immutable
class BookPendingSummary {
  const BookPendingSummary({
    this.chapters = 0,
    this.cleanup = 0,
    this.metadata = 0,
    this.checkedAt,
  });
  final int chapters, cleanup, metadata;
  final DateTime? checkedAt;
  int get total => chapters + cleanup + metadata;

  /// 例如“章节 12 项 · 清理 3 处 · 书籍信息 1 项”。
  String get breakdown => [
    if (chapters > 0) '章节问题 $chapters 项',
    if (cleanup > 0) '清理建议 $cleanup 处',
    if (metadata > 0) '书籍信息 $metadata 项待补充',
  ].join(' · ');
}

@immutable
class ImportOutcome {
  const ImportOutcome(
    this.path,
    this.succeeded,
    this.message, {
    this.skipped = false,
    this.sourceChanged = false,
  });
  final String path, message;
  final bool succeeded;
  final bool skipped;

  /// 书库里已有这本书，来源文件的内容却变了（如书源追更后重新拼出 TXT）：草稿保留，
  /// 新内容没有采用，要用“刷新来源”对比确认（V111）。
  final bool sourceChanged;
}

@immutable
class FolderBook {
  const FolderBook(
    this.path,
    this.bytes,
    this.alreadyImported, {
    this.modified,
  });
  final String path;
  final int bytes;
  final bool alreadyImported;

  /// 文件修改时间；读不到时为 null（V84 排序用）。
  final DateTime? modified;
  String get name => path.replaceAll('\\', '/').split('/').last;

  /// 扩展名大写（TXT / EPUB），没有扩展名时为空。
  String get type {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toUpperCase();
  }
}

@immutable
class FolderListing {
  const FolderListing(
    this.books,
    this.unsupported,
    this.complete,
    this.message, {
    this.resume,
    this.close,
    this.failures = const [],
  });
  final List<FolderBook> books;
  final int unsupported;
  final bool complete;
  final Future<FolderListing> Function(bool Function())? resume;
  final void Function()? close;
  final List<String> failures;
  final String message;
}

@immutable
class ProjectOutcome {
  const ProjectOutcome(this.succeeded, this.message);
  final bool succeeded;
  final String message;
}

/// Bounded library summaries only. Source text and editable trees never enter
/// this interface. Implementations own the project's business lifecycle.
abstract class LibraryService {
  /// Library-owned shared service; pages borrow it without disposing it.
  /// The library releases subscriptions when its workspace is disposed.
  ChangeHistoryService openChangeHistory();
  OutputHistoryService openOutputHistory();
  ConversionSession openConversion();
  BookBatchSession openBookBatch(String bookId);
  LayoutBatchSession openLayoutBatch(String bookId);
  ResourceSession openResources(String bookId);
  LayoutSession openLayout(String bookId);
  BookInformationSession openBookInformation(String bookId);
  CleanupBatchSession openCleanupBatch(String bookId);
  CleanupSession openCleanup(String bookId);
  ValueListenable<BookSelection> get selection;
  void selectBook(String id);
  void checkBook(String id, bool checked);
  MappingSession openMapping();
  ChapterSession openChapters(String bookId);
  CatalogSession openCatalog(String bookId);
  BookCheckSession openChecks(String bookId);
  ValueListenable<List<BookSummary>> get books;
  ValueListenable<bool> get importing;
  ValueListenable<bool> get projectBusy;
  ValueListenable<List<String>> get favoriteFolders;
  ValueListenable<Map<String, String>> get favoriteNames;
  String favoriteName(String path);
  Future<bool> renameFavorite(String path, String name);
  Future<bool> relocateFavorite(String path, String newPath);
  Future<bool> loadFavorites();
  Future<bool> setFavorite(String path, bool favorite);
  Future<List<ImportOutcome>> importFiles(
    List<String> paths, {
    bool skipExisting = false,
  });
  Future<FolderListing> scanFolder(
    String path, {
    required bool recursive,
    required bool Function() cancelled,
  });
  Future<ProjectOutcome> saveProject(String path);
  Future<ProjectOutcome> openProject(String path);
  void cancelImport();
  void dispose();
}

/// Changes a selection as one notification without changing the current book.
abstract class LibraryRemovalService {
  /// Session-local undo stack; opening another project clears it.
  ValueListenable<int> get removedBatchCount;
  void removeBooks(Set<String> ids);
  List<RemovedBookBatch> get removedBatches;
  void undoBookRemoval({int? batchId});
}

class RemovedBookBatch {
  const RemovedBookBatch(this.id, this.titles);
  final int id;
  final List<String> titles;
}

class LibraryRemovalBlocked implements Exception {
  const LibraryRemovalBlocked(this.message, {this.openTasks = false});
  final String message;
  final bool openTasks;
}

abstract class LibraryBulkSelection {
  void checkBooks(Iterable<String> ids, bool checked);
}

abstract class BookStatisticsService {
  Future<Map<String, dynamic>> statistics(String bookId);
}

abstract class BookOverviewService {
  Future<Map<String, dynamic>> overview(String bookId);
}

abstract class BookFilePicker {
  Future<List<String>> chooseBooks();
  Future<String?> chooseFolder();
  Future<String?> chooseProject();
  Future<String?> chooseProjectDestination();
}
