import AppKit
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let canvas = StudioTheme.canvas
let panel = StudioTheme.panel
let surface = StudioTheme.surface
let studioAccent = StudioTheme.coral
let imageTypes: Set<String> = ["png","jpg","jpeg","webp","tif","tiff","heic","bmp"]
let movieTypes: Set<String> = ["mov","mp4","m4v","webm","mkv"]
func filename(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

func datedDirectory(under root: URL, on date: Date = .now, in timeZone: TimeZone = .current) -> URL {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    let name = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    return root.appendingPathComponent(name, isDirectory: true)
}

struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var start = ""
    var end = ""
    var still: Bool { imageTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
}

struct OutputDimensions: Codable {
    var width: String
    var height: String

    var pixels: [String: Int]? {
        guard let w = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)),
              (64...4096).contains(w), (64...4096).contains(h) else { return nil }
        return ["width": w, "height": h]
    }
}

struct TimelineOutput: Codable {
    var aspect = "16:9"
    var dimensions: OutputDimensions?
    var fps: Int?
    var codec: String?
    var bitDepth: Int?
}

struct TimelineTransition: Codable, Equatable {
    let after: UUID
    let before: UUID
    let kind: String
    let seconds: Double
}

struct FrameTransition: Codable {
    var seconds = 3
    var prompt = ""
}

struct Project: Codable {
    var media: [String] = []
    var clips: [Clip] = []
    var endpoint = "http://127.0.0.1:8188"
    var workflow = ""
    var source = "zimage"
    var kind = "image"
    var style = "自然紀實"
    var prompt = ""
    var aspect = "16:9"
    var resolution = "480P"
    var seconds = 5
    var model = "upd5"
    var reference = ""
    var title = ""
    var localOnly: Bool?
    var optimize: Bool?
    var camera: String?
    var videoWorkflow: String?
    var cloudGPU: String?
    var localImageModel: String?
    var localVideoModel: String?
    var localImageLoRA: String?
    var localLoRAStrength: Double?
    var imageReference: String?
    var extraCloudImageReferences: [String]?
    var extraCloudVideoImages: [String]?
    var referenceVideo: String?
    var fixedSeed: String?
    var videoMethod: String?
    var firstFrame: String?
    var lastFrame: String?
    var keyframes: [String]?
    var segments: [FrameTransition]?
    var imageDimensions: OutputDimensions?
    var videoDimensions: OutputDimensions?
    var imageFolder: String?
    var videoFolder: String?
    var audioFolder: String?
    var timelineOutput: TimelineOutput? = TimelineOutput()
    var editTransitions: [TimelineTransition]?
    var multitrack: MultitrackTimeline?
    var localModelOverrides: [String: LocalModelOverrides]?
}

struct RecordedModelParams: Decodable {
    let loraStrength: Double?
}

struct RecordedGeneration: Decodable {
    let action, kind, prompt, model, resolution: String
    var aspect: String
    let seed, seconds: Int
    let gpu, workflow, lora, reference, referenceVideo: String?
    let referenceImages: [String]?
    let localOnly: Bool
    let videoMethod: String?
    let keyframes: [String]?
    let segments: [FrameTransition]?
    let pixelSize: [String: Int]?
    let modelParams: RecordedModelParams?

    static func read(asset: String, jobs: URL) -> Self? {
        let media = URL(fileURLWithPath: asset).standardizedFileURL
        let jobs = jobs.standardizedFileURL
        let containingFolder = media.deletingLastPathComponent()
        let original = containingFolder.lastPathComponent == "out"
            ? containingFolder.deletingLastPathComponent() : containingFolder
        let stem = media.deletingPathExtension().lastPathComponent
        let identifier = String(stem.suffix(36))
        let isPublished = (stem.hasPrefix("MotionDesk-Image-") || stem.hasPrefix("MotionDesk-Video-"))
            && UUID(uuidString: identifier) != nil
        let day = containingFolder.lastPathComponent
        let isDateFolder = day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        let datedJobs = jobs.appendingPathComponent(day, isDirectory: true)
        let folders = isPublished
            ? (isDateFolder ? [datedJobs.appendingPathComponent(".\(identifier)"),
                               datedJobs.appendingPathComponent(identifier)] : [])
                + [jobs.appendingPathComponent(identifier)]
            : [original]
        for folder in folders {
            if let settings = read(media: media, folder: folder, jobs: jobs) { return settings }
        }
        return nil
    }

    private static func read(media: URL, folder: URL, jobs: URL) -> Self? {
        let parent = folder.deletingLastPathComponent()
        let isDatedJob = parent.deletingLastPathComponent().path == jobs.path
            && parent.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        let name = folder.lastPathComponent
        let identifier = name.hasPrefix(".") ? String(name.dropFirst()) : name
        guard (parent.path == jobs.path || isDatedJob),
              UUID(uuidString: identifier) != nil,
              let result = try? Data(contentsOf: folder.appendingPathComponent("result.json")),
              let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              let paths = object["paths"] as? [String],
              (paths + (object["originalPaths"] as? [String] ?? [])).contains(where: {
                  URL(fileURLWithPath: $0).standardizedFileURL.path == media.path
              }),
              let input = try? Data(contentsOf: folder.appendingPathComponent("request.json")),
              var settings = try? JSONDecoder().decode(Self.self, from: input),
              ["image", "video"].contains(settings.kind),
              (["colab", "comfy", "wan22", "wan22_14b", "ltxv13b", "zimage", "krea2", "moss", "redcraft", "realxl", "iniverse_flux", "sdxl1", "openai_image", "gemini_image"].contains(settings.action)
               || settings.action.hasPrefix("umodel_")) else {
            return nil
        }
        if let actual = object["generationAspect"] as? String { settings.aspect = actual }
        return settings
    }
}

let styles = [
    ("自然紀實", "Observational documentary, natural light, unretouched texture, restrained colors."),
    ("清晨膠片", "Soft dawn sidelight, fine analog film grain, subdued contrast, warm highlights."),
    ("手繪水彩", "Hand-painted watercolor, textured paper, layered washes, soft flowing edges."),
    ("鉛筆故事", "Colored pencil sketchbook, fine paper grain, hand-drawn outlines, gentle color."),
    ("極簡產品", "Minimal product art direction, controlled studio light, clean silhouette, generous space."),
    ("不套風格", "")
]

enum Workspace: String {
    case generate
    case edit
}

struct BridgeShot {
    let id = UUID()
    let afterID: UUID
    let beforeID: UUID
    let afterPath: String
    let beforePath: String
    let afterStart: String
    let afterEnd: String
    let beforeStart: String
    let beforeEnd: String
    let afterName: String
    let beforeName: String
    let leadingFrame: String
    let trailingFrame: String
    var generatedVideo: String?
}

// MARK: - Edit Timeline v2 Time Engine & Playback

struct TimelineSegment: Equatable, Identifiable {
    let id: UUID
    let index: Int
    let clip: Clip
    let sourceStart: Double
    let sourceEnd: Double
    let sourceDuration: Double?
    let duration: Double
    let frames: Int
    let timelineStart: Double
    let timelineEnd: Double
    let incomingOverlap: Double
    let outgoingOverlap: Double
    let visualStart: Double
    let visualEnd: Double
    let isTrimValid: Bool
    let loadError: String?

    var visualDuration: Double { max(0, visualEnd - visualStart) }
}

struct TimelineJunction: Equatable, Identifiable {
    var id: UUID { afterID }
    let index: Int
    let afterID: UUID
    let beforeID: UUID
    let transition: TimelineTransition?
    let seamTime: Double
    let overlapStart: Double
    let overlapEnd: Double
    let overlapDuration: Double
    let overlapFrames: Int
    let isValid: Bool

    var isCut: Bool { transition == nil || transition?.kind == "cut" || overlapDuration <= 0 }
}

struct TimelineSample: Equatable {
    let time: Double
    let segment: TimelineSegment
    let sourceTime: Double
    let activeJunction: TimelineJunction?
    let transitionProgress: Double
}

enum TimelineSplitFailure: Error, Equatable {
    case emptyTimeline
    case noClipAtPlayhead
    case sourceDurationUnknown
    case sourceUnreadable(String)
    case tooCloseToEdge
    case insideTransitionOverlap
    case invalidTrimRange

    var message: String {
        switch self {
        case .emptyTimeline: return "時間軸尚無片段可分割。"
        case .noClipAtPlayhead: return "播放頭位置沒有可分割的片段。"
        case .sourceDurationUnknown: return "正在讀取影片長度，請稍候再分割。"
        case .sourceUnreadable(let reason): return "無法分割：\(reason)"
        case .tooCloseToEdge: return "播放頭距離片段邊緣過近（分割後每段需至少 0.1 秒）。"
        case .insideTransitionOverlap: return "播放頭位於相鄰轉場重疊區內，請移出重疊區或先縮短轉場後再分割。"
        case .invalidTrimRange: return "片段入出點無效，請先修正後再分割。"
        }
    }
}

struct TimelineSplitCandidate: Equatable {
    let segment: TimelineSegment
    let offsetInClip: Double
    let leftDuration: Double
    let rightDuration: Double
}

struct TimelineLayout: Equatable {
    static let fps: Double = 24.0
    static let minClipDuration: Double = 0.1
    static let defaultStillDuration: Double = 3.0
    static let supportedTransitionKinds: Set<String> = ["dissolve", "fadeblack", "wipeleft"]
    static let empty = TimelineLayout(clips: [], transitions: [], durations: [:])

    let segments: [TimelineSegment]
    let junctions: [TimelineJunction]
    let totalDuration: Double
    let hasTransitions: Bool
    let hasInvalidTransitions: Bool
    let totalOverlapDeducted: Double

    static func parseSeconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    static func quantizeFrames(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((seconds * fps).rounded(.toNearestOrEven))
    }

    static func formatTrimSeconds(_ value: Double) -> String {
        let safe = max(0, value.isFinite ? value : 0)
        let rounded = (safe * 1000).rounded() / 1000
        var text = String(format: "%.3f", rounded)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) {
            text.removeLast()
        }
        return text.isEmpty ? "0" : text
    }

    static func formatTimecode(_ seconds: Double) -> String {
        let safe = min(359_999.99, max(0, seconds.isFinite ? seconds : 0))
        let totalHundredths = Int((safe * 100).rounded())
        let mins = totalHundredths / 6000
        let secs = (totalHundredths % 6000) / 100
        let hundredths = totalHundredths % 100
        return String(format: "%02d:%02d.%02d", mins, secs, hundredths)
    }

    static func transitionLabel(_ kind: String) -> String {
        switch kind {
        case "dissolve": return "交叉淡化"
        case "fadeblack": return "淡黑"
        case "wipeleft": return "向左擦拭"
        default: return "硬切"
        }
    }

    init(clips: [Clip], transitions: [TimelineTransition?], durations: [String: Double], durationErrors: [String: String] = [:]) {
        guard !clips.isEmpty else {
            self.segments = []
            self.junctions = []
            self.totalDuration = 0
            self.hasTransitions = false
            self.hasInvalidTransitions = false
            self.totalOverlapDeducted = 0
            return
        }

        let pairCount = max(0, clips.count - 1)
        let normalizedTransitions: [TimelineTransition?] = (0..<pairCount).map { idx in
            guard transitions.indices.contains(idx), let tr = transitions[idx],
                  Self.supportedTransitionKinds.contains(tr.kind),
                  tr.seconds.isFinite, tr.seconds >= 0.1, tr.seconds <= 3.0 else {
                return nil
            }
            return tr
        }
        let needsTransitions = normalizedTransitions.contains { $0 != nil }

        struct RawSpec {
            let sourceStart: Double
            let sourceEnd: Double
            let sourceDuration: Double?
            let duration: Double
            let frames: Int
            let isTrimValid: Bool
        }

        let specs: [RawSpec] = clips.map { clip in
            if clip.still {
                let parsedEnd = Self.parseSeconds(clip.end)
                let rawEnd = parsedEnd ?? Self.defaultStillDuration
                let valid = (clip.end.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (parsedEnd != nil && rawEnd >= 1.0 / Self.fps))
                let rawLength = max(1.0 / Self.fps, rawEnd)
                let frames = max(1, Self.quantizeFrames(rawLength))
                let effective = needsTransitions ? Double(frames) / Self.fps : rawLength
                return RawSpec(sourceStart: 0, sourceEnd: rawLength, sourceDuration: nil,
                               duration: effective, frames: frames, isTrimValid: valid)
            } else {
                let probed = durations[clip.path]
                let parsedStart = Self.parseSeconds(clip.start)
                let parsedEnd = Self.parseSeconds(clip.end)
                let startTrimEmpty = clip.start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let endTrimEmpty = clip.end.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let start = max(0, parsedStart ?? 0)
                let end = parsedEnd ?? probed ?? (start + Self.defaultStillDuration)
                let rawLength = end - start
                let withinSource = probed.map { end <= $0 + 0.10 } ?? true
                let valid = (startTrimEmpty || (parsedStart != nil && (parsedStart ?? -1) >= 0))
                    && (endTrimEmpty || parsedEnd != nil)
                    && rawLength >= (1.0 / Self.fps)
                    && withinSource
                let safeLength = max(1.0 / Self.fps, rawLength.isFinite ? rawLength : Self.defaultStillDuration)
                let frames = max(1, Self.quantizeFrames(safeLength))
                let effective = needsTransitions ? Double(frames) / Self.fps : safeLength
                return RawSpec(sourceStart: start, sourceEnd: start + safeLength, sourceDuration: probed,
                               duration: effective, frames: frames, isTrimValid: valid)
            }
        }

        let requestedOverlapFrames: [Int] = normalizedTransitions.map { tr in
            guard let tr else { return 0 }
            return max(1, Self.quantizeFrames(tr.seconds))
        }

        var clipValidTransition = Array(repeating: true, count: clips.count)
        if needsTransitions {
            for i in 0..<clips.count {
                let incoming = i > 0 ? requestedOverlapFrames[i - 1] : 0
                let outgoing = i < pairCount ? requestedOverlapFrames[i] : 0
                let frames = specs[i].frames
                if max(incoming, outgoing) >= frames || incoming + outgoing > frames {
                    clipValidTransition[i] = false
                }
            }
        }

        var junctionValid: [Bool] = []
        var effectiveOverlaps: [Double] = []
        for idx in 0..<pairCount {
            if normalizedTransitions[idx] == nil {
                junctionValid.append(true)
                effectiveOverlaps.append(0)
            } else {
                let valid = clipValidTransition[idx] && clipValidTransition[idx + 1]
                junctionValid.append(valid)
                let requestedSec = Double(requestedOverlapFrames[idx]) / Self.fps
                let maxSafe = min(specs[idx].duration, specs[idx + 1].duration)
                effectiveOverlaps.append(valid ? requestedSec : min(requestedSec, maxSafe * 0.9))
            }
        }

        var timelineStarts: [Double] = []
        var timelineEnds: [Double] = []
        var cursor = 0.0
        var totalDeducted = 0.0
        for i in 0..<clips.count {
            if i > 0 {
                let overlap = effectiveOverlaps[i - 1]
                cursor = max(0, cursor - overlap)
                totalDeducted += overlap
            }
            timelineStarts.append(cursor)
            let end = cursor + specs[i].duration
            timelineEnds.append(end)
            cursor = end
        }

        let finalTotal = timelineEnds.last ?? 0

        // Compute non-overlapping visual seam midpoints whose intervals sum cleanly to finalTotal.
        var seamTimes: [Double] = []
        for idx in 0..<pairCount {
            let overlap = effectiveOverlaps[idx]
            let rawMid = timelineStarts[idx + 1] + overlap * 0.5
            let minBound = idx == 0 ? 0 : seamTimes[idx - 1] + 0.001
            let maxBound = finalTotal
            seamTimes.append(min(maxBound, max(minBound, rawMid)))
        }

        var builtSegments: [TimelineSegment] = []
        for i in 0..<clips.count {
            let incoming = i > 0 ? effectiveOverlaps[i - 1] : 0
            let outgoing = i < pairCount ? effectiveOverlaps[i] : 0
            let vStart = i == 0 ? 0 : seamTimes[i - 1]
            let vEnd = i == clips.count - 1 ? finalTotal : seamTimes[i]
            builtSegments.append(TimelineSegment(
                id: clips[i].id,
                index: i,
                clip: clips[i],
                sourceStart: specs[i].sourceStart,
                sourceEnd: specs[i].sourceEnd,
                sourceDuration: specs[i].sourceDuration,
                duration: specs[i].duration,
                frames: specs[i].frames,
                timelineStart: timelineStarts[i],
                timelineEnd: timelineEnds[i],
                incomingOverlap: incoming,
                outgoingOverlap: outgoing,
                visualStart: vStart,
                visualEnd: max(vStart, vEnd),
                isTrimValid: specs[i].isTrimValid,
                loadError: durationErrors[clips[i].path]
            ))
        }

        var builtJunctions: [TimelineJunction] = []
        for idx in 0..<pairCount {
            let overlap = effectiveOverlaps[idx]
            let overlapStart = timelineStarts[idx + 1]
            let overlapEnd = overlapStart + overlap
            builtJunctions.append(TimelineJunction(
                index: idx,
                afterID: clips[idx].id,
                beforeID: clips[idx + 1].id,
                transition: normalizedTransitions[idx],
                seamTime: seamTimes[idx],
                overlapStart: overlapStart,
                overlapEnd: overlapEnd,
                overlapDuration: overlap,
                overlapFrames: requestedOverlapFrames[idx],
                isValid: junctionValid[idx]
            ))
        }

        self.segments = builtSegments
        self.junctions = builtJunctions
        self.totalDuration = finalTotal
        self.hasTransitions = needsTransitions
        self.hasInvalidTransitions = builtJunctions.contains { !$0.isValid }
        self.totalOverlapDeducted = totalDeducted
    }

    func sample(at rawTime: Double) -> TimelineSample? {
        guard !segments.isEmpty else { return nil }
        let t = min(totalDuration, max(0, rawTime.isFinite ? rawTime : 0))

        // Find active segment using exact visual seam midpoints (matches rendered duration 1:1).
        let segment: TimelineSegment
        if t >= totalDuration - 1e-6 {
            segment = segments[segments.count - 1]
        } else if let found = segments.first(where: { t >= $0.visualStart - 1e-6 && t < $0.visualEnd - 1e-6 }) {
            segment = found
        } else if let found = segments.last(where: { t >= $0.visualStart - 1e-6 }) {
            segment = found
        } else {
            segment = segments[0]
        }

        let offset = min(segment.duration, max(0, t - segment.timelineStart))
        var sourceTime = segment.sourceStart + offset
        if let maxDur = segment.sourceDuration, maxDur > 0 {
            sourceTime = min(max(0, sourceTime), max(0, maxDur - 0.002))
        }

        var activeJunction: TimelineJunction? = nil
        var progress = 0.0
        for junction in junctions where !junction.isCut {
            if t >= junction.overlapStart - 1e-6 && t <= junction.overlapEnd + 1e-6 {
                activeJunction = junction
                progress = min(1, max(0, (t - junction.overlapStart) / max(0.001, junction.overlapDuration)))
                break
            }
        }

        return TimelineSample(
            time: t,
            segment: segment,
            sourceTime: sourceTime,
            activeJunction: activeJunction,
            transitionProgress: progress
        )
    }

    func splitCandidate(at rawTime: Double, preferredClipID: UUID?) -> Result<TimelineSplitCandidate, TimelineSplitFailure> {
        guard !segments.isEmpty else { return .failure(.emptyTimeline) }
        let t = min(totalDuration, max(0, rawTime.isFinite ? rawTime : 0))

        let segment: TimelineSegment?
        if let preferredClipID,
           let preferred = segments.first(where: { $0.id == preferredClipID }),
           t > preferred.visualStart + 1e-5 && t < preferred.visualEnd - 1e-5 {
            segment = preferred
        } else {
            segment = segments.first(where: { t >= $0.visualStart && t <= $0.visualEnd })
        }
        guard let target = segment else { return .failure(.noClipAtPlayhead) }

        if !target.clip.still && target.sourceDuration == nil && Self.parseSeconds(target.clip.end) == nil {
            if let err = target.loadError {
                return .failure(.sourceUnreadable(err))
            }
            return .failure(.sourceDurationUnknown)
        }
        guard target.isTrimValid else { return .failure(.invalidTrimRange) }

        let offset = t - target.timelineStart
        let leftDuration = offset
        let rightDuration = target.duration - offset

        if target.incomingOverlap > 0 && offset <= target.incomingOverlap + 1e-4 {
            return .failure(.insideTransitionOverlap)
        }
        if target.outgoingOverlap > 0 && rightDuration <= target.outgoingOverlap + 1e-4 {
            return .failure(.insideTransitionOverlap)
        }
        guard leftDuration >= Self.minClipDuration - 1e-4 && rightDuration >= Self.minClipDuration - 1e-4 else {
            return .failure(.tooCloseToEdge)
        }

        return .success(TimelineSplitCandidate(
            segment: target,
            offsetInClip: offset,
            leftDuration: leftDuration,
            rightDuration: rightDuration
        ))
    }
}

@MainActor final class TimelinePlaybackController: ObservableObject {
    @Published var playhead: Double = 0
    @Published var isPlaying: Bool = false
    @Published var activeSample: TimelineSample?
    @Published var currentStillImage: NSImage?
    @Published var currentVideoMissing: Bool = false
    @Published var playbackError: String? = nil
    @Published var playbackNeedsPermission: Bool = false

    let player = AVPlayer()

    private var layout: TimelineLayout = .empty
    private var loadedVideoPath: String?
    private var assetCache: [String: AVURLAsset] = [:]
    private var imageCache: [String: NSImage] = [:]
    private var playbackTimer: Timer?
    private var lastWallTime: CFTimeInterval = 0
    private var isSeeking = false
    private var queuedSeek: (time: Double, exact: Bool)?
    private var lastSyncedSegmentID: UUID?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemReady = false
    private var desiredSourceTime: Double = 0
    private var desiredExactSeek = true

    init() {
        player.actionAtItemEnd = .pause
    }

    func syncLayout(_ newLayout: TimelineLayout) {
        let oldDuration = layout.totalDuration
        layout = newLayout
        if newLayout.segments.isEmpty {
            pause()
            playhead = 0
            activeSample = nil
            currentStillImage = nil
            currentVideoMissing = false
            playbackError = nil
            playbackNeedsPermission = false
            loadedVideoPath = nil
            lastSyncedSegmentID = nil
            itemReady = false
            itemStatusObserver = nil
            player.replaceCurrentItem(with: nil)
            return
        }

        let clamped = min(newLayout.totalDuration, max(0, playhead))
        let clampedChanged = abs(clamped - playhead) > 1e-6 || abs(oldDuration - newLayout.totalDuration) > 1e-6
        playhead = clamped
        if !isPlaying {
            applySample(at: playhead, exact: true, forceReload: clampedChanged)
        } else {
            activeSample = newLayout.sample(at: playhead)
        }
    }

    func reloadCurrentSample() {
        assetCache.removeAll()
        imageCache.removeAll()
        loadedVideoPath = nil
        itemReady = false
        itemStatusObserver = nil
        playbackError = nil
        playbackNeedsPermission = false
        applySample(at: playhead, exact: true, forceReload: true)
    }

    func seek(to time: Double, exact: Bool = true) {
        guard !layout.segments.isEmpty else {
            playhead = 0
            activeSample = nil
            return
        }
        let clamped = min(layout.totalDuration, max(0, time.isFinite ? time : 0))
        playhead = clamped
        applySample(at: clamped, exact: exact, forceReload: false)
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard !layout.segments.isEmpty, layout.totalDuration > 0 else { return }
        if playhead >= layout.totalDuration - (1.0 / 48.0) {
            playhead = 0
        }
        isPlaying = true
        lastWallTime = CACurrentMediaTime()
        startCurrentSegmentPlayback(at: playhead)
        if !isPlaying { return }
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    func pause() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        player.pause()
    }

    func stepFrames(_ count: Int) {
        pause()
        seek(to: playhead + Double(count) / TimelineLayout.fps, exact: true)
    }

    func jumpToStart() {
        pause()
        seek(to: 0, exact: true)
    }

    func jumpToEnd() {
        pause()
        seek(to: layout.totalDuration, exact: true)
    }

    func tearDown() {
        pause()
        itemStatusObserver = nil
        itemReady = false
        player.replaceCurrentItem(with: nil)
        loadedVideoPath = nil
        lastSyncedSegmentID = nil
        imageCache.removeAll()
        assetCache.removeAll()
    }

    private func tick() {
        guard isPlaying, !layout.segments.isEmpty else {
            pause()
            return
        }
        if playbackError != nil || currentVideoMissing {
            pause()
            return
        }
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastWallTime))
        lastWallTime = now

        if let current = activeSample, !current.segment.clip.still {
            // Wait until AVPlayerItem reaches readyToPlay rather than advancing timecode over a black screen.
            if !itemReady {
                return
            }
        }

        var nextTime = playhead + dt
        if let current = activeSample,
           !current.segment.clip.still,
           !currentVideoMissing,
           loadedVideoPath == current.segment.clip.path,
           player.timeControlStatus == .playing {
            let playerSec = player.currentTime().seconds
            if playerSec.isFinite {
                let mapped = current.segment.timelineStart + (playerSec - current.segment.sourceStart)
                if mapped >= playhead - 0.04 && abs(mapped - (playhead + dt)) < 0.25 {
                    nextTime = mapped
                }
            }
        }

        if nextTime >= layout.totalDuration {
            playhead = layout.totalDuration
            pause()
            applySample(at: playhead, exact: true, forceReload: false)
            return
        }

        playhead = nextTime
        guard let nextSample = layout.sample(at: nextTime) else {
            pause()
            return
        }
        let segmentChanged = nextSample.segment.id != lastSyncedSegmentID
        activeSample = nextSample

        if segmentChanged {
            startCurrentSegmentPlayback(at: nextTime)
        } else if !nextSample.segment.clip.still && itemReady && playbackError == nil && player.rate == 0 {
            player.play()
        }
    }

    private func verifyReadable(path: String) -> (ok: Bool, missing: Bool, permissionDenied: Bool, message: String?) {
        let url = URL(fileURLWithPath: path)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
            return (true, false, false, nil)
        } catch let err as NSError {
            let underlying = err.userInfo[NSUnderlyingErrorKey] as? NSError
            let posixCode = underlying?.code ?? err.code
            if err.code == NSFileReadNoPermissionError || posixCode == Int(EPERM) || posixCode == Int(EACCES) {
                return (false, false, true, "無法讀取 \(filename(path))：macOS 未授權存取所在資料夾，請點「授權素材資料夾」或將素材移至可讀取位置。")
            }
            if err.code == NSFileReadNoSuchFileError || posixCode == Int(ENOENT) {
                return (false, true, false, "找不到片段檔案：\(filename(path))")
            }
            return (false, false, false, "無法讀取 \(filename(path))：\(err.localizedDescription)")
        }
    }

    private func startCurrentSegmentPlayback(at time: Double) {
        guard let sample = layout.sample(at: time) else { return }
        activeSample = sample
        lastSyncedSegmentID = sample.segment.id
        let path = sample.segment.clip.path
        let access = verifyReadable(path: path)
        currentVideoMissing = access.missing
        playbackNeedsPermission = access.permissionDenied
        playbackError = access.message
        if !access.ok {
            pause()
            currentStillImage = nil
            return
        }
        if sample.segment.clip.still {
            player.pause()
            currentStillImage = loadStillImage(path: path)
            if currentStillImage == nil {
                playbackError = "無法解碼圖片：\(filename(path))"
                pause()
            }
        } else {
            currentStillImage = nil
            desiredSourceTime = max(0, sample.sourceTime)
            desiredExactSeek = true
            ensureVideoLoaded(path: path, forceReload: false)
            if itemReady {
                let cm = CMTime(seconds: desiredSourceTime, preferredTimescale: 600)
                player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.isPlaying, self.lastSyncedSegmentID == sample.segment.id else { return }
                        self.player.play()
                    }
                }
            }
        }
    }

    private func applySample(at time: Double, exact: Bool, forceReload: Bool) {
        guard let sample = layout.sample(at: time) else {
            activeSample = nil
            currentStillImage = nil
            playbackError = nil
            playbackNeedsPermission = false
            return
        }
        activeSample = sample
        lastSyncedSegmentID = sample.segment.id
        let path = sample.segment.clip.path
        let access = verifyReadable(path: path)
        currentVideoMissing = access.missing
        playbackNeedsPermission = access.permissionDenied
        playbackError = access.message
        if !access.ok {
            player.pause()
            currentStillImage = nil
            return
        }
        if sample.segment.clip.still {
            player.pause()
            currentStillImage = loadStillImage(path: path)
            if currentStillImage == nil {
                playbackError = "無法解碼圖片：\(filename(path))"
            }
        } else {
            currentStillImage = nil
            desiredSourceTime = max(0, sample.sourceTime)
            desiredExactSeek = exact
            ensureVideoLoaded(path: path, forceReload: forceReload)
            player.pause()
            if itemReady {
                requestVideoSeek(to: desiredSourceTime, exact: exact)
            }
        }
    }

    private func loadStillImage(path: String) -> NSImage? {
        if let cached = imageCache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        if imageCache.count > 24 { imageCache.removeAll() }
        imageCache[path] = image
        return image
    }

    private func ensureVideoLoaded(path: String, forceReload: Bool) {
        guard forceReload || loadedVideoPath != path || player.currentItem == nil else { return }
        let asset: AVURLAsset
        if !forceReload, let cached = assetCache[path] {
            asset = cached
        } else {
            let created = AVURLAsset(url: URL(fileURLWithPath: path),
                                     options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            if assetCache.count > 24 { assetCache.removeAll() }
            assetCache[path] = created
            asset = created
        }
        let item = AVPlayerItem(asset: asset)
        itemReady = false
        isSeeking = false
        queuedSeek = nil
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let errorMessage = observedItem.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.player.currentItem === observedItem else { return }
                switch status {
                case .readyToPlay:
                    self.itemReady = true
                    self.playbackError = nil
                    self.playbackNeedsPermission = false
                    let target = self.desiredSourceTime
                    if self.isPlaying {
                        let cm = CMTime(seconds: max(0, target), preferredTimescale: 600)
                        self.player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            Task { @MainActor in
                                guard let self, self.isPlaying else { return }
                                self.player.play()
                            }
                        }
                    } else {
                        self.requestVideoSeek(to: target, exact: self.desiredExactSeek)
                    }
                case .failed:
                    self.itemReady = false
                    self.playbackError = "無法載入影片預覽：\(errorMessage ?? filename(path))"
                    self.pause()
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        loadedVideoPath = path
    }

    private func requestVideoSeek(to seconds: Double, exact: Bool) {
        guard itemReady else {
            desiredSourceTime = seconds
            desiredExactSeek = exact
            return
        }
        if isSeeking {
            queuedSeek = (seconds, exact)
            return
        }
        isSeeking = true
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance: CMTime = exact ? .zero : CMTime(seconds: 0.04, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                if let next = self.queuedSeek {
                    self.queuedSeek = nil
                    self.requestVideoSeek(to: next.time, exact: next.exact)
                }
            }
        }
    }
}

