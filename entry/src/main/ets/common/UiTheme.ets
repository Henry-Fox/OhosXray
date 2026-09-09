/**
 * OhosXray UI 主题：跟随系统浅色/深色（base + dark 颜色资源，对齐 v0）。
 */
export class UiTheme {
  static readonly bg: Resource = $r('app.color.ui_bg');
  static readonly fg: Resource = $r('app.color.ui_fg');
  static readonly card: Resource = $r('app.color.ui_card');
  static readonly primary: Resource = $r('app.color.ui_primary');
  static readonly primaryFg: Resource = $r('app.color.ui_primary_fg');
  static readonly secondary: Resource = $r('app.color.ui_secondary');
  static readonly muted: Resource = $r('app.color.ui_muted');
  static readonly mutedFg: Resource = $r('app.color.ui_muted_fg');
  static readonly accent: Resource = $r('app.color.ui_accent');
  static readonly accentFg: Resource = $r('app.color.ui_accent_fg');
  static readonly destructive: Resource = $r('app.color.ui_destructive');
  static readonly border: Resource = $r('app.color.ui_border');
  static readonly warn: Resource = $r('app.color.ui_warn');
  static readonly primarySoft: Resource = $r('app.color.ui_primary_soft');
  static readonly destructiveSoft: Resource = $r('app.color.ui_destructive_soft');
  static readonly inputBg: Resource = $r('app.color.ui_input_bg');
  static readonly selectedBorder: Resource = $r('app.color.ui_selected_border');
  static readonly dotOff: Resource = $r('app.color.ui_dot_off');
  static readonly primaryDisabled: Resource = $r('app.color.ui_primary_disabled');
  static readonly errorBorder: Resource = $r('app.color.ui_error_border');
  static readonly radiusCard: number = 16;
  static readonly radiusPill: number = 999;
  static readonly radiusBtn: number = 16;
}