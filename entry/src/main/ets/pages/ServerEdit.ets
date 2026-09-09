import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { vibrator } from '@kit.SensorServiceKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { ServerProfile } from '../model/ServerProfile';
import { parseShareLink } from '../model/LinkParser';
import { serverStore } from '../common/ServerStore';
import { ScanImportHelper } from '../common/ScanImportHelper';
import { Logger } from '../common/Logger';
import { UiTheme } from '../common/UiTheme';
import { UiIcon } from '../common/UiIcon';
import { util } from '@kit.ArkTS';

const TAG = 'ServerEdit';

interface EditRouterParams {
  profileId?: string;
}

@Entry
@Component
struct ServerEdit {
  @State linkText: string = '';
  @State preview: ServerProfile | null = null;
  @State errorMsg: string = '';
  private editingId: string = '';
  private scanning: boolean = false;

  async aboutToAppear(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await serverStore.init(context);
    const params = router.getParams() as EditRouterParams | null;
    if (params && params.profileId) {
      this.editingId = params.profileId;
      const profile = await serverStore.getServerById(this.editingId);
      if (profile) {
        this.linkText = profile.originalLink ?? '';
        if (this.linkText) {
          this.onParse();
        } else {
          this.preview = profile;
        }
      }
    }
  }

  private async onPasteFromClipboard(): Promise<void> {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getData();
      const text = data.getPrimaryText();
      if (text) {
        this.linkText = text;
        this.onParse();
      }
    } catch (e) {
      Logger.error(TAG, `paste failed: ${Logger.stringifyError(e as Error)}`);
      this.errorMsg = '无法读取剪贴板，请手动粘贴';
    }
  }

  /**
   * 使用系统 Scan Kit 扫码（含相册），成功后直接入库并返回列表。
   */
  private async onScanQr(): Promise<void> {
    if (this.scanning) {
      return;
    }
    if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
      this.errorMsg = '当前设备不支持系统扫码能力';
      return;
    }
    this.scanning = true;
    this.errorMsg = '';
    const context = getContext(this) as common.UIAbilityContext;
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: false,
      enableAlbum: true
    };
    try {
      const data = await scanBarcode.startScanForResult(context, options);
      const raw = data?.originalValue ?? '';
      Logger.info(TAG, `ScanKit result len=${raw.length}`);
      const result = await ScanImportHelper.saveFromLink(context, raw, this.editingId);
      if (!result.ok) {
        this.errorMsg = result.message ?? '扫码内容无法导入';
        try {
          promptAction.showToast({ message: this.errorMsg, duration: 2500 });
        } catch (_e) {
        }
        return;
      }
      this.playScanSuccessFeedback();
      try {
        promptAction.showToast({ message: result.message ?? '已保存', duration: 2000 });
      } catch (_e) {
      }
      router.back();
    } catch (e) {
      const err = e as BusinessError;
      if (err && typeof err.code === 'number' && err.code !== 0) {
        Logger.warn(TAG, `ScanKit failed: code=${err.code} msg=${err.message}`);
        const msg = `${err.message ?? ''}`;
        if (msg.toLowerCase().indexOf('cancel') < 0 && msg.indexOf('取消') < 0) {
          this.errorMsg = `扫码失败: ${err.message ?? err.code}`;
        }
      } else {
        Logger.warn(TAG, `ScanKit throw: ${Logger.stringifyError(e as Error)}`);
      }
    } finally {
      this.scanning = false;
    }
  }

  private playScanSuccessFeedback(): void {
    try {
      vibrator.startVibration({
        type: 'time',
        duration: 80
      }, {
        usage: 'notification'
      }).catch((e: BusinessError) => {
        Logger.warn(TAG, `vibrator failed: code=${e.code}`);
      });
    } catch (e) {
      Logger.warn(TAG, `vibrator throw: ${Logger.stringifyError(e as Error)}`);
    }
  }

  private onParse(): void {
    this.errorMsg = '';
    this.preview = null;
    try {
      this.preview = parseShareLink(this.linkText);
    } catch (e) {
      this.errorMsg = e instanceof Error ? e.message : '链接无效，请粘贴 vmess:// 或 vless:// 开头的分享链接';
    }
  }

  private async onSave(): Promise<void> {
    if (!this.preview) {
      this.errorMsg = '请先解析出有效节点再保存';
      return;
    }
    const profile: ServerProfile = this.preview;
    if (this.editingId) {
      profile.id = this.editingId;
    } else if (!profile.id) {
      profile.id = util.generateRandomUUID();
    }
    profile.originalLink = this.linkText;
    await serverStore.upsertServer(profile);
    router.back();
  }

  build() {
    Column() {
      Row() {
        Text(this.editingId ? '编辑节点' : '添加节点')
          .fontSize(24).fontWeight(FontWeight.Bold).fontColor(UiTheme.fg).layoutWeight(1)
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

      Column({ space: 20 }) {
        Column({ space: 8 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              UiIcon({ src: $r('app.media.ic_scan'), iconSize: 20, color: UiTheme.primaryFg })
              Text('扫码添加').fontSize(16).fontWeight(FontWeight.Bold).fontColor(UiTheme.primaryFg)
            }
          }
          .width('100%').height(52).borderRadius(UiTheme.radiusBtn).backgroundColor(UiTheme.primary)
          .onClick(() => { this.onScanQr(); })

          Row({ space: 6 }) {
            UiIcon({ src: $r('app.media.ic_qr'), iconSize: 14, color: UiTheme.mutedFg })
            Text('使用系统扫码（支持相册选图）').fontSize(12).fontColor(UiTheme.mutedFg)
          }
          .width('100%')
        }

        Row() {
          Divider().layoutWeight(1).color(UiTheme.border)
          Text('或粘贴分享链接').fontSize(12).fontWeight(FontWeight.Medium).fontColor(UiTheme.mutedFg)
            .margin({ left: 12, right: 12 })
          Divider().layoutWeight(1).color(UiTheme.border)
        }
        .width('100%').alignItems(VerticalAlign.Center)

        Column({ space: 12 }) {
          Column() {
            Row({ space: 6 }) {
              UiIcon({ src: $r('app.media.ic_link'), iconSize: 14, color: UiTheme.mutedFg })
              Text('分享链接').fontSize(12).fontWeight(FontWeight.Medium).fontColor(UiTheme.mutedFg)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 8 })
            .border({ width: { bottom: 1 }, color: UiTheme.border })

            TextArea({ placeholder: '粘贴 vmess:// 或 vless:// 分享链接', text: this.linkText })
              .height(110).width('100%').fontSize(13).fontFamily('monospace')
              .fontColor(UiTheme.fg).backgroundColor(Color.Transparent)
              .padding({ left: 16, right: 16, top: 10, bottom: 12 })
              .onChange((value: string) => {
                this.linkText = value;
                this.errorMsg = '';
                this.preview = null;
              })
          }
          .width('100%')
          .borderRadius(UiTheme.radiusCard)
          .border({ width: 1, color: this.errorMsg ? UiTheme.errorBorder : UiTheme.border })
          .backgroundColor(UiTheme.inputBg)

          Row({ space: 8 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                UiIcon({ src: $r('app.media.ic_clipboard'), iconSize: 16, color: UiTheme.fg })
                Text('从剪贴板粘贴').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
              }
            }
            .layoutWeight(1).height(44).borderRadius(12).backgroundColor(UiTheme.secondary)
            .onClick(() => { this.onPasteFromClipboard(); })

            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                UiIcon({ src: $r('app.media.ic_sparkles'), iconSize: 16, color: UiTheme.accentFg })
                Text('解析').fontSize(13).fontWeight(FontWeight.Medium).fontColor(UiTheme.accentFg)
              }
            }
            .layoutWeight(1).height(44).borderRadius(12).backgroundColor(UiTheme.accent)
            .enabled(this.linkText.trim().length > 0)
            .opacity(this.linkText.trim().length > 0 ? 1 : 0.4)
            .onClick(() => { this.onParse(); })
          }
          .width('100%')

          if (this.errorMsg) {
            Text(this.errorMsg)
              .fontSize(12).fontColor(UiTheme.destructive).width('100%')
              .padding(12).borderRadius(12).backgroundColor(UiTheme.destructiveSoft)
          }

          if (this.preview) {
            Column({ space: 4 }) {
              Text('解析成功').fontSize(12).fontWeight(FontWeight.Medium).fontColor(UiTheme.primary)
              Text(this.preview.remark)
                .fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${this.preview.protocol.toUpperCase()} · ${this.preview.address}:${this.preview.port}`)
                .fontSize(12).fontColor(UiTheme.mutedFg).fontFamily('monospace')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`传输 ${this.preview.network} · TLS ${this.preview.tls}`)
                .fontSize(12).fontColor(UiTheme.mutedFg)
            }
            .alignItems(HorizontalAlign.Start).width('100%').padding(16)
            .borderRadius(UiTheme.radiusCard)
            .border({ width: 1, color: UiTheme.selectedBorder })
            .backgroundColor(UiTheme.primarySoft)
          }

          if (this.editingId && !this.linkText) {
            Text('提示：没有保存原始链接，请重新粘贴链接后保存')
              .fontSize(12).fontColor(UiTheme.warn).width('100%')
          }
        }

        Blank()

        Button(this.editingId ? '保存修改' : '保存', { type: ButtonType.Normal })
          .width('100%').height(52).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(UiTheme.primaryFg).borderRadius(UiTheme.radiusBtn)
          .backgroundColor(this.preview !== null ? UiTheme.primary : UiTheme.primaryDisabled)
          .enabled(this.preview !== null)
          .onClick(() => { this.onSave(); })
      }
      .layoutWeight(1).width('100%').padding({ left: 20, right: 20, bottom: 28 })
    }
    .width('100%').height('100%').backgroundColor(UiTheme.bg)
  }
}