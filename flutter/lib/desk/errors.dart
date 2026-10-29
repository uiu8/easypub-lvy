// 错误原因对照表（V15，G-065）：把后端返回的 next_action 换成“发生了什么、接下来怎么做”。
// 所有页面在 catch 里用 deskErrorText(e, 兜底说明)，不再只显示“失败，请重试”。
// 对照表里没有的后端错误，在兜底说明后附上错误代码，便于反馈定位。
import 'dart:convert';
import 'dart:io';

import '../src/rust/api.dart' as api;
import '../application/book_source_errors.dart';
import '../application/plugin_host.dart' show PluginError;

const _reasons = <String, String>{
  ...bookSourceErrorReasons,
  // 书稿与来源
  'import_source': '书稿还没有导入完成。请先导入，或重新选择文件。',
  'reimport_source': '原文件已变化或不可读。请重新导入这本书。',
  'reimport_changed_source': '原文件在导入后被修改过。请重新导入，或在概览里刷新来源。',
  'reload_source': '书稿需要重新读取。请回到书库重新打开这本书。',
  'refresh_source': '书稿版本已变化。请刷新后重试。',
  'refresh_book': '这本书已变化。请回到书库重新打开。',
  'inspect_source': '原文件读取失败。请检查文件是否还在、是否被其他程序占用。',
  'choose_readable_file': '文件读不到。请检查文件是否存在、是否有读取权限。',
  'check_path_permissions': '没有访问这个位置的权限。请换一个文件夹，或检查文件夹权限。',
  'reduce_source_size': '书稿太大，超过了处理上限。请拆分后再导入。',
  'retry_import': '导入没有完成。请重试；仍失败时检查文件编码与权限。',
  // 预览与版本
  'refresh_page': '页面数据已过期。请刷新后重试。',
  'refresh_composition': '书稿组合已变化。请重新打开当前页面。',
  'refresh_effective_tree': '章节结构已变化。请重新读取目录后再操作。',
  'refresh_candidates': '候选已过期。请重新生成预览。',
  'reopen_preview': '预览已过期。请关闭后重新预览。',
  'preview_current_targets_again': '目标已变化。请重新预览全部目标后再确认。',
  'preview_and_confirm_all_targets': '还有目标没有预览确认。请逐个预览并确认后再应用。',
  'use_returned_cursor': '翻页位置已过期。请回到第一页重新浏览。',
  'use_composition_or_edits': '内部请求组合不正确。请重新打开页面后再试。',
  // 章节与结构
  'review_effective_nodes_and_base':
      '章节修改所依据的书稿已经变化（例如先后改动了清理或识别规则）。请在变更记录中按顺序撤销后再操作。',
  'review_effective_history': '章节编辑历史与当前书稿不一致。请在变更记录中查看并撤销最近的修改。',
  'review_structure_history': '结构历史与当前书稿不一致。请撤销最近的结构修改后再试。',
  'review_structure_settings': '章节结构设置无效。请恢复默认识别规则后重试。',
  'review_levels_and_source_lines': '标题层级或行号无效。请重新选择标题位置。',
  'review_line_boundaries': '所选行不在这一章的正文范围内。请重新选择。',
  'select_body_node': '请先在左侧选择一个章节。',
  'choose_previous_sibling_of_same_role': '只能与前面同级的章节合并。请换一个目标。',
  'choose_target_outside_subtree': '不能移动到它自己的下级里。请换一个目标位置。',
  'choose_disjoint_target_with_valid_depth': '目标位置的层级不合适。请选择同级或上一级的位置。',
  'choose_position_in_own_source': '只能在本书的原文范围内选择位置。',
  'confirm_volume_line_and_title': '请确认卷标题所在的行和卷名后再插入。',
  'use_set_volume_action': '这一步应使用“插入卷”。请改用卷操作。',
  'recheck_duplicate_heading_evidence': '重复标题的依据已变化。请重新检查后再处理。',
  'add_number_and_title_groups': '规则需要同时包含章节编号和标题部分。请补全后再试。',
  'reduce_edit_batch': '一次修改的内容太多，超过了处理上限。请先生成编辑检查点，或分几批修改。',
  'restore_edit_checkpoint': '编辑检查点读取失败。请检查项目目录是否完整。',
  'check_checkpoint_directory': '检查点所在的文件夹不可用。请检查磁盘空间与权限。',
  'reduce_checkpoint_size': '检查点太大。请分批保存。',
  'rebase_checkpoint': '章节修改经过多次压缩，原始操作不完整，无法换算到新的文本。可在变更记录中撤销到压缩之前再试。',
  'restore_edit_evidence': '修改记录不完整。请重新打开项目。',
  // 修复
  'confirm_repair_before_commit': '修复方案还没有确认。请先核对差异并确认。',
  'confirm_only_safe_actions': '方案里含有需要人工判断的修改。请逐项核对后再应用。',
  'confirm_known_actions': '方案里含有无法识别的修改。请重新生成方案。',
  'choose_next_repair_revision': '修复方案已被更新。请重新预览后确认。',
  'choose_previous_repair_revision': '没有可以返回的上一版方案。',
  'reopen_repair_session': '修复会话已过期。请重新打开修复方案。',
  'review_repair_copy': '修复副本与书稿不一致。请重新生成。',
  'select_known_findings': '所选问题已不存在。请重新检查后再选。',
  'review_current_findings': '问题列表已变化。请重新检查。',
  'review_or_positions': '请求的内容有冲突。请重新打开检查页。',
  'review_batch_limit': '一次处理的条目太多（上限 1000）。请分批处理。',
  'retry_check': '检查没有完成。请重试。',
  'review_navigation': '目录导航数据无效。请重新检查。',
  'review_projection': '书稿映射无效。请重新打开这本书。',
  // 目录
  'review_catalog_manual_coordinates': '手动对应的目录位置无效。请重新选择对应行。',
  // 清理
  'review_cleanup': '清理设置无效。请检查规则后重新检测。',
  'review_cleanup_request': '清理请求无效。请重新检测。',
  'review_cleanup_rule': '有一条清理规则写法不对。请检查正则表达式或参数。',
  'review_cleanup_rules_and_lines': '清理规则或所选行无效。请重新检测。',
  'review_cleanup_preset': '清理预设无效。请重新选择预设。',
  'review_cleanup_settings_history': '清理历史与当前书稿不一致。请撤销最近的清理设置后再试。',
  'reduce_cleanup_scope_or_expansion': '清理改动过多或替换结果过长。请缩小清理范围，或调整替换规则。',
  'cleanup_would_remove_structural_heading':
      '这次清理会删除章节标题所在的行。请保留该行，或调整规则后重新检测。',
  'clear_conflicting_notice_selections': '所选的提示候选互相冲突。请清空选择后重新勾选。',
  'keep_notice_rule_or_clear_target_selection': '去掉规则前请先清空依赖它的候选选择。',
  'reselect_step_difference': '逐步骤差异已变化。请重新选择要保留的修改。',
  'choose_supported_regex_or_compatibility_engine':
      '这条正则表达式不受支持（例如用了环视）。请改写规则。',
  'select_explicit_rule': '请明确选择一条规则后再操作。',
  'edit_rule': '规则写法有误。请编辑后重试。',
  'restore_rule_directory_or_explicitly_remove_rule':
      '规则依赖的目录不存在。请恢复目录，或删除这条规则。',
  'review_dictionary_version': '简繁词典版本不匹配。请重新选择简繁转换规则。',
  'check_dictionary_installation': '简繁词典缺失。请检查程序是否完整。',
  // 书籍信息、排版、资源
  'review_production_fields':
      '书籍信息或插图设置无效：插入位置须在原稿范围内，替代文本和图注不能换行，同一张图片不能引用两次。',
  'choose_publication_language': '请先选择书籍语言。',
  'choose_readable_supported_image':
      '图片读不到：文件可能已损坏，或格式不是 PNG、JPG、WebP、GIF、BMP。',
  'reduce_image_dimensions_or_size':
      '图片太大：文件须小于 32 MB，长边不超过 16384 像素，总像素不超过 1600 万。',
  'choose_cover_before_kindling_export': '这个格式需要封面。请设置封面，或开启“缺封面时生成文字封面”。',
  'locate_original_epub': '找不到原 EPUB 文件（可能已移动或删除）。请把它放回原处，或改用“使用软件排版”。',
  'choose_original_epub': '原稿不是 EPUB，不能保持原格式；请改用“使用软件排版”。',
  'review_cover_recipe_and_crop_before_restoring': '封面设置或裁切记录无效。请重新设置封面。',
  'choose_valid_font_and_face': '字体文件无效或不受支持。请换一个字体。',
  'review_layout_layers': '排版设置的来源冲突。请在“设置来源 / 恢复默认”中检查。',
  'review_margin_value_and_unit': '边距的数值或单位无效。请检查边距设置。',
  'review_preset_file': '预设文件读不到或格式不对。请换一个文件。',
  'review_preset_name_and_layout_fields': '预设名称或排版字段无效。请检查后再保存。',
  'review_saved_layout_origins': '保存的排版来源记录无效。请恢复默认后重试。',
  'review_css_project_resources': '附加 CSS 引用的资源缺失。请检查 CSS 资源。',
  'restore_complete_css_bundle': 'CSS 资源包不完整。请重新导入 CSS。',
  // 转换与输出
  'review_publication_and_output': '成品设置有误。请检查格式、书籍信息与输出位置。',
  'review_publication_structure': '成品的章节结构无效。请先在检查页处理章节问题。',
  'review_final_structure_and_xml_text': '成品中有无法写入的文字或结构。请检查章节标题与正文中的特殊字符。',
  'review_final_book_resources': '成品引用的图片或资源缺失。请在“图片与资源”中检查。',
  'review_composition': '书稿组合请求无效。请重新打开页面后再试。',
  'choose_writable_output': '输出位置不可写。请换一个文件夹。',
  'choose_new_output_path': '同名成品已存在。请换一个文件名或输出位置。',
  'choose_new_writable_path': '目标文件已存在或不可写。请换一个位置。',
  'choose_supported_mode': '这种输出方式不受支持。请换一个格式。',
  'inspect_output': '成品文件校验未通过。请查看任务详情。',
  'inspect_staged_output': '临时成品校验未通过。请查看任务详情后重试。',
  'inspect_output_history': '转换记录读取失败。请检查输出记录文件夹。',
  'check_output_history_directory': '转换记录所在的文件夹不可用。请检查磁盘空间与权限。',
  'inspect_transaction': '上次写入没有完成。请在任务页查看并恢复。',
  'inspect_transaction_manifest': '写入记录不完整。请在任务页查看并恢复。',
  'recover_transaction': '有未完成的写入需要恢复。请在任务页恢复后再试。',
  'engine_metadata_mismatch': '转换器版本与记录不一致。请重新安装程序或重新转换。',
  'retry_export': '导出没有完成。请重试；仍失败时查看任务详情。',
  'retry_job': '任务没有完成。请重试。',
  'refresh_jobs': '任务列表已变化。请刷新后再操作。',
  'wait_for_current_job': '当前还有任务在进行。请等它完成后再试。',
  'retry_after_owner_stops': '另一个窗口或任务正在使用这个文件。请等它结束后再试。',
  'reduce_batch_size': '一次处理的书太多。请分批处理。',
  'review_batch_targets_and_rules': '批量目标或规则有误。请重新选择目标后预览。',
  // 项目与设置
  'choose_new_project_path': '项目文件已存在。请换一个文件名。',
  'choose_supported_project': '这个项目文件格式不受支持，或已损坏。',
  'reduce_project_size': '项目太大。请移除部分书稿后再保存。',
  'restore_project_checkpoints': '项目里的检查点缺失。请检查项目文件夹是否完整。',
  'reduce_history': '编辑历史太长。请先保存检查点。',
  'review_manual_draft': '人工编辑草稿无效。请撤销最近的人工编辑。',
  'review_legacy_configuration': '旧版配置文件格式不对。请换一个配置文件。',
  'select_default_fields': '请至少选择一项要恢复的设置。',
  'review_unique_existing_folders_and_fields': '映射里有重复或不存在的文件夹。请检查后再保存。',
  'save_project_and_restart': '请先保存项目，然后重新启动程序。',
  'restart_application': '请重新启动程序后再试。',
  'use_action_object': '内部请求格式不对。请重新打开页面。',
  'use_supported_action': '这个操作不受支持。请换一种方式。',
  // 自动更新（V68）。
  'update_network': '连不上 GitHub。请检查网络，或稍后再试；也可以到发布页手动下载。',
  'update_not_found': '发布页上没有找到更新信息。请稍后再试，或到发布页手动下载。',
  'update_signature_invalid': '更新信息的签名不对，已拒绝。请到发布页手动下载，或向作者反馈。',
  'update_manifest_invalid': '更新信息的格式不对，已拒绝。请到发布页手动下载。',
  'update_source_invalid': '更新地址不受信任，已拒绝。',
  'update_check_first': '请先重新检查更新。',
  'update_busy': '正在下载更新，请等它完成或先取消。',
  'update_download_failed': '下载没有完成。请检查网络后重试。',
  'update_checksum_mismatch': '下载的文件与发布信息不一致，已丢弃。请重试。',
  'update_package_invalid': '发布包里的文件没有通过核对，已丢弃，没有替换任何文件。',
  'update_disk_write_failed': '写入下载文件失败。请检查磁盘空间后重试。',
  'update_app_dir_not_writable': '程序目录不能写入，无法自动更新。请把程序解压到自己的文件夹，或到发布页手动下载。',
  'update_not_packaged': '开发版本不能自动更新。',
  'update_not_ready': '还没有下载好的新版本。',
  'update_no_backup': '没有可以回退的上一版。',
  'update_updater_missing': '程序目录里缺少更新程序，无法自动更新。请到发布页手动下载新版本。',
  'update_launch_failed': '无法启动更新程序。请稍后重试，或到发布页手动下载。',
  'update_replace_failed': '替换文件失败',
  'update_staging_invalid': '下载的新版本不完整',
  'update_staging_missing': '下载的新版本不见了',
  // R9：后端已有、界面原来没有中文说明的原因码。
  'update_action_invalid': '更新请求不完整。请关闭本窗口后重新检查更新。',
  'update_cancelled': '已取消更新，没有替换任何文件。',
  'update_job_missing': '找不到这次更新任务，可能已经结束。请重新检查更新。',
  'update_mode_invalid': '更新方式不可用。请重新检查更新，或到发布页手动下载。',
  // 设置
  'archive_settings_history': '设置的历史版本已到上限，暂时不能再保存设置。请把设置目录备份后反馈，等后续版本自动整理。',
  'inspect_settings_history': '设置历史文件不完整或被改动过。请先备份设置目录，再在“设置 · 数据与迁移”里从备份恢复。',
  'reload_settings_before_saving': '设置已在别处更新。请重新打开设置页，再改一次。',
  'reduce_settings_size': '设置文件太大，超过了上限。请减少收藏文件夹、自定义规则等内容后再保存。',
  'reduce_batch_history_size': '批量转换的记录太多。请清理较早的转换记录后再试。',
  'check_settings_directory': '设置目录读写失败。请检查磁盘空间、文件夹权限，或是否被其他程序占用。',
  'check_auto_import_folders': '自动入库的文件夹设置不正确。请在文件夹页重新选择。',
  'check_backup_directory': '备份文件夹不可用。请重新选择一个可以写入的文件夹。',
  'check_epub_conversion_mode': 'EPUB 转换方式的取值不正确。请在设置里重新选择。',
  'check_favorite_folder_names': '收藏文件夹的名称有重复或为空。请改名后再保存。',
  'check_favorite_folders': '收藏文件夹里有无效的路径。请移除后再保存。',
  'check_import_directory': '默认导入位置不可用。请重新选择。',
  'check_kfx_converter': 'KFX 转换工具的路径不可用。请在“设置 · 转换工具”里重新指定。',
  'check_kindle_converter': 'AZW3 / MOBI 转换工具的路径不可用。请在“设置 · 转换工具”里重新指定。',
  'check_output_collision_policy': '同名成品的处理方式取值不正确。请在设置里重新选择。',
  'check_output_directory': '默认输出文件夹不可用。请重新选择一个可以写入的文件夹。',
  'check_output_format': '默认输出格式取值不正确。请在设置里重新选择。',
  'check_output_naming': '成品命名规则不正确。请在设置里重新填写。',
  'check_parallel_books': '“同时处理的书”取值不正确。请在设置里重新选择。',
  'check_ui_density': '界面密度取值不正确。请在设置里重新选择。',
  'check_ui_scale': '界面缩放取值不正确。请在设置里重新选择。',
  'check_ui_theme': '主题取值不正确。请在设置里重新选择。',
  // 编码与导入
  'choose_complete_utf16_file': '文件按 UTF-16 读取时末尾不完整，可能被截断了。请换一份完整的文件。',
  'choose_complete_utf32_file': '文件按 UTF-32 读取时末尾不完整，可能被截断了。请换一份完整的文件。',
  'choose_valid_utf16_file': '文件不是有效的 UTF-16 文本。请在导入时改选其他编码，或选“自动”。',
  'choose_valid_utf32_file': '文件不是有效的 UTF-32 文本。请在导入时改选其他编码，或选“自动”。',
  'choose_valid_utf8_or_auto': '文件不是有效的 UTF-8 文本。请在导入时改选其他编码，或选“自动”。',
  'remove_bom_or_choose_utf8': '文件开头的编码标记与所选编码不一致。请选 UTF-8，或去掉文件开头的标记后再导入。',
  'choose_file_under_128_mib': '文件超过 128 MB，超出处理上限。请拆分后再导入。',
  'reduce_epub_entry_count': 'EPUB 里的文件太多，超出处理上限。请换一份 EPUB，或先用其他工具整理。',
  'reduce_epub_file_size': 'EPUB 太大，超出处理上限。请换一份较小的 EPUB。',
  'use_1_to_200_items': '一次读取的条数超出范围。请刷新页面后重试。',
  'use_1_to_200_lines': '一次读取的行数超出范围。请刷新页面后重试。',
  // 转换
  'choose_existing_output_directory': '输出文件夹不存在。请重新选择输出位置。',
  'choose_new_epub_path': '输出位置已有同名文件。请换一个文件名，或在设置里选择同名成品的处理方式。',
  'choose_readable_source': '原文件读不到。请检查文件是否还在、是否被其他程序占用。',
  'retry_source_read': '读取原文件时出错。请检查文件是否被其他程序占用，然后重试。',
  'retry_preview': '生成预览时出错。请重试；仍不行时检查磁盘空间。',
  'review_preview': '预览请求不完整。请关闭预览后重新打开。',
  'review_export_log': '转换过程中出现意外错误，已停止。请查看转换记录后重试。',
  'retry_export_worker': '无法启动转换任务。请稍后重试；电脑繁忙时可减少“同时处理的书”。',
  'refresh_export_jobs': '找不到这个转换任务，可能已经结束。请刷新任务页。',
  'wait_for_export_or_release_finished_jobs': '同时进行的转换太多。请等当前任务完成后再开始。',
  'wait_for_export_to_finish': '转换还没有结束。请等它完成后再查看结果。',
  // 统计与样式
  'request_statistics_again': '统计已取消。需要时请重新统计。',
  'review_collection_names_members_and_fields': '收藏夹的名称、书目或预设信息有误。请检查后再保存。',
  'review_layout_settings': '排版设置里有不支持的取值。请检查刚改动的样式后再保存。',
  'review_style_pack': '样式包内容不完整或格式不对。请换一个样式包，或重新导出后再导入。',
};

