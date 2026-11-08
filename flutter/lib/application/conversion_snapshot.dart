import 'dart:convert';

import 'package:crypto/crypto.dart';

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList();
  return value;
}

/// Stable content identity, excluding transient UI selection and map key order.
String publicationFingerprint(Map<String, dynamic> request) =>
    sha256.convert(utf8.encode(jsonEncode(_ordered(request)))).toString();

/// Apply output-only choices without changing the manuscript or its history.
/// Frozen retry settings retain their original provenance when values match.
Map<String, dynamic> conversionSettings(
  Map base,
  Map<String, dynamic>? overrides,
) {
  final result = <String, dynamic>{
    ...base.cast<String, dynamic>(),
    ...?overrides,
  };
  final origins = result['metadata_origins'];
  if (origins is Map) {
    result['metadata_origins'] = {
      for (final entry in origins.entries)
        entry.key:
            jsonEncode(_ordered((entry.value as Map)['value'])) ==
                jsonEncode(_ordered(result[entry.key]))
            ? Map<String, dynamic>.from(entry.value as Map)
            : {'source': 'conversion', 'value': result[entry.key]},
    };
  }
  return result;
}
