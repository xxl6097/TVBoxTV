/**
 * 构建信息 —— 由 scripts/lib/harmony-env.sh 的 hv_write_build_info() 在**编译前**覆写，
 * 编译结束后自动还原成本文件里的默认值。所以手改这里没有意义：下一次打包就覆盖了。
 *
 * 为什么要单独一个文件：
 *   · 编译时间只有在打包那一刻才知道，写死在业务代码里必然过期；
 *   · 读 hap 的 installTime 拿到的是「安装时间」，重装/降级都会变，不是编译时间；
 *   · 用生成源码的方式，运行时零成本（常量），也不用加权限、不用额外资源文件。
 *
 * 仓库里这份默认值的作用只有一个：没走构建脚本（比如 DevEco 直接点运行）时也能编译通过。
 */
export class BuildInfo {
  /** 打包时的版本号，与 AppScope/app.json5 的 versionName 一致 */
  static readonly VERSION: string = '1.1.1';
  /** versionCode，每次打包 +1 */
  static readonly VERSION_CODE: number = 1000009;
  /** 编译时间，本地时区，形如 2026-11-28 11:55:07；空串表示不是脚本打包出来的 */
  static readonly BUILT_AT: string = '';
  /** 构建模式：debug / release */
  static readonly BUILD_MODE: string = 'debug';
}