/// 把异常换成给用户看的说明。[fallback] 写“哪一步没有完成”，在没有更具体原因时使用。
String deskErrorText(Object error, String fallback) {
  if (error is PluginError) {
    final msg = error.message.trim();
    if (msg.isEmpty) return fallback;
    return _reasons[msg] ?? msg;
  }
  if (error is FormatException) return error.message.toString();
  if (error is api.ApiError) {
    try {
      final detail = jsonDecode(api.describeApiErrorSync(error: error)) as Map;
      final action = detail['next_action'] as String? ?? '';
      return _reasons[action] ??
          '$fallback（错误代码：${detail['operation']} / $action）';
    } catch (_) {
      return fallback;
    }
  }
  if (error is FileSystemException) {
    final os = error.osError?.message;
    return os == null || os.isEmpty ? fallback : '$fallback（系统提示：$os）';
  }
  return fallback;
}

/// 书源插件错误转译（V105，P0-04）：将 PluginError、Rust 原因码或底层异常转为可读说明，
/// 剥离 Exception/AnyhowException 等技术前缀，不吞掉插件已给出的中文原因。
String bookSourceErrorText(Object error, [String fallback = '书源操作未完成，请重试。']) {
  if (error is PluginError ||
      error is FormatException ||
      error is api.ApiError ||
      error is FileSystemException) {
    return deskErrorText(error, fallback);
  }
  var raw = '$error'.trim();
  if (raw.startsWith('Exception:')) {
    raw = raw.substring('Exception:'.length).trim();
  } else if (raw.startsWith('AnyhowException(') && raw.endsWith(')')) {
    raw = raw.substring('AnyhowException('.length, raw.length - 1).trim();
  }
  if (raw.isEmpty) return fallback;
  return _reasons[raw] ?? raw;
}

/// 结构化深比较（V105，P0-05）：在内存中递归比对 Map/List/Set 与基本类型，避免高频 jsonEncode。
bool deskDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) ||
          !deskDeepEquals(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deskDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
  return a == b;
}

/// 对照表中的说明（测试与文档用）。
String? deskErrorReason(String nextAction) => _reasons[nextAction];
