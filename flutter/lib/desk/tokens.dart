// 编辑台设计令牌：单色“纸与墨”。灰墨是唯一的强调色；语义色只有三种且低饱和：
// 朱（错误/删除）、赭（提醒/过期）、苔（差异中的新增/成功）。
// 设计来源 design_review_v37/tokens.dart（预览），见 docs/37 §14。
import 'package:flutter/material.dart';

@immutable
class Desk extends ThemeExtension<Desk> {
  const Desk({
    required this.dark,
    required this.canvas,
    required this.rail,
    required this.surface,
    required this.sunken,
    required this.paper,
    required this.line,
    required this.lineStrong,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentInk,
    required this.accentSoft,
    required this.pen,
    required this.penSoft,
    required this.warn,
    required this.warnSoft,
    required this.info,
    required this.infoSoft,
    required this.add,
    required this.addSoft,
    required this.del,
    required this.delSoft,
    required this.grain,
  });

  final bool dark;
  final Color canvas, rail, surface, sunken, paper, line, lineStrong;
  final Color ink, ink2, ink3;

  /// 强调色为灰墨 #6F6A63（用户 2026-10-10 选定）：主按钮、选中、开关、勾选、提示；其上文字用浅色。
  final Color accent, accentInk, accentSoft;
  final Color pen, penSoft, warn, warnSoft, info, infoSoft;
  final Color add, addSoft, del, delSoft;

  /// 纸纹强度（0 关闭）。
  final double grain;

  static const light = Desk(
    dark: false,
    canvas: Color(0xFFF6F4EF),
    rail: Color(0xFFF2EFE9),
    surface: Color(0xFFFCFBF8),
    sunken: Color(0xFFF0EDE7),
    paper: Color(0xFFFDFCF9),
    line: Color(0xFFE4E0D7),
    lineStrong: Color(0xFFD3CEC3),
    ink: Color(0xFF1F1E1B),
    ink2: Color(0xFF5E5A53),
    ink3: Color(0xFF99948A),
    accent: Color(0xFF6F6A63),
    accentInk: Color(0xFFF7F5F0),
    accentSoft: Color(0xFFECE9E4),
    pen: Color(0xFFA94434),
    penSoft: Color(0xFFF6EBE7),
    warn: Color(0xFF8D6A3B),
    warnSoft: Color(0xFFF4EEE3),
    info: Color(0xFF5E5A53),
    infoSoft: Color(0xFFEFECE6),
    add: Color(0xFF4E6D58),
    addSoft: Color(0xFFE9F0EA),
    del: Color(0xFFA94434),
    delSoft: Color(0xFFF6EBE7),
    grain: .016,
  );

  static const darkTheme = Desk(
    dark: true,
    canvas: Color(0xFF161513),
    rail: Color(0xFF1A1917),
    surface: Color(0xFF201F1C),
    sunken: Color(0xFF1A1917),
    paper: Color(0xFF22211E),
    line: Color(0xFF2F2D29),
    lineStrong: Color(0xFF3E3B36),
    ink: Color(0xFFECE9E2),
    ink2: Color(0xFFADA89E),
    ink3: Color(0xFF79756D),
    accent: Color(0xFFA9A49D),
    accentInk: Color(0xFF1A1917),
    accentSoft: Color(0xFF2E2C29),
    pen: Color(0xFFE0806A),
    penSoft: Color(0xFF3A2520),
    warn: Color(0xFFD2A45E),
    warnSoft: Color(0xFF332B1E),
    info: Color(0xFFADA89E),
    infoSoft: Color(0xFF26241F),
    add: Color(0xFF93BA9F),
    addSoft: Color(0xFF1E2C22),
    del: Color(0xFFE0806A),
    delSoft: Color(0xFF3A2520),
    grain: .02,
  );