final class PassThroughAVPlayerView: AVPlayerView {
    var desiredZPosition: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Timeline monitor video views are display-only; never steal clicks/drags
        // from canvas subtitles, PiP transform boxes, or corner resize handles.
        return nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyZOrder()
    }

    override func layout() {
        super.layout()
        applyZOrder()
    }

    func applyZOrder() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.zPosition = desiredZPosition
        if let parent = superview {
            parent.wantsLayer = true
            parent.layer?.zPosition = desiredZPosition
        }
    }
}

struct TimelinePlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var zOrder: CGFloat = 0

    func makeNSView(context: Context) -> PassThroughAVPlayerView {
        let view = PassThroughAVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.updatesNowPlayingInfoCenter = false
        view.desiredZPosition = zOrder
        view.player = player
        view.applyZOrder()
        return view
    }

    func updateNSView(_ view: PassThroughAVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        view.desiredZPosition = zOrder
        view.applyZOrder()
    }

    static func dismantleNSView(_ view: PassThroughAVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

final class MonitorOverlayHostingContainer<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    var interactive: Bool
    var desiredZPosition: CGFloat

    override var isOpaque: Bool { false }

    init(rootView: Content, interactive: Bool, zPosition: CGFloat) {
        self.hostingView = NSHostingView(rootView: rootView)
        self.interactive = interactive
        self.desiredZPosition = zPosition
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = zPosition

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactive else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyZOrder()
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
}

struct MonitorOverlayHostView<Content: View>: NSViewRepresentable {
    let zOrder: CGFloat
    let interactive: Bool
    let content: Content

    init(zOrder: CGFloat, interactive: Bool = true, @ViewBuilder content: () -> Content) {
        self.zOrder = zOrder
        self.interactive = interactive
        self.content = content()
    }

    func makeNSView(context: Context) -> MonitorOverlayHostingContainer<Content> {
        let container = MonitorOverlayHostingContainer(
            rootView: content,
            interactive: interactive,
            zPosition: zOrder
        )
        container.applyZOrder()
        return container
    }

    func updateNSView(_ nsView: MonitorOverlayHostingContainer<Content>, context: Context) {
        nsView.interactive = interactive
        nsView.desiredZPosition = zOrder
        nsView.hostingView.rootView = content
        nsView.applyZOrder()
    }
}

@MainActor final class Studio: ObservableObject {
    @Published var project = Project()
    @Published var workspace: Workspace = .generate
    @Published var generateSelection = ""
    @Published var libraryBatchSelection: Set<String>? = nil
    @Published var editSelection = ""
    @Published var bridgeShot: BridgeShot?
    @Published var status = "就緒"
    @Published var log = ""
    @Published var busy = false
    @Published var comfyConnectionMode: String = "managed" // "managed" (Klipora 託管引擎) or "desktop" (外部 ComfyUI Desktop)
    @Published var referenceRoleByPath: [String: String] = [:] // "角色" / "場景" / "物品" / "風格"
    @Published var jobStartedAt: Date? = nil
    @Published var jobElapsedSeconds: Int = 0
    @Published var jobProgress: Double? = nil
    @Published var jobProgressStep: Int? = nil
    @Published var jobProgressMax: Int? = nil
    @Published var jobStageLabel: String = ""
    @Published var showLog = false
    @Published var showPrompt = false
    @Published var promptDraft = ""
    @Published var editedPrompt: String?
    @Published var vlmDraftPrompt = ""
    @Published var vlmDraftSourcePath = ""
    @Published var showVLMDraftCard = false
    @Published private(set) var defaultOutputPath = UserDefaults.standard.string(forKey: "MotionDesk.defaultOutputPath")
    @Published var timelinePreviewPath: String?
    @Published var timelineDurations: [String: Double] = [:]
    @Published var timelineDurationErrors: [String: String] = [:]
    @Published var mediaReloadToken = 0
    @Published var projectRevision = 0
    @Published var lastAddedClipID: UUID?

    var selection: String {
        get { workspace == .edit ? editSelection : generateSelection }
        set {
            if workspace == .edit { editSelection = newValue }
            else { generateSelection = newValue }
        }
    }

    var source: String {
        guard project.localOnly != true else { return "zimage" }
        if project.source == "colab" { return "colab" }
        if project.kind == "image" && (project.source == "openai_image" || project.source == "gemini_image") {
            return project.source
        }
        return "zimage"
    }
    var localImageModel: String { project.localImageModel ?? "zimage" }
    static let builtinLocalVideoModels: Set<String> = ["wan22", "wan22_14b", "ltxv13b"]
    var isBuiltinLocalVideoAction: Bool { Self.builtinLocalVideoModels.contains(action) }
    var localVideoModel: String { project.localVideoModel ?? "wan22" }
    var localModel: String { project.kind == "video" ? localVideoModel : localImageModel }
    var action: String {
        if source == "colab" { return "colab" }
        if source == "openai_image" || source == "gemini_image" { return source }
        if project.kind != "video", localModel.hasPrefix("workflow_") { return "comfy" }
        return localModel
    }
    var videoMethod: String {
        project.videoMethod ?? "reference"
    }
    var supportsMultiImageReference: Bool {
        source == "colab" || source == "openai_image" || source == "gemini_image"
    }
    var supportsImageReference: Bool { supportsMultiImageReference || localModelSupportsReference }
    var takesReference: Bool {
        (project.kind == "image" && supportsImageReference)
            || (project.kind == "video" && videoMethod == "reference" && (source == "colab" || localModelSupportsReference))
    }

    func referenceRole(for path: String) -> String {
        referenceRoleByPath[path] ?? "角色"
    }

    func setReferenceRole(_ role: String, for path: String) {
        referenceRoleByPath[path] = role
    }

    func insertReferenceMention(index: Int, path: String) {
        let role = referenceRole(for: path)
        let tag = "@圖片\(index + 1)（\(role)）"
        let trimmed = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            project.prompt = tag + " "
        } else if project.prompt.hasSuffix(" ") || project.prompt.hasSuffix("\n") {
            project.prompt += tag + " "
        } else {
            project.prompt += " " + tag + " "
        }
    }
    var unsupportedKreaReference: String {
        unsupportedLocalReferencePath
    }
    var unsupportedKreaLoRA: String {
        unsupportedLocalLoRAInfo?.id ?? ""
    }
    var unsupportedKreaLoRALabel: String {
        unsupportedLocalLoRAInfo?.label ?? ""
    }
    var acceptsVideoReference: Bool {
        project.kind == "video" && takesReference && (Self.builtinLocalVideoModels.contains(action) || action == "colab")
    }
    var orderedFrames: [String] { project.keyframes ?? [] }
    static let maxKeyframes = 32
    var multiTransitions: [FrameTransition] {
        let count = max(0, orderedFrames.count - 1)
        if let segments = project.segments, segments.count == count { return segments }
        guard count > 0 else { return [] }
        let total = min(15 * count, max(2 * count, project.seconds))
        return (0..<count).map { FrameTransition(seconds: total / count + ($0 < total % count ? 1 : 0)) }
    }

    func updateTransition(_ index: Int, seconds: Int? = nil, prompt: String? = nil, applyToAll: Bool = false) {
        guard !busy else { return }
        if let seconds, !(2...15).contains(seconds) { return }
        var segments = multiTransitions
        guard segments.indices.contains(index) else { return }
        for target in applyToAll ? segments.indices : index..<(index + 1) {
            if let seconds { segments[target].seconds = seconds }
            if let prompt { segments[target].prompt = prompt }
        }
        project.segments = segments
    }
    var outputDimensions: OutputDimensions? {
        get { project.kind == "video" ? project.videoDimensions : project.imageDimensions }
        set {
            if project.kind == "video" { project.videoDimensions = newValue }
            else { project.imageDimensions = newValue }
        }
    }
    var outputFolder: String? {
        get { project.kind == "video" ? project.videoFolder : project.imageFolder }
        set {
            if project.kind == "video" { project.videoFolder = newValue }
            else { project.imageFolder = newValue }
        }
    }
    var timelineOutput: TimelineOutput {
        get { project.timelineOutput ?? TimelineOutput(aspect: project.aspect, dimensions: project.videoDimensions) }
        set { project.timelineOutput = newValue }
    }

    var defaultOutputDirectory: URL {
        if let defaultOutputPath, !defaultOutputPath.isEmpty {
            return URL(fileURLWithPath: defaultOutputPath, isDirectory: true)
        }
        return jobsDirectory
    }

    var generationOutputDirectory: URL {
        outputFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultOutputDirectory
    }

    var videoOutputDirectory: URL {
        project.videoFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultOutputDirectory
    }

    var audioOutputDirectory: URL {
        if let folder = project.audioFolder, !folder.isEmpty {
            return URL(fileURLWithPath: folder, isDirectory: true)
        }
        return defaultOutputDirectory
    }

    func prepareOutputDirectory(_ url: URL) -> Bool {
        do {
            try fs.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            status = "無法使用儲存位置：\(error.localizedDescription)"
            return false
        }
    }

    func openOutputDirectory(_ url: URL) {
        guard prepareOutputDirectory(url) else { return }
        if !NSWorkspace.shared.open(url) { status = "Finder 無法開啟此資料夾。" }
    }

    func chooseDefaultOutputDirectory() {
        let dialog = openPanel(title: "設定工作台預設儲存位置", types: [], multiple: false, directory: true)
        dialog.canCreateDirectories = true
        dialog.directoryURL = defaultOutputDirectory
        present(dialog) { [weak self] urls in
            guard let self, let url = urls.first, self.prepareOutputDirectory(url) else { return }
            self.defaultOutputPath = url.path
            UserDefaults.standard.set(url.path, forKey: "MotionDesk.defaultOutputPath")
            self.status = "已設定預設儲存位置 · \(url.path)"
        }
    }

    func resetDefaultOutputDirectory() {
        UserDefaults.standard.removeObject(forKey: "MotionDesk.defaultOutputPath")
        defaultOutputPath = nil
    }

    func chooseOutputFolder() {
        let kind = project.kind
        let dialog = openPanel(title: "選擇儲存資料夾", types: [], multiple: false, directory: true)
        dialog.canCreateDirectories = true
        dialog.directoryURL = generationOutputDirectory
        present(dialog) { [weak self] urls in
            guard let self, let path = urls.first?.path else { return }
            if kind == "video" { self.project.videoFolder = path }
            else { self.project.imageFolder = path }
        }
    }
    var secondsRange: ClosedRange<Int> {
        2...15
    }
    var usesFirstLastFrames: Bool { action == "colab" && project.kind == "video" && videoMethod == "frames" }
    var usesMultiFrames: Bool { action == "colab" && project.kind == "video" && videoMethod == "multi" }
    var generationSeconds: Int {
        if usesMultiFrames { return multiTransitions.reduce(0) { $0 + min(15, max(0, $1.seconds)) } }
        return min(secondsRange.upperBound, max(secondsRange.lowerBound, project.seconds))
    }
    var referenceImage: String {
        get { project.kind == "video" ? project.reference : (project.imageReference ?? "") }
        set {
            if project.kind == "video" { project.reference = newValue }
            else { project.imageReference = newValue }
        }
    }
    static let maxCloudReferenceImages = 8

    private var extraCloudReferences: [String] {
        get { (project.kind == "video" ? project.extraCloudVideoImages : project.extraCloudImageReferences) ?? [] }
        set {
            if project.kind == "video" { project.extraCloudVideoImages = newValue }
            else { project.extraCloudImageReferences = newValue }
        }
    }

    var referenceImages: [String] {
        let first = referenceImage.isEmpty ? [] : [referenceImage]
        guard supportsMultiImageReference else { return first }
        var seen = Set<String>()
        return Array((first + extraCloudReferences).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }.prefix(Self.maxCloudReferenceImages))
    }

    func setReferenceImages(_ paths: [String]) {
        referenceImage = paths.first ?? ""
        if supportsMultiImageReference { extraCloudReferences = Array(paths.dropFirst()) }
    }

    func removeReferenceImage(_ path: String) {
        guard !busy else { return }
        setReferenceImages(referenceImages.filter { $0 != path })
    }

    var supportsLoRA: Bool { localModelSupportsLoRA }
    var selectedLoRA: String { supportsLoRA ? (project.localImageLoRA ?? "") : "" }
    var selectedWorkflow: String {
        if project.kind == "video" { return project.videoWorkflow ?? "" }
        if localModel.hasPrefix("workflow_"), let entry = CustomWorkflowRegistry.entry(for: localModel) {
            return CustomWorkflowRegistry.fileURL(for: entry).path
        }
        return project.workflow
    }
    var cloudGPU: String { project.cloudGPU ?? "L4" }
    var camera: String { project.camera ?? "依原稿" }

    @Published var projectURL: URL?
    private var timer: Timer?
    private var worker: Process?
    private var localEngine: Process?
    @Published var engineRunning = false
    @Published var engineStarting = false
    @Published private var engineEndpoint: String?

    var endpoint: String { engineEndpoint ?? project.endpoint }
    var jobsDirectory: URL {
        fs.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klipora/Jobs", isDirectory: true)
    }
    private var bridgeDirectory: URL {
        let support = fs.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klipora/BridgeFrames", isDirectory: true)
        if (try? fs.createDirectory(at: support, withIntermediateDirectories: true)) != nil {
            return support
        }
        return fs.temporaryDirectory.appendingPathComponent("Klipora/BridgeFrames", isDirectory: true)
    }

    func toggleEngine() {
        if let engine = localEngine, engine.isRunning {
            engine.terminate()
            status = "正在關閉本機 ComfyUI"
            return
        }
        do {
            let home = fs.homeDirectoryForCurrentUser
            guard let comfy = PortabilitySetupManager.shared.resolveAuthorizedComfyModelsRoot() else {
                status = "首次啟動本機 ComfyUI 前，請先選擇 ComfyUI 模型目錄（如 ~/Documents/ComfyUI）以完成資料夾授權…"
                PortabilitySetupManager.shared.chooseComfyModelsRoot(app: self) { [weak self] _ in
                    self?.toggleEngine()
                }
                return
            }
            let desktopInstance = home.appendingPathComponent("ComfyUI-Installs/ComfyUI-MPS")
            let newCore = desktopInstance.appendingPathComponent("ComfyUI")
            let newRuntime = newCore.appendingPathComponent(".venv/bin/python3")
            let useNewDesktop = fs.isExecutableFile(atPath: newRuntime.path)
                && fs.fileExists(atPath: newCore.appendingPathComponent("main.py").path)
            let runtime = useNewDesktop ? newRuntime : comfy.appendingPathComponent(".venv/bin/python3")
            let core = useNewDesktop ? newCore : URL(fileURLWithPath: "/Applications/ComfyUI.app/Contents/Resources/ComfyUI")
            let front = core.appendingPathComponent("web_custom_versions/desktop_app")
            guard fs.isExecutableFile(atPath: runtime.path),
                  fs.fileExists(atPath: core.appendingPathComponent("main.py").path),
                  (useNewDesktop || fs.fileExists(atPath: comfy.appendingPathComponent("models").path)) else {
                status = "找不到 ComfyUI Desktop 的程式或 Python 環境，請先在 ComfyUI 裡完成設定。"
                return
            }
            let folder = fs.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Klipora/ComfyUI", isDirectory: true)
            try fs.createDirectory(at: folder, withIntermediateDirectories: true)
            try fs.createDirectory(at: folder.appendingPathComponent("user"), withIntermediateDirectories: true)
            try fs.createDirectory(at: folder.appendingPathComponent("custom_nodes"), withIntermediateDirectories: true)
            guard let launcher = Bundle.main.url(forResource: "engine", withExtension: "py") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let runID = UUID().uuidString
            let mapping = folder.appendingPathComponent("models-\(runID).yaml")
            let comfyMap: [String: String] = [
                "base_path": comfy.path,
                "checkpoints": "models/checkpoints",
                "text_encoders": "models/text_encoders",
                "diffusion_models": "models/diffusion_models",
                "vae": "models/vae",
                "loras": "models/loras"
            ]
            var models: [String: [String: String]] = ["MotionDesk": comfyMap]
            if useNewDesktop {
                var desktopMap: [String: String] = [
                    "base_path": core.path,
                    "LLM": "models/LLM"
                ]
                if fs.fileExists(atPath: core.appendingPathComponent("custom_nodes").path) {
                    desktopMap["custom_nodes"] = "custom_nodes"
                }
                models["MotionDeskDesktopCore"] = desktopMap
            }
            let sharedComfy = home.appendingPathComponent("ComfyUI-Shared")
            if fs.fileExists(atPath: sharedComfy.path) {
                models["MotionDeskShared"] = [
                    "base_path": sharedComfy.path,
                    "LLM": "models/LLM"
                ]
            }
            try JSONSerialization.data(withJSONObject: models).write(to: mapping, options: .atomic)
            let output = folder.appendingPathComponent("engine-\(runID).log")
            let ready = folder.appendingPathComponent("engine-\(runID).ready")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            let process = Process()
            process.executableURL = runtime
            process.arguments = ["-u", launcher.path, ready.path, core.appendingPathComponent("main.py").path,
                                 "--base-directory", folder.path, "--extra-model-paths-config", mapping.path,
                                 "--database-url", "sqlite:///:memory:",
                                 "--disable-all-custom-nodes",
                                 "--whitelist-custom-nodes", "ComfyUI-llama-cpp_vlm",
                                 "--disable-api-nodes", "--disable-auto-launch",
                                 "--fp32-vae"]
            if fs.fileExists(atPath: front.path) {
                process.arguments?.append(contentsOf: ["--front-end-root", front.path])
            }
            process.currentDirectoryURL = folder
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self] process in
                try? handle.close()
                try? FileManager.default.removeItem(at: mapping)
                let code = process.terminationStatus
                Task { @MainActor in
                    self?.engineRunning = false
                    self?.engineStarting = false
                    self?.engineEndpoint = nil
                    self?.localEngine = nil
                    self?.refreshLog(output)
                    self?.status = code == 0 || code == 15 ? "本機 ComfyUI 已關閉" : "本機 ComfyUI 已停止，詳情見工作紀錄"
                }
            }
            try process.run()
            localEngine = process
            engineRunning = true
            engineStarting = true
            status = "本機 ComfyUI 正在啟動"
            log = "本機 ComfyUI 紀錄：\(output.path)"
            Task { @MainActor in
                defer { try? fs.removeItem(at: ready) }
                for step in 0..<300 {
                    guard process.isRunning, localEngine === process else { return }
                    if let value = try? String(contentsOf: ready, encoding: .utf8),
                       let port = Int(value), (1...65535).contains(port) {
                        engineEndpoint = "http://127.0.0.1:\(port)"
                        engineStarting = false
                        status = "本機 ComfyUI 就緒 · \(port)"
                        return
                    }
                    if step == 40 {
                        status = "本機 ComfyUI 啟動較久；若卡在讀取模型目錄，請停止後至「元件與連線設定」重新點選「選擇模型目錄…」完成資料夾授權。"
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                engineStarting = false
                status = "等候本機 ComfyUI 逾時；請至「元件與連線設定」重新點選「選擇模型目錄…」重新授權模型資料夾，或查看工作紀錄。"
                refreshLog(output)
                process.terminate()
            }
        } catch { status = error.localizedDescription }
    }

    func stopEngine() {
        if let engine = localEngine, engine.isRunning { engine.terminate() }
    }
    let fs = FileManager.default
    private weak var activeFilePanel: NSSavePanel?

    func openPanel(
        title: String,
        types: [UTType],
        multiple: Bool,
        directory: Bool,
        initialDirectory: URL? = nil
    ) -> NSOpenPanel {
        let dialog = NSOpenPanel()
        dialog.title = title
        dialog.canChooseFiles = !directory
        dialog.canChooseDirectories = directory
        dialog.allowsMultipleSelection = multiple
        dialog.allowedContentTypes = types
        if let initialDirectory {
            dialog.directoryURL = initialDirectory
        }
        return dialog
    }

    func pickAsync(
        title: String,
        types: [UTType] = [],
        multiple: Bool = false,
        directory: Bool = false,
        initialDirectory: URL? = nil,
        receive: @escaping ([URL]) -> Void
    ) {
        // Defer even NSOpenPanel() creation (which lazily boots XPC openAndSavePanelService)
        // to the next main-queue turn so AXPress (_XPerformAction MIG RPC) returns in < 1ms!
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let dialog = self.openPanel(
                title: title,
                types: types,
                multiple: multiple,
                directory: directory,
                initialDirectory: initialDirectory
            )
            self.presentNow(dialog, receive: receive)
        }
    }

    func pickReferences(title: String, types: [UTType] = [], multiple: Bool = false,
                        directory: Bool = false, receive: @escaping ([URL]) -> Void) {
        pickAsync(title: title, types: types, multiple: multiple, directory: directory, receive: receive)
    }

    /// Presents an already-constructed NSOpenPanel asynchronously on the next main-queue turn.
    func present(_ dialog: NSOpenPanel, receive: @escaping ([URL]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.presentNow(dialog, receive: receive)
        }
    }

    private func presentNow(_ dialog: NSOpenPanel, receive: @escaping ([URL]) -> Void) {
        if let existing = activeFilePanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        activeFilePanel = dialog
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            self?.activeFilePanel = nil
            if result == .OK { receive(dialog.urls) }
        }
        let hostWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        if let window = hostWindow, window.attachedSheet == nil {
            dialog.beginSheetModal(for: window, completionHandler: complete)
        } else {
            dialog.begin(completionHandler: complete)
        }
    }

    /// Allocates, configures, and presents an NSSavePanel asynchronously on the next main-queue turn (AX-safe, < 1ms return).
    func presentSavePanel(configure: @escaping (NSSavePanel) -> Void, receive: @escaping (URL) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let existing = self.activeFilePanel {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            let dialog = NSSavePanel()
            configure(dialog)
            self.activeFilePanel = dialog
            let complete: (NSApplication.ModalResponse) -> Void = { [weak self] result in
                self?.activeFilePanel = nil
                if result == .OK, let url = dialog.url { receive(url) }
            }
            let hostWindow = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
            if let window = hostWindow, window.attachedSheet == nil {
                dialog.beginSheetModal(for: window, completionHandler: complete)
            } else {
                dialog.begin(completionHandler: complete)
            }
        }
    }

    func importMedia() {
        pickAsync(title: "匯入影音素材", types: [.image, .movie, .audio], multiple: true) { [weak self] urls in
            self?.importPaths(urls.map(\.path))
        }
    }

    func registerMedia(_ paths: [String]) {
        var seen = Set(project.media)
        let added = paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        if !added.isEmpty { project.media.append(contentsOf: added) }
    }

    func importPaths(_ paths: [String], selectingIn target: Workspace? = nil) {
        registerMedia(paths)
        guard let path = paths.last else { return }
        if (target ?? workspace) == .edit { editSelection = path }
        else { generateSelection = path }
    }

    @discardableResult
    func importDroppedMediaURLs(_ urls: [URL], selectingIn target: Workspace? = nil) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        var collected: [String] = []
        var seenDropped = Set<String>()
        func appendIfSupported(_ fileURL: URL) {
            let std = fileURL.standardizedFileURL
            let ext = std.pathExtension.lowercased()
            guard multitrackMediaTypes.contains(ext),
                  (try? std.resourceValues(forKeys: keys).isRegularFile) == true else { return }
            if seenDropped.insert(std.path).inserted {
                collected.append(std.path)
            }
        }
        for url in urls where url.isFileURL {
            if (try? url.resourceValues(forKeys: keys).isDirectory) == true {
                if let enumerator = fs.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    let entries = enumerator.compactMap { $0 as? URL }
                        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                    entries.forEach(appendIfSupported)
                }
            } else {
                appendIfSupported(url)
            }
        }
        guard !collected.isEmpty else {
            status = "拖入的檔案不含支援的影片、圖片或音訊格式。"
            return false
        }
        let existing = Set(project.media)
        let newlyAddedCount = collected.filter { !existing.contains($0) }.count
        importPaths(collected, selectingIn: target)
        if newlyAddedCount > 0 {
            status = "已拖入匯入 \(newlyAddedCount) 個素材至素材庫"
        } else {
            status = "所拖入的素材已存在於素材庫中"
        }
        Task { await loadMultitrackDurations() }
        return true
    }

    func removeFromLibrary(_ paths: Set<String>) {
        let removed = paths.intersection(project.media)
        guard !removed.isEmpty else { return }
        project.media.removeAll { removed.contains($0) }
        let fallback = project.media.last ?? ""
        if removed.contains(generateSelection) { generateSelection = fallback }
        if removed.contains(editSelection) { editSelection = fallback }
        if let video = bridgeShot?.generatedVideo, removed.contains(video) { bridgeShot?.generatedVideo = nil }
        libraryBatchSelection?.subtract(removed)
        status = "已從素材庫移除 \(removed.count) 個項目"
    }

    private func writeProject(to target: URL) {
        do {
            if project.multitrack != nil {
                syncLegacyMirrorFromMultitrack()
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: target, options: .atomic)
            NativeVoiceWorkspaceStore.shared.migrateProjectScopeOnSave(to: target)
            projectURL = target
            status = "已儲存 \(target.lastPathComponent)"
        } catch { status = error.localizedDescription }
    }

    func save() {
        if let url = projectURL {
            writeProject(to: url)
            return
        }
        presentSavePanel(configure: { [weak self] dialog in
            let rawTitle = (self?.project.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = rawTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            dialog.nameFieldStringValue = safeTitle.isEmpty ? "影音專案.studio.json" : "\(safeTitle).studio.json"
            dialog.allowedContentTypes = [.json]
        }) { [weak self] url in
            self?.writeProject(to: url)
        }
    }

    func open() {
        guard !busy else { return }
        pickAsync(title: "開啟影音專案", types: [.json]) { [weak self] urls in
            guard let self, !self.busy, let url = urls.first else { return }
            self.openProject(at: url)
        }
    }

    func openProject(at url: URL) {
        do {
            project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            if project.timelineOutput == nil { project.timelineOutput = timelineOutput }
            if project.source == "comfy" {
                project.source = "zimage"
                project.localImageModel = "comfy"
                project.localVideoModel = "comfy"
                if project.kind == "video", project.videoWorkflow == nil {
                    project.videoWorkflow = project.workflow
                }
            }
            if project.kind == "image", project.imageReference == nil {
                if project.source == "colab" || project.localImageModel == "comfy" {
                    project.imageReference = project.reference
                } else {
                    // Old projects could keep a hidden video reference while generating stills.
                    project.imageReference = ""
                }
            }
            editedPrompt = nil
            bridgeShot = nil
            libraryBatchSelection = nil
            NativeVoiceWorkspaceStore.shared.switchProjectScopeOnOpen(to: url)
            projectURL = url
            let first = project.media.first ?? ""
            generateSelection = first
            editSelection = first
            timelineDurationErrors.removeAll()
            projectRevision += 1
            if source != "colab", let removed = removedModelNotice {
                status = "已開啟 \(url.lastPathComponent) · \(removed.message)"
            } else {
                status = "已開啟 \(url.lastPathComponent)"
            }
            Task { await loadMultitrackDurations(forceRetry: true) }
        } catch { status = "無法開啟專案。\(error.localizedDescription)" }
    }

    var timelineTransitions: [TimelineTransition?] {
        let saved = project.editTransitions ?? []
        return zip(project.clips, project.clips.dropFirst()).map { pair in
            saved.first { $0.after == pair.0.id && $0.before == pair.1.id }
        }
    }

    func sourceDuration(for path: String) -> Double? {
        timelineDurations[path]
    }

    func currentTimelineLayout() -> TimelineLayout {
        TimelineLayout(
            clips: project.clips,
            transitions: timelineTransitions,
            durations: timelineDurations,
            durationErrors: timelineDurationErrors
        )
    }

    private func pruneOrphanedTransitions() {
        guard var saved = project.editTransitions, !saved.isEmpty else { return }
        let adjacentPairs = Set(zip(project.clips, project.clips.dropFirst()).map { "\($0.0.id.uuidString)->\($0.1.id.uuidString)" })
        saved.removeAll { !adjacentPairs.contains("\($0.after.uuidString)->\($0.before.uuidString)") }
        project.editTransitions = saved
    }

    func setTimelineTransition(after: UUID, before: UUID, kind: String, seconds: Double) {
        guard !busy,
              let index = project.clips.firstIndex(where: { $0.id == after }),
              project.clips.indices.contains(index + 1), project.clips[index + 1].id == before,
              kind == "cut" || TimelineTransitionKind.supportedRawValues.contains(kind),
              kind == "cut" || (seconds.isFinite && (0.1...3).contains(seconds)) else { return }
        var transitions = project.editTransitions ?? []
        transitions.removeAll { $0.after == after && $0.before == before }
        if kind != "cut" {
            let cleanSeconds = (min(3.0, max(0.1, seconds)) * 100).rounded() / 100
            transitions.append(TimelineTransition(after: after, before: before, kind: kind, seconds: cleanSeconds))
        }
        project.editTransitions = transitions
    }

    func timelineDuration(for clip: Clip) -> Double {
        if clip.still { return max(TimelineLayout.minClipDuration, TimelineLayout.parseSeconds(clip.end) ?? TimelineLayout.defaultStillDuration) }
        let start = max(0, TimelineLayout.parseSeconds(clip.start) ?? 0)
        return max(TimelineLayout.minClipDuration, (TimelineLayout.parseSeconds(clip.end) ?? timelineDurations[clip.path] ?? start + TimelineLayout.defaultStillDuration) - start)
    }

    private nonisolated static func probeDurationWithFFprobe(path: String) -> Double? {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let seconds = Double(text), seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    private nonisolated static func probeVideoDuration(path: String) async -> (duration: Double?, error: String?) {
        let url = URL(fileURLWithPath: path)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
        } catch let err as NSError {
            let underlying = err.userInfo[NSUnderlyingErrorKey] as? NSError
            let posixCode = underlying?.code ?? err.code
            if err.code == NSFileReadNoPermissionError || posixCode == Int(EPERM) || posixCode == Int(EACCES) {
                return (nil, "缺少資料夾讀取權限（macOS 權限限制，請點「授權素材資料夾」或移至可存取目錄）")
            }
            if err.code == NSFileReadNoSuchFileError || posixCode == Int(ENOENT) {
                return (nil, "找不到影片檔案")
            }
            return (nil, "無法讀取檔案：\(err.localizedDescription)")
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let time = try await asset.load(.duration)
            let seconds = time.seconds
            if seconds.isFinite && seconds > 0 {
                return (seconds, nil)
            }
        } catch {
            if let fallback = probeDurationWithFFprobe(path: path) {
                return (fallback, nil)
            }
            return (nil, "AVFoundation 無法讀取片長：\(error.localizedDescription)")
        }

        if let fallback = probeDurationWithFFprobe(path: path) {
            return (fallback, nil)
        }
        return (nil, "無法判定影片長度")
    }

    func loadTimelineDurations(forceRetry: Bool = false) async {
        var seen = Set<String>()
        let uniqueVideoPaths = project.clips
            .filter { !$0.still }
            .map(\.path)
            .filter { seen.insert($0).inserted }

        var firstError: String?
        for path in uniqueVideoPaths {
            if !forceRetry && timelineDurations[path] != nil { continue }
            let result = await Self.probeVideoDuration(path: path)
            if Task.isCancelled { return }
            if let duration = result.duration {
                timelineDurations[path] = duration
                timelineDurationErrors.removeValue(forKey: path)
            } else if let error = result.error {
                timelineDurationErrors[path] = error
                if firstError == nil { firstError = "\(filename(path))：\(error)" }
            }
        }
        if let firstError, !busy {
            status = "無法讀取部分影片 · \(firstError)"
        }
    }

    func grantMediaFolderAccess() {
        let failingPath = timelineDurationErrors.keys.first
            ?? allTimelineMediaPaths.first(where: { !isImageMediaPath($0) && timelineDurations[$0] == nil })
        let dialog = openPanel(title: "授權素材所在資料夾", types: [], multiple: false, directory: true)
        dialog.prompt = "授權讀取"
        if let failingPath {
            dialog.directoryURL = URL(fileURLWithPath: failingPath).deletingLastPathComponent()
        }
        present(dialog) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.timelineDurationErrors.removeAll()
            self.mediaReloadToken += 1
            Task { @MainActor in
                await self.loadMultitrackDurations(forceRetry: true)
                if self.timelineDurationErrors.isEmpty {
                    self.status = "已重新載入時間軸素材"
                }
            }
        }
    }

    func retryMediaLoad() {
        timelineDurationErrors.removeAll()
        mediaReloadToken += 1
        Task { @MainActor in
            await loadMultitrackDurations(forceRetry: true)
        }
    }

    func addToTimeline(_ path: String) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard multitrackMediaTypes.contains(ext) else { return }
        _ = addMediaToMultitrack(path)
    }

    @discardableResult
    func addURLsToTimeline(_ urls: [URL]) -> Bool {
        addURLsToMultitrack(urls) != nil
    }

    @discardableResult
    func splitClip(at timelineTime: Double, preferredClipID: UUID? = nil) -> UUID? {
        guard !busy else { return nil }
        let layout = currentTimelineLayout()
        switch layout.splitCandidate(at: timelineTime, preferredClipID: preferredClipID) {
        case .failure(let reason):
            status = reason.message
            return nil
        case .success(let candidate):
            let index = candidate.segment.index
            guard project.clips.indices.contains(index) else { return nil }
            let original = project.clips[index]
            var left = original
            var right = Clip(path: original.path)

            if original.still {
                let leftSec = max(TimelineLayout.minClipDuration, (candidate.leftDuration * 1000).rounded() / 1000)
                let rightSec = max(TimelineLayout.minClipDuration, (candidate.rightDuration * 1000).rounded() / 1000)
                left.start = ""
                left.end = TimelineLayout.formatTrimSeconds(leftSec)
                right.start = ""
                right.end = TimelineLayout.formatTrimSeconds(rightSec)
            } else {
                let splitSource = candidate.segment.sourceStart + candidate.offsetInClip
                let maxEnd = candidate.segment.sourceDuration ?? candidate.segment.sourceEnd
                let clampedSplit = min(maxEnd - TimelineLayout.minClipDuration,
                                       max(candidate.segment.sourceStart + TimelineLayout.minClipDuration, splitSource))
                guard clampedSplit > candidate.segment.sourceStart + 1e-4,
                      clampedSplit < candidate.segment.sourceEnd - 1e-4 else {
                    status = TimelineSplitFailure.tooCloseToEdge.message
                    return nil
                }
                let splitText = TimelineLayout.formatTrimSeconds(clampedSplit)
                left.start = original.start.trimmingCharacters(in: .whitespacesAndNewlines)
                left.end = splitText
                right.start = splitText
                right.end = original.end.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            project.clips[index] = left
            project.clips.insert(right, at: index + 1)

            // Re-target any outgoing transition from original clip to the new right half.
            if var transitions = project.editTransitions {
                for i in transitions.indices where transitions[i].after == original.id {
                    transitions[i] = TimelineTransition(
                        after: right.id,
                        before: transitions[i].before,
                        kind: transitions[i].kind,
                        seconds: transitions[i].seconds
                    )
                }
                project.editTransitions = transitions
            }
            pruneOrphanedTransitions()
            validateBridgeShotAfterTimelineChange()
            status = "已在 \(TimelineLayout.formatTimecode(timelineTime)) 分割片段 · \(filename(original.path))"
            return right.id
        }
    }

    func setClipTrimNumeric(id: UUID, start: Double?, end: Double?) {
        guard !busy, let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = project.clips[index]
        if clip.still {
            let targetDuration = min(300.0, max(TimelineLayout.minClipDuration, end ?? TimelineLayout.defaultStillDuration))
            clip.start = ""
            clip.end = TimelineLayout.formatTrimSeconds(targetDuration)
        } else {
            let probed = timelineDurations[clip.path]
            let currentStart = max(0, TimelineLayout.parseSeconds(clip.start) ?? 0)
            let currentEnd = TimelineLayout.parseSeconds(clip.end) ?? probed ?? (currentStart + TimelineLayout.defaultStillDuration)
            var nextStart = max(0, start ?? currentStart)
            var nextEnd = end ?? currentEnd
            if let probed, probed > 0 {
                nextEnd = min(probed, nextEnd)
                nextStart = min(max(0, probed - TimelineLayout.minClipDuration), nextStart)
            }
            if nextEnd - nextStart < TimelineLayout.minClipDuration {
                if start != nil && end == nil {
                    nextStart = max(0, nextEnd - TimelineLayout.minClipDuration)
                } else {
                    nextEnd = nextStart + TimelineLayout.minClipDuration
                    if let probed, probed > 0, nextEnd > probed {
                        nextEnd = probed
                        nextStart = max(0, nextEnd - TimelineLayout.minClipDuration)
                    }
                }
            }
            clip.start = nextStart <= 0.0005 ? "" : TimelineLayout.formatTrimSeconds(nextStart)
            if let probed, abs(nextEnd - probed) <= 0.002 {
                clip.end = ""
            } else {
                clip.end = TimelineLayout.formatTrimSeconds(nextEnd)
            }
        }
        guard clip != project.clips[index] else { return }
        project.clips[index] = clip
        validateBridgeShotAfterTimelineChange()
    }

    func updateClipTrimText(id: UUID, startText: String, endText: String) {
        guard !busy, let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.clips[index]
        let trimmedStart = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnd = endText.trimmingCharacters(in: .whitespacesAndNewlines)

        if clip.still {
            if trimmedEnd.isEmpty {
                var updated = clip
                updated.start = ""
                updated.end = ""
                project.clips[index] = updated
                validateBridgeShotAfterTimelineChange()
                return
            }
            guard let parsed = Double(trimmedEnd), parsed.isFinite, parsed >= TimelineLayout.minClipDuration else {
                status = "圖片停留時間需為大於等於 0.1 秒的數值。"
                return
            }
            setClipTrimNumeric(id: id, start: nil, end: parsed)
            return
        }

        let probed = timelineDurations[clip.path]
        let parsedStart: Double?
        if trimmedStart.isEmpty {
            parsedStart = 0
        } else if let value = Double(trimmedStart), value.isFinite, value >= 0 {
            parsedStart = value
        } else {
            status = "入點需為大於等於 0 的秒數。"
            return
        }

        let parsedEnd: Double?
        if trimmedEnd.isEmpty {
            parsedEnd = probed
        } else if let value = Double(trimmedEnd), value.isFinite, value > 0 {
            parsedEnd = value
        } else {
            status = "出點需為大於 0 的秒數。"
            return
        }

        let effStart = parsedStart ?? 0
        if let probed, let explicitEnd = parsedEnd, explicitEnd > probed + 0.05 {
            status = String(format: "出點已限制於影片長度 %.2f 秒內。", probed)
            setClipTrimNumeric(id: id, start: effStart, end: probed)
            return
        }
        if let effEnd = parsedEnd, effEnd - effStart < TimelineLayout.minClipDuration {
            status = "出點必須大於入點至少 0.1 秒。"
            return
        }

        var updated = clip
        updated.start = trimmedStart.isEmpty ? "" : TimelineLayout.formatTrimSeconds(effStart)
        if trimmedEnd.isEmpty {
            updated.end = ""
        } else if let effEnd = parsedEnd {
            updated.end = TimelineLayout.formatTrimSeconds(effEnd)
        }
        guard updated != project.clips[index] else { return }
        project.clips[index] = updated
        validateBridgeShotAfterTimelineChange()
    }

    func resetClipTrim(id: UUID) {
        guard !busy, let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        project.clips[index].start = ""
        project.clips[index].end = ""
        validateBridgeShotAfterTimelineChange()
        status = "已重設片段裁切 · \(filename(project.clips[index].path))"
    }

    func move(_ index: Int, _ by: Int) {
        let target = index + by
        guard !busy, project.clips.indices.contains(index), project.clips.indices.contains(target) else { return }
        project.clips.swapAt(index, target)
        pruneOrphanedTransitions()
        validateBridgeShotAfterTimelineChange()
    }

    @discardableResult
    func reorderClip(_ id: UUID, to target: Int) -> Bool {
        guard !busy, project.clips.indices.contains(target),
              let source = project.clips.firstIndex(where: { $0.id == id }), source != target else { return false }
        var clips = project.clips
        let clip = clips.remove(at: source)
        clips.insert(clip, at: target)
        project.clips = clips
        pruneOrphanedTransitions()
        validateBridgeShotAfterTimelineChange()
        return true
    }

    func removeClip(at index: Int) {
        guard !busy, project.clips.indices.contains(index) else { return }
        let removed = project.clips.remove(at: index)
        project.editTransitions?.removeAll { $0.after == removed.id || $0.before == removed.id }
        pruneOrphanedTransitions()
        validateBridgeShotAfterTimelineChange()
        status = "已移除片段並自動接合 · \(filename(removed.path))"
    }

    func bridgeInsertionIndex(for bridge: BridgeShot) -> Int? {
        guard let index = project.clips.firstIndex(where: { $0.id == bridge.afterID }),
              project.clips.indices.contains(index + 1),
              project.clips[index + 1].id == bridge.beforeID else {
            return nil
        }
        let leading = project.clips[index]
        let trailing = project.clips[index + 1]
        guard leading.path == bridge.afterPath,
              trailing.path == bridge.beforePath,
              leading.start.trimmingCharacters(in: .whitespacesAndNewlines) == bridge.afterStart,
              leading.end.trimmingCharacters(in: .whitespacesAndNewlines) == bridge.afterEnd,
              trailing.start.trimmingCharacters(in: .whitespacesAndNewlines) == bridge.beforeStart,
              trailing.end.trimmingCharacters(in: .whitespacesAndNewlines) == bridge.beforeEnd else {
            return nil
        }
        return index + 1
    }

    func validateBridgeShotAfterTimelineChange() {
        guard let bridge = bridgeShot, bridgeInsertionIndex(for: bridge) == nil else { return }
        status = "補鏡頭綁定的相鄰片段已刪除、重排或修改裁切，成品將保留在素材庫，請重新選擇補鏡頭位置。"
    }

    func startBridgeShot(after afterID: UUID, before beforeID: UUID) {
        Task { @MainActor in
            _ = await prepareBridgeShot(after: afterID, before: beforeID)
        }
    }

    @discardableResult
    func prepareBridgeShot(after afterID: UUID, before beforeID: UUID) async -> Bool {
        guard !busy else { return false }
        guard let index = project.clips.firstIndex(where: { $0.id == afterID }),
              project.clips.indices.contains(index + 1),
              project.clips[index + 1].id == beforeID else {
            status = "請選擇時間軸上相鄰的兩段素材。"
            return false
        }
        let leading = project.clips[index]
        let trailing = project.clips[index + 1]
        guard fs.fileExists(atPath: leading.path), fs.fileExists(atPath: trailing.path) else {
            status = "找不到時間軸片段檔案，請確認素材是否存在。"
            return false
        }
        let leadingStart = leading.start.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingEnd = leading.end.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingStart = trailing.start.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingEnd = trailing.end.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        status = "正在擷取補鏡頭參考影格…"
        defer { busy = false }
        do {
            try fs.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
            let leadingFrame = try await extractBridgeFrame(from: leading, isLastFrame: true, role: "leading")
            let trailingFrame = try await extractBridgeFrame(from: trailing, isLastFrame: false, role: "trailing")
            let handoff = BridgeShot(
                afterID: leading.id,
                beforeID: trailing.id,
                afterPath: leading.path,
                beforePath: trailing.path,
                afterStart: leadingStart,
                afterEnd: leadingEnd,
                beforeStart: trailingStart,
                beforeEnd: trailingEnd,
                afterName: filename(leading.path),
                beforeName: filename(trailing.path),
                leadingFrame: leadingFrame,
                trailingFrame: trailingFrame,
                generatedVideo: nil
            )
            guard let insertionIndex = bridgeInsertionIndex(for: handoff) else {
                status = "補鏡頭位置或裁切範圍已變更，請重新選擇相鄰片段。"
                return false
            }
            bridgeShot = handoff
            applyBridgeFrames(handoff)
            generateSelection = leadingFrame
            editedPrompt = nil
            workspace = .generate
            let pairText = String(format: "%02d → %02d", insertionIndex, insertionIndex + 1)
            status = source == "colab"
                ? "已帶入補鏡頭首尾幀（\(pairText)）"
                : "已帶入補鏡頭前段尾幀（\(pairText) · Wan 2.2）"
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    func applyBridgeFrames(_ handoff: BridgeShot? = nil) {
        guard let bridge = handoff ?? bridgeShot else { return }
        project.kind = "video"
        if source == "colab" {
            project.videoMethod = "frames"
            project.firstFrame = bridge.leadingFrame
            project.lastFrame = bridge.trailingFrame
        } else {
            project.localVideoModel = "wan22"
            project.videoMethod = "reference"
            project.reference = bridge.leadingFrame
            project.referenceVideo = nil
        }
    }

    func isBridgeConfigurationActive(for bridge: BridgeShot) -> Bool {
        guard project.kind == "video" else { return false }
        if source == "colab" {
            return videoMethod == "frames"
                && project.firstFrame == bridge.leadingFrame
                && project.lastFrame == bridge.trailingFrame
        } else {
            return action == "wan22"
                && videoMethod == "reference"
                && project.reference == bridge.leadingFrame
                && (project.referenceVideo ?? "").isEmpty
        }
    }

    func matchesBridgeRequest(_ value: [String: Any], bridge: BridgeShot) -> Bool {
        guard (value["kind"] as? String) == "video" else { return false }
        let reqAction = value["action"] as? String ?? ""
        let method = value["videoMethod"] as? String ?? ""
        let frames = value["keyframes"] as? [String] ?? []
        let ref = value["reference"] as? String ?? ""
        let refVideo = value["referenceVideo"] as? String ?? ""
        if reqAction == "colab" {
            return method == "frames"
                && frames == [bridge.leadingFrame, bridge.trailingFrame]
                && ref.isEmpty
                && refVideo.isEmpty
        } else if reqAction == "wan22" {
            return method == "reference"
                && ref == bridge.leadingFrame
                && refVideo.isEmpty
                && frames.isEmpty
        }
        return false
    }

    func clearBridgeShot() {
        guard !busy else { return }
        bridgeShot = nil
        status = "已清除補鏡頭插入點"
    }

    func insertBridgeShot() {
        guard !busy, let bridge = bridgeShot, let video = bridge.generatedVideo else { return }
        guard fs.fileExists(atPath: video) else {
            status = "找不到已生成的補鏡頭影片，請重新生成。"
            return
        }
        if !project.media.contains(video) {
            project.media.append(video)
        }
        guard let insertIndex = bridgeInsertionIndex(for: bridge) else {
            status = "原相鄰片段已刪除、重排或修改裁切，成品已保留在素材庫，請回剪輯頁重新選擇補鏡頭位置。"
            return
        }
        project.clips.insert(Clip(path: video), at: insertIndex)
        bridgeShot = nil
        workspace = .edit
        status = String(format: "已插入補鏡頭至第 %02d 段 · %@", insertIndex + 1, filename(video))
    }

    private func extractBridgeFrame(from clip: Clip, isLastFrame: Bool, role: String) async throws -> String {
        let startText = clip.start.trimmingCharacters(in: .whitespacesAndNewlines)
        let endText = clip.end.trimmingCharacters(in: .whitespacesAndNewlines)
        if clip.still {
            if !endText.isEmpty {
                guard let duration = Double(endText), duration.isFinite, duration >= 1.0 / 24.0 else {
                    throw NSError(domain: "MotionDesk", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "\(filename(clip.path)) 的停留秒數無效。"
                    ])
                }
            }
            return clip.path
        }
        let url = URL(fileURLWithPath: clip.path)
        let asset = AVURLAsset(url: url)
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        guard duration.isFinite, duration > 0 else {
            throw NSError(domain: "MotionDesk", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "無法讀取影片長度：\(filename(clip.path))"
            ])
        }
        let startSeconds: Double
        if startText.isEmpty {
            startSeconds = 0
        } else if let value = Double(startText), value.isFinite {
            startSeconds = value
        } else {
            throw NSError(domain: "MotionDesk", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\(filename(clip.path)) 的起點秒數無效。"
            ])
        }
        let endSeconds: Double
        if endText.isEmpty {
            endSeconds = duration
        } else if let value = Double(endText), value.isFinite {
            endSeconds = value
        } else {
            throw NSError(domain: "MotionDesk", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "\(filename(clip.path)) 的終點秒數無效。"
            ])
        }
        guard startSeconds >= 0, min(endSeconds, duration) - startSeconds >= 1.0 / 24.0,
              endSeconds <= duration + 0.10 else {
            throw NSError(domain: "MotionDesk", code: 5, userInfo: [
                NSLocalizedDescriptionKey: String(format: "%@ 裁切時間無效（影片長度 %.2f 秒）。", filename(clip.path), duration)
            ])
        }
        let targetSeconds: Double
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if isLastFrame {
            let effectiveEnd = min(endSeconds, duration)
            targetSeconds = max(startSeconds, effectiveEnd - (1.0 / 30.0))
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = .zero
        } else {
            targetSeconds = min(max(0, startSeconds), max(0, duration - (1.0 / 30.0)))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        }
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let cgImage: CGImage
        if let exact = try? await generator.image(at: targetTime).image {
            cgImage = exact
        } else {
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            let fallbackSeconds = isLastFrame ? max(startSeconds, min(endSeconds, duration) - 0.05) : targetSeconds
            do {
                cgImage = try await generator.image(at: CMTime(seconds: fallbackSeconds, preferredTimescale: 600)).image
            } catch {
                throw NSError(domain: "MotionDesk", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "無法擷取 \(filename(clip.path)) 的影格。"
                ])
            }
        }
        let outputURL = bridgeDirectory.appendingPathComponent("bridge-\(role)-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "MotionDesk", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "無法建立補鏡頭暫存影格。"
            ])
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "MotionDesk", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "無法寫入補鏡頭暫存影格。"
            ])
        }
        return outputURL.path
    }

    func export() {
        let layout = currentMultitrackLayout()
        guard !busy, !layout.isEmpty else { return }
        if layout.hasInvalidTransitions {
            status = "有轉場超過相鄰片段長度，請修正後再匯出。"
            return
        }
        let size = timelineOutput.dimensions?.pixels
        if timelineOutput.dimensions != nil && !validVideoSize(size) {
            status = "請在成片輸出尺寸填入 64–4096 之間的偶數寬高。"
            return
        }
        let day = datedDirectory(under: videoOutputDirectory)
        let preparedDay = prepareOutputDirectory(day) ? day : nil
        presentSavePanel(configure: { dialog in
            dialog.nameFieldStringValue = "影音成片.mp4"
            dialog.allowedContentTypes = [.mpeg4Movie]
            if let preparedDay { dialog.directoryURL = preparedDay }
        }) { [weak self] url in
            guard let self, !self.busy else { return }
            let targetStandard = url.standardizedFileURL
            if self.allTimelineMediaPaths.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL == targetStandard }) {
                self.status = "請選擇不同檔名，避免覆蓋時間軸來源素材。"
                return
            }
            self.perform(self.timelineExportRequest(to: url, size: size), "匯出多軌成片")
        }
    }

    func timelineExportRequest(to url: URL, size: [String: Int]?) -> [String: Any] {
        let clips = project.clips.map {
            [
                "path": $0.path,
                "start": $0.still ? "" : $0.start.trimmingCharacters(in: .whitespacesAndNewlines),
                "end": $0.end.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        }
        var request: [String: Any] = [
            "action": "export",
            "destination": url.path,
            "clips": clips,
            "timeline": multitrackExportPayload(),
            "aspect": timelineOutput.aspect,
            "fps": timelineOutput.fps ?? 24,
            "codec": timelineOutput.codec ?? "h264",
            "bitDepth": timelineOutput.bitDepth ?? 8
        ]
        if let size { request["pixelSize"] = size }
        let transitions = timelineTransitions
        if transitions.contains(where: { $0 != nil }) {
            request["transitions"] = transitions.map { transition -> Any in
                guard let transition else { return NSNull() }
                return ["kind": transition.kind, "seconds": transition.seconds]
            }
        }
        return request
    }

    func previewTimeline() {
        let layout = currentMultitrackLayout()
        guard !busy, !layout.isEmpty else { return }
        if layout.hasInvalidTransitions {
            status = "有轉場超過相鄰片段長度，請修正後再預覽成片。"
            return
        }
        let output = timelineOutput
        let base = output.dimensions?.pixels
            ?? (output.aspect == "9:16" ? ["width": 1080, "height": 1920]
                : output.aspect == "1:1" ? ["width": 1080, "height": 1080] : ["width": 1920, "height": 1080])
        let divisor = Double(max(base["width"] ?? 1920, base["height"] ?? 1080)) / 640
        let size = base.mapValues { max(64, Int(Double($0) / divisor / 2) * 2) }
        let url = fs.temporaryDirectory.appendingPathComponent("MotionDesk-Timeline-\(UUID().uuidString).mp4")
        var previewReq = timelineExportRequest(to: url, size: size)
        previewReq["fps"] = 24
        previewReq["codec"] = "h264"
        previewReq["bitDepth"] = 8
        perform(previewReq, "正在準備多軌時間軸預覽", previewOnly: true)
    }

    func closeTimelinePreview() {
        if let path = timelinePreviewPath { try? fs.removeItem(atPath: path) }
        timelinePreviewPath = nil
    }

    private func validVideoSize(_ dimensions: [String: Int]?) -> Bool {
        guard let dimensions else { return false }
        return dimensions.values.allSatisfy { $0.isMultiple(of: 2) }
    }

    var referencePrompt: String {
        if let editedPrompt { return editedPrompt }
        let raw = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.optimize != false, !raw.isEmpty else { return raw }
        let style = styles.first(where: { $0.0 == project.style })?.1 ?? ""
        let cameraHints = [
            "固定鏡位": "Stable locked camera; preserve composition.",
            "細節特寫": "Close-up at eye level; keep the subject's key details in focus.",
            "緩慢推近": "A slow, gentle push-in with a small change in framing.",
            "廣角環境": "Wide establishing framing; keep subject and environment legible."
        ]
        var parts = [raw]
        if selectedLoRA == "pixel_art" {
            parts.insert("Pixel art style.", at: 0)
        } else if !style.isEmpty {
            parts.append("Visual style: " + style)
        }
        if let hint = cameraHints[camera] { parts.append("Camera: " + hint) }
        if project.kind == "video" && !usesMultiFrames {
            parts.append("Timing: Stage the requested actions in order within \(generationSeconds) seconds. " +
                         "Preserve continuity of appearance, props, and lighting across the shot.")
        }
        return parts.joined(separator: "\n\n")
    }

    func previewPrompt() {
        promptDraft = referencePrompt
        showPrompt = true
    }

    func selectSource(_ newValue: String) {
        project.source = newValue
        if bridgeShot != nil { applyBridgeFrames() }
    }

    func selectLocalModel(_ model: String) {
        if project.kind == "video" {
            project.localVideoModel = model
        } else {
            project.localImageModel = model
            let currentLoRA = (project.localImageLoRA ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentLoRA.isEmpty && !profileStore.compatibleLoRAs(for: model).contains(where: { $0.id == currentLoRA }) {
                project.localImageLoRA = ""
                project.localLoRAStrength = nil
            }
        }
    }

    func openComfyDesktop() {
        guard let application = ["/Applications/Comfy Desktop.app", "/Applications/ComfyUI.app"]
            .map({ URL(fileURLWithPath: $0) })
            .first(where: { fs.fileExists(atPath: $0.path) }) else {
            status = "找不到 Comfy Desktop。請啟動已安裝的 ComfyUI，並填入它的本機位址。"
            return
        }
        NSWorkspace.shared.openApplication(at: application, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                guard let self, !self.busy else { return }
                self.status = error?.localizedDescription ?? "請在 Comfy Desktop 開啟本機實例，再檢查就緒狀態。"
            }
        }
    }

    func prepareLocalVideo(from path: String) {
        guard !busy, imageTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return }
        guard fs.fileExists(atPath: path) else {
            status = "找不到參考圖。請重新匯入素材。"
            return
        }
        selectSource("zimage")
        project.kind = "video"
        project.localVideoModel = "wan22"
        project.videoMethod = "reference"
        project.reference = path
        project.referenceVideo = nil
        generateSelection = path
        workspace = .generate
        editedPrompt = nil
        status = "已設定影片首幀 · \(filename(path))"
    }

    func referenceFiles(in urls: [URL], extensions: Set<String>, deduplicate: Bool = true) -> [URL] {
        var seen = Set<String>()
        var files: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        func append(_ file: URL) {
            let url = file.standardizedFileURL
            guard extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: keys).isRegularFile) == true,
                  !deduplicate || seen.insert(url.path).inserted else { return }
            files.append(url)
        }
        for url in urls where url.isFileURL {
            if (try? url.resourceValues(forKeys: keys).isDirectory) == true {
                guard let contents = fs.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                let entries = contents.compactMap { $0 as? URL }
                entries.sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }.forEach(append)
            } else {
                append(url)
            }
        }
        return files
    }

    @discardableResult
    func attachReference(_ url: URL) -> Bool {
        attachReferences([url])
    }

    @discardableResult
    func attachReferences(_ urls: [URL]) -> Bool {
        guard !busy else { return false }
        if !supportsMultiImageReference && project.kind == "image" && !localModelSupportsReference {
            status = "\(profileStore.displayName(for: action)) 目前僅支援文字生圖，不支援參考圖片。"
            return false
        }
        guard takesReference else { return false }
        let files = referenceFiles(in: urls, extensions: acceptsVideoReference ? imageTypes.union(movieTypes) : imageTypes)
        guard let first = files.first else {
            status = "找不到此模式支援的參考素材。"
            return false
        }
        let images = files.filter { imageTypes.contains($0.pathExtension.lowercased()) }.map(\.path)
        let video = files.first { movieTypes.contains($0.pathExtension.lowercased()) }?.path
        var active: Set<String> = []
        if supportsMultiImageReference {
            var seen = Set<String>()
            let references = Array((referenceImages + images).filter { seen.insert($0).inserted }
                .prefix(Self.maxCloudReferenceImages))
            setReferenceImages(references)
            active.formUnion(references)
            if acceptsVideoReference, let video { project.referenceVideo = video }
            if acceptsVideoReference, let existingVideo = project.referenceVideo { active.insert(existingVideo) }
        } else if isBuiltinLocalVideoAction, movieTypes.contains(first.pathExtension.lowercased()) {
            referenceImage = ""
            project.referenceVideo = first.path
            active.insert(first.path)
        } else {
            referenceImage = first.path
            if isBuiltinLocalVideoAction { project.referenceVideo = nil }
            active.insert(first.path)
        }
        let imported = files.map(\.path)
        registerMedia(imported)
        let selected = imported.filter { active.contains($0) }.count
        workspace = .generate
        status = selected == imported.count
            ? "已加入 \(selected) 個參考素材"
            : "已加入素材庫 \(imported.count) 個檔案，其中 \(selected) 個設為這次參考。"
        return true
    }

    func attachFirstLastFromFolder(_ urls: [URL]) {
        guard !busy, usesFirstLastFrames else { return }
        let paths = referenceFiles(in: urls, extensions: imageTypes).map(\.path)
        guard paths.count >= 2, let first = paths.first, let last = paths.last else {
            status = "資料夾至少要有兩張支援的圖片。"
            return
        }
        project.firstFrame = first
        project.lastFrame = last
        registerMedia(paths)
        status = "已依檔名設定首尾影格，並將 \(paths.count) 張圖加入素材庫。"
    }

    @discardableResult
    func attachFrame(_ urls: [URL], to value: Binding<String?>) -> Bool {
        guard !busy, let url = urls.first(where: {
            $0.isFileURL && imageTypes.contains($0.pathExtension.lowercased()) && fs.fileExists(atPath: $0.path)
        }) else { return false }
        value.wrappedValue = url.path
        registerMedia([url.path])
        return true
    }

    @discardableResult
    func addKeyframes(_ urls: [URL]) -> Bool {
        guard !busy else { return false }
        let paths = referenceFiles(in: urls, extensions: imageTypes, deduplicate: false).map(\.path)
        let available = Self.maxKeyframes - orderedFrames.count
        let accepted = Array(paths.prefix(max(0, available)))
        guard !accepted.isEmpty else {
            status = available <= 0 ? "多影格已達 \(Self.maxKeyframes) 張上限。" : "找不到支援的影格圖片。"
            return false
        }
        let frames = orderedFrames + accepted
        let previous = multiTransitions
        project.keyframes = frames
        project.segments = previous + Array(repeating: FrameTransition(), count: frames.count - 1 - previous.count)
        registerMedia(accepted)
        workspace = .generate
        status = accepted.count == paths.count
            ? "已加入 \(accepted.count) 張影格"
            : "已加入 \(accepted.count) 張影格，多影格上限為 \(Self.maxKeyframes) 張。"
        return true
    }

    func moveKeyframe(_ index: Int, offset: Int) {
        let target = index + offset
        var order = Array(orderedFrames.indices)
        guard !busy, order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
        reorderKeyframes(order)
    }

    func removeKeyframe(_ index: Int) {
        guard !busy, orderedFrames.indices.contains(index) else { return }
        reorderKeyframes(orderedFrames.indices.filter { $0 != index })
    }

    private func reorderKeyframes(_ order: [Int]) {
        let frames = orderedFrames
        let previous = multiTransitions
        project.keyframes = order.map { frames[$0] }
        project.segments = zip(order, order.dropFirst()).map { left, right in
            right == left + 1 ? previous[left] : FrameTransition()
        }
    }

    func recordedGeneration(for path: String) -> RecordedGeneration? {
        RecordedGeneration.read(asset: path, jobs: jobsDirectory)
    }

    func restoreGeneration(_ settings: RecordedGeneration) {
        guard !busy else { return }
        guard settings.action != "colab" || project.localOnly != true else {
            status = "目前為僅本機模式。請先切換模式，再載入 Colab 設定。"
            return
        }
        project.source = settings.action == "colab" ? "colab" : "zimage"
        if settings.localOnly { project.localOnly = true }
        project.kind = settings.kind
        if settings.action != "colab" { selectLocalModel(settings.action) }
        if settings.action == "comfy" {
            if settings.kind == "video" { project.videoWorkflow = settings.workflow }
            else { project.workflow = settings.workflow ?? "" }
        }
        if supportsLoRA {
            project.localImageLoRA = settings.lora
            project.localLoRAStrength = settings.modelParams?.loraStrength
        }
        else if settings.action == "krea2" { project.localImageLoRA = "" }
        project.aspect = settings.aspect
        project.model = settings.model
        project.resolution = settings.resolution
        project.seconds = settings.videoMethod == "multi" && settings.segments != nil
            ? min(15, max(2, settings.seconds)) : settings.seconds
        project.cloudGPU = settings.gpu
        if let width = settings.pixelSize?["width"], let height = settings.pixelSize?["height"] {
            outputDimensions = OutputDimensions(width: String(width), height: String(height))
        } else {
            outputDimensions = nil
        }
        let storedImages = settings.referenceImages ?? (settings.reference.map { [$0] } ?? [])
        setReferenceImages(storedImages.filter { !$0.isEmpty })
        if settings.kind == "video" {
            project.referenceVideo = settings.referenceVideo
            project.videoMethod = settings.videoMethod
            if settings.videoMethod == "frames", let frames = settings.keyframes, frames.count == 2 {
                project.firstFrame = frames[0]
                project.lastFrame = frames[1]
            } else if settings.videoMethod == "multi" {
                project.keyframes = settings.keyframes
                project.segments = settings.segments
            }
        }
        project.fixedSeed = String(settings.seed)
        project.prompt = settings.prompt
        project.optimize = false
        editedPrompt = nil
        workspace = .generate
        if let removed = profileStore.removedNotice(for: settings.action) {
            status = "\(removed.message)（已保留 Seed \(settings.seed) 與提示詞，請改選模型）"
        } else {
            status = "已載入生成設定 · Seed \(settings.seed)"
        }
    }

    func interrogateReferenceImage(path: String? = nil) {
        guard !busy else { return }
        if engineStarting {
            status = "請等本機 ComfyUI 啟動完成後再執行看圖產生提示詞。"
            return
        }
        let targetImage: String
        let targetVideo: String
        if let explicitPath = path, !explicitPath.isEmpty {
            let ext = URL(fileURLWithPath: explicitPath).pathExtension.lowercased()
            if movieTypes.contains(ext) {
                targetImage = ""
                targetVideo = explicitPath
            } else {
                targetImage = explicitPath
                targetVideo = ""
            }
        } else {
            targetImage = referenceImages.first ?? ""
            targetVideo = acceptsVideoReference ? (project.referenceVideo ?? "") : ""
        }
        guard !targetImage.isEmpty || !targetVideo.isEmpty else {
            status = "請先選擇一張參考圖片（或影片首幀）再執行看圖產生提示詞。"
            return
        }
        let checkPath = !targetImage.isEmpty ? targetImage : targetVideo
        guard fs.fileExists(atPath: checkPath) else {
            status = "找不到參考素材檔案：\(filename(checkPath))"
            return
        }
        let seedText = (project.fixedSeed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seedVal: Int
        if seedText.isEmpty {
            seedVal = 42
        } else if let parsed = UInt32(seedText) {
            seedVal = Int(parsed)
        } else {
            status = "Seed 請填 0–4294967295 的整數，或留空使用預設值。"
            return
        }
        let req: [String: Any] = [
            "action": "interrogate_image",
            "endpoint": endpoint,
            "reference": targetImage,
            "referenceVideo": targetVideo,
            "seed": seedVal
        ]
        perform(req, "Qwen3-VL 看圖產生提示詞中…")
    }

    func applyVLMDraftToPrompt(append: Bool = false) {
        let trimmed = vlmDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if append, !project.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project.prompt = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + trimmed
        } else {
            project.prompt = trimmed
        }
        editedPrompt = nil
        status = append ? "已將看圖提示詞附加至畫面與動作稿件" : "已套用看圖提示詞至畫面與動作稿件"
    }

    func dismissVLMDraft() {
        showVLMDraftCard = false
    }

    func generate() {
        guard !busy else { return }
        guard !project.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "請描述你想看到的畫面。"
            return
        }
        let source = action
        if let onlineProvider = OnlineImageProvider(rawValue: source) {
            if project.localOnly == true {
                status = "已啟用僅限本機模式，無法呼叫 \(onlineProvider.displayName) API。"
                return
            }
            if project.kind != "image" {
                status = "\(onlineProvider.displayName) 僅支援圖片生成；雲端影片請改選 Google Colab。"
                return
            }
            if !(project.referenceVideo ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = "\(onlineProvider.displayName) 官方 API 僅支援圖片生成與圖片參考，不支援參考影片；請先清除參考影片再生成。"
                return
            }
            if !(project.localImageLoRA ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = "\(onlineProvider.displayName) 官方 API 不支援本機 LoRA；請先取消 LoRA 再生成。"
                return
            }
            let gate = OnlineImageProvider.canInvokeAPI(
                provider: onlineProvider,
                hasKey: onlineProvider.hasKeychainCredential(),
                billingAccepted: onlineProvider.isBillingAcknowledged(),
                networkState: NetworkReachabilityMonitor.shared.state
            )
            if !gate.allowed {
                status = gate.reason ?? "線上圖片 API 尚未就緒。"
                return
            }
            let onlineRefs = referenceImages
            if onlineRefs.contains(where: { !fs.fileExists(atPath: $0) }) {
                status = "找不到參考圖片，請重新選取檔案。"
                return
            }
            let trimmedRawPrompt = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            var request: [String: Any] = [
                "action": source,
                "kind": "image",
                "prompt": referencePrompt,
                "rawPrompt": trimmedRawPrompt,
                "originalPrompt": trimmedRawPrompt,
                "aspect": project.aspect,
                "localOnly": false,
                "billingAcknowledged": true,
                "onlineModel": onlineProvider.savedModelID(),
                "outputFolder": generationOutputDirectory.path,
                "seed": Int(UInt32.random(in: 1...2147483646)),
                "model": onlineProvider.savedModelID(),
                "resolution": project.resolution,
                "seconds": generationSeconds
            ]
            if !onlineRefs.isEmpty {
                request["referenceImages"] = onlineRefs
                request["referenceRoles"] = onlineRefs.map { referenceRole(for: $0) }
            }
            if onlineProvider == .openai {
                request["onlineQuality"] = onlineProvider.savedOpenAIQuality()
            } else {
                request["onlineImageSize"] = onlineProvider.savedGeminiImageSize()
            }
            perform(request, "\(onlineProvider.displayName) 生成中")
            return
        }
        if source != "colab", let notice = removedModelNotice {
            status = notice.message
            return
        }
        if project.kind == "motion" {
            let mgr = MografySkillManager.shared
            guard mgr.isUnlocked, let agentBin = mgr.activeAgentBinaryPath else {
                status = "尚未偵測到 Mografy Skill 或可用的 Agent CLI（請先至「元件與連線設定」安裝）。"
                return
            }
            let trimmedPrompt = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPrompt.isEmpty else {
                status = "請先輸入動態圖形製作需求。"
                return
            }
            let req: [String: Any] = [
                "action": "mografy_motion",
                "kind": "video",
                "prompt": trimmedPrompt,
                "aspect": project.aspect,
                "seconds": max(3, min(30, project.seconds)),
                "agent": mgr.effectiveAgent.rawValue,
                "agentBinary": agentBin,
                "mografyWorkspace": mgr.workspacePath,
                "attachments": mgr.attachments.map(\.path),
                "outputFolder": generationOutputDirectory.path,
            ]
            perform(req, "動態圖形生成中（\(mgr.effectiveAgent.displayName)）")
            return
        }
        if source != "colab" && engineStarting { status = "請等本機 ComfyUI 啟動。"; return }
        if project.kind == "video", let reason = videoMethodUnsupportedReason {
            status = reason
            return
        }
        if source != "colab", let issue = hasUnsupportedLocalCapabilityIssue {
            status = issue
            return
        }
        let workflow = selectedWorkflow
        if source == "comfy" && workflow.isEmpty {
            status = project.kind == "video" ? "請先選擇本機影片 API 工作流和對應模型。" : "請先選擇 ComfyUI API 工作流。"
            return
        }
        let seedText = (project.fixedSeed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = seedText.isEmpty ? UInt32.random(in: 1...2147483646) : UInt32(seedText)
        guard let seed else {
            status = "Seed 請填 0–4294967295 的整數，或留空隨機生成。"
            return
        }
        let video = acceptsVideoReference ? (project.referenceVideo ?? "") : ""
        let images = takesReference ? referenceImages : []
        let image = images.first ?? ""
        let method = project.kind == "video" ? videoMethod : ""
        let frames = method == "frames" ? [project.firstFrame ?? "", project.lastFrame ?? ""] : method == "multi" ? orderedFrames : []
        if method == "frames", frames.contains("") {
            status = "請加入首幀和尾幀圖片。"
            return
        }
        if method == "multi" {
            guard (3...Self.maxKeyframes).contains(frames.count) else {
                status = "多影格需要加入 3–\(Self.maxKeyframes) 張圖片。"
                return
            }
            if let invalid = multiTransitions.firstIndex(where: { !(2...15).contains($0.seconds) }) {
                status = "第 \(invalid + 1) 段請填 2–15 秒。"
                return
            }
        }
        if (images + [video] + frames).contains(where: { !$0.isEmpty && !fs.fileExists(atPath: $0) }) {
            status = "找不到原參考素材。請重新選取檔案。"
            return
        }
        if Self.builtinLocalVideoModels.contains(source), !image.isEmpty, !video.isEmpty {
            status = "Wan 2.2 請擇一使用參考圖片或影片首幀。"
            return
        }
        let size = outputDimensions?.pixels
        if outputDimensions != nil && (size == nil || (project.kind == "video" && !validVideoSize(size))) {
            status = project.kind == "video" ? "影片寬高請填 64–4096 之間的偶數。" : "圖片寬高請填 64–4096 之間的整數。"
            return
        }
        let trimmedRawPrompt = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var request: [String: Any] = [
            "action": source, "endpoint": endpoint, "workflow": workflow, "lora": selectedLoRA,
            "localOnly": project.localOnly == true, "gpu": cloudGPU,
            "kind": project.kind, "prompt": referencePrompt, "rawPrompt": trimmedRawPrompt,
            "originalPrompt": trimmedRawPrompt, "aspect": project.aspect,
            "model": project.model, "seconds": generationSeconds,
            "resolution": project.resolution, "videoMethod": method, "keyframes": frames,
            "seed": Int(seed), "reference": image, "referenceVideo": video
        ]
        if source != "colab" && source != "comfy" {
            request["modelParams"] = currentModelParamsPayload()
        }
        if source == "colab", !images.isEmpty { request["referenceImages"] = images }
        if let size { request["pixelSize"] = size }
        request["outputFolder"] = generationOutputDirectory.path
        if method == "multi" {
            request["segments"] = multiTransitions.map { ["seconds": $0.seconds, "prompt": $0.prompt] }
        }
        let bridgeID = bridgeShot.flatMap { matchesBridgeRequest(request, bridge: $0) ? $0.id : nil }
        if let bridgeID { request["bridgeID"] = bridgeID.uuidString }
        perform(request, source == "colab" ? "Colab 生成中" : "本機 ComfyUI 生成中", bridgeID: bridgeID)
    }

    func perform(_ value: [String: Any], _ label: String, bridgeID: UUID? = nil, previewOnly: Bool = false) {
        guard !busy else { return }
        let now = Date()
        var request = value
        if let path = request["outputFolder"] as? String {
            let day = datedDirectory(under: URL(fileURLWithPath: path, isDirectory: true), on: now)
            guard prepareOutputDirectory(day) else { return }
            request["outputFolder"] = day.path
        }
        do {
            let folder = datedDirectory(under: jobsDirectory, on: now)
                .appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
            try fs.createDirectory(at: folder, withIntermediateDirectories: true)
            let input = folder.appendingPathComponent("request.json")
            let output = folder.appendingPathComponent("result.json")
            let logURL = folder.appendingPathComponent("activity.log")
            try JSONSerialization.data(withJSONObject: request).write(to: input)
            _ = fs.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)
            guard let script = Bundle.main.url(forResource: "worker", withExtension: "py") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", script.path, input.path, output.path]
            var env = ProcessInfo.processInfo.environment
            if let comfyToken = KeychainCredentialsStore.read(account: SupportedAPIProvider.comfyui_api.keychainAccount),
               !comfyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                env["MOTIONDESK_COMFY_BEARER_TOKEN"] = comfyToken.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                env.removeValue(forKey: "MOTIONDESK_COMFY_BEARER_TOKEN")
            }
            env.removeValue(forKey: "MOTIONDESK_OPENAI_API_KEY")
            env.removeValue(forKey: "MOTIONDESK_GEMINI_API_KEY")
            let actionName = (request["action"] as? String) ?? ""
            if actionName == "openai_image",
               let openAIKey = KeychainCredentialsStore.read(account: SupportedAPIProvider.openai_image.keychainAccount)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !openAIKey.isEmpty {
                env["MOTIONDESK_OPENAI_API_KEY"] = openAIKey
            } else if actionName == "gemini_image",
                      let geminiKey = KeychainCredentialsStore.read(account: SupportedAPIProvider.gemini_image.keychainAccount)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !geminiKey.isEmpty {
                env["MOTIONDESK_GEMINI_API_KEY"] = geminiKey
            }
            process.environment = env
            process.standardOutput = logHandle
            process.standardError = logHandle
            let origin = workspace
            process.terminationHandler = { [weak self] process in
                try? logHandle.close()
                let code = process.terminationStatus
                Task { @MainActor in self?.finish(output, logURL: logURL, code: code, origin: origin, bridgeID: bridgeID, previewOnly: previewOnly) }
            }
            log = ""
            status = label
            jobStartedAt = Date()
            jobElapsedSeconds = 0
            jobProgress = nil
            jobProgressStep = nil
            jobProgressMax = nil
            jobStageLabel = ""
            busy = true
            try process.run()
            if let bridgeID, bridgeShot?.id == bridgeID { bridgeShot?.generatedVideo = nil }
            worker = process
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshLog(logURL) }
            }
        } catch {
            busy = false
            jobStartedAt = nil
            jobElapsedSeconds = 0
            jobProgress = nil
            jobProgressStep = nil
            jobProgressMax = nil
            jobStageLabel = ""
            status = error.localizedDescription
        }
    }

    private func refreshLog(_ url: URL) {
        if let startedAt = jobStartedAt {
            jobElapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines)
        var visibleLines: [String] = []
        visibleLines.reserveCapacity(lines.count)
        var latestProgressJSON: String? = nil
        let prefix = "KLIPORA_PROGRESS:"
        for line in lines {
            if line.hasPrefix(prefix) {
                latestProgressJSON = String(line.dropFirst(prefix.count))
            } else {
                visibleLines.append(line)
            }
        }
        if let jsonText = latestProgressJSON,
           let data = jsonText.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let pct = obj["pct"] as? Double {
                jobProgress = max(0.0, min(1.0, pct))
            } else if let pctNum = obj["pct"] as? NSNumber {
                jobProgress = max(0.0, min(1.0, pctNum.doubleValue))
            }
            if let step = obj["step"] as? Int, let maxStep = obj["max"] as? Int, maxStep > 0 {
                jobProgressStep = step
                jobProgressMax = maxStep
            } else if let stepNum = obj["step"] as? NSNumber, let maxNum = obj["max"] as? NSNumber, maxNum.intValue > 0 {
                jobProgressStep = stepNum.intValue
                jobProgressMax = maxNum.intValue
            }
            if let stage = obj["stage"] as? String, !stage.isEmpty {
                jobStageLabel = stage
            }
        }
        log = String(visibleLines.joined(separator: "\n").suffix(16000))
    }

    private func finish(_ resultURL: URL, logURL: URL, code: Int32, origin: Workspace, bridgeID: UUID?, previewOnly: Bool) {
        timer?.invalidate()
        timer = nil
        worker = nil
        busy = false
        refreshLog(logURL)
        jobStartedAt = nil
        jobElapsedSeconds = 0
        jobProgress = nil
        jobProgressStep = nil
        jobProgressMax = nil
        jobStageLabel = ""
        guard let data = try? Data(contentsOf: resultURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status = "工作未完成（代碼 \(code)）。請查看紀錄。"
            return
        }
        if let error = object["error"] as? String { status = error; return }
        if let interrogated = object["interrogatedPrompt"] as? String,
           !interrogated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vlmDraftPrompt = interrogated.trimmingCharacters(in: .whitespacesAndNewlines)
            vlmDraftSourcePath = (object["interrogatedImage"] as? String) ?? (referenceImages.first ?? "")
            showVLMDraftCard = true
            status = "看圖產生提示詞完成 · 請檢視或編修後點擊「套用到提示詞」"
            return
        }
        let paths = object["paths"] as? [String] ?? []
        if let canvasWF = object["canvasWorkflowPath"] as? String {
            var exported = [canvasWF]
            if let apiWF = object["apiWorkflowPath"] as? String { exported.append(apiWF) }
            LocalWorkflowExportState.shared.setPaths(exported, for: self)
        }
        if previewOnly {
            timelinePreviewPath = paths.first
            status = paths.isEmpty ? "無法開啟時間軸預覽。" : "多軌時間軸預覽已就緒"
            return
        }
        importPaths(paths, selectingIn: origin)
        if let bridgeID, bridgeShot?.id == bridgeID,
           let video = paths.last(where: {
               fs.fileExists(atPath: $0) && movieTypes.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
           }) {
            bridgeShot?.generatedVideo = video
            generateSelection = video
            if let warning = object["warning"] as? String { status = warning; return }
            if let bridge = bridgeShot, bridgeInsertionIndex(for: bridge) == nil {
                status = "補鏡頭已生成並保留於素材庫 · 原相鄰片段已刪除、重排或修改裁切，請回剪輯頁重新選擇位置"
            } else {
                status = "補鏡頭已完成 · \(filename(video))"
            }
            return
        }
        if let warning = object["warning"] as? String { status = warning; return }
        status = paths.isEmpty ? "檢查完成，詳情見工作紀錄" : "已完成 · \(filename(paths[0]))"
    }
}

