import 'dart:convert';

import '../src/rust/api.dart' as api;

/// 只翻译结构化原因，不向用户回显引擎原始错误或请求正文。
String conversionFailureMessage(Map error) {
  final action = error['next_action'];
  return switch (action) {
    'choose_cover_before_kindling_export' => '本书缺少封面，请先选择封面再重新预览。',
    'choose_publication_language' => '本书语言未填写，请设置语言（如 zh-CN 或 en）后重新预览。',
    'choose_kindling_executable' ||
    'choose_supported_engine' => '转换器不存在或不受支持，请在设置中选择配套转换器后重试。',
    'engine_failed_review_log' => '转换器未能完成，请查看转换目录中的日志。',
    'engine_timed_out_review_log' =>
      '转换器超过执行时限，已停止本次转换。请查看日志，缩小书稿或减少同时转换的本数后重试。',
    'engine_log_limit_review_log' => '转换器日志超过大小限制，已停止本次转换。请查看日志中的重复错误并检查配套转换器。',
    'kfx_validation_failed_review_log' =>
      'KFX 与原 EPUB 的内容或排版校验未通过，未提交成品。请查看转换目录中的 validation.log。',
    'engine_metadata_mismatch' => '转换结果丢失或改变了书目信息，已停止保存。请使用配套修订版转换器后重试。',
    'review_engine_output' => '转换器生成的成品无效或超过限制，请检查转换日志并使用配套转换器重试。',
    'reopen_preview' ||
    'preview_and_confirm_export' => '书稿、资源或转换器已变化，或尚未确认预览，请重新预览并确认。',
    'reduce_export_request' => '转换请求超过大小限制，请减少本批书籍或资源后重新预览。',
    'review_export_request' => '转换参数无效，请检查格式与制作设置后重新预览。',
    'review_export_files_and_log' => '转换文件读写失败，请检查磁盘空间、目录权限及文件占用，再查看转换日志并重试。',
    'export_cancelled' => '转换已取消；如需继续，请重新预览并开始转换。',
    _ => switch (error['code'] ?? error['error']) {
      'Io' => '文件读写失败，请检查磁盘空间、目录权限或文件占用后重试。',
      'OutputConflict' => '输出位置已有文件，请选择新文件名或其他输出目录后重新预览。',
      'SourceChanged' || 'StaleRevision' => '原稿或制作状态已改变，请重新读取并预览。',
      'TooLarge' => '书稿、资源或请求超过处理上限，请减少资源或缩小本批范围后重试。',
      'NotFound' => '所需书稿或资源不存在，请重新关联文件后预览。',
      'InvalidEncoding' || 'InvalidUtf8' => '书稿编码或字符无效，请确认源文件编码后重新导入。',
      'InvalidRule' || 'UnsupportedRule' => '制作规则或转换参数不受支持，请检查设置后重新预览。',
      'Busy' => '已有任务正在处理相关文件，请等待任务完成后重试。',
      'Cancelled' => '转换已取消；如需继续，请重新预览并开始转换。',
      _ => '导出未完成，请保留转换日志，检查书稿、资源与输出目录后重新预览。',
    },
  };
}

String conversionApiErrorMessage(Object error) {
  if (error is FormatException) return error.message;
  if (error is api.ApiError) {
    try {
      return conversionFailureMessage(
        jsonDecode(api.describeApiErrorSync(error: error)) as Map,
      );
    } catch (_) {
      // 错误展示失败时仍保留安全的恢复建议。
    }
  }
  return conversionFailureMessage(const {});
}
