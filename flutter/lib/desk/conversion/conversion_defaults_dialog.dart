// 转换默认设置：一眼看出本次用什么、默认是什么、会不会变。
import 'package:flutter/material.dart';

import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';

/// 返回 'update'、'keep'、'reset'；取消时为空。
Future<String?> showConversionDefaultsDialog(
  BuildContext context, {
  required Map<String, String> labels,
  required Map<String, Object?> current,
  required Map<String, Object> defaults,
  required Set<String> manual,
  required bool pending,
}) => showDialog<String>(
  context: context,
  builder: (_) => ConversionDefaultsDialog(
    labels: labels,
    current: current,
    defaults: defaults,
    manual: manual,
    pending: pending,
  ),
);

class ConversionDefaultsDialog extends StatelessWidget {
  const ConversionDefaultsDialog({
    super.key,
    required this.labels,
    required this.current,
    required this.defaults,
    required this.manual,
    required this.pending,
  });
  final Map<String, String> labels;
  final Map<String, Object?> current;
  final Map<String, Object> defaults;
  final Set<String> manual;

  /// 默认设置刚变过，可以选择保留现在的值。
  final bool pending;

  static const _nameWidth = 116.0, _stateWidth = 84.0;

  String shown(String key, Object? value) {
    if (value is bool) return value ? '开启' : '关闭';
    if (value == null || value == '') return '未设置';
    final text = '$value';
    return key == 'kindle_converter'
        ? text.replaceAll('\\', '/').split('/').last
        : text;
  }

  (String, Tone) state(String key) => manual.contains(key)
      ? ('手工设置', Tone.info)
      : current[key] == defaults[key]
      ? ('跟随默认', Tone.neutral)
      : ('将更新', Tone.accent);

  Widget value(
    BuildContext context,
    String key,
    Object? raw, {
    bool on = false,
  }) {
    final d = context.desk;
    final text = shown(key, raw);
    return Tooltip(
      message: '${raw ?? ''}'.isEmpty ? text : '$raw',
      waitDuration: const Duration(milliseconds: 400),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ui(13, c: on ? d.ink : d.ink2, w: on ? 600 : 400),
      ),
    );
  }

  Widget row(BuildContext context, String key, String label) {
    final d = context.desk;
    final (status, tone) = state(key);
    final differs = current[key] != defaults[key];
    return Container(
      key: ValueKey(('conversion-default', key)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _nameWidth,
            child: Text(label, style: ui(13, c: d.ink)),
          ),
          Expanded(child: value(context, key, current[key], on: differs)),
          const SizedBox(width: 12),
          Expanded(child: value(context, key, defaults[key])),
          const SizedBox(width: 12),
          SizedBox(
            width: _stateWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: DeskTag(status, tone),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final updates = labels.keys.where((k) => state(k).$2 == Tone.accent).length;
    final kept = labels.keys.where(manual.contains).length;
    Widget head(String text) => Text(text, style: ui(12, w: 600, c: d.ink3));
    return DeskDialog(
      title: '默认设置',
      subtitle: [
        if (updates > 0) '$updates 项将更新为默认值',
        if (kept > 0) '$kept 项是手工设置，会保留',
        if (updates == 0 && kept == 0) '本次转换全部跟随默认设置',
      ].join('，'),
      closeTooltip: '取消',
      width: 760,
      actions: [
        DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(context)),
        if (pending)
          DeskButton(
            '保留当前设置',
            quiet: true,
            onPressed: () => Navigator.pop(context, 'keep'),
          ),
        if (manual.isNotEmpty)
          DeskButton(
            '全部跟随默认',
            quiet: true,
            onPressed: () => Navigator.pop(context, 'reset'),
          ),
        DeskButton(
          '采用默认值并重新预览',
          primary: true,
          onPressed: () => Navigator.pop(context, 'update'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: d.line),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      SizedBox(width: _nameWidth, child: head('设置')),
                      Expanded(child: head('本次转换')),
                      const SizedBox(width: 12),
                      Expanded(child: head('默认值')),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: _stateWidth,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: head('状态'),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final entry in labels.entries)
                  row(context, entry.key, entry.value),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '手工改过的设置不会被覆盖。采用默认值后要重新预览；已开始的转换任务不受影响。',
            style: ui(12, c: d.ink3, h: 1.5),
          ),
        ],
      ),
    );
  }
}
