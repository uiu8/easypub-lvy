// Default values shared by controls and project serialization.
const defaultImageOptions = <String, dynamic>{
  'max_long': 2560,
  'max_short': 1600,
  'quality': 90,
  'png_to_jpeg': false,
  'grayscale': false,
  'preserve_cover': true,
  'recompress_jpeg': false,
};
const defaultNavigationOptions = <String, dynamic>{
  'apply_to_original': false,
  'original_start': '',
  'toc_title': '目录',
  'toc_position': 'front',
  'toc_filter': '',
  'filter_regex': false,
  'start': 'chapter',
  'start_chapter': '',
};
const defaultOutputOptions = <String, dynamic>{
  'document_type': 'default',
  'epub_version': 3,
  'txt_encoding': 'utf-8',
  'txt_newline': 'preserve',
};
bool hasCustomOptions(
  Map<String, dynamic>? value,
  Map<String, dynamic> defaults,
) =>
    value != null &&
    value.entries.any(
      (e) => !defaults.containsKey(e.key) || defaults[e.key] != e.value,
    );
