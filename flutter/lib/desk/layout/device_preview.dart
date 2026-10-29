// 排版预览的机型与分页（LAY-092/093）：机型表沿用原版 EasyPub-Modern 的 KindleDeviceProfiles
// （分辨率、PPI 与 CSS 视口）；书页按所选机型的视口宽高比排版并近似分页。只用于示意，以真机为准。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../application/layout_service.dart'
    show
        isSceneBreak,
        isSystemLine,
        isVerseAttribution,
        isVerseLine,
        sceneBreakText;
import 'system_block_look.dart';

class KindleDevice {
  const KindleDevice(
    this.id,
    this.name,
    this.width,
    this.height,
    this.ppi,
    this.viewportWidth,
    this.viewportHeight, {
    required this.bodyWidthMm,
    required this.bodyHeightMm,
    this.grip = false,
    this.gripLeft = false,
    this.topBezelMm = 10,
    this.cornerMm = 6,
    this.logo = '',
    this.pressMarks = false,
  });
  final String id, name;
  final int width, height, ppi;

  /// 机身宽高（毫米，竖持），真机预览按此等比例绘制（LAY-109）。来源见
  /// docs/evidence/v30-kindle-preview-20261014.md；Oasis、Scribe 一侧为宽边（[grip]）。
  final double bodyWidthMm, bodyHeightMm;
  final bool grip;

  /// 外观（V31，LAY-112，按实拍照片测量，见 docs/evidence/v31-kindle-body-20261014.md）：
  /// [topBezelMm] 为上边框（握持机型为三条窄边的宽度），下边框取余量；[gripLeft] 宽边在左（Scribe）；
  /// [logo] 为下边框“kindle”字样：'light' 浅灰、'dark' 压印暗字、'' 没有；[pressMarks] 为 Voyage 两侧压感翻页标记。
  final bool gripLeft, pressMarks;
  final double topBezelMm, cornerMm;
  final String logo;

  /// 屏幕可视区宽高（毫米）：分辨率 ÷ ppi。
  double get screenWidthMm => width / ppi * 25.4;
  double get screenHeightMm => height / ppi * 25.4;

  /// 阅读器中的 CSS 视口（逻辑像素），预览按此尺寸排版后整体缩放显示。
  final int viewportWidth, viewportHeight;

  String get label => '$name · $width × $height';
}

const kindleDevices = <KindleDevice>[
  KindleDevice(
    'kpw3',
    'KPW3 / Paperwhite 第 7 代（6 英寸）',
    1072,
    1448,
    300,
    1072,
    1448,
    bodyWidthMm: 117.0,
    bodyHeightMm: 169.0,
    topBezelMm: 13.4,
    cornerMm: 6,
    logo: 'light',
  ),
  KindleDevice(
    'kpw4',
    'KPW4 / Paperwhite 第 10 代（6 英寸）',
    1072,
    1448,
    300,
    1072,
    1448,
    bodyWidthMm: 116.0,
    bodyHeightMm: 167.0,
    topBezelMm: 18.6,
    cornerMm: 6,
    logo: 'light',
  ),
  KindleDevice(
    'kpw5',
    'KPW5 / Paperwhite 第 11 代（6.8 英寸）',
    1236,
    1648,
    300,
    1236,
    1648,
    bodyWidthMm: 124.6,
    bodyHeightMm: 174.2,
    topBezelMm: 9.7,
    cornerMm: 5.5,
    logo: 'light',
  ),
  KindleDevice(
    'kpw6',
    'KPW6 / Paperwhite 第 12 代（7 英寸）',
    1264,
    1680,
    300,
    1264,
    1680,
    bodyWidthMm: 127.6,
    bodyHeightMm: 176.7,
    topBezelMm: 8.4,
    cornerMm: 7,
    logo: 'light',
  ),
  KindleDevice(
    'basic10',
    'Kindle 基础款第 10 代（6 英寸）',
    600,
    800,
    167,
    600,
    800,
    bodyWidthMm: 113.0,
    bodyHeightMm: 160.0,
    topBezelMm: 10.7,
    cornerMm: 8,
    logo: 'dark',
  ),
  KindleDevice(
    'basic11',
    'Kindle 基础款第 11 代（6 英寸）',
    1072,
    1448,
    300,
    1072,
    1448,
    bodyWidthMm: 108.6,
    bodyHeightMm: 157.8,
    topBezelMm: 8.4,
    cornerMm: 8,
    logo: 'light',
  ),
  KindleDevice(
    'voyage',
    'Kindle Voyage（6 英寸）',
    1080,
    1440,
    300,
    1080,
    1440,
    bodyWidthMm: 115.0,
    bodyHeightMm: 162.0,
    topBezelMm: 15.0,
    cornerMm: 5,
    logo: 'light',
    pressMarks: true,
  ),
  KindleDevice(
    'oasis1',
    'Kindle Oasis 1（6 英寸）',
    1080,
    1440,
    300,
    1080,
    1440,
    bodyWidthMm: 122.0,
    bodyHeightMm: 143.0,
    grip: true,
    topBezelMm: 10.5,
    cornerMm: 4,
  ),
  KindleDevice(
    'oasis2',
    'Kindle Oasis 2（7 英寸）',
    1264,
    1680,
    300,
    1264,
    1680,
    bodyWidthMm: 141.0,
    bodyHeightMm: 159.0,
    grip: true,
    topBezelMm: 8.4,
    cornerMm: 4,
  ),
  KindleDevice(
    'oasis3',
    'Kindle Oasis 3（7 英寸）',
    1264,
    1680,
    300,
    1264,
    1680,
    bodyWidthMm: 141.0,
    bodyHeightMm: 159.0,
    grip: true,
    topBezelMm: 8.4,
    cornerMm: 4,
  ),
  KindleDevice(
    'scribe',
    'Kindle Scribe（10.2 英寸）',
    1860,
    2480,
    300,
    1860,
    2480,
    bodyWidthMm: 196.0,
    bodyHeightMm: 230.0,
    grip: true,
    topBezelMm: 10.0,
    cornerMm: 6,
    gripLeft: true,
  ),
  KindleDevice(
    'colorsoft',
    'Kindle Colorsoft（7 英寸）',
    1264,
    1680,
    300,
    1264,
    1680,
    bodyWidthMm: 127.6,
    bodyHeightMm: 176.7,
    topBezelMm: 8.4,
    cornerMm: 7,
    logo: 'light',
  ),
];

const defaultKindleDeviceId = 'kpw6';

/// 机型短名：“KPW6 / Paperwhite 第 12 代（7 英寸）”写作“KPW6”，
/// 没有代号的去掉“Kindle”和括号部分，例如“Scribe”“基础款第 10 代”（LAY-102）。
String kindleShortName(String name) =>
    name.split('（').first.split(' / ').first.replaceFirst('Kindle ', '').trim();

