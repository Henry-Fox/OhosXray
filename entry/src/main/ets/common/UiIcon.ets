/**
 * 主题图标：media SVG + fillColor 着色（对齐 v0 图标用法）。
 */
@Component
export struct UiIcon {
  @Prop src: Resource = $r('app.media.ic_plus');
  @Prop iconSize: number = 18;
  @Prop color: ResourceColor = $r('app.color.ui_fg');

  build() {
    Image(this.src)
      .width(this.iconSize)
      .height(this.iconSize)
      .objectFit(ImageFit.Contain)
      .fillColor(this.color)
  }
}