@MainActor private final class NativePlayerState: ObservableObject {
    @Published var player: AVPlayer? = nil
    @Published var posterImage: NSImage? = nil
    @Published var isLoading: Bool = false
    @Published var isReady: Bool = false
    @Published var hasStartedPlayback: Bool = false
    @Published var errorMessage: String? = nil
    @Published var currentFilename: String = ""
    @Published var durationText: String = ""
    private var loadedPath: String? = nil
    private var statusObservation: NSKeyValueObservation? = nil
    private var rateObservation: NSKeyValueObservation? = nil
    private var timeObserverToken: Any? = nil

    func load(path: String) {
        guard loadedPath != path else { return }
        tearDown()
        loadedPath = path
        currentFilename = filename(path)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            errorMessage = "找不到素材檔案：\(filename(path))"
            return
        }

        isLoading = true
        isReady = false
        hasStartedPlayback = false
        errorMessage = nil
        posterImage = nil
        durationText = ""

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // 1. Reliable first-frame poster extraction (AVAssetImageGenerator strict + relaxed + FFmpeg fallback).
        let targetPath = path
        Task.detached(priority: .userInitiated) {
            let loadedDur = (try? await asset.load(.duration))?.seconds ?? 0
            let durStr = (loadedDur.isFinite && loadedDur > 0) ? Self.formatDuration(loadedDur) : ""
            let extracted = Self.extractPosterImage(path: targetPath, asset: asset)
            await MainActor.run { [weak self] in
                guard let self, self.loadedPath == targetPath else { return }
                if !durStr.isEmpty {
                    self.durationText = durStr
                }
                if let extracted {
                    self.posterImage = extracted
                    self.isLoading = false
                } else if self.isReady {
                    self.isLoading = false
                }
            }
        }

