import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ServerProfile, createEmptyProfile } from '../model/ServerProfile';
import { parseShareLink } from '../model/LinkParser';
import { serverStore } from '../common/ServerStore';
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

  async aboutToAppear(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await serverStore.init(context);

    const params = router.getParams() as EditRouterParams | null;
    if (params && params.profileId) {
      this.editingId = params.profileId;
      const profile = await serverStore.getServerById(this.editingId);
      if (profile) {
        // Restore original link if available, so user can see / modify it
        this.linkText = profile.originalLink ?? '';
        if (this.linkText) {
          this.onParse();
        } else {
          // Show parsed details even without the original link
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
      Logger.error(TAG, `paste failed: ${Logger.stringifyError(e)}`);
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
    // Keep the existing ID when editing, assign new UUID when adding
    if (this.editingId) {
      profile.id = this.editingId;
    } else if (!profile.id) {
      profile.id = util.generateRandomUUID();
    }
    // Persist original link for future editing
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
