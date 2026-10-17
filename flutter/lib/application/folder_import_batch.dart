import 'library_service.dart';

FolderListing markFolderBooksHandled(
  FolderListing listing,
  Iterable<ImportOutcome> outcomes,
) {
  final handled = outcomes
      .where((result) => result.succeeded)
      .map((result) => result.path)
      .toSet();
  return FolderListing(
    List.unmodifiable(
      listing.books.map(
        (book) => FolderBook(
          book.path,
          book.bytes,
          book.alreadyImported || handled.contains(book.path),
        ),
      ),
    ),
    listing.unsupported,
    listing.complete,
    listing.message,
    resume: listing.resume,
    close: listing.close,
    failures: listing.failures,
  );
}

/// Keep the service's 128-book transaction limit independent of enumeration.
/// Results are returned even when a later chunk fails; cancellation prevents
/// a following chunk from resetting the service's cancellation flag.
Future<List<ImportOutcome>> importFolderSelection(
  LibraryService library,
  List<String> paths, {
  required bool Function() cancelled,
  bool skipExisting = true,
}) async {
  final results = <ImportOutcome>[];
  for (var start = 0; start < paths.length; start += 128) {
    if (cancelled()) break;
    final end = (start + 128).clamp(0, paths.length);
    final chunk = paths.sublist(start, end);
    try {
      final current = await library.importFiles(
        chunk,
        skipExisting: skipExisting,
      );
      results.addAll(current);
      if (current.length < chunk.length) break;
    } catch (error) {
      results.addAll(
        chunk.map((path) => ImportOutcome(path, false, '本批导入未完成：$error')),
      );
      break;
    }
  }
  return List.unmodifiable(results);
}