        // 2. Prepare AVPlayerItem in the background while keeping AVPlayerView hidden
        // until the user explicitly clicks Play (eliminates macOS AVPlayerView black surface before play).
        let item = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let errText = observedItem.error?.localizedDescription
            let itemDur = observedItem.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, self.loadedPath == targetPath else { return }
                switch status {
                case .readyToPlay:
                    self.isReady = true
                    self.errorMessage = nil
                    if self.durationText.isEmpty, itemDur.isFinite, itemDur > 0 {
                        self.durationText = Self.formatDuration(itemDur)
                    }
                    if self.posterImage != nil {
                        self.isLoading = false
                    }
                    avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                case .failed:
                    self.isLoading = false
                    self.isReady = false
                    self.errorMessage = "無法解碼影片：\(errText ?? filename(targetPath))"
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        rateObservation = avPlayer.observe(\.rate, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.rate > 0.01
            Task { @MainActor [weak self] in
                guard let self, self.loadedPath == targetPath else { return }
                if playing && !self.hasStartedPlayback {
                    self.hasStartedPlayback = true
                }
            }
        }

        timeObserverToken = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let secs = time.seconds
            Task { @MainActor [weak self] in
                guard let self, self.loadedPath == targetPath else { return }
                if secs.isFinite && secs > 0.04 && !self.hasStartedPlayback {
                    self.hasStartedPlayback = true
                }
            }
        }
    }

    func startPlayback() {
        guard errorMessage == nil, !hasStartedPlayback else { return }
        hasStartedPlayback = true
        if let p = player {
            let cur = p.currentTime().seconds
            if !cur.isFinite || cur < 0.02 {
                p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            p.play()
        }
    }

    func tearDown() {
        if let token = timeObserverToken, let p = player {
            p.removeTimeObserver(token)
        }
        timeObserverToken = nil
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        posterImage = nil
        isLoading = false
        isReady = false
        hasStartedPlayback = false
        errorMessage = nil
        durationText = ""
        loadedPath = nil
    }

    private nonisolated static func formatDuration(_ secs: Double) -> String {
        let total = max(0, Int(secs.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private nonisolated static func averageLuma(of cg: CGImage) -> Double {
        let w = 16, h = 16
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 128 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: buf.count, by: 4) {
            sum += 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
        }
        return sum / Double(w * h)
    }

    private nonisolated static func extractPosterImage(path: String, asset: AVURLAsset) -> NSImage? {
        // Pass 1: exact-tolerance AVAssetImageGenerator across early timestamps
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var bestCG: CGImage? = nil
        for sec in [0.05, 0.0, 0.35, 1.0] {
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: sec, preferredTimescale: 600), actualTime: nil) {
                if bestCG == nil { bestCG = cg }
                if averageLuma(of: cg) >= 10.0 {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }

        // Pass 2: relaxed keyframe tolerance if exact seek failed
        if bestCG == nil {
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                bestCG = cg
                if averageLuma(of: cg) >= 10.0 {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
        }

        // Pass 3: FFmpeg 1-frame PNG fallback (handles exotic pixel formats / codecs)
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        if let ffmpeg {
            for seekArg in ["0.05", "0.0"] {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("md-poster-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: tmp) }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpeg)
                proc.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-ss", seekArg, "-i", path, "-frames:v", "1", tmp.path]
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0, let img = NSImage(contentsOf: tmp), img.size.width > 0 {
                        return img
                    }
                }
            }
        }

        if let bestCG {
            return NSImage(cgImage: bestCG, size: NSSize(width: bestCG.width, height: bestCG.height))
        }
        return nil
    }
}

/// Container NSView that keeps AVPlayerView hidden until playback actually starts,
/// rendering a native AppKit NSImageView first-frame poster + Play button in its own
/// full-bounds stage so macOS AVPlayerView's unstarted black CALayerHost (and 0x0
/// contentOverlayView before first frame) can never cover the preview.
final class PosterBackedVideoContainerView: NSView {
    let playerView = AVPlayerView()
    private let posterStage = NSView()
    let posterImageView = NSImageView()
    private let fallbackCard = NSView()
    private let fallbackTitleLabel = NSTextField(labelWithString: "影片已就緒")
    private let fallbackDetailLabel = NSTextField(labelWithString: "無法擷取首幀縮圖，點擊播放以預覽")
    let playOverlayButton = NSButton()
    private let captionPill = NSView()
    private let captionLabel = NSTextField(labelWithString: "")
    let loadingContainer = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "載入影片首幀…")
    let errorContainer = NSView()
    private let errorTitleLabel = NSTextField(labelWithString: "無法預覽影片")
    private let errorDetailLabel = NSTextField(wrappingLabelWithString: "")

    var onStartPlayback: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHierarchy()
    }

    private func setupHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.047, green: 0.051, blue: 0.063, alpha: 1.0).cgColor

        // 1. Live AVPlayerView (hidden until playback starts so it never draws a black frame at t=0)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.updatesNowPlayingInfoCenter = false
        playerView.isHidden = true
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 2. Full-bounds first-frame poster stage (always non-zero bounds)
        posterStage.translatesAutoresizingMaskIntoConstraints = false
        posterStage.wantsLayer = true
        posterStage.layer?.backgroundColor = NSColor(calibratedRed: 0.047, green: 0.051, blue: 0.063, alpha: 1.0).cgColor
        posterStage.isHidden = true
        let stageClick = NSClickGestureRecognizer(target: self, action: #selector(handlePlayTrigger))
        posterStage.addGestureRecognizer(stageClick)
        addSubview(posterStage)
        NSLayoutConstraint.activate([
            posterStage.leadingAnchor.constraint(equalTo: leadingAnchor),
            posterStage.trailingAnchor.constraint(equalTo: trailingAnchor),
            posterStage.topAnchor.constraint(equalTo: topAnchor),
            posterStage.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        posterImageView.translatesAutoresizingMaskIntoConstraints = false
        posterImageView.imageScaling = .scaleProportionallyUpOrDown
        posterImageView.imageAlignment = .alignCenter
        posterImageView.setAccessibilityRole(.image)
        posterStage.addSubview(posterImageView)
        NSLayoutConstraint.activate([
            posterImageView.leadingAnchor.constraint(equalTo: posterStage.leadingAnchor),
            posterImageView.trailingAnchor.constraint(equalTo: posterStage.trailingAnchor),
            posterImageView.topAnchor.constraint(equalTo: posterStage.topAnchor),
            posterImageView.bottomAnchor.constraint(equalTo: posterStage.bottomAnchor)
        ])

        // Fallback card when poster extraction fails but AVPlayerItem is playable
        fallbackCard.translatesAutoresizingMaskIntoConstraints = false
        fallbackCard.wantsLayer = true
        fallbackCard.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.96).cgColor
        fallbackCard.layer?.cornerRadius = 12
        fallbackCard.layer?.borderWidth = 1
        fallbackCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        fallbackCard.isHidden = true
        fallbackTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        fallbackTitleLabel.textColor = .white
        fallbackDetailLabel.font = NSFont.systemFont(ofSize: 11)
        fallbackDetailLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        let fbStack = NSStackView(views: [fallbackTitleLabel, fallbackDetailLabel])
        fbStack.orientation = .vertical
        fbStack.spacing = 4
        fbStack.alignment = .centerX
        fbStack.translatesAutoresizingMaskIntoConstraints = false
        fallbackCard.addSubview(fbStack)
        posterStage.addSubview(fallbackCard)
        NSLayoutConstraint.activate([
            fbStack.leadingAnchor.constraint(equalTo: fallbackCard.leadingAnchor, constant: 18),
            fbStack.trailingAnchor.constraint(equalTo: fallbackCard.trailingAnchor, constant: -18),
            fbStack.topAnchor.constraint(equalTo: fallbackCard.topAnchor, constant: 14),
            fbStack.bottomAnchor.constraint(equalTo: fallbackCard.bottomAnchor, constant: -14),
            fallbackCard.centerXAnchor.constraint(equalTo: posterStage.centerXAnchor),
            fallbackCard.centerYAnchor.constraint(equalTo: posterStage.centerYAnchor, constant: -54)
        ])

        // Center circular Play button on top of the poster
        playOverlayButton.translatesAutoresizingMaskIntoConstraints = false
        playOverlayButton.isBordered = false
        playOverlayButton.title = ""
        playOverlayButton.target = self
        playOverlayButton.action = #selector(handlePlayTrigger)
        playOverlayButton.wantsLayer = true
        playOverlayButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        playOverlayButton.layer?.cornerRadius = 32
        playOverlayButton.layer?.borderWidth = 1.5
        playOverlayButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        if let sym = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "播放影片") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            playOverlayButton.image = sym.withSymbolConfiguration(cfg)
            playOverlayButton.contentTintColor = .white
            playOverlayButton.imagePosition = .imageOnly
        }
        playOverlayButton.setAccessibilityRole(.button)
        playOverlayButton.setAccessibilityLabel("播放影片")
        playOverlayButton.setAccessibilityTitle("Play")
        playOverlayButton.toolTip = "點擊播放影片"
        posterStage.addSubview(playOverlayButton)
        NSLayoutConstraint.activate([
            playOverlayButton.widthAnchor.constraint(equalToConstant: 64),
            playOverlayButton.heightAnchor.constraint(equalToConstant: 64),
            playOverlayButton.centerXAnchor.constraint(equalTo: posterStage.centerXAnchor),
            playOverlayButton.centerYAnchor.constraint(equalTo: posterStage.centerYAnchor)
        ])

        // Bottom caption pill showing filename + duration + play hint
        captionPill.translatesAutoresizingMaskIntoConstraints = false
        captionPill.wantsLayer = true
        captionPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        captionPill.layer?.cornerRadius = 8
        captionPill.layer?.borderWidth = 1
        captionPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        captionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        captionLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionPill.addSubview(captionLabel)
        posterStage.addSubview(captionPill)
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: captionPill.leadingAnchor, constant: 10),
            captionLabel.trailingAnchor.constraint(equalTo: captionPill.trailingAnchor, constant: -10),
            captionLabel.topAnchor.constraint(equalTo: captionPill.topAnchor, constant: 5),
            captionLabel.bottomAnchor.constraint(equalTo: captionPill.bottomAnchor, constant: -5),
            captionPill.centerXAnchor.constraint(equalTo: posterStage.centerXAnchor),
            captionPill.bottomAnchor.constraint(equalTo: posterStage.bottomAnchor, constant: -14)
        ])

        // 3. Loading badge (pinned to full container, never 0x0)
        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.wantsLayer = true
        loadingContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        loadingContainer.layer?.cornerRadius = 10
        loadingContainer.layer?.borderWidth = 1
        loadingContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        loadingContainer.isHidden = true

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false

        loadingLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        loadingLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

        let loadStack = NSStackView(views: [loadingSpinner, loadingLabel])
        loadStack.orientation = .horizontal
        loadStack.spacing = 8
        loadStack.alignment = .centerY
        loadStack.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.addSubview(loadStack)
        addSubview(loadingContainer)
        NSLayoutConstraint.activate([
            loadStack.leadingAnchor.constraint(equalTo: loadingContainer.leadingAnchor, constant: 14),
            loadStack.trailingAnchor.constraint(equalTo: loadingContainer.trailingAnchor, constant: -14),
            loadStack.topAnchor.constraint(equalTo: loadingContainer.topAnchor, constant: 10),
            loadStack.bottomAnchor.constraint(equalTo: loadingContainer.bottomAnchor, constant: -10),
            loadingContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingContainer.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // 4. Error banner (pinned to full container)
        errorContainer.translatesAutoresizingMaskIntoConstraints = false
        errorContainer.wantsLayer = true
        errorContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        errorContainer.layer?.cornerRadius = 10
        errorContainer.layer?.borderWidth = 1
        errorContainer.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.45).cgColor
        errorContainer.isHidden = true

        errorTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        errorTitleLabel.textColor = NSColor.systemOrange
        errorDetailLabel.font = NSFont.systemFont(ofSize: 11.5)
        errorDetailLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        errorDetailLabel.alignment = .center
        errorDetailLabel.preferredMaxLayoutWidth = 340

        let errStack = NSStackView(views: [errorTitleLabel, errorDetailLabel])
        errStack.orientation = .vertical
        errStack.spacing = 6
        errStack.alignment = .centerX
        errStack.translatesAutoresizingMaskIntoConstraints = false
        errorContainer.addSubview(errStack)
        addSubview(errorContainer)
        NSLayoutConstraint.activate([
            errStack.leadingAnchor.constraint(equalTo: errorContainer.leadingAnchor, constant: 16),
            errStack.trailingAnchor.constraint(equalTo: errorContainer.trailingAnchor, constant: -16),
            errStack.topAnchor.constraint(equalTo: errorContainer.topAnchor, constant: 12),
            errStack.bottomAnchor.constraint(equalTo: errorContainer.bottomAnchor, constant: -12),
            errorContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorContainer.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func handlePlayTrigger() {
        onStartPlayback?()
    }

    func updateState(
        player: AVPlayer?,
        poster: NSImage?,
        isLoading: Bool,
        isReady: Bool,
        hasStartedPlayback: Bool,
        errorMessage: String?,
        filename: String,
        durationText: String
    ) {
        if playerView.player !== player {
            playerView.player = player
        }

        if let err = errorMessage, !err.isEmpty {
            playerView.isHidden = true
            posterStage.isHidden = true
            loadingContainer.isHidden = true
            loadingSpinner.stopAnimation(nil)
            errorDetailLabel.stringValue = err
            errorContainer.isHidden = false
            return
        }

        errorContainer.isHidden = true

        if hasStartedPlayback {
            posterStage.isHidden = true
            loadingContainer.isHidden = true
            loadingSpinner.stopAnimation(nil)
            playerView.isHidden = false
            return
        }

        // Before playback starts: NEVER expose unstarted AVPlayerView's black layer.
        playerView.isHidden = true

        let durSuffix = durationText.isEmpty ? "" : " · \(durationText)"
        captionLabel.stringValue = "首幀預覽 · \(filename)\(durSuffix) · 點擊播放"

        if let poster {
            posterImageView.image = poster
            posterImageView.isHidden = false
            posterImageView.setAccessibilityLabel("影片首幀預覽：\(filename)")
            fallbackCard.isHidden = true
            posterStage.isHidden = false
            loadingContainer.isHidden = true
            loadingSpinner.stopAnimation(nil)
        } else if isLoading {
            posterImageView.image = nil
            posterStage.isHidden = true
            loadingLabel.stringValue = filename.isEmpty ? "載入影片首幀…" : "載入影片首幀：\(filename)"
            loadingContainer.isHidden = false
            loadingSpinner.startAnimation(nil)
        } else if isReady {
            posterImageView.image = nil
            posterImageView.isHidden = true
            fallbackTitleLabel.stringValue = "影片已載入：\(filename)"
            fallbackCard.isHidden = false
            posterStage.isHidden = false
            loadingContainer.isHidden = true
            loadingSpinner.stopAnimation(nil)
        } else {
            posterStage.isHidden = true
            loadingContainer.isHidden = false
            loadingSpinner.startAnimation(nil)
        }
    }
}

private struct NativeAVPlayerHost: NSViewRepresentable {
    let player: AVPlayer?
    let poster: NSImage?
    let isLoading: Bool
    let isReady: Bool
    let hasStartedPlayback: Bool
    let errorMessage: String?
    let filename: String
    let durationText: String
    let onStartPlayback: () -> Void

    func makeNSView(context: Context) -> PosterBackedVideoContainerView {
        let view = PosterBackedVideoContainerView()
        view.onStartPlayback = onStartPlayback
        view.updateState(
            player: player,
            poster: poster,
            isLoading: isLoading,
            isReady: isReady,
            hasStartedPlayback: hasStartedPlayback,
            errorMessage: errorMessage,
            filename: filename,
            durationText: durationText
        )
        return view
    }

    func updateNSView(_ view: PosterBackedVideoContainerView, context: Context) {
        view.onStartPlayback = onStartPlayback
        view.updateState(
            player: player,
            poster: poster,
            isLoading: isLoading,
            isReady: isReady,
            hasStartedPlayback: hasStartedPlayback,
            errorMessage: errorMessage,
            filename: filename,
            durationText: durationText
        )
    }

    static func dismantleNSView(_ view: PosterBackedVideoContainerView, coordinator: ()) {
        view.playerView.player?.pause()
        view.playerView.player = nil
    }
}

struct NativePlayer: View {
    let path: String
    @StateObject private var state = NativePlayerState()

    var body: some View {
        NativeAVPlayerHost(
            player: state.player,
            poster: state.posterImage,
            isLoading: state.isLoading,
            isReady: state.isReady,
            hasStartedPlayback: state.hasStartedPlayback,
            errorMessage: state.errorMessage,
            filename: state.currentFilename,
            durationText: state.durationText,
            onStartPlayback: { state.startPlayback() }
        )
        .onAppear { state.load(path: path) }
        .onChange(of: path) { _, nextPath in state.load(path: nextPath) }
        .onDisappear { state.tearDown() }
    }
}

struct MediaSurface: View {
    var path: String
    var body: some View {
        Group {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if path.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(studioAccent)
                        .frame(width: 62, height: 62)
                        .background(surface, in: RoundedRectangle(cornerRadius: 16))
                    Text("選取素材以預覽").font(.system(size: 17, weight: .semibold))
                    Text("從左側匯入，或在右側生成").font(.callout).foregroundStyle(.secondary)
                }
            } else if !FileManager.default.fileExists(atPath: path) {
                ContentUnavailableView("找不到素材", systemImage: "folder.badge.questionmark", description: Text(filename(path)))
            } else if imageTypes.contains(ext) {
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("無法預覽圖片", systemImage: "photo", description: Text(filename(path)))
                }
            } else {
                NativePlayer(path: path)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.047, green: 0.051, blue: 0.063))
    }
}

