export interface XrayBridgeNative {
  /**
   * 启动Xray核心。tunFd 是已经创建好的TUN设备文件描述符（数字形式的fd），
   * native层会在调用Go导出的XrayStart前把它写入环境变量供tun inbound读取。
   * 返回空字符串表示成功，否则返回错误信息。
   */
  start(configJson: string, tunFd: number): string;

  /** 停止Xray核心，关闭所有连接 */
  stop(): void;

  /** 当前是否在运行 */
  isRunning(): boolean;

  /** 查询指定outbound tag的流量统计，返回形如 {"uplink":123,"downlink":456} 的JSON字符串 */
  queryStats(tag: string): string;
}

declare const xraybridge: XrayBridgeNative;
export default xraybridge;
