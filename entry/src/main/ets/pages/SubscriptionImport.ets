import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ServerProfile } from '../model/ServerProfile';
import { serverStore } from '../common/ServerStore';
import { SubscriptionImportSession } from '../common/SubscriptionImportSession';
import { Logger } from '../common/Logger';
import { UiTheme } from '../common/UiTheme';
import { UiIcon } from '../common/UiIcon';

const TAG = 'SubscriptionImport';

/**
 * @param message 提示文案
 * @param duration 显示时长（毫秒）
 */
function showToast(message: string, duration: number = 2000): void {
  try {
    promptAction.showToast({ message: message, duration: duration });
  } catch (_e) {
  }
}

/**
 * 订阅预览页：勾选要导入的节点，确认后一次性写入节点库。
 */
@Entry
@Component
struct SubscriptionImport {
  @State profiles: ServerProfile[] = [];
  @State selected: boolean[] = [];
  @State invalidCount: number = 0;
  @State duplicateCount: number = 0;
  @State saving: boolean = false;

  async aboutToAppear(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await serverStore.init(context);
    const data = SubscriptionImportSession.take();
    if (!data) {
      showToast('订阅数据已失效，请重新获取');
      router.back();
      return;
    }
    this.profiles = data.profiles;
    this.selected = data.profiles.map((): boolean => true);
    this.invalidCount = data.invalidCount;
    this.duplicateCount = data.duplicateCount;
  }

  /**
   * @returns 已勾选数量
   */
  private selectedCount(): number {
    return this.selected.filter((v: boolean) => v).length;
  }

  /**
   * @param value true 全选，false 清空
   */
  private setAll(value: boolean): void {
    this.selected = this.profiles.map((): boolean => value);
  }

  /**
   * @param index 行号
   */
  private toggle(index: number): void {
    this.selected = this.selected.map((v: boolean, i: number) => i === index ? !v : v);
  }

  private async onImport(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (this.selectedCount() === 0) {
      showToast('请至少选择一个节点');
      return;
    }
    this.saving = true;
    try {
      const chosen = this.profiles.filter((_p: ServerProfile, i: number) => this.selected[i]);
      const summary = await serverStore.upsertServers(chosen);
      Logger.info(TAG, `imported: added=${summary.added} updated=${summary.updated} skipped=${summary.skipped}`);
      showToast(`新增 ${summary.added} · 更新 ${summary.updated} · 跳过 ${summary.skipped} · 无效 ${this.invalidCount}`,
        3000);
      router.back({ url: 'pages/Index' });
    } catch (e) {
      Logger.error(TAG, `import failed: ${Logger.stringifyError(e as Error)}`);
      showToast('导入失败，请重试');
    } finally {
      this.saving = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text('订阅导入')
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

      Column({ space: 12 }) {
        Column({ space: 4 }) {
          Text(`共 ${this.profiles.length} 个节点 · 已选 ${this.selectedCount()}/${this.profiles.length}`)
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
          if (this.invalidCount > 0 || this.duplicateCount > 0) {
            Text(`无效 ${this.invalidCount} 条 · 重复 ${this.duplicateCount} 条`)
              .fontSize(12).fontColor(UiTheme.mutedFg)
          }
        }
        .alignItems(HorizontalAlign.Start).width('100%')

        Row({ space: 8 }) {
          Button('全选', { type: ButtonType.Normal })
            .height(36).padding({ left: 16, right: 16 }).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.fg).borderRadius(12).backgroundColor(UiTheme.secondary)
            .onClick(() => this.setAll(true))
          Button('清空', { type: ButtonType.Normal })
            .height(36).padding({ left: 16, right: 16 }).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.fg).borderRadius(12).backgroundColor(UiTheme.secondary)
            .onClick(() => this.setAll(false))
        }
        .width('100%')

        List({ space: 10 }) {
          ForEach(this.profiles, (item: ServerProfile, index: number) => {
            ListItem() {
              Row({ space: 12 }) {
                Checkbox({ name: item.id })
                  .select(this.selected[index] === true)
                  .selectedColor(UiTheme.primary)
                  .hitTestBehavior(HitTestMode.None)
                Column({ space: 2 }) {
                  Text(item.remark)
                    .fontSize(15).fontWeight(FontWeight.Medium).fontColor(UiTheme.fg)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${item.protocol.toUpperCase()} · ${item.address}:${item.port}`)
                    .fontSize(12).fontColor(UiTheme.mutedFg).fontFamily('monospace')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
              }
              .width('100%').padding(16).backgroundColor(UiTheme.card)
              .borderRadius(UiTheme.radiusCard)
              .border({
                width: this.selected[index] === true ? 1.5 : 1,
                color: this.selected[index] === true ? UiTheme.selectedBorder : UiTheme.border
              })
              .onClick(() => this.toggle(index))
            }
          }, (item: ServerProfile) => item.id)
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Off)

        Button(this.saving ? '导入中…' : `导入所选（${this.selectedCount()}）`, { type: ButtonType.Normal })
          .width('100%').height(52).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(UiTheme.primaryFg).borderRadius(UiTheme.radiusBtn)
          .backgroundColor(this.selectedCount() > 0 && !this.saving ? UiTheme.primary : UiTheme.primaryDisabled)
          .enabled(this.selectedCount() > 0 && !this.saving)
          .onClick(() => { this.onImport(); })
      }
      .layoutWeight(1).width('100%').padding({ left: 20, right: 20, bottom: 28 })
    }
    .width('100%').height('100%').backgroundColor(UiTheme.bg)
  }
}