/// 自定义机型：宽 320–5000、高 320–7000 像素，PPI 72–600；超出时返回 null。
/// 视口按长边 540 逻辑像素缩放（与原版相同）。
KindleDevice? customKindleDevice(int width, int height, int ppi) {
  if (width < 320 || width > 5000 || height < 320 || height > 7000) return null;
  if (ppi < 72 || ppi > 600) return null;
  return KindleDevice(
    'custom',
    '自定义 · $ppi PPI',
    width,
    height,
    ppi,
    width,
    height,
    // 自定义机型没有真实机身：按屏幕加通用边框（左右各 10 毫米、上下合计 34 毫米）绘制。
    bodyWidthMm: width / ppi * 25.4 + 20,
    bodyHeightMm: height / ppi * 25.4 + 34,
  );
}

/// 预览机型与阅读器设置（界面偏好）：序列化后存于设置目录，不写入书稿。
/// 阅读器设置对应 Kindle 的“字号档位 / 页边距 / 行距 / 字体”（LAY-096）；
/// [calibrations] 为“按真机校准”记录：键为 机型:档位:页边距:行距，值为（每行字数，每页行数）。
class PreviewDeviceChoice {
  const PreviewDeviceChoice({
    this.id = defaultKindleDeviceId,
    this.width = 1264,
    this.height = 1680,
    this.ppi = 300,
    this.level = 8,
    this.margin = 'narrow',
    this.spacing = 'medium',
    this.serif = false,
    this.calibrations = const {},
  });
  final String id;
  final int width, height, ppi;

  /// Kindle 字号档位 1–14。
  final int level;

  /// 页边距：narrow / medium / wide；行距：small / medium / large。
  final String margin, spacing;
  final bool serif;
  final Map<String, (int, int)> calibrations;

  KindleDevice get device => id == 'custom'
      ? customKindleDevice(width, height, ppi) ?? kindleDevices[3]
      : kindleDevices.firstWhere(
          (d) => d.id == id,
          orElse: () => kindleDevices[3],
        );

  String get calibrationKey => '$id:$level:$margin:$spacing';

  PreviewDeviceChoice copyWith({
    String? id,
    int? width,
    int? height,
    int? ppi,
    int? level,
    String? margin,
    String? spacing,
    bool? serif,
    Map<String, (int, int)>? calibrations,
  }) => PreviewDeviceChoice(
    id: id ?? this.id,
    width: width ?? this.width,
    height: height ?? this.height,
    ppi: ppi ?? this.ppi,
    level: level ?? this.level,
    margin: margin ?? this.margin,
    spacing: spacing ?? this.spacing,
    serif: serif ?? this.serif,
    calibrations: calibrations ?? this.calibrations,
  );

  String encode() => jsonEncode({
    'id': id,
    'width': width,
    'height': height,
    'ppi': ppi,
    'level': level,
    'margin': margin,
    'spacing': spacing,
    'serif': serif,
    'calibrations': {
      for (final e in calibrations.entries) e.key: [e.value.$1, e.value.$2],
    },
  });

  static PreviewDeviceChoice decode(String? raw) {
    try {
      final v = jsonDecode(raw ?? '') as Map;
      final cal = <String, (int, int)>{};
      for (final e in ((v['calibrations'] as Map?) ?? const {}).entries) {
        final pair = (e.value as List).cast<num>();
        cal['${e.key}'] = (pair[0].toInt(), pair[1].toInt());
      }
      String pick(Object? value, List<String> allowed, String fallback) =>
          allowed.contains(value) ? value as String : fallback;
      return PreviewDeviceChoice(
        id: v['id'] as String? ?? defaultKindleDeviceId,
        width: (v['width'] as num?)?.toInt() ?? 1264,
        height: (v['height'] as num?)?.toInt() ?? 1680,
        ppi: (v['ppi'] as num?)?.toInt() ?? 300,
        level: ((v['level'] as num?)?.toInt() ?? 8).clamp(1, 14),
        margin: pick(v['margin'], ['narrow', 'medium', 'wide'], 'narrow'),
        spacing: pick(v['spacing'], ['small', 'medium', 'large'], 'medium'),
        serif: v['serif'] == true,
        calibrations: cal,
      );
    } catch (_) {
      return const PreviewDeviceChoice();
    }
  }
}

/// Kindle 固件 5.8.11 中的 14 档默认字号（V32，LAY-113）。MobileRead 论坛从固件代码读出，
/// 用于非中日韩文字，按屏幕 ppi 分三套；数值按磅计（与 KPW5 实测吻合，论坛另有“1/100 英寸”之说，与实测不符）。
const kindleFontRamp = <int, List<double>>{
  300: [
    6.96,
    7.92,
    8.40,
    9.36,
    10.56,
    11.52,
    12.48,
    13.92,
    15.36,
    17.04,
    19.20,
    22.08,
    25.20,
    29.28,
  ],
  212: [
    7.13,
    7.81,
    8.49,
    9.17,
    10.53,
    11.545,
    12.56,
    14.03,
    15.50,
    16.98,
    19.00,
    22.00,
    25.00,
    29.20,
  ],
  167: [
    7.33,
    8.19,
    9.05,
    9.92,
    10.78,
    11.64,
    12.93,
    14.23,
    15.95,
    17.68,
    19.83,
    22.42,
    25.87,
    29.75,
  ],
};

/// 固件中的页边距（磅）：左右“窄 / 中 / 宽”（font.wordsperline.margin.list），
/// 上边距 reader.content.topMargin，下边距 reader.content.bottomMargin。
/// 页脚（位置、进度）画在下边距里，不另占高度（V35，LAY-116：按用户 KPW5 并排照片，
/// 真机第 4 章首页第十行的下沿在屏高 0.946 处、页脚文字在 0.972 处）。
const readerMarginPt = {'narrow': 16.98, 'medium': 33.96, 'wide': 50.94};
const readerTopPt = 13.58;
const readerBottomPt = 13.58;

/// 预览排版尺寸。[measured] 为 true 表示直接来自实测或用户校准；否则为推算。
class ReaderMetrics {
  const ReaderMetrics({
    required this.fontPx,
    required this.lineRatio,
    required this.padding,
    required this.measured,
    required this.note,
    this.tracking = 0,
    this.justify = false,
    this.cssPx = 1,
  });
  final double fontPx, lineRatio;
  final EdgeInsets padding;
  final bool measured;
  final String note;

  /// 正文字距补偿（em）与两端对齐（V118，KPW5 真机规则）：真机按取整后的字宽断行，再两端对齐。
  final double tracking;
  final bool justify;

  /// 书内 CSS 的 1px 在屏幕上画几个像素（V118：KPW5 为 300 / 160 = 1.875，按标题内边距与下框实测）。
  /// 为 1 时不换算。
  final double cssPx;
}

/// KFX 真机规则（V118，2026-10-29 用户 KPW5 真机截图实测，docs/research/2026-10-29_KPW5真机实测.md）。
/// 字号 = 固件中文字号表（磅）× ppi/72 × 书内字号；行距 = 字号 × 书内行高 × 阅读器行间距，取整；
/// 版心 = 字号的整数倍（可用宽 ÷ 字号取整）并居中，两端对齐；上、下各留 15.12 磅（KPW5 上 63 像素），
/// 页脚画在下边距里。所有机型按原生分辨率排版；KPW5 以外的机型按 ppi 换算，属于推算。
const kpw5CjkRampPt = [
  6.96,
  7.92,
  8.40,
  9.36,
  10.56,
  11.52,
  12.48,
  13.92,
  15.36,
  17.04,
  19.20,
  22.08,
  25.20,
  29.04,
];

