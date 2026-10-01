# 鼠标下载神器 v0.8.5

iOS 16+ 原生 HLS 下载器 + 内置 Safari Web Extension。

## v0.8.5 架构

- 不再需要 Userscripts / Stay / Tampermonkey。
- HLSBridge.app 内嵌 `HLSBridgeSafariExtension.appex`。
- Safari 扩展自动检测页面上的 MP4 / M3U8，并在右下角显示 🎬 入口。
- HLS 点击“下载到鼠标下载神器”后，通过 `hlsbridge://` 将 URL、候选清单、来源页 Referer/Origin、User-Agent 等信息交给 App。
- App 不再使用 `AVAssetDownloadURLSession` 离线打包 HLS；v0.8.5 改为手动解析 master/media playlist，并用后台 `URLSessionDownloadTask` 下载媒体分片。
- 支持 master playlist、最高码率 variant、独立 AUDIO group、EXT-X-MAP/fMP4、普通 TS/AAC 分片、BYTERANGE。
- 加密/DRM HLS 会明确拒绝，不尝试绕过。
- 分片下载完成后尝试以 AVFoundation 无损/尽量无重编码方式封装为 MP4。

## Safari 扩展第一次启用

安装并至少打开一次“鼠标下载神器”后：

1. iPhone 打开 **设置 → Safari → 扩展**。
2. 找到 **鼠标下载神器 视频检测**。
3. 开启扩展。
4. 网站访问权限设为“允许”（可按网站授权）。
5. 返回 Safari，刷新视频页面。

之后不再需要单独导入 `.user.js`。

> iOS 不允许 App 静默开启 Safari 扩展，因此“第一次手动开启扩展”无法省略。

## Windows + GitHub Actions 构建

仓库包含 `.github/workflows/build-ios.yml`。

Actions 会：

1. macOS runner 安装 XcodeGen。
2. 生成 `HLSBridge.xcodeproj`。
3. 编译 App + Safari Web Extension。
4. 验证 `.appex`、`manifest.json`、`content.js` 已嵌入。
5. 输出 `HLSBridge-unsigned.ipa`。

unsigned IPA 再使用 Sideloadly / AltStore / 爱思等可正确重签 App Extension 的工具安装。

## 当前注意点

- 后台 URLSession 可以在 App 被挂起后继续网络下载；如果用户从多任务界面强制杀死 App，系统行为会受 iOS 控制。
- 下载完成后的大文件合并需要 App 获得运行时间；如果后台阶段只完成了分片，重新打开“鼠标下载神器”后会继续合并。
- 这是 v0.8.5 第一版手动 HLS 内核。不同 CDN 的 HLS 方言很多，若某站点失败，请保留错误信息和 M3U8 类型继续适配。


## v0.8.5 下载性能优化

- App 在前台时改用低延迟普通 URLSession，默认 **视频 6 路 + 音频 2 路并发**。
- 切到后台/锁屏时自动把未完成分片切回系统 background URLSession，保留后台能力。
- 前后台切换只重做正在传输的少量分片，已经落盘的分片不会重下。
- 增加分片传输中的实时字节统计，速度显示不再只在一个分片落盘后跳动。
- 对超时、连接丢失、HTTP 429/5xx 做最多 3 次短退避重试。
- 前台不再一次向 background daemon 塞几十个小任务，降低 HLS 小分片之间的调度停顿。

## v0.8.5 合并修复

- 单流 fMP4（`EXT-X-MAP` 且无独立 AUDIO）直接按 `init + m4s` 顺序生成最终 MP4，不再经过 AVFoundation 二次打开/导出。
- 合并阶段增加文件存在、大小、可读性检查；失败会显示具体分片和错误域/错误码。
- 合并增加互斥，避免前台/后台 URLSession 同时触发两次最终合成。
- 分片和输出文件使用 `completeUntilFirstUserAuthentication` 文件保护，提升锁屏/后台完成后重新合成的可访问性。
- 已下载完成但合并失败的任务按钮显示“重新合成”；不会重新下载分片。


## v0.8.5 TS 合成修复

- 修复 `.ts` 分片全部下载完成后，先拼成 `combined-v.ts` 再由 AVFoundation 打开时出现 `Cannot Open [MouseDownloader.Merge 50]`。
- TS 不再整文件直接拼接后重开；新版逐个读取 TS 分片中的压缩 H.264/AAC sample，重建连续时间戳并用 `AVAssetWriter` 无损封装为 MP4/M4A，再生成最终 MP4。
- 不进行视频重新编码，速度主要受本地读盘/写盘影响。
- 已下载的 v0.8.x 分片继续兼容；覆盖安装后可直接点“重新合成”，无需重新下载。


## v0.8.5：FFmpeg 无损合成

最终 MP4 合成不再依赖 AVFoundation 去打开单个 HLS `.ts` 分片。传统 MPEG-TS HLS 使用 FFmpeg 的 concat demuxer + MOV/MP4 muxer，并使用 `-c copy` 无损封装；CMAF/fMP4 仍按 `init + m4s` 顺序组装，独立音轨交给 FFmpeg 做最终 mux。

本项目通过 Swift Package 引入 iOS FFmpeg XCFramework。这里只做 remux，不进行视频重编码。FFmpeg 本身的官方 `remux.c` 示例就是“读取一个容器的 packet 并原样写入另一个容器”的标准做法。

为了避免 iOS 在后台中途挂起 CPU 密集的最终封装，分片可继续由后台 URLSession 下载；如果分片在后台全部完成，最终 FFmpeg 合成会等到再次打开 App 后执行。
