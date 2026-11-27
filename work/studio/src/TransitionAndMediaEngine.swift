import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

// MARK: - Transition Engine Errors

enum TransitionEngineError: LocalizedError, Sendable {
    case unsupportedTransitionKind(String)
    case invalidDuration(Double)
    case invalidClipPayload(String)
    case missingTimelineRenderScript(String)
    case missingPython3
    case missingSourceFile(String)
    case renderFailed(String)
    case emptyOutput(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTransitionKind(let kind):
            return "不支援的轉場類型：\(kind)"
        case .invalidDuration(let duration):
            return "無效的轉場秒數：\(duration)"
        case .invalidClipPayload(let detail):
            return "無效的轉場片段參數 JSON：\(detail)"
        case .missingTimelineRenderScript(let detail):
            return "找不到同源轉場渲染腳本 timeline_render.py：\(detail)"
        case .missingPython3:
            return "找不到 Python 3（/usr/bin/python3）"
        case .missingSourceFile(let path):
            return "轉場來源檔案不存在：\(path)"
        case .renderFailed(let message):
            return "timeline_render.py 轉場快取渲染失敗：\(message)"
        case .emptyOutput(let path):
            return "轉場快取產出檔案無效或為空：\(path)"
        }
    }
}

// MARK: - Canonical Clip Render Payload Helper

struct TransitionClipRenderPayload: Codable, Hashable, Sendable {
    var path: String
    var start: Double?
    var end: Double?
    var speed: Double
    var reversed: Bool
    var freezeFrame: Bool
    var flipH: Bool
    var flipV: Bool
    var rotation: Double
    var cropTop: Double
    var cropBottom: Double
    var cropLeft: Double
    var cropRight: Double
    var filterPreset: String
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var blur: Double
    var vignette: Bool
    var chromaKeyEnabled: Bool
    var chromaKeyColor: String
    var chromaKeySimilarity: Double
    var chromaKeyBlend: Double
    var posX: Double
    var posY: Double
    var scale: Double
    var opacity: Double

    init(
        path: String,
        start: Double? = nil,
        end: Double? = nil,
        speed: Double = 1.0,
        reversed: Bool = false,
        freezeFrame: Bool = false,
        flipH: Bool = false,
        flipV: Bool = false,
        rotation: Double = 0.0,
        cropTop: Double = 0.0,
        cropBottom: Double = 0.0,
        cropLeft: Double = 0.0,
        cropRight: Double = 0.0,
        filterPreset: String = "none",
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 1.0,
        blur: Double = 0.0,
        vignette: Bool = false,
        chromaKeyEnabled: Bool = false,
        chromaKeyColor: String = "0x00FF00",
        chromaKeySimilarity: Double = 0.18,
        chromaKeyBlend: Double = 0.08,
        posX: Double = 0.0,
        posY: Double = 0.0,
        scale: Double = 1.0,
        opacity: Double = 1.0
    ) {
        self.path = path
        self.start = start
        self.end = end
        self.speed = speed
        self.reversed = reversed
        self.freezeFrame = freezeFrame
        self.flipH = flipH
        self.flipV = flipV
        self.rotation = rotation
        self.cropTop = cropTop
        self.cropBottom = cropBottom
        self.cropLeft = cropLeft
        self.cropRight = cropRight
        self.filterPreset = filterPreset
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.blur = blur
        self.vignette = vignette
        self.chromaKeyEnabled = chromaKeyEnabled
        self.chromaKeyColor = chromaKeyColor
        self.chromaKeySimilarity = chromaKeySimilarity
        self.chromaKeyBlend = chromaKeyBlend
        self.posX = posX
        self.posY = posY
        self.scale = scale
        self.opacity = opacity
    }

    func canonicalJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - Transition Cache Request (Same-Source v2)

struct TransitionCacheRequest: Hashable, Sendable {
    static let currentCacheVersion: Int = 2

    static let supportedKinds: [String] = [
        "dissolve",
        "fadeblack",
        "fadewhite",
        "wipeleft",
        "wiperight",
        "wipeup",
        "wipedown",
        "slideleft",
        "slideright",
        "circleopen",
        "circleclose",
        "pixelize",
        "smoothleft",
        "zoomin"
    ]

    let key: String
    let cacheVersion: Int
    let kind: String
    let duration: Double
    let leadingPath: String
    let trailingPath: String
    let leadingClipPayloadJSON: String
    let trailingClipPayloadJSON: String
    let width: Int
    let height: Int
    let fps: Int

    init(
        key: String,
        cacheVersion: Int = currentCacheVersion,
        kind: String,
        duration: Double,
        leadingPath: String,
        trailingPath: String,
        leadingClipPayloadJSON: String,
        trailingClipPayloadJSON: String,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 24
    ) {
        self.key = key
        self.cacheVersion = cacheVersion
        self.kind = kind
        self.duration = duration
        self.leadingPath = leadingPath
        self.trailingPath = trailingPath
        self.leadingClipPayloadJSON = Self.canonicalizeJSONString(leadingClipPayloadJSON)
        self.trailingClipPayloadJSON = Self.canonicalizeJSONString(trailingClipPayloadJSON)
        self.width = width
        self.height = height
        self.fps = fps
    }

    init(
        cacheVersion: Int = currentCacheVersion,
        kind: String,
        duration: Double,
        leadingPath: String,
        trailingPath: String,
        leadingClipPayloadJSON: String,
        trailingClipPayloadJSON: String,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 24
    ) {
        let canonicalLeading = Self.canonicalizeJSONString(leadingClipPayloadJSON)
        let canonicalTrailing = Self.canonicalizeJSONString(trailingClipPayloadJSON)
        let computedKey = Self.makeKey(
            cacheVersion: cacheVersion,
            kind: kind,
            duration: duration,
            leadingPath: leadingPath,
            trailingPath: trailingPath,
            leadingClipPayloadJSON: canonicalLeading,
            trailingClipPayloadJSON: canonicalTrailing,
            width: width,
            height: height,
            fps: fps
        )
        self.init(
            key: computedKey,
            cacheVersion: cacheVersion,
            kind: kind,
            duration: duration,
            leadingPath: leadingPath,
            trailingPath: trailingPath,
            leadingClipPayloadJSON: canonicalLeading,
            trailingClipPayloadJSON: canonicalTrailing,
            width: width,
            height: height,
            fps: fps
        )
    }

    static func canonicalClipPayloadJSON(_ dictionary: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(dictionary) else {
            throw TransitionEngineError.invalidClipPayload("無法序列化的字典內容")
        }
        let data = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let str = String(data: data, encoding: .utf8) else {
            throw TransitionEngineError.invalidClipPayload("UTF-8 編碼失敗")
        }
        return str
    }

    static func makeKey(
        cacheVersion: Int = currentCacheVersion,
        kind: String,
        duration: Double,
        leadingPath: String,
        trailingPath: String,
        leadingClipPayloadJSON: String,
        trailingClipPayloadJSON: String,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 24
    ) -> String {
        let leadSig = fileSignature(for: leadingPath)
        let trailSig = fileSignature(for: trailingPath)
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonicalLead = canonicalizeJSONString(leadingClipPayloadJSON)
        let canonicalTrail = canonicalizeJSONString(trailingClipPayloadJSON)

        let payload = [
            "md_tr_v\(cacheVersion)",
            normalizedKind,
            String(format: "%.4f", duration),
            "\(width)x\(height)@\(fps)",
            leadingPath,
            leadSig,
            canonicalLead,
            trailingPath,
            trailSig,
            canonicalTrail
        ].joined(separator: "\n")

        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(normalizedKind)-v\(cacheVersion)-\(hex.prefix(28))"
    }

    static func ffmpegTransitionName(for kind: String) throws -> String {
        let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "dissolve":
            return "fade"
        case "fadeblack",
             "fadewhite",
             "wipeleft",
             "wiperight",
             "wipeup",
             "wipedown",
             "slideleft",
             "slideright",
             "circleopen",
             "circleclose",
             "pixelize",
             "smoothleft",
             "zoomin":
            return normalized
        default:
            throw TransitionEngineError.unsupportedTransitionKind(kind)
        }
    }