/// 阅读器行间距三档（固件行距资源 1.14 / 1.35 / 1.54；中、大实测，小为资源值）。
const kpw5SpacingFactor = {'small': 1.14, 'medium': 1.35, 'large': 1.54};

/// 三档页边距每侧扣掉的宽度（磅）：KPW5 实测可用宽窄 1056–1072、中 829–893、宽 702–766 像素，
/// 取中间值 1064 / 861 / 734，每侧 86 / 187.5 / 251 像素，按 300 ppi 换成磅，其他机型按 ppi 换算。
const kfxSideMarginPt = {'narrow': 20.64, 'medium': 45.0, 'wide': 60.24};

/// 上下边距（磅）：KPW5 上 63 像素。下边距由各截图每页行数反推为 52–92 像素，取与上边距相同；
/// 126 是 AZW3 阅读窗口的留白，不适用于 KFX。
const kfxTopPt = 15.12, kfxBottomPt = 15.12;

/// 实测过的情况：档位:页边距:行间距。
const kpw5MeasuredCases = {
  '4:narrow:medium',
  '6:narrow:medium',
  '8:narrow:medium',
  '10:narrow:medium',
  '12:narrow:medium',
  '8:medium:medium',
  '8:wide:medium',
  '8:narrow:large',
};

/// 字号表：300 ppi 级机型用 KPW5 固件的中文字号表；其他按 ppi 取固件字号表（只有非中日韩的一套）。
List<double> kfxRamp(KindleDevice d) =>
    d.ppi >= 256 ? kpw5CjkRampPt : kindleRamp(d);

ReaderMetrics kfxMetrics(
  PreviewDeviceChoice choice, {
  double bookScale = 1,
  double bookLineHeight = 1.2,
}) {
  final device = choice.device;
  final px = device.ppi / 72;
  final level = choice.level.clamp(1, 14);
  final table = (kfxRamp(device)[level - 1] * px).roundToDouble();
  final font = table * 1.1 * bookScale;
  final spacing = kpw5SpacingFactor[choice.spacing] ?? 1.35;
  final line = (font * bookLineHeight * spacing).roundToDouble();
  final sidePt = kfxSideMarginPt[choice.margin] ?? kfxSideMarginPt['narrow']!;
  final available = device.width - 2 * sidePt * px;
  final box = (available / font).floor() * font;
  final side = (device.viewportWidth - box) / 2;
  final kpw5 = device.id == 'kpw5';
  final measured =
      kpw5 &&
      kpw5MeasuredCases.contains('$level:${choice.margin}:${choice.spacing}') &&
      bookScale == 1 &&
      bookLineHeight == 1.2;
  return ReaderMetrics(
    fontPx: font,
    lineRatio: line / font,
    padding: EdgeInsets.fromLTRB(
      side,
      (kfxTopPt * px).roundToDouble(),
      side,
      (kfxBottomPt * px).roundToDouble(),
    ),
    measured: measured,
    note: measured
        ? '按 KPW5 真机实测'
        : kpw5
        ? '按 KPW5 真机规则推算'
        : '按 KPW5 真机规则按 ${device.ppi} PPI 换算',
    // 真机按取整后的字宽断行（字号 6、8 时一行少放一个字），这里用字距补到整数宽。
    tracking: (font.roundToDouble() - font) / font,
    justify: true,
    // 书内 1px 画成 ppi/160 个像素（KPW5 上 1.875）。
    cssPx: device.ppi / 160,
  );
}

/// 实测“每行 N 字”对应的行宽（字）：真机行末的句号、逗号压成半宽，数到的 N 字通常是 N−1 个整字
/// 加一个半宽标点，行宽在 N−0.5 与 N 之间，取 N−0.25（V34，LAY-115；按用户 KPW5 并排照片核对）。
double readerLineEms(int perLine) => perLine - .25;

/// 机型使用的字号表：按 ppi 取最接近的一套。
List<double> kindleRamp(KindleDevice d) => d.ppi < 190
    ? kindleFontRamp[167]!
    : d.ppi < 256
    ? kindleFontRamp[212]!
    : kindleFontRamp[300]!;

/// 磅换算为机型视口中的 CSS 像素（磅 → 机器像素 → 视口）。
double kindlePtToCss(KindleDevice d, double pt) =>
    pt * d.ppi / 72 * d.viewportWidth / d.width;

/// 每侧左右页边距（CSS 像素）。
double readerSideMargin(KindleDevice d, String margin) =>
    kindlePtToCss(d, readerMarginPt[margin] ?? readerMarginPt['narrow']!);

/// 按机型与阅读器设置计算正文字号与行高（LAY-096、LAY-113）。
/// [bookScale] 为书内字号相对 110% 的倍数；[bookLineHeight] 为书内行高。
/// V118 起没有用户校准时一律按 KFX 真机规则（[kfxMetrics]，所有机型按原生分辨率排版）；
/// 有“按真机校准”记录时按输入的每行字数、每页行数反推。
ReaderMetrics readerMetrics(
  PreviewDeviceChoice choice, {
  double bookScale = 1,
  double bookLineHeight = 1.2,
}) {
  final override = choice.calibrations[choice.calibrationKey];
  if (override == null) {
    return kfxMetrics(
      choice,
      bookScale: bookScale,
      bookLineHeight: bookLineHeight,
    );
  }
  // 用户“按真机校准”：按输入的每行字数、每页行数反推字号与行高（LAY-096）。
  final device = choice.device;
  final side = readerSideMargin(device, choice.margin);
  final top = kindlePtToCss(device, readerTopPt);
  final bottom = kindlePtToCss(device, readerBottomPt);
  final width = device.viewportWidth - 2 * side;
  final height = device.viewportHeight - top - bottom;
  final font = width / readerLineEms(override.$1);
  // 校准时一页里通常有若干段间距：按约 12% 的高度留给段间距估计行高。
  final line = height * .88 / override.$2;
  return ReaderMetrics(
    fontPx: font * bookScale,
    lineRatio: line / font,
    padding: EdgeInsets.fromLTRB(side, top, side, bottom),
    measured: true,
    note: '按真机校准',
  );
}

/// 标题下框的线型。
enum HeadingRule { none, dotted, dashed, solid }

/// 章节标题样式在预览中的画法（V36，LAY-117），与 Rust `heading_rules` 一一对应：
/// [scale] 为相对正文的字号；[top]、[bottom]、[padTop]、[padBottom] 为相对标题字号的倍数（CSS 的 em）；
/// 下框宽度为 CSS 像素。所有样式都居中、加粗（h 标签默认粗体）。
class HeadingLook {
  const HeadingLook({
    required this.scale,
    required this.top,
    required this.bottom,
    this.padTop = 0,
    this.padBottom = 0,
    this.rule = HeadingRule.none,
    this.ruleWidth = 0,
    this.ruleColor = const Color(0xFF888888),
    this.sans = false,
    this.twoLine = false,
  });
  final double scale, top, bottom, padTop, padBottom, ruleWidth;
  final HeadingRule rule;
  final Color ruleColor;