  /// 高对比（V79，SET-074）：白底纯黑字、深灰线、黑色强调，给看不清浅灰的人用；不随主题色。
  static const contrast = Desk(
    dark: false,
    canvas: Color(0xFFFFFFFF),
    rail: Color(0xFFF2F2F2),
    surface: Color(0xFFFFFFFF),
    sunken: Color(0xFFEDEDED),
    paper: Color(0xFFFFFFFF),
    line: Color(0xFF6B6B6B),
    lineStrong: Color(0xFF000000),
    ink: Color(0xFF000000),
    ink2: Color(0xFF1F1F1F),
    ink3: Color(0xFF474747),
    accent: Color(0xFF000000),
    accentInk: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFE3E3E3),
    pen: Color(0xFF9E1C10),
    penSoft: Color(0xFFFBE9E7),
    warn: Color(0xFF6B4A00),
    warnSoft: Color(0xFFFFF3D6),
    info: Color(0xFF1F1F1F),
    infoSoft: Color(0xFFEDEDED),
    add: Color(0xFF1F5F2E),
    addSoft: Color(0xFFE3F1E6),
    del: Color(0xFF9E1C10),
    delSoft: Color(0xFFFBE9E7),
    grain: 0,
  );

  List<BoxShadow> get shadow1 => dark
      ? [const BoxShadow(color: Color(0x14FFFFFF), spreadRadius: .5)]
      : [
          BoxShadow(
            color: ink.withValues(alpha: .05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
          BoxShadow(color: ink.withValues(alpha: .05), spreadRadius: .5),
        ];
  List<BoxShadow> get shadow2 => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .5 : .10),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .3 : .06),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];
  List<BoxShadow> get shadow3 => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .6 : .20),
      blurRadius: 64,
      offset: const Offset(0, 24),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .3 : .08),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  /// 换成另一种主题色（V69，G-072）：只换强调色三件套，语义色与底色不变。
  Desk withAccent(DeskAccent a) =>
      copyWith(accent: a.accent, accentInk: a.onAccent, accentSoft: a.soft);

  @override
  Desk copyWith({
    double? grain,
    Color? accent,
    Color? accentInk,
    Color? accentSoft,
  }) => Desk(
    dark: dark,
    canvas: canvas,
    rail: rail,
    surface: surface,
    sunken: sunken,
    paper: paper,
    line: line,
    lineStrong: lineStrong,
    ink: ink,
    ink2: ink2,
    ink3: ink3,
    accent: accent ?? this.accent,
    accentInk: accentInk ?? this.accentInk,
    accentSoft: accentSoft ?? this.accentSoft,
    pen: pen,
    penSoft: penSoft,
    warn: warn,
    warnSoft: warnSoft,
    info: info,
    infoSoft: infoSoft,
    add: add,
    addSoft: addSoft,
    del: del,
    delSoft: delSoft,
    grain: grain ?? this.grain,
  );

  @override
  Desk lerp(Desk? other, double t) => t < .5 ? this : (other ?? this);
}

/// 主题色（V69，G-072）：强调色、其上文字色、浅底色。都与宣纸底色保持足够对比；默认墨灰。
@immutable
class DeskAccent {
  const DeskAccent(this.id, this.label, this.accent, this.onAccent, this.soft);
  final String id, label;
  final Color accent, onAccent, soft;

  /// 夜墨主题下的同一种主题色（V79）：调亮强调色，文字改深色，浅底换成深底。
  DeskAccent forDark() => DeskAccent(
    id,
    label,
    Color.lerp(accent, const Color(0xFFFFFFFF), .45)!,
    const Color(0xFF1A1917),
    Color.lerp(accent, const Color(0xFF201F1C), .72)!,
  );
}

/// 界面主题（V79，SET-074）：设置值 `ui_theme`。
const deskThemes = {
  'paper': '宣纸',
  'night': '夜墨',
  'contrast': '高对比',
  'system': '跟随系统',
};

/// 把设置值落到实际主题：跟随系统时按系统深浅色；未知值为宣纸。
String deskThemeMode(Object? value, {required bool systemDark}) =>
    switch (value) {
      'night' => 'night',
      'contrast' => 'contrast',
      'system' => systemDark ? 'night' : 'paper',
      _ => 'paper',
    };

/// 某个主题与主题色的令牌；高对比固定黑色强调。
Desk deskTokens(String mode, DeskAccent accent) => switch (mode) {
  'night' => Desk.darkTheme.withAccent(accent.forDark()),
  'contrast' => Desk.contrast,
  _ => Desk.light.withAccent(accent),
};