    static func previewDimensions(aspectWidth: Int, aspectHeight: Int, maxLongEdge: Int = 640) -> (width: Int, height: Int) {
        let srcW = max(1, aspectWidth)
        let srcH = max(1, aspectHeight)
        let longEdge = max(64, maxLongEdge)
        let scale = Double(longEdge) / Double(max(srcW, srcH))
        let w = max(64, (Int((Double(srcW) * scale).rounded()) / 2) * 2)
        let h = max(64, (Int((Double(srcH) * scale).rounded()) / 2) * 2)
        return (w, h)
    }

    private static func canonicalizeJSONString(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(obj),
              let sortedData = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let sortedStr = String(data: sortedData, encoding: .utf8) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sortedStr
    }

    private static func fileSignature(for path: String) -> String {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return String(format: "%.3f_%lld", mtime, size)
    }
}

// MARK: - Transition Preview Cache (Same-Source timeline_render.py + Smooth Handoff)

@MainActor
final class TransitionPreviewCache: ObservableObject {
    static let shared = TransitionPreviewCache()
    static let cacheDirectoryURL = URL(fileURLWithPath: "/private/tmp/motiondesk-transition-cache", isDirectory: true)

    /// Optional override for `timeline_render.py` path (defaults to `Bundle.main` resource).
    var timelineRenderScriptURL: URL? = nil

    @Published var readyURLs: [String: URL] = [:]
    @Published var renderingKeys: Set<String> = []
    @Published var errors: [String: String] = [:]
    /// Keys whose `AVPlayerItem` reached `.readyToPlay` AND completed initial exact seek to `localSeconds`.
    /// UI should keep showing `LiveTransitionCompositorView` until `playableKeys.contains(key)` to prevent black-frame flashes or jumps.
    @Published var playableKeys: Set<String> = []

    private var players: [String: AVPlayer] = [:]
    private var statusObservations: [String: NSKeyValueObservation] = [:]
    private var primingKeys: Set<String> = []
    private var keyFPS: [String: Int] = [:]
    private var pendingLocalSeconds: [String: Double] = [:]
    private var pendingIsPlaying: [String: Bool] = [:]
    private var playerLRU: [String] = []
    private var pendingQueue: [(request: TransitionCacheRequest, scriptURL: URL?)] = []
    private var activeRenderCount: Int = 0
    private let maxConcurrentRenders: Int = 3
    private let maxCachedPlayers: Int = 16