  /// 亚马逊官方样式指定黑体；精排两行把“第 N 章”放在上行小字。
  final bool sans, twoLine;
}

const headingLooks = {
  // 原版 EasyPub：x-large（1.5rem，正文 110%）、上下内边距 10px（x-large 下约 0.417em）、浅灰点线。
  'classic': HeadingLook(
    scale: 1.5 / 1.1,
    top: 0,
    bottom: 1.2,
    padTop: 10 / 24,
    padBottom: 10 / 24,
    rule: HeadingRule.dotted,
    ruleWidth: 1,
    ruleColor: Color(0xFFC1CCC0),
  ),
  'amazon': HeadingLook(
    scale: 1.2,
    top: .67,
    bottom: 1,
    rule: HeadingRule.dashed,
    ruleWidth: 2,
    ruleColor: Color(0xFFC7C7C7),
    sans: true,
  ),
  'publisher': HeadingLook(scale: 1.6, top: 2, bottom: 1),
  'two_line': HeadingLook(scale: 1.2, top: .5, bottom: 2, twoLine: true),
  'light_novel': HeadingLook(
    scale: 1.5,
    top: 0,
    bottom: 1,
    padBottom: .4,
    rule: HeadingRule.solid,
    ruleWidth: 1,
  ),
};

/// 标题开头“第 N 章”（含后面的空白、冒号等分隔）的结束位置，与 Rust `chapter_label_end` 相同；
/// 章名为空或不是“第 N 章 / 回 / 节 / 卷 / 集 / 部 / 篇 / 话 / 幕”开头时返回 null。
int? chapterLabelEnd(String text) {
  final m = RegExp(r'^\s*第[0-9０-９零〇一二三四五六七八九十百千万两]+[章回节卷集部篇话幕][\s:：、.．·\-—]*')
      .firstMatch(text);
  if (m == null || text.substring(m.end).trim().isEmpty) return null;
  return m.end;
}

/// 画标题下框：点线、虚线或实线，[y] 为线的中心。
void paintHeadingRule(
  Canvas canvas,
  HeadingLook look,
  double x,
  double y,
  double width,
  double stroke,
) {
  if (look.rule == HeadingRule.none || stroke <= 0) return;
  final paint = Paint()
    ..color = look.ruleColor
    ..strokeWidth = stroke;
  if (look.rule == HeadingRule.solid) {
    canvas.drawLine(Offset(x, y), Offset(x + width, y), paint);
    return;
  }
  final dash = look.rule == HeadingRule.dotted ? stroke : stroke * 3;
  final gap = look.rule == HeadingRule.dotted ? stroke * 1.5 : stroke * 2;
  for (var at = x; at < x + width; at += dash + gap) {
    canvas.drawLine(
      Offset(at, y),
      Offset(math.min(at + dash, x + width), y),
      paint,
    );
  }
}

/// 一页中的一段（或段的一部分）。
class PreviewPiece {
  const PreviewPiece(
    this.text, {
    this.title = false,
    this.indent = true,
    this.initial = false,
    this.kind = '',
    this.image,
    this.role = '',
    this.runStart = false,
    this.runEnd = false,
    this.heading = false,
    this.spans,
  });
  final String text;
  final bool title, indent;

  /// 文字样式（V120，章节页排版视图）：按显示的文字分出加粗等片段；为空时整段同一样式。
  final InlineSpan Function(String text)? spans;

  /// 系统提示分类样式（V104，LAY-146）：单行 `note` 或面板 `panel`；不是分类样式时为空。
  /// 一段连续的系统提示从 [runStart] 到 [runEnd]；跨页切开时前半段不收尾、后半段不起头。
  final String role;
  final bool runStart, runEnd;

  /// 面板的标题行。
  final bool heading;

  /// 正文插图（R5-01）；不为空时这一块只画图和图注。
  final PreviewImage? image;

  /// 系统提示 `system`、诗句 `verse`、署名 `by`（V50，LAY-121/122）；普通段为空。
  final String kind;

  /// 章首段落的首字放大（V49，LAY-119）。
  final bool initial;
}

final _initialLetter = RegExp(r'^[\p{L}\p{N}]', unicode: true);

/// 小预览里的正文插图（R5-01），与成品 CSS 一致：随正文的按原尺寸、超出版心才缩小
/// （`max-width: 100%`），上下各留 1em；整页的铺满宽度并单独占一页。保持原比例；
/// 读不出的图画虚线框和文件名。只是近似，成品以真机预览为准。
class PreviewImage {
  const PreviewImage(
    this.name, {
    this.pixels,
    this.naturalWidth,
    this.layout = 'inline',
    this.caption = '',
  });
  final String name, layout, caption;
  final ui.Image? pixels;

  /// 原图宽度（像素）；[pixels] 可能是缩小后解码的。
  final double? naturalWidth;
  bool get fullPage => layout == 'full_page';
}

/// 随正文插图上下的 1em 外边距里，段后间距以外还要多留的部分。
double _figureExtra(PreviewImage image, PreviewStyle style) => image.fullPage
    ? 0
    : math.max(0, (style.body.fontSize ?? 16) - style.paragraphSpacing);

TextPainter _captionPainter(
  PreviewImage image,
  PreviewStyle style,
  double width,
  Locale? locale,
) => TextPainter(
  text: TextSpan(
    text: image.pixels == null && image.caption.isEmpty
        ? image.name
        : image.caption,
    style: style.body.copyWith(fontSize: (style.body.fontSize ?? 16) * .8),
  ),
  textAlign: TextAlign.center,
  textDirection: TextDirection.ltr,
  textScaler: TextScaler.noScaling,
  locale: locale,
)..layout(maxWidth: width);

/// 插图块的图框（不含图注），高度不超过 [height] 减去图注。
Rect _imageRect(
  PreviewImage image,
  double width,
  double height,
  double caption,
) {
  final px = image.pixels;
  final ratio = px == null || px.width == 0 ? .5 : px.height / px.width;
  var w = image.fullPage || px == null
      ? width
      : math.min(width, image.naturalWidth ?? px.width.toDouble());
  var h = w * ratio;
  final room = math.max(20.0, height - caption);
  if (h > room) {
    h = room;
    w = h / ratio;
  }
  return Rect.fromLTWH((width - w) / 2, 0, w, h);
}

/// 插图块的总高度：图、图注与两者之间的间距。
double _imageHeight(
  PreviewImage image,
  PreviewStyle style,
  double width,
  double height,
  Locale? locale,
) {
  final caption = _captionPainter(image, style, width, locale);
  final text = caption.plainText.isEmpty ? 0.0 : caption.height + 4;
  caption.dispose();
  final extra = _figureExtra(image, style);
  return _imageRect(image, width, height - 2 * extra, text).height +
      text +
      2 * extra;
}

