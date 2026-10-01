import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Safari 扩展") {
                    Label("视频检测脚本已内置在鼠标下载神器中", systemImage: "safari")
                    Text("首次安装后只需前往：设置 → Safari → 扩展 → 鼠标下载神器 视频检测，并允许需要的网站。以后不再需要 Userscripts / Stay。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("打开视频网页并播放几秒，页面右下角会出现 🎬 悬浮入口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("下载引擎") {
                    Label(manager.foregroundTurboEnabled ? "极速前台模式：视频 6 路 + 音频 2 路" : "系统后台模式：任务由 iOS 托管",
                          systemImage: manager.foregroundTurboEnabled ? "bolt.fill" : "moon.zzz.fill")
                    Text("前台使用低延迟并发会话；切到其他 App/锁屏时自动把未完成分片切换到后台 URLSession。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("最终合成使用 FFmpeg -c copy 无损封装；MPEG-TS 不再交给 AVFoundation 逐分片解析。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("下载任务") {
                    if manager.items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 42))
                                .foregroundStyle(.secondary)
                            Text("暂无下载")
                                .font(.headline)
                            Text("Safari 扩展检测到 HLS 后，点击“下载到鼠标下载神器”。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else {
                        ForEach(manager.items) { item in
                            taskRow(item)
                        }
                    }
                }
            }
            .navigationTitle("鼠标下载神器")
            .sheet(item: Binding(
                get: { shareURL.map(ShareURL.init) },
                set: { shareURL = $0?.url }
            )) { wrapper in
                ShareSheet(items: [wrapper.url])
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ item: HLSDownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.headline).lineLimit(2)
            if let selected = item.selectedURL {
                Text(selected).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            ProgressView(value: item.progress)
            HStack {
                Text(stateText(item))
                Spacer()
                if item.speedBytesPerSecond > 0 { Text(byteText(item.speedBytesPerSecond) + "/s") }
                Text("\(Int(item.progress * 100))%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if item.totalSegments > 0 {
                Text("分片 \(item.completedSegments) / \(item.totalSegments) · 已落盘 \(byteText(Double(item.bytesReceived)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let probe = item.probeInfo, !probe.isEmpty {
                Text(probe).font(.caption2).foregroundStyle(.secondary)
            }
            if let error = item.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if item.state == .downloading || item.state == .preparing {
                    Button("暂停") { manager.pause(item.id) }
                } else if item.state == .paused || item.state == .failed {
                    Button(item.state == .failed && item.completedSegments >= item.totalSegments && item.totalSegments > 0 ? "重新合成" : "继续") { manager.resume(item.id) }
                }
                if manager.shareURL(item.id) != nil {
                    Button("分享/存文件") { shareURL = manager.shareURL(item.id) }
                }
                Spacer()
                Button("删除", role: .destructive) { manager.remove(item.id) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func stateText(_ item: HLSDownloadItem) -> String {
        switch item.state {
        case .queued: return "等待"
        case .preparing: return "解析 HLS"
        case .downloading: return manager.foregroundTurboEnabled ? "极速分片下载" : "后台分片下载"
        case .paused: return "已暂停"
        case .merging: return "正在合并 MP4"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }

    private func byteText(_ value: Double) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(value))
    }
}

private struct ShareURL: Identifiable {
    let id = UUID()
    let url: URL
    init(_ url: URL) { self.url = url }
}