    private init() {
        try? FileManager.default.createDirectory(
            at: Self.cacheDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func cacheFileURL(for key: String) -> URL {
        let sanitized = key.replacingOccurrences(of: "/", with: "_")
        return Self.cacheDirectoryURL.appendingPathComponent("\(sanitized).mp4")
    }

    func isPlayerReadyForDisplay(key: String) -> Bool {
        guard playableKeys.contains(key),
              let player = players[key],
              player.currentItem?.status == .readyToPlay else {
            return false
        }
        return true
    }

    func ensureCached(_ req: TransitionCacheRequest, timelineRenderScript: URL? = nil) {
        let key = req.key
        keyFPS[key] = max(12, min(120, req.fps))
        let outURL = cacheFileURL(for: key)

        if let existing = readyURLs[key], Self.isValidCacheFile(at: existing) {
            return
        }

        if Self.isValidCacheFile(at: outURL) {
            readyURLs[key] = outURL
            errors.removeValue(forKey: key)
            return
        }

        if renderingKeys.contains(key) || errors[key] != nil {
            return
        }

        let resolvedScript = timelineRenderScript ?? timelineRenderScriptURL
        renderingKeys.insert(key)
        pendingQueue.append((request: req, scriptURL: resolvedScript))
        pumpQueue()
    }

    private func pumpQueue() {
        while activeRenderCount < maxConcurrentRenders, !pendingQueue.isEmpty {
            let entry = pendingQueue.removeFirst()
            let req = entry.request
            let scriptURL = entry.scriptURL
            let key = req.key
            let outURL = cacheFileURL(for: key)

            if Self.isValidCacheFile(at: outURL) {
                renderingKeys.remove(key)
                readyURLs[key] = outURL
                errors.removeValue(forKey: key)
                continue
            }

            activeRenderCount += 1
            Task.detached(priority: .userInitiated) {
                do {
                    try TransitionPreviewCache.renderTransitionClipSync(
                        req,
                        outputURL: outURL,
                        timelineRenderScript: scriptURL
                    )
                    await MainActor.run {
                        self.handleRenderCompletion(key: key, outputURL: outURL, error: nil)
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self.handleRenderCompletion(key: key, outputURL: nil, error: message)
                    }
                }
            }
        }
    }

    private func handleRenderCompletion(key: String, outputURL: URL?, error: String?) {
        activeRenderCount = max(0, activeRenderCount - 1)
        renderingKeys.remove(key)
        if let outputURL, Self.isValidCacheFile(at: outputURL) {
            readyURLs[key] = outputURL
            errors.removeValue(forKey: key)
        } else if let error {
            errors[key] = error
        }
        pumpQueue()
    }

    func player(for key: String) -> AVPlayer? {
        if let cached = players[key] {
            touchPlayerLRU(key)
            return cached
        }

        let resolvedURL: URL
        if let ready = readyURLs[key], Self.isValidCacheFile(at: ready) {
            resolvedURL = ready
        } else {
            let diskURL = cacheFileURL(for: key)
            guard Self.isValidCacheFile(at: diskURL) else {
                return nil
            }
            readyURLs[key] = diskURL
            resolvedURL = diskURL
        }

        let item = AVPlayerItem(url: resolvedURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false

        players[key] = player
        touchPlayerLRU(key)

        let obs = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            Task { @MainActor [weak self] in
                self?.handleItemStatusChange(key: key, status: status)
            }
        }
        statusObservations[key] = obs

        evictExcessPlayersIfNeeded(keeping: key)
        return player
    }

    private func handleItemStatusChange(key: String, status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            primePlayerAtPendingTimeIfNeeded(key: key)
        case .failed:
            playableKeys.remove(key)
            primingKeys.remove(key)
            if let errMsg = players[key]?.currentItem?.error?.localizedDescription {
                errors[key] = errMsg
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func primePlayerAtPendingTimeIfNeeded(key: String) {
        guard !playableKeys.contains(key),
              !primingKeys.contains(key),
              let player = players[key],
              let item = player.currentItem,
              item.status == .readyToPlay else {
            return
        }

        primingKeys.insert(key)
        let fps = Double(max(12, min(120, keyFPS[key] ?? 24)))
        let frameDur = 1.0 / fps
        let target = clampedTargetSeconds(
            pendingLocalSeconds[key] ?? 0.0,
            for: item,
            frameDuration: frameDur
        )
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.handleInitialPrimeSeekCompleted(key: key, finished: finished)
            }
        }
    }

    private func handleInitialPrimeSeekCompleted(key: String, finished: Bool) {
        primingKeys.remove(key)
        guard let player = players[key],
              let item = player.currentItem,
              item.status == .readyToPlay else {
            return
        }

        let fps = Double(max(12, min(120, keyFPS[key] ?? 24)))
        let frameDur = 1.0 / fps
        let latestTarget = clampedTargetSeconds(
            pendingLocalSeconds[key] ?? 0.0,
            for: item,
            frameDuration: frameDur
        )
        let current = player.currentTime().seconds
        let drift = current.isFinite ? abs(current - latestTarget) : Double.infinity

        if !finished || drift > max(0.012, frameDur * 0.75) {
            // Playhead moved while priming — re-prime cleanly before revealing cached video
            primePlayerAtPendingTimeIfNeeded(key: key)
            return
        }

        playableKeys.insert(key)
        if pendingIsPlaying[key] == true {
            if player.rate == 0 {
                player.play()
            }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    func sync(key: String, localSeconds: Double, isPlaying: Bool, exact: Bool, fps: Int? = nil) {
        if let fps {
            keyFPS[key] = max(12, min(120, fps))
        }
        let sanitizedLocal = localSeconds.isFinite ? max(0.0, localSeconds) : 0.0
        pendingLocalSeconds[key] = sanitizedLocal
        pendingIsPlaying[key] = isPlaying

        guard let player = player(for: key),
              let item = player.currentItem else {
            return
        }

        // Wait for AVPlayerItem.status == .readyToPlay + exact initial seek before handoff
        if item.status != .readyToPlay {
            if player.rate != 0 {
                player.pause()
            }
            return
        }

        if !playableKeys.contains(key) {
            primePlayerAtPendingTimeIfNeeded(key: key)
            return
        }

        let effectiveFPS = Double(max(12, min(120, keyFPS[key] ?? 24)))
        let frameDur = 1.0 / effectiveFPS
        let target = clampedTargetSeconds(sanitizedLocal, for: item, frameDuration: frameDur)

        let current = player.currentTime().seconds
        let drift = current.isFinite ? abs(current - target) : Double.infinity
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)

        if isPlaying {
            let seekThreshold = exact ? max(0.015, frameDur * 0.75) : max(0.05, frameDur * 2.2)
            if drift > seekThreshold {
                let tol = exact ? CMTime.zero : CMTime(seconds: frameDur * 0.5, preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: tol, toleranceAfter: tol)
            }
            if player.rate == 0 {
                player.play()
            }
        } else {
            if player.rate != 0 {
                player.pause()
            }
            let seekThreshold = exact ? max(0.004, frameDur * 0.25) : max(0.015, frameDur * 0.75)
            if drift > seekThreshold {
                let tol = exact ? CMTime.zero : CMTime(seconds: frameDur * 0.5, preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: tol, toleranceAfter: tol)
            }
        }
    }

    func pauseAll(except activeKeys: Set<String> = []) {
        for (key, player) in players where !activeKeys.contains(key) {
            pendingIsPlaying[key] = false
            if player.rate != 0 {
                player.pause()
            }
        }
    }

    func invalidate(key: String) {
        statusObservations.removeValue(forKey: key)?.invalidate()
        playableKeys.remove(key)
        primingKeys.remove(key)
        pendingLocalSeconds.removeValue(forKey: key)
        pendingIsPlaying.removeValue(forKey: key)
        keyFPS.removeValue(forKey: key)
        if let player = players.removeValue(forKey: key) {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        playerLRU.removeAll { $0 == key }
        readyURLs.removeValue(forKey: key)
        errors.removeValue(forKey: key)
        let url = cacheFileURL(for: key)
        try? FileManager.default.removeItem(at: url)
    }

    private func clampedTargetSeconds(_ raw: Double, for item: AVPlayerItem, frameDuration: Double) -> Double {
        var target = raw.isFinite ? max(0.0, raw) : 0.0
        let itemDuration = item.duration.seconds
        if itemDuration.isFinite, itemDuration > frameDuration {
            let maxSafe = max(0.0, itemDuration - min(0.004, frameDuration * 0.25))
            target = min(target, maxSafe)
        }
        return target
    }

    private func touchPlayerLRU(_ key: String) {
        playerLRU.removeAll { $0 == key }
        playerLRU.append(key)
    }

    private func evictExcessPlayersIfNeeded(keeping protectedKey: String) {
        while players.count > maxCachedPlayers, let oldest = playerLRU.first {
            if oldest == protectedKey {
                break
            }
            playerLRU.removeFirst()
            statusObservations.removeValue(forKey: oldest)?.invalidate()
            playableKeys.remove(oldest)
            primingKeys.remove(oldest)
            pendingLocalSeconds.removeValue(forKey: oldest)
            pendingIsPlaying.removeValue(forKey: oldest)
            if let removed = players.removeValue(forKey: oldest) {
                removed.pause()
                removed.replaceCurrentItem(with: nil)
            }
        }
    }

    private nonisolated static func isValidCacheFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size > 1024
    }

    private nonisolated static func resolveTimelineRenderScript(_ overrideURL: URL?) throws -> URL {
        if let overrideURL {
            guard FileManager.default.fileExists(atPath: overrideURL.path) else {
                throw TransitionEngineError.missingTimelineRenderScript(overrideURL.path)
            }
            return overrideURL
        }
        if let bundled = Bundle.main.url(forResource: "timeline_render", withExtension: "py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        throw TransitionEngineError.missingTimelineRenderScript("Bundle.main 未找到 timeline_render.py（拒絕退回原片假快取）")
    }

    private nonisolated static func locatePython3() throws -> URL {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw TransitionEngineError.missingPython3
    }

    private nonisolated static func parseClipDict(from json: String, fallbackPath: String, label: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransitionEngineError.invalidClipPayload("\(label) 必須為有效 JSON 物件")
        }
        if (dict["path"] as? String)?.isEmpty ?? true {
            dict["path"] = fallbackPath
        }
        return dict
    }

    nonisolated static func renderTransitionClipSync(
        _ req: TransitionCacheRequest,
        outputURL: URL,
        timelineRenderScript: URL? = nil
    ) throws {
        // Strictly validate transition kind (never degrade unknown kind to fade)
        let _ = try TransitionCacheRequest.ffmpegTransitionName(for: req.kind)
        let normalizedKind = req.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard req.duration.isFinite, req.duration >= 0.05 else {
            throw TransitionEngineError.invalidDuration(req.duration)
        }
        guard FileManager.default.fileExists(atPath: req.leadingPath) else {
            throw TransitionEngineError.missingSourceFile(req.leadingPath)
        }
        guard FileManager.default.fileExists(atPath: req.trailingPath) else {
            throw TransitionEngineError.missingSourceFile(req.trailingPath)
        }

        let scriptURL = try resolveTimelineRenderScript(timelineRenderScript)
        let pythonURL = try locatePython3()

        let leadingDict = try parseClipDict(
            from: req.leadingClipPayloadJSON,
            fallbackPath: req.leadingPath,
            label: "leadingClip"
        )
        let trailingDict = try parseClipDict(
            from: req.trailingClipPayloadJSON,
            fallbackPath: req.trailingPath,
            label: "trailingClip"
        )

        let w = max(64, (req.width / 2) * 2)
        let h = max(64, (req.height / 2) * 2)
        let fps = max(12, min(120, req.fps))

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let token = UUID().uuidString
        let specURL = parentDir.appendingPathComponent(".spec-\(token).json")
        let tempOutURL = parentDir.appendingPathComponent(".tmp-\(token)-\(outputURL.lastPathComponent)")
        defer {
            if FileManager.default.fileExists(atPath: specURL.path) {
                try? FileManager.default.removeItem(at: specURL)
            }
            if FileManager.default.fileExists(atPath: tempOutURL.path) {
                try? FileManager.default.removeItem(at: tempOutURL)
            }
        }

        let specObject: [String: Any] = [
            "cacheVersion": req.cacheVersion,
            "kind": normalizedKind,
            "duration": req.duration,
            "width": w,
            "height": h,
            "fps": fps,
            "leadingClip": leadingDict,
            "trailingClip": trailingDict
        ]
        let specData = try JSONSerialization.data(
            withJSONObject: specObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try specData.write(to: specURL, options: .atomic)

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            scriptURL.path,
            "--render-transition-cache",
            specURL.path,
            tempOutURL.path
        ]

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(extraPath):\(existing)"
        } else {
            env["PATH"] = extraPath
        }
        process.environment = env

        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        try? stderrPipe.fileHandleForWriting.close()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit code \(process.terminationStatus)"
            throw TransitionEngineError.renderFailed(errText)
        }

        guard Self.isValidCacheFile(at: tempOutURL) else {
            throw TransitionEngineError.emptyOutput(tempOutURL.path)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempOutURL, to: outputURL)
    }
}

// MARK: - Live Transition Compositor View (All 14 Distinct Geometries)

private struct TransitionRectMask: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        let clamped = rect.intersection(bounds)
        return clamped.isNull ? Path() : Path(clamped)
    }
}

private struct TransitionCircleMask: Shape {
    let radius: CGFloat

    func path(in bounds: CGRect) -> Path {
        let r = max(0, radius)
        if r <= 0.01 { return Path() }
        let ellipse = CGRect(
            x: bounds.midX - r,
            y: bounds.midY - r,
            width: r * 2,
            height: r * 2
        )
        return Path(ellipseIn: ellipse)
    }
}

