import 'dart:convert';

import '../src/rust/api.dart' as api;

Future<String> cleanupErrorMessage(Object error, String fallback) async {
  if (error is FormatException) return error.message;
  if (error is! api.ApiError) return fallback;
  try {
    final detail = jsonDecode(await api.describeApiError(error: error)) as Map;
    if (detail['operation'] == 'cleanup_preserve_conflict') {
      return '已选排除行包含结构标题或命中保留条件。请清空排除选择后重新预览，再勾选可排除的候选；原稿和原设置未更改。';
    }
    if (detail['operation'] == 'cleanup_step_exclusion_conflict') {
      return '某条逐步骤排除对应的原文行已被结构编辑移除或移动，不能静默套用。请在当前组合预览中重新选择该差异；原稿和原设置未更改。';
    }
    if (detail['operation'] == 'chinese_variant_dictionary') {
      return '本版本无法使用设置中的简繁词典。请检查程序是否完整，或重新选择简繁转换规则并预览；原稿和原设置未更改。';
    }
    if (detail['error'] == 'InvalidEncoding') {
      return '转换结果含有原稿编码无法表示的字符，不能无损保存。请跳过对应源行或调整规则；原稿和原设置未更改。';
    }
    if (detail['error'] == 'TooLarge') {
      return '规则计算超过上限。请缩小源行范围或减少规则；简繁、广告匹配、编号和中文标点每行上限为 64 KiB。';
    }
  } catch (_) {
    // Error reporting must never replace the original failure with another one.
  }
  return fallback;
}
