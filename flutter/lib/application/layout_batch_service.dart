import 'book_information_service.dart';

class LayoutBatchPreview {
  LayoutBatchPreview(Map<String, BookInformationPreview> items)
    : items = Map.unmodifiable(items);
  final Map<String, BookInformationPreview> items;
}

abstract class LayoutBatchSession {
  Map<String, Object?> get source;
  Future<LayoutBatchPreview> preview(Set<String> fields, List<String> targets);
  Future<void> apply(LayoutBatchPreview preview);
  void dispose();
}