/// 预览的排版参数（逻辑像素）。
class PreviewStyle {
  const PreviewStyle({
    required this.title,
    required this.body,
    required this.align,
    required this.indent,
    required this.paragraphSpacing,
    required this.titleSpacing,
    required this.padding,
    this.heading,
    this.ruleScale = 1,
    this.sceneBreak = 'off',
    this.firstParagraph = 'normal',
    this.systemBlock = 'off',
    this.verseBlock = 'off',
    this.headImage,
    this.headFraction = .5,
    this.systemStyles,
  });

  /// 系统提示与诗词样式（V50，LAY-121/122），见 `systemBlockStyles`、`verseBlockStyles`。
  final String systemBlock, verseBlock;

  /// “分类样式”下单行提示与面板的样式参数（V104，LAY-146）：`{note: {...}, panel: {...}}`。
  final Map? systemStyles;

  /// 统一章首图（V54，LAY-124）：画在章标题上方，宽度为版心的 [headFraction]，保持原比例。
  final ui.Image? headImage;
  final double headFraction;

  /// 章首图连同下方 0.8em 间距的高度。
  double headHeight(double width) {
    final image = headImage;
    if (image == null || image.width == 0) return 0;
    return width * headFraction * image.height / image.width +
        (body.fontSize ?? 16) * .8;
  }

  final TextStyle title, body;

  /// 章首段落样式（V49，LAY-119），见 `firstParagraphStyles`。
  final String firstParagraph;

  /// 场景分隔样式（V46，LAY-118），见 `sceneBreakStyles`。
  final String sceneBreak;
  final TextAlign align;
  final double indent, paragraphSpacing, titleSpacing;
  final EdgeInsets padding;

  /// 章节标题样式（V36）；为空时标题后只留 [titleSpacing]。
  final HeadingLook? heading;

  /// CSS 像素换算为预览像素的倍数（下框宽度用）。
  final double ruleScale;

  double get _titleSize => title.fontSize ?? 16;

  /// 标题块在文字上方、下方额外占的高度（外边距、内边距、下框），以及标题后的间距。
  double get titleBefore {
    final h = heading;
    return h == null ? 0 : (h.top + h.padTop) * _titleSize;
  }

  double get titleAfter {
    final h = heading;
    return h == null ? 0 : h.padBottom * _titleSize + ruleStroke;
  }

  double get ruleStroke {
    final h = heading;
    return h == null || h.rule == HeadingRule.none
        ? 0
        : math.max(1, h.ruleWidth * ruleScale);
  }

  double get titleGap {
    final h = heading;
    return h == null ? titleSpacing : h.bottom * _titleSize;
  }
}

/// 这一段系统提示的分类样式；不是分类样式时为空。
SystemBlockLook? _look(PreviewPiece piece, PreviewStyle style) {
  if (piece.role.isEmpty) return null;
  final values = style.systemStyles?[piece.role];
  if (values is! Map) return null;
  return SystemBlockLook(values, style.body.fontSize ?? 16, style.ruleScale);
}

/// 分类样式的系统提示在文字上方、下方多占的高度（块的外边距、边框、内边距，标题行的内边距与线）。
/// 块的外边距与相邻段落的段间距按 CSS 外边距折叠取较大者。
(double, double) _blockExtra(PreviewPiece piece, PreviewStyle style) {
  final look = _look(piece, style);
  if (look == null) return (0, 0);
  final margin = math.max(0.0, look.margin - style.paragraphSpacing);
  final shadedTitle = piece.heading && look.title == 'shaded';
  var before = 0.0, after = 0.0;
  if (piece.runStart) {
    before += margin + look.top + (shadedTitle ? 0 : look.pad);
  }
  if (piece.heading) {
    before += look.titlePad;
    after += look.titlePad + look.titleRule + look.titleGap;
  }
  if (piece.runEnd) after += look.pad + look.bottom + margin;
  return (before, after);
}

/// 一段之后到下一段的间距：同一段系统提示里的行之间没有段间距。
double _gapAfter(PreviewPiece piece, PreviewStyle style) => piece.title
    ? style.titleGap
    : piece.role.isNotEmpty && !piece.runEnd && _look(piece, style) != null
    ? 0
    : style.paragraphSpacing;

TextSpan _span(PreviewPiece piece, PreviewStyle style) {
  if (piece.title && style.heading?.twoLine == true) {
    final end = chapterLabelEnd(piece.text);
    if (end != null) {
      return TextSpan(
        style: style.title,
        children: [
          TextSpan(
            text: piece.text.substring(0, end).trimRight(),
            style: style.title.copyWith(fontSize: style._titleSize * .7),
          ),
          TextSpan(text: '\n${piece.text.substring(end)}'),
        ],
      );
    }
  }
  if (!piece.title && style.sceneBreak != 'off' && isSceneBreak(piece.text)) {
    return TextSpan(
      style: style.body.copyWith(
        letterSpacing: (style.body.fontSize ?? 16) * .2,
      ),
      text: sceneBreakText(style.sceneBreak, piece.text),
    );
  }
  final look = _look(piece, style);
  if (look != null) {
    final base = style.body.copyWith(
      fontSize: look.fontEm,
      fontWeight: look.bold || piece.heading ? FontWeight.bold : null,
      fontFamily: look.kai ? 'KaiTi' : null,
    );
    final key = look.keyBold && !piece.heading
        ? systemKeyEnd(piece.text)
        : null;
    return TextSpan(
      style: base,
      children: key == null
          ? [piece.spans?.call(piece.text) ?? TextSpan(text: piece.text)]
          : [
              TextSpan(
                text: piece.text.substring(0, key),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              TextSpan(text: piece.text.substring(key)),
            ],
    );
  }
  final initial = piece.initial && _initialLetter.hasMatch(piece.text);
  return TextSpan(
    style: piece.title ? style.title : style.body,
    children: [
      if (!piece.title && piece.indent && style.indent > 0)
        WidgetSpan(child: SizedBox(width: style.indent)),
      if (initial)
        TextSpan(
          text: String.fromCharCode(piece.text.runes.first),
          style: style.body.copyWith(
            fontSize: (style.body.fontSize ?? 16) * 1.6,
            fontWeight: FontWeight.bold,
            height: 1,
          ),
        ),
      if (!initial && piece.spans != null)
        piece.spans!(piece.text)
      else
        TextSpan(
          text: initial
              ? piece.text.substring(
                  String.fromCharCode(piece.text.runes.first).length,
                )
              : piece.text,
        ),
    ],
  );
}

/// 一段之后到下一段的间距（V120，章节页排版视图逐段排时用）。
double previewGapAfter(PreviewPiece piece, PreviewStyle style) =>
    _gapAfter(piece, style);

/// 按书页规则画的一段（V120，章节页排版视图）：[style] 的页边距应为零，宽为版心宽；
/// 高度与书页里这一段相同，不含段后间距。
class PreviewPieceView extends StatelessWidget {
  const PreviewPieceView({
    super.key,
    required this.piece,
    required this.style,
    required this.width,
    required this.paper,
    this.locale,
  });
  final PreviewPiece piece;
  final PreviewStyle style;
  final double width;
  final Color paper;
  final Locale? locale;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, PreviewPage.contentHeight([piece], style, width, locale)),
    painter: _PagePainter([piece], style, paper, locale),
  );
}

