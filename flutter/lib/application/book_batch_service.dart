import 'book_information_service.dart';
import 'cleanup_batch_service.dart';

import 'package:flutter/foundation.dart';

class BookBatchPreview {
  BookBatchPreview(
    Map<String, BookInformationPreview> production,
    this.cleanup, {
    Map<String, String> errors = const {},
    this.batchError = '',
  }) : production = Map.unmodifiable(production),
       errors = Map.unmodifiable(errors);
  final Map<String, BookInformationPreview> production;
  final CleanupBatchPreview? cleanup;
  final Map<String, String> errors;
  final String batchError;
  bool get ready =>
      errors.isEmpty &&
      batchError.isEmpty &&
      (production.isNotEmpty || cleanup != null) &&
      (cleanup?.ready ?? true);
}

abstract class BookBatchSession {
  Listenable get changes;
  bool canRead(BookBatchPreview plan, String bookId);
  Future<BookBatchPreview> preview(
    Set<String> fields,
    List<String> targets, {
    required bool cleanup,
    required bool append,
  });
  Future<CleanupBatchDifferencePage> differences(
    BookBatchPreview plan,
    String bookId, {
    int offset = 0,
  });
  Future<void> apply(BookBatchPreview plan);
  void dispose();
}
