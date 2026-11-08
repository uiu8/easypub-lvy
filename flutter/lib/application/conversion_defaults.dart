import 'conversion_desktop.dart';

Map<String, Object> readConversionDefaults(Map<String, dynamic> config) => {
  'output_directory': config['output_directory'] as String? ?? '',
  'output_format': config['output_format'] as String? ?? 'EPUB',
  'kindle_converter': config['kindle_converter'] as String? ?? '',
  'kfx_converter': config['kfx_converter'] as String? ?? '',
  'generate_cover': config['generate_cover'] as bool? ?? true,
  'check_before_conversion':
      config['check_before_conversion'] as bool? ?? false,
};
Future<Map<String, Object>> resolveConversionDefaults(
  Map<String, Object> raw,
  ConversionDesktop desktop, {
  String? format,
}) async {
  final resolved = Map<String, Object>.of(raw);
  if ((resolved['output_directory'] as String).trim().isEmpty &&
      desktop is OutputDirectoryDesktop) {
    resolved['output_directory'] = await (desktop as OutputDirectoryDesktop)
        .defaultOutputDirectory();
  }
  final kindling = (resolved['kindle_converter'] as String).trim().isEmpty
      ? await desktop.bundledConverter() ?? ''
      : resolved['kindle_converter'] as String;
  resolved['kindling_path'] = kindling;
  if ((format ?? resolved['output_format']) == 'KFX') {
    var path = resolved['kfx_converter'] as String? ?? '';
    if (path.trim().isEmpty && desktop is KfxConversionDesktop) {
      path =
          await (desktop as KfxConversionDesktop).bundledKfxConverter() ?? '';
    }
    resolved['kindle_converter'] = path;
    resolved['kfx_converter'] = path;
  } else {
    resolved['kindle_converter'] = kindling;
    if ((resolved['kfx_converter'] as String? ?? '').isEmpty &&
        desktop is KfxConversionDesktop) {
      resolved['kfx_converter'] =
          await (desktop as KfxConversionDesktop).bundledKfxConverter() ?? '';
    }
  }
  return resolved;
}
