# v0.8.5 合成方案验证

本版不再自写 MPEG-TS 解析器，也不再依赖 AVFoundation 打开单个 HLS `.ts` 分片。

## 使用的成熟方案

- MPEG-TS → MP4：FFmpeg concat demuxer + MP4/MOV muxer，`-c copy`，不重编码。
- AAC/ADTS → MP4/M4A：由 FFmpeg 的 MOV/MP4 muxer自动插入 `aac_adtstoasc` bitstream filter。
- CMAF/fMP4：同一 rendition 的 `init + m4s` 顺序组装；独立音视频轨再由 FFmpeg `-c copy` mux。

## 本地实际验证

在 FFmpeg 7.1.5 上实际生成 HLS 测试素材并运行与 App 相同的核心命令：

1. H.264 + AAC 同一 MPEG-TS HLS：成功生成 MP4；ffprobe 识别到 H.264 video + AAC audio。
2. 视频 TS 与独立音频 TS：分别使用 concat demuxer作为两个输入，再 `-map 0:v -map 1:a -c copy`：成功生成 MP4；ffprobe 识别到 H.264 video + AAC audio。
3. CMAF/fMP4：`init.mp4 + seg*.m4s` 顺序组装后，ffprobe 正常识别 H.264 video + AAC audio。

注意：容器内无法运行 Xcode/iOS 真机，因此 Swift Package 集成和最终 IPA 仍需要 GitHub Actions 的 macOS/Xcode 构建验证。
