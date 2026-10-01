import Foundation
import Combine
import UIKit
import ffmpegkit

private struct StoredPlan: Codable {
    var masterURL: String
    var videoPlaylistURL: String
    var audioPlaylistURL: String?
    var videoInit: HLSSegment?
    var videoSegments: [HLSSegment]
    var audioInit: HLSSegment?
    var audioSegments: [HLSSegment]
    var resolution: String?
    var bandwidth: Int?
}

private enum TrackKind: String { case video = "v", audio = "a" }

final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    // Lazy singleton: avoid constructing the manager before SwiftUI finishes booting.
    static var shared: DownloadManager {
        struct Holder { static let instance = DownloadManager() }
        return Holder.instance
    }
    static let backgroundIdentifier = "local.hlsbridge.manual-hls.v080"

    @Published private(set) var items: [HLSDownloadItem] = []
    @Published private(set) var foregroundTurboEnabled = false
    var backgroundEventsCompletionHandler: (() -> Void)?

    private let fm = FileManager.default
    private let storeURL: URL
    private let jobsRoot: URL
    private var idByTaskIdentifier: [Int: UUID] = [:]
    private var activeTaskKeys = Set<String>()
    private var finalizeInFlight = Set<UUID>()
    private let finalizeLock = NSLock()
    private var lastSpeedSample: [UUID: (Date, Int64)] = [:]
    private var speedTimer: Timer?
    private var liveBytesByTask: [Int: Int64] = [:]
    private var retryCountByKey: [String: Int] = [:]
    private var retryNotBeforeByKey: [String: Date] = [:]
    private var appIsActive = false

    // Foreground: use a normal URLSession for low-latency HLS segment fetching.
    // Background: hand the remaining work to the system background session.
    private let turboVideoConcurrency = 6
    private let turboAudioConcurrency = 2
    private let backgroundVideoQueued = 18
    private let backgroundAudioQueued = 6

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 12
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: q)
    }()

    private lazy var turboSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60 * 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        if #available(iOS 13.0, *) { config.networkServiceType = .responsiveData }
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: q)
    }()

    override private init() {
        // Avoid a launch crash if the Application Support directory is temporarily unavailable.
        // This can happen during first launch after install/restore on iOS.
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        jobsRoot = appSupport.appendingPathComponent("HLSJobs", isDirectory: true)
        storeURL = appSupport.appendingPathComponent("downloads-v080.json")

        do {
            try fm.createDirectory(at: jobsRoot, withIntermediateDirectories: true)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                 ofItemAtPath: jobsRoot.path)
        } catch {
            NSLog("HLSBridge storage init failed: %@", error.localizedDescription)
        }

        super.init()

        // Delay recovery work until the app has completed its first run loop.
        // Prevents startup crashes caused by restoring old download state too early.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loadStore()
            self.reconnectBackgroundTasks()
            self.startSpeedTimer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.resumePendingWork()
            }
        }
    }

    // MARK: Incoming bridge
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "hlsbridge" else { return }
        if url.host?.lowercased() == "manager" { return }
        guard url.host?.lowercased() == "add",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: { $0.name == "p" })?.value,
              let payload = decodePayload(encoded) else { return }
        add(payload)
    }

    private func decodePayload(_ value: String) -> HLSIncomingPayload? {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return try? JSONDecoder().decode(HLSIncomingPayload.self, from: data)
    }

    func add(_ payload: HLSIncomingPayload) {
        guard let primary = URL(string: payload.url), ["http", "https"].contains(primary.scheme?.lowercased() ?? "") else { return }
        let candidates = ([payload.url] + (payload.candidates ?? [])).reduce(into: [String]()) { out, value in
            if !out.contains(value) { out.append(value) }
        }

        if let i = items.firstIndex(where: { sameMediaURL($0.sourceURL, payload.url) && $0.state != .completed }) {
            DispatchQueue.main.async {
                self.items[i].candidateURLs = candidates
                self.items[i].userAgent = payload.userAgent
                self.items[i].pageURL = payload.pageUrl
                self.items[i].pageOrigin = payload.pageOrigin
                self.items[i].acceptLanguage = payload.acceptLanguage
                self.items[i].visibleCookie = payload.visibleCookie
                self.items[i].error = nil
                self.persist()
                if self.items[i].state == .failed || self.items[i].state == .paused { self.resume(self.items[i].id) }
            }
            return
        }

        let item = HLSDownloadItem(
            id: UUID(), sourceURL: payload.url, candidateURLs: candidates, selectedURL: nil,
            title: (payload.title?.isEmpty == false ? payload.title! : primary.lastPathComponent),
            posterURL: payload.poster, pageURL: payload.pageUrl, pageOrigin: payload.pageOrigin,
            userAgent: payload.userAgent, acceptLanguage: payload.acceptLanguage, visibleCookie: payload.visibleCookie,
            resolution: payload.resolution, duration: payload.duration, state: .queued, progress: 0,
            bytesReceived: 0, speedBytesPerSecond: 0, totalSegments: 0, completedSegments: 0,
            outputMP4Path: nil, error: nil, probeInfo: nil, createdAt: Date()
        )
        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.persist()
            self.prepareAndStart(item.id)
        }
    }

    private func sameMediaURL(_ a: String, _ b: String) -> Bool {
        func key(_ raw: String) -> String {
            guard var c = URLComponents(string: raw) else { return raw }
            c.fragment = nil
            c.query = nil
            return c.string ?? raw
        }
        return key(a) == key(b)
    }

    // MARK: Headers / playlist fetch
    private func headerFields(for item: HLSDownloadItem, targetURL: URL) -> [String: String] {
        var headers: [String: String] = [:]
        if let ua = item.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        if let ref = item.pageURL, !ref.isEmpty { headers["Referer"] = ref }
        if let origin = item.pageOrigin, !origin.isEmpty { headers["Origin"] = origin }
        if let lang = item.acceptLanguage, !lang.isEmpty { headers["Accept-Language"] = lang }
        headers["Accept"] = "application/vnd.apple.mpegurl, application/x-mpegURL, video/*, audio/*, */*;q=0.8"
        if let page = item.pageURL.flatMap(URL.init(string:)),
           page.host?.lowercased() == targetURL.host?.lowercased(),
           let cookie = item.visibleCookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    private func request(url: URL, item: HLSDownloadItem, rangeStart: Int64? = nil, rangeLength: Int64? = nil) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "GET"
        for (k, v) in headerFields(for: item, targetURL: url) { req.setValue(v, forHTTPHeaderField: k) }
        if let start = rangeStart, let len = rangeLength, len > 0 {
            req.setValue("bytes=\(start)-\(start + len - 1)", forHTTPHeaderField: "Range")
        }
        return req
    }

    private func fetchText(_ url: URL, item: HLSDownloadItem) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request(url: url, item: item))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "HLSHTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"])
        }
        guard !data.isEmpty else { throw HLSParseError.invalidPlaylist("服务器返回空内容") }
        if let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") { return text }
        if let text = String(data: data, encoding: .isoLatin1), text.contains("#EXTM3U") { return text }
        throw HLSParseError.invalidPlaylist("响应不是 M3U8")
    }

    // MARK: Resolve HLS
    func prepareAndStart(_ id: UUID) {
        guard let item = item(id) else { return }
        set(id) { $0.state = .preparing; $0.error = nil; $0.probeInfo = "正在解析主清单和独立音轨…" }
        Task {
            do {
                let plan = try await resolvePlan(item)
                try save(plan: plan, for: id)
                let total = plan.videoSegments.count + plan.audioSegments.count + (plan.videoInit == nil ? 0 : 1) + (plan.audioInit == nil ? 0 : 1)
                DispatchQueue.main.async {
                    guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[i].selectedURL = plan.masterURL
                    self.items[i].resolution = plan.resolution ?? self.items[i].resolution
                    self.items[i].totalSegments = total
                    self.items[i].completedSegments = self.completedCount(for: id, plan: plan)
                    self.items[i].progress = total > 0 ? Double(self.items[i].completedSegments) / Double(total) : 0
                    self.items[i].state = .downloading
                    let tracks = plan.audioPlaylistURL == nil ? "视频流" : "视频 + 独立音轨"
                    self.items[i].probeInfo = self.appIsActive ? "极速前台：6 视频 + 2 音频并发 · \(tracks)" : "系统后台队列 · \(tracks)"
                    self.persist()
                    self.refillQueue(id)
                }
            } catch {
                set(id) { $0.state = .failed; $0.error = error.localizedDescription; $0.speedBytesPerSecond = 0 }
            }
        }
    }

    private func resolvePlan(_ item: HLSDownloadItem) async throws -> StoredPlan {
        let urls = item.candidateURLs.compactMap(URL.init(string:))
        var bestMaster: (URL, String, [HLSVariant], [HLSAudioRendition])?
        var firstMedia: (URL, String)?
        var diagnostics: [String] = []

        for url in urls.prefix(16) {
            do {
                let text = try await fetchText(url, item: item)
                if text.contains("#EXT-X-STREAM-INF") {
                    let parsed = try parseMasterPlaylist(text, url: url)
                    if !parsed.variants.isEmpty { bestMaster = (url, text, parsed.variants, parsed.audio); break }
                } else if firstMedia == nil {
                    firstMedia = (url, text)
                }
            } catch {
                diagnostics.append("\(url.host ?? "?"): \(error.localizedDescription)")
            }
        }

        if let master = bestMaster {
            guard let variant = master.2.max(by: { $0.bandwidth < $1.bandwidth }) else { throw HLSParseError.noVariant }
            let videoText = try await fetchText(variant.url, item: item)
            let video = try parseMediaPlaylist(videoText, url: variant.url, prefix: "v")
            var audio: HLSMediaPlaylist? = nil
            var audioURL: URL? = nil
            if let group = variant.audioGroup {
                let options = master.3.filter { $0.groupID == group }
                if let chosen = options.first(where: { $0.isDefault }) ?? options.first {
                    let audioText = try await fetchText(chosen.url, item: item)
                    audio = try parseMediaPlaylist(audioText, url: chosen.url, prefix: "a")
                    audioURL = chosen.url
                }
            }
            return StoredPlan(
                masterURL: master.0.absoluteString,
                videoPlaylistURL: variant.url.absoluteString,
                audioPlaylistURL: audioURL?.absoluteString,
                videoInit: video.initSegment,
                videoSegments: video.segments,
                audioInit: audio?.initSegment,
                audioSegments: audio?.segments ?? [],
                resolution: variant.resolution,
                bandwidth: variant.bandwidth
            )
        }

        if let media = firstMedia {
            let video = try parseMediaPlaylist(media.1, url: media.0, prefix: "v")
            return StoredPlan(masterURL: media.0.absoluteString, videoPlaylistURL: media.0.absoluteString, audioPlaylistURL: nil,
                              videoInit: video.initSegment, videoSegments: video.segments, audioInit: nil, audioSegments: [],
                              resolution: item.resolution, bandwidth: nil)
        }

        throw NSError(domain: "HLSBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取任何 HLS 候选地址。" + (diagnostics.isEmpty ? "" : " \(diagnostics.prefix(3).joined(separator: "；"))")])
    }

    // MARK: Job files
    private func jobDir(_ id: UUID) -> URL { jobsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func videoDir(_ id: UUID) -> URL { jobDir(id).appendingPathComponent("video", isDirectory: true) }
    private func audioDir(_ id: UUID) -> URL { jobDir(id).appendingPathComponent("audio", isDirectory: true) }
    private func planURL(_ id: UUID) -> URL { jobDir(id).appendingPathComponent("plan.json") }

    private func save(plan: StoredPlan, for id: UUID) throws {
        try fm.createDirectory(at: videoDir(id), withIntermediateDirectories: true)
        try fm.createDirectory(at: audioDir(id), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(plan)
        try data.write(to: planURL(id), options: .atomic)
    }

    private func loadPlan(_ id: UUID) -> StoredPlan? {
        guard let data = try? Data(contentsOf: planURL(id)) else { return nil }
        return try? JSONDecoder().decode(StoredPlan.self, from: data)
    }

    private func fileURL(id: UUID, kind: TrackKind, segment: HLSSegment) -> URL {
        (kind == .video ? videoDir(id) : audioDir(id)).appendingPathComponent(segment.localName)
    }

    private func completedCount(for id: UUID, plan: StoredPlan) -> Int {
        var n = 0
        if let x = plan.videoInit, fm.fileExists(atPath: fileURL(id: id, kind: .video, segment: x).path) { n += 1 }
        n += plan.videoSegments.filter { fm.fileExists(atPath: fileURL(id: id, kind: .video, segment: $0).path) }.count
        if let x = plan.audioInit, fm.fileExists(atPath: fileURL(id: id, kind: .audio, segment: x).path) { n += 1 }
        n += plan.audioSegments.filter { fm.fileExists(atPath: fileURL(id: id, kind: .audio, segment: $0).path) }.count
        return n
    }

    private func taskKey(id: UUID, kind: TrackKind, segment: HLSSegment) -> String {
        "\(id.uuidString)|\(kind.rawValue)|\(segment.index)|\(segment.isInit ? 1 : 0)"
    }

    private func decodeTaskKey(_ raw: String?) -> (UUID, TrackKind, Int, Bool)? {
        guard let raw else { return nil }
        let p = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard p.count == 4, let id = UUID(uuidString: String(p[0])), let kind = TrackKind(rawValue: String(p[1])), let idx = Int(p[2]) else { return nil }
        return (id, kind, idx, p[3] == "1")
    }

    private func segmentFor(plan: StoredPlan, kind: TrackKind, index: Int, isInit: Bool) -> HLSSegment? {
        if kind == .video { return isInit ? plan.videoInit : plan.videoSegments.first(where: { $0.index == index }) }
        return isInit ? plan.audioInit : plan.audioSegments.first(where: { $0.index == index })
    }

    // MARK: Foreground / background transfer mode
    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        foregroundTurboEnabled = active
        for it in items where it.state == .downloading {
            let tracks = (loadPlan(it.id)?.audioPlaylistURL == nil) ? "视频流" : "视频 + 独立音轨"
            set(it.id) { item in
                item.probeInfo = active ? "极速前台：6 视频 + 2 音频并发 · \(tracks)" : "系统后台队列 · \(tracks)"
            }
        }
        if active {
            // Background URLSession may finish all pieces while the app is suspended.
            // Do the CPU/file-I/O heavy FFmpeg remux only after the user returns.
            for it in items where it.state == .merging { finalize(it.id) }
        }

        // A default URLSession is much faster for thousands of small HLS pieces,
        // but it cannot be trusted once iOS suspends the app.  Switch only the
        // unfinished pieces; completed files remain valid on disk.
        let source = active ? backgroundSession : turboSession
        source.getAllTasks { tasks in
            var affected = Set<UUID>()
            for task in tasks {
                guard let key = task.taskDescription,
                      let (id, _, _, _) = self.decodeTaskKey(key),
                      self.item(id)?.state == .downloading else { continue }
                affected.insert(id)
                self.activeTaskKeys.remove(key)
                self.idByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
                self.liveBytesByTask.removeValue(forKey: task.taskIdentifier)
                task.cancel()
            }
            if affected.isEmpty {
                for it in self.items where it.state == .downloading { self.refillQueue(it.id) }
            } else {
                for id in affected { self.refillQueue(id) }
            }
        }
    }

    // MARK: Scheduling
    private func refillQueue(_ id: UUID) {
        guard let current = item(id), current.state == .downloading, let plan = loadPlan(id) else { return }

        let targetSession = appIsActive ? turboSession : backgroundSession
        let videoLimit = appIsActive ? turboVideoConcurrency : backgroundVideoQueued
        let audioLimit = appIsActive ? turboAudioConcurrency : backgroundAudioQueued

        func activeCount(_ kind: TrackKind) -> Int {
            activeTaskKeys.reduce(into: 0) { count, key in
                if let (taskID, taskKind, _, _) = decodeTaskKey(key), taskID == id, taskKind == kind { count += 1 }
            }
        }

        var videoSlots = max(0, videoLimit - activeCount(.video))
        var audioSlots = max(0, audioLimit - activeCount(.audio))
        guard videoSlots > 0 || audioSlots > 0 else { return }

        var videoJobs: [HLSSegment] = []
        if let x = plan.videoInit { videoJobs.append(x) }
        videoJobs.append(contentsOf: plan.videoSegments)
        var audioJobs: [HLSSegment] = []
        if let x = plan.audioInit { audioJobs.append(x) }
        audioJobs.append(contentsOf: plan.audioSegments)

        func schedule(_ kind: TrackKind, _ jobs: [HLSSegment], slots: inout Int) {
            guard slots > 0 else { return }
            for seg in jobs where slots > 0 {
                let key = taskKey(id: id, kind: kind, segment: seg)
                if activeTaskKeys.contains(key) { continue }
                if let notBefore = retryNotBeforeByKey[key], notBefore > Date() { continue }
                if fm.fileExists(atPath: fileURL(id: id, kind: kind, segment: seg).path) { continue }
                guard let u = URL(string: seg.url), let liveItem = item(id) else { continue }

                let task = targetSession.downloadTask(with: request(url: u, item: liveItem, rangeStart: seg.rangeStart, rangeLength: seg.rangeLength))
                task.taskDescription = key
                task.priority = kind == .video ? URLSessionTask.highPriority : URLSessionTask.defaultPriority
                activeTaskKeys.insert(key)
                idByTaskIdentifier[task.taskIdentifier] = id
                liveBytesByTask[task.taskIdentifier] = 0
                task.resume()
                slots -= 1
            }
        }

        // Keep the video pipe full first, while reserving two foreground lanes
        // for an independent audio rendition.
        schedule(.video, videoJobs, slots: &videoSlots)
        schedule(.audio, audioJobs, slots: &audioSlots)

        let done = completedCount(for: id, plan: plan)
        let activeForItem = activeTaskKeys.contains { key in decodeTaskKey(key)?.0 == id }
        if !activeForItem && done >= current.totalSegments { finalize(id) }
    }

    func pause(_ id: UUID) {
        set(id) { $0.state = .paused; $0.speedBytesPerSecond = 0 }
        for s in [turboSession, backgroundSession] {
            s.getAllTasks { tasks in
                for task in tasks where self.decodeTaskKey(task.taskDescription)?.0 == id { task.cancel() }
            }
        }
    }

    func resume(_ id: UUID) {
        guard let current = item(id) else { return }
        guard let plan = loadPlan(id) else { prepareAndStart(id); return }
        if current.totalSegments > 0 && completedCount(for: id, plan: plan) >= current.totalSegments {
            finalize(id)
            return
        }
        DispatchQueue.main.async {
            guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[i].state = .downloading
            self.items[i].error = nil
            self.persist()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { self.refillQueue(id) }
        }
    }

    func remove(_ id: UUID) {
        for s in [turboSession, backgroundSession] {
            s.getAllTasks { tasks in
                for task in tasks where self.decodeTaskKey(task.taskDescription)?.0 == id { task.cancel() }
            }
        }
        try? fm.removeItem(at: jobDir(id))
        DispatchQueue.main.async {
            self.items.removeAll { $0.id == id }
            self.persist()
        }
    }

    // MARK: Finalize / mux
    private func beginFinalize(_ id: UUID) -> Bool {
        finalizeLock.lock(); defer { finalizeLock.unlock() }
        if finalizeInFlight.contains(id) { return false }
        finalizeInFlight.insert(id)
        return true
    }

    private func endFinalize(_ id: UUID) {
        finalizeLock.lock(); defer { finalizeLock.unlock() }
        finalizeInFlight.remove(id)
    }

    /// Final muxing deliberately uses FFmpeg instead of AVFoundation for MPEG-TS.
    /// HLS TS pieces are valid transport-stream fragments, but individual pieces are
    /// not guaranteed to be standalone AVAssets. FFmpeg's concat demuxer + MOV muxer
    /// is built for remuxing packet streams without decoding/re-encoding.
    private func finalize(_ id: UUID) {
        guard beginFinalize(id) else { return }
        guard let plan = loadPlan(id), let current = item(id) else { endFinalize(id); return }
        guard completedCount(for: id, plan: plan) >= current.totalSegments else {
            endFinalize(id)
            refillQueue(id)
            return
        }

        // Downloading may finish while iOS briefly wakes the app in the background.
        // FFmpeg remuxing a multi-GB job is CPU/file-I/O work and should be done while
        // the app is active; otherwise iOS may suspend it in the middle of the output.
        guard appIsActive else {
            set(id) {
                $0.state = .merging
                $0.progress = 1
                $0.error = nil
                $0.probeInfo = "分片已全部下载 · 打开鼠标下载神器后将用 FFmpeg 无损合成 MP4"
            }
            endFinalize(id)
            return
        }

        set(id) {
            $0.state = .merging
            $0.progress = 1
            $0.error = nil
            $0.probeInfo = "分片下载完成 · 正在使用 FFmpeg 无损合成 MP4…"
        }

        Task.detached(priority: .utility) {
            do {
                let output = try self.ffmpegFinalize(id: id, plan: plan)
                guard self.fm.fileExists(atPath: output.path) else {
                    throw NSError(domain: "MouseDownloader.FFmpeg", code: 31,
                                  userInfo: [NSLocalizedDescriptionKey: "FFmpeg 未生成最终 MP4：\(output.lastPathComponent)"])
                }
                let attrs = try self.fm.attributesOfItem(atPath: output.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else {
                    throw NSError(domain: "MouseDownloader.FFmpeg", code: 32,
                                  userInfo: [NSLocalizedDescriptionKey: "最终 MP4 文件大小为 0"])
                }
                try? self.fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
                self.set(id) {
                    $0.state = .completed
                    $0.outputMP4Path = output.path
                    $0.error = nil
                    $0.probeInfo = "FFmpeg 无损合成完成 · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
                }
            } catch {
                let ns = error as NSError
                let detail = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
                self.set(id) {
                    $0.state = .failed
                    $0.error = "分片已下载，但 FFmpeg 合成失败：\(detail)"
                    $0.probeInfo = "全部分片仍保留；点“重新合成”不会重新下载"
                }
            }
            self.endFinalize(id)
        }
    }

    private func ffmpegFinalize(id: UUID, plan: StoredPlan) throws -> URL {
        let output = jobDir(id).appendingPathComponent("output.mp4")
        try? fm.removeItem(at: output)

        // CMAF/fMP4: init + media fragments already form fragmented MP4 tracks.
        // Assemble each rendition first, then let FFmpeg only mux tracks when needed.
        if plan.videoInit != nil {
            let video = jobDir(id).appendingPathComponent("assembled-video.mp4")
            try assembleTrack(id: id, kind: .video, initSegment: plan.videoInit, segments: plan.videoSegments, destination: video)

            if !plan.audioSegments.isEmpty {
                let audio = jobDir(id).appendingPathComponent("assembled-audio.m4a")
                try assembleTrack(id: id, kind: .audio, initSegment: plan.audioInit, segments: plan.audioSegments, destination: audio)
                set(id) { $0.probeInfo = "FFmpeg 正在合并 fMP4 视频轨与独立音轨…" }
                try runFFmpeg(arguments: [
                    "-y", "-hide_banner", "-loglevel", "warning",
                    "-i", video.path,
                    "-i", audio.path,
                    "-map", "0:v:0?", "-map", "1:a:0?",
                    "-c", "copy", "-shortest", "-movflags", "+faststart", output.path
                ])
            } else {
                // Single CMAF stream is already a valid fragmented MP4 after ordered assembly.
                try fm.moveItem(at: video, to: output)
            }
            return output
        }

        // Classic MPEG-TS HLS.  Do NOT concatenate into one giant .ts and ask
        // AVFoundation to open it.  FFmpeg concat demuxer opens each downloaded
        // HLS segment as its own input file and carries packet timestamps/codecs
        // into the MP4 muxer with -c copy.
        let videoList = try writeFFConcat(id: id, kind: .video, segments: plan.videoSegments, name: "video.ffconcat")
        var args = ["-y", "-hide_banner", "-loglevel", "warning", "-fflags", "+genpts",
                    "-f", "concat", "-safe", "0", "-i", videoList.path]

        if !plan.audioSegments.isEmpty {
            let audioList = try writeFFConcat(id: id, kind: .audio, segments: plan.audioSegments, name: "audio.ffconcat")
            args += ["-f", "concat", "-safe", "0", "-i", audioList.path,
                     "-map", "0:v:0?", "-map", "1:a:0?", "-c", "copy", "-shortest"]
            set(id) { $0.probeInfo = "FFmpeg 正在无损拼接 TS 视频 + 独立音轨…" }
        } else {
            args += ["-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy"]
            set(id) { $0.probeInfo = "FFmpeg 正在无损拼接 MPEG-TS 分片…" }
        }

        args += ["-avoid_negative_ts", "make_zero", "-movflags", "+faststart", output.path]
        try runFFmpeg(arguments: args)
        return output
    }

    private func writeFFConcat(id: UUID, kind: TrackKind, segments: [HLSSegment], name: String) throws -> URL {
        guard !segments.isEmpty else {
            throw NSError(domain: "MouseDownloader.FFmpeg", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "没有可供 FFmpeg 合并的分片"])
        }
        let listURL = jobDir(id).appendingPathComponent(name)
        var lines = ["ffconcat version 1.0"]
        for seg in segments.sorted(by: { $0.index < $1.index }) {
            let src = fileURL(id: id, kind: kind, segment: seg)
            try verifyReadableSegment(src, label: "分片 #\(seg.index)")
            // ffconcat quoting: backslash and single quote must be escaped.
            let escaped = src.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "'\\''")
            lines.append("file '\(escaped)'")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
        return listURL
    }

    private func runFFmpeg(arguments: [String]) throws {
        let command = arguments.map(ffmpegShellQuote).joined(separator: " ")
        let session = FFmpegKit.execute(command)
        guard ReturnCode.isSuccess(session.getReturnCode()) else {
            let raw = session.getOutput()
            let tail = String(raw.suffix(1800))
            throw NSError(domain: "MouseDownloader.FFmpeg", code: 50,
                          userInfo: [NSLocalizedDescriptionKey: tail.isEmpty ? "FFmpeg remux 失败" : "FFmpeg remux 失败：\(tail)"])
        }
    }

    private func ffmpegShellQuote(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\\\""))) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func verifyReadableSegment(_ url: URL, label: String) throws {
        guard fm.fileExists(atPath: url.path) else {
            throw NSError(domain: "MouseDownloader.Merge", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "缺少\(label)：\(url.lastPathComponent)"])
        }
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw NSError(domain: "MouseDownloader.Merge", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: "\(label)为空文件：\(url.lastPathComponent)"])
        }
        guard fm.isReadableFile(atPath: url.path) else {
            throw NSError(domain: "MouseDownloader.Merge", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取\(label)：\(url.lastPathComponent)"])
        }
    }

    private func assembleTrack(id: UUID, kind: TrackKind, initSegment: HLSSegment?, segments: [HLSSegment], destination: URL) throws {
        let dir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)

        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw NSError(domain: "MouseDownloader.Merge", code: 43,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建合成文件：\(partial.lastPathComponent)"])
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: partial.path)

        let outputHandle: FileHandle
        do { outputHandle = try FileHandle(forWritingTo: partial) }
        catch {
            throw NSError(domain: "MouseDownloader.Merge", code: 44,
                          userInfo: [NSLocalizedDescriptionKey: "无法打开合成输出：\(partial.lastPathComponent)；\(error.localizedDescription)"])
        }
        defer { try? outputHandle.close() }

        let all = ([initSegment].compactMap { $0 } + segments)
        guard !all.isEmpty else {
            throw NSError(domain: "MouseDownloader.Merge", code: 45,
                          userInfo: [NSLocalizedDescriptionKey: "没有可合成的媒体分片"])
        }

        for (position, seg) in all.enumerated() {
            let src = fileURL(id: id, kind: kind, segment: seg)
            try verifyReadableSegment(src, label: seg.isInit ? "初始化分片" : "分片 #\(seg.index)")
            let input: FileHandle
            do { input = try FileHandle(forReadingFrom: src) }
            catch {
                throw NSError(domain: "MouseDownloader.Merge", code: 46,
                              userInfo: [NSLocalizedDescriptionKey: "无法打开分片 #\(seg.index)：\(src.lastPathComponent)；\(error.localizedDescription)"])
            }
            defer { try? input.close() }
            do {
                while true {
                    let data = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try outputHandle.write(contentsOf: data)
                }
            } catch {
                throw NSError(domain: "MouseDownloader.Merge", code: 47,
                              userInfo: [NSLocalizedDescriptionKey: "写入第 \(position + 1)/\(all.count) 个分片失败：\(error.localizedDescription)"])
            }
            try? input.close()
        }
        try outputHandle.synchronize()
        try outputHandle.close()
        try fm.moveItem(at: partial, to: destination)
    }

    func shareURL(_ id: UUID) -> URL? {
        guard let p = item(id)?.outputMP4Path else { return nil }
        return URL(fileURLWithPath: p)
    }

    // MARK: URLSession delegates
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        liveBytesByTask[downloadTask.taskIdentifier] = totalBytesWritten
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription,
              let (id, kind, idx, isInit) = decodeTaskKey(key),
              let plan = loadPlan(id),
              let seg = segmentFor(plan: plan, kind: kind, index: idx, isInit: isInit) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The completion delegate below owns retry/failure policy.
            return
        }
        let dest = fileURL(id: id, kind: kind, segment: seg)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dest.path)
        } catch {
            set(id) { $0.state = .failed; $0.error = "保存分片失败：\(error.localizedDescription)" }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription, let (id, _, _, _) = decodeTaskKey(key) else { return }
        activeTaskKeys.remove(key)
        idByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
        liveBytesByTask.removeValue(forKey: task.taskIdentifier)

        if let error = error as NSError? {
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                if item(id)?.state == .downloading { refillQueue(id) }
                return
            }
            let transient = error.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet].contains(error.code)
            if transient, retryCountByKey[key, default: 0] < 3, item(id)?.state == .downloading {
                retryCountByKey[key, default: 0] += 1
                let delay = Double(retryCountByKey[key] ?? 1) * 0.45
                retryNotBeforeByKey[key] = Date().addingTimeInterval(delay)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.refillQueue(id) }
                return
            }
            set(id) { $0.state = .failed; $0.error = error.localizedDescription; $0.speedBytesPerSecond = 0 }
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if [429, 500, 502, 503, 504].contains(http.statusCode), retryCountByKey[key, default: 0] < 3, item(id)?.state == .downloading {
                retryCountByKey[key, default: 0] += 1
                let delay = Double(retryCountByKey[key] ?? 1) * 0.75
                retryNotBeforeByKey[key] = Date().addingTimeInterval(delay)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.refillQueue(id) }
                return
            }
            set(id) { $0.state = .failed; $0.error = "分片请求失败：HTTP \(http.statusCode)"; $0.speedBytesPerSecond = 0 }
            return
        }
        retryCountByKey.removeValue(forKey: key)
        retryNotBeforeByKey.removeValue(forKey: key)

        if let plan = loadPlan(id), let current = item(id) {
            let done = completedCount(for: id, plan: plan)
            let bytes = directorySize(jobDir(id))
            set(id) {
                $0.completedSegments = done
                $0.bytesReceived = bytes
                $0.progress = $0.totalSegments > 0 ? min(1, Double(done) / Double($0.totalSegments)) : 0
            }
            if done >= current.totalSegments { finalize(id) }
            else { refillQueue(id) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundEventsCompletionHandler?()
            self.backgroundEventsCompletionHandler = nil
        }
    }

    private func reconnectBackgroundTasks() {
        _ = backgroundSession
        backgroundSession.getAllTasks { tasks in
            for task in tasks {
                guard let key = task.taskDescription, let (id, _, _, _) = self.decodeTaskKey(key) else { continue }
                self.activeTaskKeys.insert(key)
                self.idByTaskIdentifier[task.taskIdentifier] = id
                if self.item(id)?.state == .downloading { task.resume() }
            }
        }
    }

    private func resumePendingWork() {
        for it in items {
            if it.state == .downloading { refillQueue(it.id) }
            else if it.state == .merging { finalize(it.id) }
        }
    }

    // MARK: speed / persistence
    private func startSpeedTimer() {
        DispatchQueue.main.async {
            self.speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.sampleSpeeds() }
        }
    }

    private func sampleSpeeds() {
        for it in items where it.state == .downloading {
            let now = Date()
            let diskBytes = directorySize(jobDir(it.id))
            let inflight = idByTaskIdentifier.reduce(into: Int64(0)) { total, pair in
                if pair.value == it.id { total += liveBytesByTask[pair.key] ?? 0 }
            }
            let observed = diskBytes + inflight
            let old = lastSpeedSample[it.id]
            lastSpeedSample[it.id] = (now, observed)
            guard let old else { continue }
            let dt = now.timeIntervalSince(old.0)
            if dt > 0 {
                let instant = Double(max(0, observed - old.1)) / dt
                let previous = it.speedBytesPerSecond
                let smoothed = previous > 0 ? previous * 0.55 + instant * 0.45 : instant
                set(it.id) { $0.bytesReceived = diskBytes; $0.speedBytesPerSecond = smoothed }
            }
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var size: Int64 = 0
        for case let file as URL in e {
            size += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return size
    }

    private func item(_ id: UUID) -> HLSDownloadItem? { items.first { $0.id == id } }

    private func set(_ id: UUID, _ mutate: @escaping (inout HLSDownloadItem) -> Void) {
        DispatchQueue.main.async {
            guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            mutate(&self.items[i])
            self.persist()
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storeURL, options: .atomic)
        } catch { }
    }

    private func loadStore() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([HLSDownloadItem].self, from: data) else { return }
        items = saved
    }
}
