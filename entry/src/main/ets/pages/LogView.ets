import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { UiTheme } from '../common/UiTheme';
import { UiIcon } from '../common/UiIcon';

@Entry
@Component
struct LogView {
  @State logText: string = '';

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    Logger.init(context);
    this.refresh();
  }

  private refresh(): void {
    this.logText = Logger.readLogs();
  }

  private async copyToClipboard(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '已复制到剪贴板', duration: 1500 });
    } catch (e) {
      promptAction.showToast({ message: `复制失败: ${Logger.stringifyError(e)}`, duration: 2000 });
    }
  }

  private clear(): void {
    Logger.clearLogs();
    this.refresh();
  }

  build() {
    Column() {
      Row() {
        Text('日志').fontSize(24).fontWeight(FontWeight.Bold).fontColor(UiTheme.fg).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            UiIcon({ src: $r('app.media.ic_back'), iconSize: 16, color: UiTheme.fg })
            Text('返回').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
          }
        }
        .height(36).padding({ left: 14, right: 14 })
        .borderRadius(UiTheme.radiusPill).backgroundColor(UiTheme.secondary)
        .onClick(() => router.back())
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 12 })

      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            UiIcon({ src: $r('app.media.ic_refresh'), iconSize: 15, color: UiTheme.fg })
            Text('刷新').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
          }
        }
        .layoutWeight(1).height(40).borderRadius(12).backgroundColor(UiTheme.secondary)
        .onClick(() => this.refresh())

        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            UiIcon({ src: $r('app.media.ic_copy'), iconSize: 15, color: UiTheme.accentFg })
            Text('复制全部').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.accentFg)
          }
        }
        .layoutWeight(1).height(40).borderRadius(12).backgroundColor(UiTheme.accent)
        .onClick(() => { this.copyToClipboard(); })

        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            UiIcon({ src: $r('app.media.ic_trash'), iconSize: 15, color: UiTheme.primaryFg })
            Text('清空').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.primaryFg)
          }
        }
        .layoutWeight(1).height(40).borderRadius(12).backgroundColor(UiTheme.destructive)
        .onClick(() => this.clear())
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 12 })

      Scroll() {
        Text(this.logText.length > 0 ? this.logText : '暂无日志')
          .fontSize(11).fontFamily('monospace')
          .fontColor(this.logText.length > 0 ? UiTheme.fg : UiTheme.mutedFg)
          .width('100%').textAlign(TextAlign.Start).padding(16)
      }
      .layoutWeight(1).width('100%')
      .margin({ left: 20, right: 20, bottom: 28 })
      .borderRadius(UiTheme.radiusCard)
      .border({ width: 1, color: UiTheme.border })
      .backgroundColor(UiTheme.card)
      .align(Alignment.TopStart)
      .clip(true)
    }
    .width('100%').height('100%').backgroundColor(UiTheme.bg)
  }
}