/// Resolve missing metadata without overriding a book's explicit language.
String resolveOutputLanguage({
  String? override,
  String? book,
  String? fallback,
}) {
  for (final value in [override, book, fallback, 'zh-CN']) {
    final language = value?.trim() ?? '';
    if (language.isNotEmpty && language.toLowerCase() != 'und') return language;
  }
  return 'zh-CN';
}
