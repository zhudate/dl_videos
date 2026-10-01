import Foundation

struct HLSIncomingPayload: Codable {
    var version: Int?
    var url: String
    var candidates: [String]?
    var title: String?
    var poster: String?
    var pageUrl: String?
    var pageOrigin: String?
    var userAgent: String?
    var acceptLanguage: String?
    var visibleCookie: String?
    var resolution: String?
    var duration: Double?
}

enum HLSDownloadState: String, Codable {
    case queued, preparing, downloading, paused, merging, completed, failed
}

struct HLSDownloadItem: Identifiable, Codable, Equatable {
    var id: UUID
    var sourceURL: String
    var candidateURLs: [String]
    var selectedURL: String?
    var title: String
    var posterURL: String?
    var pageURL: String?
    var pageOrigin: String?
    var userAgent: String?
    var acceptLanguage: String?
    var visibleCookie: String?
    var resolution: String?
    var duration: Double?
    var state: HLSDownloadState
    var progress: Double
    var bytesReceived: Int64
    var speedBytesPerSecond: Double
    var totalSegments: Int
    var completedSegments: Int
    var outputMP4Path: String?
    var error: String?
    var probeInfo: String?
    var createdAt: Date
}
