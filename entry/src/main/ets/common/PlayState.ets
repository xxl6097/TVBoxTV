/**
 * 播放器主状态机（优化 #133）。
 *
 * 背景：Player.ets 里 playing / prepared / buffering / resolving / errMsg
 * 五个布尔散落在二十多处直接赋值，彼此可以任意组合，出现过的典型问题：
 *   - 能力提示 801 被当失败 → 画面在播却报「无法播放」并自动换台
 *   - 换集时 release 后残留的 buffering=true → 一直转圈
 *   - 缓冲结束事件晚于 completed → 错误态被覆盖成播放中
 *
 * 这里给出唯一的「主状态」和显式转移表：所有事件都必须经 reduce 校验，
 * 非法/重复事件保持原状态，不会再让散落的布尔互相打架。
 * 页面侧由 applyEv() 统一接入，并在每次真实转换时打一条状态轨迹日志，
 * 真机排障直接从日志就能还原「加载 → 就绪 → 播放 → 缓冲 → 错误」全过程。
 *
 * 注意：这是第一阶段。页面现有的五个布尔仍驱动 UI，主状态目前负责
 * 单一事实视图 + 转移校验 + 日志，避免一次性改动 3400 行引入回归。
 */
export class PlayState {
  /** 空闲：没有播放器实例 */
  static readonly IDLE: number = 0;
  /** 加载：解析地址 / 创建 AVPlayer / prepare 中 */
  static readonly LOADING: number = 1;
  /** 就绪：prepared，随时可 play */
  static readonly READY: number = 2;
  /** 播放中 */
  static readonly PLAYING: number = 3;
  /** 暂停 */
  static readonly PAUSED: number = 4;
  /** 缓冲中（可由加载/就绪/播放/暂停进入） */
  static readonly BUFFERING: number = 5;
  /** 失败：只能靠 EV_LOAD / EV_RESET 离开 */
  static readonly ERROR: number = 6;
  /** 播完：只能靠 EV_LOAD / EV_RESET 离开 */
  static readonly COMPLETED: number = 7;

  static readonly EV_LOAD: number = 0;
  static readonly EV_PREPARED: number = 1;
  static readonly EV_PLAY: number = 2;
  static readonly EV_PAUSE: number = 3;
  static readonly EV_BUFFER_START: number = 4;
  static readonly EV_BUFFER_END: number = 5;
  static readonly EV_ERROR: number = 6;
  static readonly EV_COMPLETE: number = 7;
  static readonly EV_RESET: number = 8;

  /**
   * 唯一的状态转移入口。返回新状态；非法或重复事件返回 cur。
   * EV_LOAD / EV_ERROR / EV_RESET 是全局事件（从任何状态都允许），
   * 因为重建、报错、销毁本来就可能发生在任意时刻。
   */
  static reduce(cur: number, ev: number): number {
    if (ev === PlayState.EV_RESET) {
      return PlayState.IDLE;
    }
    if (ev === PlayState.EV_LOAD) {
      return PlayState.LOADING;
    }
    if (ev === PlayState.EV_ERROR) {
      return PlayState.ERROR;
    }
    switch (cur) {
      case PlayState.IDLE:
      case PlayState.LOADING:
        if (ev === PlayState.EV_PREPARED) {
          return PlayState.READY;
        }
        if (ev === PlayState.EV_PLAY) {
          return PlayState.PLAYING;
        }
        if (ev === PlayState.EV_BUFFER_START) {
          return PlayState.BUFFERING;
        }
        return cur;
      case PlayState.READY:
        if (ev === PlayState.EV_PLAY) {
          return PlayState.PLAYING;
        }
        if (ev === PlayState.EV_PAUSE) {
          return PlayState.PAUSED;
        }
        if (ev === PlayState.EV_BUFFER_START) {
          return PlayState.BUFFERING;
        }
        if (ev === PlayState.EV_COMPLETE) {
          return PlayState.COMPLETED;
        }
        return cur;
      case PlayState.PLAYING:
        if (ev === PlayState.EV_PAUSE) {
          return PlayState.PAUSED;
        }
        if (ev === PlayState.EV_BUFFER_START) {
          return PlayState.BUFFERING;
        }
        if (ev === PlayState.EV_COMPLETE) {
          return PlayState.COMPLETED;
        }
        return cur;
      case PlayState.PAUSED:
        if (ev === PlayState.EV_PLAY) {
          return PlayState.PLAYING;
        }
        if (ev === PlayState.EV_BUFFER_START) {
          return PlayState.BUFFERING;
        }
        return cur;
      case PlayState.BUFFERING:
        // 缓冲结束由调用方按「缓冲前的状态」翻译成 EV_PLAY / EV_PAUSE
        if (ev === PlayState.EV_PLAY) {
          return PlayState.PLAYING;
        }
        if (ev === PlayState.EV_PAUSE) {
          return PlayState.PAUSED;
        }
        if (ev === PlayState.EV_PREPARED) {
          return PlayState.READY;
        }
        if (ev === PlayState.EV_COMPLETE) {
          return PlayState.COMPLETED;
        }
        return cur;
      case PlayState.ERROR:
      case PlayState.COMPLETED:
        // 终态：迟到的 playing / buffering 事件不能把错误或播完覆盖掉
        return cur;
      default:
        return cur;
    }
  }

  static label(s: number): string {
    switch (s) {
      case PlayState.IDLE:
        return 'IDLE';
      case PlayState.LOADING:
        return 'LOADING';
      case PlayState.READY:
        return 'READY';
      case PlayState.PLAYING:
        return 'PLAYING';
      case PlayState.PAUSED:
        return 'PAUSED';
      case PlayState.BUFFERING:
        return 'BUFFERING';
      case PlayState.ERROR:
        return 'ERROR';
      case PlayState.COMPLETED:
        return 'COMPLETED';
      default:
        return 'UNKNOWN';
    }
  }

  static eventLabel(ev: number): string {
    switch (ev) {
      case PlayState.EV_LOAD:
        return 'LOAD';
      case PlayState.EV_PREPARED:
        return 'PREPARED';
      case PlayState.EV_PLAY:
        return 'PLAY';
      case PlayState.EV_PAUSE:
        return 'PAUSE';
      case PlayState.EV_BUFFER_START:
        return 'BUFFER_START';
      case PlayState.EV_BUFFER_END:
        return 'BUFFER_END';
      case PlayState.EV_ERROR:
        return 'ERROR';
      case PlayState.EV_COMPLETE:
        return 'COMPLETE';
      case PlayState.EV_RESET:
        return 'RESET';
      default:
        return 'UNKNOWN';
    }
  }

  /** 处于「还在等数据」的阶段，UI 不该接受 seek / 换档等操作 */
  static isBusy(s: number): boolean {
    return s === PlayState.LOADING || s === PlayState.BUFFERING;
  }

  /** 只有解码器就绪之后 seek 才有意义 */
  static canSeek(s: number): boolean {
    return s === PlayState.READY || s === PlayState.PLAYING || s === PlayState.PAUSED;
  }

  static isError(s: number): boolean {
    return s === PlayState.ERROR;
  }

  /** 终态：错误 / 播完，只能重建或销毁 */
  static isTerminal(s: number): boolean {
    return s === PlayState.ERROR || s === PlayState.COMPLETED;
  }
}
