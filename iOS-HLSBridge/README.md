# 鼠标下载神器 iOS v0.8.5

- iOS 16+
- 内嵌 Safari Web Extension：`HLSBridgeSafariExtension`
- HLS 下载内核：后台 `URLSessionDownloadTask` + 手动解析 M3U8
- 输出：优先 MP4
- 工程：XcodeGen (`project.yml`)

云构建会生成 unsigned IPA，侧载工具安装时需要同时重签主 App 与 Safari App Extension。