const deskAccents = [
  DeskAccent(
    'ink',
    '墨灰',
    Color(0xFF6F6A63),
    Color(0xFFF7F5F0),
    Color(0xFFECE9E4),
  ),
  DeskAccent(
    'teal',
    '青',
    Color(0xFF2F6B5E),
    Color(0xFFF3F8F6),
    Color(0xFFE1EEEA),
  ),
  DeskAccent(
    'blue',
    '蓝',
    Color(0xFF2F5D8A),
    Color(0xFFF4F7FB),
    Color(0xFFE2EAF3),
  ),
  DeskAccent(
    'violet',
    '紫',
    Color(0xFF5B4E8C),
    Color(0xFFF6F5FB),
    Color(0xFFE8E5F2),
  ),
  DeskAccent(
    'ochre',
    '赭',
    Color(0xFF8A5A2B),
    Color(0xFFFBF6F0),
    Color(0xFFF1E7DA),
  ),
  DeskAccent(
    'rose',
    '玫',
    Color(0xFF8C4361),
    Color(0xFFFBF4F7),
    Color(0xFFF1E2E9),
  ),
];

/// 设置值（`ui_accent`）对应的主题色；未知或缺省为墨灰。
DeskAccent deskAccentOf(Object? id) =>
    deskAccents.firstWhere((a) => a.id == id, orElse: () => deskAccents.first);

extension DeskContext on BuildContext {
  /// 未挂主题扩展的独立测试宿主回落到浅色令牌。
  Desk get desk => Theme.of(this).extension<Desk>() ?? Desk.light;
}

/// 动效令牌（V41，G-070）：时长五档、曲线三条，参考 Claude 前端的时间阶梯。
/// 悬停用 [fast]，切换用 [snap]，展开折叠用 [base] + [snapCurve]，侧栏用 [sheet]，主题与背景用 [slow]；
/// 回弹 [overshoot] 只给按钮按下，面板不弹。“减少动效”打开时经 [of] 得到零时长。
abstract final class DeskMotion {
  static const fast = Duration(milliseconds: 60);
  static const snap = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 200);
  static const sheet = Duration(milliseconds: 300);
  static const slow = Duration(milliseconds: 450);

  /// 平滑减速：大多数过渡。
  static const easeOut = Cubic(.165, .84, .44, 1);

  /// 利落咬合：展开、折叠、切换。
  static const snapCurve = Cubic(.32, .72, 0, 1);

  /// 轻微回弹：只用于按钮按下后的复位。
  static const overshoot = Cubic(.34, 1.3, .64, 1);

  /// 按“减少动效”（设置项与系统辅助功能，经 MediaQuery 传入）返回实际时长。
  static Duration of(BuildContext context, Duration duration) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true
      ? Duration.zero
      : duration;
}

/// 字体：界面黑体，正文/标题宋体，数字与正则等宽。
/// 界面黑体与宋体也用等宽数字（V41，G-069）：进度、计数、耗时变化时文字不左右晃。
const sansFamily = 'Desk Sans';
const serifFamily = 'Desk Serif';
const monoFamily = 'Desk Mono';
const deskFallback = ['Microsoft YaHei', 'Segoe UI'];

FontWeight _w(double w) =>
    FontWeight.values[((w / 100).round() - 1).clamp(0, 8)];

TextStyle ui(double size, {double w = 400, Color? c, double? h}) => TextStyle(
  fontFamily: sansFamily,
  fontFamilyFallback: deskFallback,
  fontSize: size,
  fontWeight: _w(w),
  fontVariations: [FontVariation('wght', w)],
  color: c,
  height: h,
  leadingDistribution: TextLeadingDistribution.even,
  fontFeatures: const [FontFeature.tabularFigures()],
);

TextStyle serif(double size, {double w = 400, Color? c, double? h}) =>
    TextStyle(
      fontFamily: serifFamily,
      fontFamilyFallback: deskFallback,
      fontSize: size,
      fontWeight: _w(w),
      fontVariations: [FontVariation('wght', w)],
      color: c,
      height: h,
      leadingDistribution: TextLeadingDistribution.even,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

TextStyle mono(double size, {Color? c, double w = 400}) => TextStyle(
  fontFamily: monoFamily,
  // 等宽字体不含汉字：混排中文时先回落到界面黑体。
  fontFamilyFallback: const [sansFamily, ...deskFallback],
  fontSize: size,
  fontWeight: _w(w),
  color: c,
  letterSpacing: -.1,
  fontFeatures: const [FontFeature.tabularFigures()],
);

enum Tone { pen, warn, info, ok, accent, neutral }

extension ToneColors on Desk {
  (Color, Color) tone(Tone t) => switch (t) {
    Tone.pen => (pen, penSoft),
    Tone.warn => (warn, warnSoft),
    Tone.info => (info, infoSoft),
    Tone.ok => (add, addSoft),
    Tone.accent => (accent, accentSoft),
    Tone.neutral => (ink2, sunken),
  };
}