private struct TransitionPixelizeTileMask: Shape {
    let progress: Double
    let columns: Int
    let rows: Int

    func path(in bounds: CGRect) -> Path {
        let cols = max(2, columns)
        let rws = max(2, rows)
        let cellW = bounds.width / CGFloat(cols)
        let cellH = bounds.height / CGFloat(rws)
        var path = Path()

        for r in 0..<rws {
            for c in 0..<cols {
                let hash = ((c * 37 + r * 73 + (c ^ r) * 19) % 29)
                let threshold = (Double(hash) + 0.5) / 29.0
                if progress >= threshold {
                    let tile = CGRect(
                        x: bounds.minX + CGFloat(c) * cellW,
                        y: bounds.minY + CGFloat(r) * cellH,
                        width: cellW + 0.5,
                        height: cellH + 0.5
                    )
                    path.addRect(tile)
                }
            }
        }
        return path
    }
}

/// Immediate 14-transition geometric compositor used while same-source cache renders (~150ms).
/// Accepts pre-filtered / flipped / rotated / cropped Leading & Trailing views so effects stay visible during fallback.
struct LiveTransitionCompositorView<Leading: View, Trailing: View>: View {
    let kind: String
    let progress: Double
    private let leading: Leading
    private let trailing: Trailing

    init(
        kind: String,
        progress: Double,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.kind = kind
        self.progress = progress
        self.leading = leading()
        self.trailing = trailing()
    }

    private var clampedProgress: Double {
        progress.isFinite ? min(1.0, max(0.0, progress)) : 0.0
    }

    var body: some View {
        let p = clampedProgress
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        GeometryReader { proxy in
            let w = max(1, proxy.size.width)
            let h = max(1, proxy.size.height)
            let maxRadius = hypot(w, h) * 0.5

            ZStack {
                switch normalizedKind {
                case "dissolve", "fade":
                    leading
                        .frame(width: w, height: h)
                        .compositingGroup()
                    trailing
                        .frame(width: w, height: h)
                        .compositingGroup()
                        .opacity(p)

                case "fadeblack":
                    Color.black
                    if p < 0.5 {
                        leading
                            .frame(width: w, height: h)
                            .compositingGroup()
                            .opacity(max(0.0, 1.0 - p * 2.0))
                    } else {
                        trailing
                            .frame(width: w, height: h)
                            .compositingGroup()
                            .opacity(min(1.0, (p - 0.5) * 2.0))
                    }

                case "fadewhite":
                    Color.white
                    if p < 0.5 {
                        leading
                            .frame(width: w, height: h)
                            .compositingGroup()
                            .opacity(max(0.0, 1.0 - p * 2.0))
                    } else {
                        trailing
                            .frame(width: w, height: h)
                            .compositingGroup()
                            .opacity(min(1.0, (p - 0.5) * 2.0))
                    }

                case "wipeleft":
                    leading
                        .frame(width: w, height: h)
                    trailing
                        .frame(width: w, height: h)
                        .clipShape(
                            TransitionRectMask(
                                rect: CGRect(x: w * (1.0 - p), y: 0, width: w * p, height: h)
                            )
                        )

                case "wiperight":
                    leading
                        .frame(width: w, height: h)
                    trailing
                        .frame(width: w, height: h)
                        .clipShape(
                            TransitionRectMask(
                                rect: CGRect(x: 0, y: 0, width: w * p, height: h)
                            )
                        )

                case "wipeup":
                    leading
                        .frame(width: w, height: h)
                    trailing
                        .frame(width: w, height: h)
                        .clipShape(
                            TransitionRectMask(
                                rect: CGRect(x: 0, y: h * (1.0 - p), width: w, height: h * p)
                            )
                        )

                case "wipedown":
                    leading
                        .frame(width: w, height: h)
                    trailing
                        .frame(width: w, height: h)
                        .clipShape(
                            TransitionRectMask(
                                rect: CGRect(x: 0, y: 0, width: w, height: h * p)
                            )
                        )

                case "slideleft":
                    leading
                        .frame(width: w, height: h)
                        .offset(x: -w * p)
                    trailing
                        .frame(width: w, height: h)
                        .offset(x: w * (1.0 - p))

                case "slideright":
                    leading
                        .frame(width: w, height: h)
                        .offset(x: w * p)
                    trailing
                        .frame(width: w, height: h)
                        .offset(x: -w * (1.0 - p))

                case "circleopen":
                    leading
                        .frame(width: w, height: h)
                    trailing
                        .frame(width: w, height: h)
                        .clipShape(TransitionCircleMask(radius: maxRadius * p))

                case "circleclose":
                    trailing
                        .frame(width: w, height: h)
                    leading
                        .frame(width: w, height: h)
                        .clipShape(TransitionCircleMask(radius: maxRadius * (1.0 - p)))

                case "pixelize":
                    let mosaicIntensity = sin(p * .pi)
                    leading
                        .frame(width: w, height: h)
                        .compositingGroup()
                    trailing
                        .frame(width: w, height: h)
                        .compositingGroup()
                        .opacity(p * 0.45)
                    trailing
                        .frame(width: w, height: h)
                        .clipShape(TransitionPixelizeTileMask(progress: p, columns: 10, rows: 6))
                    Canvas { context, size in
                        guard mosaicIntensity > 0.02 else { return }
                        let cols = 10
                        let rows = 6
                        let cellW = size.width / CGFloat(cols)
                        let cellH = size.height / CGFloat(rows)
                        var grid = Path()
                        for c in 1..<cols {
                            let x = CGFloat(c) * cellW
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        for r in 1..<rows {
                            let y = CGFloat(r) * cellH
                            grid.move(to: CGPoint(x: 0, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(
                            grid,
                            with: .color(Color.white.opacity(0.24 * mosaicIntensity)),
                            lineWidth: 1.0
                        )
                    }
                    .allowsHitTesting(false)

                case "smoothleft":
                    leading
                        .frame(width: w, height: h)
                    trailing
                        .frame(width: w, height: h)
                        .compositingGroup()
                        .mask(smoothLeftMask(progress: p))

                case "zoomin":
                    leading
                        .frame(width: w, height: h)
                        .compositingGroup()
                        .scaleEffect(1.0 + 0.18 * p)
                        .opacity(1.0 - p)
                    trailing
                        .frame(width: w, height: h)
                        .compositingGroup()
                        .scaleEffect(0.85 + 0.15 * p)
                        .opacity(p)

                default:
                    // Hard cut for "cut" or unrecognized kind (never silently degrade to dissolve)
                    if p < 0.5 {
                        leading.frame(width: w, height: h)
                    } else {
                        trailing.frame(width: w, height: h)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }

    private func smoothLeftMask(progress p: Double) -> some View {
        let feather = 0.24
        let edge = 1.0 - p * (1.0 + feather)
        let stop0 = min(1.0, max(0.0, edge))
        let stop1 = min(1.0, max(stop0, edge + feather))

        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: stop0),
                .init(color: .white, location: stop1),
                .init(color: .white, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Transition Card Animated Preview

struct TransitionCardAnimatedPreview: View {
    let kindRaw: String
    let title: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                let progress = Self.loopProgress(for: context.date)
                LiveTransitionCompositorView(
                    kind: kindRaw,
                    progress: progress,
                    leading: { clipACard },
                    trailing: { clipBCard }
                )
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color(red: 0.40, green: 0.72, blue: 1.0)
                            : Color.white.opacity(0.14),
                        lineWidth: isSelected ? 1.5 : 0.75
                    )
            )

            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : Color.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isSelected
                        ? Color(red: 0.16, green: 0.26, blue: 0.40).opacity(0.85)
                        : Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.92)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected
                        ? Color(red: 0.42, green: 0.72, blue: 1.0).opacity(0.9)
                        : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    private static func loopProgress(for date: Date) -> Double {
        let cycle = 2.2
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        let phase = t < 0 ? t + cycle : t
        if phase < 0.30 {
            return 0.0
        } else if phase < 1.40 {
            let linear = (phase - 0.30) / 1.10
            return linear * linear * (3.0 - 2.0 * linear)
        } else if phase < 1.95 {
            return 1.0
        } else {
            return 0.0
        }
    }

    private var clipACard: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.23, blue: 0.47),
                    Color(red: 0.07, green: 0.13, blue: 0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                var stripes = Path()
                let step: CGFloat = 10
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += step
                }
                context.stroke(
                    stripes,
                    with: .color(Color(red: 0.48, green: 0.72, blue: 1.0).opacity(0.24)),
                    lineWidth: 2.2
                )
            }
            Text("A")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.86))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 3))
        }
    }

    private var clipBCard: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.50, blue: 0.53),
                    Color(red: 0.85, green: 0.53, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                let center = CGPoint(x: size.width * 0.72, y: size.height * 0.34)
                let ring = Path(ellipseIn: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
                context.stroke(ring, with: .color(Color.white.opacity(0.28)), lineWidth: 2.0)
            }
            Text("B")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.92))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 3))
        }
    }
}