struct MediaThumbnail: View {
    let path: String
    var width: CGFloat = 48
    var height: CGFloat = 36
    var reloadToken: Int = 0
    final class Thumbnail: ObservableObject {
        @Published var bitmap: CGImage?
    }
    @StateObject private var thumbnail = Thumbnail()

    var body: some View {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        RoundedRectangle(cornerRadius: 5).fill(surface)
            .overlay {
                if let bitmap = thumbnail.bitmap {
                    Image(decorative: bitmap, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: imageTypes.contains(ext) ? "photo" : movieTypes.contains(ext) ? "film" : "waveform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            .task(id: "\(path)#\(reloadToken)") {
                thumbnail.bitmap = nil
                let url = URL(fileURLWithPath: path)
                if imageTypes.contains(ext) {
                    let bitmap = await Task.detached(priority: .utility) {
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                        let options: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 132,
                        ]
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                    }.value
                    if !Task.isCancelled { thumbnail.bitmap = bitmap }
                } else if movieTypes.contains(ext) {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 132, height: 132)
                    let bitmap = try? await generator.image(at: .zero).image
                    if !Task.isCancelled { thumbnail.bitmap = bitmap }
                }
            }
    }
}

private enum EditPreviewMode: String {
    case timeline
    case source
}

@MainActor private final class TimelineViewState: ObservableObject {
    @Published var selectedClip: UUID?
    @Published var selectedJunction: UUID?
    @Published var pixelsPerSecond: CGFloat = 64
    @Published var previewMode: EditPreviewMode = .timeline
    @Published var viewportWidth: CGFloat = 680
    @Published var hoveredJunction: UUID?
    @Published var dropTargetClip: UUID?
    @Published var trimPreviewHint: String?
    var keyMonitor: Any?

    static let minZoom: CGFloat = 16
    static let maxZoom: CGFloat = 240

    func zoomIn() {
        pixelsPerSecond = min(Self.maxZoom, (pixelsPerSecond * 1.25).rounded())
    }

    func zoomOut() {
        pixelsPerSecond = max(Self.minZoom, (pixelsPerSecond / 1.25).rounded())
    }

    func fit(totalDuration: Double) {
        let available = max(140, viewportWidth - 48)
        let target = available / CGFloat(max(1.0, totalDuration))
        pixelsPerSecond = min(Self.maxZoom, max(Self.minZoom, target))
    }
}

struct LibraryItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
final class LibraryInteractionState: ObservableObject {
    @Published var isDropTargeted: Bool = false
    @Published var marqueeStart: CGPoint? = nil
    @Published var marqueeCurrent: CGPoint? = nil
    var itemFrames: [String: CGRect] = [:]
    var preDragSelection: Set<String> = []

    var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)
        guard w >= 4 || h >= 4 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func updateMarquee(value: DragGesture.Value, app: Studio) {
        if marqueeStart == nil {
            marqueeStart = value.startLocation
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) || flags.contains(.command) {
                preDragSelection = app.libraryBatchSelection ?? []
            } else {
                preDragSelection = []
            }
        }
        marqueeCurrent = value.location
        guard let rect = marqueeRect else { return }
        var hits = preDragSelection
        for (path, frame) in itemFrames where frame.intersects(rect) {
            hits.insert(path)
        }
        app.libraryBatchSelection = hits
    }

    func endMarquee(app: Studio) {
        marqueeStart = nil
        marqueeCurrent = nil
        preDragSelection = []
        if app.libraryBatchSelection?.isEmpty == true {
            app.libraryBatchSelection = nil
        }
    }
}

struct LibraryDropHighlightOverlay: View {
    let isTargeted: Bool

    var body: some View {
        if isTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(studioAccent.opacity(0.14))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(studioAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(studioAccent)
                    Text("放開滑鼠以匯入素材")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(4)
            .allowsHitTesting(false)
        }
    }
}

struct LibraryMarqueeBoxOverlay: View {
    let rect: CGRect?

    var body: some View {
        if let rect {
            Rectangle()
                .fill(studioAccent.opacity(0.20))
                .overlay(
                    Rectangle()
                        .strokeBorder(studioAccent, lineWidth: 1.25)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }
}

struct ConditionalLibraryDragModifier: ViewModifier {
    let enabled: Bool
    let url: URL
    let onMarqueeChanged: (DragGesture.Value) -> Void
    let onMarqueeEnded: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.draggable(url)
        } else {
            content.highPriorityGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("kliporaEditLibrarySpace"))
                    .onChanged(onMarqueeChanged)
                    .onEnded { _ in onMarqueeEnded() }
            )
        }
    }
}

struct StudioView: View {
    @ObservedObject var app: Studio
    @ObservedObject private var network = NetworkReachabilityMonitor.shared
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var startup = KliporaStartupController.shared
    @ObservedObject private var mografySkill = MografySkillManager.shared
    @AppStorage("MotionDesk.onlineImage.openai_image.billingAcknowledged") private var openAIBillingAccepted = false
    @AppStorage("MotionDesk.onlineImage.gemini_image.billingAcknowledged") private var geminiBillingAccepted = false
    @StateObject private var multitrackState = MultitrackEditState()
    @StateObject private var multitrackPlayback = MultitrackPlaybackController()
    @StateObject private var libraryInteraction = LibraryInteractionState()

    private var editLayout: MultitrackLayout {
        app.currentMultitrackLayout()
    }

    private var onlineGenerationUnavailable: Bool {
        if let provider = OnlineImageProvider(rawValue: app.source) {
            return !OnlineImageProvider.canInvokeAPI(
                provider: provider,
                hasKey: provider.hasKeychainCredential(),
                billingAccepted: provider == .openai ? openAIBillingAccepted : geminiBillingAccepted,
                networkState: network.state
            ).allowed
        }
        return app.source == "colab" && network.isOffline
    }

    var body: some View {
        let layout = editLayout
        ZStack {
            mainShell
            if startup.isSplashVisible {
                KliporaSplashOverlay(startup: startup)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
            .frame(minWidth: 960, minHeight: 680)
            .background(canvas)
            .foregroundStyle(StudioTheme.textPrimary)
            .tint(StudioTheme.neutralAccent)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $startup.isOnboardingPresented) {
                KliporaOnboardingSheet(startup: startup)
            }
            .sheet(isPresented: $startup.isAboutPresented) {
                KliporaAboutSheet()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kliporaOpenAbout)) { _ in
                startup.isAboutPresented = true
            }
            .task(id: app.allTimelineMediaPaths) {
                await app.loadMultitrackDurations()
                multitrackPlayback.syncLayout(app.currentMultitrackLayout())
            }
            .onAppear {
                multitrackPlayback.syncLayout(layout)
                installEditKeyMonitor()
                startup.runStartupSelfCheck()
            }
            .onDisappear {
                removeEditKeyMonitor()
                multitrackPlayback.tearDown()
            }
            .onChange(of: layout) { _, newLayout in
                multitrackState.reconcileSelection(with: newLayout)
                multitrackPlayback.syncLayout(newLayout)
            }
            .onChange(of: app.workspace) { _, newWorkspace in
                if newWorkspace != .edit {
                    multitrackPlayback.pause()
                } else {
                    let current = app.currentMultitrackLayout()
                    multitrackState.reconcileSelection(with: current)
                    multitrackPlayback.syncLayout(current)
                    if !current.isEmpty {
                        multitrackState.previewMode = .timeline
                    }
                }
            }
            .onChange(of: app.mediaReloadToken) { _, _ in
                multitrackPlayback.reloadAllMedia()
            }
            .onChange(of: app.projectRevision) { _, _ in
                multitrackPlayback.pause()
                let current = app.currentMultitrackLayout()
                multitrackState.selection = nil
                multitrackState.reconcileSelection(with: current)
                multitrackState.previewMode = .timeline
                multitrackPlayback.syncLayout(current)
                multitrackPlayback.seek(to: 0, exact: true)
                if !current.isEmpty {
                    multitrackState.fit(totalDuration: current.totalDuration)
                }
            }
            .onChange(of: app.lastAddedClipID) { _, addedID in
                handleLastAddedClip(addedID)
            }
            .sheet(isPresented: Binding(get: { app.timelinePreviewPath != nil }, set: {
                if !$0 { app.closeTimelinePreview() }
            })) {
                timelinePreviewSheet
            }
            .onChange(of: app.project.prompt) { _, _ in app.editedPrompt = nil }
            .onChange(of: app.project.style) { _, _ in app.editedPrompt = nil }
            .onChange(of: app.project.camera) { _, _ in app.editedPrompt = nil }
            .onChange(of: app.project.kind) { _, _ in app.editedPrompt = nil }
            .onChange(of: app.action) { _, _ in app.editedPrompt = nil }
            .onChange(of: app.selectedLoRA) { _, _ in app.editedPrompt = nil }
            .onChange(of: app.generationSeconds) { _, _ in app.editedPrompt = nil }
            .onChange(of: app.project.optimize) { _, _ in app.editedPrompt = nil }
            .sheet(isPresented: $app.showPrompt) {
                promptSheet
            }
            .sheet(isPresented: $app.showLog) {
                logSheet
            }
    }

    private var mainShell: some View {
        VStack(spacing: 0) {
            top
            Divider()
            if app.workspace == .generate {
                generateWorkspaceView
            } else {
                editWorkspaceView
            }
            Divider()
            statusFooter
        }
    }

