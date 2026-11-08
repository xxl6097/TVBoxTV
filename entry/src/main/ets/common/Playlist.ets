import { Episode } from './Model';

/**
 * 当前播放列表（同一数据源、同一线路下的全部剧集）。
 *
 * 为什么不用 router 传参：几百集的名字和地址序列化后体积很大，且 router 参数
 * 有大小限制，容易在长剧上失败。播放页只关心「上一集 / 下一集」，用进程内
 * 单例共享最省事，退出播放页后由 clear() 释放。
 */
export class Playlist {
  private static eps: Episode[] = [];
  private static idx: number = 0;
  private static vodTitle: string = '';

  /** 进播放页前调用。传的是整条线路的剧集，idx 是当前集下标 */
  static set(eps: Episode[], idx: number, vodTitle: string): void {
    const copy: Episode[] = [];
    for (let i = 0; i < eps.length; i++) {
      const e = new Episode();
      e.name = eps[i].name;
      e.url = eps[i].url;
      for (let k = 0; k < eps[i].urls.length; k++) {
        e.urls.push(eps[i].urls[k]);
      }
      copy.push(e);
    }
    Playlist.eps = copy;
    Playlist.idx = (idx >= 0 && idx < copy.length) ? idx : 0;
    Playlist.vodTitle = vodTitle;
  }

  static clear(): void {
    Playlist.eps = [];
    Playlist.idx = 0;
    Playlist.vodTitle = '';
  }

  static count(): number {
    return Playlist.eps.length;
  }

  static index(): number {
    return Playlist.idx;
  }

  static title(): string {
    return Playlist.vodTitle;
  }

  static current(): Episode | null {
    if (Playlist.idx < 0 || Playlist.idx >= Playlist.eps.length) {
      return null;
    }
    return Playlist.eps[Playlist.idx];
  }

  static hasNext(): boolean {
    return Playlist.idx + 1 < Playlist.eps.length;
  }

  static hasPrev(): boolean {
    return Playlist.idx > 0;
  }

  /** 游标前后移动一格；到头返回 null（游标不变） */
  static step(delta: number): Episode | null {
    const t: number = Playlist.idx + delta;
    if (t < 0 || t >= Playlist.eps.length) {
      return null;
    }
    Playlist.idx = t;
    return Playlist.eps[t];
  }

  /** 获取下一集（不改游标） */
  static nextEpisode(): Episode | null {
    const t: number = Playlist.idx + 1;
    if (t < 0 || t >= Playlist.eps.length) {
      return null;
    }
    return Playlist.eps[t];
  }
}
