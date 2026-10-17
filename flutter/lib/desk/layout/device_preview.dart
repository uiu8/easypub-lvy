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
    360,
    486,
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
    360,
    486,
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
    390,
    520,
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
    400,
    532,
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
    360,
    480,
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
    360,
    486,
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
    360,
    480,
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
    360,
    480,
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
    400,
    532,
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
    400,
    532,
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
    465,
    620,
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
    400,
    532,
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
  final scale = 540 / math.max(width, height);
  return KindleDevice(
    'custom',
    '自定义 · $ppi PPI',
    width,
    height,
    ppi,
    math.max(240, (width * scale).round()),
    math.max(320, (height * scale).round()),
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

/// KPW5 实测校准点（来源：用户 2026-10-12 拍摄的真机照片；苹方、页边距最窄、行距中，
/// 书内字号 110%、行高 1.2）：档位 →（每行字数，每页正文行数，该页段间距数）。
const kpw5Calibration = <int, (int, int, int)>{
  4: (25, 17, 8),
  8: (16, 12, 6),
  12: (9, 9, 2),
};

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

/// 推导行距时用的下方留白（磅）：KPW5 校准照片“每页行数”按下边距加页脚高度推导行距；
/// V35 并排照片直接量得的第 8 档行距与这样推导的结果相差 0.6%，所以行距推导保留这个值。
const readerCalibrationBottomPt = 13.58 + 13.58;

/// 行距档位对行高的倍数。中为实测；小、大为推算（没有找到固件数值）。
const readerSpacingFactor = {'small': .88, 'medium': 1.0, 'large': 1.15};

/// 预览排版尺寸。[measured] 为 true 表示直接来自实测或用户校准；否则为推算。
class ReaderMetrics {
  const ReaderMetrics({
    required this.fontPx,
    required this.lineRatio,
    required this.padding,
    required this.measured,
    required this.note,
  });
  final double fontPx, lineRatio;
  final EdgeInsets padding;
  final bool measured;
  final String note;
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
/// 字号：固件字号表 × 书内 110% × 中文修正；修正取 KPW5 实测点与字号表之比，档位之间线性插值，
/// 所以 KPW5 的实测档位与照片一致，其他档位与机型沿用固件字号表的走势。
ReaderMetrics readerMetrics(
  PreviewDeviceChoice choice, {
  double bookScale = 1,
  double bookLineHeight = 1.2,
}) {
  final device = choice.device;
  final kpw5 = kindleDevices.firstWhere((d) => d.id == 'kpw5');
  final side = readerSideMargin(device, choice.margin);
  final top = kindlePtToCss(device, readerTopPt);
  final bottom = kindlePtToCss(device, readerBottomPt);
  final width = device.viewportWidth - 2 * side;
  final height = device.viewportHeight - top - bottom;
  final padding = EdgeInsets.fromLTRB(side, top, side, bottom);
  final override = choice.calibrations[choice.calibrationKey];
  if (override != null) {
    final font = width / readerLineEms(override.$1);
    // 校准时一页里通常有若干段间距：按约 12% 的高度留给段间距估计行高。
    final line = height * .88 / override.$2;
    return ReaderMetrics(
      fontPx: font * bookScale,
      lineRatio: line / font,
      padding: padding,
      measured: true,
      note: '按真机校准',
    );
  }
  // KPW5 实测点：每档正文字号与固件字号表之比（中文修正）、行高倍数。
  final kWidth = kpw5.viewportWidth - 2 * readerSideMargin(kpw5, 'narrow');
  final kHeight =
      kpw5.viewportHeight -
      kindlePtToCss(kpw5, readerTopPt) -
      kindlePtToCss(kpw5, readerCalibrationBottomPt);
  final ramp300 = kindleFontRamp[300]!;
  final points = [
    for (final e in kpw5Calibration.entries)
      () {
        final font = kWidth / readerLineEms(e.value.$1);
        final gaps = .6 * font * e.value.$3;
        return (
          e.key,
          font / (kindlePtToCss(kpw5, ramp300[e.key - 1]) * 1.1),
          (kHeight - gaps) / e.value.$2 / font,
        );
      }(),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final level = choice.level.clamp(1, 14);
  double at(double Function((int, double, double)) pick) {
    if (level <= points.first.$1) return pick(points.first);
    if (level >= points.last.$1) return pick(points.last);
    var i = 0;
    while (level > points[i + 1].$1) {
      i++;
    }
    final t = (level - points[i].$1) / (points[i + 1].$1 - points[i].$1);
    return pick(points[i]) + (pick(points[i + 1]) - pick(points[i])) * t;
  }

  final font =
      kindlePtToCss(device, kindleRamp(device)[level - 1]) *
      1.1 *
      at((p) => p.$2);
  final ratio =
      at((p) => p.$3).clamp(1.05, 2.4) *
      (readerSpacingFactor[choice.spacing] ?? 1) *
      (bookLineHeight / 1.2);
  final measured =
      device.id == 'kpw5' &&
      kpw5Calibration.containsKey(level) &&
      choice.margin == 'narrow' &&
      choice.spacing == 'medium' &&
      bookScale == 1 &&
      bookLineHeight == 1.2;
  return ReaderMetrics(
    fontPx: font * bookScale,
    lineRatio: ratio,
    padding: padding,
    measured: measured,
    note: measured ? '按 KPW5 实测' : '按固件推算',
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
  });
  final String text;
  final bool title, indent;

  /// 系统提示 `system`、诗句 `verse`、署名 `by`（V50，LAY-121/122）；普通段为空。
  final String kind;

  /// 章首段落的首字放大（V49，LAY-119）。
  final bool initial;
}

final _initialLetter = RegExp(r'^[\p{L}\p{N}]', unicode: true);

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
  });

  /// 系统提示与诗词样式（V50，LAY-121/122），见 `systemBlockStyles`、`verseBlockStyles`。
  final String systemBlock, verseBlock;

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