    private var generateWorkspaceView: some View {
        HSplitView {
            library.frame(minWidth: 188, idealWidth: 218, maxWidth: 280)
            preview
            inspector.frame(minWidth: 300, idealWidth: 344, maxWidth: 420)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editWorkspaceView: some View {
        VSplitView {
            HSplitView {
                MultitrackLibraryPanel(
                    app: app,
                    state: multitrackState,
                    playback: multitrackPlayback
                )
                .frame(minWidth: 232, idealWidth: 268, maxWidth: 344)
                MultitrackPreviewMonitor(
                    app: app,
                    state: multitrackState,
                    playback: multitrackPlayback
                )
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                MultitrackInspectorView(
                    app: app,
                    state: multitrackState,
                    playback: multitrackPlayback
                )
                .frame(minWidth: 296, idealWidth: 326, maxWidth: 392)
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            MultitrackTimelineDockView(
                app: app,
                state: multitrackState,
                playback: multitrackPlayback
            )
            .frame(minHeight: 230, idealHeight: 280, maxHeight: 480)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formattedJobElapsed(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formattedJobETA(elapsed: Int, progress: Double?, step: Int?, maxStep: Int?) -> String? {
        // Only estimate remaining time when backed by real linear step/frame progress,
        // never from fixed coarse stage milestones (e.g. 12% while an AI Agent is coding).
        guard let step, let maxStep, maxStep > 0, step >= 2, step < maxStep,
              let pct = progress, pct >= 0.05, pct < 0.99, elapsed >= 5 else { return nil }
        let ratio = Double(step) / Double(maxStep)
        let remaining = Int((Double(elapsed) * (1.0 - ratio) / ratio).rounded())
        guard remaining > 0 else { return nil }
        if remaining >= 3600 {
            let h = remaining / 3600
            let m = (remaining % 3600) / 60
            return "預估剩餘 ~\(h) 小時 \(m) 分"
        } else if remaining >= 60 {
            let m = max(1, Int((Double(remaining) / 60.0).rounded()))
            return "預估剩餘 ~\(m) 分"
        }
        return "預估剩餘 ~\(remaining) 秒"
    }

    private var statusFooter: some View {
        HStack(spacing: 10) {
            if app.busy {
                ProgressView().controlSize(.small)
                Text(app.status).lineLimit(1).truncationMode(.tail).help(app.status)
                if !app.jobStageLabel.isEmpty {
                    Text("· \(app.jobStageLabel)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let pct = app.jobProgress {
                    ProgressView(value: pct, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(studioAccent)
                        .frame(width: 96)
                    Text("\(Int((pct * 100).rounded()))%")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(studioAccent)
                    if let step = app.jobProgressStep, let maxStep = app.jobProgressMax, maxStep > 0 {
                        Text("(\(step)/\(maxStep))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("已耗時 \(formattedJobElapsed(app.jobElapsedSeconds))")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
                if let eta = formattedJobETA(elapsed: app.jobElapsedSeconds, progress: app.jobProgress, step: app.jobProgressStep, maxStep: app.jobProgressMax) {
                    Text(eta)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(studioAccent)
                Text(app.status).lineLimit(1).truncationMode(.tail).help(app.status)
            }
            Spacer()
            Button("工作紀錄") { app.showLog.toggle() }.disabled(app.log.isEmpty && !app.busy)
        }.font(.callout).padding(.horizontal, 14).frame(height: 34).background(panel)
    }

    private func handleLastAddedClip(_ addedID: UUID?) {
        guard let addedID else { return }
        let current = app.currentMultitrackLayout()
        multitrackState.previewMode = .timeline
        multitrackPlayback.syncLayout(current)
        if let vt = current.videoTracks.first(where: { $0.segments.contains(where: { $0.id == addedID }) }),
           let seg = vt.segments.first(where: { $0.id == addedID }) {
            multitrackState.selection = .videoClip(trackID: vt.id, clipID: seg.id)
            multitrackState.selectActiveTrack(vt.id, kind: .video)
            multitrackPlayback.pause()
            multitrackPlayback.seek(to: seg.timelineStart, exact: true)
        } else if let at = current.audioTracks.first(where: { $0.segments.contains(where: { $0.id == addedID }) }),
                  let seg = at.segments.first(where: { $0.id == addedID }) {
            multitrackState.selection = .audioClip(trackID: at.id, clipID: seg.id)
            multitrackState.selectActiveTrack(at.id, kind: .audio)
            multitrackPlayback.pause()
            multitrackPlayback.seek(to: seg.timelineStart, exact: true)
        } else if let tt = current.textTracks.first(where: { $0.segments.contains(where: { $0.id == addedID }) }),
                  let seg = tt.segments.first(where: { $0.id == addedID }) {
            multitrackState.selection = .textClip(trackID: tt.id, clipID: seg.id)
            multitrackState.selectActiveTrack(tt.id, kind: .text)
            multitrackPlayback.pause()
            multitrackPlayback.seek(to: seg.timelineStart, exact: true)
        }
    }

    private var timelinePreviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("多軌時間軸渲染預覽（含精準疊合、音訊混音、字幕與轉場）").font(.headline)
                Spacer()
                Button("關閉", action: app.closeTimelinePreview)
            }
            if let path = app.timelinePreviewPath { MediaSurface(path: path) }
        }.padding(14).frame(width: 760, height: 480)
    }

    private var promptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("送出提示詞").font(.title2.bold())
            Text("這裡的文字會原樣送給選定的生成來源。").foregroundStyle(.secondary)
            TextEditor(text: $app.promptDraft).font(.body).padding(5)
            HStack {
                Button("取消") { app.showPrompt = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("套用編輯") {
                    app.editedPrompt = app.promptDraft
                    app.showPrompt = false
                }.keyboardShortcut(.defaultAction)
                 .disabled(app.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 650, height: 375)
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("工作紀錄").font(.title2.bold())
                Spacer()
                Button("關閉") { app.showLog = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(app.log.isEmpty ? "等待工作回報⋯" : app.log)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18).frame(width: 740, height: 480)
    }

    private func isTextInputFocused() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        if window.attachedSheet != nil { return true }
        guard let responder = window.firstResponder else { return false }
        return responder is NSText || responder is NSTextView || responder is NSTextField
    }

    private func installEditKeyMonitor() {
        removeEditKeyMonitor()
        multitrackState.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [app, multitrackState, multitrackPlayback] event in
            guard app.workspace == .edit,
                  !app.showPrompt, !app.showLog, app.timelinePreviewPath == nil,
                  !isTextInputFocused() else {
                return event
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
                return event
            }
            let layout = app.currentMultitrackLayout()
            switch event.keyCode {
            case 49: // Space
                if !layout.isEmpty {
                    multitrackState.previewMode = .timeline
                    multitrackPlayback.togglePlay()
                    return nil
                }
            case 51, 117: // Delete / Forward Delete
                if !app.busy, multitrackState.selection != nil {
                    multitrackState.deleteSelected(app: app, playback: multitrackPlayback)
                    return nil
                }
            case 123: // Left Arrow
                if !layout.isEmpty {
                    multitrackState.previewMode = .timeline
                    multitrackPlayback.stepFrames(modifiers.contains(.shift) ? -24 : -1)
                    return nil
                }
            case 124: // Right Arrow
                if !layout.isEmpty {
                    multitrackState.previewMode = .timeline
                    multitrackPlayback.stepFrames(modifiers.contains(.shift) ? 24 : 1)
                    return nil
                }
            case 115: // Home
                if !layout.isEmpty {
                    multitrackState.previewMode = .timeline
                    multitrackPlayback.jumpToStart()
                    return nil
                }
            case 119: // End
                if !layout.isEmpty {
                    multitrackState.previewMode = .timeline
                    multitrackPlayback.jumpToEnd()
                    return nil
                }
            default:
                break
            }
            if let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case "s", "b":
                    if !app.busy && !layout.isEmpty {
                        multitrackState.splitSelectedAtPlayhead(app: app, playback: multitrackPlayback)
                        return nil
                    }
                case "+", "=":
                    multitrackState.zoomIn()
                    return nil
                case "-":
                    multitrackState.zoomOut()
                    return nil
                case "0":
                    multitrackState.fit(totalDuration: layout.totalDuration)
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    private func removeEditKeyMonitor() {
        if let monitor = multitrackState.keyMonitor {
            NSEvent.removeMonitor(monitor)
            multitrackState.keyMonitor = nil
        }
    }

    var top: some View {
        let mtLayout = app.currentMultitrackLayout()
        let headerLogo: NSImage = {
            if let url = Bundle.main.url(forResource: "KliporaLogo", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                return img
            }
            return NSApp.applicationIconImage
        }()
        return HStack(spacing: 12) {
            Image(nsImage: headerLogo).renderingMode(.original).resizable().scaledToFit()
                .frame(width: 42, height: 42).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.text("app.name", fallback: "Klipora")).font(.system(size: 19, weight: .semibold))
                HStack(spacing: 4) {
                    TextField(
                        l10n.text("app.untitled", fallback: "未命名專案"),
                        text: Binding(
                            get: {
                                let t = app.project.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !t.isEmpty { return app.project.title }
                                return app.projectURL?.deletingPathExtension().lastPathComponent ?? ""
                            },
                            set: { app.project.title = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(minWidth: 100, idealWidth: 145, maxWidth: 210)
                    .accessibilityLabel("專案名稱")
                    .help("點選可直接編輯專案名稱")
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundStyle(StudioTheme.textMuted)
                }
            }
            Spacer()
            Picker("工作區", selection: $app.workspace) {
                Text(l10n.text("workspace.generate", fallback: "生成")).tag(Workspace.generate)
                Text(l10n.text("workspace.edit", fallback: "剪輯")).tag(Workspace.edit)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 160).accessibilityLabel("工作區")
            Spacer()
            PortabilitySetupToolbarButton(app: app)
            Button(action: app.open) { Label(l10n.text("toolbar.open", fallback: "開啟專案"), systemImage: "folder") }.disabled(app.busy).keyboardShortcut("o")
            Button(action: app.save) { Label(l10n.text("toolbar.save", fallback: "儲存專案"), systemImage: "tray.and.arrow.down") }.keyboardShortcut("s")
            if app.workspace == .edit {
                Button(l10n.text("toolbar.preview", fallback: "預覽成片"), action: app.previewTimeline)
                    .disabled(app.busy || mtLayout.isEmpty || mtLayout.hasInvalidTransitions)
                    .help("依目前多軌疊合、音訊混音、字幕與轉場產生低解析度預覽")
                Button { app.export() } label: { Label(l10n.text("toolbar.export", fallback: "匯出 MP4"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .disabled(app.busy || mtLayout.isEmpty || mtLayout.hasInvalidTransitions)
            }
        }.padding(.horizontal, 16).frame(height: 66).background(StudioWarmGlowBackground(intensity: 0.9, base: panel))
    }

    var preview: some View {
        VStack(spacing: 0) {
            previewHeader
            MediaSurface(path: app.selection)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07)))
                .padding([.horizontal, .bottom], 12)
            if app.workspace == .generate && app.project.kind == "video" {
                GenerationVideoSequenceDock(app: app)
                    .padding([.horizontal, .bottom], 12)
            } else if app.workspace == .generate && app.project.kind == "image" && app.supportsImageReference {
                GenerationImageReferenceDock(app: app)
                    .padding([.horizontal, .bottom], 12)
            }
        }.frame(minWidth: 415, maxWidth: .infinity, maxHeight: .infinity)
    }

    var previewHeader: some View {
        HStack {
            Label("預覽", systemImage: "play.rectangle").font(.headline)
            Spacer()
            if !app.selection.isEmpty {
                Text(filename(app.selection)).font(.callout).lineLimit(1).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 15).frame(height: 44)
    }

    var library: some View {
        let batch = app.libraryBatchSelection
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("素材庫", systemImage: "square.stack").font(.headline)
                Spacer()
                Text(app.project.media.count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if batch != nil {
                    Button("完成") { app.libraryBatchSelection = nil }.controlSize(.small)
                } else {
                    Button("多選") { app.libraryBatchSelection = [] }
                        .controlSize(.small)
                        .disabled(app.project.media.isEmpty)
                        .help("勾選多個項目後一起從素材庫移除")
                    Button { app.importMedia() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("匯入素材").help("匯入素材")
                }
            }.padding(14)
            HStack(spacing: 6) {
                Button {
                    app.openOutputDirectory(app.defaultOutputDirectory)
                } label: {
                    Label("開啟預設位置", systemImage: "folder")
                }.help(app.defaultOutputDirectory.path)
                Menu {
                    Button("開啟今日成品") {
                        app.openOutputDirectory(datedDirectory(under: app.defaultOutputDirectory))
                    }
                    Button("更改預設位置…", action: app.chooseDefaultOutputDirectory)
                    if app.defaultOutputPath != nil {
                        Button("恢復原始位置", action: app.resetDefaultOutputDirectory)
                    }
                } label: {
                    Image(systemName: "gearshape")
                }.accessibilityLabel("預設儲存位置設定")
            }.controlSize(.small).padding(.horizontal, 14).padding(.bottom, 8)
            Text((app.defaultOutputDirectory.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(app.defaultOutputDirectory.path)
                .padding(.horizontal, 14).padding(.bottom, 8)
            if app.project.media.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("拖曳影片、圖片或音檔至此，或點下方選擇檔案")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("選擇檔案", action: app.importMedia)
                }.padding(12)
            }
            GeometryReader { scrollGeo in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(minWidth: scrollGeo.size.width, minHeight: max(180, scrollGeo.size.height))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if app.libraryBatchSelection != nil {
                                    app.libraryBatchSelection = nil
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 5, coordinateSpace: .named("kliporaGenLibrarySpace"))
                                    .onChanged { value in
                                        libraryInteraction.updateMarquee(value: value, app: app)
                                    }
                                    .onEnded { _ in
                                        libraryInteraction.endMarquee(app: app)
                                    }
                            )

                        LazyVStack(spacing: 3) {
                            ForEach(app.project.media, id: \.self) { path in
                                let row = Button {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        var selected = app.libraryBatchSelection ?? []
                                        if selected.contains(path) { selected.remove(path) }
                                        else { selected.insert(path) }
                                        app.libraryBatchSelection = selected.isEmpty ? nil : selected
                                    } else if var selected = app.libraryBatchSelection {
                                        if selected.contains(path) { selected.remove(path) }
                                        else { selected.insert(path) }
                                        app.libraryBatchSelection = selected
                                    } else {
                                        app.selection = path
                                    }
                                } label: {
                                    HStack(spacing: 9) {
                                        if let batch {
                                            Image(systemName: batch.contains(path) ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(batch.contains(path) ? studioAccent : .secondary)
                                                .accessibilityLabel(batch.contains(path) ? "已勾選" : "未勾選")
                                        }
                                        MediaThumbnail(path: path, reloadToken: app.mediaReloadToken)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                                .font(.callout.weight(.medium)).lineLimit(1)
                                            Text(URL(fileURLWithPath: path).pathExtension.uppercased())
                                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(7)
                                        .background((batch?.contains(path) ?? (app.selection == path))
                                            ? studioAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                                .background(
                                    GeometryReader { itemGeo in
                                        Color.clear.preference(
                                            key: LibraryItemFramePreferenceKey.self,
                                            value: [path: itemGeo.frame(in: .named("kliporaGenLibrarySpace"))]
                                        )
                                    }
                                )
                                .contextMenu {
                                    let url = URL(fileURLWithPath: path)
                                    let ext = url.pathExtension.lowercased()
                                    if multitrackMediaTypes.contains(ext) {
                                        Button(isAudioMediaPath(path) ? "加入音訊軌" : "加入時間軸") {
                                            app.addToTimeline(path)
                                        }.disabled(app.busy)
                                    }
                                    if (app.takesReference && imageTypes.contains(ext)) || (app.acceptsVideoReference && movieTypes.contains(ext)) {
                                        Button("加入生成參考") { app.attachReference(url) }.disabled(app.busy)
                                    }
                                    if app.project.kind == "video", app.usesMultiFrames, imageTypes.contains(ext) {
                                        Button("加入多影格") { app.addKeyframes([url]) }
                                            .disabled(app.busy || app.orderedFrames.count >= Studio.maxKeyframes)
                                    }
                                    if let settings = app.recordedGeneration(for: path) {
                                        Button("載入原生成設定") { app.restoreGeneration(settings) }.disabled(app.busy)
                                    }
                                    Button("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                    Button("從素材庫移除") { app.removeFromLibrary([path]) }
                                }

                                if batch == nil {
                                    row.draggable(URL(fileURLWithPath: path))
                                } else {
                                    row.highPriorityGesture(
                                        DragGesture(minimumDistance: 5, coordinateSpace: .named("kliporaGenLibrarySpace"))
                                            .onChanged { value in
                                                libraryInteraction.updateMarquee(value: value, app: app)
                                            }
                                            .onEnded { _ in
                                                libraryInteraction.endMarquee(app: app)
                                            }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)

                        LibraryMarqueeBoxOverlay(rect: libraryInteraction.marqueeRect)
                    }
                    .coordinateSpace(name: "kliporaGenLibrarySpace")
                    .onPreferenceChange(LibraryItemFramePreferenceKey.self) { frames in
                        libraryInteraction.itemFrames = frames
                    }
                }
            }
            if let batch {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("已選 \(batch.count) 項").foregroundStyle(.secondary)
                        Spacer()
                        Button(batch.count == app.project.media.count && !batch.isEmpty ? "取消全選" : "全選") {
                            app.libraryBatchSelection = batch.count == app.project.media.count
                                ? [] : Set(app.project.media)
                        }.disabled(app.project.media.isEmpty)
                    }
                    Button("移除所選項目") { app.removeFromLibrary(batch) }
                        .disabled(batch.isEmpty)
                        .help("只從此專案的素材庫移除，保留磁碟上的檔案")
                }.controlSize(.small).font(.caption).padding(12)
            } else if !app.selection.isEmpty {
                Divider()
                let ext = URL(fileURLWithPath: app.selection).pathExtension.lowercased()
                VStack(spacing: 8) {
                    if imageTypes.contains(ext) {
                        Button("用這張圖生成本機影片") { app.prepareLocalVideo(from: app.selection) }
                            .disabled(app.busy)
                    }
                    Button("加入時間軸") { app.addToTimeline(app.selection) }
                        .disabled(!multitrackMediaTypes.contains(ext))
                }.padding(12)
            }
        }
        .frame(maxHeight: .infinity)
        .background(panel)
        .overlay { LibraryDropHighlightOverlay(isTargeted: libraryInteraction.isDropTargeted) }
        .dropDestination(for: URL.self) { urls, _ in
            libraryInteraction.isDropTargeted = false
            return app.importDroppedMediaURLs(urls, selectingIn: .generate)
        } isTargeted: { targeted in
            libraryInteraction.isDropTargeted = targeted
        }
    }

    func bridgeBanner(_ bridge: BridgeShot) -> some View {
        let insertIndex = app.bridgeInsertionIndex(for: bridge)
        let activeConfig = app.isBridgeConfigurationActive(for: bridge)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("補鏡頭插入點", systemImage: "plus.viewfinder")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(studioAccent)
                Spacer()
                Button("套用影格") { app.applyBridgeFrames() }
                    .controlSize(.mini)
                    .disabled(app.busy)
                Button("清除") { app.clearBridgeShot() }
                    .controlSize(.mini)
                    .disabled(app.busy)
            }
            if let insertIndex {
                Text(String(format: "插入至第 %02d 與 %02d 段之間（%@ → %@）",
                            insertIndex, insertIndex + 1, bridge.afterName, bridge.beforeName))
                    .font(.caption)
                if activeConfig {
                    Text(app.source == "colab"
                         ? "Colab 首尾影格：使用前段尾幀與後段首幀"
                         : "本機 Wan 2.2：只取前段尾幀作為首幀")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("目前生成表單已變更參考影格或模式，送出將視為一般影片（點「套用影格」可恢復補鏡頭設定）。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("原綁定片段（\(bridge.afterName) → \(bridge.beforeName)）已刪除、重排或修改裁切。成品僅保留於素材庫，請回剪輯頁重新選擇補鏡頭位置。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("回剪輯頁重新選擇") {
                    app.clearBridgeShot()
                    app.workspace = .edit
                }
                .controlSize(.small)
                .disabled(app.busy)
            }
            if let video = bridge.generatedVideo, FileManager.default.fileExists(atPath: video) {
                Divider()
                HStack(spacing: 8) {
                    MediaThumbnail(path: video, width: 42, height: 32)
                    Text(filename(video))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("預覽成品") { app.generateSelection = video }
                        .controlSize(.small)
                    Button("插入時間軸") { app.insertBridgeShot() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(app.busy || insertIndex == nil)
                }
            }
        }
        .padding(10)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(studioAccent.opacity(0.28)))
    }

    var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Label("生成", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("只用本機", isOn: Binding(
                    get: { app.project.localOnly == true },
                    set: {
                        app.project.localOnly = $0
                        if app.bridgeShot != nil { app.applyBridgeFrames() }
                    }
                )).toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .help("開啟後，生成任務只使用你的本機 ComfyUI。此開關不會啟動 ComfyUI。")
            }.padding(.horizontal, 14).frame(height: 48)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let bridge = app.bridgeShot {
                        bridgeBanner(bridge)
                    }
                    generationSettings
                    if app.project.kind != "motion" && app.source == "zimage" {
                        if app.isRemovedModelSelected {
                            RemovedModelBanner(app: app)
                        } else {
                            LocalModelProfilePanel(app: app)
                        }
                    }
                    if app.project.kind == "image" {
                        if app.takesReference {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.stack")
                                    .foregroundStyle(studioAccent)
                                Text(app.supportsMultiImageReference
                                     ? "多參考素材（角色三視圖／場景／物品，最多 8 張）請於中央下方參考素材板編輯。"
                                     : "圖片參考素材請於中央下方參考素材板編輯（與專案同步）。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                            if app.showVLMDraftCard {
                                VLMPromptDraftCard(app: app)
                            }
                        } else if app.source != "colab" && !app.isRemovedModelSelected {
                            kreaUnsupportedOptionsNotice
                        }
                    } else if app.project.kind == "video" {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.bottomthird.inset.filled")
                                .foregroundStyle(studioAccent)
                            Text("影片首幀／參考／首尾／多影格請於中央下方序列區編輯（與專案同步）。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                        if app.showVLMDraftCard {
                            VLMPromptDraftCard(app: app)
                        }
                    }
                    if !app.usesFirstLastFrames {
                        promptEditor(app.project.kind == "motion" ? "動態圖形需求" : "畫面與動作", placeholder: "請在這裡輸入提示詞")
                    }
                    if !app.generateSelection.isEmpty {
                        RecordedGenerationSummaryCard(app: app, assetPath: app.generateSelection)
                    }
                    if app.project.kind != "motion" {
                        Divider()
                        DisclosureGroup("風格、鏡頭與 Seed") {
                            refinementSettings.padding(.top, 9)
                        }
                        DisclosureGroup("動態片頭") {
                            motionTitles.padding(.top, 9)
                        }
                    }
                }.padding(14)
            }
            Divider()
            if app.usesMultiFrames && app.orderedFrames.count >= 3 {
                Text("\(app.multiTransitions.count) 段 · 目標 \(app.generationSeconds) 秒 · \(app.project.resolution) · \(app.cloudGPU)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 9)
            }
            Button { app.generate() } label: {
                Label(app.busy ? "處理中…" : (app.project.kind == "motion" ? "生成動態圖形" : "生成\(app.project.kind == "video" ? "影片" : "圖片")"),
                      systemImage: "sparkles")
                    .fontWeight(.semibold).frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .tint(StudioTheme.coral).foregroundStyle(StudioTheme.cream)
                .disabled(
                    app.busy
                        || (app.project.kind != "motion" && onlineGenerationUnavailable)
                        || app.project.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (app.project.kind != "motion" && app.source != "colab" && app.isRemovedModelSelected)
                        || (app.project.kind == "video" && app.videoMethodUnsupportedReason != nil)
                        || (app.project.kind != "motion" && app.source != "colab" && app.hasUnsupportedLocalCapabilityIssue != nil)
                )
                .padding(12)
        }.background(panel)
    }

    private var mografyMotionSettings: some View {
        let mgr = MografySkillManager.shared
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Agent 引擎", selection: Binding(
                get: { mgr.effectiveAgent },
                set: { mgr.selectedAgent = $0 }
            )) {
                ForEach(mgr.availableAgents) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Picker("比例", selection: $app.project.aspect) {
                Text("16:9").tag("16:9")
                Text("9:16").tag("9:16")
                Text("1:1").tag("1:1")
            }
            Stepper("目標片長：\(max(3, min(30, app.project.seconds))) 秒", value: Binding(
                get: { max(3, min(30, app.project.seconds)) },
                set: { app.project.seconds = $0 }
            ), in: 3...30)
            MografyAttachmentsSection(disabled: app.busy)
            Text("透過 \(mgr.effectiveAgent.displayName) 搭配 Mografy Skill 撰寫並渲染 MP4，完成後自動匯入左側素材庫。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    var generationSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.project.kind != "motion" {
                Picker("來源", selection: Binding(get: { app.source }, set: app.selectSource)) {
                    Text("本機 · ComfyUI").tag("zimage")
                    if app.project.localOnly != true {
                        if app.project.kind == "image" {
                            Text(NetworkReachabilityMonitor.shared.isOffline ? "線上 · OpenAI（離線停用）" : "線上 · OpenAI（圖片）").tag("openai_image")
                            Text(NetworkReachabilityMonitor.shared.isOffline ? "線上 · Gemini（離線停用）" : "線上 · Gemini（圖片）").tag("gemini_image")
                        }
                        Text(NetworkReachabilityMonitor.shared.isOffline ? "線上 · Google Colab（離線停用）" : "線上 · Google Colab").tag("colab")
                    }
                }
            }
            Picker("輸出", selection: $app.project.kind) {
                Text("圖片").tag("image")
                Text("影片").tag("video")
                if mografySkill.isUnlocked {
                    Text("動態圖形").tag("motion")
                }
            }.pickerStyle(.segmented)
            if app.project.kind == "motion" {
                mografyMotionSettings
            } else {
                outputSettings
            }
            if app.project.kind == "motion" {
                EmptyView()
            } else if let onlineProvider = OnlineImageProvider(rawValue: app.source) {
                OnlineImageControls(provider: onlineProvider)
            } else if app.source == "colab" {
                HStack {
                    Picker("GPU", selection: Binding(get: { app.cloudGPU }, set: { app.project.cloudGPU = $0 })) {
                        Text("L4").tag("L4")
                        Text("G4").tag("G4")
                    }
                    Button("檢查 Colab") { app.perform(["action": "check_colab"], "檢查 Colab") }
                        .disabled(app.busy || NetworkReachabilityMonitor.shared.isOffline)
                }
                if NetworkReachabilityMonitor.shared.isOffline {
                    Text("目前處於離線狀態，Google Colab 雲端功能已停用；可切換回「本機 · ComfyUI」繼續離線創作。")
                        .font(.caption).foregroundStyle(StudioTheme.warning)
                }
                if app.project.kind == "video" {
                    Picker("影片模型", selection: $app.project.model) { Text("UPD5").tag("upd5"); Text("PRISM").tag("prism") }
                    Picker("生成解析度", selection: $app.project.resolution) {
                        ForEach(["480P", "720P", "1080P"], id: \.self) { Text($0) }
                    }
                    if app.project.resolution == "1080P" {
                        Text("生成 1080P 所需運算較多，是否能完成取決於 GPU 與片長。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Picker(app.project.kind == "video" ? "本機影片模型" : "本機圖片模型",
                       selection: Binding(get: { app.localModel }, set: app.selectLocalModel)) {
                    if app.project.kind == "video" {
                        ForEach(ModelProfileStore.shared.videoModels) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    } else {
                        if let removed = app.removedModelNotice {
                            Text("\(removed.displayName)（已移除）").tag(removed.id)
                        }
                        ForEach(ModelProfileStore.shared.imageModels) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                        ForEach(CustomWorkflowRegistry.safeLoad()) { wf in
                            Text("工作流 · \(wf.displayName)").tag(wf.id)
                        }
                    }
                    Text("自訂 ComfyUI 工作流").tag("comfy")
                }
                if app.project.kind == "image" {
                    LocalModelManagerControls(app: app)
                    CustomWorkflowControls(app: app)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("ComfyUI 執行模式", selection: $app.comfyConnectionMode) {
                        Text("Klipora 託管引擎").tag("managed")
                        Text("外部 ComfyUI Desktop").tag("desktop")
                    }
                    .pickerStyle(.segmented)
                    .disabled(app.busy)

                    if app.comfyConnectionMode == "managed" {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(app.engineRunning ? StudioTheme.success : StudioTheme.textMuted.opacity(0.5))
                                    .frame(width: 7, height: 7)
                                Text(app.engineStarting ? "Klipora 託管引擎啟動中…" : (app.engineRunning ? "執行中 · \(app.endpoint)" : "未啟動（建議使用，自動套用 --fp32-vae 畫質修正）"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack(spacing: 8) {
                                Button(app.engineRunning ? "停止託管 ComfyUI" : "啟動託管 ComfyUI", action: app.toggleEngine)
                                    .disabled(app.busy)
                                Button("檢查就緒狀態") {
                                    var checkReq: [String: Any] = [
                                        "action": "check_local",
                                        "endpoint": app.endpoint,
                                        "preset": app.action,
                                        "workflow": app.selectedWorkflow,
                                        "localOnly": app.project.localOnly == true,
                                        "lora": app.unsupportedLocalLoRAInfo?.id ?? app.selectedLoRA,
                                        "reference": app.takesReference ? app.referenceImage : app.unsupportedLocalReferencePath
                                    ]
                                    if app.action != "comfy" && !app.isRemovedModelSelected {
                                        checkReq["modelParams"] = app.currentModelParamsPayload()
                                    }
                                    app.perform(checkReq, "檢查本機 ComfyUI")
                                }
                                .disabled(app.busy || app.engineStarting || !app.engineRunning)
                                .help("確認 Klipora 託管的 ComfyUI 與所選模型皆已就緒")
                            }
                        }
                        .padding(8)
                        .background(canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            if app.engineRunning {
                                Text("目前 Klipora 託管引擎正在執行；若要改連外部 ComfyUI Desktop，請先停止託管引擎。")
                                    .font(.caption)
                                    .foregroundStyle(StudioTheme.warning)
                            }
                            TextField("外部 ComfyUI 位址", text: $app.project.endpoint)
                                .disabled(app.engineRunning || app.busy)
                            HStack(spacing: 8) {
                                Button("開啟 Comfy Desktop", action: app.openComfyDesktop)
                                    .help("在 Comfy Desktop 啟動實例，再回來檢查連線")
                                Button("檢查外部連線") {
                                    var checkReq: [String: Any] = [
                                        "action": "check_local",
                                        "endpoint": app.project.endpoint,
                                        "preset": app.action,
                                        "workflow": app.selectedWorkflow,
                                        "localOnly": app.project.localOnly == true,
                                        "lora": app.unsupportedLocalLoRAInfo?.id ?? app.selectedLoRA,
                                        "reference": app.takesReference ? app.referenceImage : app.unsupportedLocalReferencePath
                                    ]
                                    if app.action != "comfy" && !app.isRemovedModelSelected {
                                        checkReq["modelParams"] = app.currentModelParamsPayload()
                                    }
                                    app.perform(checkReq, "檢查外部 ComfyUI")
                                }
                                .disabled(app.busy || app.engineStarting)
                                .help("確認外部 ComfyUI 位址已啟動且模型可用")
                            }
                        }
                        .padding(8)
                        .background(canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if app.action == "comfy" && !app.localModel.hasPrefix("workflow_") {
                    Button("選擇\(app.project.kind == "video" ? "影片" : "圖片") API 工作流") {
                        app.pickAsync(title: "選擇 ComfyUI API 工作流", types: [.json]) { urls in
                            guard let url = urls.first else { return }
                            if app.project.kind == "video" { app.project.videoWorkflow = url.path }
                            else { app.project.workflow = url.path }
                        }
                    }
                    if !app.selectedWorkflow.isEmpty {
                        Text(filename(app.selectedWorkflow)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(app.project.kind == "video"
                         ? "需有本機影片模型與 API 工作流。工作流可讀取 {{PROMPT}}、{{IMAGE}}、{{SEED}}、{{SECONDS}}。"
                         : "工作流可讀取 {{PROMPT}}、{{IMAGE}}、{{SEED}}。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if app.project.kind == "video" {
                Picker("影片方式", selection: Binding(
                    get: { app.videoMethod }, set: { app.selectVideoMethod($0) }
                )) {
                    Text("文字生成").tag("text")
                    Text(app.isBuiltinLocalVideoAction ? "首幀" : "參考素材").tag("reference")
                    if app.action == "colab" || app.videoMethod == "frames" {
                        Text(app.action == "colab" ? "首尾影格" : "首尾影格（僅線上 Colab）").tag("frames")
                    }
                    if app.action == "colab" || app.videoMethod == "multi" {
                        Text(app.action == "colab" ? "多影格（3–32 張）" : "多影格（僅線上 Colab）").tag("multi")
                    }
                }
                if !["frames", "multi"].contains(app.videoMethod) {
                    Stepper("\(app.generationSeconds) 秒", value: Binding(
                        get: { app.generationSeconds },
                        set: { app.project.seconds = $0 }
                    ), in: app.secondsRange)
                }
            }
        }
    }

    var outputSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("輸出尺寸", selection: Binding(get: { app.outputDimensions != nil }, set: { custom in
                let defaults = app.project.aspect == "9:16" ? ("720", "1280")
                    : app.project.aspect == "1:1" ? ("1024", "1024") : ("1280", "720")
                app.outputDimensions = custom
                    ? (app.outputDimensions ?? OutputDimensions(width: defaults.0, height: defaults.1)) : nil
            })) {
                Text("依比例").tag(false)
                Text("自訂寬高").tag(true)
            }
            if let dimensions = app.outputDimensions {
                HStack {
                    TextField("寬度", text: Binding(get: { app.outputDimensions?.width ?? "" }, set: {
                        app.outputDimensions?.width = $0
                    })).accessibilityLabel("輸出寬度").monospacedDigit()
                    Text("×").foregroundStyle(.secondary)
                    TextField("高度", text: Binding(get: { app.outputDimensions?.height ?? "" }, set: {
                        app.outputDimensions?.height = $0
                    })).accessibilityLabel("輸出高度").monospacedDigit()
                    Text("px").foregroundStyle(.secondary)
                }
                Text(dimensions.pixels == nil ? "寬高範圍為 64–4096 px。"
                     : app.project.kind == "video" ? "生成檔寬高須為偶數。"
                     : "模型若無法直接生成此尺寸，會縮放並置中裁切。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("比例", selection: $app.project.aspect) {
                    ForEach(["16:9", "9:16", "1:1"], id: \.self) { Text($0) }
                }
            }
            HStack {
                Button { app.openOutputDirectory(datedDirectory(under: app.generationOutputDirectory)) } label: {
                    Label(app.generationOutputDirectory.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                }.help("在 Finder 開啟 \(datedDirectory(under: app.generationOutputDirectory).path)")
                Spacer()
                Button("選擇資料夾", action: app.chooseOutputFolder)
                    .accessibilityLabel(app.project.kind == "video" ? "選擇影片儲存資料夾" : "選擇圖片儲存資料夾")
                if app.outputFolder != nil {
                    Button { app.outputFolder = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("使用工作台預設位置")
                }
            }.controlSize(.small).font(.caption)
        }.disabled(app.busy)
    }

    var generationReferences: some View {
        let images = app.referenceImages
        let video = app.acceptsVideoReference ? app.project.referenceVideo : nil
        let primaryRef = images.first ?? (video ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("參考素材").font(.callout.weight(.semibold))
                Spacer()
                if !primaryRef.isEmpty {
                    Button {
                        app.interrogateReferenceImage(path: primaryRef)
                    } label: {
                        Label("看圖產生提示詞", systemImage: "sparkles.rectangle.stack")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(studioAccent)
                    .foregroundStyle(canvas)
                    .disabled(app.busy)
                    .accessibilityLabel("看圖產生提示詞")
                    .help("使用本機 ComfyUI 的 Qwen3-VL-8B 模型分析參考圖並產生可編輯提示詞草稿（不會自動覆蓋現有稿件）")
                }
            }
            HStack(spacing: 6) {
                Button("選擇檔案") {
                    let types: [UTType] = app.acceptsVideoReference ? [.image, .movie] : [.image]
                    app.pickReferences(title: "選擇參考素材", types: types, multiple: true) { app.attachReferences($0) }
                }
                Button("選擇資料夾") {
                    app.pickReferences(title: "選擇參考素材資料夾", directory: true) { app.attachReferences($0) }
                }.help("讀取資料夾與子資料夾中的支援檔案，依檔名順序加入")
            }.controlSize(.small)
            ForEach(Array(images.enumerated()), id: \.element) { index, path in
                referenceAsset(app.action == "colab" ? "圖片 \(index + 1)" : "參考圖片", path: path) {
                    app.removeReferenceImage(path)
                }
            }
            if let video, !video.isEmpty {
                referenceAsset(app.isBuiltinLocalVideoAction ? "影片首幀" : "影片 1", path: video) {
                    app.project.referenceVideo = nil
                }
            }
            if app.showVLMDraftCard {
                VLMPromptDraftCard(app: app)
            }
            if app.action == "colab" {
                Text(app.acceptsVideoReference
                     ? "最多 8 張圖與 1 支影片。預設全用，也可以用 @圖片1、@影片1 指定。"
                     : "最多 8 張圖，第一張是要修改的圖片。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("本機一次使用一個參考。批次加入時會先選第一個支援的檔案，可從素材庫右鍵改選。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
        .disabled(app.busy)
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in app.attachReferences(urls) }
    }

    var kreaUnsupportedOptionsNotice: some View {
        let modelName = app.profileStore.displayName(for: app.action)
        let badRef = app.unsupportedLocalReferencePath
        let badLoRA = app.unsupportedLocalLoRAInfo
        return VStack(alignment: .leading, spacing: 8) {
            Text("參考素材與 LoRA").font(.callout.weight(.semibold))
            Text("\(modelName) 目前僅支援文字生圖，不支援參考圖片\(app.localModelSupportsLoRA ? "" : "與本機風格 LoRA")。")
                .font(.caption).foregroundStyle(.secondary)
            if !badRef.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("目前仍掛載一張參考圖片，需移除後才能使用 \(modelName) 生成：")
                        .font(.caption).foregroundStyle(.orange)
                    referenceAsset("未支援參考圖", path: badRef) {
                        app.project.imageReference = ""
                    }
                }
            }
            if let badLoRA {
                HStack(spacing: 8) {
                    Text("目前仍選取風格 LoRA（\(badLoRA.label)），\(modelName) 不支援。")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("清除 LoRA") { app.project.localImageLoRA = "" }
                        .controlSize(.small)
                }
            }
        }
        .padding(9)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            (!badRef.isEmpty || badLoRA != nil)
                ? Color.orange.opacity(0.45) : Color.clear
        ))
        .disabled(app.busy)
    }

    func referenceAsset(_ label: String, path: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 7) {
            MediaThumbnail(path: path, width: 34, height: 26)
            Text(label).font(.caption.weight(.medium))
            Text(filename(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "xmark") }
                .accessibilityLabel("移除\(label)")
                .help("移除這個參考項目")
        }.controlSize(.small)
    }

    var firstLastFramesPanel: some View {
        let clampedSeconds = min(15, max(2, app.project.seconds))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("首尾影格", systemImage: "rectangle.split.2x1")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("從資料夾取首尾") {
                    app.pickReferences(title: "選擇首尾影格資料夾", directory: true, receive: app.attachFirstLastFromFolder)
                }.controlSize(.small).help("依檔名順序取第一張和最後一張圖片")
                Text("首尾過渡 · \(clampedSeconds) 秒")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(studioAccent)
            }
            HStack(alignment: .top, spacing: 8) {
                frameSlot("首幀", value: $app.project.firstFrame).frame(width: 80)
                Button {
                    let first = app.project.firstFrame
                    app.project.firstFrame = app.project.lastFrame
                    app.project.lastFrame = first
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .frame(width: 22, height: 96)
                }
                .buttonStyle(.plain)
                .foregroundStyle(studioAccent)
                .disabled(app.project.firstFrame == nil && app.project.lastFrame == nil)
                .accessibilityLabel("互換首尾影格")
                .help("互換首尾影格")
                frameSlot("尾幀", value: $app.project.lastFrame).frame(width: 80)
                promptEditor("轉場描述", placeholder: "描述首幀與尾幀之間的動作及運鏡。")
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity)
            }
            Divider().overlay(.white.opacity(0.06))
            HStack(spacing: 8) {
                Text("目標片長")
                    .font(.caption.weight(.medium))
                Spacer()
                TextField("目標片長", value: Binding(
                    get: { clampedSeconds },
                    set: { app.project.seconds = min(15, max(2, $0)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .monospacedDigit()
                .accessibilityLabel("目標片長")
                Text("秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("目標片長", value: Binding(
                    get: { clampedSeconds },
                    set: { app.project.seconds = min(15, max(2, $0)) }
                ), in: 2...15)
                .labelsHidden()
                .controlSize(.small)
                Text("2–15 秒")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.07)))
        .disabled(app.busy)
    }

    var multiKeyframesPanel: some View {
        let count = app.orderedFrames.count
        let transitions = app.multiTransitions
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("多影格", systemImage: "rectangle.on.rectangle")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(count)/\(Studio.maxKeyframes) 張")
                    .foregroundStyle(.secondary)
                if !transitions.isEmpty {
                    Text("· \(transitions.count) 段 · 共 \(app.generationSeconds) 秒")
                        .foregroundStyle(studioAccent)
                }
                if count < Studio.maxKeyframes {
                    Button("加入資料夾") {
                        app.pickReferences(title: "選擇影格資料夾", directory: true) { app.addKeyframes($0) }
                    }.controlSize(.small).disabled(app.busy)
                        .help("依檔名順序加入圖片，最多 8 張影格")
                }
            }
            .font(.caption.monospacedDigit())
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(Array(app.orderedFrames.enumerated()), id: \.offset) { index, path in
                        multiKeyframeTile(index, path: path, total: count)
                        if index < transitions.count {
                            TransitionTile(index: index, transition: transitions[index], app: app)
                                .id([path, app.orderedFrames[index + 1]])
                        }
                    }
                    if count < Studio.maxKeyframes {
                        Button {
                            app.pickReferences(title: "依順序加入影格", types: [.image], multiple: true) { urls in
                                app.addKeyframes(urls)
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "plus").font(.title3)
                                Text(count == 0 ? "加入影格" : "影格 \(count + 1)").font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .frame(width: 76, height: 96)
                            .background(canvas, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("加入影格")
                        .disabled(app.busy)
                    }
                    if count == 0 {
                        Text("選擇或拖入 3–\(Studio.maxKeyframes) 張圖片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 9)
            }
            .frame(height: 105)
            if count > 0 {
                Text(count < 3 ? "再加入 \(3 - count) 張圖片即可生成。" : "點 T 設定描述和秒數。右鍵影格可調整順序。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07)))
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in app.addKeyframes(urls) }
    }

    func multiKeyframeTile(_ index: Int, path: String, total: Int) -> some View {
        Button { app.generateSelection = path } label: {
            MediaThumbnail(path: path, width: 76, height: 96)
                .overlay(alignment: .bottomLeading) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(5)
                }
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(app.generateSelection == path ? studioAccent : .white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("影格 \(index + 1)，\(filename(path))")
        .help(filename(path))
        .contextMenu {
            Button("向左移動") { app.moveKeyframe(index, offset: -1) }
                .disabled(app.busy || index == 0)
            Button("向右移動") { app.moveKeyframe(index, offset: 1) }
                .disabled(app.busy || index == total - 1)
            Button("移除影格", role: .destructive) { app.removeKeyframe(index) }
                .disabled(app.busy)
        }
    }

    func frameSlot(_ title: String, value: Binding<String?>) -> some View {
        let hasImage = value.wrappedValue != nil
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                app.pickReferences(title: "選擇" + title, types: [.image]) { urls in
                    app.attachFrame(urls, to: value)
                }
            } label: {
                VStack(spacing: 6) {
                    HStack {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(hasImage ? canvas : .white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(hasImage ? studioAccent : surface, in: Capsule())
                        Spacer(minLength: 0)
                        if hasImage {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let path = value.wrappedValue {
                        MediaThumbnail(path: path, width: 64, height: 54)
                        Text(filename(path))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Spacer(minLength: 4)
                        Image(systemName: "plus.viewfinder")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(studioAccent)
                        Text("加入圖片")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(hasImage ? studioAccent.opacity(0.35) : .white.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            .disabled(app.busy)
            .accessibilityLabel("選擇" + title)
            if value.wrappedValue != nil {
                Button("移除" + title) { value.wrappedValue = nil }
                    .controlSize(.mini)
                    .disabled(app.busy)
            }
        }
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            app.attachFrame(urls, to: value)
        }
    }

    var refinementSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("風格", selection: $app.project.style) { ForEach(styles, id: \.0) { Text($0.0).tag($0.0) } }
            if app.source != "colab", app.project.kind == "image", app.action != "comfy" {
                ManualLoRAControls(app: app)
            }
            Picker("鏡頭", selection: Binding(get: { app.camera }, set: { app.project.camera = $0 })) {
                ForEach(["依原稿", "固定鏡位", "細節特寫", "緩慢推近", "廣角環境"], id: \.self) { Text($0) }
            }
            Toggle("套用提示詞優化", isOn: Binding(
                get: { app.project.optimize != false },
                set: { app.project.optimize = $0 }
            ))
            TextField("Seed（留空隨機）", text: Binding(
                get: { app.project.fixedSeed ?? "" }, set: { app.project.fixedSeed = $0 }
            )).textFieldStyle(.roundedBorder)
        }
    }

    func promptEditor(_ title: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $app.project.prompt)
                    .accessibilityLabel(title)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                if app.project.prompt.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5).padding(.trailing, 14).padding(.top, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }.padding(6).frame(height: 104)
                .background(canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.09)))
            if app.project.kind != "motion" {
                HStack {
                    Button("預覽／編輯送出提示詞", action: app.previewPrompt)
                        .disabled(app.project.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if app.editedPrompt != nil { Button("還原") { app.editedPrompt = nil } }
                }
            }
        }
    }

    var motionTitles: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("輸入片頭文字", text: $app.project.title)
            Button("製作 2 秒片頭") {
                let folder = app.videoOutputDirectory
                app.perform(["action": "title", "title": app.project.title, "aspect": app.project.aspect,
                             "outputFolder": folder.path],
                            "渲染動態片頭")
            }.disabled(app.busy || app.project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("渲染 HyperFrames 專案") {
                app.pickAsync(title: "選擇 HyperFrames 專案", directory: true) { urls in
                    guard let url = urls.first else { return }
                    let folder = app.videoOutputDirectory
                    app.perform(["action": "hyperframes", "workflow": url.path, "outputFolder": folder.path],
                                "HyperFrames 渲染中")
                }
            }.disabled(app.busy)
            Text("渲染資料夾中的 index.html，完成後匯入素材庫。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Edit Workspace v2 Views

private let playheadRed = Color(red: 0.96, green: 0.34, blue: 0.36)
private let videoClipFill = Color(red: 0.165, green: 0.215, blue: 0.295)
private let videoClipAccent = Color(red: 0.45, green: 0.68, blue: 0.98)
private let stillClipFill = Color(red: 0.145, green: 0.235, blue: 0.245)
private let stillClipAccent = Color(red: 0.40, green: 0.80, blue: 0.74)

private struct EditPreviewMonitor: View {
    @ObservedObject var app: Studio
    @ObservedObject var timelineView: TimelineViewState
    @ObservedObject var playback: TimelinePlaybackController
    let layout: TimelineLayout

    private var outputAspectRatio: CGFloat {
        if let pixels = app.timelineOutput.dimensions?.pixels,
           let w = pixels["width"], let h = pixels["height"], h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        switch app.timelineOutput.aspect {
        case "9:16": return 9.0 / 16.0
        case "1:1": return 1.0
        default: return 16.0 / 9.0
        }
    }

    private var outputSpecLabel: String {
        if let pixels = app.timelineOutput.dimensions?.pixels,
           let w = pixels["width"], let h = pixels["height"] {
            return "\(w)×\(h) · 24fps"
        }
        return "\(app.timelineOutput.aspect) · 24fps"
    }

    private var fadeBlackOpacity: Double {
        guard let sample = playback.activeSample,
              let junction = sample.activeJunction,
              junction.transition?.kind == "fadeblack" else { return 1.0 }
        return min(1.0, max(0.0, abs(sample.transitionProgress * 2.0 - 1.0)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("預覽模式", selection: $timelineView.previewMode) {
                    Text("時間軸").tag(EditPreviewMode.timeline)
                    Text("素材原檔").tag(EditPreviewMode.source)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 146)
                .controlSize(.small)

                Text(outputSpecLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                if timelineView.previewMode == .timeline && layout.hasTransitions {
                    Label("轉場示意預覽 · 精準效果請按「預覽成片」", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(surface.opacity(0.8), in: Capsule())
                        .help("時間軸與播放頭已扣除轉場重疊秒數；淡黑可即時示意，交叉淡化與擦拭需點「預覽成片」渲染檢視。")
                } else if timelineView.previewMode == .source, !app.editSelection.isEmpty {
                    Text(filename(app.editSelection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            Group {
                if timelineView.previewMode == .source {
                    MediaSurface(path: app.editSelection)
                } else {
                    timelineStage
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
            .padding(.horizontal, 12)

            if timelineView.previewMode == .timeline {
                transportBar
            } else {
                HStack(spacing: 10) {
                    Text("素材原檔檢視模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !app.editSelection.isEmpty {
                        let ext = URL(fileURLWithPath: app.editSelection).pathExtension.lowercased()
                        Button("加入時間軸") { app.addToTimeline(app.editSelection) }
                            .controlSize(.small)
                            .disabled(!imageTypes.union(movieTypes).contains(ext))
                    }
                    Button("回到時間軸預覽") { timelineView.previewMode = .timeline }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            }
        }
        .background(canvas)
    }

    private var timelineStage: some View {
        ZStack {
            Color(red: 0.043, green: 0.047, blue: 0.059)
            if layout.segments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(studioAccent)
                        .frame(width: 54, height: 54)
                        .background(surface, in: RoundedRectangle(cornerRadius: 14))
                    Text("時間軸尚無片段")
                        .font(.system(size: 16, weight: .semibold))
                    Text("從左側素材庫點「加入時間軸」，或直接拖曳檔案到下方 V1 軌道。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !app.editSelection.isEmpty {
                        let ext = URL(fileURLWithPath: app.editSelection).pathExtension.lowercased()
                        if imageTypes.union(movieTypes).contains(ext) {
                            Button("加入目前所選素材 · \(filename(app.editSelection))") {
                                app.addToTimeline(app.editSelection)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(20)
            } else {
                GeometryReader { geo in
                    let fitted = fittedSize(in: geo.size, aspect: outputAspectRatio)
                    ZStack {
                        Color.black
                        if let errorText = playback.playbackError {
                            VStack(spacing: 10) {
                                Image(systemName: playback.playbackNeedsPermission ? "lock.doc" : "exclamationmark.triangle")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.orange)
                                Text(playback.playbackNeedsPermission ? "無法讀取素材資料夾" : "無法載入預覽畫面")
                                    .font(.headline)
                                Text(errorText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 340)
                                HStack(spacing: 8) {
                                    if playback.playbackNeedsPermission {
                                        Button("授權素材資料夾…") { app.grantMediaFolderAccess() }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                    }
                                    Button("重試讀取") { app.retryMediaLoad() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                            .padding(16)
                        } else if playback.currentVideoMissing, let sample = playback.activeSample {
                            ContentUnavailableView("找不到片段檔案", systemImage: "exclamationmark.triangle",
                                                   description: Text(filename(sample.segment.clip.path)))
                        } else if let sample = playback.activeSample, sample.segment.clip.still {
                            if let image = playback.currentStillImage {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .opacity(fadeBlackOpacity)
                            } else {
                                ContentUnavailableView("無法載入圖片", systemImage: "photo",
                                                       description: Text(filename(sample.segment.clip.path)))
                            }
                        } else {
                            TimelinePlayerLayerView(player: playback.player)
                                .opacity(fadeBlackOpacity)
                        }
                    }
                    .frame(width: max(1, fitted.width), height: max(1, fitted.height))
                    .clipped()
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .position(x: max(1, geo.size.width) / 2, y: max(1, geo.size.height) / 2)
                }
                .overlay(alignment: .top) {
                    if let sample = playback.activeSample,
                       let junction = sample.activeJunction,
                       let transition = junction.transition {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.caption2)
                            Text("\(TimelineLayout.transitionLabel(transition.kind)) \(TimelineLayout.formatTrimSeconds(transition.seconds))s")
                                .font(.caption2.weight(.medium))
                            Text(transition.kind == "fadeblack" ? "· 淡黑示意" : "· 示意（精準見預覽成片）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.76), in: Capsule())
                        .overlay(Capsule().strokeBorder(studioAccent.opacity(0.45), lineWidth: 1))
                        .padding(.top, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transportBar: some View {
        let isEmpty = layout.segments.isEmpty
        let atEnd = !isEmpty && playback.playhead >= layout.totalDuration - 0.015
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(TimelineLayout.formatTimecode(playback.playhead))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("/")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(TimelineLayout.formatTimecode(layout.totalDuration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 148, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button { playback.jumpToStart() } label: {
                    Image(systemName: "backward.end.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("跳至開頭（Home）")

                Button { playback.stepFrames(-1) } label: {
                    Image(systemName: "backward.frame.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("上一影格（←）")

                Button {
                    timelineView.previewMode = .timeline
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isEmpty ? .secondary : canvas)
                        .frame(width: 34, height: 26)
                        .background(isEmpty ? surface : studioAccent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
                .accessibilityLabel(playback.isPlaying ? "暫停" : "播放")
                .help(playback.isPlaying ? "暫停（Space）" : "播放（Space）")

                Button { playback.stepFrames(1) } label: {
                    Image(systemName: "forward.frame.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("下一影格（→）")

                Button { playback.jumpToEnd() } label: {
                    Image(systemName: "forward.end.fill").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("跳至片尾（End）")
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if let sample = playback.activeSample {
                    Text(String(format: "#%02d", sample.segment.index + 1))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(studioAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(studioAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    Text(filename(sample.segment.clip.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if atEnd {
                        Text("片尾")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(surface, in: Capsule())
                    }
                } else {
                    Text("未選取片段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 140, maxWidth: 210, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func fittedSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        let safeW = max(1, container.width - 16)
        let safeH = max(1, container.height - 16)
        let safeAspect = max(0.1, min(10.0, aspect))
        if safeW / safeH > safeAspect {
            return CGSize(width: safeH * safeAspect, height: safeH)
        } else {
            return CGSize(width: safeW, height: safeW / safeAspect)
        }
    }
}

@MainActor private final class EditInspectorDrafts: ObservableObject {
    @Published var startDraft = ""
    @Published var endDraft = ""
    @Published var transitionSecondsDraft = "0.5"
}

private struct EditInspectorView: View {
    private enum InspectorField: Hashable {
        case start
        case end
        case transitionSeconds
        case outputWidth
        case outputHeight
    }

    @ObservedObject var app: Studio
    @ObservedObject var timelineView: TimelineViewState
    @ObservedObject var playback: TimelinePlaybackController
    let layout: TimelineLayout
    let onSplit: () -> Void
    let onDeleteSelected: () -> Void

    @StateObject private var drafts = EditInspectorDrafts()
    @FocusState private var focusedField: InspectorField?

    private var selectedSegment: TimelineSegment? {
        guard let id = timelineView.selectedClip else { return nil }
        return layout.segments.first { $0.id == id }
    }

    private var activeJunction: TimelineJunction? {
        if let junctionID = timelineView.selectedJunction,
           let direct = layout.junctions.first(where: { $0.afterID == junctionID }) {
            return direct
        }
        if let seg = selectedSegment {
            if let outgoing = layout.junctions.first(where: { $0.afterID == seg.id }) {
                return outgoing
            }
            if let incoming = layout.junctions.first(where: { $0.beforeID == seg.id }) {
                return incoming
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("屬性面板", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let seg = selectedSegment {
                    Text(String(format: "#%02d / %02d", seg.index + 1, layout.segments.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let junction = activeJunction, timelineView.selectedJunction != nil {
                        junctionCard(junction, highlighted: true)
                    }

                    if let seg = selectedSegment {
                        clipPropertiesCard(seg)
                    } else if layout.segments.isEmpty {
                        emptyInspectorCard
                    } else {
                        Text("點選時間軸片段或接縫標記以調整屬性。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let junction = activeJunction, timelineView.selectedJunction == nil {
                        junctionCard(junction, highlighted: false)
                    } else if layout.segments.count == 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("接縫轉場與補鏡頭")
                                .font(.caption.weight(.semibold))
                            Text("加入第二段片段後，即可在接縫處設定硬切、交叉淡化、淡黑、向左擦拭或補鏡頭。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }

                    outputAndExportCard
                }
                .padding(12)
            }
        }
        .background(panel)
        .onAppear {
            syncClipDrafts()
            syncJunctionDraft()
        }
        .onChange(of: selectedSegment) { _, _ in
            if focusedField != .start && focusedField != .end {
                syncClipDrafts()
            }
        }
        .onChange(of: timelineView.selectedClip) { _, _ in
            syncClipDrafts()
        }
        .onChange(of: activeJunction) { _, _ in
            if focusedField != .transitionSeconds {
                syncJunctionDraft()
            }
        }
        .onChange(of: focusedField) { oldField, newField in
            if (oldField == .start || oldField == .end) && newField != .start && newField != .end {
                commitClipDrafts()
            }
            if oldField == .transitionSeconds && newField != .transitionSeconds {
                commitTransitionSecondsDraft()
            }
        }
    }

    private var emptyInspectorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("尚未加入片段")
                .font(.callout.weight(.semibold))
            Text("從左側素材庫加入影片或圖片後，可於此調整入出點、時長、排序、轉場與成片輸出尺寸。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func clipPropertiesCard(_ seg: TimelineSegment) -> some View {
        let clip = seg.clip
        let splitStatus = layout.splitCandidate(at: playback.playhead, preferredClipID: seg.id)
        let canSplit: Bool = {
            if case .success = splitStatus { return true }
            return false
        }()
        let playheadInsideClip = playback.playhead > seg.timelineStart + 0.05 && playback.playhead < seg.timelineEnd - 0.05
        let playheadSourceSec = seg.sourceStart + (playback.playhead - seg.timelineStart)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MediaThumbnail(path: clip.path, width: 44, height: 32, reloadToken: app.mediaReloadToken)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename(clip.path))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .help(clip.path)
                    HStack(spacing: 6) {
                        Text(clip.still ? "靜態圖片" : "影片片段")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(clip.still ? stillClipAccent : videoClipAccent)
                        if let srcDur = seg.sourceDuration {
                            Text(String(format: "· 來源 %.2fs", srcDur))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(.white.opacity(0.08))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("片段時長").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.2f 秒", seg.duration))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(studioAccent)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("時間軸區間").font(.caption2).foregroundStyle(.secondary)
                    Text("\(TimelineLayout.formatTimecode(seg.timelineStart)) – \(TimelineLayout.formatTimecode(seg.timelineEnd))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if clip.still {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("停留時長")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .leading)
                        TextField("3", text: $drafts.endDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .monospacedDigit()
                            .focused($focusedField, equals: .end)
                            .onSubmit { commitClipDrafts() }
                        Text("秒").font(.caption).foregroundStyle(.secondary)
                        Stepper("停留時長", value: Binding(
                            get: { seg.duration },
                            set: { app.setClipTrimNumeric(id: seg.id, start: nil, end: $0) }
                        ), in: 0.1...300, step: 0.5)
                        .labelsHidden()
                        .controlSize(.small)
                        .disabled(app.busy)
                    }
                    Text("靜態圖片不具影片入出點，直接以停留秒數控制片長；分割後兩段皆維持圖片時長語意。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("入點")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        TextField("0", text: $drafts.startDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .monospacedDigit()
                            .focused($focusedField, equals: .start)
                            .onSubmit { commitClipDrafts() }
                        Text("秒").font(.caption2).foregroundStyle(.secondary)
                        Stepper("入點", value: Binding(
                            get: { seg.sourceStart },
                            set: { app.setClipTrimNumeric(id: seg.id, start: $0, end: nil) }
                        ), in: 0...max(0.1, seg.sourceEnd - 0.1), step: 0.1)
                        .labelsHidden()
                        .controlSize(.small)
                        .disabled(app.busy)
                        Button("設為播放頭") {
                            app.setClipTrimNumeric(id: seg.id, start: playheadSourceSec, end: nil)
                        }
                        .controlSize(.mini)
                        .disabled(app.busy || !playheadInsideClip || playheadSourceSec >= seg.sourceEnd - 0.1)
                        .help("將入點裁切至目前播放頭位置")
                    }

                    HStack(spacing: 6) {
                        Text("出點")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        TextField(seg.sourceDuration.map { TimelineLayout.formatTrimSeconds($0) } ?? "結尾", text: $drafts.endDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .monospacedDigit()
                            .focused($focusedField, equals: .end)
                            .onSubmit { commitClipDrafts() }
                        Text("秒").font(.caption2).foregroundStyle(.secondary)
                        Stepper("出點", value: Binding(
                            get: { seg.sourceEnd },
                            set: { app.setClipTrimNumeric(id: seg.id, start: nil, end: $0) }
                        ), in: (seg.sourceStart + 0.1)...max(seg.sourceStart + 0.1, seg.sourceDuration ?? 3600), step: 0.1)
                        .labelsHidden()
                        .controlSize(.small)
                        .disabled(app.busy)
                        Button("設為播放頭") {
                            app.setClipTrimNumeric(id: seg.id, start: nil, end: playheadSourceSec)
                        }
                        .controlSize(.mini)
                        .disabled(app.busy || !playheadInsideClip || playheadSourceSec <= seg.sourceStart + 0.1)
                        .help("將出點裁切至目前播放頭位置")
                    }

                    if let loadError = seg.loadError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(loadError)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            HStack(spacing: 6) {
                                Button("授權素材資料夾…") { app.grantMediaFolderAccess() }
                                    .controlSize(.mini)
                                Button("重試讀取") { app.retryMediaLoad() }
                                    .controlSize(.mini)
                            }
                        }
                    } else if !seg.isTrimValid {
                        Text("入出點超出有效來源範圍，請重新調整或點「重設裁切」。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 6) {
                Button("重設裁切") {
                    app.resetClipTrim(id: seg.id)
                    syncClipDrafts()
                }
                .controlSize(.small)
                .disabled(app.busy || (clip.start.isEmpty && clip.end.isEmpty))

                Spacer()

                Button {
                    app.move(seg.index, -1)
                } label: {
                    Label("左移", systemImage: "arrow.left")
                }
                .controlSize(.small)
                .disabled(app.busy || seg.index == 0)

                Button {
                    app.move(seg.index, 1)
                } label: {
                    Label("右移", systemImage: "arrow.right")
                }
                .controlSize(.small)
                .disabled(app.busy || seg.index + 1 >= layout.segments.count)
            }

            Divider().overlay(.white.opacity(0.08))

            HStack(spacing: 8) {
                Button {
                    onSplit()
                } label: {
                    Label("播放頭分割", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(app.busy || !canSplit)
                .help(canSplit ? "在目前播放頭位置分割此片段（快捷鍵 S）" : "將播放頭移至片段內且避開轉場重疊區即可分割")

                Button(role: .destructive) {
                    onDeleteSelected()
                } label: {
                    Label("刪除", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(app.busy)
                .help("刪除此片段並自動向左接合（快捷鍵 Delete）")
            }
        }
        .padding(10)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
    }

    private func junctionCard(_ junction: TimelineJunction, highlighted: Bool) -> some View {
        let leading = layout.segments[junction.index]
        let trailing = layout.segments[junction.index + 1]
        let activeKind = junction.transition?.kind ?? "cut"
        let isCut = junction.isCut
        let currentSeconds = junction.transition?.seconds ?? 0.5
        let sameBridge = app.bridgeShot?.afterID == junction.afterID && app.bridgeShot?.beforeID == junction.beforeID
        let bridgeValid = app.bridgeShot.map { app.bridgeInsertionIndex(for: $0) != nil } ?? false

        let hasBothAdjacentJunctions: Bool = {
            guard let seg = selectedSegment else { return false }
            return seg.index > 0 && seg.index + 1 < layout.segments.count
        }()

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("第 \(junction.index + 1) → \(junction.index + 2) 段接縫", systemImage: "rectangle.on.rectangle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(highlighted ? studioAccent : .white)
                Spacer(minLength: 4)
                if hasBothAdjacentJunctions, let seg = selectedSegment {
                    let isShowingIncoming = junction.beforeID == seg.id
                    Button(isShowingIncoming ? "切到後接縫" : "切到前接縫") {
                        let targetIdx = isShowingIncoming ? seg.index : seg.index - 1
                        if layout.junctions.indices.contains(targetIdx) {
                            timelineView.selectedJunction = layout.junctions[targetIdx].afterID
                        }
                    }
                    .controlSize(.mini)
                }
            }

            Text("\(filename(leading.clip.path)) → \(filename(trailing.clip.path))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Picker("轉場效果", selection: Binding(
                get: { isCut ? "cut" : activeKind },
                set: { newKind in
                    if newKind == "cut" {
                        app.setTimelineTransition(after: junction.afterID, before: junction.beforeID, kind: "cut", seconds: 0)
                    } else {
                        app.setTimelineTransition(after: junction.afterID, before: junction.beforeID, kind: newKind, seconds: currentSeconds)
                    }
                }
            )) {
                Text("硬切（無轉場）").tag("cut")
                Text("交叉淡化（Dissolve）").tag("dissolve")
                Text("淡黑（Fade Black）").tag("fadeblack")
                Text("向左擦拭（Wipe Left）").tag("wipeleft")
            }
            .controlSize(.small)
            .disabled(app.busy)

            HStack(spacing: 6) {
                Text("轉場秒數")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0.5", text: $drafts.transitionSecondsDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 54)
                    .monospacedDigit()
                    .focused($focusedField, equals: .transitionSeconds)
                    .onSubmit { commitTransitionSecondsDraft() }
                    .disabled(app.busy || isCut)
                Text("秒").font(.caption2).foregroundStyle(.secondary)
                Stepper("轉場秒數", value: Binding(
                    get: { currentSeconds },
                    set: { newVal in
                        let clamped = (min(3.0, max(0.1, newVal)) * 100).rounded() / 100
                        app.setTimelineTransition(after: junction.afterID, before: junction.beforeID, kind: activeKind, seconds: clamped)
                    }
                ), in: 0.1...3.0, step: 0.1)
                .labelsHidden()
                .controlSize(.small)
                .disabled(app.busy || isCut)
                Spacer(minLength: 0)
            }

            if !isCut {
                if !junction.isValid {
                    Text("轉場秒數過長：相鄰片段需比轉場更長且容納前後重疊，請縮短轉場秒數。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text(String(format: "重疊區間：%@ – %@（扣除 %.2fs）",
                                TimelineLayout.formatTimecode(junction.overlapStart),
                                TimelineLayout.formatTimecode(junction.overlapEnd),
                                junction.overlapDuration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider().overlay(.white.opacity(0.08))

            HStack(spacing: 8) {
                Button {
                    app.startBridgeShot(after: junction.afterID, before: junction.beforeID)
                } label: {
                    Label("接縫補鏡頭", systemImage: "plus.viewfinder")
                }
                .controlSize(.small)
                .disabled(app.busy)
                .help("擷取前段尾幀與後段首幀，切換至生成頁生成過渡鏡頭")

                if sameBridge {
                    Text(bridgeValid ? "已綁定補鏡頭" : "補鏡頭需重選")
                        .font(.caption2)
                        .foregroundStyle(bridgeValid ? studioAccent : .orange)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            !junction.isValid ? Color.orange.opacity(0.6) : (highlighted ? studioAccent.opacity(0.6) : .white.opacity(0.08)),
            lineWidth: highlighted || !junction.isValid ? 1.2 : 1
        ))
    }

    private var outputAndExportCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("預覽與匯出設定")
                .font(.callout.weight(.semibold))

            HStack(spacing: 6) {
                Text("成片比例")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("成片比例", selection: Binding(
                    get: { app.timelineOutput.dimensions == nil ? app.timelineOutput.aspect : "custom" },
                    set: { pick in
                        if pick == "custom" {
                            let size = app.timelineOutput.aspect == "9:16" ? ("1080", "1920")
                                : app.timelineOutput.aspect == "1:1" ? ("1080", "1080") : ("1920", "1080")
                            if app.timelineOutput.dimensions == nil {
                                app.timelineOutput.dimensions = OutputDimensions(width: size.0, height: size.1)
                            }
                        } else {
                            app.timelineOutput = TimelineOutput(aspect: pick)
                        }
                    }
                )) {
                    ForEach(["16:9", "9:16", "1:1"], id: \.self) { Text($0) }
                    Text("自訂").tag("custom")
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 94)
            }

            if app.timelineOutput.dimensions != nil {
                HStack(spacing: 6) {
                    Text("像素尺寸").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("寬", text: Binding(
                        get: { app.timelineOutput.dimensions?.width ?? "" },
                        set: { app.timelineOutput.dimensions?.width = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 58)
                    .monospacedDigit()
                    .focused($focusedField, equals: .outputWidth)
                    Text("×").font(.caption)
                    TextField("高", text: Binding(
                        get: { app.timelineOutput.dimensions?.height ?? "" },
                        set: { app.timelineOutput.dimensions?.height = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 58)
                    .monospacedDigit()
                    .focused($focusedField, equals: .outputHeight)
                    Text("px").font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("\(layout.segments.count) 段 · 共 \(TimelineLayout.formatTimecode(layout.totalDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if layout.totalOverlapDeducted > 0 {
                    Text(String(format: "轉場 -%.2fs", layout.totalOverlapDeducted))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(studioAccent)
                }
            }

            if layout.hasInvalidTransitions {
                Text("有轉場超過相鄰片段長度，修正後才能正常預覽或匯出。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("預覽成片", action: app.previewTimeline)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .disabled(app.busy || layout.segments.isEmpty || layout.hasInvalidTransitions)
                    .help("透過 ffmpeg 依目前裁切與轉場渲染低解析度成片預覽")

                Button { app.export() } label: {
                    Label("匯出 MP4", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(studioAccent)
                .foregroundStyle(canvas)
                .disabled(app.busy || layout.segments.isEmpty || layout.hasInvalidTransitions)
            }
        }
        .padding(10)
        .background(surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
    }

    private func syncClipDrafts() {
        guard let seg = selectedSegment else {
            drafts.startDraft = ""
            drafts.endDraft = ""
            return
        }
        drafts.startDraft = seg.clip.start
        drafts.endDraft = seg.clip.end
    }

    private func commitClipDrafts() {
        guard let seg = selectedSegment else { return }
        app.updateClipTrimText(id: seg.id, startText: drafts.startDraft, endText: drafts.endDraft)
        syncClipDrafts()
    }

    private func syncJunctionDraft() {
        guard let junction = activeJunction else {
            drafts.transitionSecondsDraft = "0.5"
            return
        }
        drafts.transitionSecondsDraft = TimelineLayout.formatTrimSeconds(junction.transition?.seconds ?? 0.5)
    }

    private func commitTransitionSecondsDraft() {
        guard let junction = activeJunction, !junction.isCut,
              let kind = junction.transition?.kind else { return }
        if let parsed = TimelineLayout.parseSeconds(drafts.transitionSecondsDraft) {
            let clamped = (min(3.0, max(0.1, parsed)) * 100).rounded() / 100
            app.setTimelineTransition(after: junction.afterID, before: junction.beforeID, kind: kind, seconds: clamped)
            drafts.transitionSecondsDraft = TimelineLayout.formatTrimSeconds(clamped)
        } else {
            syncJunctionDraft()
        }
    }
}

private struct TimelineDockView: View {
    @ObservedObject var app: Studio
    @ObservedObject var timelineView: TimelineViewState
    @ObservedObject var playback: TimelinePlaybackController
    let layout: TimelineLayout
    let onSplit: () -> Void
    let onDeleteSelected: () -> Void
    let onDeleteAtIndex: (Int) -> Void

    private let trackHeaderWidth: CGFloat = 68
    private let rulerHeight: CGFloat = 26
    private let trackHeight: CGFloat = 78

    private var splitEligibility: Result<TimelineSplitCandidate, TimelineSplitFailure> {
        layout.splitCandidate(at: playback.playhead, preferredClipID: timelineView.selectedClip)
    }

    private var canSplit: Bool {
        if case .success = splitEligibility { return true }
        return false
    }

    private var splitTooltip: String {
        switch splitEligibility {
        case .success: return "在目前播放頭位置分割片段（快捷鍵 S）"
        case .failure(let reason): return reason.message
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                trackHeaderColumn
                Divider()
                scrollableTimeCanvas
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(panel)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                onSplit()
            } label: {
                Label("分割", systemImage: "scissors")
            }
            .controlSize(.small)
            .disabled(app.busy || !canSplit)
            .help(splitTooltip)

            Button {
                onDeleteSelected()
            } label: {
                Label("刪除", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(app.busy || timelineView.selectedClip == nil)
            .help("刪除選中片段並自動接合（快捷鍵 Delete）")

            Divider().frame(height: 16)

            Text("\(layout.segments.count) 段 · \(TimelineLayout.formatTimecode(layout.totalDuration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if layout.totalOverlapDeducted > 0 {
                Text(String(format: "含轉場重疊 -%.2fs", layout.totalOverlapDeducted))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(studioAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(studioAccent.opacity(0.12), in: Capsule())
            }

            if let hint = timelineView.trimPreviewHint {
                Text(hint)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(canvas)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(studioAccent, in: Capsule())
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button { timelineView.zoomOut() } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("縮小時間軸（-）")

                Slider(
                    value: $timelineView.pixelsPerSecond,
                    in: TimelineViewState.minZoom...TimelineViewState.maxZoom
                )
                .frame(width: 112)
                .controlSize(.small)
                .help("調整時間軸縮放比例")

                Button { timelineView.zoomIn() } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("放大時間軸（+）")

                Button("適合全部") {
                    timelineView.fit(totalDuration: layout.totalDuration)
                }
                .controlSize(.small)
                .disabled(layout.segments.isEmpty)
                .help("自動縮放以完整檢視整條時間軸（快捷鍵 0）")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(panel)
    }

    private var trackHeaderColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("24fps")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: trackHeaderWidth, height: rulerHeight)
            .background(canvas.opacity(0.65))
            Divider()
            VStack(spacing: 3) {
                Text("V1")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(studioAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(studioAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                Text("主軌道")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: trackHeaderWidth, height: trackHeight)
            .background(panel)
            Spacer(minLength: 0)
        }
        .frame(width: trackHeaderWidth)
        .background(panel)
    }

    private var scrollableTimeCanvas: some View {
        GeometryReader { geo in
            let pxPerSec = timelineView.pixelsPerSecond
            let displaySeconds = max(layout.totalDuration, 6.0)
            let contentWidth = max(geo.size.width, CGFloat(displaySeconds) * pxPerSec + 96)

            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        TimelineRulerView(
                            contentWidth: contentWidth,
                            pixelsPerSecond: pxPerSec,
                            totalDuration: layout.totalDuration,
                            onScrub: { targetTime, finished in
                                timelineView.previewMode = .timeline
                                playback.pause()
                                playback.seek(to: targetTime, exact: finished)
                            }
                        )
                        .frame(width: contentWidth, height: rulerHeight)

                        Divider()

                        trackLane(contentWidth: contentWidth, pixelsPerSecond: pxPerSec)
                            .frame(width: contentWidth, height: trackHeight)
                    }

                    if !layout.segments.isEmpty {
                        TimelinePlayheadNeedle(
                            x: CGFloat(playback.playhead) * pxPerSec,
                            rulerHeight: rulerHeight,
                            totalHeight: rulerHeight + trackHeight + 1
                        )
                    }
                }
                .frame(width: contentWidth, height: rulerHeight + trackHeight + 1, alignment: .topLeading)
                .coordinateSpace(name: "timelineTrack")
            }
            .background(canvas.opacity(0.85))
            .onAppear { timelineView.viewportWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, newWidth in
                timelineView.viewportWidth = newWidth
            }
        }
    }

    private func trackLane(contentWidth: CGFloat, pixelsPerSecond: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Canvas { context, size in
                let step = TimelineRulerView.majorStep(for: pixelsPerSecond)
                let maxSec = Double(size.width / pixelsPerSecond)
                var t = 0.0
                while t <= maxSec {
                    let x = CGFloat(t) * pixelsPerSecond
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.white.opacity(0.04)), lineWidth: 1)
                    t += step
                }
            }

            if layout.segments.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .foregroundStyle(.secondary)
                    Text("從左側素材庫點「加入時間軸」或拖曳影片／圖片到此 V1 軌道")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 24)
            } else {
                // 1. Clips positioned strictly at their true time-scale visual coordinates.
                ForEach(layout.segments) { segment in
                    let clipX = CGFloat(segment.visualStart) * pixelsPerSecond
                    let clipWidth = max(4, CGFloat(segment.visualDuration) * pixelsPerSecond)
                    TimelineClipBlock(
                        app: app,
                        timelineView: timelineView,
                        playback: playback,
                        segment: segment,
                        width: clipWidth,
                        pixelsPerSecond: pixelsPerSecond,
                        totalClips: layout.segments.count,
                        onSplit: onSplit,
                        onDelete: { onDeleteAtIndex(segment.index) }
                    )
                    .offset(x: clipX)
                }

                // 2. Transition overlap shading bands showing exact overlap duration on time ruler.
                ForEach(layout.junctions.filter { !$0.isCut }) { junction in
                    let startX = CGFloat(junction.overlapStart) * pixelsPerSecond
                    let spanW = max(3, CGFloat(junction.overlapDuration) * pixelsPerSecond)
                    let isSelected = timelineView.selectedJunction == junction.afterID
                    RoundedRectangle(cornerRadius: 3)
                        .fill((junction.isValid ? studioAccent : Color.orange).opacity(isSelected ? 0.28 : 0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder((junction.isValid ? studioAccent : Color.orange).opacity(0.7), lineWidth: 1)
                        )
                        .frame(width: spanW, height: 60)
                        .offset(x: startX)
                        .allowsHitTesting(false)
                }

                // 3. Compact seam transition markers centered strictly on seamTime (0pt added width).
                ForEach(layout.junctions) { junction in
                    seamMarker(junction: junction, pixelsPerSecond: pixelsPerSecond)
                }
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            app.addURLsToTimeline(urls)
        }
    }

    private func seamMarker(junction: TimelineJunction, pixelsPerSecond: CGFloat) -> some View {
        let x = CGFloat(junction.seamTime) * pixelsPerSecond
        let isSelected = timelineView.selectedJunction == junction.afterID
        let isHovered = timelineView.hoveredJunction == junction.afterID
        let isCut = junction.isCut
        let sameBridge = app.bridgeShot?.afterID == junction.afterID && app.bridgeShot?.beforeID == junction.beforeID
        let accent: Color = !junction.isValid ? .orange : (isSelected || !isCut || sameBridge ? studioAccent : .secondary)
        let label = isCut
            ? "第 \(junction.index + 1) 與 \(junction.index + 2) 段接縫（硬切）· 點擊設定轉場或補鏡頭"
            : "\(TimelineLayout.transitionLabel(junction.transition?.kind ?? "")) \(TimelineLayout.formatTrimSeconds(junction.transition?.seconds ?? 0.5))s"

        return Button {
            timelineView.selectedJunction = junction.afterID
        } label: {
            ZStack {
                if !isCut || isSelected || isHovered || sameBridge {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? accent : panel.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(accent.opacity(isCut ? 0.55 : 0.9), lineWidth: 1)
                        )
                        .frame(width: 20, height: 22)
                    Image(systemName: isCut ? "plus" : "rectangle.on.rectangle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? canvas : accent)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.24))
                        .frame(width: 3, height: 24)
                }
            }
            .frame(width: 22, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { timelineView.hoveredJunction = junction.afterID }
            else if timelineView.hoveredJunction == junction.afterID { timelineView.hoveredJunction = nil }
        }
        .offset(x: x - 11)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct TimelineRulerView: View {
    let contentWidth: CGFloat
    let pixelsPerSecond: CGFloat
    let totalDuration: Double
    let onScrub: (Double, Bool) -> Void

    static func majorStep(for pxPerSec: CGFloat) -> Double {
        if pxPerSec >= 110 { return 1.0 }
        if pxPerSec >= 52 { return 1.0 }
        if pxPerSec >= 28 { return 2.0 }
        if pxPerSec >= 16 { return 5.0 }
        return 10.0
    }

    static func minorDivisions(for pxPerSec: CGFloat) -> Int {
        if pxPerSec >= 110 { return 5 }
        if pxPerSec >= 52 { return 2 }
        if pxPerSec >= 28 { return 4 }
        return 5
    }

    private func formatTick(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        let mins = rounded / 60
        let secs = rounded % 60
        return mins > 0 ? String(format: "%d:%02d", mins, secs) : "\(secs)s"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.088, green: 0.095, blue: 0.115)
            Canvas { context, size in
                let major = Self.majorStep(for: pixelsPerSecond)
                let minors = Self.minorDivisions(for: pixelsPerSecond)
                let minorStep = major / Double(minors)
                let maxSec = Double(size.width / pixelsPerSecond)

                var idx = 0
                while true {
                    let t = Double(idx) * minorStep
                    if t > maxSec + 0.001 { break }
                    let x = CGFloat(t) * pixelsPerSecond
                    let isMajor = idx % minors == 0
                    let tickH: CGFloat = isMajor ? 10 : 5
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - tickH))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(.white.opacity(isMajor ? 0.36 : 0.16)), lineWidth: 1)

                    if isMajor {
                        let label = Text(formatTick(t))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                        context.draw(label, at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                    }
                    idx += 1
                }

                if totalDuration > 0 {
                    let endX = CGFloat(totalDuration) * pixelsPerSecond
                    var endLine = Path()
                    endLine.move(to: CGPoint(x: endX, y: 0))
                    endLine.addLine(to: CGPoint(x: endX, y: size.height))
                    context.stroke(endLine, with: .color(studioAccent.opacity(0.6)), lineWidth: 1.5)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineTrack"))
                .onChanged { value in
                    let rawSec = max(0, Double(value.location.x / pixelsPerSecond))
                    let clamped = totalDuration > 0 ? min(totalDuration, rawSec) : 0
                    onScrub(clamped, false)
                }
                .onEnded { value in
                    let rawSec = max(0, Double(value.location.x / pixelsPerSecond))
                    let clamped = totalDuration > 0 ? min(totalDuration, rawSec) : 0
                    onScrub(clamped, true)
                }
        )
    }
}

@MainActor private final class ClipTrimDragState: ObservableObject {
    var originStart: Double?
    var originEnd: Double?
}

private struct TimelineClipBlock: View {
    @ObservedObject var app: Studio
    @ObservedObject var timelineView: TimelineViewState
    @ObservedObject var playback: TimelinePlaybackController
    let segment: TimelineSegment
    let width: CGFloat
    let pixelsPerSecond: CGFloat
    let totalClips: Int
    let onSplit: () -> Void
    let onDelete: () -> Void

    @StateObject private var trimDrag = ClipTrimDragState()

    private var isSelected: Bool { timelineView.selectedClip == segment.id }
    private var isDropTarget: Bool { timelineView.dropTargetClip == segment.id }
    private var clip: Clip { segment.clip }
    private var accentColor: Color { clip.still ? stillClipAccent : videoClipAccent }
    private var fillColor: Color { clip.still ? stillClipFill : videoClipFill }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(segment.isTrimValid ? accentColor : Color.orange)
                    .frame(height: 3)

                HStack(spacing: 6) {
                    if width >= 72 {
                        MediaThumbnail(path: clip.path, width: 38, height: 28, reloadToken: app.mediaReloadToken)
                    }
                    if width >= 34 {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(String(format: "%02d", segment.index + 1))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(isSelected ? canvas : accentColor)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(isSelected ? studioAccent : canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                                if width >= 92 {
                                    Text(filename(clip.path))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                            }
                            if width >= 54 {
                                Text(String(format: "%.2fs%@", segment.duration, clip.still ? " · 靜態圖" : ""))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, width >= 44 ? 8 : (width >= 12 ? 2 : 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width, height: 60)
            .background(isSelected ? fillColor.opacity(1.0) : fillColor.opacity(0.84), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isDropTarget ? Color.white : (isSelected ? studioAccent : .white.opacity(0.14)),
                        lineWidth: isSelected || isDropTarget ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                timelineView.selectedClip = segment.id
                timelineView.selectedJunction = nil
                timelineView.previewMode = .timeline
                app.editSelection = clip.path
                if playback.playhead < segment.visualStart - 0.01 || playback.playhead > segment.visualEnd + 0.01 {
                    playback.pause()
                    playback.seek(to: segment.visualStart, exact: true)
                }
            }
            .draggable(segment.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                timelineView.dropTargetClip = nil
                guard let idString = items.first, let draggedID = UUID(uuidString: idString) else { return false }
                return app.reorderClip(draggedID, to: segment.index)
            } isTargeted: { targeted in
                if targeted { timelineView.dropTargetClip = segment.id }
                else if timelineView.dropTargetClip == segment.id { timelineView.dropTargetClip = nil }
            }
            .contextMenu {
                Button("在播放頭分割") { onSplit() }
                    .disabled(app.busy)
                Button("跳至片段開頭") {
                    timelineView.selectedClip = segment.id
                    timelineView.selectedJunction = nil
                    timelineView.previewMode = .timeline
                    playback.pause()
                    playback.seek(to: segment.visualStart, exact: true)
                }
                Button("重設裁切") { app.resetClipTrim(id: segment.id) }
                    .disabled(app.busy || (clip.start.isEmpty && clip.end.isEmpty))
                Divider()
                Button("往左移") { app.move(segment.index, -1) }
                    .disabled(app.busy || segment.index == 0)
                Button("往右移") { app.move(segment.index, 1) }
                    .disabled(app.busy || segment.index + 1 >= totalClips)
                Divider()
                Button("刪除片段（自動接合）", role: .destructive) { onDelete() }
                    .disabled(app.busy)
            }

            if width >= 22 && !app.busy {
                HStack(spacing: 0) {
                    if !clip.still {
                        trimHandle(isLeading: true)
                    }
                    Spacer(minLength: 0)
                    trimHandle(isLeading: false)
                }
                .frame(width: width, height: 60)
            }
        }
        .help("\(filename(clip.path)) · \(String(format: "%.2f", segment.duration)) 秒（拖曳左右邊緣可修剪，拖曳中間可重排）")
    }

    private func trimHandle(isLeading: Bool) -> some View {
        let handleWidth: CGFloat = min(9, max(5, width * 0.22))
        return Rectangle()
            .fill(isSelected ? studioAccent.opacity(0.32) : .white.opacity(0.001))
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? studioAccent : .white.opacity(0.38))
                    .frame(width: 2, height: 22)
            )
            .frame(width: handleWidth, height: 60)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("timelineTrack"))
                    .onChanged { value in
                        if trimDrag.originStart == nil {
                            trimDrag.originStart = segment.sourceStart
                            trimDrag.originEnd = segment.sourceEnd
                            timelineView.selectedClip = segment.id
                            timelineView.selectedJunction = nil
                            timelineView.previewMode = .timeline
                            playback.pause()
                        }
                        let baseStart = trimDrag.originStart ?? segment.sourceStart
                        let baseEnd = trimDrag.originEnd ?? segment.sourceEnd
                        let deltaSec = Double(value.translation.width / pixelsPerSecond)
                        if clip.still {
                            let newDur = min(300.0, max(TimelineLayout.minClipDuration, baseEnd + deltaSec))
                            app.setClipTrimNumeric(id: segment.id, start: nil, end: newDur)
                            timelineView.trimPreviewHint = String(format: "圖片停留 %.2fs", newDur)
                        } else if isLeading {
                            let newStart = min(baseEnd - TimelineLayout.minClipDuration, max(0, baseStart + deltaSec))
                            app.setClipTrimNumeric(id: segment.id, start: newStart, end: baseEnd)
                            timelineView.trimPreviewHint = String(format: "入點 %.2fs · 片長 %.2fs", newStart, baseEnd - newStart)
                            playback.seek(to: segment.visualStart, exact: false)
                        } else {
                            let maxEnd = segment.sourceDuration ?? 3600
                            let newEnd = min(maxEnd, max(baseStart + TimelineLayout.minClipDuration, baseEnd + deltaSec))
                            app.setClipTrimNumeric(id: segment.id, start: baseStart, end: newEnd)
                            timelineView.trimPreviewHint = String(format: "出點 %.2fs · 片長 %.2fs", newEnd, newEnd - baseStart)
                            playback.seek(to: max(segment.visualStart, segment.timelineStart + (newEnd - baseStart) - 0.02), exact: false)
                        }
                    }
                    .onEnded { _ in
                        trimDrag.originStart = nil
                        trimDrag.originEnd = nil
                        timelineView.trimPreviewHint = nil
                        playback.seek(to: playback.playhead, exact: true)
                    }
            )
    }
}

private struct TimelinePlayheadNeedle: View {
    let x: CGFloat
    let rulerHeight: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x - 6, y: 0))
                path.addLine(to: CGPoint(x: x + 6, y: 0))
                path.addLine(to: CGPoint(x: x + 6, y: 8))
                path.addLine(to: CGPoint(x: x, y: 14))
                path.addLine(to: CGPoint(x: x - 6, y: 8))
                path.closeSubpath()
            }
            .fill(playheadRed)

            Rectangle()
                .fill(playheadRed)
                .frame(width: 1.5, height: max(0, totalHeight - 12))
                .offset(x: x - 0.75, y: 12)
        }
        .allowsHitTesting(false)
    }
}

private final class TransitionDraft: ObservableObject {
    @Published var isPresented = false
    @Published var prompt = ""
    @Published var seconds = ""
    @Published var applyToAll = false

    var validSeconds: Int? {
        guard let value = Int(seconds.trimmingCharacters(in: .whitespacesAndNewlines)),
              (2...15).contains(value) else { return nil }
        return value
    }

    func open(_ transition: FrameTransition) {
        prompt = transition.prompt
        seconds = String(transition.seconds)
        applyToAll = false
        isPresented = true
    }
}

private struct TransitionTile: View {
    private enum Field: Hashable {
        case prompt
        case seconds
    }

    let index: Int
    let transition: FrameTransition
    @ObservedObject var app: Studio
    @StateObject private var draft = TransitionDraft()
    @FocusState private var focusedField: Field?

    var body: some View {
        let hasPrompt = !transition.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button { draft.open(transition) } label: {
            VStack(spacing: 7) {
                Text("T").font(.system(.title3, design: .monospaced).weight(.semibold))
                Text("\(transition.seconds) 秒").font(.caption.monospacedDigit())
            }
            .foregroundStyle(hasPrompt || draft.isPresented ? studioAccent : .white.opacity(0.75))
            .frame(width: 52, height: 76)
            .background(panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(hasPrompt || draft.isPresented ? studioAccent : .white.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .disabled(app.busy)
        .accessibilityLabel("第 \(index + 1) 段過渡，\(transition.seconds) 秒")
        .help(hasPrompt ? transition.prompt : "編輯過渡描述和秒數")
        .popover(isPresented: $draft.isPresented) { editor }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .escape {
            draft.isPresented = false
            return .handled
        }
        let backTab = KeyEquivalent("\u{19}")
        guard keyPress.key == .tab || keyPress.key == backTab,
              keyPress.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        let backward = keyPress.modifiers.contains(.shift) || keyPress.key == backTab
        if focusedField == .prompt && !backward {
            focusedField = .seconds
            return .handled
        }
        if focusedField == .seconds && backward {
            focusedField = .prompt
            return .handled
        }
        return .ignored
    }

    var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("影格 \(index + 1) → \(index + 2)").font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($focusedField, equals: .prompt)
                    .accessibilityLabel("過渡描述")
                if draft.prompt.isEmpty {
                    Text("描述兩張影格之間的動作與運鏡").foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 120)
            .background(canvas, in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 8) {
                Text("片長")
                TextField("秒數", text: $draft.seconds)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 44)
                    .focused($focusedField, equals: .seconds)
                Text("秒（2–15）").foregroundStyle(draft.validSeconds == nil ? .orange : .secondary)
                Spacer()
                Toggle("套用到全部過渡段", isOn: $draft.applyToAll)
                    .toggleStyle(.checkbox)
                    .help("將這組描述和秒數套用到所有過渡段")
            }.font(.callout)
            HStack {
                Spacer()
                Button("取消") { draft.isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("確認") {
                    guard let seconds = draft.validSeconds else { return }
                    app.updateTransition(index, seconds: seconds, prompt: draft.prompt, applyToAll: draft.applyToAll)
                    draft.isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(app.busy || draft.validSeconds == nil)
            }
        }
        .padding(16)
        .frame(width: 370)
        .tint(studioAccent)
        .onAppear { focusedField = .prompt }
        .onKeyPress(phases: .down, action: handleKeyPress)
    }
}

@MainActor final class StudioDelegate: NSObject, NSApplicationDelegate {
    weak var studio: Studio?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if studio?.busy == true {
            studio?.status = "請等待工作完成後再關閉，以便正常收回成品與釋放資源。"
            return .terminateCancel
        }
        studio?.stopEngine()
        VoiceboxServiceController.shared.stopOwnedServiceIfIdle(forceOnAppQuit: true)
        return .terminateNow
    }
}

@main struct MotionDeskApp: App {
    @NSApplicationDelegateAdaptor(StudioDelegate.self) private var delegate
    @StateObject private var studio = Studio()
    var body: some Scene {
        WindowGroup("Klipora") {
            StudioView(app: studio)
                .onAppear {
                    delegate.studio = studio
                    if let i = CommandLine.arguments.firstIndex(of: "--import"), CommandLine.arguments.indices.contains(i+1) {
                        studio.importPaths([CommandLine.arguments[i+1]])
                    }
                    if let i = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.indices.contains(i+1) {
                        studio.openProject(at: URL(fileURLWithPath: CommandLine.arguments[i+1]))
                    }
                    if let i = CommandLine.arguments.firstIndex(of: "--workspace"), CommandLine.arguments.indices.contains(i+1),
                       let target = Workspace(rawValue: CommandLine.arguments[i+1]) {
                        studio.workspace = target
                    }
                }
        }.defaultSize(width: 1320, height: 790)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("關於 Klipora") {
                    NotificationCenter.default.post(name: .kliporaOpenAbout, object: nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("元件與連線設定…") {
                    NotificationCenter.default.post(name: .motionDeskOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