// MARK: - Media Visual Cache (Filmstrips & Real Audio Waveforms)

@MainActor
final class MediaVisualCache: ObservableObject {
    static let shared = MediaVisualCache()

    @Published var filmstrips: [String: [CGImage]] = [:]
    @Published var waveforms: [String: [Float]] = [:]

    private var inFlightFilmstrips: Set<String> = []
    private var inFlightWaveforms: Set<String> = []
    private var failedFilmstrips: Set<String> = []
    private var failedWaveforms: Set<String> = []

    private var pendingFilmstrips: [(path: String, count: Int)] = []
    private var pendingWaveforms: [(path: String, bins: Int)] = []
    private var activeFilmstripJobs: Int = 0
    private var activeWaveformJobs: Int = 0
    private let maxConcurrentJobs: Int = 3

    private init() {}

    func requestFilmstrip(path: String, count: Int = 6) {
        let clampedCount = max(1, min(24, count))
        guard !path.isEmpty else { return }
        if let existing = filmstrips[path], !existing.isEmpty {
            return
        }
        if inFlightFilmstrips.contains(path) || failedFilmstrips.contains(path) {
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            failedFilmstrips.insert(path)
            return
        }

        inFlightFilmstrips.insert(path)
        pendingFilmstrips.append((path: path, count: clampedCount))
        pumpFilmstripQueue()
    }

    func requestWaveform(path: String, bins: Int = 64) {
        let clampedBins = max(8, min(512, bins))
        guard !path.isEmpty else { return }
        if let existing = waveforms[path], !existing.isEmpty {
            return
        }
        if inFlightWaveforms.contains(path) || failedWaveforms.contains(path) {
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            failedWaveforms.insert(path)
            return
        }

        inFlightWaveforms.insert(path)
        pendingWaveforms.append((path: path, bins: clampedBins))
        pumpWaveformQueue()
    }

    func invalidate(path: String) {
        filmstrips.removeValue(forKey: path)
        waveforms.removeValue(forKey: path)
        failedFilmstrips.remove(path)
        failedWaveforms.remove(path)
    }

    private func pumpFilmstripQueue() {
        while activeFilmstripJobs < maxConcurrentJobs, !pendingFilmstrips.isEmpty {
            let job = pendingFilmstrips.removeFirst()
            activeFilmstripJobs += 1
            Task.detached(priority: .utility) {
                let images = await MediaVisualCache.extractFilmstrip(path: job.path, count: job.count)
                await MainActor.run {
                    self.activeFilmstripJobs = max(0, self.activeFilmstripJobs - 1)
                    self.inFlightFilmstrips.remove(job.path)
                    if images.isEmpty {
                        self.failedFilmstrips.insert(job.path)
                    } else {
                        self.filmstrips[job.path] = images
                    }
                    self.pumpFilmstripQueue()
                }
            }
        }
    }

    private func pumpWaveformQueue() {
        while activeWaveformJobs < maxConcurrentJobs, !pendingWaveforms.isEmpty {
            let job = pendingWaveforms.removeFirst()
            activeWaveformJobs += 1
            Task.detached(priority: .utility) {
                let peaks = await MediaVisualCache.extractWaveform(path: job.path, bins: job.bins)
                await MainActor.run {
                    self.activeWaveformJobs = max(0, self.activeWaveformJobs - 1)
                    self.inFlightWaveforms.remove(job.path)
                    if peaks.isEmpty {
                        self.failedWaveforms.insert(job.path)
                    } else {
                        self.waveforms[job.path] = peaks
                    }
                    self.pumpWaveformQueue()
                }
            }
        }
    }

    nonisolated static func extractFilmstrip(path: String, count: Int = 6) async -> [CGImage] {
        let clampedCount = max(1, min(24, count))
        let url = URL(fileURLWithPath: path)

        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"]
        if imageExtensions.contains(ext) {
            if let thumb = loadStillThumbnail(url: url, maxPixelSize: 96) {
                return [thumb]
            }
            return []
        }

        let asset = AVURLAsset(url: url)
        guard let durationCM = try? await asset.load(.duration) else {
            return []
        }
        let durationSeconds = durationCM.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return []
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 96)
        let tolerance = CMTime(seconds: min(0.25, durationSeconds / Double(clampedCount * 2)), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [CGImage] = []
        frames.reserveCapacity(clampedCount)

        for idx in 0..<clampedCount {
            let frac = (Double(idx) + 0.5) / Double(clampedCount)
            let seconds = max(0.0, min(durationSeconds - 0.01, durationSeconds * frac))
            let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: cmTime) {
                frames.append(result.image)
            }
        }

        if frames.isEmpty, let first = try? await generator.image(at: .zero) {
            frames.append(first.image)
        }
        return frames
    }

    nonisolated static func extractWaveform(path: String, bins: Int = 64) async -> [Float] {
        let clampedBins = max(8, min(512, bins))
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = audioTracks.first else {
            return []
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            return []
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return []
        }
        reader.add(output)

        guard reader.startReading() else {
            return []
        }

        let blockSize = 512
        var blockPeaks: [Float] = []
        var currentBlockPeak: Float = 0
        var currentBlockCount: Int = 0
        var scratchBytes = [UInt8]()

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            let totalLength = CMBlockBufferGetDataLength(blockBuffer)
            guard totalLength >= MemoryLayout<Float>.size else { continue }

            var lengthAtOffset: Int = 0
            var totalBytes: Int = 0
            var dataPointer: UnsafeMutablePointer<CChar>?

            let ptrStatus = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalBytes,
                dataPointerOut: &dataPointer
            )

            if ptrStatus == kCMBlockBufferNoErr,
               let rawPtr = dataPointer,
               lengthAtOffset == totalBytes {
                let floatCount = totalBytes / MemoryLayout<Float>.size
                rawPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
                    for i in 0..<floatCount {
                        let v = abs(floats[i])
                        if v.isFinite, v > currentBlockPeak {
                            currentBlockPeak = v
                        }
                        currentBlockCount += 1
                        if currentBlockCount >= blockSize {
                            blockPeaks.append(currentBlockPeak)
                            currentBlockPeak = 0
                            currentBlockCount = 0
                        }
                    }
                }
            } else {
                if scratchBytes.count < totalLength {
                    scratchBytes = [UInt8](repeating: 0, count: totalLength)
                }
                let copyStatus = scratchBytes.withUnsafeMutableBytes { dest -> OSStatus in
                    guard let base = dest.baseAddress else { return kCMBlockBufferBadOffsetParameterErr }
                    return CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: totalLength,
                        destination: base
                    )
                }
                if copyStatus == kCMBlockBufferNoErr {
                    let floatCount = totalLength / MemoryLayout<Float>.size
                    scratchBytes.withUnsafeBytes { raw in
                        let floats = raw.bindMemory(to: Float.self)
                        for i in 0..<floatCount {
                            let v = abs(floats[i])
                            if v.isFinite, v > currentBlockPeak {
                                currentBlockPeak = v
                            }
                            currentBlockCount += 1
                            if currentBlockCount >= blockSize {
                                blockPeaks.append(currentBlockPeak)
                                currentBlockPeak = 0
                                currentBlockCount = 0
                            }
                        }
                    }
                }
            }
        }

        if currentBlockCount > 0 {
            blockPeaks.append(currentBlockPeak)
        }

        if reader.status == .reading {
            reader.cancelReading()
        }

        guard !blockPeaks.isEmpty else {
            return Array(repeating: Float(0.05), count: clampedBins)
        }

        var binned = [Float](repeating: 0, count: clampedBins)
        if blockPeaks.count >= clampedBins {
            for b in 0..<clampedBins {
                let start = (b * blockPeaks.count) / clampedBins
                let end = max(start + 1, ((b + 1) * blockPeaks.count) / clampedBins)
                var peak: Float = 0
                for idx in start..<min(end, blockPeaks.count) {
                    if blockPeaks[idx] > peak {
                        peak = blockPeaks[idx]
                    }
                }
                binned[b] = peak
            }
        } else {
            for b in 0..<clampedBins {
                let pos = Double(b) * Double(blockPeaks.count - 1) / Double(max(1, clampedBins - 1))
                let lo = Int(floor(pos))
                let hi = min(blockPeaks.count - 1, lo + 1)
                let frac = Float(pos - Double(lo))
                binned[b] = blockPeaks[lo] * (1.0 - frac) + blockPeaks[hi] * frac
            }
        }

        let globalMax = binned.max() ?? 0
        if globalMax <= 1e-6 {
            return Array(repeating: Float(0.05), count: clampedBins)
        }

        return binned.map { value in
            min(1.0, max(0.05, value / globalMax))
        }
    }

    private nonisolated static func loadStillThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Same-Source Processed Clip Effect Preview Cache (Chroma Key, Crop, Color Grading, Speed/Reverse/Freeze)

