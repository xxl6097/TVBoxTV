/**
 * 播放器错误码翻译与「能力提示」判定。
 *
 * 从 Player.ets 抽出来：这几个函数是纯映射，不依赖组件状态，
 * 放在页面文件里既撑行数，也没法在别处复用（如直播探测、日志面板）。
 */

/**
 * 判断这条 error 是不是系统播放器的「能力提示」而非播放失败。
 *
 * 801 = 「直播流不支持变速」，是 prepared 阶段的能力提示，紧接着就会
 * state=playing、画面正常出。之前把它当失败，导致「画面在播却提示
 * 无法播放、自动换台」（实测 CCTV6/iFan 等多数源每次进入都发，
 * CCTV1 的源编码不同不发这条）。同类 not support 文案同样按提示处理。
 */
export function isCapabilityHint(code: number, msg: string, isLive: boolean): boolean {
  if (code === 801) {
    return true;
  }
  return isLive && /not support/i.test(msg);
}

/**
 * 把播放器底层错误码/错误消息转成用户能看懂的中文。
 * 鸿蒙 AVPlayer 的错误码体系：
 *  - 5400101：格式/编码不支持
 *  - 5400102：网络连接/数据源打不开
 *  - 5400103：I/O 读取失败（包括 HLS 分片 403/404）
 *  - 5400104：流中断/数据结束异常
 *  - 5400105：超时（seek 超时、缓冲超时）
 *  - 5400106：解码失败
 *  - 801：能力提示，本函数不会被调用（isCapabilityHint 已提前拦掉）
 */
export function friendlyErr(code: number, msg: string): string {
  if (code === 5400101) {
    return '不支持此视频格式或编码，可尝试其他线路';
  }
  if (code === 5400102) {
    const m: string = msg.toLowerCase();
    if (m.indexOf('403') >= 0) {
      return '播放地址被拒绝（403），源站可能有防盗链';
    }
    if (m.indexOf('404') >= 0) {
      return '播放地址不存在（404），此资源可能已下线';
    }
    return '无法打开视频源，地址可能已失效';
  }
  if (code === 5400103) {
    return '视频数据读取失败，网络不稳定或资源已损坏';
  }
  if (code === 5400104) {
    return '视频流异常中断，请重试';
  }
  if (code === 5400105) {
    return '播放超时，请检查网络后重试';
  }
  if (code === 5400106) {
    /**
     * 5400106 实际包含两类完全不同的失败，原来看消息里的关键字才能分开：
     *  - CONTAINER_ERR：连容器都解不开（avi/rmvb/wmv/flv 等）。系统播放器
     *    只支持 mp4/mkv/ts，这才是网盘/本地文件最常见的情况。
     *  - 解码失败：容器能开，但编码不支持（如个别 H.265/10bit）。
     * 原来一律说「硬件不支持」，会把「格式选错了」误导成「手机不行」。
     */
    if (/CONTAINER_ERR|container format/i.test(msg)) {
      return '系统播放器打不开这个视频的封装格式，转成 MP4 后可播放';
    }
    return '视频解码失败，可能硬件不支持此规格';
  }
  // 通用后备：只显示简短的原始信息，不暴露底层堆栈
  const first: string = msg.split('\n')[0];
  return '播放失败（' + code + '）：' + (first.length > 80 ? first.substring(0, 80) + '…' : first);
}