TextPainter _painter(
  PreviewPiece piece,
  PreviewStyle style,
  double width, [
  Locale? locale,
]) {
  final scene =
      !piece.title && style.sceneBreak != 'off' && isSceneBreak(piece.text);
  final painter = TextPainter(
    text: _span(piece, style),
    textAlign: piece.title || scene
        ? TextAlign.center
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
  painter.layout(maxWidth: width);
  return painter;
}

/// 按版面把标题与各段分到书页；放不下的段在行边界处切开，下一页续排（续排部分不再缩进）。
List<List<PreviewPiece>> paginatePreview({
  required String title,
  required List<String> paragraphs,
  required PreviewStyle style,
  required Size page,
  Locale? locale,
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
  var pending = style.firstParagraph != 'normal';
  var previous = '';
  for (final p in paragraphs) {
    final scene = style.sceneBreak != 'off' && isSceneBreak(p);
    // 系统提示与诗词（V50，LAY-121/122）：署名只接在诗句之后。
    final kind = style.systemBlock != 'off' && isSystemLine(p)
        ? 'system'
        : style.verseBlock != 'off' && isVerseLine(p)
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
  }
  for (final block in blocks) {
    var piece = block;
    final gap = block.title ? style.titleGap : style.paragraphSpacing;
    for (var guard = 0; guard < 2000; guard++) {
      final painter = _painter(piece, style, width, locale);
      final h =
          painter.height +
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
      var used = 0.0;
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
              Offset(0, used - metrics[fit - 1].height / 2),
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
        ),
      );
      flush();
      final rest = piece.text.substring(cut);
      if (rest.trim().isEmpty) break;
      piece = PreviewPiece(rest, indent: false, kind: piece.kind);
    }
  }
  flush();
  return pages.isEmpty ? [<PreviewPiece>[]] : pages;
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
      final painter = _painter(piece, style, width, locale);
      y += painter.height;
      if (piece.title) {
        y += style.titleBefore + style.titleAfter + style.headHeight(width);
      }
      painter.dispose();
      if (i < pieces.length - 1) {
        y += piece.title ? style.titleGap : style.paragraphSpacing;
      }
    }
    return y;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: pieces.map((p) => p.text).join('\n'),
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
      final boxed = piece.kind == 'system' && style.systemBlock == 'box';
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

  @override
  bool shouldRepaint(_PagePainter old) =>
      !identical(old.pieces, pieces) ||
      old.style != style ||
      old.paper != paper ||
      old.locale != locale;
}
