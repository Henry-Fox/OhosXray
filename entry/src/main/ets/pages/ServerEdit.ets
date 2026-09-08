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
          // ignore
        }
        return;
      }

      this.playScanSuccessFeedback();
      try {
        promptAction.showToast({ message: result.message ?? '已保存', duration: 2000 });
      } catch (_e) {
        // ignore
      }
      router.back();
    } catch (e) {
      const err = e as BusinessError;
      // 用户取消通常不提示；其它错误给出原因
      if (err && typeof err.code === 'number' && err.code !== 0) {
        Logger.warn(TAG, `ScanKit failed: code=${err.code} msg=${err.message}`);
        // 常见取消码：1010500001 / 1000500001 等，文案含 cancel 则静默
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
      this.errorMsg = e instanceof Error ? e.message : '解析失败';
    }
  }

  private async onSave(): Promise<void> {
    if (!this.preview) {
      this.errorMsg = '请先粘贴并解析一个有效的链接';
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
    Column({ space: 16 }) {
      Row() {
        Text(this.editingId ? '编辑节点' : '添加节点')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('返回').onClick(() => router.back())
      }
      .width('100%')
      .padding(16)

      Column({ space: 8 }) {
        Button('扫码添加')
          .width('100%')
          .height(48)
          .fontSize(16)
          .backgroundColor('#2ECC71')
          .onClick(() => {
            this.onScanQr();
          })

        Text('使用系统扫码（支持相册选图）')
          .fontSize(12)
          .fontColor('#999999')
          .width('100%')

        Text('或粘贴分享链接')
          .fontSize(12)
          .fontColor('#999999')
          .width('100%')
          .margin({ top: 8 })

        TextArea({ placeholder: '粘贴 vmess:// 或 vless:// 分享链接', text: this.linkText })
          .height(100)
          .width('100%')
          .onChange((value: string) => {
            this.linkText = value;
          })

        Row({ space: 12 }) {
          Button('从剪贴板粘贴').onClick(() => this.onPasteFromClipboard())
          Button('解析').onClick(() => this.onParse())
        }

        if (this.errorMsg) {
          Text(this.errorMsg).fontColor('#E74C3C').fontSize(13)
        }

        if (this.preview) {
          Column({ space: 4 }) {
            Text(`备注：${this.preview.remark}`)
            Text(`协议：${this.preview.protocol}`)
            Text(`地址：${this.preview.address}:${this.preview.port}`)
            Text(`传输：${this.preview.network}  TLS：${this.preview.tls}`)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .backgroundColor('#F5F5F5')
          .borderRadius(8)
        }

        if (this.editingId && !this.linkText) {
          Text('提示：没有保存原始链接，请重新粘贴链接后保存')
            .fontSize(12)
            .fontColor('#E67E22')
            .padding({ top: 4 })
        }
      }
      .width('90%')

      Button(this.editingId ? '保存修改' : '保存')
        .width('90%')
        .height(48)
        .enabled(this.preview !== null)
        .onClick(() => this.onSave())
    }
    .width('100%')
    .height('100%')
  }
}
