import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0002;
const MAX_LOG_SIZE = 512 * 1024; // rotate (truncate) past 512KB

export class Logger {
  private static logFilePath: string = '';

  // Must be called once per process (main UIAbility and VPN extension each
  // run in their own process, but both resolve to the same sandbox file path).
  static init(context: common.Context): void {
    Logger.logFilePath = `${context.filesDir}/app.log`;
  }

  private static writeToFile(level: string, tag: string, msg: string): void {
    if (!Logger.logFilePath) return;
    try {
      let mode = fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND;
      if (fs.accessSync(Logger.logFilePath)) {
        const stat = fs.statSync(Logger.logFilePath);
        if (stat.size > MAX_LOG_SIZE) {
          mode = fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC;
        }
      }
      const file = fs.openSync(Logger.logFilePath, mode);
      const line = `${new Date().toISOString()} [${level}] [${tag}] ${msg}\n`;
      fs.writeSync(file.fd, line);
      fs.closeSync(file);
    } catch (_e) {
      // file logging is best-effort; hilog still captures the message
    }
  }

  static info(tag: string, msg: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', msg);
    Logger.writeToFile('INFO', tag, msg);
  }

  static warn(tag: string, msg: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', msg);
    Logger.writeToFile('WARN', tag, msg);
  }

  static error(tag: string, msg: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', msg);
    Logger.writeToFile('ERROR', tag, msg);
  }

  static readLogs(): string {
    if (!Logger.logFilePath) return '';
    try {
      if (!fs.accessSync(Logger.logFilePath)) return '(暂无日志)';
      return fs.readTextSync(Logger.logFilePath);
    } catch (_e) {
      return '(读取日志失败)';
    }
  }

  static clearLogs(): void {
    if (!Logger.logFilePath) return;
    try {
      if (fs.accessSync(Logger.logFilePath)) {
        fs.unlinkSync(Logger.logFilePath);
      }
    } catch (_e) {
      // ignore
    }
  }

  // JSON.stringify(new Error('x')) produces '{}' because Error's message/stack
  // are not own-enumerable properties. Use this in all catch blocks instead of
  // JSON.stringify(e) to actually capture the error content. ArkTS catch
  // variables are typed as Error (arkts-no-any-unknown forbids unknown/any).
  static stringifyError(e: Error): string {
    const businessError = e as BusinessError;
    const parts: string[] = [];
    if (e.name) parts.push(`name=${e.name}`);
    if (businessError.code !== undefined) parts.push(`code=${businessError.code}`);
    if (e.message) parts.push(`message=${e.message}`);
    let result = parts.length > 0 ? parts.join(', ') : '(no error detail)';
    if (e.stack) {
      result += ` stack=${e.stack}`;
    }
    return result;
  }
}