enum ClipEffectAlphaMode: String, Codable, Hashable, Sendable {
    case opaqueMP4 = "opaque_mp4"
    case stackedAlphaMP4 = "stacked_mp4"
    case rgbaPNG = "rgba_png"

    var fileExtension: String {
        switch self {
        case .rgbaPNG: return "png"
        case .opaqueMP4, .stackedAlphaMP4: return "mp4"
        }
    }
}

struct ClipEffectCacheRequest: Hashable, Sendable {
    static let currentCacheVersion: Int = 1

    let key: String
    let cacheVersion: Int
    let alphaMode: ClipEffectAlphaMode
    let sourcePath: String
    let clipPayloadJSON: String
    let duration: Double
    let width: Int
    let height: Int
    let fps: Int

    init(
        cacheVersion: Int = currentCacheVersion,
        alphaMode: ClipEffectAlphaMode,
        sourcePath: String,
        clipPayloadJSON: String,
        duration: Double,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 24
    ) {
        let canonical = Self.canonicalizeJSONString(clipPayloadJSON)
        self.cacheVersion = cacheVersion
        self.alphaMode = alphaMode
        self.sourcePath = sourcePath
        self.clipPayloadJSON = canonical
        self.duration = duration
        self.width = width
        self.height = height
        self.fps = fps
        self.key = Self.makeKey(
            cacheVersion: cacheVersion,
            alphaMode: alphaMode,
            sourcePath: sourcePath,
            clipPayloadJSON: canonical,
            duration: duration,
            width: width,
            height: height,
            fps: fps
        )
    }

    static func makeKey(
        cacheVersion: Int = currentCacheVersion,
        alphaMode: ClipEffectAlphaMode,
        sourcePath: String,
        clipPayloadJSON: String,
        duration: Double,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 24
    ) -> String {
        let sig = fileSignature(for: sourcePath)
        let canonical = canonicalizeJSONString(clipPayloadJSON)
        let payload = [
            "md_clip_fx_v\(cacheVersion)",
            alphaMode.rawValue,
            String(format: "%.4f", duration),
            "\(width)x\(height)@\(fps)",
            sourcePath,
            sig,
            canonical
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "fx-\(alphaMode.rawValue)-v\(cacheVersion)-\(hex.prefix(28))"
    }

    private static func canonicalizeJSONString(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(obj),
              let sortedData = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let sortedStr = String(data: sortedData, encoding: .utf8) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sortedStr
    }

    private static func fileSignature(for path: String) -> String {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "missing"
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return String(format: "%.3f_%lld", mtime, size)
    }
}

@MainActor
final class ClipEffectPreviewCache: ObservableObject {
    static let shared = ClipEffectPreviewCache()
    static let cacheDirectoryURL = URL(fileURLWithPath: "/private/tmp/motiondesk-clip-fx-cache", isDirectory: true)

    var timelineRenderScriptURL: URL? = nil

    @Published var readyURLs: [String: URL] = [:]
    @Published var readyImages: [String: NSImage] = [:]
    @Published var renderingKeys: Set<String> = []
    @Published var errors: [String: String] = [:]
    @Published var playableKeys: Set<String> = []

    private var players: [String: AVPlayer] = [:]
    private var videoOutputs: [String: AVPlayerItemVideoOutput] = [:]
    private var alphaModes: [String: ClipEffectAlphaMode] = [:]
    private var statusObservations: [String: NSKeyValueObservation] = [:]
    private var primingKeys: Set<String> = []
    private var keyFPS: [String: Int] = [:]
    private var pendingLocalSeconds: [String: Double] = [:]
    private var pendingIsPlaying: [String: Bool] = [:]
    private var playerLRU: [String] = []
    private var pendingQueue: [(request: ClipEffectCacheRequest, scriptURL: URL?)] = []
    private var activeRenderCount: Int = 0
    private let maxConcurrentRenders: Int = 3
    private let maxCachedPlayers: Int = 16

