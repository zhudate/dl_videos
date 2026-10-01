import Foundation

struct HLSVariant {
    let url: URL
    let bandwidth: Int
    let resolution: String?
    let audioGroup: String?
}

struct HLSAudioRendition {
    let url: URL
    let groupID: String
    let name: String?
    let isDefault: Bool
}

struct HLSSegment: Codable, Hashable {
    var url: String
    var index: Int
    var rangeStart: Int64?
    var rangeLength: Int64?
    var isInit: Bool
    var localName: String
}

struct HLSMediaPlaylist {
    var playlistURL: URL
    var initSegment: HLSSegment?
    var segments: [HLSSegment]
    var duration: Double
    var isEncrypted: Bool
    var usesByteRange: Bool
}

struct HLSResolvedPlan {
    var masterURL: URL
    var videoPlaylistURL: URL
    var audioPlaylistURL: URL?
    var video: HLSMediaPlaylist
    var audio: HLSMediaPlaylist?
    var resolution: String?
    var bandwidth: Int?
}

enum HLSParseError: LocalizedError {
    case invalidPlaylist(String)
    case noVariant
    case encrypted

    var errorDescription: String? {
        switch self {
        case .invalidPlaylist(let reason): return "M3U8 解析失败：\(reason)"
        case .noVariant: return "主 M3U8 中没有可用的视频清晰度"
        case .encrypted: return "该 HLS 使用加密分片，当前版本不处理加密/DRM"
        }
    }
}

private func parseAttributeList(_ raw: String) -> [String: String] {
    var result: [String: String] = [:]
    var token = ""
    var inQuotes = false
    var parts: [String] = []
    for ch in raw {
        if ch == "\"" { inQuotes.toggle(); token.append(ch) }
        else if ch == "," && !inQuotes { parts.append(token); token = "" }
        else { token.append(ch) }
    }
    if !token.isEmpty { parts.append(token) }
    for p in parts {
        guard let eq = p.firstIndex(of: "=") else { continue }
        let key = String(p[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
        var value = String(p[p.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value.removeFirst(); value.removeLast()
        }
        result[key] = value
    }
    return result
}

private func resolvedURL(_ raw: String, base: URL, inheritQuery: Bool = true) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
    if inheritQuery,
       let baseQuery = URLComponents(url: base, resolvingAgainstBaseURL: false)?.query,
       !baseQuery.isEmpty,
       (URLComponents(url: url, resolvingAgainstBaseURL: false)?.query ?? "").isEmpty,
       var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
        c.percentEncodedQuery = baseQuery
        if let q = c.url { url = q }
    }
    return url
}

func parseMasterPlaylist(_ text: String, url: URL) throws -> (variants: [HLSVariant], audio: [HLSAudioRendition]) {
    guard text.contains("#EXTM3U") else { throw HLSParseError.invalidPlaylist("缺少 #EXTM3U") }
    let lines = text.components(separatedBy: .newlines)
    var variants: [HLSVariant] = []
    var audios: [HLSAudioRendition] = []
    var i = 0
    while i < lines.count {
        let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("#EXT-X-MEDIA:") {
            let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            if attrs["TYPE"]?.uppercased() == "AUDIO",
               let group = attrs["GROUP-ID"],
               let uri = attrs["URI"],
               let u = resolvedURL(uri, base: url) {
                audios.append(HLSAudioRendition(
                    url: u,
                    groupID: group,
                    name: attrs["NAME"],
                    isDefault: attrs["DEFAULT"]?.uppercased() == "YES"
                ))
            }
        } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
            let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            var j = i + 1
            while j < lines.count {
                let next = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.isEmpty || next.hasPrefix("#") { j += 1; continue }
                if let u = resolvedURL(next, base: url) {
                    variants.append(HLSVariant(
                        url: u,
                        bandwidth: Int(attrs["AVERAGE-BANDWIDTH"] ?? attrs["BANDWIDTH"] ?? "0") ?? 0,
                        resolution: attrs["RESOLUTION"],
                        audioGroup: attrs["AUDIO"]
                    ))
                }
                i = j
                break
            }
        }
        i += 1
    }
    return (variants, audios)
}

func parseMediaPlaylist(_ text: String, url: URL, prefix: String) throws -> HLSMediaPlaylist {
    guard text.contains("#EXTM3U") else { throw HLSParseError.invalidPlaylist("媒体清单缺少 #EXTM3U") }
    if text.range(of: #"#EXT-X-KEY:[^\n\r]*METHOD=(?!NONE)"#, options: .regularExpression) != nil {
        throw HLSParseError.encrypted
    }

    let lines = text.components(separatedBy: .newlines)
    var segments: [HLSSegment] = []
    var initSegment: HLSSegment?
    var totalDuration = 0.0
    var pendingDuration: Double?
    var pendingRangeLength: Int64?
    var pendingRangeStart: Int64?
    var implicitRangeEnd: Int64 = 0
    var usesByteRange = false

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        if line.hasPrefix("#EXTINF:") {
            let value = String(line.dropFirst("#EXTINF:".count)).split(separator: ",", maxSplits: 1).first.map(String.init) ?? "0"
            pendingDuration = Double(value) ?? 0
            totalDuration += pendingDuration ?? 0
        } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
            usesByteRange = true
            let spec = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            let p = spec.split(separator: "@", maxSplits: 1).map(String.init)
            pendingRangeLength = Int64(p.first ?? "")
            pendingRangeStart = p.count > 1 ? Int64(p[1]) : implicitRangeEnd
        } else if line.hasPrefix("#EXT-X-MAP:") {
            let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
            if let uri = attrs["URI"], let u = resolvedURL(uri, base: url) {
                var start: Int64? = nil
                var length: Int64? = nil
                if let br = attrs["BYTERANGE"] {
                    let p = br.split(separator: "@", maxSplits: 1).map(String.init)
                    length = Int64(p.first ?? "")
                    start = p.count > 1 ? Int64(p[1]) : 0
                    usesByteRange = true
                }
                initSegment = HLSSegment(url: u.absoluteString, index: -1, rangeStart: start, rangeLength: length, isInit: true, localName: "\(prefix)-init.bin")
            }
        } else if !line.hasPrefix("#") {
            guard let u = resolvedURL(line, base: url) else { continue }
            let idx = segments.count
            let ext = u.pathExtension.isEmpty ? "bin" : u.pathExtension
            let seg = HLSSegment(
                url: u.absoluteString,
                index: idx,
                rangeStart: pendingRangeStart,
                rangeLength: pendingRangeLength,
                isInit: false,
                localName: String(format: "%@-%06d.%@", prefix, idx, ext)
            )
            if let start = pendingRangeStart, let len = pendingRangeLength { implicitRangeEnd = start + len }
            else if let len = pendingRangeLength { implicitRangeEnd += len }
            segments.append(seg)
            pendingRangeLength = nil
            pendingRangeStart = nil
            pendingDuration = nil
        }
    }
    guard !segments.isEmpty else { throw HLSParseError.invalidPlaylist("没有媒体分片") }
    return HLSMediaPlaylist(playlistURL: url, initSegment: initSegment, segments: segments, duration: totalDuration, isEncrypted: false, usesByteRange: usesByteRange)
}
