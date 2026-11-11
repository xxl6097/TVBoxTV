import { Cms } from './Cms';

/**
 * 把「网页地址」换成「能直接播的流地址」。
 *
 * 采集站常见的坑：第一组线路给的是 https://cdn/play/AbCd1234（网页，靠 hls.js 播），
 * 真流是 https://cdn/play/AbCd1234/index.m3u8。判据是最后一段没有扩展名。
 *
 * 从 Player.ets 抽出来的纯函数：不碰 UI 状态，方便单独复用与排查。
 */
export function fixPlayable(u: string): string {
  if (u.length === 0 || Cms.isDirect(u)) {
    return u;
  }
  if (u.indexOf('://') < 0) {
    return u;
  }
  const noQuery: string = u.split('?')[0].replace(/\/+$/, '');
  const last: string = noQuery.substring(noQuery.lastIndexOf('/') + 1);
  if (last.length > 0 && last.indexOf('.') < 0) {
    return noQuery + '/index.m3u8';
  }
  return u;
}