    private init() {
        try? FileManager.default.createDirectory(
            at: Self.cacheDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func cacheFileURL(for req: ClipEffectCacheRequest) -> URL {
        let sanitized = req.key.replacingOccurrences(of: "/", with: "_")
        return Self.cacheDirectoryURL.appendingPathComponent("\(sanitized).\(req.alphaMode.fileExtension)")
    }

    func isReadyForDisplay(req: ClipEffectCacheRequest) -> Bool {
        switch req.alphaMode {
        case .rgbaPNG:
            if readyImages[req.key] != nil {
                return true
            }
            let disk = readyURLs[req.key] ?? cacheFileURL(for: req)
            if Self.isValidCacheFile(at: disk), let img = NSImage(contentsOf: disk) {
                readyImages[req.key] = img
                readyURLs[req.key] = disk
                return true
            }
            return false
        case .opaqueMP4, .stackedAlphaMP4:
            guard playableKeys.contains(req.key),
                  let player = players[req.key],
                  player.currentItem?.status == .readyToPlay else {
                return false
            }
            if req.alphaMode == .stackedAlphaMP4 {
                return videoOutputs[req.key] != nil
            }
            return true
        }
    }

    func image(for key: String) -> NSImage? {
        readyImages[key]
    }

    func videoOutput(for key: String) -> AVPlayerItemVideoOutput? {
        videoOutputs[key]
    }

    func ensureCached(_ req: ClipEffectCacheRequest, timelineRenderScript: URL? = nil) {
        let key = req.key
        keyFPS[key] = max(12, min(60, req.fps))
        alphaModes[key] = req.alphaMode
        let outURL = cacheFileURL(for: req)

        if req.alphaMode == .rgbaPNG, readyImages[key] != nil {
            return
        }
        if let existing = readyURLs[key], Self.isValidCacheFile(at: existing) {
            if req.alphaMode == .rgbaPNG, readyImages[key] == nil, let img = NSImage(contentsOf: existing) {
                readyImages[key] = img
            }
            return
        }
        if Self.isValidCacheFile(at: outURL) {
            readyURLs[key] = outURL
            if req.alphaMode == .rgbaPNG, let img = NSImage(contentsOf: outURL) {
                readyImages[key] = img
            }
            errors.removeValue(forKey: key)
            return
        }
        if renderingKeys.contains(key) || errors[key] != nil {
            return
        }

        let resolvedScript = timelineRenderScript ?? timelineRenderScriptURL
        renderingKeys.insert(key)
        pendingQueue.append((request: req, scriptURL: resolvedScript))
        pumpQueue()
    }

    private func pumpQueue() {
        while activeRenderCount < maxConcurrentRenders, !pendingQueue.isEmpty {
            let entry = pendingQueue.removeFirst()
            let req = entry.request
            let scriptURL = entry.scriptURL
            let key = req.key
            let outURL = cacheFileURL(for: req)

            if Self.isValidCacheFile(at: outURL) {
                renderingKeys.remove(key)
                readyURLs[key] = outURL
                if req.alphaMode == .rgbaPNG, let img = NSImage(contentsOf: outURL) {
                    readyImages[key] = img
                }
                errors.removeValue(forKey: key)
                continue
            }

            activeRenderCount += 1
            Task.detached(priority: .userInitiated) {
                do {
                    try ClipEffectPreviewCache.renderClipPreviewSync(
                        req,
                        outputURL: outURL,
                        timelineRenderScript: scriptURL
                    )
                    await MainActor.run {
                        self.handleRenderCompletion(req: req, outputURL: outURL, error: nil)
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self.handleRenderCompletion(req: req, outputURL: nil, error: message)
                    }
                }
            }
        }
    }

    private func handleRenderCompletion(req: ClipEffectCacheRequest, outputURL: URL?, error: String?) {
        activeRenderCount = max(0, activeRenderCount - 1)
        renderingKeys.remove(req.key)
        if let outputURL, Self.isValidCacheFile(at: outputURL) {
            readyURLs[req.key] = outputURL
            errors.removeValue(forKey: req.key)
            if req.alphaMode == .rgbaPNG, let img = NSImage(contentsOf: outputURL) {
                readyImages[req.key] = img
            } else {
                // Immediately prime player if this clip is currently visible at the playhead
                if let pendingSec = pendingLocalSeconds[req.key] {
                    sync(
                        req: req,
                        localSeconds: pendingSec,
                        isPlaying: pendingIsPlaying[req.key] ?? false,
                        exact: true
                    )
                }
            }
        } else if let error {
            errors[req.key] = error
        }
        pumpQueue()
    }

    func player(for req: ClipEffectCacheRequest) -> AVPlayer? {
        guard req.alphaMode != .rgbaPNG else { return nil }
        let key = req.key
        if let cached = players[key] {
            touchPlayerLRU(key)
            return cached
        }

        let resolvedURL: URL
        if let ready = readyURLs[key], Self.isValidCacheFile(at: ready) {
            resolvedURL = ready
        } else {
            let diskURL = cacheFileURL(for: req)
            guard Self.isValidCacheFile(at: diskURL) else { return nil }
            readyURLs[key] = diskURL
            resolvedURL = diskURL
        }

        let item = AVPlayerItem(url: resolvedURL)
        if req.alphaMode == .stackedAlphaMP4 {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ])
            item.add(output)
            videoOutputs[key] = output
        }

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false

        players[key] = player
        alphaModes[key] = req.alphaMode
        touchPlayerLRU(key)

        let obs = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            Task { @MainActor [weak self] in
                self?.handleItemStatusChange(key: key, status: status)
            }
        }
        statusObservations[key] = obs
        evictExcessPlayersIfNeeded(keeping: key)
        return player
    }

    private func handleItemStatusChange(key: String, status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            primePlayerAtPendingTimeIfNeeded(key: key)
        case .failed:
            playableKeys.remove(key)
            primingKeys.remove(key)
            if let errMsg = players[key]?.currentItem?.error?.localizedDescription {
                errors[key] = errMsg
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func primePlayerAtPendingTimeIfNeeded(key: String) {
        guard !playableKeys.contains(key),
              !primingKeys.contains(key),
              let player = players[key],
              let item = player.currentItem,
              item.status == .readyToPlay else {
            return
        }

        primingKeys.insert(key)
        let fps = Double(max(12, min(60, keyFPS[key] ?? 24)))
        let frameDur = 1.0 / fps
        let target = clampedTargetSeconds(pendingLocalSeconds[key] ?? 0.0, for: item, frameDuration: frameDur)
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.handleInitialPrimeSeekCompleted(key: key, finished: finished)
            }
        }
    }

    private func handleInitialPrimeSeekCompleted(key: String, finished: Bool) {
        primingKeys.remove(key)
        guard let player = players[key],
              let item = player.currentItem,
              item.status == .readyToPlay else {
            return
        }

        let fps = Double(max(12, min(60, keyFPS[key] ?? 24)))
        let frameDur = 1.0 / fps
        let latestTarget = clampedTargetSeconds(pendingLocalSeconds[key] ?? 0.0, for: item, frameDuration: frameDur)
        let current = player.currentTime().seconds
        let drift = current.isFinite ? abs(current - latestTarget) : Double.infinity

        if !finished || drift > max(0.015, frameDur * 0.85) {
            primePlayerAtPendingTimeIfNeeded(key: key)
            return
        }

        playableKeys.insert(key)
        if pendingIsPlaying[key] == true {
            if player.rate == 0 {
                player.play()
            }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    func sync(req: ClipEffectCacheRequest, localSeconds: Double, isPlaying: Bool, exact: Bool) {
        let key = req.key
        keyFPS[key] = max(12, min(60, req.fps))
        alphaModes[key] = req.alphaMode
        let sanitizedLocal = localSeconds.isFinite ? max(0.0, localSeconds) : 0.0
        pendingLocalSeconds[key] = sanitizedLocal
        pendingIsPlaying[key] = isPlaying

        if req.alphaMode == .rgbaPNG {
            _ = isReadyForDisplay(req: req)
            return
        }

        guard let player = player(for: req),
              let item = player.currentItem else {
            return
        }

        if item.status != .readyToPlay {
            if player.rate != 0 {
                player.pause()
            }
            return
        }

        if !playableKeys.contains(key) {
            primePlayerAtPendingTimeIfNeeded(key: key)
            return
        }

        let effectiveFPS = Double(max(12, min(60, keyFPS[key] ?? 24)))
        let frameDur = 1.0 / effectiveFPS
        let target = clampedTargetSeconds(sanitizedLocal, for: item, frameDuration: frameDur)
        let current = player.currentTime().seconds
        let drift = current.isFinite ? abs(current - target) : Double.infinity
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)

        if isPlaying {
            let seekThreshold = exact ? max(0.015, frameDur * 0.75) : max(0.06, frameDur * 2.4)
            if drift > seekThreshold {
                let tol = exact ? CMTime.zero : CMTime(seconds: frameDur * 0.5, preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: tol, toleranceAfter: tol)
            }
            if player.rate == 0 {
                player.play()
            }
        } else {
            if player.rate != 0 {
                player.pause()
            }
            let seekThreshold = exact ? max(0.004, frameDur * 0.25) : max(0.015, frameDur * 0.75)
            if drift > seekThreshold {
                let tol = exact ? CMTime.zero : CMTime(seconds: frameDur * 0.5, preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: tol, toleranceAfter: tol)
            }
        }
    }

    func pauseAll(except activeKeys: Set<String> = []) {
        for (key, player) in players where !activeKeys.contains(key) {
            pendingIsPlaying[key] = false
            if player.rate != 0 {
                player.pause()
            }
        }
    }

    private func clampedTargetSeconds(_ raw: Double, for item: AVPlayerItem, frameDuration: Double) -> Double {
        var target = raw.isFinite ? max(0.0, raw) : 0.0
        let itemDuration = item.duration.seconds
        if itemDuration.isFinite, itemDuration > frameDuration {
            let maxSafe = max(0.0, itemDuration - min(0.004, frameDuration * 0.25))
            target = min(target, maxSafe)
        }
        return target
    }

    private func touchPlayerLRU(_ key: String) {
        playerLRU.removeAll { $0 == key }
        playerLRU.append(key)
    }

    private func evictExcessPlayersIfNeeded(keeping protectedKey: String) {
        while players.count > maxCachedPlayers, let oldest = playerLRU.first {
            if oldest == protectedKey { break }
            playerLRU.removeFirst()
            statusObservations.removeValue(forKey: oldest)?.invalidate()
            playableKeys.remove(oldest)
            primingKeys.remove(oldest)
            pendingLocalSeconds.removeValue(forKey: oldest)
            pendingIsPlaying.removeValue(forKey: oldest)
            videoOutputs.removeValue(forKey: oldest)
            if let removed = players.removeValue(forKey: oldest) {
                removed.pause()
                removed.replaceCurrentItem(with: nil)
            }
        }
    }

    private nonisolated static func isValidCacheFile(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size > 256
    }

    private nonisolated static func resolveTimelineRenderScript(_ overrideURL: URL?) throws -> URL {
        if let overrideURL {
            guard FileManager.default.fileExists(atPath: overrideURL.path) else {
                throw TransitionEngineError.missingTimelineRenderScript(overrideURL.path)
            }
            return overrideURL
        }
        if let bundled = Bundle.main.url(forResource: "timeline_render", withExtension: "py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        throw TransitionEngineError.missingTimelineRenderScript("Bundle.main 未找到 timeline_render.py")
    }

    private nonisolated static func locatePython3() throws -> URL {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw TransitionEngineError.missingPython3
    }

    nonisolated static func renderClipPreviewSync(
        _ req: ClipEffectCacheRequest,
        outputURL: URL,
        timelineRenderScript: URL? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: req.sourcePath) else {
            throw TransitionEngineError.missingSourceFile(req.sourcePath)
        }
        guard let data = req.clipPayloadJSON.data(using: .utf8),
              var clipDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransitionEngineError.invalidClipPayload("clipPayloadJSON 無效")
        }
        if (clipDict["path"] as? String)?.isEmpty ?? true {
            clipDict["path"] = req.sourcePath
        }

        let scriptURL = try resolveTimelineRenderScript(timelineRenderScript)
        let pythonURL = try locatePython3()

        let w = max(64, (req.width / 2) * 2)
        let h = max(64, (req.height / 2) * 2)
        let fps = max(12, min(60, req.fps))

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let token = UUID().uuidString
        let specURL = parentDir.appendingPathComponent(".clip-spec-\(token).json")
        let tempOutURL = parentDir.appendingPathComponent(".clip-tmp-\(token).\(req.alphaMode.fileExtension)")
        defer {
            try? FileManager.default.removeItem(at: specURL)
            try? FileManager.default.removeItem(at: tempOutURL)
        }

        let specObject: [String: Any] = [
            "cacheVersion": req.cacheVersion,
            "alphaMode": req.alphaMode.rawValue,
            "width": w,
            "height": h,
            "fps": fps,
            "clip": clipDict
        ]
        let specData = try JSONSerialization.data(
            withJSONObject: specObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try specData.write(to: specURL, options: .atomic)

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            scriptURL.path,
            "--render-clip-preview",
            specURL.path,
            tempOutURL.path
        ]

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(extraPath):\(existing)"
        } else {
            env["PATH"] = extraPath
        }
        process.environment = env

        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        try? stderrPipe.fileHandleForWriting.close()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit code \(process.terminationStatus)"
            throw TransitionEngineError.renderFailed(errText)
        }

        guard Self.isValidCacheFile(at: tempOutURL) else {
            throw TransitionEngineError.emptyOutput(tempOutURL.path)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempOutURL, to: outputURL)
    }
}