TextPainter _painter(
  PreviewPiece piece,
  PreviewStyle style,
  double width, [
  Locale? locale,
]) {
  final scene =
      !piece.title && style.sceneBreak != 'off' && isSceneBreak(piece.text);
  final look = _look(piece, style);
  final painter = TextPainter(
    text: _span(piece, style),
    textAlign: piece.title || scene || look?.center == true
        ? TextAlign.center
        : look != null
        ? TextAlign.start
        : piece.kind == 'by'
        ? TextAlign.right
        : piece.kind == 'verse' && style.verseBlock == 'center'
        ? TextAlign.center
        : style.align,
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    locale: locale,
  );
  if (!piece.title && !scene && piece.indent && style.indent > 0) {
    painter.setPlaceholderDimensions([
      PlaceholderDimensions(
        size: Size(style.indent, 0),
        alignment: PlaceholderAlignment.bottom,
      ),
    ]);
  }
  // 分类样式的系统提示：文字在边框与左右内边距以内排。
  // 普通段按版心宽排（V120）：否则段宽缩到文字宽，居中的诗句、靠右的署名都会画在左边。
  painter.layout(
    minWidth: look == null ? width : 0,
    maxWidth: look == null
        ? width
        : math.max(
            20.0,
            width -
                look.insetLeft(width) -
                look.insetRight(width) -
                look.left -
                look.right -
                2 * look.side,
          ),
  );
  return painter;
}

/// 按版面把标题与各段分到书页；放不下的段在行边界处切开，下一页续排（续排部分不再缩进）。
List<List<PreviewPiece>> paginatePreview({
  required String title,
  required List<String> paragraphs,
  required PreviewStyle style,
  required Size page,
  Locale? locale,

  /// 正文插图（R5-01）：键是插在第几段之后（0 起），-1 表示紧接标题。
  Map<int, List<PreviewImage>> images = const {},
}) {
  final width = math.max(40.0, page.width - style.padding.horizontal);
  final height = math.max(40.0, page.height - style.padding.vertical);
  final pages = <List<PreviewPiece>>[];
  var current = <PreviewPiece>[];
  var remaining = height;
  void flush() {
    if (current.isNotEmpty) pages.add(current);
    current = [];
    remaining = height;
  }

  // 章首段落（V49，LAY-119）：标题后与场景分隔后的第一段不缩进，可放大首字。
  final blocks = [PreviewPiece(title, title: true)];
  void addImages(int after) {
    for (final image in images[after] ?? const <PreviewImage>[]) {
      blocks.add(PreviewPiece('', indent: false, kind: 'image', image: image));
    }
  }

  addImages(-1);
  final styled = style.systemBlock == 'styled' && style.systemStyles != null;
  var pending = style.firstParagraph != 'normal';
  var previous = '';
  for (final (index, p) in paragraphs.indexed) {
    final scene = style.sceneBreak != 'off' && isSceneBreak(p);
    // 系统提示与诗词（V50，LAY-121/122）：署名只接在诗句之后。
    // 分类样式下单独一行的“叮！”并入紧跟的系统提示（与 Rust 相同）。
    final ding =
        styled &&
        isDingLine(p) &&
        index + 1 < paragraphs.length &&
        isSystemLine(paragraphs[index + 1]);
    final kind = style.systemBlock != 'off' && (isSystemLine(p) || ding)
        ? 'system'
        // 诗句要成联：前一行是诗句，或后一行是诗句或署名（与 Rust 相同，单独一行不算）。
        : style.verseBlock != 'off' &&
              isVerseLine(p) &&
              (previous == 'verse' ||
                  (index + 1 < paragraphs.length &&
                      (isVerseLine(paragraphs[index + 1]) ||
                          isVerseAttribution(paragraphs[index + 1]))))
        ? 'verse'
        : previous == 'verse' && isVerseAttribution(p)
        ? 'by'
        : '';
    previous = kind;
    final first = pending && !scene && p.trim().isNotEmpty && kind.isEmpty;
    blocks.add(
      kind.isNotEmpty
          ? PreviewPiece(p.trimLeft(), indent: false, kind: kind)
          : first
          ? PreviewPiece(
              p.trimLeft(),
              indent: false,
              initial: style.firstParagraph == 'large_initial',
            )
          : PreviewPiece(p),
    );
    if (scene) {
      pending = style.firstParagraph != 'normal';
    } else if (p.trim().isNotEmpty) {
      pending = false;
    }
    addImages(index);
  }
  if (styled) _markSystemRuns(blocks, style);
  for (final block in blocks) {
    final image = block.image;
    if (image != null) {
      // 整页插图前后都换页；放不下的随正文插图挪到下一页。
      if (image.fullPage) flush();
      final h = _imageHeight(image, style, width, height, locale);
      if (h > remaining && current.isNotEmpty) flush();
      current.add(block);
      remaining -= h + style.paragraphSpacing;
      if (image.fullPage) flush();
      continue;
    }
    var piece = block;
    final gap = _gapAfter(block, style);
    for (var guard = 0; guard < 2000; guard++) {
      final painter = _painter(piece, style, width, locale);
      final (before, after) = _blockExtra(piece, style);
      final h =
          painter.height +
          before +
          after +
          (piece.title
              ? style.titleBefore + style.titleAfter + style.headHeight(width)
              : 0);
      if (h <= remaining) {
        current.add(piece);
        remaining -= h + gap;
        painter.dispose();
        break;
      }
      final metrics = painter.computeLineMetrics();
      var fit = 0;
      var used = before;
      for (final m in metrics) {
        if (used + m.height > remaining) break;
        used += m.height;
        fit++;
      }
      if (fit == 0 || piece.title) {
        if (current.isEmpty) {
          // 单行就超过整页：照放，避免死循环。
          current.add(piece);
          painter.dispose();
          flush();
          break;
        }
        painter.dispose();
        flush();
        continue;
      }
      final shift = piece.indent && style.indent > 0 ? 1 : 0;
      final end = painter
          .getLineBoundary(
            painter.getPositionForOffset(
              Offset(0, used - before - metrics[fit - 1].height / 2),
            ),
          )
          .end;
      painter.dispose();
      final cut = (end - shift).clamp(1, piece.text.length);
      current.add(
        PreviewPiece(
          piece.text.substring(0, cut),
          indent: piece.indent,
          initial: piece.initial,
          kind: piece.kind,
          role: piece.role,
          runStart: piece.runStart,
          heading: piece.heading,
        ),
      );
      flush();
      final rest = piece.text.substring(cut);
      if (rest.trim().isEmpty) break;
      piece = PreviewPiece(
        rest,
        indent: false,
        kind: piece.kind,
        role: piece.role,
        runEnd: piece.runEnd,
      );
    }
  }
  flush();
  return pages.isEmpty ? [<PreviewPiece>[]] : pages;
}

