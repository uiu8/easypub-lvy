abstract interface class ChapterRulesService {
  ChapterRulesSession openRules(String? bookId);
}

abstract class ChapterRulesSession {
  bool get hasBook;
  Future<Map<String, dynamic>> load();
  Future<Map<String, dynamic>> builtin();

  /// 内置规则的只读说明（CH-248）：识别形式、排除项、参考正则与数字标题正则。
  Future<Map<String, dynamic>> builtinDescription();
  Future<Map<String, dynamic>> sample(Map<String, dynamic> rules, String text);
  Future<ChapterRulesPreview> preview(
    Map<String, dynamic> rules, {
    required bool preserveDecisions,
  });
  Future<void> apply(ChapterRulesPreview preview);
  Future<void> saveDefault(Map<String, dynamic> rules);
  Future<void> savePresets(List<Map<String, dynamic>> presets);
  void saveDraft(Map<String, dynamic>? draft);
}

class ChapterRulesPreview {
  const ChapterRulesPreview(this.data);
  final Map<String, dynamic> data;
}