// MARK: - Hardware-Independent Alpha Compositor View for Stacked RGB+Alpha Preview Clips

@MainActor
final class AlphaStackedPlayerNSView: NSView {
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

    weak var player: AVPlayer?
    weak var videoOutput: AVPlayerItemVideoOutput?
    var desiredZPosition: CGFloat = 0
    var isPlaying: Bool = false {
        didSet { updateTimerState() }
    }
    var targetLocalTime: Double = 0 {
        didSet {
            if abs(targetLocalTime - oldValue) > 0.001 {
                pendingPausedRetries = 12
                refreshFrame(force: true)
                updateTimerState()
            }
        }
    }

    private var timer: Timer?
    private var lastRenderedItemTime: CMTime = .invalid
    private var pendingPausedRetries: Int = 12

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never intercept mouse clicks/drags meant for canvas subtitles or transform handles.
        return nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyZOrder()
        if superview == nil {
            stopTimer()
        } else {
            pendingPausedRetries = 12
            refreshFrame(force: true)
            updateTimerState()
        }
    }

    override func layout() {
        super.layout()
        applyZOrder()
    }

    func applyZOrder() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = desiredZPosition
        if let parent = superview {
            parent.wantsLayer = true
            parent.layer?.zPosition = desiredZPosition
        }
    }

    func configure(player: AVPlayer, output: AVPlayerItemVideoOutput, localTime: Double, isPlaying: Bool, zOrder: CGFloat) {
        let playerChanged = (self.player !== player) || (self.videoOutput !== output)
        self.player = player
        self.videoOutput = output
        self.desiredZPosition = zOrder
        applyZOrder()
        if playerChanged {
            lastRenderedItemTime = .invalid
            pendingPausedRetries = 15
        }
        self.isPlaying = isPlaying
        self.targetLocalTime = localTime
        if playerChanged || layer?.contents == nil {
            refreshFrame(force: true)
            updateTimerState()
        }
    }

    private func updateTimerState() {
        if isPlaying || pendingPausedRetries > 0 {
            if timer == nil {
                let interval = isPlaying ? (1.0 / 30.0) : 0.05
                timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.tick()
                    }
                }
            }
        } else {
            stopTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if isPlaying {
            refreshFrame(force: false)
        } else if pendingPausedRetries > 0 {
            pendingPausedRetries -= 1
            let drew = refreshFrame(force: true)
            if drew && pendingPausedRetries <= 8 {
                pendingPausedRetries = 0
                stopTimer()
            } else if pendingPausedRetries <= 0 {
                stopTimer()
            }
        } else {
            stopTimer()
        }
    }

    @discardableResult
    func refreshFrame(force: Bool) -> Bool {
        guard let player, let output = videoOutput else { return false }
        let hostTime = CACurrentMediaTime()
        var itemTime = output.itemTime(forHostTime: hostTime)
        if !itemTime.isValid || !isPlaying {
            itemTime = player.currentTime()
        }
        guard itemTime.isValid else { return false }

        if !force && !output.hasNewPixelBuffer(forItemTime: itemTime) {
            return false
        }

        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return false
        }

        let src = CIImage(cvPixelBuffer: pixelBuffer)
        let w = src.extent.width
        let halfH = floor(src.extent.height / 2.0)
        guard w >= 2, halfH >= 2 else { return false }

        // In FFmpeg vstack: top half (CoreImage y >= halfH) = RGB, bottom half (CoreImage y < halfH) = Alpha mask.
        let rgb = src
            .cropped(to: CGRect(x: 0, y: halfH, width: w, height: halfH))
            .transformed(by: CGAffineTransform(translationX: 0, y: -halfH))
        let maskGray = src.cropped(to: CGRect(x: 0, y: 0, width: w, height: halfH))
        let targetRect = CGRect(x: 0, y: 0, width: w, height: halfH)
        let clearBg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: targetRect)

        guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: rgb,
            kCIInputBackgroundImageKey: clearBg,
            kCIInputMaskImageKey: maskGray
        ]),
        let outImage = blend.outputImage?.cropped(to: targetRect),
        let cgImage = Self.sharedCIContext.createCGImage(outImage, from: targetRect) else {
            return false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = cgImage
        CATransaction.commit()
        lastRenderedItemTime = itemTime
        return true
    }
}

struct TimelineAlphaStackedPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let videoOutput: AVPlayerItemVideoOutput
    let localTime: Double
    let isPlaying: Bool
    var zOrder: CGFloat = 0

    func makeNSView(context: Context) -> AlphaStackedPlayerNSView {
        let view = AlphaStackedPlayerNSView()
        view.configure(player: player, output: videoOutput, localTime: localTime, isPlaying: isPlaying, zOrder: zOrder)
        return view
    }

    func updateNSView(_ view: AlphaStackedPlayerNSView, context: Context) {
        view.configure(player: player, output: videoOutput, localTime: localTime, isPlaying: isPlaying, zOrder: zOrder)
    }

    static func dismantleNSView(_ view: AlphaStackedPlayerNSView, coordinator: ()) {
        view.isPlaying = false
        view.player = nil
        view.videoOutput = nil
    }
}