/// 分类样式（V104，LAY-146）：连续的系统提示合成一段，一行为单行提示、多行为面板（与 Rust 按行数
/// 的规则相同）；面板首行是“叮！”或够短且不含冒号时作标题；按样式去掉【】。
void _markSystemRuns(List<PreviewPiece> blocks, PreviewStyle style) {
  var i = 0;
  while (i < blocks.length) {
    if (blocks[i].kind != 'system' || blocks[i].image != null) {
      i++;
      continue;
    }
    var end = i;
    while (end + 1 < blocks.length && blocks[end + 1].kind == 'system') {
      end++;
    }
    final role = end > i ? 'panel' : 'note';
    final values = style.systemStyles?[role];
    final look = values is Map
        ? SystemBlockLook(values, style.body.fontSize ?? 16, style.ruleScale)
        : null;
    final first = blocks[i].text;
    final titled =
        role == 'panel' &&
        look != null &&
        look.title != 'none' &&
        (isDingLine(first) || isSystemTitle(first));
    for (var k = i; k <= end; k++) {
      final text = blocks[k].text;
      blocks[k] = PreviewPiece(
        look?.removeBrackets == true || (titled && k == i)
            ? stripSystemBrackets(text)
            : text,
        indent: false,
        kind: 'system',
        role: role,
        runStart: k == i,
        runEnd: k == end,
        heading: titled && k == i,
      );
    }
    i = end + 1;
  }
}

/// 章节标题样式的缩略图（V36，LAY-117）：与小预览同一套画法，标题下画两条灰线代表正文。
class HeadingSample extends StatelessWidget {
  const HeadingSample({
    super.key,
    required this.look,
    required this.ink,
    required this.muted,
    this.text = '第1章 铜镜',
  });
  final HeadingLook look;
  final Color ink, muted;
  final String text;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(double.infinity, 50),
    painter: _HeadingSamplePainter(look, ink, muted, text),
  );
}

class _HeadingSamplePainter extends CustomPainter {
  _HeadingSamplePainter(this.look, this.ink, this.muted, this.text);
  final HeadingLook look;
  final Color ink, muted;
  final String text;

  @override
  void paint(Canvas canvas, Size size) {
    // 正文按 8 像素画；出版社样式上方留白较大，缩略图里按比例压缩外边距。
    const body = 8.0;
    final title = TextStyle(
      fontSize: body * look.scale,
      fontWeight: FontWeight.w700,
      color: ink,
      height: 1.25,
      fontFamily: look.sans ? 'Microsoft YaHei' : null,
    );
    final style = PreviewStyle(
      title: title,
      body: TextStyle(fontSize: body, color: ink),
      align: TextAlign.center,
      indent: 0,
      paragraphSpacing: 0,
      titleSpacing: 0,
      padding: EdgeInsets.zero,
      heading: look,
      ruleScale: body / 17.6 * 1.6,
    );
    final width = size.width * .9;
    final x = (size.width - width) / 2;
    final painter = _painter(PreviewPiece(text, title: true), style, width);
    final squeeze = .35;
    final before = style.titleBefore * squeeze;
    final total =
        before +
        painter.height +
        style.titleAfter +
        style.titleGap * squeeze +
        10;
    var y = math.max(0.0, (size.height - total) / 2) + before;
    painter.paint(canvas, Offset(x, y));
    y += painter.height + look.padBottom * (title.fontSize ?? body);
    paintHeadingRule(
      canvas,
      look,
      x,
      y + style.ruleStroke / 2,
      width,
      style.ruleStroke,
    );
    y += style.ruleStroke + style.titleGap * squeeze;
    painter.dispose();
    final bar = Paint()..color = muted;
    for (final (i, w) in [.86, .6].indexed) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y + i * 5, width * w, 2.5),
          const Radius.circular(1.25),
        ),
        bar,
      );
    }
  }

  @override
  bool shouldRepaint(_HeadingSamplePainter old) =>
      old.look != look ||
      old.ink != ink ||
      old.muted != muted ||
      old.text != text;
}

/// 一页书页：按视口尺寸排版，外部用 FittedBox 缩放。
/// 书页按与分页完全相同的 TextPainter（同字体、同语言区域、不缩放）绘制，
/// 分页与显示不会再因继承的默认文字样式不同而错开、截掉末尾几行（LAY-101）。
class PreviewPage extends StatelessWidget {
  const PreviewPage({
    super.key,
    required this.pieces,
    required this.style,
    required this.size,
    required this.paper,
    this.locale,
  });
  final List<PreviewPiece> pieces;
  final PreviewStyle style;
  final Size size;
  final Color paper;
  final Locale? locale;

  /// 各段内容的总高度（含段间距），供测试核对不超出版心。
  static double contentHeight(
    List<PreviewPiece> pieces,
    PreviewStyle style,
    double width, [
    Locale? locale,
  ]) {
    var y = 0.0;
    for (final (i, piece) in pieces.indexed) {
      if (piece.image != null) {
        y += _imageHeight(piece.image!, style, width, double.infinity, locale);
        if (i < pieces.length - 1) y += style.paragraphSpacing;
        continue;
      }
      final painter = _painter(piece, style, width, locale);
      final (before, after) = _blockExtra(piece, style);
      y += painter.height + before + after;
      if (piece.title) {
        y += style.titleBefore + style.titleAfter + style.headHeight(width);
      }
      painter.dispose();
      if (i < pieces.length - 1) y += _gapAfter(piece, style);
    }
    return y;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: pieces
        .map((p) => p.image == null ? p.text : '插图：${p.image!.name}')
        .join('\n'),
    child: ClipRect(
      child: CustomPaint(
        size: size,
        painter: _PagePainter(pieces, style, paper, locale),
      ),
    ),
  );
}

