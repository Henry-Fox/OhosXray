import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

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
        Text('日志').fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('返回').onClick(() => router.back())
      }
      .width('100%')
      .padding(16)

      Row({ space: 12 }) {
        Button('刷新').onClick(() => this.refresh())
        Button('复制全部').onClick(() => { this.copyToClipboard(); })
        Button('清空').fontColor('#E74C3C').onClick(() => this.clear())
      }
      .padding({ left: 16, right: 16, bottom: 8 })

      Scroll() {
        Text(this.logText)
          .fontSize(11)
          .fontFamily('monospace')
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding(12)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#F5F5F5')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }
}