class _PagePainter extends CustomPainter {
  _PagePainter(this.pieces, this.style, this.paper, this.locale);
  final List<PreviewPiece> pieces;
  final PreviewStyle style;
  final Color paper;
  final Locale? locale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    final width = math.max(40.0, size.width - style.padding.horizontal);
    var y = style.padding.top;
    double? boxTop;
    for (final (i, piece) in pieces.indexed) {
      final image = piece.image;
      if (image != null) {
        y += _paintImage(canvas, image, style.padding.left, y, width, size);
        if (i < pieces.length - 1) y += style.paragraphSpacing;
        continue;
      }
      final painter = _painter(piece, style, width, locale);
      final head = style.headImage;
      if (piece.title && head != null && head.width > 0) {
        final w = width * style.headFraction;
        final h = w * head.height / head.width;
        canvas.drawImageRect(
          head,
          Rect.fromLTWH(0, 0, head.width.toDouble(), head.height.toDouble()),
          Rect.fromLTWH(style.padding.left + (width - w) / 2, y, w, h),
          Paint()..filterQuality = FilterQuality.medium,
        );
        y += style.headHeight(width);
      }
      if (piece.title) y += style.titleBefore;
      final look = _look(piece, style);
      if (look != null) {
        // 分类样式（V104，LAY-146）：照成品 CSS 画底色、边框、标题行，再画文字。
        y = _paintStyled(canvas, piece, look, painter, y, width);
        painter.dispose();
        if (i < pieces.length - 1) y += _gapAfter(piece, style);
        continue;
      }
      // “加框”（V50）；分类样式缺参数时也按加框画。
      final boxed =
          piece.kind == 'system' &&
          (style.systemBlock == 'box' || style.systemBlock == 'styled');
      if (boxed) boxTop ??= y;
      painter.paint(canvas, Offset(style.padding.left, y));
      y += painter.height;
      painter.dispose();
      // 系统提示加框（V50，LAY-121）：连续几段画一个框。
      final next = i + 1 < pieces.length ? pieces[i + 1] : null;
      if (boxed && next?.kind != 'system') {
        canvas.drawRect(
          Rect.fromLTRB(
            style.padding.left - 4,
            boxTop! - 3,
            style.padding.left + width + 4,
            y + 3,
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = style.body.color ?? const Color(0xFF333333),
        );
        boxTop = null;
      }
      if (piece.title && style.heading != null) {
        y += style.heading!.padBottom * style._titleSize;
        paintHeadingRule(
          canvas,
          style.heading!,
          style.padding.left,
          y + style.ruleStroke / 2,
          width,
          style.ruleStroke,
        );
        y += style.ruleStroke;
      }
      if (i < pieces.length - 1) {
        y += piece.title ? style.titleGap : style.paragraphSpacing;
      }
    }
  }

  /// 画一行分类样式的系统提示，返回画完后的纵坐标（含块的下边距）。
  double _paintStyled(
    Canvas canvas,
    PreviewPiece piece,
    SystemBlockLook look,
    TextPainter painter,
    double y,
    double width,
  ) {
    final ink = look.lineColor(style.body.color ?? const Color(0xFF333333));
    final left = style.padding.left + look.insetLeft(width);
    final right = style.padding.left + width - look.insetRight(width);
    width = right - left;
    final margin = math.max(0.0, look.margin - style.paragraphSpacing);
    final shadedTitle = piece.heading && look.title == 'shaded';
    if (piece.runStart) y += margin;
    final top = y;
    if (piece.runStart) y += look.top + (shadedTitle ? 0 : look.pad);
    final titleTop = y;
    y += look.titlePad;
    final textTop = y;
    y += painter.height;
    var bottom = y;
    if (piece.heading) bottom += look.titlePad + look.titleRule + look.titleGap;
    if (piece.runEnd) bottom += look.pad + look.bottom;
    final shade = look.shade;
    if (shade != null) {
      final rect = Rect.fromLTRB(left, top, right, bottom);
      // 圆角（V119）：一段跨页切开时只给起头、收尾的那一侧画圆角。
      final r = Radius.circular(look.radius ? .5 * look.fontEm : 0);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: piece.runStart ? r : Radius.zero,
          topRight: piece.runStart ? r : Radius.zero,
          bottomLeft: piece.runEnd ? r : Radius.zero,
          bottomRight: piece.runEnd ? r : Radius.zero,
        ),
        Paint()..color = shade,
      );
    }
    if (shadedTitle) {
      canvas.drawRect(
        Rect.fromLTRB(
          left + look.left,
          titleTop,
          right - look.right,
          y + look.titlePad,
        ),
        Paint()..color = const Color(0xFFE4E4E4),
      );
    }
    void rule(Offset a, Offset b, double w) {
      if (w <= 0) return;
      final paint = Paint()
        ..color = ink
        ..strokeWidth = look.doubleLine ? math.max(1.0, w / 3) : w;
      if (!look.doubleLine) {
        canvas.drawLine(a, b, paint);
        return;
      }
      // 双线：两条细线，中间留一条细线宽的空隙。
      final step = (w - paint.strokeWidth) / 2;
      final normal = a.dx == b.dx ? Offset(step, 0) : Offset(0, step);
      canvas.drawLine(a - normal, b - normal, paint);
      canvas.drawLine(a + normal, b + normal, paint);
    }

    if (look.left > 0) {
      final x = left + look.left / 2;
      rule(Offset(x, top), Offset(x, bottom), look.left);
    }
    if (look.right > 0) {
      final x = right - look.right / 2;
      rule(Offset(x, top), Offset(x, bottom), look.right);
    }
    if (piece.runStart && look.top > 0) {
      rule(
        Offset(left, top + look.top / 2),
        Offset(right, top + look.top / 2),
        look.top,
      );
    }
    if (piece.runEnd && look.bottom > 0) {
      final b = bottom - look.bottom / 2;
      rule(Offset(left, b), Offset(right, b), look.bottom);
    }
    if (piece.heading && look.titleRule > 0) {
      final b = y + look.titlePad + look.titleRule / 2;
      canvas.drawLine(
        Offset(left + look.left, b),
        Offset(right - look.right, b),
        Paint()
          ..color = ink
          ..strokeWidth = look.titleRule,
      );
    }
    final inner = width - look.left - look.right - 2 * look.side;
    final dx = look.center ? (inner - painter.width) / 2 : 0.0;
    painter.paint(
      canvas,
      Offset(left + look.left + look.side + math.max(0.0, dx), textTop),
    );
    return piece.runEnd ? bottom + margin : bottom;
  }

  /// 画一张插图和图注，返回占用的高度（R5-01）。
  double _paintImage(
    Canvas canvas,
    PreviewImage image,
    double left,
    double top,
    double width,
    Size size,
  ) {
    final caption = _captionPainter(image, style, width, locale);
    final text = caption.plainText.isEmpty ? 0.0 : caption.height + 4;
    final extra = _figureExtra(image, style);
    final box = _imageRect(
      image,
      width,
      size.height - style.padding.vertical - 2 * extra,
      text,
    ).shift(Offset(left, top + extra));
    final px = image.pixels;
    if (px != null) {
      canvas.drawImageRect(
        px,
        Rect.fromLTWH(0, 0, px.width.toDouble(), px.height.toDouble()),
        box,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      // 读不出的图：虚线框，图注位置写文件名。
      final ink = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = (style.body.color ?? const Color(0xFF333333)).withValues(
          alpha: .45,
        );
      for (var x = box.left; x < box.right; x += 8) {
        final end = math.min(x + 4, box.right);
        canvas.drawLine(Offset(x, box.top), Offset(end, box.top), ink);
        canvas.drawLine(Offset(x, box.bottom), Offset(end, box.bottom), ink);
      }
      for (var y = box.top; y < box.bottom; y += 8) {
        final end = math.min(y + 4, box.bottom);
        canvas.drawLine(Offset(box.left, y), Offset(box.left, end), ink);
        canvas.drawLine(Offset(box.right, y), Offset(box.right, end), ink);
      }
    }
    if (text > 0) caption.paint(canvas, Offset(left, box.bottom + 4));
    caption.dispose();
    return box.height + text + 2 * extra;
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      !identical(old.pieces, pieces) ||
      old.style != style ||
      old.paper != paper ||
      old.locale != locale;
}
