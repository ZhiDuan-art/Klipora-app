import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media Types & Color Helpers

let audioTypes: Set<String> = ["mp3", "wav", "m4a", "aac", "flac"]
let multitrackMediaTypes: Set<String> = imageTypes.union(movieTypes).union(audioTypes)

func isAudioMediaPath(_ path: String) -> Bool {
    audioTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
}

func isImageMediaPath(_ path: String) -> Bool {
    imageTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
}

func isMovieMediaPath(_ path: String) -> Bool {
    movieTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
}

enum MultitrackColorHex {
    static func parseRGBA(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        if cleaned.count == 3 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned, radix: 16) else {
            return nil
        }
        if cleaned.count == 6 {
            let r = Double((value >> 16) & 0xFF) / 255.0
            let g = Double((value >> 8) & 0xFF) / 255.0
            let b = Double(value & 0xFF) / 255.0
            return (r, g, b, 1.0)
        } else {
            let r = Double((value >> 24) & 0xFF) / 255.0
            let g = Double((value >> 16) & 0xFF) / 255.0
            let b = Double((value >> 8) & 0xFF) / 255.0
            let a = Double(value & 0xFF) / 255.0
            return (r, g, b, a)
        }
    }

    static func color(from hex: String, opacity: Double = 1.0, fallback: Color = .white) -> Color {
        guard let rgba = parseRGBA(hex) else { return fallback.opacity(opacity) }
        return Color(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a * opacity)
    }

    static func nsColor(from hex: String, opacity: Double = 1.0, fallback: NSColor = .white) -> NSColor {
        guard let rgba = parseRGBA(hex) else { return fallback.withAlphaComponent(opacity) }
        return NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a * opacity)
    }

    static func hexString(from color: Color) -> String {
        hexString(from: NSColor(color))
    }

    static func hexString(from nsColor: NSColor) -> String {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 1
        var a: CGFloat = 1
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((min(1, max(0, r)) * 255).rounded())
        let gi = Int((min(1, max(0, g)) * 255).rounded())
        let bi = Int((min(1, max(0, b)) * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

// MARK: - Transition Catalog (14 Validated FFmpeg xfade Transitions)

enum TimelineTransitionKind: String, CaseIterable, Codable, Identifiable {
    case dissolve
    case fadeblack
    case fadewhite
    case wipeleft
    case wiperight
    case wipeup
    case wipedown
    case slideleft
    case slideright
    case circleopen
    case circleclose
    case pixelize
    case smoothleft
    case zoomin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dissolve: return "交叉淡化"
        case .fadeblack: return "淡入黑場"
        case .fadewhite: return "閃白過渡"
        case .wipeleft: return "向左擦拭"
        case .wiperight: return "向右擦拭"
        case .wipeup: return "向上擦拭"
        case .wipedown: return "向下擦拭"
        case .slideleft: return "向左滑入"
        case .slideright: return "向右滑入"
        case .circleopen: return "圓形展開"
        case .circleclose: return "圓形收合"
        case .pixelize: return "像素馬賽克"
        case .smoothleft: return "柔邊左推"
        case .zoomin: return "推進縮放"
        }
    }

    var symbolName: String {
        switch self {
        case .dissolve: return "rectangle.on.rectangle"
        case .fadeblack: return "circle.fill"
        case .fadewhite: return "sun.max.fill"
        case .wipeleft: return "arrow.left.to.line"
        case .wiperight: return "arrow.right.to.line"
        case .wipeup: return "arrow.up.to.line"
        case .wipedown: return "arrow.down.to.line"
        case .slideleft: return "chevron.left.2"
        case .slideright: return "chevron.right.2"
        case .circleopen: return "circle.dashed"
        case .circleclose: return "circle.inset.filled"
        case .pixelize: return "square.grid.3x3"
        case .smoothleft: return "arrow.left.circle"
        case .zoomin: return "plus.magnifyingglass"
        }
    }

    var defaultSeconds: Double { 0.5 }

    static let supportedRawValues: Set<String> = Set(allCases.map(\.rawValue))

    static func label(for kind: String) -> String {
        if kind == "cut" || kind.isEmpty { return "硬切" }
        return TimelineTransitionKind(rawValue: kind)?.displayName ?? "硬切"
    }

    static func symbol(for kind: String) -> String {
        if kind == "cut" || kind.isEmpty { return "scissors" }
        return TimelineTransitionKind(rawValue: kind)?.symbolName ?? "rectangle.on.rectangle"
    }
}

// MARK: - Filter, Animation, Audio FX & Export Catalogs

enum VideoFilterPreset: String, CaseIterable, Codable, Identifiable {
    case none
    case warm
    case cool
    case bw
    case vintage
    case vivid
    case soft
    case vignette

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "原色"
        case .warm: return "暖調膠片"
        case .cool: return "冷色電影"
        case .bw: return "高對比黑白"
        case .vintage: return "復古褪色"
        case .vivid: return "鮮豔飽和"
        case .soft: return "柔焦模糊"
        case .vignette: return "暗角暈影"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "circle.slash"
        case .warm: return "sun.horizon.fill"
        case .cool: return "snowflake"
        case .bw: return "circle.lefthalf.filled"
        case .vintage: return "camera.aperture"
        case .vivid: return "sparkles"
        case .soft: return "drop.halffull"
        case .vignette: return "circle.dashed.inset.filled"
        }
    }

    var swatchColors: [Color] {
        switch self {
        case .none: return [Color(red: 0.24, green: 0.28, blue: 0.34), Color(red: 0.16, green: 0.19, blue: 0.24)]
        case .warm: return [Color(red: 0.78, green: 0.46, blue: 0.24), Color(red: 0.34, green: 0.18, blue: 0.12)]
        case .cool: return [Color(red: 0.20, green: 0.48, blue: 0.72), Color(red: 0.10, green: 0.18, blue: 0.30)]
        case .bw: return [Color(white: 0.78), Color(white: 0.14)]
        case .vintage: return [Color(red: 0.62, green: 0.52, blue: 0.38), Color(red: 0.28, green: 0.24, blue: 0.20)]
        case .vivid: return [Color(red: 0.86, green: 0.32, blue: 0.56), Color(red: 0.22, green: 0.56, blue: 0.88)]
        case .soft: return [Color(red: 0.60, green: 0.64, blue: 0.74), Color(red: 0.34, green: 0.38, blue: 0.46)]
        case .vignette: return [Color(red: 0.38, green: 0.42, blue: 0.48), Color(red: 0.05, green: 0.05, blue: 0.07)]
        }
    }

    static func resolved(_ raw: String) -> VideoFilterPreset {
        VideoFilterPreset(rawValue: raw) ?? .none
    }
}

enum ClipAnimationKind: String, CaseIterable, Codable, Identifiable {
    case none
    case fade
    case slideLeft = "slide_left"
    case slideUp = "slide_up"
    case zoom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "無"
        case .fade: return "淡入淡出"
        case .slideLeft: return "左滑進場"
        case .slideUp: return "上浮進場"
        case .zoom: return "推進縮放"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "nosign"
        case .fade: return "circle.dotted.circle"
        case .slideLeft: return "arrow.left.square"
        case .slideUp: return "arrow.up.square"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        }
    }

    static func resolved(_ raw: String) -> ClipAnimationKind {
        ClipAnimationKind(rawValue: raw) ?? .none
    }
}

enum AudioEffectKind: String, CaseIterable, Codable, Identifiable {
    case none
    case telephone
    case robot
    case chipmunk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "原聲"
        case .telephone: return "電話"
        case .robot: return "機器人"
        case .chipmunk: return "花栗鼠"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "waveform"
        case .telephone: return "phone.fill"
        case .robot: return "cpu"
        case .chipmunk: return "hare.fill"
        }
    }

    static func resolved(_ raw: String) -> AudioEffectKind {
        AudioEffectKind(rawValue: raw) ?? .none
    }
}

enum TimelineExportCodec: String, CaseIterable, Identifiable {
    case h264 = "h264"
    case hevc = "hevc"
    case h264Hardware = "h264_videotoolbox"
    case hevcHardware = "hevc_videotoolbox"
    case av1 = "av1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264 (CPU)"
        case .hevc: return "HEVC (CPU)"
        case .h264Hardware: return "H.264 硬體"
        case .hevcHardware: return "HEVC 硬體"
        case .av1: return "AV1 (SVT-AV1)"
        }
    }

    var supports10Bit: Bool {
        self == .hevc || self == .hevcHardware || self == .av1
    }
}

// MARK: - V4 Pro Models: Keyframes, Speed Ramp, Blend Modes, Masks, Editable Shapes

enum KeyframeEasing: String, CaseIterable, Codable, Equatable, Hashable, Identifiable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "線性"
        case .easeIn: return "緩入"
        case .easeOut: return "緩出"
        case .easeInOut: return "緩入緩出"
        }
    }

    func apply(_ p: Double) -> Double {
        let clamped = min(1.0, max(0.0, p))
        switch self {
        case .linear: return clamped
        case .easeIn: return clamped * clamped
        case .easeOut: return 1.0 - (1.0 - clamped) * (1.0 - clamped)
        case .easeInOut: return clamped * clamped * (3.0 - 2.0 * clamped)
        }
    }
}

enum KeyframeProperty: String, CaseIterable, Codable, Equatable, Hashable, Identifiable {
    case posX
    case posY
    case scale
    case rotation
    case opacity
    case volume

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .posX: return "水平位置 X"
        case .posY: return "垂直位置 Y"
        case .scale: return "縮放"
        case .rotation: return "旋轉角度"
        case .opacity: return "不透明度"
        case .volume: return "音量"
        }
    }
}

struct ClipKeyframe: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var property: String
    var time: Double
    var value: Double
    var easing: String

    init(
        id: UUID = UUID(),
        property: String,
        time: Double,
        value: Double,
        easing: String = KeyframeEasing.easeInOut.rawValue
    ) {
        self.id = id
        self.property = property
        self.time = max(0, time)
        self.value = value
        self.easing = easing
    }

    func toDict() -> [String: Any] {
        [
            "id": id.uuidString,
            "property": property,
            "time": MultitrackLayout.roundTime(time),
            "value": value,
            "easing": easing
        ]
    }
}

enum KeyframeEvaluator {
    static func evaluate(
        keyframes: [ClipKeyframe],
        property: KeyframeProperty,
        localTime: Double,
        fallback: Double
    ) -> Double {
        let matching = keyframes
            .filter { $0.property == property.rawValue }
            .sorted { $0.time < $1.time }
        guard !matching.isEmpty else { return fallback }
        if matching.count == 1 { return matching[0].value }
        let t = max(0, localTime)
        if t <= matching[0].time { return matching[0].value }
        if t >= matching[matching.count - 1].time { return matching[matching.count - 1].value }
        for idx in 0..<(matching.count - 1) {
            let a = matching[idx]
            let b = matching[idx + 1]
            if t >= a.time && t <= b.time {
                let span = max(0.0001, b.time - a.time)
                let p = (t - a.time) / span
                let ease = KeyframeEasing(rawValue: a.easing) ?? .linear
                let eased = ease.apply(p)
                return a.value + (b.value - a.value) * eased
            }
        }
        return fallback
    }
}

struct SpeedRampPoint: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var progress: Double
    var speed: Double

    init(id: UUID = UUID(), progress: Double, speed: Double) {
        self.id = id
        self.progress = min(1.0, max(0.0, progress))
        self.speed = min(4.0, max(0.25, speed))
    }

    func toDict() -> [String: Any] {
        [
            "progress": (progress * 1000).rounded() / 1000,
            "speed": (speed * 100).rounded() / 100
        ]
    }
}

struct SpeedRampPreset: Identifiable {
    let id: String
    let name: String
    let description: String
    let points: [SpeedRampPoint]

    static let presets: [SpeedRampPreset] = [
        SpeedRampPreset(id: "none", name: "關閉曲線", description: "回歸恆定速度", points: []),
        SpeedRampPreset(id: "montage", name: "蒙太奇快慢", description: "前段加速 → 中段慢動作 → 尾段回速", points: [
            SpeedRampPoint(progress: 0.0, speed: 2.0),
            SpeedRampPoint(progress: 0.35, speed: 0.5),
            SpeedRampPoint(progress: 0.70, speed: 0.6),
            SpeedRampPoint(progress: 1.0, speed: 1.8)
        ]),
        SpeedRampPreset(id: "hero_slow", name: "高光慢鏡", description: "正常進場 → 中央 0.4x 慢鏡 → 正常退場", points: [
            SpeedRampPoint(progress: 0.0, speed: 1.2),
            SpeedRampPoint(progress: 0.30, speed: 0.4),
            SpeedRampPoint(progress: 0.70, speed: 0.4),
            SpeedRampPoint(progress: 1.0, speed: 1.2)
        ]),
        SpeedRampPreset(id: "flash_in", name: "疾速切入", description: "3x 切入後漸慢至 1x", points: [
            SpeedRampPoint(progress: 0.0, speed: 3.0),
            SpeedRampPoint(progress: 0.30, speed: 1.0),
            SpeedRampPoint(progress: 1.0, speed: 1.0)
        ]),
        SpeedRampPreset(id: "flash_out", name: "疾速抽離", description: "1x 穩定後尾段加速至 3x", points: [
            SpeedRampPoint(progress: 0.0, speed: 1.0),
            SpeedRampPoint(progress: 0.70, speed: 1.0),
            SpeedRampPoint(progress: 1.0, speed: 3.0)
        ])
    ]
}

enum VideoBlendMode: String, CaseIterable, Codable, Identifiable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case addition
    case difference

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "正常"
        case .multiply: return "色彩增值"
        case .screen: return "濾色"
        case .overlay: return "覆蓋"
        case .darken: return "變暗"
        case .lighten: return "變亮"
        case .addition: return "線性加亮"
        case .difference: return "差異化"
        }
    }

    var swiftUIBlendMode: BlendMode {
        switch self {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        case .addition: return .plusLighter
        case .difference: return .difference
        }
    }

    static func resolved(_ raw: String) -> VideoBlendMode {
        VideoBlendMode(rawValue: raw) ?? .normal
    }
}

enum VideoMaskKind: String, CaseIterable, Codable, Identifiable {
    case none
    case rect
    case ellipse
    case linearFade = "linear_fade"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "無遮罩"
        case .rect: return "矩形遮罩"
        case .ellipse: return "圓形／橢圓遮罩"
        case .linearFade: return "線性漸層遮罩"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "rectangle.dashed"
        case .rect: return "rectangle.inset.filled"
        case .ellipse: return "circle.inset.filled"
        case .linearFade: return "rectangle.lefthalf.inset.filled"
        }
    }

    static func resolved(_ raw: String) -> VideoMaskKind {
        VideoMaskKind(rawValue: raw) ?? .none
    }
}

enum ShapeKind: String, CaseIterable, Codable, Identifiable {
    case rect
    case roundedRect = "rounded_rect"
    case ellipse
    case triangle
    case star
    case arrow
    case pill
    case line

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rect: return "矩形"
        case .roundedRect: return "圓角框"
        case .ellipse: return "圓形／橢圓"
        case .triangle: return "三角形"
        case .star: return "五角星"
        case .arrow: return "指示箭頭"
        case .pill: return "膠囊標籤"
        case .line: return "分隔線"
        }
    }

    var symbolName: String {
        switch self {
        case .rect: return "rectangle.fill"
        case .roundedRect: return "app.fill"
        case .ellipse: return "circle.fill"
        case .triangle: return "triangle.fill"
        case .star: return "star.fill"
        case .arrow: return "arrow.right.circle.fill"
        case .pill: return "capsule.fill"
        case .line: return "minus"
        }
    }

    static func resolved(_ raw: String) -> ShapeKind {
        ShapeKind(rawValue: raw) ?? .roundedRect
    }
}

struct ShapeClip: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: String
    var timelineStart: Double
    var duration: Double
    var posX: Double
    var posY: Double
    var width: Double
    var height: Double
    var rotation: Double
    var opacity: Double
    var fillColorHex: String
    var fillGradientEnabled: Bool
    var fillGradientEndHex: String
    var fillGradientAngle: Double
    var strokeColorHex: String
    var strokeWidth: Double
    var cornerRadius: Double
    var shadowEnabled: Bool
    var label: String
    var labelColorHex: String
    var labelFontSize: Double

    init(
        id: UUID = UUID(),
        kind: String = ShapeKind.roundedRect.rawValue,
        timelineStart: Double = 0,
        duration: Double = 3.0,
        posX: Double = 0.5,
        posY: Double = 0.5,
        width: Double = 0.28,
        height: Double = 0.16,
        rotation: Double = 0,
        opacity: Double = 0.92,
        fillColorHex: String = "#0EA5E9",
        fillGradientEnabled: Bool = true,
        fillGradientEndHex: String = "#6366F1",
        fillGradientAngle: Double = 45,
        strokeColorHex: String = "#FFFFFF",
        strokeWidth: Double = 3.0,
        cornerRadius: Double = 0.22,
        shadowEnabled: Bool = true,
        label: String = "",
        labelColorHex: String = "#FFFFFF",
        labelFontSize: Double = 32
    ) {
        self.id = id
        self.kind = kind
        self.timelineStart = timelineStart
        self.duration = duration
        self.posX = posX
        self.posY = posY
        self.width = width
        self.height = height
        self.rotation = rotation
        self.opacity = opacity
        self.fillColorHex = fillColorHex
        self.fillGradientEnabled = fillGradientEnabled
        self.fillGradientEndHex = fillGradientEndHex
        self.fillGradientAngle = fillGradientAngle
        self.strokeColorHex = strokeColorHex
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.shadowEnabled = shadowEnabled
        self.label = label
        self.labelColorHex = labelColorHex
        self.labelFontSize = labelFontSize
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, timelineStart, duration, posX, posY, width, height, rotation, opacity
        case fillColorHex, fillGradientEnabled, fillGradientEndHex, fillGradientAngle
        case strokeColorHex, strokeWidth, cornerRadius, shadowEnabled
        case label, labelColorHex, labelFontSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ShapeKind.roundedRect.rawValue
        timelineStart = try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3.0
        posX = try c.decodeIfPresent(Double.self, forKey: .posX) ?? 0.5
        posY = try c.decodeIfPresent(Double.self, forKey: .posY) ?? 0.5
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.28
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.16
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.92
        fillColorHex = try c.decodeIfPresent(String.self, forKey: .fillColorHex) ?? "#0EA5E9"
        fillGradientEnabled = try c.decodeIfPresent(Bool.self, forKey: .fillGradientEnabled) ?? true
        fillGradientEndHex = try c.decodeIfPresent(String.self, forKey: .fillGradientEndHex) ?? "#6366F1"
        fillGradientAngle = try c.decodeIfPresent(Double.self, forKey: .fillGradientAngle) ?? 45
        strokeColorHex = try c.decodeIfPresent(String.self, forKey: .strokeColorHex) ?? "#FFFFFF"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 3.0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0.22
        shadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        labelColorHex = try c.decodeIfPresent(String.self, forKey: .labelColorHex) ?? "#FFFFFF"
        labelFontSize = try c.decodeIfPresent(Double.self, forKey: .labelFontSize) ?? 32
    }
}

struct ShapeTrack: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var hidden: Bool
    var locked: Bool
    var clips: [ShapeClip]

    init(
        id: UUID = UUID(),
        name: String = "S1 形狀",
        hidden: Bool = false,
        locked: Bool = false,
        clips: [ShapeClip] = []
    ) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.locked = locked
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hidden, locked, clips
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "S1 形狀"
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        clips = try c.decodeIfPresent([ShapeClip].self, forKey: .clips) ?? []
    }
}

struct ShapeSegmentLayout: Equatable, Identifiable {
    let id: UUID
    let trackID: UUID
    let trackIndex: Int
    let clip: ShapeClip
    let timelineStart: Double
    let timelineEnd: Double
    let duration: Double
}

struct ShapeTrackLayout: Equatable, Identifiable {
    var id: UUID { track.id }
    let trackIndex: Int
    let track: ShapeTrack
    let segments: [ShapeSegmentLayout]
    let endTime: Double
}

struct TextStylePreset: Identifiable {
    let id: String
    let name: String
    let sampleText: String
    let fontFamily: String
    let fontSize: Double
    let textColorHex: String
    let strokeColorHex: String
    let strokeWidth: Double
    let shadowEnabled: Bool
    let backgroundEnabled: Bool
    let backgroundColorHex: String
    let backgroundOpacity: Double
    let posX: Double
    let posY: Double

    func makeClip(at startTime: Double) -> TextClip {
        TextClip(
            text: sampleText,
            timelineStart: MultitrackLayout.roundTime(max(0, startTime)),
            duration: 3.0,
            fontFamily: fontFamily,
            fontSize: fontSize,
            textColorHex: textColorHex,
            strokeColorHex: strokeColorHex,
            strokeWidth: strokeWidth,
            shadowEnabled: shadowEnabled,
            backgroundEnabled: backgroundEnabled,
            backgroundColorHex: backgroundColorHex,
            backgroundOpacity: backgroundOpacity,
            posX: posX,
            posY: posY
        )
    }

    static let presets: [TextStylePreset] = [
        TextStylePreset(
            id: "standard_sub",
            name: "標準底字幕",
            sampleText: "標準繁中底字幕",
            fontFamily: "PingFang TC",
            fontSize: 44,
            textColorHex: "#FFFFFF",
            strokeColorHex: "#000000",
            strokeWidth: 3.0,
            shadowEnabled: true,
            backgroundEnabled: true,
            backgroundColorHex: "#000000",
            backgroundOpacity: 0.55,
            posX: 0.5,
            posY: 0.86
        ),
        TextStylePreset(
            id: "cinema_bilingual",
            name: "電影雙語白字",
            sampleText: "電影敘事對白\nCinema Subtitle",
            fontFamily: "Songti TC",
            fontSize: 36,
            textColorHex: "#F5F3EE",
            strokeColorHex: "#101010",
            strokeWidth: 1.5,
            shadowEnabled: true,
            backgroundEnabled: false,
            backgroundColorHex: "#000000",
            backgroundOpacity: 0.0,
            posX: 0.5,
            posY: 0.88
        ),
        TextStylePreset(
            id: "variety_yellow",
            name: "綜藝黃字黑邊",
            sampleText: "重點爆笑字卡！",
            fontFamily: "Heiti TC",
            fontSize: 56,
            textColorHex: "#FFE033",
            strokeColorHex: "#000000",
            strokeWidth: 6.0,
            shadowEnabled: true,
            backgroundEnabled: false,
            backgroundColorHex: "#000000",
            backgroundOpacity: 0.0,
            posX: 0.5,
            posY: 0.80
        ),
        TextStylePreset(
            id: "news_banner",
            name: "新聞標題條",
            sampleText: "即時快訊｜焦點新聞標題",
            fontFamily: "PingFang TC",
            fontSize: 38,
            textColorHex: "#FFFFFF",
            strokeColorHex: "#000000",
            strokeWidth: 0.0,
            shadowEnabled: false,
            backgroundEnabled: true,
            backgroundColorHex: "#B81D24",
            backgroundOpacity: 0.90,
            posX: 0.5,
            posY: 0.14
        ),
        TextStylePreset(
            id: "minimal_center",
            name: "極簡置中大字",
            sampleText: "章節標題",
            fontFamily: "PingFang TC",
            fontSize: 76,
            textColorHex: "#FFFFFF",
            strokeColorHex: "#000000",
            strokeWidth: 1.2,
            shadowEnabled: true,
            backgroundEnabled: false,
            backgroundColorHex: "#000000",
            backgroundOpacity: 0.0,
            posX: 0.5,
            posY: 0.50
        ),
        TextStylePreset(
            id: "corner_note",
            name: "左上角註記",
            sampleText: "台北 · 2026",
            fontFamily: "PingFang TC",
            fontSize: 28,
            textColorHex: "#C8E6FF",
            strokeColorHex: "#000000",
            strokeWidth: 1.5,
            shadowEnabled: false,
            backgroundEnabled: true,
            backgroundColorHex: "#0E1624",
            backgroundOpacity: 0.72,
            posX: 0.20,
            posY: 0.12
        )
    ]
}

// MARK: - Multitrack Codable Data Models

enum TrackKind: String, Codable, Equatable, Hashable {
    case video
    case audio
    case text
    case shape
}

enum TimelineSelection: Equatable, Hashable {
    case videoClip(trackID: UUID, clipID: UUID)
    case audioClip(trackID: UUID, clipID: UUID)
    case textClip(trackID: UUID, clipID: UUID)
    case shapeClip(trackID: UUID, clipID: UUID)
    case transition(trackID: UUID, afterID: UUID, beforeID: UUID)

    var trackID: UUID {
        switch self {
        case .videoClip(let trackID, _),
             .audioClip(let trackID, _),
             .textClip(let trackID, _),
             .shapeClip(let trackID, _),
             .transition(let trackID, _, _):
            return trackID
        }
    }

    var clipID: UUID? {
        switch self {
        case .videoClip(_, let clipID),
             .audioClip(_, let clipID),
             .textClip(_, let clipID),
             .shapeClip(_, let clipID):
            return clipID
        case .transition:
            return nil
        }
    }
}

struct VideoClip: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var timelineStart: Double
    var start: String
    var end: String
    var posX: Double
    var posY: Double
    var scale: Double
    var opacity: Double
    var volume: Double
    var muted: Bool

    // Geometry
    var rotation: Double
    var flipH: Bool
    var flipV: Bool
    var cropTop: Double
    var cropBottom: Double
    var cropLeft: Double
    var cropRight: Double

    // Speed & FX
    var speed: Double
    var reversed: Bool
    var freezeFrame: Bool

    // Filter & Chroma Key
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

    // Entry / Exit Animation
    var animationIn: String
    var animationOut: String
    var animationDuration: Double

    // Audio Processing
    var voiceCleanup: Bool
    var audioEffect: String

    // V4 Pro Effects, Blend, Masks, Stabilize, Enhance, Keyframes, Speed Ramp, Proxy
    var effectId: String
    var blendMode: String
    var maskKind: String
    var maskFeather: Double
    var maskInvert: Bool
    var stabilizeEnabled: Bool
    var stabilizeStrength: Double
    var enhanceClarity: Double
    var keyframes: [ClipKeyframe]
    var speedCurve: [SpeedRampPoint]
    var proxyPath: String?

    var still: Bool {
        imageTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    init(
        id: UUID = UUID(),
        path: String,
        timelineStart: Double = 0,
        start: String = "",
        end: String = "",
        posX: Double = 0,
        posY: Double = 0,
        scale: Double = 1.0,
        opacity: Double = 1.0,
        volume: Double = 1.0,
        muted: Bool = false,
        rotation: Double = 0,
        flipH: Bool = false,
        flipV: Bool = false,
        cropTop: Double = 0,
        cropBottom: Double = 0,
        cropLeft: Double = 0,
        cropRight: Double = 0,
        speed: Double = 1.0,
        reversed: Bool = false,
        freezeFrame: Bool = false,
        filterPreset: String = "none",
        brightness: Double = 0,
        contrast: Double = 1.0,
        saturation: Double = 1.0,
        blur: Double = 0,
        vignette: Bool = false,
        chromaKeyEnabled: Bool = false,
        chromaKeyColor: String = "#00FF00",
        chromaKeySimilarity: Double = 0.18,
        chromaKeyBlend: Double = 0.08,
        animationIn: String = "none",
        animationOut: String = "none",
        animationDuration: Double = 0.4,
        voiceCleanup: Bool = false,
        audioEffect: String = "none",
        effectId: String = "none",
        blendMode: String = "normal",
        maskKind: String = "none",
        maskFeather: Double = 0.08,
        maskInvert: Bool = false,
        stabilizeEnabled: Bool = false,
        stabilizeStrength: Double = 0.5,
        enhanceClarity: Double = 0.0,
        keyframes: [ClipKeyframe] = [],
        speedCurve: [SpeedRampPoint] = [],
        proxyPath: String? = nil
    ) {
        self.id = id
        self.path = path
        self.timelineStart = timelineStart
        self.start = start
        self.end = end
        self.posX = posX
        self.posY = posY
        self.scale = scale
        self.opacity = opacity
        self.volume = volume
        self.muted = muted
        self.rotation = rotation
        self.flipH = flipH
        self.flipV = flipV
        self.cropTop = cropTop
        self.cropBottom = cropBottom
        self.cropLeft = cropLeft
        self.cropRight = cropRight
        self.speed = speed
        self.reversed = reversed
        self.freezeFrame = freezeFrame
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
        self.animationIn = animationIn
        self.animationOut = animationOut
        self.animationDuration = animationDuration
        self.voiceCleanup = voiceCleanup
        self.audioEffect = audioEffect
        self.effectId = effectId
        self.blendMode = blendMode
        self.maskKind = maskKind
        self.maskFeather = maskFeather
        self.maskInvert = maskInvert
        self.stabilizeEnabled = stabilizeEnabled
        self.stabilizeStrength = stabilizeStrength
        self.enhanceClarity = enhanceClarity
        self.keyframes = keyframes
        self.speedCurve = speedCurve
        self.proxyPath = proxyPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, timelineStart, start, end, posX, posY, scale, opacity, volume, muted
        case rotation, flipH, flipV, cropTop, cropBottom, cropLeft, cropRight
        case speed, reversed, freezeFrame
        case filterPreset, brightness, contrast, saturation, blur, vignette
        case chromaKeyEnabled, chromaKeyColor, chromaKeySimilarity, chromaKeyBlend
        case animationIn, animationOut, animationDuration
        case voiceCleanup, audioEffect
        case effectId, blendMode, maskKind, maskFeather, maskInvert
        case stabilizeEnabled, stabilizeStrength, enhanceClarity
        case keyframes, speedCurve, proxyPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        timelineStart = try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0
        start = try c.decodeIfPresent(String.self, forKey: .start) ?? ""
        end = try c.decodeIfPresent(String.self, forKey: .end) ?? ""
        posX = try c.decodeIfPresent(Double.self, forKey: .posX) ?? 0
        posY = try c.decodeIfPresent(Double.self, forKey: .posY) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false

        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try c.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        cropTop = try c.decodeIfPresent(Double.self, forKey: .cropTop) ?? 0
        cropBottom = try c.decodeIfPresent(Double.self, forKey: .cropBottom) ?? 0
        cropLeft = try c.decodeIfPresent(Double.self, forKey: .cropLeft) ?? 0
        cropRight = try c.decodeIfPresent(Double.self, forKey: .cropRight) ?? 0

        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        freezeFrame = try c.decodeIfPresent(Bool.self, forKey: .freezeFrame) ?? false

        filterPreset = try c.decodeIfPresent(String.self, forKey: .filterPreset) ?? "none"
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        vignette = try c.decodeIfPresent(Bool.self, forKey: .vignette) ?? false
        chromaKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .chromaKeyEnabled) ?? false
        chromaKeyColor = try c.decodeIfPresent(String.self, forKey: .chromaKeyColor) ?? "#00FF00"
        chromaKeySimilarity = try c.decodeIfPresent(Double.self, forKey: .chromaKeySimilarity) ?? 0.18
        chromaKeyBlend = try c.decodeIfPresent(Double.self, forKey: .chromaKeyBlend) ?? 0.08

        animationIn = try c.decodeIfPresent(String.self, forKey: .animationIn) ?? "none"
        animationOut = try c.decodeIfPresent(String.self, forKey: .animationOut) ?? "none"
        animationDuration = try c.decodeIfPresent(Double.self, forKey: .animationDuration) ?? 0.4

        voiceCleanup = try c.decodeIfPresent(Bool.self, forKey: .voiceCleanup) ?? false
        audioEffect = try c.decodeIfPresent(String.self, forKey: .audioEffect) ?? "none"

        effectId = try c.decodeIfPresent(String.self, forKey: .effectId) ?? "none"
        blendMode = try c.decodeIfPresent(String.self, forKey: .blendMode) ?? "normal"
        maskKind = try c.decodeIfPresent(String.self, forKey: .maskKind) ?? "none"
        maskFeather = try c.decodeIfPresent(Double.self, forKey: .maskFeather) ?? 0.08
        maskInvert = try c.decodeIfPresent(Bool.self, forKey: .maskInvert) ?? false
        stabilizeEnabled = try c.decodeIfPresent(Bool.self, forKey: .stabilizeEnabled) ?? false
        stabilizeStrength = try c.decodeIfPresent(Double.self, forKey: .stabilizeStrength) ?? 0.5
        enhanceClarity = try c.decodeIfPresent(Double.self, forKey: .enhanceClarity) ?? 0.0
        keyframes = try c.decodeIfPresent([ClipKeyframe].self, forKey: .keyframes) ?? []
        speedCurve = try c.decodeIfPresent([SpeedRampPoint].self, forKey: .speedCurve) ?? []
        proxyPath = try c.decodeIfPresent(String.self, forKey: .proxyPath)
    }

    func cachePayloadDict(
        sourceStart: Double? = nil,
        sourceEnd: Double? = nil,
        duration: Double? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "path": path,
            "still": still,
            "start": still ? "" : start.trimmingCharacters(in: .whitespacesAndNewlines),
            "end": end.trimmingCharacters(in: .whitespacesAndNewlines),
            "speed": speed,
            "reversed": reversed,
            "freezeFrame": freezeFrame,
            "flipH": flipH,
            "flipV": flipV,
            "rotation": rotation,
            "cropTop": cropTop,
            "cropBottom": cropBottom,
            "cropLeft": cropLeft,
            "cropRight": cropRight,
            "filterPreset": filterPreset,
            "brightness": brightness,
            "contrast": contrast,
            "saturation": saturation,
            "blur": blur,
            "vignette": vignette,
            "chromaKeyEnabled": chromaKeyEnabled,
            "chromaKeyColor": chromaKeyColor,
            "chromaKeySimilarity": chromaKeySimilarity,
            "chromaKeyBlend": chromaKeyBlend,
            "effectId": effectId,
            "blendMode": blendMode,
            "maskKind": maskKind,
            "maskFeather": maskFeather,
            "maskInvert": maskInvert,
            "stabilizeEnabled": stabilizeEnabled,
            "stabilizeStrength": stabilizeStrength,
            "enhanceClarity": enhanceClarity,
            "speedCurve": speedCurve.map { $0.toDict() },
            "posX": posX,
            "posY": posY,
            "scale": scale,
            "opacity": opacity
        ]
        if let sourceStart {
            dict["sourceStart"] = MultitrackLayout.roundTime(sourceStart)
        }
        if let sourceEnd {
            dict["sourceEnd"] = MultitrackLayout.roundTime(sourceEnd)
        }
        if let duration {
            dict["duration"] = MultitrackLayout.roundTime(duration)
        }
        return dict
    }

    func canonicalCacheJSON(
        sourceStart: Double? = nil,
        sourceEnd: Double? = nil,
        duration: Double? = nil
    ) -> String {
        let dict = cachePayloadDict(sourceStart: sourceStart, sourceEnd: sourceEnd, duration: duration)
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(
                  withJSONObject: dict,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    var needsProcessedClipPreview: Bool {
        let preset = VideoFilterPreset.resolved(filterPreset)
        return chromaKeyEnabled
            || preset != .none
            || (effectId != "none" && !effectId.isEmpty)
            || (maskKind != "none" && !maskKind.isEmpty)
            || stabilizeEnabled
            || enhanceClarity > 0.01
            || speedCurve.count >= 2
            || abs(brightness) > 0.001
            || abs(contrast - 1.0) > 0.001
            || abs(saturation - 1.0) > 0.001
            || blur > 0.01
            || vignette
            || cropTop > 0.001
            || cropBottom > 0.001
            || cropLeft > 0.001
            || cropRight > 0.001
            || flipH
            || flipV
            || abs(rotation) > 0.01
            || reversed
            || freezeFrame
            || abs(speed - 1.0) > 0.01
    }

    /// Canonical payload for same-source single-clip effect preview cache (neutralizes
    /// live canvas transform/opacity so PiP drag & resize stay 60fps without re-rendering).
    func canonicalClipEffectJSON(
        sourceStart: Double? = nil,
        sourceEnd: Double? = nil,
        duration: Double? = nil
    ) -> String {
        var dict = cachePayloadDict(sourceStart: sourceStart, sourceEnd: sourceEnd, duration: duration)
        dict["posX"] = 0.0
        dict["posY"] = 0.0
        dict["scale"] = 1.0
        dict["opacity"] = 1.0
        dict["still"] = still
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(
                  withJSONObject: dict,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

struct TrackTransition: Codable, Equatable, Identifiable {
    var id: UUID { after }
    var after: UUID
    var before: UUID
    var kind: String
    var seconds: Double

    init(after: UUID, before: UUID, kind: String, seconds: Double) {
        self.after = after
        self.before = before
        self.kind = kind
        self.seconds = seconds
    }
}

struct VideoTrack: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var muted: Bool
    var hidden: Bool
    var locked: Bool
    var clips: [VideoClip]
    var transitions: [TrackTransition]

    init(
        id: UUID = UUID(),
        name: String,
        muted: Bool = false,
        hidden: Bool = false,
        locked: Bool = false,
        clips: [VideoClip] = [],
        transitions: [TrackTransition] = []
    ) {
        self.id = id
        self.name = name
        self.muted = muted
        self.hidden = hidden
        self.locked = locked
        self.clips = clips
        self.transitions = transitions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, muted, hidden, locked, clips, transitions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "V1"
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        clips = try c.decodeIfPresent([VideoClip].self, forKey: .clips) ?? []
        transitions = try c.decodeIfPresent([TrackTransition].self, forKey: .transitions) ?? []
    }
}

struct AudioClip: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var timelineStart: Double
    var sourceStart: Double
    var sourceEnd: Double?
    var volume: Double
    var muted: Bool
    var fadeIn: Double
    var fadeOut: Double
    var voiceCleanup: Bool
    var audioEffect: String
    var keyframes: [ClipKeyframe]

    init(
        id: UUID = UUID(),
        path: String,
        timelineStart: Double = 0,
        sourceStart: Double = 0,
        sourceEnd: Double? = nil,
        volume: Double = 1.0,
        muted: Bool = false,
        fadeIn: Double = 0,
        fadeOut: Double = 0,
        voiceCleanup: Bool = false,
        audioEffect: String = "none",
        keyframes: [ClipKeyframe] = []
    ) {
        self.id = id
        self.path = path
        self.timelineStart = timelineStart
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.volume = volume
        self.muted = muted
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.voiceCleanup = voiceCleanup
        self.audioEffect = audioEffect
        self.keyframes = keyframes
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, timelineStart, sourceStart, sourceEnd, volume, muted, fadeIn, fadeOut
        case voiceCleanup, audioEffect, keyframes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        timelineStart = try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0
        sourceStart = try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        sourceEnd = try c.decodeIfPresent(Double.self, forKey: .sourceEnd)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        voiceCleanup = try c.decodeIfPresent(Bool.self, forKey: .voiceCleanup) ?? false
        audioEffect = try c.decodeIfPresent(String.self, forKey: .audioEffect) ?? "none"
        keyframes = try c.decodeIfPresent([ClipKeyframe].self, forKey: .keyframes) ?? []
    }
}

struct AudioTrack: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var muted: Bool
    var locked: Bool
    var volume: Double
    var clips: [AudioClip]

    init(
        id: UUID = UUID(),
        name: String,
        muted: Bool = false,
        locked: Bool = false,
        volume: Double = 1.0,
        clips: [AudioClip] = []
    ) {
        self.id = id
        self.name = name
        self.muted = muted
        self.locked = locked
        self.volume = volume
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, muted, locked, volume, clips
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "A1"
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
    }
}

struct TextClip: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var timelineStart: Double
    var duration: Double
    var fontFamily: String
    var fontSize: Double
    var textColorHex: String
    var strokeColorHex: String
    var strokeWidth: Double
    var shadowEnabled: Bool
    var backgroundEnabled: Bool
    var backgroundColorHex: String
    var backgroundOpacity: Double
    var posX: Double
    var posY: Double

    init(
        id: UUID = UUID(),
        text: String,
        timelineStart: Double = 0,
        duration: Double = 3.0,
        fontFamily: String = "PingFang TC",
        fontSize: Double = 44,
        textColorHex: String = "#FFFFFF",
        strokeColorHex: String = "#000000",
        strokeWidth: Double = 3.0,
        shadowEnabled: Bool = true,
        backgroundEnabled: Bool = true,
        backgroundColorHex: String = "#000000",
        backgroundOpacity: Double = 0.55,
        posX: Double = 0.5,
        posY: Double = 0.86
    ) {
        self.id = id
        self.text = text
        self.timelineStart = timelineStart
        self.duration = duration
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.textColorHex = textColorHex
        self.strokeColorHex = strokeColorHex
        self.strokeWidth = strokeWidth
        self.shadowEnabled = shadowEnabled
        self.backgroundEnabled = backgroundEnabled
        self.backgroundColorHex = backgroundColorHex
        self.backgroundOpacity = backgroundOpacity
        self.posX = posX
        self.posY = posY
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, timelineStart, duration, fontFamily, fontSize
        case textColorHex, strokeColorHex, strokeWidth, shadowEnabled
        case backgroundEnabled, backgroundColorHex, backgroundOpacity, posX, posY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        timelineStart = try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3.0
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "PingFang TC"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 44
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"
        strokeColorHex = try c.decodeIfPresent(String.self, forKey: .strokeColorHex) ?? "#000000"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 3.0
        shadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        backgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true
        backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? "#000000"
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.55
        posX = try c.decodeIfPresent(Double.self, forKey: .posX) ?? 0.5
        posY = try c.decodeIfPresent(Double.self, forKey: .posY) ?? 0.86
    }
}

struct TextTrack: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var hidden: Bool
    var locked: Bool
    var clips: [TextClip]

    init(
        id: UUID = UUID(),
        name: String,
        hidden: Bool = false,
        locked: Bool = false,
        clips: [TextClip] = []
    ) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.locked = locked
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hidden, locked, clips
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "T1"
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        clips = try c.decodeIfPresent([TextClip].self, forKey: .clips) ?? []
    }
}

struct TimelineSequence: Codable, Identifiable, Equatable {
    static let defaultPrimaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id: UUID
    var name: String
    var videoTracks: [VideoTrack]
    var audioTracks: [AudioTrack]
    var textTracks: [TextTrack]
    var shapeTracks: [ShapeTrack]
    var snapEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        videoTracks: [VideoTrack] = [VideoTrack(name: "V1 主軌")],
        audioTracks: [AudioTrack] = [AudioTrack(name: "A1 音訊")],
        textTracks: [TextTrack] = [TextTrack(name: "T1 字幕")],
        shapeTracks: [ShapeTrack] = [ShapeTrack(name: "S1 形狀")],
        snapEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.textTracks = textTracks
        self.shapeTracks = shapeTracks
        self.snapEnabled = snapEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, videoTracks, audioTracks, textTracks, shapeTracks, snapEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "時間軸 1"
        videoTracks = try c.decodeIfPresent([VideoTrack].self, forKey: .videoTracks) ?? [VideoTrack(name: "V1 主軌")]
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? [AudioTrack(name: "A1 音訊")]
        textTracks = try c.decodeIfPresent([TextTrack].self, forKey: .textTracks) ?? [TextTrack(name: "T1 字幕")]
        shapeTracks = try c.decodeIfPresent([ShapeTrack].self, forKey: .shapeTracks) ?? [ShapeTrack(name: "S1 形狀")]
        snapEnabled = try c.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? true
    }

    func duplicated(named newName: String) -> TimelineSequence {
        let newVideoTracks: [VideoTrack] = videoTracks.map { vt in
            var idMap: [UUID: UUID] = [:]
            let copiedClips: [VideoClip] = vt.clips.map { clip in
                var copy = clip
                let newID = UUID()
                idMap[clip.id] = newID
                copy.id = newID
                return copy
            }
            let copiedTransitions: [TrackTransition] = vt.transitions.compactMap { tr in
                guard let newAfter = idMap[tr.after], let newBefore = idMap[tr.before] else { return nil }
                return TrackTransition(after: newAfter, before: newBefore, kind: tr.kind, seconds: tr.seconds)
            }
            return VideoTrack(
                id: UUID(),
                name: vt.name,
                muted: vt.muted,
                hidden: vt.hidden,
                locked: vt.locked,
                clips: copiedClips,
                transitions: copiedTransitions
            )
        }
        let newAudioTracks: [AudioTrack] = audioTracks.map { at in
            AudioTrack(
                id: UUID(),
                name: at.name,
                muted: at.muted,
                locked: at.locked,
                volume: at.volume,
                clips: at.clips.map { clip in
                    var copy = clip
                    copy.id = UUID()
                    return copy
                }
            )
        }
        let newTextTracks: [TextTrack] = textTracks.map { tt in
            TextTrack(
                id: UUID(),
                name: tt.name,
                hidden: tt.hidden,
                locked: tt.locked,
                clips: tt.clips.map { clip in
                    var copy = clip
                    copy.id = UUID()
                    return copy
                }
            )
        }
        let newShapeTracks: [ShapeTrack] = shapeTracks.map { st in
            ShapeTrack(
                id: UUID(),
                name: st.name,
                hidden: st.hidden,
                locked: st.locked,
                clips: st.clips.map { clip in
                    var copy = clip
                    copy.id = UUID()
                    return copy
                }
            )
        }
        return TimelineSequence(
            id: UUID(),
            name: newName,
            videoTracks: newVideoTracks,
            audioTracks: newAudioTracks,
            textTracks: newTextTracks,
            shapeTracks: newShapeTracks,
            snapEnabled: snapEnabled
        )
    }
}

struct MultitrackTimeline: Codable, Equatable {
    /// `videoTracks[0]` is the bottom-most base track (V1); `videoTracks[1]` composites over V1, etc.
    /// Top-level tracks always mirror the currently active `TimelineSequence` for 100% 0.2.0 backward compatibility.
    var videoTracks: [VideoTrack]
    var audioTracks: [AudioTrack]
    var textTracks: [TextTrack]
    var shapeTracks: [ShapeTrack]
    var snapEnabled: Bool
    var sequences: [TimelineSequence]?
    var activeSequenceID: UUID?

    init(
        videoTracks: [VideoTrack] = [VideoTrack(name: "V1 主軌")],
        audioTracks: [AudioTrack] = [AudioTrack(name: "A1 音訊")],
        textTracks: [TextTrack] = [TextTrack(name: "T1 字幕")],
        shapeTracks: [ShapeTrack] = [ShapeTrack(name: "S1 形狀")],
        snapEnabled: Bool = true,
        sequences: [TimelineSequence]? = nil,
        activeSequenceID: UUID? = nil
    ) {
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.textTracks = textTracks
        self.shapeTracks = shapeTracks
        self.snapEnabled = snapEnabled
        self.sequences = sequences
        self.activeSequenceID = activeSequenceID
    }

    private enum CodingKeys: String, CodingKey {
        case videoTracks, audioTracks, textTracks, shapeTracks, snapEnabled, sequences, activeSequenceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoTracks = try c.decodeIfPresent([VideoTrack].self, forKey: .videoTracks) ?? [VideoTrack(name: "V1 主軌")]
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks) ?? [AudioTrack(name: "A1 音訊")]
        textTracks = try c.decodeIfPresent([TextTrack].self, forKey: .textTracks) ?? [TextTrack(name: "T1 字幕")]
        shapeTracks = try c.decodeIfPresent([ShapeTrack].self, forKey: .shapeTracks) ?? [ShapeTrack(name: "S1 形狀")]
        snapEnabled = try c.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? true
        sequences = try c.decodeIfPresent([TimelineSequence].self, forKey: .sequences)
        activeSequenceID = try c.decodeIfPresent(UUID.self, forKey: .activeSequenceID)
    }

    var resolvedActiveSequenceID: UUID {
        if let activeSequenceID, let seqs = sequences, seqs.contains(where: { $0.id == activeSequenceID }) {
            return activeSequenceID
        }
        if let first = sequences?.first {
            return first.id
        }
        return activeSequenceID ?? TimelineSequence.defaultPrimaryID
    }

    var resolvedSequences: [TimelineSequence] {
        if let seqs = sequences, !seqs.isEmpty {
            return seqs
        }
        return [
            TimelineSequence(
                id: resolvedActiveSequenceID,
                name: "時間軸 1",
                videoTracks: videoTracks,
                audioTracks: audioTracks,
                textTracks: textTracks,
                shapeTracks: shapeTracks,
                snapEnabled: snapEnabled
            )
        ]
    }

    mutating func syncActiveSequenceFromTopLevel() {
        guard var seqs = sequences, !seqs.isEmpty else { return }
        let activeID = resolvedActiveSequenceID
        if let idx = seqs.firstIndex(where: { $0.id == activeID }) {
            seqs[idx].videoTracks = videoTracks
            seqs[idx].audioTracks = audioTracks
            seqs[idx].textTracks = textTracks
            seqs[idx].shapeTracks = shapeTracks
            seqs[idx].snapEnabled = snapEnabled
            sequences = seqs
            activeSequenceID = activeID
        }
    }

    mutating func ensureMaterializedSequences() {
        if sequences == nil || sequences?.isEmpty == true {
            let primaryID = activeSequenceID ?? TimelineSequence.defaultPrimaryID
            sequences = [
                TimelineSequence(
                    id: primaryID,
                    name: "時間軸 1",
                    videoTracks: videoTracks,
                    audioTracks: audioTracks,
                    textTracks: textTracks,
                    shapeTracks: shapeTracks,
                    snapEnabled: snapEnabled
                )
            ]
            activeSequenceID = primaryID
        } else {
            syncActiveSequenceFromTopLevel()
        }
    }

    static func emptyDefault() -> MultitrackTimeline {
        MultitrackTimeline(
            videoTracks: [VideoTrack(name: "V1 主軌")],
            audioTracks: [AudioTrack(name: "A1 音訊")],
            textTracks: [TextTrack(name: "T1 字幕")],
            shapeTracks: [ShapeTrack(name: "S1 形狀")],
            snapEnabled: true
        )
    }

    var isEmpty: Bool {
        videoTracks.allSatisfy(\.clips.isEmpty)
            && audioTracks.allSatisfy(\.clips.isEmpty)
            && textTracks.allSatisfy(\.clips.isEmpty)
            && shapeTracks.allSatisfy(\.clips.isEmpty)
    }

    /// Losslessly migrates a MotionDesk 0.1.19 single-track timeline into V1 while creating empty A1 & T1.
    static func migrateFromLegacy(
        clips: [Clip],
        transitions: [TimelineTransition]?,
        durations: [String: Double]
    ) -> MultitrackTimeline {
        guard !clips.isEmpty else { return .emptyDefault() }

        let savedTransitions = transitions ?? []
        var pairTransitions: [TrackTransition?] = []
        for idx in 0..<max(0, clips.count - 1) {
            let leading = clips[idx]
            let trailing = clips[idx + 1]
            if let found = savedTransitions.first(where: { $0.after == leading.id && $0.before == trailing.id }),
               TimelineTransitionKind.supportedRawValues.contains(found.kind),
               found.seconds.isFinite, (0.1...3.0).contains(found.seconds) {
                pairTransitions.append(TrackTransition(
                    after: found.after,
                    before: found.before,
                    kind: found.kind,
                    seconds: (found.seconds * 100).rounded() / 100
                ))
            } else {
                pairTransitions.append(nil)
            }
        }

        let clipDurations: [Double] = clips.map { clip in
            if clip.still {
                return max(TimelineLayout.minClipDuration,
                           TimelineLayout.parseSeconds(clip.end) ?? TimelineLayout.defaultStillDuration)
            }
            let start = max(0, TimelineLayout.parseSeconds(clip.start) ?? 0)
            let end = TimelineLayout.parseSeconds(clip.end)
                ?? durations[clip.path]
                ?? (start + TimelineLayout.defaultStillDuration)
            return max(TimelineLayout.minClipDuration, end - start)
        }

        var v1Clips: [VideoClip] = []
        var validTrackTransitions: [TrackTransition] = []
        var cursor = 0.0

        for idx in clips.indices {
            if idx > 0, let tr = pairTransitions[idx - 1] {
                let maxSafe = min(clipDurations[idx - 1], clipDurations[idx]) * 0.9
                let overlap = min(tr.seconds, max(0, maxSafe))
                cursor = max(0, cursor - overlap)
                validTrackTransitions.append(tr)
            }
            let legacy = clips[idx]
            v1Clips.append(VideoClip(
                id: legacy.id,
                path: legacy.path,
                timelineStart: (cursor * 1000).rounded() / 1000,
                start: legacy.start,
                end: legacy.end
            ))
            cursor += clipDurations[idx]
        }

        return MultitrackTimeline(
            videoTracks: [VideoTrack(name: "V1 主軌", clips: v1Clips, transitions: validTrackTransitions)],
            audioTracks: [AudioTrack(name: "A1 音訊")],
            textTracks: [TextTrack(name: "T1 字幕")],
            snapEnabled: true
        )
    }

    /// Mirrors V1 back to legacy `Project.clips` and `Project.editTransitions` for backward compatibility.
    func mirrorLegacyV1() -> (clips: [Clip], transitions: [TimelineTransition]) {
        guard let v1 = videoTracks.first else { return ([], []) }
        let sorted = v1.clips.enumerated().sorted { lhs, rhs in
            if abs(lhs.element.timelineStart - rhs.element.timelineStart) > 1e-6 {
                return lhs.element.timelineStart < rhs.element.timelineStart
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let legacyClips = sorted.map { clip in
            Clip(id: clip.id, path: clip.path, start: clip.start, end: clip.end)
        }
        let adjacentPairs = Set(zip(sorted, sorted.dropFirst()).map { "\($0.0.id.uuidString)->\($0.1.id.uuidString)" })
        let legacyTransitions = v1.transitions.compactMap { tr -> TimelineTransition? in
            guard adjacentPairs.contains("\(tr.after.uuidString)->\(tr.before.uuidString)"),
                  TimelineTransitionKind.supportedRawValues.contains(tr.kind),
                  tr.seconds.isFinite, (0.1...3.0).contains(tr.seconds) else {
                return nil
            }
            return TimelineTransition(after: tr.after, before: tr.before, kind: tr.kind, seconds: tr.seconds)
        }
        return (legacyClips, legacyTransitions)
    }

    /// Exports the JSON-serializable `"timeline"` dictionary consumed by `timeline_render.py`.
    func exportPayload(durations: [String: Double], fps: Int = Int(TimelineLayout.fps)) -> [String: Any] {
        let layout = MultitrackLayout(timeline: self, durations: durations, outputFPS: fps)

        let vTracks: [[String: Any]] = layout.videoTracks.map { trackLayout in
            let clipsPayload: [[String: Any]] = trackLayout.segments.map { seg in
                [
                    "id": seg.clip.id.uuidString,
                    "path": seg.clip.path,
                    "still": seg.clip.still,
                    "timelineStart": MultitrackLayout.roundTime(seg.timelineStart),
                    "duration": MultitrackLayout.roundTime(seg.duration),
                    "start": seg.clip.still ? "" : seg.clip.start.trimmingCharacters(in: .whitespacesAndNewlines),
                    "end": seg.clip.end.trimmingCharacters(in: .whitespacesAndNewlines),
                    "sourceStart": MultitrackLayout.roundTime(seg.sourceStart),
                    "sourceEnd": MultitrackLayout.roundTime(seg.sourceEnd),
                    "posX": seg.clip.posX,
                    "posY": seg.clip.posY,
                    "scale": seg.clip.scale,
                    "opacity": seg.clip.opacity,
                    "volume": seg.clip.volume,
                    "muted": seg.clip.muted,
                    "rotation": seg.clip.rotation,
                    "flipH": seg.clip.flipH,
                    "flipV": seg.clip.flipV,
                    "cropTop": seg.clip.cropTop,
                    "cropBottom": seg.clip.cropBottom,
                    "cropLeft": seg.clip.cropLeft,
                    "cropRight": seg.clip.cropRight,
                    "speed": seg.clip.speed,
                    "reversed": seg.clip.reversed,
                    "freezeFrame": seg.clip.freezeFrame,
                    "filterPreset": seg.clip.filterPreset,
                    "brightness": seg.clip.brightness,
                    "contrast": seg.clip.contrast,
                    "saturation": seg.clip.saturation,
                    "blur": seg.clip.blur,
                    "vignette": seg.clip.vignette,
                    "chromaKeyEnabled": seg.clip.chromaKeyEnabled,
                    "chromaKeyColor": seg.clip.chromaKeyColor,
                    "chromaKeySimilarity": seg.clip.chromaKeySimilarity,
                    "chromaKeyBlend": seg.clip.chromaKeyBlend,
                    "animationIn": seg.clip.animationIn,
                    "animationOut": seg.clip.animationOut,
                    "animationDuration": MultitrackLayout.roundTime(seg.clip.animationDuration),
                    "voiceCleanup": seg.clip.voiceCleanup,
                    "audioEffect": seg.clip.audioEffect,
                    "effectId": seg.clip.effectId,
                    "blendMode": seg.clip.blendMode,
                    "maskKind": seg.clip.maskKind,
                    "maskFeather": seg.clip.maskFeather,
                    "maskInvert": seg.clip.maskInvert,
                    "stabilizeEnabled": seg.clip.stabilizeEnabled,
                    "stabilizeStrength": seg.clip.stabilizeStrength,
                    "enhanceClarity": seg.clip.enhanceClarity,
                    "keyframes": seg.clip.keyframes.map { $0.toDict() },
                    "speedCurve": seg.clip.speedCurve.map { $0.toDict() }
                ]
            }
            let transitionsPayload: [[String: Any]] = trackLayout.junctions.compactMap { j in
                guard let tr = j.transition, !j.isCut else { return nil }
                return [
                    "after": tr.after.uuidString,
                    "before": tr.before.uuidString,
                    "kind": tr.kind,
                    "seconds": MultitrackLayout.roundTime(tr.seconds)
                ]
            }
            return [
                "id": trackLayout.track.id.uuidString,
                "name": trackLayout.track.name,
                "muted": trackLayout.track.muted,
                "hidden": trackLayout.track.hidden,
                "clips": clipsPayload,
                "transitions": transitionsPayload
            ]
        }

        let aTracks: [[String: Any]] = layout.audioTracks.map { trackLayout in
            let clipsPayload: [[String: Any]] = trackLayout.segments.map { seg in
                var dict: [String: Any] = [
                    "id": seg.clip.id.uuidString,
                    "path": seg.clip.path,
                    "timelineStart": MultitrackLayout.roundTime(seg.timelineStart),
                    "sourceStart": MultitrackLayout.roundTime(seg.sourceStart),
                    "sourceEnd": MultitrackLayout.roundTime(seg.sourceEnd),
                    "duration": MultitrackLayout.roundTime(seg.duration),
                    "volume": seg.clip.volume,
                    "muted": seg.clip.muted,
                    "fadeIn": MultitrackLayout.roundTime(seg.clip.fadeIn),
                    "fadeOut": MultitrackLayout.roundTime(seg.clip.fadeOut),
                    "voiceCleanup": seg.clip.voiceCleanup,
                    "audioEffect": seg.clip.audioEffect,
                    "keyframes": seg.clip.keyframes.map { $0.toDict() }
                ]
                if seg.clip.sourceEnd == nil && seg.sourceDuration == nil {
                    dict["sourceEnd"] = NSNull()
                }
                return dict
            }
            return [
                "id": trackLayout.track.id.uuidString,
                "name": trackLayout.track.name,
                "muted": trackLayout.track.muted,
                "volume": trackLayout.track.volume,
                "clips": clipsPayload
            ]
        }

        let tTracks: [[String: Any]] = layout.textTracks.map { trackLayout in
            let clipsPayload: [[String: Any]] = trackLayout.segments.map { seg in
                [
                    "id": seg.clip.id.uuidString,
                    "text": seg.clip.text,
                    "timelineStart": MultitrackLayout.roundTime(seg.timelineStart),
                    "duration": MultitrackLayout.roundTime(seg.duration),
                    "fontFamily": seg.clip.fontFamily,
                    "fontSize": seg.clip.fontSize,
                    "textColorHex": seg.clip.textColorHex,
                    "strokeColorHex": seg.clip.strokeColorHex,
                    "strokeWidth": seg.clip.strokeWidth,
                    "shadowEnabled": seg.clip.shadowEnabled,
                    "backgroundEnabled": seg.clip.backgroundEnabled,
                    "backgroundColorHex": seg.clip.backgroundColorHex,
                    "backgroundOpacity": seg.clip.backgroundOpacity,
                    "posX": seg.clip.posX,
                    "posY": seg.clip.posY
                ]
            }
            return [
                "id": trackLayout.track.id.uuidString,
                "name": trackLayout.track.name,
                "hidden": trackLayout.track.hidden,
                "clips": clipsPayload
            ]
        }

        let sTracks: [[String: Any]] = layout.shapeTracks.map { trackLayout in
            let clipsPayload: [[String: Any]] = trackLayout.segments.map { seg in
                [
                    "id": seg.clip.id.uuidString,
                    "kind": seg.clip.kind,
                    "timelineStart": MultitrackLayout.roundTime(seg.timelineStart),
                    "duration": MultitrackLayout.roundTime(seg.duration),
                    "posX": seg.clip.posX,
                    "posY": seg.clip.posY,
                    "shapeWidth": seg.clip.width,
                    "shapeHeight": seg.clip.height,
                    "rotation": seg.clip.rotation,
                    "opacity": seg.clip.opacity,
                    "fillColorHex": seg.clip.fillColorHex,
                    "fillGradientEnabled": seg.clip.fillGradientEnabled,
                    "fillGradientEndHex": seg.clip.fillGradientEndHex,
                    "fillGradientAngle": seg.clip.fillGradientAngle,
                    "strokeColorHex": seg.clip.strokeColorHex,
                    "strokeWidth": seg.clip.strokeWidth,
                    "cornerRadius": seg.clip.cornerRadius,
                    "shadowEnabled": seg.clip.shadowEnabled,
                    "label": seg.clip.label,
                    "labelColorHex": seg.clip.labelColorHex,
                    "labelFontSize": seg.clip.labelFontSize
                ]
            }
            return [
                "id": trackLayout.track.id.uuidString,
                "name": trackLayout.track.name,
                "hidden": trackLayout.track.hidden,
                "clips": clipsPayload
            ]
        }

        return [
            "fps": fps,
            "totalDuration": MultitrackLayout.roundTime(layout.totalDuration),
            "videoTracks": vTracks,
            "audioTracks": aTracks,
            "textTracks": tTracks,
            "shapeTracks": sTracks
        ]
    }
}

// MARK: - SRT Codec

enum SRTCodec {
    static func parse(_ content: String) -> [TextClip] {
        var text = content
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = text.components(separatedBy: "\n")
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current)
        }

        var result: [TextClip] = []
        for block in blocks {
            guard let tsIndex = block.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let range = parseTimeRange(block[tsIndex]) else { continue }
            let bodyLines = block.dropFirst(tsIndex + 1)
            let subtitleText = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subtitleText.isEmpty else { continue }
            let start = max(0, range.start)
            let duration = max(TimelineLayout.minClipDuration, range.end - start)
            result.append(TextClip(
                text: subtitleText,
                timelineStart: (start * 1000).rounded() / 1000,
                duration: (duration * 1000).rounded() / 1000
            ))
        }

        return result.sorted { lhs, rhs in
            if abs(lhs.timelineStart - rhs.timelineStart) > 1e-6 {
                return lhs.timelineStart < rhs.timelineStart
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func export(_ clips: [TextClip]) -> String {
        let valid = clips
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.duration > 0 }
            .sorted { lhs, rhs in
                if abs(lhs.timelineStart - rhs.timelineStart) > 1e-6 {
                    return lhs.timelineStart < rhs.timelineStart
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        var entries: [String] = []
        for (idx, clip) in valid.enumerated() {
            let start = max(0, clip.timelineStart)
            let end = start + max(TimelineLayout.minClipDuration, clip.duration)
            let body = clip.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append("\(idx + 1)\n\(formatTimestamp(start)) --> \(formatTimestamp(end))\n\(body)")
        }
        return entries.joined(separator: "\n\n") + (entries.isEmpty ? "" : "\n")
    }

    private static func parseTimeRange(_ line: String) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let startRaw = parts[0].trimmingCharacters(in: .whitespaces)
        let endToken = parts[1].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first ?? ""
        guard let start = parseTimestamp(startRaw),
              let end = parseTimestamp(endToken),
              end > start else {
            return nil
        }
        return (start, end)
    }

    private static func parseTimestamp(_ raw: String) -> Double? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]),
              hours >= 0, minutes >= 0, seconds >= 0 else {
            return nil
        }
        return hours * 3600.0 + minutes * 60.0 + seconds
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let totalMs = max(0, Int((seconds.isFinite ? seconds * 1000.0 : 0).rounded()))
        let hours = totalMs / 3_600_000
        let minutes = (totalMs % 3_600_000) / 60_000
        let secs = (totalMs % 60_000) / 1000
        let millis = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}

// MARK: - Multitrack Layout Engine

struct VideoSegmentLayout: Equatable, Identifiable {
    let id: UUID
    let trackID: UUID
    let trackIndex: Int
    let clipIndex: Int
    let clip: VideoClip
    let sourceStart: Double
    let sourceEnd: Double
    let sourceDuration: Double?
    let duration: Double
    let timelineStart: Double
    let timelineEnd: Double
    let incomingOverlap: Double
    let outgoingOverlap: Double
    let isTrimValid: Bool
    let loadError: String?
}

struct TrackJunctionLayout: Equatable, Identifiable {
    var id: String { "\(trackID.uuidString):\(afterID.uuidString):\(beforeID.uuidString)" }
    let trackID: UUID
    let trackIndex: Int
    let leadingIndex: Int
    let trailingIndex: Int
    let afterID: UUID
    let beforeID: UUID
    let transition: TrackTransition?
    let seamTime: Double
    let overlapStart: Double
    let overlapEnd: Double
    let overlapDuration: Double
    let isValid: Bool

    var isCut: Bool { transition == nil || transition?.kind == "cut" || overlapDuration <= 0 }
}

struct VideoTrackLayout: Equatable, Identifiable {
    var id: UUID { track.id }
    let trackIndex: Int
    let track: VideoTrack
    let segments: [VideoSegmentLayout]
    let junctions: [TrackJunctionLayout]
    let endTime: Double
}

struct AudioSegmentLayout: Equatable, Identifiable {
    let id: UUID
    let trackID: UUID
    let trackIndex: Int
    let clip: AudioClip
    let sourceStart: Double
    let sourceEnd: Double
    let sourceDuration: Double?
    let duration: Double
    let timelineStart: Double
    let timelineEnd: Double
    let effectiveVolume: Double
    let isTrimValid: Bool
    let loadError: String?
}

struct AudioTrackLayout: Equatable, Identifiable {
    var id: UUID { track.id }
    let trackIndex: Int
    let track: AudioTrack
    let segments: [AudioSegmentLayout]
    let endTime: Double
}

struct TextSegmentLayout: Equatable, Identifiable {
    let id: UUID
    let trackID: UUID
    let trackIndex: Int
    let clip: TextClip
    let timelineStart: Double
    let timelineEnd: Double
    let duration: Double
}

struct TextTrackLayout: Equatable, Identifiable {
    var id: UUID { track.id }
    let trackIndex: Int
    let track: TextTrack
    let segments: [TextSegmentLayout]
    let endTime: Double
}

struct ActiveVideoLayer: Equatable, Identifiable {
    var id: UUID { segment.id }
    let trackIndex: Int
    let trackID: UUID
    let trackMuted: Bool
    let segment: VideoSegmentLayout
    let sourceTime: Double
    let activeJunction: TrackJunctionLayout?
    let transitionProgress: Double
    let effectiveOpacity: Double
    let fadeOverlayColor: String?
    let fadeOverlayOpacity: Double
    let transitionTrailingSegment: VideoSegmentLayout?
    let transitionTrailingSourceTime: Double?
    let transitionCacheRequest: TransitionCacheRequest?
    let transitionLocalTime: Double
    let clipEffectCacheRequest: ClipEffectCacheRequest?
    let clipLocalTime: Double
}

struct ActiveAudioLayer: Equatable, Identifiable {
    var id: UUID { segment.id }
    let trackID: UUID
    let segment: AudioSegmentLayout
    let sourceTime: Double
    let currentGain: Float
}

struct MultitrackLayout: Equatable {
    static let empty = MultitrackLayout(timeline: .emptyDefault(), durations: [:])

    let videoTracks: [VideoTrackLayout]
    let audioTracks: [AudioTrackLayout]
    let textTracks: [TextTrackLayout]
    let shapeTracks: [ShapeTrackLayout]
    /// Maximum end time across all V, A, T, and S tracks (never sum).
    let totalDuration: Double
    let hasTransitions: Bool
    let hasInvalidTransitions: Bool
    let isEmpty: Bool
    let outputWidth: Int
    let outputHeight: Int
    let outputFPS: Int

    static func roundTime(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (max(0, value) * 1000.0).rounded() / 1000.0
    }

    init(
        timeline: MultitrackTimeline,
        durations: [String: Double],
        durationErrors: [String: String] = [:],
        outputWidth: Int = 1920,
        outputHeight: Int = 1080,
        outputFPS: Int = Int(TimelineLayout.fps)
    ) {
        var builtVideoTracks: [VideoTrackLayout] = []
        var anyTransition = false
        var anyInvalidTransition = false

        for (trackIdx, track) in timeline.videoTracks.enumerated() {
            let sortedClips = track.clips.enumerated().sorted { lhs, rhs in
                if abs(lhs.element.timelineStart - rhs.element.timelineStart) > 1e-6 {
                    return lhs.element.timelineStart < rhs.element.timelineStart
                }
                return lhs.offset < rhs.offset
            }.map(\.element)

            struct RawVideoSpec {
                let sourceStart: Double
                let sourceEnd: Double
                let sourceDuration: Double?
                let duration: Double
                let timelineStart: Double
                let timelineEnd: Double
                let isTrimValid: Bool
            }

            let rawSpecs: [RawVideoSpec] = sortedClips.map { clip in
                let tStart = max(0, clip.timelineStart.isFinite ? clip.timelineStart : 0)
                if clip.still {
                    let parsedEnd = TimelineLayout.parseSeconds(clip.end)
                    let rawLen = parsedEnd ?? TimelineLayout.defaultStillDuration
                    let valid = clip.end.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (parsedEnd != nil && rawLen >= TimelineLayout.minClipDuration)
                    let safeLen = max(TimelineLayout.minClipDuration, rawLen.isFinite ? rawLen : TimelineLayout.defaultStillDuration)
                    return RawVideoSpec(
                        sourceStart: 0,
                        sourceEnd: safeLen,
                        sourceDuration: nil,
                        duration: safeLen,
                        timelineStart: tStart,
                        timelineEnd: tStart + safeLen,
                        isTrimValid: valid
                    )
                } else if clip.freezeFrame {
                    let probed = durations[clip.path]
                    let parsedStart = TimelineLayout.parseSeconds(clip.start)
                    let parsedEnd = TimelineLayout.parseSeconds(clip.end)
                    let srcStart = max(0, parsedStart ?? 0)
                    let freezeLen: Double
                    if let parsedEnd, parsedEnd > srcStart + TimelineLayout.minClipDuration - 1e-4 {
                        freezeLen = parsedEnd - srcStart
                    } else if let parsedEnd, parsedStart == nil, parsedEnd >= TimelineLayout.minClipDuration {
                        freezeLen = parsedEnd
                    } else {
                        freezeLen = 2.0
                    }
                    let safeLen = max(TimelineLayout.minClipDuration, min(300.0, freezeLen.isFinite ? freezeLen : 2.0))
                    return RawVideoSpec(
                        sourceStart: srcStart,
                        sourceEnd: srcStart + safeLen,
                        sourceDuration: probed,
                        duration: safeLen,
                        timelineStart: tStart,
                        timelineEnd: tStart + safeLen,
                        isTrimValid: true
                    )
                } else {
                    let probed = durations[clip.path]
                    let parsedStart = TimelineLayout.parseSeconds(clip.start)
                    let parsedEnd = TimelineLayout.parseSeconds(clip.end)
                    let startEmpty = clip.start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let endEmpty = clip.end.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let srcStart = max(0, parsedStart ?? 0)
                    let srcEnd = parsedEnd ?? probed ?? (srcStart + TimelineLayout.defaultStillDuration)
                    let rawSourceLen = srcEnd - srcStart
                    let safeSpeed = min(4.0, max(0.25, clip.speed.isFinite ? clip.speed : 1.0))
                    let withinSource = probed.map { srcEnd <= $0 + 0.10 } ?? true
                    let valid = (startEmpty || (parsedStart != nil && (parsedStart ?? -1) >= 0))
                        && (endEmpty || parsedEnd != nil)
                        && rawSourceLen >= TimelineLayout.minClipDuration - 1e-4
                        && withinSource
                    let safeSourceLen = max(TimelineLayout.minClipDuration, rawSourceLen.isFinite ? rawSourceLen : TimelineLayout.defaultStillDuration)
                    let timelineDur = max(TimelineLayout.minClipDuration, safeSourceLen / safeSpeed)
                    return RawVideoSpec(
                        sourceStart: srcStart,
                        sourceEnd: srcStart + safeSourceLen,
                        sourceDuration: probed,
                        duration: timelineDur,
                        timelineStart: tStart,
                        timelineEnd: tStart + timelineDur,
                        isTrimValid: valid
                    )
                }
            }

            // Build same-track adjacent junctions ONLY (never across tracks, never across gaps).
            var incomingOverlaps = Array(repeating: 0.0, count: sortedClips.count)
            var outgoingOverlaps = Array(repeating: 0.0, count: sortedClips.count)
            var preliminaryJunctions: [(idx: Int, tr: TrackTransition?, seam: Double, oStart: Double, oEnd: Double, oDur: Double)] = []

            if sortedClips.count >= 2 {
                for i in 0..<(sortedClips.count - 1) {
                    let a = sortedClips[i]
                    let b = sortedClips[i + 1]
                    let aSpec = rawSpecs[i]
                    let bSpec = rawSpecs[i + 1]
                    let gap = bSpec.timelineStart - aSpec.timelineEnd

                    let savedTr = track.transitions.first {
                        $0.after == a.id && $0.before == b.id
                            && TimelineTransitionKind.supportedRawValues.contains($0.kind)
                            && $0.seconds.isFinite && (0.1...3.0).contains($0.seconds)
                    }

                    if let tr = savedTr, gap <= 0.08 {
                        let actualOverlap = aSpec.timelineEnd - bSpec.timelineStart
                        let effOverlap = actualOverlap > 0.01 ? min(tr.seconds, actualOverlap) : tr.seconds
                        let oEnd = aSpec.timelineEnd
                        let oStart = max(aSpec.timelineStart, oEnd - effOverlap)
                        let oDur = max(0, oEnd - oStart)
                        outgoingOverlaps[i] = tr.seconds
                        incomingOverlaps[i + 1] = tr.seconds
                        preliminaryJunctions.append((i, tr, (oStart + oEnd) * 0.5, oStart, oEnd, oDur))
                        anyTransition = true
                    } else if abs(gap) <= 0.06 {
                        preliminaryJunctions.append((i, nil, aSpec.timelineEnd, aSpec.timelineEnd, aSpec.timelineEnd, 0))
                    }
                }
            }

            var clipTransitionValid = Array(repeating: true, count: sortedClips.count)
            for i in 0..<sortedClips.count {
                let inc = incomingOverlaps[i]
                let out = outgoingOverlaps[i]
                let dur = rawSpecs[i].duration
                if max(inc, out) >= dur - 0.001 || inc + out > dur + 0.001 {
                    clipTransitionValid[i] = false
                }
            }

            var builtJunctions: [TrackJunctionLayout] = []
            for item in preliminaryJunctions {
                let i = item.idx
                let valid = item.tr == nil ? true : (clipTransitionValid[i] && clipTransitionValid[i + 1])
                if !valid { anyInvalidTransition = true }
                builtJunctions.append(TrackJunctionLayout(
                    trackID: track.id,
                    trackIndex: trackIdx,
                    leadingIndex: i,
                    trailingIndex: i + 1,
                    afterID: sortedClips[i].id,
                    beforeID: sortedClips[i + 1].id,
                    transition: item.tr,
                    seamTime: item.seam,
                    overlapStart: item.oStart,
                    overlapEnd: item.oEnd,
                    overlapDuration: item.oDur,
                    isValid: valid
                ))
            }

            let builtSegments: [VideoSegmentLayout] = sortedClips.enumerated().map { idx, clip in
                let spec = rawSpecs[idx]
                return VideoSegmentLayout(
                    id: clip.id,
                    trackID: track.id,
                    trackIndex: trackIdx,
                    clipIndex: idx,
                    clip: clip,
                    sourceStart: spec.sourceStart,
                    sourceEnd: spec.sourceEnd,
                    sourceDuration: spec.sourceDuration,
                    duration: spec.duration,
                    timelineStart: spec.timelineStart,
                    timelineEnd: spec.timelineEnd,
                    incomingOverlap: incomingOverlaps[idx],
                    outgoingOverlap: outgoingOverlaps[idx],
                    isTrimValid: spec.isTrimValid,
                    loadError: durationErrors[clip.path]
                )
            }

            let trackEnd = builtSegments.map(\.timelineEnd).max() ?? 0
            builtVideoTracks.append(VideoTrackLayout(
                trackIndex: trackIdx,
                track: track,
                segments: builtSegments,
                junctions: builtJunctions,
                endTime: trackEnd
            ))
        }

        var builtAudioTracks: [AudioTrackLayout] = []
        for (trackIdx, track) in timeline.audioTracks.enumerated() {
            let sortedClips = track.clips.enumerated().sorted { lhs, rhs in
                if abs(lhs.element.timelineStart - rhs.element.timelineStart) > 1e-6 {
                    return lhs.element.timelineStart < rhs.element.timelineStart
                }
                return lhs.offset < rhs.offset
            }.map(\.element)

            let builtSegments: [AudioSegmentLayout] = sortedClips.map { clip in
                let tStart = max(0, clip.timelineStart.isFinite ? clip.timelineStart : 0)
                let probed = durations[clip.path]
                let srcStart = max(0, clip.sourceStart.isFinite ? clip.sourceStart : 0)
                let srcEnd = clip.sourceEnd ?? probed ?? (srcStart + TimelineLayout.defaultStillDuration)
                let rawLen = srcEnd - srcStart
                let withinSource = probed.map { srcEnd <= $0 + 0.15 } ?? true
                let valid = srcStart >= 0 && rawLen >= TimelineLayout.minClipDuration - 1e-4 && withinSource
                let safeLen = max(TimelineLayout.minClipDuration, rawLen.isFinite ? rawLen : TimelineLayout.defaultStillDuration)
                let gain = (track.muted || clip.muted) ? 0.0 : max(0, min(2.0, clip.volume) * max(0, min(2.0, track.volume)))
                return AudioSegmentLayout(
                    id: clip.id,
                    trackID: track.id,
                    trackIndex: trackIdx,
                    clip: clip,
                    sourceStart: srcStart,
                    sourceEnd: srcStart + safeLen,
                    sourceDuration: probed,
                    duration: safeLen,
                    timelineStart: tStart,
                    timelineEnd: tStart + safeLen,
                    effectiveVolume: gain,
                    isTrimValid: valid,
                    loadError: durationErrors[clip.path]
                )
            }

            let trackEnd = builtSegments.map(\.timelineEnd).max() ?? 0
            builtAudioTracks.append(AudioTrackLayout(
                trackIndex: trackIdx,
                track: track,
                segments: builtSegments,
                endTime: trackEnd
            ))
        }

        var builtTextTracks: [TextTrackLayout] = []
        for (trackIdx, track) in timeline.textTracks.enumerated() {
            let sortedClips = track.clips.enumerated().sorted { lhs, rhs in
                if abs(lhs.element.timelineStart - rhs.element.timelineStart) > 1e-6 {
                    return lhs.element.timelineStart < rhs.element.timelineStart
                }
                return lhs.offset < rhs.offset
            }.map(\.element)

            let builtSegments: [TextSegmentLayout] = sortedClips.map { clip in
                let tStart = max(0, clip.timelineStart.isFinite ? clip.timelineStart : 0)
                let dur = max(TimelineLayout.minClipDuration, clip.duration.isFinite ? clip.duration : 3.0)
                return TextSegmentLayout(
                    id: clip.id,
                    trackID: track.id,
                    trackIndex: trackIdx,
                    clip: clip,
                    timelineStart: tStart,
                    timelineEnd: tStart + dur,
                    duration: dur
                )
            }

            let trackEnd = builtSegments.map(\.timelineEnd).max() ?? 0
            builtTextTracks.append(TextTrackLayout(
                trackIndex: trackIdx,
                track: track,
                segments: builtSegments,
                endTime: trackEnd
            ))
        }

        var builtShapeTracks: [ShapeTrackLayout] = []
        for (trackIdx, track) in timeline.shapeTracks.enumerated() {
            let sortedClips = track.clips.enumerated().sorted { lhs, rhs in
                if abs(lhs.element.timelineStart - rhs.element.timelineStart) > 1e-6 {
                    return lhs.element.timelineStart < rhs.element.timelineStart
                }
                return lhs.offset < rhs.offset
            }.map(\.element)

            let builtSegments: [ShapeSegmentLayout] = sortedClips.map { clip in
                let tStart = max(0, clip.timelineStart.isFinite ? clip.timelineStart : 0)
                let dur = max(TimelineLayout.minClipDuration, clip.duration.isFinite ? clip.duration : 3.0)
                return ShapeSegmentLayout(
                    id: clip.id,
                    trackID: track.id,
                    trackIndex: trackIdx,
                    clip: clip,
                    timelineStart: tStart,
                    timelineEnd: tStart + dur,
                    duration: dur
                )
            }
            let trackEnd = builtSegments.map(\.timelineEnd).max() ?? 0
            builtShapeTracks.append(ShapeTrackLayout(
                trackIndex: trackIdx,
                track: track,
                segments: builtSegments,
                endTime: trackEnd
            ))
        }

        let maxVideo = builtVideoTracks.map(\.endTime).max() ?? 0
        let maxAudio = builtAudioTracks.map(\.endTime).max() ?? 0
        let maxText = builtTextTracks.map(\.endTime).max() ?? 0
        let maxShape = builtShapeTracks.map(\.endTime).max() ?? 0

        self.videoTracks = builtVideoTracks
        self.audioTracks = builtAudioTracks
        self.textTracks = builtTextTracks
        self.shapeTracks = builtShapeTracks
        self.totalDuration = max(max(maxVideo, maxAudio), max(maxText, maxShape))
        self.hasTransitions = anyTransition
        self.hasInvalidTransitions = anyInvalidTransition
        self.isEmpty = builtVideoTracks.allSatisfy(\.segments.isEmpty)
            && builtAudioTracks.allSatisfy(\.segments.isEmpty)
            && builtTextTracks.allSatisfy(\.segments.isEmpty)
            && builtShapeTracks.allSatisfy(\.segments.isEmpty)
        self.outputWidth = max(64, outputWidth)
        self.outputHeight = max(64, outputHeight)
        self.outputFPS = max(12, min(60, outputFPS))
    }

    func sourceTime(for seg: VideoSegmentLayout, at timelineTime: Double) -> Double {
        if seg.clip.still {
            return min(seg.duration, max(0, timelineTime - seg.timelineStart))
        }
        if seg.clip.freezeFrame {
            if let maxDur = seg.sourceDuration, maxDur > 0 {
                return min(max(0, seg.sourceStart), max(0, maxDur - 0.002))
            }
            return max(0, seg.sourceStart)
        }
        let offset = min(seg.duration, max(0, timelineTime - seg.timelineStart))
        let safeSpeed = min(4.0, max(0.25, seg.clip.speed.isFinite ? seg.clip.speed : 1.0))
        var st = seg.clip.reversed
            ? max(seg.sourceStart, seg.sourceEnd - offset * safeSpeed)
            : (seg.sourceStart + offset * safeSpeed)
        if let maxDur = seg.sourceDuration, maxDur > 0 {
            st = min(max(0, st), max(0, maxDur - 0.002))
        }
        return max(0, st)
    }

    func makeTransitionCacheRequest(
        junction: TrackJunctionLayout,
        leading: VideoSegmentLayout,
        trailing: VideoSegmentLayout
    ) -> TransitionCacheRequest? {
        guard let tr = junction.transition, !junction.isCut, junction.isValid else { return nil }
        let dims = TransitionCacheRequest.previewDimensions(
            aspectWidth: outputWidth,
            aspectHeight: outputHeight,
            maxLongEdge: 640
        )
        let previewFPS = max(12, min(60, outputFPS))
        let dur = max(0.1, junction.overlapDuration)
        let leadingJSON = leading.clip.canonicalCacheJSON(
            sourceStart: leading.sourceStart,
            sourceEnd: leading.clip.freezeFrame ? leading.sourceStart : leading.sourceEnd,
            duration: leading.duration
        )
        let trailingJSON = trailing.clip.canonicalCacheJSON(
            sourceStart: trailing.sourceStart,
            sourceEnd: trailing.clip.freezeFrame ? trailing.sourceStart : trailing.sourceEnd,
            duration: trailing.duration
        )
        let cacheKey = TransitionCacheRequest.makeKey(
            cacheVersion: TransitionCacheRequest.currentCacheVersion,
            kind: tr.kind,
            duration: dur,
            leadingPath: leading.clip.path,
            trailingPath: trailing.clip.path,
            leadingClipPayloadJSON: leadingJSON,
            trailingClipPayloadJSON: trailingJSON,
            width: dims.width,
            height: dims.height,
            fps: previewFPS
        )
        return TransitionCacheRequest(
            key: cacheKey,
            cacheVersion: TransitionCacheRequest.currentCacheVersion,
            kind: tr.kind,
            duration: dur,
            leadingPath: leading.clip.path,
            trailingPath: trailing.clip.path,
            leadingClipPayloadJSON: leadingJSON,
            trailingClipPayloadJSON: trailingJSON,
            width: dims.width,
            height: dims.height,
            fps: previewFPS
        )
    }

    func allTransitionCacheRequests() -> [TransitionCacheRequest] {
        var requests: [TransitionCacheRequest] = []
        var seen = Set<String>()
        for vt in videoTracks {
            for j in vt.junctions where !j.isCut && j.isValid {
                guard let leading = vt.segments.first(where: { $0.id == j.afterID }),
                      let trailing = vt.segments.first(where: { $0.id == j.beforeID }),
                      let req = makeTransitionCacheRequest(junction: j, leading: leading, trailing: trailing) else {
                    continue
                }
                if seen.insert(req.key).inserted {
                    requests.append(req)
                }
            }
        }
        return requests
    }

    func makeClipEffectCacheRequest(segment: VideoSegmentLayout) -> ClipEffectCacheRequest? {
        let clip = segment.clip
        guard clip.needsProcessedClipPreview else { return nil }
        let dims = TransitionCacheRequest.previewDimensions(
            aspectWidth: outputWidth,
            aspectHeight: outputHeight,
            maxLongEdge: 640
        )
        let previewFPS = max(12, min(60, outputFPS))
        let needsAlpha = clip.chromaKeyEnabled
            || (clip.maskKind != "none" && !clip.maskKind.isEmpty)
            || (segment.trackIndex > 0 && abs(clip.rotation) > 0.01)
        let alphaMode: ClipEffectAlphaMode
        if clip.still || (clip.freezeFrame && needsAlpha) {
            alphaMode = .rgbaPNG
        } else if needsAlpha {
            alphaMode = .stackedAlphaMP4
        } else {
            alphaMode = .opaqueMP4
        }
        let payloadJSON = clip.canonicalClipEffectJSON(
            sourceStart: segment.sourceStart,
            sourceEnd: clip.freezeFrame ? segment.sourceStart : segment.sourceEnd,
            duration: segment.duration
        )
        return ClipEffectCacheRequest(
            cacheVersion: ClipEffectCacheRequest.currentCacheVersion,
            alphaMode: alphaMode,
            sourcePath: clip.path,
            clipPayloadJSON: payloadJSON,
            duration: segment.duration,
            width: dims.width,
            height: dims.height,
            fps: previewFPS
        )
    }

    func allClipEffectCacheRequests() -> [ClipEffectCacheRequest] {
        var requests: [ClipEffectCacheRequest] = []
        var seen = Set<String>()
        for vt in videoTracks where !vt.track.hidden {
            for seg in vt.segments {
                guard let req = makeClipEffectCacheRequest(segment: seg) else { continue }
                if seen.insert(req.key).inserted {
                    requests.append(req)
                }
            }
        }
        return requests
    }

    func snapPoints(playhead: Double, excludingClipID: UUID? = nil) -> [Double] {
        var points: [Double] = [0.0, max(0, playhead)]
        for vt in videoTracks {
            for seg in vt.segments where seg.id != excludingClipID {
                points.append(seg.timelineStart)
                points.append(seg.timelineEnd)
            }
        }
        for at in audioTracks {
            for seg in at.segments where seg.id != excludingClipID {
                points.append(seg.timelineStart)
                points.append(seg.timelineEnd)
            }
        }
        for tt in textTracks {
            for seg in tt.segments where seg.id != excludingClipID {
                points.append(seg.timelineStart)
                points.append(seg.timelineEnd)
            }
        }
        points.sort()
        var unique: [Double] = []
        for p in points {
            if let last = unique.last, abs(last - p) < 1e-4 { continue }
            unique.append(p)
        }
        return unique
    }

    func snap(
        time: Double,
        playhead: Double,
        thresholdSeconds: Double,
        excludingClipID: UUID? = nil
    ) -> (snapped: Double, guideTime: Double?) {
        let clamped = max(0, time)
        let candidates = snapPoints(playhead: playhead, excludingClipID: excludingClipID)
        var best: Double?
        var bestDist = thresholdSeconds
        for pt in candidates {
            let d = abs(pt - clamped)
            if d <= bestDist {
                bestDist = d
                best = pt
            }
        }
        if let best {
            return (best, best)
        }
        return (clamped, nil)
    }

    /// Returns visible video layers ordered bottom-to-top (V1 at index 0, V2 above V1, ...).
    /// Inside any non-cut transition overlap, fills BOTH leading (`segment`/`sourceTime`) AND trailing
    /// (`transitionTrailingSegment`/`transitionTrailingSourceTime`) plus `transitionCacheRequest` for
    /// real FFmpeg `xfade` cache playback and live 14-transition compositing.
    func activeVideoLayers(at rawTime: Double) -> [ActiveVideoLayer] {
        guard totalDuration > 0 else { return [] }
        let t = min(totalDuration, max(0, rawTime.isFinite ? rawTime : 0))
        let atExactEnd = t >= totalDuration - 1e-4
        var layers: [ActiveVideoLayer] = []

        for vt in videoTracks where !vt.track.hidden {
            var activeJunction: TrackJunctionLayout?
            var transitionLocalTime = 0.0
            var transitionProgress = 0.0
            for j in vt.junctions where !j.isCut {
                if t >= j.overlapStart - 1e-6 && t <= j.overlapEnd + 1e-6 {
                    activeJunction = j
                    transitionLocalTime = min(j.overlapDuration, max(0, t - j.overlapStart))
                    transitionProgress = min(1, max(0, transitionLocalTime / max(0.001, j.overlapDuration)))
                    break
                }
            }

            if let j = activeJunction,
               let leading = vt.segments.first(where: { $0.id == j.afterID }),
               let trailing = vt.segments.first(where: { $0.id == j.beforeID }) {
                let leadTime = sourceTime(for: leading, at: t)
                let trailTime = sourceTime(for: trailing, at: t)
                let cacheReq = makeTransitionCacheRequest(junction: j, leading: leading, trailing: trailing)
                let effectiveOpacity = min(1.0, max(0.0, leading.clip.opacity))

                layers.append(ActiveVideoLayer(
                    trackIndex: vt.trackIndex,
                    trackID: vt.track.id,
                    trackMuted: vt.track.muted,
                    segment: leading,
                    sourceTime: leadTime,
                    activeJunction: j,
                    transitionProgress: transitionProgress,
                    effectiveOpacity: effectiveOpacity,
                    fadeOverlayColor: nil,
                    fadeOverlayOpacity: 0.0,
                    transitionTrailingSegment: trailing,
                    transitionTrailingSourceTime: trailTime,
                    transitionCacheRequest: cacheReq,
                    transitionLocalTime: transitionLocalTime,
                    clipEffectCacheRequest: nil,
                    clipLocalTime: min(leading.duration, max(0, t - leading.timelineStart))
                ))
                continue
            }

            let chosenSegment = vt.segments.last(where: { seg in
                if atExactEnd && seg.timelineEnd >= totalDuration - 1e-3 {
                    return t >= seg.timelineStart - 1e-6 && t <= seg.timelineEnd + 1e-4
                }
                return t >= seg.timelineStart - 1e-6 && t < seg.timelineEnd - 1e-6
            })

            guard let seg = chosenSegment else { continue }
            let st = sourceTime(for: seg, at: t)
            let effectiveOpacity = min(1.0, max(0.0, seg.clip.opacity))
            let effectReq = makeClipEffectCacheRequest(segment: seg)
            let localClipTime = min(seg.duration, max(0, t - seg.timelineStart))

            layers.append(ActiveVideoLayer(
                trackIndex: vt.trackIndex,
                trackID: vt.track.id,
                trackMuted: vt.track.muted,
                segment: seg,
                sourceTime: st,
                activeJunction: nil,
                transitionProgress: 0.0,
                effectiveOpacity: effectiveOpacity,
                fadeOverlayColor: nil,
                fadeOverlayOpacity: 0.0,
                transitionTrailingSegment: nil,
                transitionTrailingSourceTime: nil,
                transitionCacheRequest: nil,
                transitionLocalTime: 0.0,
                clipEffectCacheRequest: effectReq,
                clipLocalTime: localClipTime
            ))
        }

        return layers
    }

    func activeTextClips(at rawTime: Double) -> [TextSegmentLayout] {
        guard totalDuration > 0 else { return [] }
        let t = min(totalDuration, max(0, rawTime.isFinite ? rawTime : 0))
        let atExactEnd = t >= totalDuration - 1e-4
        var result: [TextSegmentLayout] = []

        for tt in textTracks where !tt.track.hidden {
            for seg in tt.segments {
                let inside = (atExactEnd && seg.timelineEnd >= totalDuration - 1e-3)
                    ? (t >= seg.timelineStart - 1e-6 && t <= seg.timelineEnd + 1e-4)
                    : (t >= seg.timelineStart - 1e-6 && t < seg.timelineEnd - 1e-6)
                if inside {
                    result.append(seg)
                }
            }
        }
        return result
    }

    func activeAudioClips(at rawTime: Double) -> [ActiveAudioLayer] {
        guard totalDuration > 0 else { return [] }
        let t = min(totalDuration, max(0, rawTime.isFinite ? rawTime : 0))
        var result: [ActiveAudioLayer] = []

        for at in audioTracks where !at.track.muted {
            for seg in at.segments where !seg.clip.muted && seg.effectiveVolume > 0 {
                guard t >= seg.timelineStart - 1e-6 && t < seg.timelineEnd - 1e-6 else { continue }
                let localTime = max(0, t - seg.timelineStart)
                let remaining = max(0, seg.timelineEnd - t)

                var fadeFactor = 1.0
                if seg.clip.fadeIn > 0.001 && localTime < seg.clip.fadeIn {
                    fadeFactor = min(fadeFactor, max(0, localTime / seg.clip.fadeIn))
                }
                if seg.clip.fadeOut > 0.001 && remaining < seg.clip.fadeOut {
                    fadeFactor = min(fadeFactor, max(0, remaining / seg.clip.fadeOut))
                }

                var sourceTime = seg.sourceStart + localTime
                if let maxDur = seg.sourceDuration, maxDur > 0 {
                    sourceTime = min(max(0, sourceTime), max(0, maxDur - 0.002))
                }
                let gain = Float(min(2.0, max(0.0, seg.effectiveVolume * fadeFactor)))
                result.append(ActiveAudioLayer(
                    trackID: at.track.id,
                    segment: seg,
                    sourceTime: sourceTime,
                    currentGain: gain
                ))
            }
        }
        return result
    }

    func videoSegment(trackID: UUID, clipID: UUID) -> VideoSegmentLayout? {
        videoTracks.first(where: { $0.id == trackID })?.segments.first(where: { $0.id == clipID })
    }

    func audioSegment(trackID: UUID, clipID: UUID) -> AudioSegmentLayout? {
        audioTracks.first(where: { $0.id == trackID })?.segments.first(where: { $0.id == clipID })
    }

    func textSegment(trackID: UUID, clipID: UUID) -> TextSegmentLayout? {
        textTracks.first(where: { $0.id == trackID })?.segments.first(where: { $0.id == clipID })
    }

    func activeShapeClips(at rawTime: Double) -> [ShapeSegmentLayout] {
        guard totalDuration > 0 else { return [] }
        let t = min(totalDuration, max(0, rawTime.isFinite ? rawTime : 0))
        let atExactEnd = t >= totalDuration - 1e-4
        var result: [ShapeSegmentLayout] = []
        for st in shapeTracks where !st.track.hidden {
            for seg in st.segments {
                let inside = (atExactEnd && seg.timelineEnd >= totalDuration - 1e-3)
                    ? (t >= seg.timelineStart - 1e-6 && t <= seg.timelineEnd + 1e-4)
                    : (t >= seg.timelineStart - 1e-6 && t < seg.timelineEnd - 1e-6)
                if inside {
                    result.append(seg)
                }
            }
        }
        return result
    }

    func shapeSegment(trackID: UUID, clipID: UUID) -> ShapeSegmentLayout? {
        shapeTracks.first(where: { $0.id == trackID })?.segments.first(where: { $0.id == clipID })
    }

    func junction(trackID: UUID, afterID: UUID, beforeID: UUID) -> TrackJunctionLayout? {
        videoTracks.first(where: { $0.id == trackID })?
            .junctions.first(where: { $0.afterID == afterID && $0.beforeID == beforeID })
    }
}

// MARK: - Multitrack Real-Time Playback Controller

@MainActor final class MultitrackPlaybackController: ObservableObject {
    @Published var playhead: Double = 0
    @Published var isPlaying: Bool = false
    @Published var activeVideoLayers: [ActiveVideoLayer] = []
    @Published var activeTextClips: [TextSegmentLayout] = []
    @Published var activeShapeClips: [ShapeSegmentLayout] = []
    @Published var activeAudioLayers: [ActiveAudioLayer] = []
    @Published var stillImages: [String: NSImage] = [:]
    @Published var playbackError: String? = nil
    @Published var playbackNeedsPermission: Bool = false
    @Published var missingPaths: Set<String> = []

    @MainActor private final class PlayerSlot {
        let player = AVPlayer()
        var loadedPath: String?
        var syncedClipID: UUID?
        var itemReady = false
        var isSeeking = false
        var queuedSeek: (time: Double, exact: Bool)?
        var desiredSourceTime: Double = 0
        var desiredExactSeek = true
        var desiredPlayRate: Float = 1.0
        var shouldStayPaused = false
        var statusObserver: NSKeyValueObservation?
        var itemError: String?

        init() {
            player.actionAtItemEnd = .pause
        }

        func tearDown() {
            player.pause()
            statusObserver = nil
            itemReady = false
            isSeeking = false
            queuedSeek = nil
            loadedPath = nil
            syncedClipID = nil
            desiredPlayRate = 1.0
            shouldStayPaused = false
            itemError = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    private var layout: MultitrackLayout = .empty
    private var videoSlots: [UUID: PlayerSlot] = [:]
    private var secondaryVideoSlots: [UUID: PlayerSlot] = [:]
    private var audioSlots: [UUID: PlayerSlot] = [:]
    private var assetCache: [String: AVURLAsset] = [:]
    private var imageCache: [String: NSImage] = [:]
    private var playbackTimer: Timer?
    private var lastWallTime: CFTimeInterval = 0

    func player(forVideoTrackID trackID: UUID) -> AVPlayer {
        slot(forVideoTrackID: trackID).player
    }

    func secondaryPlayer(forVideoTrackID trackID: UUID) -> AVPlayer {
        secondarySlot(forVideoTrackID: trackID).player
    }

    private func slot(forVideoTrackID trackID: UUID) -> PlayerSlot {
        if let existing = videoSlots[trackID] { return existing }
        let created = PlayerSlot()
        videoSlots[trackID] = created
        return created
    }

    private func secondarySlot(forVideoTrackID trackID: UUID) -> PlayerSlot {
        if let existing = secondaryVideoSlots[trackID] { return existing }
        let created = PlayerSlot()
        created.player.isMuted = true
        created.player.volume = 0
        secondaryVideoSlots[trackID] = created
        return created
    }

    private func slot(forAudioTrackID trackID: UUID) -> PlayerSlot {
        if let existing = audioSlots[trackID] { return existing }
        let created = PlayerSlot()
        audioSlots[trackID] = created
        return created
    }

    func syncLayout(_ newLayout: MultitrackLayout) {
        let oldDuration = layout.totalDuration
        layout = newLayout

        // Clean up slots for deleted tracks.
        let validVideoIDs = Set(newLayout.videoTracks.map(\.id))
        for (id, slot) in videoSlots where !validVideoIDs.contains(id) {
            slot.tearDown()
            videoSlots.removeValue(forKey: id)
        }
        for (id, slot) in secondaryVideoSlots where !validVideoIDs.contains(id) {
            slot.tearDown()
            secondaryVideoSlots.removeValue(forKey: id)
        }
        let validAudioIDs = Set(newLayout.audioTracks.map(\.id))
        for (id, slot) in audioSlots where !validAudioIDs.contains(id) {
            slot.tearDown()
            audioSlots.removeValue(forKey: id)
        }

        // Pre-warm real FFmpeg xfade transition preview caches & processed clip effect caches (~0.15s each).
        for req in newLayout.allTransitionCacheRequests() {
            TransitionPreviewCache.shared.ensureCached(req)
        }
        for fxReq in newLayout.allClipEffectCacheRequests() {
            ClipEffectPreviewCache.shared.ensureCached(fxReq)
        }

        if newLayout.isEmpty || newLayout.totalDuration <= 0 {
            pause()
            playhead = 0
            activeVideoLayers = []
            activeTextClips = []
            activeShapeClips = []
            activeAudioLayers = []
            playbackError = nil
            playbackNeedsPermission = false
            missingPaths = []
            for slot in videoSlots.values { slot.tearDown() }
            for slot in secondaryVideoSlots.values { slot.tearDown() }
            for slot in audioSlots.values { slot.tearDown() }
            TransitionPreviewCache.shared.pauseAll(except: [])
            ClipEffectPreviewCache.shared.pauseAll(except: [])
            return
        }

        let clamped = min(newLayout.totalDuration, max(0, playhead))
        let changed = abs(clamped - playhead) > 1e-6 || abs(oldDuration - newLayout.totalDuration) > 1e-6
        playhead = clamped
        if !isPlaying {
            applyFrame(at: playhead, exact: true, forceReload: changed)
        } else {
            refreshPublishedSamples(at: playhead)
        }
    }

    func reloadAllMedia() {
        assetCache.removeAll()
        imageCache.removeAll()
        stillImages.removeAll()
        for slot in videoSlots.values { slot.tearDown() }
        for slot in secondaryVideoSlots.values { slot.tearDown() }
        for slot in audioSlots.values { slot.tearDown() }
        playbackError = nil
        playbackNeedsPermission = false
        missingPaths = []
        applyFrame(at: playhead, exact: true, forceReload: true)
    }

    func seek(to time: Double, exact: Bool = true) {
        guard !layout.isEmpty, layout.totalDuration > 0 else {
            playhead = 0
            activeVideoLayers = []
            activeTextClips = []
            activeShapeClips = []
            activeAudioLayers = []
            return
        }
        let clamped = min(layout.totalDuration, max(0, time.isFinite ? time : 0))
        playhead = clamped
        applyFrame(at: clamped, exact: exact, forceReload: false)
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard !layout.isEmpty, layout.totalDuration > 0 else { return }
        if playhead >= layout.totalDuration - (1.0 / 48.0) {
            playhead = 0
        }
        isPlaying = true
        lastWallTime = CACurrentMediaTime()
        syncActiveSlotsForPlayback(at: playhead, forceSeek: true)
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
        for slot in videoSlots.values { slot.player.pause() }
        for slot in secondaryVideoSlots.values { slot.player.pause() }
        for slot in audioSlots.values { slot.player.pause() }
        TransitionPreviewCache.shared.pauseAll(except: [])
        ClipEffectPreviewCache.shared.pauseAll(except: [])
    }

    func stepFrames(_ count: Int) {
        pause()
        let fps = Double(max(12, layout.outputFPS))
        seek(to: playhead + Double(count) / fps, exact: true)
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
        for slot in videoSlots.values { slot.tearDown() }
        for slot in secondaryVideoSlots.values { slot.tearDown() }
        for slot in audioSlots.values { slot.tearDown() }
        videoSlots.removeAll()
        secondaryVideoSlots.removeAll()
        audioSlots.removeAll()
        assetCache.removeAll()
        imageCache.removeAll()
        stillImages.removeAll()
    }

    private func refreshPublishedSamples(at time: Double) {
        activeVideoLayers = layout.activeVideoLayers(at: time)
        activeTextClips = layout.activeTextClips(at: time)
        activeShapeClips = layout.activeShapeClips(at: time)
        activeAudioLayers = layout.activeAudioClips(at: time)
    }

    private func tick() {
        guard isPlaying, !layout.isEmpty, layout.totalDuration > 0 else {
            pause()
            return
        }
        if playbackError != nil {
            pause()
            return
        }

        // Wait if any active non-still video track slot hasn't reached readyToPlay yet (never advance over black screen).
        for layer in activeVideoLayers where !layer.segment.clip.still && !layer.segment.clip.freezeFrame {
            if let req = layer.transitionCacheRequest,
               TransitionPreviewCache.shared.isPlayerReadyForDisplay(key: req.key) {
                continue
            }
            if let fxReq = layer.clipEffectCacheRequest,
               ClipEffectPreviewCache.shared.isReadyForDisplay(req: fxReq) {
                continue
            }
            let slot = slot(forVideoTrackID: layer.trackID)
            if slot.loadedPath == layer.segment.clip.path && !slot.itemReady {
                lastWallTime = CACurrentMediaTime()
                return
            }
        }

        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastWallTime))
        lastWallTime = now

        let nextTime = playhead + dt
        if nextTime >= layout.totalDuration {
            playhead = layout.totalDuration
            pause()
            applyFrame(at: playhead, exact: true, forceReload: false)
            return
        }

        playhead = nextTime
        syncActiveSlotsForPlayback(at: nextTime, forceSeek: false)
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
                return (false, true, false, "找不到素材檔案：\(filename(path))")
            }
            return (false, false, false, "無法讀取 \(filename(path))：\(err.localizedDescription)")
        }
    }

    private func loadStillImage(path: String) -> NSImage? {
        if let cached = imageCache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        if imageCache.count > 32 { imageCache.removeAll() }
        imageCache[path] = image
        return image
    }

    private func ensureSlotLoaded(_ slot: PlayerSlot, path: String, forceReload: Bool) {
        guard forceReload || slot.loadedPath != path || slot.player.currentItem == nil else { return }
        let asset: AVURLAsset
        if !forceReload, let cached = assetCache[path] {
            asset = cached
        } else {
            let created = AVURLAsset(
                url: URL(fileURLWithPath: path),
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            if assetCache.count > 32 { assetCache.removeAll() }
            assetCache[path] = created
            asset = created
        }
        let item = AVPlayerItem(asset: asset)
        slot.itemReady = false
        slot.isSeeking = false
        slot.queuedSeek = nil
        slot.itemError = nil
        slot.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak slot] observedItem, _ in
            let status = observedItem.status
            let errDesc = observedItem.error?.localizedDescription
            Task { @MainActor in
                guard let self, let slot, slot.player.currentItem === observedItem else { return }
                switch status {
                case .readyToPlay:
                    slot.itemReady = true
                    slot.itemError = nil
                    let target = slot.desiredSourceTime
                    if self.isPlaying && !slot.shouldStayPaused {
                        let cm = CMTime(seconds: max(0, target), preferredTimescale: 600)
                        slot.player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak slot] _ in
                            Task { @MainActor in
                                guard let self, let slot, self.isPlaying, !slot.shouldStayPaused else { return }
                                slot.player.rate = slot.desiredPlayRate
                            }
                        }
                    } else {
                        self.requestSlotSeek(slot, to: target, exact: slot.desiredExactSeek)
                    }
                case .failed:
                    slot.itemReady = false
                    slot.itemError = "無法載入媒體預覽：\(errDesc ?? filename(path))"
                    self.playbackError = slot.itemError
                    self.pause()
                default:
                    break
                }
            }
        }
        slot.player.replaceCurrentItem(with: item)
        slot.loadedPath = path
    }

    private func requestSlotSeek(_ slot: PlayerSlot, to seconds: Double, exact: Bool) {
        guard slot.itemReady else {
            slot.desiredSourceTime = seconds
            slot.desiredExactSeek = exact
            return
        }
        if slot.isSeeking {
            slot.queuedSeek = (seconds, exact)
            return
        }
        slot.isSeeking = true
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance: CMTime = exact ? .zero : CMTime(seconds: 0.04, preferredTimescale: 600)
        slot.player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak slot] _ in
            Task { @MainActor in
                guard let self, let slot else { return }
                slot.isSeeking = false
                if let next = slot.queuedSeek {
                    slot.queuedSeek = nil
                    self.requestSlotSeek(slot, to: next.time, exact: next.exact)
                }
            }
        }
    }

    private func syncVideoSlotStatic(
        _ s: PlayerSlot,
        seg: VideoSegmentLayout,
        sourceTime: Double,
        muted: Bool,
        exact: Bool,
        forceReload: Bool,
        firstError: inout String?,
        needsPerm: inout Bool,
        missing: inout Set<String>
    ) {
        let path = seg.clip.path
        let access = verifyReadable(path: path)
        if !access.ok {
            if access.missing { missing.insert(path) }
            if access.permissionDenied { needsPerm = true }
            if firstError == nil { firstError = access.message }
            s.player.pause()
            return
        }
        if seg.clip.still {
            s.player.pause()
            s.syncedClipID = seg.id
            s.shouldStayPaused = true
            if let img = loadStillImage(path: path) {
                stillImages[path] = img
            } else if firstError == nil {
                firstError = "無法解碼圖片：\(filename(path))"
            }
        } else {
            s.syncedClipID = seg.id
            s.desiredSourceTime = max(0, sourceTime)
            s.desiredExactSeek = exact
            s.shouldStayPaused = true
            s.player.isMuted = muted
            s.player.volume = muted ? 0 : Float(min(2.0, max(0.0, seg.clip.volume)))
            ensureSlotLoaded(s, path: path, forceReload: forceReload)
            s.player.pause()
            if s.itemReady {
                requestSlotSeek(s, to: s.desiredSourceTime, exact: exact)
            }
        }
    }

    private func syncVideoSlotPlaying(
        _ s: PlayerSlot,
        seg: VideoSegmentLayout,
        sourceTime: Double,
        muted: Bool,
        forceSeek: Bool,
        firstError: inout String?,
        needsPerm: inout Bool,
        missing: inout Set<String>
    ) {
        let path = seg.clip.path
        let access = verifyReadable(path: path)
        if !access.ok {
            if access.missing { missing.insert(path) }
            if access.permissionDenied { needsPerm = true }
            if firstError == nil { firstError = access.message }
            return
        }
        if seg.clip.still {
            s.player.pause()
            s.syncedClipID = seg.id
            s.shouldStayPaused = true
            if let img = loadStillImage(path: path) {
                stillImages[path] = img
            } else if firstError == nil {
                firstError = "無法解碼圖片：\(filename(path))"
            }
            return
        }

        let clipChanged = s.syncedClipID != seg.id || s.loadedPath != path
        let stayPaused = seg.clip.freezeFrame || seg.clip.reversed
        let targetRate = Float(min(4.0, max(0.25, seg.clip.speed.isFinite ? seg.clip.speed : 1.0)))

        s.syncedClipID = seg.id
        s.desiredSourceTime = max(0, sourceTime)
        s.desiredExactSeek = true
        s.desiredPlayRate = targetRate
        s.shouldStayPaused = stayPaused
        s.player.isMuted = muted || stayPaused
        s.player.volume = (muted || stayPaused) ? 0 : Float(min(2.0, max(0.0, seg.clip.volume)))
        ensureSlotLoaded(s, path: path, forceReload: false)

        if s.itemReady {
            if seg.clip.freezeFrame {
                if s.player.rate != 0 { s.player.pause() }
                let currentSec = s.player.currentTime().seconds
                if forceSeek || clipChanged || !currentSec.isFinite || abs(currentSec - sourceTime) > 0.05 {
                    requestSlotSeek(s, to: sourceTime, exact: true)
                }
            } else if seg.clip.reversed {
                if s.player.rate != 0 { s.player.pause() }
                requestSlotSeek(s, to: sourceTime, exact: false)
            } else {
                let currentSec = s.player.currentTime().seconds
                let drift = currentSec.isFinite ? abs(currentSec - sourceTime) : 999
                if forceSeek || clipChanged || drift > 0.28 {
                    let cm = CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)
                    s.player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak s] _ in
                        Task { @MainActor in
                            guard let self, let s, self.isPlaying, !s.shouldStayPaused, s.syncedClipID == seg.id else { return }
                            s.player.rate = targetRate
                        }
                    }
                } else if abs(s.player.rate - targetRate) > 0.01 {
                    s.player.rate = targetRate
                }
            }
        }
    }

    private func applyFrame(at time: Double, exact: Bool, forceReload: Bool) {
        refreshPublishedSamples(at: time)
        var firstError: String?
        var needsPerm = false
        var missing: Set<String> = []
        var activeTransitionKeys = Set<String>()
        var activeClipEffectKeys = Set<String>()

        let activeVideoTrackIDs = Set(activeVideoLayers.map(\.trackID))
        for (trackID, slot) in videoSlots where !activeVideoTrackIDs.contains(trackID) {
            slot.player.pause()
            slot.syncedClipID = nil
        }
        for (trackID, slot) in secondaryVideoSlots where !activeVideoTrackIDs.contains(trackID) {
            slot.player.pause()
            slot.syncedClipID = nil
        }

        for layer in activeVideoLayers {
            if let req = layer.transitionCacheRequest {
                TransitionPreviewCache.shared.ensureCached(req)
                if TransitionPreviewCache.shared.readyURLs[req.key] != nil {
                    activeTransitionKeys.insert(req.key)
                    TransitionPreviewCache.shared.sync(
                        key: req.key,
                        localSeconds: layer.transitionLocalTime,
                        isPlaying: false,
                        exact: exact,
                        fps: layout.outputFPS
                    )
                    if TransitionPreviewCache.shared.isPlayerReadyForDisplay(key: req.key) {
                        slot(forVideoTrackID: layer.trackID).player.pause()
                        secondaryVideoSlots[layer.trackID]?.player.pause()
                        continue
                    }
                }
            } else if let fxReq = layer.clipEffectCacheRequest {
                ClipEffectPreviewCache.shared.ensureCached(fxReq)
                activeClipEffectKeys.insert(fxReq.key)
                ClipEffectPreviewCache.shared.sync(
                    req: fxReq,
                    localSeconds: layer.clipLocalTime,
                    isPlaying: false,
                    exact: exact
                )
                if ClipEffectPreviewCache.shared.isReadyForDisplay(req: fxReq) {
                    slot(forVideoTrackID: layer.trackID).player.pause()
                    secondaryVideoSlots[layer.trackID]?.player.pause()
                    continue
                }
            }

            let primaryMuted = layer.trackMuted || layer.segment.clip.muted
            syncVideoSlotStatic(
                slot(forVideoTrackID: layer.trackID),
                seg: layer.segment,
                sourceTime: layer.sourceTime,
                muted: primaryMuted,
                exact: exact,
                forceReload: forceReload,
                firstError: &firstError,
                needsPerm: &needsPerm,
                missing: &missing
            )

            if let trailingSeg = layer.transitionTrailingSegment,
               let trailingTime = layer.transitionTrailingSourceTime {
                syncVideoSlotStatic(
                    secondarySlot(forVideoTrackID: layer.trackID),
                    seg: trailingSeg,
                    sourceTime: trailingTime,
                    muted: true,
                    exact: exact,
                    forceReload: forceReload,
                    firstError: &firstError,
                    needsPerm: &needsPerm,
                    missing: &missing
                )
            } else {
                secondaryVideoSlots[layer.trackID]?.player.pause()
                secondaryVideoSlots[layer.trackID]?.syncedClipID = nil
            }
        }

        TransitionPreviewCache.shared.pauseAll(except: activeTransitionKeys)
        ClipEffectPreviewCache.shared.pauseAll(except: activeClipEffectKeys)

        let activeAudioTrackIDs = Set(activeAudioLayers.map(\.trackID))
        for (trackID, slot) in audioSlots where !activeAudioTrackIDs.contains(trackID) {
            slot.player.pause()
            slot.syncedClipID = nil
        }

        for aLayer in activeAudioLayers {
            let path = aLayer.segment.clip.path
            let access = verifyReadable(path: path)
            if !access.ok {
                if access.missing { missing.insert(path) }
                if access.permissionDenied { needsPerm = true }
                if firstError == nil { firstError = access.message }
                slot(forAudioTrackID: aLayer.trackID).player.pause()
                continue
            }
            let s = slot(forAudioTrackID: aLayer.trackID)
            s.syncedClipID = aLayer.segment.id
            s.desiredSourceTime = max(0, aLayer.sourceTime)
            s.desiredExactSeek = exact
            s.shouldStayPaused = true
            s.player.isMuted = aLayer.currentGain <= 0.0001
            s.player.volume = aLayer.currentGain
            ensureSlotLoaded(s, path: path, forceReload: forceReload)
            s.player.pause()
            if s.itemReady {
                requestSlotSeek(s, to: s.desiredSourceTime, exact: exact)
            }
        }

        missingPaths = missing
        playbackNeedsPermission = needsPerm
        playbackError = firstError
    }

    private func syncActiveSlotsForPlayback(at time: Double, forceSeek: Bool) {
        refreshPublishedSamples(at: time)
        var firstError: String?
        var needsPerm = false
        var missing: Set<String> = []
        var activeTransitionKeys = Set<String>()
        var activeClipEffectKeys = Set<String>()

        let activeVideoTrackIDs = Set(activeVideoLayers.map(\.trackID))
        for (trackID, slot) in videoSlots where !activeVideoTrackIDs.contains(trackID) {
            slot.player.pause()
            slot.syncedClipID = nil
        }
        for (trackID, slot) in secondaryVideoSlots where !activeVideoTrackIDs.contains(trackID) {
            slot.player.pause()
            slot.syncedClipID = nil
        }

        for layer in activeVideoLayers {
            if let req = layer.transitionCacheRequest {
                TransitionPreviewCache.shared.ensureCached(req)
                if TransitionPreviewCache.shared.readyURLs[req.key] != nil {
                    activeTransitionKeys.insert(req.key)
                    TransitionPreviewCache.shared.sync(
                        key: req.key,
                        localSeconds: layer.transitionLocalTime,
                        isPlaying: true,
                        exact: forceSeek,
                        fps: layout.outputFPS
                    )
                    if TransitionPreviewCache.shared.isPlayerReadyForDisplay(key: req.key) {
                        let primaryMuted = layer.trackMuted || layer.segment.clip.muted
                        if !primaryMuted && !layer.segment.clip.still && !layer.segment.clip.freezeFrame {
                            // Keep primary audio flowing seamlessly across the transition overlap.
                            syncVideoSlotPlaying(
                                slot(forVideoTrackID: layer.trackID),
                                seg: layer.segment,
                                sourceTime: layer.sourceTime,
                                muted: false,
                                forceSeek: forceSeek,
                                firstError: &firstError,
                                needsPerm: &needsPerm,
                                missing: &missing
                            )
                        } else {
                            slot(forVideoTrackID: layer.trackID).player.pause()
                        }
                        secondaryVideoSlots[layer.trackID]?.player.pause()
                        continue
                    }
                }
            } else if let fxReq = layer.clipEffectCacheRequest {
                ClipEffectPreviewCache.shared.ensureCached(fxReq)
                activeClipEffectKeys.insert(fxReq.key)
                ClipEffectPreviewCache.shared.sync(
                    req: fxReq,
                    localSeconds: layer.clipLocalTime,
                    isPlaying: true,
                    exact: forceSeek
                )
                if ClipEffectPreviewCache.shared.isReadyForDisplay(req: fxReq) {
                    let primaryMuted = layer.trackMuted || layer.segment.clip.muted
                    if !primaryMuted && !layer.segment.clip.still && !layer.segment.clip.freezeFrame && !layer.segment.clip.reversed {
                        // Keep clip audio flowing while displaying processed same-source video.
                        syncVideoSlotPlaying(
                            slot(forVideoTrackID: layer.trackID),
                            seg: layer.segment,
                            sourceTime: layer.sourceTime,
                            muted: false,
                            forceSeek: forceSeek,
                            firstError: &firstError,
                            needsPerm: &needsPerm,
                            missing: &missing
                        )
                    } else {
                        slot(forVideoTrackID: layer.trackID).player.pause()
                    }
                    secondaryVideoSlots[layer.trackID]?.player.pause()
                    continue
                }
            }

            let primaryMuted = layer.trackMuted || layer.segment.clip.muted
            syncVideoSlotPlaying(
                slot(forVideoTrackID: layer.trackID),
                seg: layer.segment,
                sourceTime: layer.sourceTime,
                muted: primaryMuted,
                forceSeek: forceSeek,
                firstError: &firstError,
                needsPerm: &needsPerm,
                missing: &missing
            )

            if let trailingSeg = layer.transitionTrailingSegment,
               let trailingTime = layer.transitionTrailingSourceTime {
                syncVideoSlotPlaying(
                    secondarySlot(forVideoTrackID: layer.trackID),
                    seg: trailingSeg,
                    sourceTime: trailingTime,
                    muted: true,
                    forceSeek: forceSeek,
                    firstError: &firstError,
                    needsPerm: &needsPerm,
                    missing: &missing
                )
            } else {
                secondaryVideoSlots[layer.trackID]?.player.pause()
                secondaryVideoSlots[layer.trackID]?.syncedClipID = nil
            }
        }

        TransitionPreviewCache.shared.pauseAll(except: activeTransitionKeys)
        ClipEffectPreviewCache.shared.pauseAll(except: activeClipEffectKeys)

        let activeAudioTrackIDs = Set(activeAudioLayers.map(\.trackID))
        for (trackID, slot) in audioSlots where !activeAudioTrackIDs.contains(trackID) {
            slot.player.pause()
            slot.syncedClipID = nil
        }

        for aLayer in activeAudioLayers {
            let path = aLayer.segment.clip.path
            let access = verifyReadable(path: path)
            if !access.ok {
                if access.missing { missing.insert(path) }
                if access.permissionDenied { needsPerm = true }
                if firstError == nil { firstError = access.message }
                continue
            }
            let s = slot(forAudioTrackID: aLayer.trackID)
            let clipChanged = s.syncedClipID != aLayer.segment.id || s.loadedPath != path
            s.syncedClipID = aLayer.segment.id
            s.desiredSourceTime = max(0, aLayer.sourceTime)
            s.desiredExactSeek = true
            s.desiredPlayRate = 1.0
            s.shouldStayPaused = false
            s.player.isMuted = aLayer.currentGain <= 0.0001
            s.player.volume = aLayer.currentGain
            ensureSlotLoaded(s, path: path, forceReload: false)
            if s.itemReady {
                let currentSec = s.player.currentTime().seconds
                let drift = currentSec.isFinite ? abs(currentSec - aLayer.sourceTime) : 999
                if forceSeek || clipChanged || drift > 0.25 {
                    let cm = CMTime(seconds: max(0, aLayer.sourceTime), preferredTimescale: 600)
                    s.player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak s] _ in
                        Task { @MainActor in
                            guard let self, let s, self.isPlaying, s.syncedClipID == aLayer.segment.id else { return }
                            s.player.play()
                        }
                    }
                } else if s.player.rate == 0 {
                    s.player.play()
                }
            }
        }

        missingPaths = missing
        playbackNeedsPermission = needsPerm
        if let firstError {
            playbackError = firstError
            pause()
        }
    }
}

// MARK: - Studio Multitrack Extension

extension Studio {
    /// Non-destructive view of the active multitrack timeline (migrates legacy 0.1.19 clips in memory if `project.multitrack == nil`).
    var activeMultitrack: MultitrackTimeline {
        if let existing = project.multitrack {
            return existing
        }
        return MultitrackTimeline.migrateFromLegacy(
            clips: project.clips,
            transitions: project.editTransitions,
            durations: timelineDurations
        )
    }

    func currentMultitrackLayout() -> MultitrackLayout {
        let dims: (width: Int, height: Int) = {
            if let pixels = timelineOutput.dimensions?.pixels,
               let w = pixels["width"], let h = pixels["height"], w > 0, h > 0 {
                return (w, h)
            }
            switch timelineOutput.aspect {
            case "9:16": return (1080, 1920)
            case "1:1": return (1080, 1080)
            default: return (1920, 1080)
            }
        }()
        return MultitrackLayout(
            timeline: activeMultitrack,
            durations: timelineDurations,
            durationErrors: timelineDurationErrors,
            outputWidth: dims.width,
            outputHeight: dims.height,
            outputFPS: timelineOutput.fps ?? Int(TimelineLayout.fps)
        )
    }

    func multitrackExportPayload() -> [String: Any] {
        activeMultitrack.exportPayload(
            durations: timelineDurations,
            fps: timelineOutput.fps ?? Int(TimelineLayout.fps)
        )
    }

    var allTimelineMediaPaths: [String] {
        let mt = activeMultitrack
        var seen = Set<String>()
        var paths: [String] = []
        func collect(videoTracks: [VideoTrack], audioTracks: [AudioTrack]) {
            for vt in videoTracks {
                for clip in vt.clips where !clip.still {
                    if seen.insert(clip.path).inserted { paths.append(clip.path) }
                }
            }
            for at in audioTracks {
                for clip in at.clips {
                    if seen.insert(clip.path).inserted { paths.append(clip.path) }
                }
            }
        }
        collect(videoTracks: mt.videoTracks, audioTracks: mt.audioTracks)
        for seq in mt.sequences ?? [] {
            collect(videoTracks: seq.videoTracks, audioTracks: seq.audioTracks)
        }
        for legacy in project.clips where !legacy.still {
            if seen.insert(legacy.path).inserted { paths.append(legacy.path) }
        }
        return paths
    }

    nonisolated static func probeMultitrackMediaDuration(path: String) async -> (duration: Double?, error: String?) {
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
                return (nil, "找不到媒體檔案")
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
            if let fallback = probeMultitrackFFprobe(path: path) {
                return (fallback, nil)
            }
            return (nil, "AVFoundation 無法讀取片長：\(error.localizedDescription)")
        }

        if let fallback = probeMultitrackFFprobe(path: path) {
            return (fallback, nil)
        }
        return (nil, "無法判定媒體長度")
    }

    private nonisolated static func probeMultitrackFFprobe(path: String) -> Double? {
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

    func loadMultitrackDurations(forceRetry: Bool = false) async {
        let paths = allTimelineMediaPaths
        var firstError: String?
        for path in paths {
            if !forceRetry && timelineDurations[path] != nil { continue }
            let result = await Self.probeMultitrackMediaDuration(path: path)
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
            status = "無法讀取部分媒體 · \(firstError)"
        }
    }

    private func mutateMultitrack(_ body: (inout MultitrackTimeline) -> Void) {
        var mt = activeMultitrack
        body(&mt)
        mt.syncActiveSequenceFromTopLevel()
        project.multitrack = mt
        syncLegacyMirrorFromMultitrack()
    }

    func syncLegacyMirrorFromMultitrack() {
        guard let mt = project.multitrack else { return }
        let mirrored = mt.mirrorLegacyV1()
        project.clips = mirrored.clips
        project.editTransitions = mirrored.transitions
        validateBridgeShotAfterTimelineChange()
    }

    // MARK: Multi-Timeline Sequences (Project Versions)

    var timelineSequences: [TimelineSequence] {
        activeMultitrack.resolvedSequences
    }

    var activeSequenceID: UUID {
        activeMultitrack.resolvedActiveSequenceID
    }

    @discardableResult
    func addTimelineSequence(duplicateCurrent: Bool = false) -> UUID {
        let existing = timelineSequences
        var nextNum = existing.count + 1
        var proposedName = duplicateCurrent ? "時間軸 \(nextNum) 副本" : "時間軸 \(nextNum)"
        let usedNames = Set(existing.map(\.name))
        while usedNames.contains(proposedName) {
            nextNum += 1
            proposedName = duplicateCurrent ? "時間軸 \(nextNum) 副本" : "時間軸 \(nextNum)"
        }

        var createdID = UUID()
        var mt = activeMultitrack
        mt.ensureMaterializedSequences()

        let newSeq: TimelineSequence
        if duplicateCurrent,
           let cur = mt.sequences?.first(where: { $0.id == mt.resolvedActiveSequenceID }) {
            newSeq = cur.duplicated(named: proposedName)
        } else {
            newSeq = TimelineSequence(name: proposedName)
        }
        createdID = newSeq.id
        var seqs = mt.sequences ?? []
        seqs.append(newSeq)
        mt.sequences = seqs
        mt.activeSequenceID = newSeq.id
        mt.videoTracks = newSeq.videoTracks
        mt.audioTracks = newSeq.audioTracks
        mt.textTracks = newSeq.textTracks
        mt.shapeTracks = newSeq.shapeTracks
        mt.snapEnabled = newSeq.snapEnabled

        project.multitrack = mt
        syncLegacyMirrorFromMultitrack()
        status = duplicateCurrent ? "已複製新時間軸版本 · \(proposedName)" : "已建立空白時間軸 · \(proposedName)"
        return createdID
    }

    func selectTimelineSequence(_ id: UUID) {
        guard !busy else { return }
        var mt = activeMultitrack
        mt.ensureMaterializedSequences()
        guard let target = mt.sequences?.first(where: { $0.id == id }) else { return }
        if mt.activeSequenceID == id { return }

        mt.activeSequenceID = target.id
        mt.videoTracks = target.videoTracks
        mt.audioTracks = target.audioTracks
        mt.textTracks = target.textTracks
        mt.shapeTracks = target.shapeTracks
        mt.snapEnabled = target.snapEnabled

        project.multitrack = mt
        syncLegacyMirrorFromMultitrack()
        status = "已切換至 \(target.name)"
        Task { await loadMultitrackDurations() }
    }

    func renameTimelineSequence(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty else { return }
        var mt = activeMultitrack
        mt.ensureMaterializedSequences()
        guard var seqs = mt.sequences,
              let idx = seqs.firstIndex(where: { $0.id == id }) else { return }
        seqs[idx].name = trimmed
        mt.sequences = seqs
        project.multitrack = mt
        status = "已重新命名時間軸 · \(trimmed)"
    }

    func deleteTimelineSequence(_ id: UUID) {
        guard !busy else { return }
        var mt = activeMultitrack
        mt.ensureMaterializedSequences()
        guard var seqs = mt.sequences, seqs.count > 1,
              let idx = seqs.firstIndex(where: { $0.id == id }) else {
            status = "至少需保留一個時間軸。"
            return
        }
        let removed = seqs.remove(at: idx)
        mt.sequences = seqs
        if mt.activeSequenceID == id {
            let nextIdx = min(idx, seqs.count - 1)
            let nextSeq = seqs[nextIdx]
            mt.activeSequenceID = nextSeq.id
            mt.videoTracks = nextSeq.videoTracks
            mt.audioTracks = nextSeq.audioTracks
            mt.textTracks = nextSeq.textTracks
            mt.shapeTracks = nextSeq.shapeTracks
            mt.snapEnabled = nextSeq.snapEnabled
        }
        project.multitrack = mt
        syncLegacyMirrorFromMultitrack()
        status = "已刪除時間軸 · \(removed.name)"
    }

    @discardableResult
    func insertFreezeFrame(at playhead: Double, selection: TimelineSelection? = nil) -> TimelineSelection? {
        guard !busy else { return nil }
        let layout = currentMultitrackLayout()
        guard !layout.isEmpty else {
            status = "時間軸尚無影片片段可插入定格。"
            return nil
        }

        let t = MultitrackLayout.roundTime(max(0, playhead))
        let freezeDuration = 2.0

        var targetSeg: VideoSegmentLayout?
        if case .videoClip(let tid, let cid) = selection {
            targetSeg = layout.videoSegment(trackID: tid, clipID: cid)
        }
        if targetSeg == nil {
            for vt in layout.videoTracks.reversed() where !vt.track.locked {
                if let seg = vt.segments.first(where: { t >= $0.timelineStart - 1e-4 && t <= $0.timelineEnd + 1e-4 }) {
                    targetSeg = seg
                    break
                }
            }
        }
        guard let seg = targetSeg else {
            status = "請先選取影片片段或將播放頭移至影片上再插入定格。"
            return nil
        }
        guard let vt = activeMultitrack.videoTracks.first(where: { $0.id == seg.trackID }), !vt.locked else {
            status = "影片軌已鎖定，無法插入定格。"
            return nil
        }

        let freezeSourceSec = layout.sourceTime(for: seg, at: min(seg.timelineEnd, max(seg.timelineStart, t)))
        let insideStrictly = !seg.clip.still && !seg.clip.freezeFrame
            && t > seg.timelineStart + TimelineLayout.minClipDuration
            && t < seg.timelineEnd - TimelineLayout.minClipDuration
            && !(seg.incomingOverlap > 0 && (t - seg.timelineStart) <= seg.incomingOverlap + 1e-4)
            && !(seg.outgoingOverlap > 0 && (seg.timelineEnd - t) <= seg.outgoingOverlap + 1e-4)

        var freezeClip = seg.clip
        freezeClip.id = UUID()
        freezeClip.freezeFrame = true
        freezeClip.speed = 1.0
        freezeClip.reversed = false
        freezeClip.muted = true

        if seg.clip.still {
            freezeClip.start = ""
            freezeClip.end = TimelineLayout.formatTrimSeconds(freezeDuration)
        } else {
            freezeClip.start = TimelineLayout.formatTrimSeconds(freezeSourceSec)
            freezeClip.end = TimelineLayout.formatTrimSeconds(freezeSourceSec + freezeDuration)
        }

        if insideStrictly {
            let original = seg.clip
            let splitText = TimelineLayout.formatTrimSeconds(freezeSourceSec)
            var left = original
            left.start = original.start.trimmingCharacters(in: .whitespacesAndNewlines)
            left.end = splitText

            var right = original
            right.id = UUID()
            right.timelineStart = MultitrackLayout.roundTime(t + freezeDuration)
            right.start = splitText
            right.end = original.end.trimmingCharacters(in: .whitespacesAndNewlines)

            freezeClip.timelineStart = MultitrackLayout.roundTime(t)

            mutateMultitrack { mt in
                guard let tIdx = mt.videoTracks.firstIndex(where: { $0.id == seg.trackID }),
                      let cIdx = mt.videoTracks[tIdx].clips.firstIndex(where: { $0.id == original.id }) else { return }
                // Shift downstream clips on the same track by +freezeDuration
                for i in mt.videoTracks[tIdx].clips.indices where mt.videoTracks[tIdx].clips[i].id != original.id && mt.videoTracks[tIdx].clips[i].timelineStart >= t - 1e-4 {
                    mt.videoTracks[tIdx].clips[i].timelineStart = MultitrackLayout.roundTime(
                        mt.videoTracks[tIdx].clips[i].timelineStart + freezeDuration
                    )
                }
                mt.videoTracks[tIdx].clips[cIdx] = left
                mt.videoTracks[tIdx].clips.insert(freezeClip, at: cIdx + 1)
                mt.videoTracks[tIdx].clips.insert(right, at: cIdx + 2)
                for i in mt.videoTracks[tIdx].transitions.indices where mt.videoTracks[tIdx].transitions[i].after == original.id {
                    mt.videoTracks[tIdx].transitions[i].after = right.id
                }
                pruneOrphanedTransitions(on: &mt.videoTracks[tIdx])
            }
        } else {
            let insertAt = MultitrackLayout.roundTime(seg.timelineEnd)
            freezeClip.timelineStart = insertAt
            mutateMultitrack { mt in
                guard let tIdx = mt.videoTracks.firstIndex(where: { $0.id == seg.trackID }) else { return }
                for i in mt.videoTracks[tIdx].clips.indices where mt.videoTracks[tIdx].clips[i].timelineStart >= insertAt - 1e-4 {
                    mt.videoTracks[tIdx].clips[i].timelineStart = MultitrackLayout.roundTime(
                        mt.videoTracks[tIdx].clips[i].timelineStart + freezeDuration
                    )
                }
                mt.videoTracks[tIdx].clips.append(freezeClip)
                pruneOrphanedTransitions(on: &mt.videoTracks[tIdx])
            }
        }

        status = "已插入 2.0s 定格畫面 · \(filename(seg.clip.path))"
        return .videoClip(trackID: seg.trackID, clipID: freezeClip.id)
    }

    private func pruneOrphanedTransitions(on track: inout VideoTrack) {
        guard !track.transitions.isEmpty else { return }
        let sorted = track.clips.enumerated().sorted { lhs, rhs in
            if abs(lhs.element.timelineStart - rhs.element.timelineStart) > 1e-6 {
                return lhs.element.timelineStart < rhs.element.timelineStart
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let adjacentPairs = Set(zip(sorted, sorted.dropFirst()).map { "\($0.0.id.uuidString)->\($0.1.id.uuidString)" })
        track.transitions.removeAll { !adjacentPairs.contains("\($0.after.uuidString)->\($0.before.uuidString)") }
    }

    // MARK: Track Management

    @discardableResult
    func addVideoTrack(name: String? = nil) -> UUID {
        let newID = UUID()
        mutateMultitrack { mt in
            let nextNum = mt.videoTracks.count + 1
            let trackName = name ?? "V\(nextNum) 疊加"
            mt.videoTracks.append(VideoTrack(id: newID, name: trackName))
        }
        status = "已新增影片軌 · \(activeMultitrack.videoTracks.last?.name ?? "V")"
        return newID
    }

    @discardableResult
    func addAudioTrack(name: String? = nil) -> UUID {
        let newID = UUID()
        mutateMultitrack { mt in
            let nextNum = mt.audioTracks.count + 1
            let trackName = name ?? "A\(nextNum) 音訊"
            mt.audioTracks.append(AudioTrack(id: newID, name: trackName))
        }
        status = "已新增音訊軌 · \(activeMultitrack.audioTracks.last?.name ?? "A")"
        return newID
    }

    @discardableResult
    func addTextTrack(name: String? = nil) -> UUID {
        let newID = UUID()
        mutateMultitrack { mt in
            let nextNum = mt.textTracks.count + 1
            let trackName = name ?? "T\(nextNum) 字幕"
            mt.textTracks.append(TextTrack(id: newID, name: trackName))
        }
        status = "已新增文字軌 · \(activeMultitrack.textTracks.last?.name ?? "T")"
        return newID
    }

    func renameTrack(id: UUID, kind: TrackKind, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty else { return }
        mutateMultitrack { mt in
            switch kind {
            case .video:
                if let idx = mt.videoTracks.firstIndex(where: { $0.id == id }) {
                    mt.videoTracks[idx].name = trimmed
                }
            case .audio:
                if let idx = mt.audioTracks.firstIndex(where: { $0.id == id }) {
                    mt.audioTracks[idx].name = trimmed
                }
            case .text:
                if let idx = mt.textTracks.firstIndex(where: { $0.id == id }) {
                    mt.textTracks[idx].name = trimmed
                }
            case .shape:
                if let idx = mt.shapeTracks.firstIndex(where: { $0.id == id }) {
                    mt.shapeTracks[idx].name = trimmed
                }
            }
        }
        status = "已重新命名軌道 · \(trimmed)"
    }

    func deleteTrack(id: UUID, kind: TrackKind) {
        guard !busy else { return }
        var deletedName: String?
        mutateMultitrack { mt in
            switch kind {
            case .video:
                guard let idx = mt.videoTracks.firstIndex(where: { $0.id == id }) else { return }
                if mt.videoTracks.count <= 1 {
                    deletedName = mt.videoTracks[idx].name
                    mt.videoTracks[idx].clips.removeAll()
                    mt.videoTracks[idx].transitions.removeAll()
                } else {
                    deletedName = mt.videoTracks.remove(at: idx).name
                }
            case .audio:
                if let idx = mt.audioTracks.firstIndex(where: { $0.id == id }) {
                    deletedName = mt.audioTracks.remove(at: idx).name
                }
            case .text:
                if let idx = mt.textTracks.firstIndex(where: { $0.id == id }) {
                    deletedName = mt.textTracks.remove(at: idx).name
                }
            case .shape:
                if let idx = mt.shapeTracks.firstIndex(where: { $0.id == id }) {
                    deletedName = mt.shapeTracks.remove(at: idx).name
                }
            }
        }
        if let deletedName {
            status = "已刪除軌道 · \(deletedName)"
        }
    }

    func toggleTrackMuted(id: UUID, kind: TrackKind) {
        guard !busy else { return }
        mutateMultitrack { mt in
            switch kind {
            case .video:
                if let idx = mt.videoTracks.firstIndex(where: { $0.id == id }) {
                    mt.videoTracks[idx].muted.toggle()
                }
            case .audio:
                if let idx = mt.audioTracks.firstIndex(where: { $0.id == id }) {
                    mt.audioTracks[idx].muted.toggle()
                }
            case .text, .shape:
                break
            }
        }
    }

    func toggleTrackHidden(id: UUID, kind: TrackKind) {
        guard !busy else { return }
        mutateMultitrack { mt in
            switch kind {
            case .video:
                if let idx = mt.videoTracks.firstIndex(where: { $0.id == id }) {
                    mt.videoTracks[idx].hidden.toggle()
                }
            case .text:
                if let idx = mt.textTracks.firstIndex(where: { $0.id == id }) {
                    mt.textTracks[idx].hidden.toggle()
                }
            case .shape:
                if let idx = mt.shapeTracks.firstIndex(where: { $0.id == id }) {
                    mt.shapeTracks[idx].hidden.toggle()
                }
            case .audio:
                break
            }
        }
    }

    func toggleTrackLocked(id: UUID, kind: TrackKind) {
        guard !busy else { return }
        mutateMultitrack { mt in
            switch kind {
            case .video:
                if let idx = mt.videoTracks.firstIndex(where: { $0.id == id }) {
                    mt.videoTracks[idx].locked.toggle()
                }
            case .audio:
                if let idx = mt.audioTracks.firstIndex(where: { $0.id == id }) {
                    mt.audioTracks[idx].locked.toggle()
                }
            case .text:
                if let idx = mt.textTracks.firstIndex(where: { $0.id == id }) {
                    mt.textTracks[idx].locked.toggle()
                }
            case .shape:
                if let idx = mt.shapeTracks.firstIndex(where: { $0.id == id }) {
                    mt.shapeTracks[idx].locked.toggle()
                }
            }
        }
    }

    func setAudioTrackVolume(id: UUID, volume: Double) {
        guard !busy else { return }
        let clamped = min(2.0, max(0.0, volume))
        mutateMultitrack { mt in
            if let idx = mt.audioTracks.firstIndex(where: { $0.id == id }) {
                mt.audioTracks[idx].volume = clamped
            }
        }
    }

    func toggleMultitrackSnap() {
        mutateMultitrack { mt in
            mt.snapEnabled.toggle()
        }
        status = activeMultitrack.snapEnabled ? "已開啟時間軸吸附" : "已關閉時間軸吸附"
    }

    // MARK: Adding Media

    private func collectMultitrackMediaURLs(from urls: [URL], extensions: Set<String>) -> [URL] {
        var files: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        func append(_ file: URL) {
            let url = file.standardizedFileURL
            guard extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: keys).isRegularFile) == true else { return }
            files.append(url)
        }
        for url in urls where url.isFileURL {
            if (try? url.resourceValues(forKeys: keys).isDirectory) == true {
                guard let contents = fs.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
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
    func addMediaToMultitrack(
        _ path: String,
        targetTrackID: UUID? = nil,
        at startTime: Double? = nil
    ) -> TimelineSelection? {
        guard !busy else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard multitrackMediaTypes.contains(ext) else { return nil }

        let currentLayout = currentMultitrackLayout()
        var createdSelection: TimelineSelection?

        if audioTypes.contains(ext) {
            mutateMultitrack { mt in
                if mt.audioTracks.isEmpty {
                    mt.audioTracks.append(AudioTrack(name: "A1 音訊"))
                }
                let trackIdx = mt.audioTracks.firstIndex(where: { $0.id == targetTrackID }) ?? 0
                if mt.audioTracks[trackIdx].locked {
                    status = "軌道 \(mt.audioTracks[trackIdx].name) 已鎖定，無法加入音訊。"
                    return
                }
                let trackID = mt.audioTracks[trackIdx].id
                let defaultStart = currentLayout.audioTracks.first(where: { $0.id == trackID })?.endTime ?? 0
                let insertAt = MultitrackLayout.roundTime(max(0, startTime ?? defaultStart))
                let clip = AudioClip(path: path, timelineStart: insertAt)
                mt.audioTracks[trackIdx].clips.append(clip)
                createdSelection = .audioClip(trackID: trackID, clipID: clip.id)
            }
        } else {
            mutateMultitrack { mt in
                if mt.videoTracks.isEmpty {
                    mt.videoTracks.append(VideoTrack(name: "V1 主軌"))
                }
                let trackIdx = mt.videoTracks.firstIndex(where: { $0.id == targetTrackID }) ?? 0
                if mt.videoTracks[trackIdx].locked {
                    status = "軌道 \(mt.videoTracks[trackIdx].name) 已鎖定，無法加入片段。"
                    return
                }
                let trackID = mt.videoTracks[trackIdx].id
                let defaultStart = currentLayout.videoTracks.first(where: { $0.id == trackID })?.endTime ?? 0
                let insertAt = MultitrackLayout.roundTime(max(0, startTime ?? defaultStart))
                let clip = VideoClip(path: path, timelineStart: insertAt)
                mt.videoTracks[trackIdx].clips.append(clip)
                lastAddedClipID = clip.id
                createdSelection = .videoClip(trackID: trackID, clipID: clip.id)
            }
        }

        if createdSelection != nil {
            registerMedia([path])
            editSelection = path
            workspace = .edit
            status = "已加入時間軸 · \(filename(path))"
            Task { await loadMultitrackDurations() }
        }
        return createdSelection
    }

    @discardableResult
    func addURLsToMultitrack(
        _ urls: [URL],
        targetTrackID: UUID? = nil,
        at startTime: Double? = nil
    ) -> TimelineSelection? {
        guard !busy else { return nil }
        let files = collectMultitrackMediaURLs(from: urls, extensions: multitrackMediaTypes)
        guard !files.isEmpty else { return nil }
        let paths = files.map(\.path)
        registerMedia(paths)

        var lastSelection: TimelineSelection?
        var cursorOffset = startTime
        for path in paths {
            if let sel = addMediaToMultitrack(path, targetTrackID: targetTrackID, at: cursorOffset) {
                lastSelection = sel
                if let currentCursor = cursorOffset {
                    let estDur = isImageMediaPath(path)
                        ? TimelineLayout.defaultStillDuration
                        : (timelineDurations[path] ?? TimelineLayout.defaultStillDuration)
                    cursorOffset = currentCursor + estDur
                }
            }
        }
        if paths.count > 1 {
            status = "已加入 \(paths.count) 個素材至時間軸"
        }
        return lastSelection
    }

    // MARK: Moving, Cross-Track Transfer & Trimming

    func moveVideoClip(id: UUID, toStart newStart: Double, targetTrackID: UUID? = nil) {
        guard !busy else { return }
        let cleanStart = MultitrackLayout.roundTime(max(0, newStart))
        mutateMultitrack { mt in
            guard let srcTrackIdx = mt.videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  let clipIdx = mt.videoTracks[srcTrackIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            guard !mt.videoTracks[srcTrackIdx].locked else { return }

            let dstTrackIdx = targetTrackID.flatMap { tid in mt.videoTracks.firstIndex(where: { $0.id == tid }) } ?? srcTrackIdx
            guard !mt.videoTracks[dstTrackIdx].locked else { return }

            var clip = mt.videoTracks[srcTrackIdx].clips[clipIdx]
            clip.timelineStart = cleanStart

            if srcTrackIdx == dstTrackIdx {
                mt.videoTracks[srcTrackIdx].clips[clipIdx] = clip
                pruneOrphanedTransitions(on: &mt.videoTracks[srcTrackIdx])
            } else {
                mt.videoTracks[srcTrackIdx].clips.remove(at: clipIdx)
                mt.videoTracks[srcTrackIdx].transitions.removeAll { $0.after == id || $0.before == id }
                pruneOrphanedTransitions(on: &mt.videoTracks[srcTrackIdx])
                mt.videoTracks[dstTrackIdx].clips.append(clip)
                pruneOrphanedTransitions(on: &mt.videoTracks[dstTrackIdx])
            }
        }
    }

    func moveAudioClip(id: UUID, toStart newStart: Double, targetTrackID: UUID? = nil) {
        guard !busy else { return }
        let cleanStart = MultitrackLayout.roundTime(max(0, newStart))
        mutateMultitrack { mt in
            guard let srcTrackIdx = mt.audioTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  let clipIdx = mt.audioTracks[srcTrackIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            guard !mt.audioTracks[srcTrackIdx].locked else { return }

            let dstTrackIdx = targetTrackID.flatMap { tid in mt.audioTracks.firstIndex(where: { $0.id == tid }) } ?? srcTrackIdx
            guard !mt.audioTracks[dstTrackIdx].locked else { return }

            var clip = mt.audioTracks[srcTrackIdx].clips[clipIdx]
            clip.timelineStart = cleanStart

            if srcTrackIdx == dstTrackIdx {
                mt.audioTracks[srcTrackIdx].clips[clipIdx] = clip
            } else {
                mt.audioTracks[srcTrackIdx].clips.remove(at: clipIdx)
                mt.audioTracks[dstTrackIdx].clips.append(clip)
            }
        }
    }

    func moveTextClip(id: UUID, toStart newStart: Double, targetTrackID: UUID? = nil) {
        guard !busy else { return }
        let cleanStart = MultitrackLayout.roundTime(max(0, newStart))
        mutateMultitrack { mt in
            guard let srcTrackIdx = mt.textTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  let clipIdx = mt.textTracks[srcTrackIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            guard !mt.textTracks[srcTrackIdx].locked else { return }

            let dstTrackIdx = targetTrackID.flatMap { tid in mt.textTracks.firstIndex(where: { $0.id == tid }) } ?? srcTrackIdx
            guard !mt.textTracks[dstTrackIdx].locked else { return }

            var clip = mt.textTracks[srcTrackIdx].clips[clipIdx]
            clip.timelineStart = cleanStart

            if srcTrackIdx == dstTrackIdx {
                mt.textTracks[srcTrackIdx].clips[clipIdx] = clip
            } else {
                mt.textTracks[srcTrackIdx].clips.remove(at: clipIdx)
                mt.textTracks[dstTrackIdx].clips.append(clip)
            }
        }
    }

    func trimVideoClip(id: UUID, sourceStart: Double?, sourceEnd: Double?, timelineStart: Double? = nil) {
        guard !busy else { return }
        mutateMultitrack { mt in
            guard let tIdx = mt.videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  !mt.videoTracks[tIdx].locked,
                  let cIdx = mt.videoTracks[tIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            var clip = mt.videoTracks[tIdx].clips[cIdx]
            if let timelineStart {
                clip.timelineStart = MultitrackLayout.roundTime(max(0, timelineStart))
            }
            if clip.still {
                let targetDur = min(300.0, max(TimelineLayout.minClipDuration, sourceEnd ?? TimelineLayout.defaultStillDuration))
                clip.start = ""
                clip.end = TimelineLayout.formatTrimSeconds(targetDur)
            } else {
                let probed = timelineDurations[clip.path]
                let curStart = max(0, TimelineLayout.parseSeconds(clip.start) ?? 0)
                let curEnd = TimelineLayout.parseSeconds(clip.end) ?? probed ?? (curStart + TimelineLayout.defaultStillDuration)
                var nextStart = max(0, sourceStart ?? curStart)
                var nextEnd = sourceEnd ?? curEnd
                if let probed, probed > 0 {
                    nextEnd = min(probed, nextEnd)
                    nextStart = min(max(0, probed - TimelineLayout.minClipDuration), nextStart)
                }
                if nextEnd - nextStart < TimelineLayout.minClipDuration {
                    if sourceStart != nil && sourceEnd == nil {
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
            mt.videoTracks[tIdx].clips[cIdx] = clip
        }
    }

    func resetVideoClipTrim(id: UUID) {
        guard !busy else { return }
        var name: String?
        mutateMultitrack { mt in
            guard let tIdx = mt.videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  !mt.videoTracks[tIdx].locked,
                  let cIdx = mt.videoTracks[tIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            mt.videoTracks[tIdx].clips[cIdx].start = ""
            mt.videoTracks[tIdx].clips[cIdx].end = ""
            name = filename(mt.videoTracks[tIdx].clips[cIdx].path)
        }
        if let name { status = "已重設片段裁切 · \(name)" }
    }

    func updateVideoClipProperties(id: UUID, _ mutate: (inout VideoClip) -> Void) {
        guard !busy else { return }
        mutateMultitrack { mt in
            guard let tIdx = mt.videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  !mt.videoTracks[tIdx].locked,
                  let cIdx = mt.videoTracks[tIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            mutate(&mt.videoTracks[tIdx].clips[cIdx])
        }
    }

    func trimAudioClip(id: UUID, sourceStart: Double?, sourceEnd: Double?, timelineStart: Double? = nil) {
        guard !busy else { return }
        mutateMultitrack { mt in
            guard let tIdx = mt.audioTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  !mt.audioTracks[tIdx].locked,
                  let cIdx = mt.audioTracks[tIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            var clip = mt.audioTracks[tIdx].clips[cIdx]
            if let timelineStart {
                clip.timelineStart = MultitrackLayout.roundTime(max(0, timelineStart))
            }
            let probed = timelineDurations[clip.path]
            let curStart = max(0, clip.sourceStart)
            let curEnd = clip.sourceEnd ?? probed ?? (curStart + TimelineLayout.defaultStillDuration)
            var nextStart = max(0, sourceStart ?? curStart)
            var nextEnd = sourceEnd ?? curEnd
            if let probed, probed > 0 {
                nextEnd = min(probed, nextEnd)
                nextStart = min(max(0, probed - TimelineLayout.minClipDuration), nextStart)
            }
            if nextEnd - nextStart < TimelineLayout.minClipDuration {
                if sourceStart != nil && sourceEnd == nil {
                    nextStart = max(0, nextEnd - TimelineLayout.minClipDuration)
                } else {
                    nextEnd = nextStart + TimelineLayout.minClipDuration
                    if let probed, probed > 0, nextEnd > probed {
                        nextEnd = probed
                        nextStart = max(0, nextEnd - TimelineLayout.minClipDuration)
                    }
                }
            }
            clip.sourceStart = MultitrackLayout.roundTime(nextStart)
            if let probed, abs(nextEnd - probed) <= 0.002 {
                clip.sourceEnd = nil
            } else {
                clip.sourceEnd = MultitrackLayout.roundTime(nextEnd)
            }
            mt.audioTracks[tIdx].clips[cIdx] = clip
        }
    }

    func updateAudioClipProperties(id: UUID, _ mutate: (inout AudioClip) -> Void) {
        guard !busy else { return }
        mutateMultitrack { mt in
            guard let tIdx = mt.audioTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  !mt.audioTracks[tIdx].locked,
                  let cIdx = mt.audioTracks[tIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            mutate(&mt.audioTracks[tIdx].clips[cIdx])
        }
    }

    func updateTextClipProperties(id: UUID, _ mutate: (inout TextClip) -> Void) {
        guard !busy else { return }
        mutateMultitrack { mt in
            guard let tIdx = mt.textTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == id }) }),
                  !mt.textTracks[tIdx].locked,
                  let cIdx = mt.textTracks[tIdx].clips.firstIndex(where: { $0.id == id }) else { return }
            mutate(&mt.textTracks[tIdx].clips[cIdx])
        }
    }

    @discardableResult
    func duplicateSelection(_ selection: TimelineSelection) -> TimelineSelection? {
        guard !busy else { return nil }
        let layout = currentMultitrackLayout()
        var duplicated: TimelineSelection?
        switch selection {
        case .videoClip(let trackID, let clipID):
            guard let seg = layout.videoSegment(trackID: trackID, clipID: clipID) else { return nil }
            mutateMultitrack { mt in
                guard let tIdx = mt.videoTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.videoTracks[tIdx].locked else { return }
                var copy = seg.clip
                copy.id = UUID()
                copy.timelineStart = MultitrackLayout.roundTime(seg.timelineEnd)
                mt.videoTracks[tIdx].clips.append(copy)
                duplicated = .videoClip(trackID: trackID, clipID: copy.id)
            }
        case .audioClip(let trackID, let clipID):
            guard let seg = layout.audioSegment(trackID: trackID, clipID: clipID) else { return nil }
            mutateMultitrack { mt in
                guard let tIdx = mt.audioTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.audioTracks[tIdx].locked else { return }
                var copy = seg.clip
                copy.id = UUID()
                copy.timelineStart = MultitrackLayout.roundTime(seg.timelineEnd)
                mt.audioTracks[tIdx].clips.append(copy)
                duplicated = .audioClip(trackID: trackID, clipID: copy.id)
            }
        case .textClip(let trackID, let clipID):
            guard let seg = layout.textSegment(trackID: trackID, clipID: clipID) else { return nil }
            mutateMultitrack { mt in
                guard let tIdx = mt.textTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.textTracks[tIdx].locked else { return }
                var copy = seg.clip
                copy.id = UUID()
                copy.timelineStart = MultitrackLayout.roundTime(seg.timelineEnd)
                mt.textTracks[tIdx].clips.append(copy)
                duplicated = .textClip(trackID: trackID, clipID: copy.id)
            }
        case .shapeClip(let trackID, let clipID):
            guard let seg = layout.shapeSegment(trackID: trackID, clipID: clipID) else { return nil }
            mutateMultitrack { mt in
                guard let sIdx = mt.shapeTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.shapeTracks[sIdx].locked else { return }
                var copy = seg.clip
                copy.id = UUID()
                copy.timelineStart = MultitrackLayout.roundTime(seg.timelineEnd)
                mt.shapeTracks[sIdx].clips.append(copy)
                duplicated = .shapeClip(trackID: trackID, clipID: copy.id)
            }
        case .transition:
            return nil
        }
        if duplicated != nil {
            status = "已複製片段"
        }
        return duplicated
    }

    // MARK: Split & Delete (V / A / T)

    @discardableResult
    func splitMultitrackClip(at playhead: Double, selection: TimelineSelection?) -> TimelineSelection? {
        guard !busy else { return nil }
        let layout = currentMultitrackLayout()
        guard !layout.isEmpty else {
            status = "時間軸尚無片段可分割。"
            return nil
        }

        let t = MultitrackLayout.roundTime(max(0, playhead))

        // Determine target: prefer current selection if playhead is inside it, else search topmost unlocked track under playhead.
        if let selection {
            switch selection {
            case .videoClip(let tid, let cid):
                if let seg = layout.videoSegment(trackID: tid, clipID: cid),
                   t > seg.timelineStart + 1e-4 && t < seg.timelineEnd - 1e-4 {
                    return performVideoSplit(seg: seg, at: t)
                }
            case .audioClip(let tid, let cid):
                if let seg = layout.audioSegment(trackID: tid, clipID: cid),
                   t > seg.timelineStart + 1e-4 && t < seg.timelineEnd - 1e-4 {
                    return performAudioSplit(seg: seg, at: t)
                }
            case .textClip(let tid, let cid):
                if let seg = layout.textSegment(trackID: tid, clipID: cid),
                   t > seg.timelineStart + 1e-4 && t < seg.timelineEnd - 1e-4 {
                    return performTextSplit(seg: seg, at: t)
                }
            case .shapeClip, .transition:
                break
            }
        }

        // Fallback: check Video tracks top-to-bottom, then Text tracks top-to-bottom, then Audio tracks.
        for vt in layout.videoTracks.reversed() where !vt.track.locked {
            if let seg = vt.segments.first(where: { t > $0.timelineStart + 1e-4 && t < $0.timelineEnd - 1e-4 }) {
                return performVideoSplit(seg: seg, at: t)
            }
        }
        for tt in layout.textTracks.reversed() where !tt.track.locked {
            if let seg = tt.segments.first(where: { t > $0.timelineStart + 1e-4 && t < $0.timelineEnd - 1e-4 }) {
                return performTextSplit(seg: seg, at: t)
            }
        }
        for at in layout.audioTracks where !at.track.locked {
            if let seg = at.segments.first(where: { t > $0.timelineStart + 1e-4 && t < $0.timelineEnd - 1e-4 }) {
                return performAudioSplit(seg: seg, at: t)
            }
        }

        status = "播放頭位置沒有可分割的未鎖定片段。"
        return nil
    }

    private func performVideoSplit(seg: VideoSegmentLayout, at t: Double) -> TimelineSelection? {
        guard let vt = activeMultitrack.videoTracks.first(where: { $0.id == seg.trackID }), !vt.locked else {
            status = "軌道已鎖定，無法分割。"
            return nil
        }
        if !seg.clip.still && seg.sourceDuration == nil && TimelineLayout.parseSeconds(seg.clip.end) == nil {
            status = seg.loadError.map { "無法分割：\($0)" } ?? "正在讀取影片長度，請稍候再分割。"
            return nil
        }
        guard seg.isTrimValid else {
            status = "片段入出點無效，請先修正後再分割。"
            return nil
        }
        let offset = t - seg.timelineStart
        let rightDur = seg.duration - offset
        if seg.incomingOverlap > 0 && offset <= seg.incomingOverlap + 1e-4 {
            status = "播放頭位於相鄰轉場重疊區內，請移出重疊區後再分割。"
            return nil
        }
        if seg.outgoingOverlap > 0 && rightDur <= seg.outgoingOverlap + 1e-4 {
            status = "播放頭位於相鄰轉場重疊區內，請移出重疊區後再分割。"
            return nil
        }
        guard offset >= TimelineLayout.minClipDuration - 1e-4 && rightDur >= TimelineLayout.minClipDuration - 1e-4 else {
            status = "播放頭距離片段邊緣過近（分割後每段需至少 0.1 秒）。"
            return nil
        }

        let original = seg.clip
        var left = original
        var right = original
        right.id = UUID()
        right.timelineStart = MultitrackLayout.roundTime(t)

        if original.still {
            let leftSec = max(TimelineLayout.minClipDuration, MultitrackLayout.roundTime(offset))
            let rightSec = max(TimelineLayout.minClipDuration, MultitrackLayout.roundTime(rightDur))
            left.start = ""
            left.end = TimelineLayout.formatTrimSeconds(leftSec)
            right.start = ""
            right.end = TimelineLayout.formatTrimSeconds(rightSec)
        } else if original.freezeFrame {
            let leftSec = max(TimelineLayout.minClipDuration, MultitrackLayout.roundTime(offset))
            let rightSec = max(TimelineLayout.minClipDuration, MultitrackLayout.roundTime(rightDur))
            left.start = TimelineLayout.formatTrimSeconds(seg.sourceStart)
            left.end = TimelineLayout.formatTrimSeconds(seg.sourceStart + leftSec)
            right.start = TimelineLayout.formatTrimSeconds(seg.sourceStart)
            right.end = TimelineLayout.formatTrimSeconds(seg.sourceStart + rightSec)
        } else {
            let safeSpeed = min(4.0, max(0.25, original.speed.isFinite ? original.speed : 1.0))
            let splitSource = seg.sourceStart + offset * safeSpeed
            let maxEnd = seg.sourceDuration ?? seg.sourceEnd
            let clampedSplit = min(maxEnd - TimelineLayout.minClipDuration,
                                   max(seg.sourceStart + TimelineLayout.minClipDuration, splitSource))
            let splitText = TimelineLayout.formatTrimSeconds(clampedSplit)
            left.start = original.start.trimmingCharacters(in: .whitespacesAndNewlines)
            left.end = splitText
            right.start = splitText
            right.end = original.end.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutateMultitrack { mt in
            guard let tIdx = mt.videoTracks.firstIndex(where: { $0.id == seg.trackID }),
                  let cIdx = mt.videoTracks[tIdx].clips.firstIndex(where: { $0.id == original.id }) else { return }
            mt.videoTracks[tIdx].clips[cIdx] = left
            mt.videoTracks[tIdx].clips.insert(right, at: cIdx + 1)
            for i in mt.videoTracks[tIdx].transitions.indices where mt.videoTracks[tIdx].transitions[i].after == original.id {
                mt.videoTracks[tIdx].transitions[i].after = right.id
            }
            pruneOrphanedTransitions(on: &mt.videoTracks[tIdx])
        }
        status = "已在 \(TimelineLayout.formatTimecode(t)) 分割影片片段 · \(filename(original.path))"
        return .videoClip(trackID: seg.trackID, clipID: right.id)
    }

    private func performAudioSplit(seg: AudioSegmentLayout, at t: Double) -> TimelineSelection? {
        guard let at = activeMultitrack.audioTracks.first(where: { $0.id == seg.trackID }), !at.locked else {
            status = "音訊軌已鎖定，無法分割。"
            return nil
        }
        let offset = t - seg.timelineStart
        let rightDur = seg.duration - offset
        guard offset >= TimelineLayout.minClipDuration - 1e-4 && rightDur >= TimelineLayout.minClipDuration - 1e-4 else {
            status = "播放頭距離音訊邊緣過近（每段需至少 0.1 秒）。"
            return nil
        }
        let splitSource = MultitrackLayout.roundTime(seg.sourceStart + offset)
        var left = seg.clip
        left.sourceEnd = splitSource
        left.fadeOut = 0

        var right = seg.clip
        right.id = UUID()
        right.timelineStart = MultitrackLayout.roundTime(t)
        right.sourceStart = splitSource
        right.fadeIn = 0

        mutateMultitrack { mt in
            guard let tIdx = mt.audioTracks.firstIndex(where: { $0.id == seg.trackID }),
                  let cIdx = mt.audioTracks[tIdx].clips.firstIndex(where: { $0.id == seg.clip.id }) else { return }
            mt.audioTracks[tIdx].clips[cIdx] = left
            mt.audioTracks[tIdx].clips.insert(right, at: cIdx + 1)
        }
        status = "已在 \(TimelineLayout.formatTimecode(t)) 分割音訊片段 · \(filename(seg.clip.path))"
        return .audioClip(trackID: seg.trackID, clipID: right.id)
    }

    private func performTextSplit(seg: TextSegmentLayout, at t: Double) -> TimelineSelection? {
        guard let tt = activeMultitrack.textTracks.first(where: { $0.id == seg.trackID }), !tt.locked else {
            status = "文字軌已鎖定，無法分割。"
            return nil
        }
        let leftDur = t - seg.timelineStart
        let rightDur = seg.duration - leftDur
        guard leftDur >= TimelineLayout.minClipDuration - 1e-4 && rightDur >= TimelineLayout.minClipDuration - 1e-4 else {
            status = "播放頭距離字幕邊緣過近（每段需至少 0.1 秒）。"
            return nil
        }
        var left = seg.clip
        left.duration = MultitrackLayout.roundTime(leftDur)

        var right = seg.clip
        right.id = UUID()
        right.timelineStart = MultitrackLayout.roundTime(t)
        right.duration = MultitrackLayout.roundTime(rightDur)

        mutateMultitrack { mt in
            guard let tIdx = mt.textTracks.firstIndex(where: { $0.id == seg.trackID }),
                  let cIdx = mt.textTracks[tIdx].clips.firstIndex(where: { $0.id == seg.clip.id }) else { return }
            mt.textTracks[tIdx].clips[cIdx] = left
            mt.textTracks[tIdx].clips.insert(right, at: cIdx + 1)
        }
        status = "已在 \(TimelineLayout.formatTimecode(t)) 分割文字字幕"
        return .textClip(trackID: seg.trackID, clipID: right.id)
    }

    @discardableResult
    func deleteMultitrackSelection(_ selection: TimelineSelection, ripple: Bool) -> TimelineSelection? {
        guard !busy else { return nil }
        let layout = currentMultitrackLayout()
        var nextSelection: TimelineSelection?

        switch selection {
        case .videoClip(let trackID, let clipID):
            guard let seg = layout.videoSegment(trackID: trackID, clipID: clipID) else { return nil }
            var didDelete = false
            mutateMultitrack { mt in
                guard let tIdx = mt.videoTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.videoTracks[tIdx].locked,
                      let cIdx = mt.videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipID }) else { return }
                mt.videoTracks[tIdx].clips.remove(at: cIdx)
                mt.videoTracks[tIdx].transitions.removeAll { $0.after == clipID || $0.before == clipID }
                if ripple {
                    let shift = seg.duration
                    for i in mt.videoTracks[tIdx].clips.indices where mt.videoTracks[tIdx].clips[i].timelineStart >= seg.timelineStart - 1e-4 {
                        mt.videoTracks[tIdx].clips[i].timelineStart = MultitrackLayout.roundTime(
                            max(0, mt.videoTracks[tIdx].clips[i].timelineStart - shift)
                        )
                    }
                }
                pruneOrphanedTransitions(on: &mt.videoTracks[tIdx])
                if let fallback = mt.videoTracks[tIdx].clips.first {
                    nextSelection = .videoClip(trackID: trackID, clipID: fallback.id)
                }
                didDelete = true
            }
            if didDelete {
                status = ripple
                    ? "已移除影片片段並自動接合 · \(filename(seg.clip.path))"
                    : "已移除影片片段 · \(filename(seg.clip.path))"
            }

        case .audioClip(let trackID, let clipID):
            guard let seg = layout.audioSegment(trackID: trackID, clipID: clipID) else { return nil }
            var didDelete = false
            mutateMultitrack { mt in
                guard let tIdx = mt.audioTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.audioTracks[tIdx].locked,
                      let cIdx = mt.audioTracks[tIdx].clips.firstIndex(where: { $0.id == clipID }) else { return }
                mt.audioTracks[tIdx].clips.remove(at: cIdx)
                if ripple {
                    let shift = seg.duration
                    for i in mt.audioTracks[tIdx].clips.indices where mt.audioTracks[tIdx].clips[i].timelineStart >= seg.timelineStart - 1e-4 {
                        mt.audioTracks[tIdx].clips[i].timelineStart = MultitrackLayout.roundTime(
                            max(0, mt.audioTracks[tIdx].clips[i].timelineStart - shift)
                        )
                    }
                }
                if let fallback = mt.audioTracks[tIdx].clips.first {
                    nextSelection = .audioClip(trackID: trackID, clipID: fallback.id)
                }
                didDelete = true
            }
            if didDelete {
                status = ripple
                    ? "已移除音訊片段並自動接合 · \(filename(seg.clip.path))"
                    : "已移除音訊片段 · \(filename(seg.clip.path))"
            }

        case .textClip(let trackID, let clipID):
            guard let seg = layout.textSegment(trackID: trackID, clipID: clipID) else { return nil }
            var didDelete = false
            mutateMultitrack { mt in
                guard let tIdx = mt.textTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.textTracks[tIdx].locked,
                      let cIdx = mt.textTracks[tIdx].clips.firstIndex(where: { $0.id == clipID }) else { return }
                mt.textTracks[tIdx].clips.remove(at: cIdx)
                if ripple {
                    let shift = seg.duration
                    for i in mt.textTracks[tIdx].clips.indices where mt.textTracks[tIdx].clips[i].timelineStart >= seg.timelineStart - 1e-4 {
                        mt.textTracks[tIdx].clips[i].timelineStart = MultitrackLayout.roundTime(
                            max(0, mt.textTracks[tIdx].clips[i].timelineStart - shift)
                        )
                    }
                }
                if let fallback = mt.textTracks[tIdx].clips.first {
                    nextSelection = .textClip(trackID: trackID, clipID: fallback.id)
                }
                didDelete = true
            }
            if didDelete {
                status = ripple ? "已移除文字字幕並自動接合" : "已移除文字字幕"
            }

        case .shapeClip(let trackID, let clipID):
            guard layout.shapeSegment(trackID: trackID, clipID: clipID) != nil else { return nil }
            var didDelete = false
            mutateMultitrack { mt in
                guard let sIdx = mt.shapeTracks.firstIndex(where: { $0.id == trackID }),
                      !mt.shapeTracks[sIdx].locked,
                      let cIdx = mt.shapeTracks[sIdx].clips.firstIndex(where: { $0.id == clipID }) else { return }
                mt.shapeTracks[sIdx].clips.remove(at: cIdx)
                if let fallback = mt.shapeTracks[sIdx].clips.first {
                    nextSelection = .shapeClip(trackID: trackID, clipID: fallback.id)
                }
                didDelete = true
            }
            if didDelete {
                status = "已移除形狀圖層"
            }

        case .transition(let trackID, let afterID, let beforeID):
            setMultitrackTransition(trackID: trackID, after: afterID, before: beforeID, kind: "cut", seconds: 0)
            return .videoClip(trackID: trackID, clipID: afterID)
        }

        return nextSelection
    }

    // MARK: Same-Track Adjacent Transitions

    func setMultitrackTransition(trackID: UUID, after: UUID, before: UUID, kind: String, seconds: Double) {
        guard !busy,
              kind == "cut" || (TimelineTransitionKind.supportedRawValues.contains(kind) && seconds.isFinite && (0.1...3.0).contains(seconds)) else {
            return
        }
        let layout = currentMultitrackLayout()
        guard let trackLayout = layout.videoTracks.first(where: { $0.id == trackID }),
              !trackLayout.track.locked,
              let leadIdx = trackLayout.segments.firstIndex(where: { $0.id == after }),
              trackLayout.segments.indices.contains(leadIdx + 1),
              trackLayout.segments[leadIdx + 1].id == before else {
            status = "僅支援於同軌相鄰影片片段設定轉場。"
            return
        }

        let leadingSeg = trackLayout.segments[leadIdx]
        let trailingSeg = trackLayout.segments[leadIdx + 1]
        let currentOverlap = max(0, leadingSeg.timelineEnd - trailingSeg.timelineStart)
        let newSeconds = kind == "cut" ? 0.0 : (min(3.0, max(0.1, seconds)) * 100.0).rounded() / 100.0
        let deltaShift = currentOverlap - newSeconds // positive shifts right (removing overlap), negative shifts left (creating overlap)

        // Collect IDs of trailing segment and any downstream contiguous clips on the same track.
        var downstreamIDs: Set<UUID> = [trailingSeg.id]
        var cursorEnd = trailingSeg.timelineEnd
        if leadIdx + 2 < trackLayout.segments.count {
            for idx in (leadIdx + 2)..<trackLayout.segments.count {
                let seg = trackLayout.segments[idx]
                if seg.timelineStart <= cursorEnd + 0.08 {
                    downstreamIDs.insert(seg.id)
                    cursorEnd = max(cursorEnd, seg.timelineEnd)
                } else {
                    break
                }
            }
        }

        mutateMultitrack { mt in
            guard let tIdx = mt.videoTracks.firstIndex(where: { $0.id == trackID }) else { return }
            mt.videoTracks[tIdx].transitions.removeAll { $0.after == after && $0.before == before }
            if kind != "cut" {
                mt.videoTracks[tIdx].transitions.append(
                    TrackTransition(after: after, before: before, kind: kind, seconds: newSeconds)
                )
            }
            if abs(deltaShift) > 1e-4 {
                for i in mt.videoTracks[tIdx].clips.indices where downstreamIDs.contains(mt.videoTracks[tIdx].clips[i].id) {
                    mt.videoTracks[tIdx].clips[i].timelineStart = MultitrackLayout.roundTime(
                        max(0, mt.videoTracks[tIdx].clips[i].timelineStart + deltaShift)
                    )
                }
            }
        }
        status = kind == "cut"
            ? "已重設接縫為硬切"
            : "已設定轉場 · \(TimelineTransitionKind.label(for: kind)) \(TimelineLayout.formatTrimSeconds(newSeconds))s"
    }

    // MARK: Text & SRT Import / Export

    @discardableResult
    func addTextClip(
        at playhead: Double,
        trackID: UUID? = nil,
        text: String = "新字幕"
    ) -> TimelineSelection? {
        guard !busy else { return nil }
        var created: TimelineSelection?
        mutateMultitrack { mt in
            if mt.textTracks.isEmpty {
                mt.textTracks.append(TextTrack(name: "T1 字幕"))
            }
            let tIdx = mt.textTracks.firstIndex(where: { $0.id == trackID }) ?? 0
            if mt.textTracks[tIdx].locked {
                status = "文字軌 \(mt.textTracks[tIdx].name) 已鎖定，無法新增字幕。"
                return
            }
            let clip = TextClip(
                text: text,
                timelineStart: MultitrackLayout.roundTime(max(0, playhead)),
                duration: 3.0
            )
            mt.textTracks[tIdx].clips.append(clip)
            created = .textClip(trackID: mt.textTracks[tIdx].id, clipID: clip.id)
        }
        if created != nil {
            workspace = .edit
            status = "已在 \(TimelineLayout.formatTimecode(playhead)) 新增字幕"
        }
        return created
    }

    @discardableResult
    func addStyledTextClip(
        _ preset: TextStylePreset,
        at playhead: Double,
        trackID: UUID? = nil
    ) -> TimelineSelection? {
        guard !busy else { return nil }
        var created: TimelineSelection?
        mutateMultitrack { mt in
            if mt.textTracks.isEmpty {
                mt.textTracks.append(TextTrack(name: "T1 字幕"))
            }
            let tIdx = mt.textTracks.firstIndex(where: { $0.id == trackID }) ?? 0
            if mt.textTracks[tIdx].locked {
                status = "文字軌 \(mt.textTracks[tIdx].name) 已鎖定，無法新增字幕。"
                return
            }
            let clip = preset.makeClip(at: playhead)
            mt.textTracks[tIdx].clips.append(clip)
            created = .textClip(trackID: mt.textTracks[tIdx].id, clipID: clip.id)
        }
        if created != nil {
            workspace = .edit
            status = "已套用「\(preset.name)」於 \(TimelineLayout.formatTimecode(playhead))"
        }
        return created
    }

    @discardableResult
    func importSRTContent(_ content: String, to trackID: UUID? = nil) -> (count: Int, firstSelection: TimelineSelection?) {
        let parsed = SRTCodec.parse(content)
        guard !parsed.isEmpty else {
            status = "SRT 檔案未包含有效字幕區段。"
            return (0, nil)
        }
        var firstSel: TimelineSelection?
        var targetTrackName = "T1 字幕"
        mutateMultitrack { mt in
            if mt.textTracks.isEmpty {
                mt.textTracks.append(TextTrack(name: "T1 字幕"))
            }
            let tIdx = mt.textTracks.firstIndex(where: { $0.id == trackID }) ?? 0
            if mt.textTracks[tIdx].locked {
                status = "文字軌 \(mt.textTracks[tIdx].name) 已鎖定，無法匯入 SRT。"
                return
            }
            targetTrackName = mt.textTracks[tIdx].name
            mt.textTracks[tIdx].clips.append(contentsOf: parsed)
            if let first = parsed.first {
                firstSel = .textClip(trackID: mt.textTracks[tIdx].id, clipID: first.id)
            }
        }
        if firstSel != nil {
            status = "已匯入 \(parsed.count) 條 SRT 字幕至 \(targetTrackName)"
            return (parsed.count, firstSel)
        }
        return (0, nil)
    }

    func importSRTFile(to trackID: UUID? = nil, onImported: ((TimelineSelection) -> Void)? = nil) {
        guard !busy else { return }
        var types: [UTType] = [.plainText]
        if let srtType = UTType(filenameExtension: "srt") {
            types.insert(srtType, at: 0)
        }
        pickAsync(title: "匯入 SRT 字幕檔", types: types, multiple: false, directory: false) { [weak self] urls in
            guard let self, !self.busy, let url = urls.first else { return }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                if let sel = self.importSRTContent(content, to: trackID).firstSelection {
                    onImported?(sel)
                }
            } catch {
                self.status = "無法讀取 SRT 檔案：\(error.localizedDescription)"
            }
        }
    }

    func exportSRTFile(from trackID: UUID? = nil) {
        guard !busy else { return }
        let mt = activeMultitrack
        let targetTrack = mt.textTracks.first(where: { $0.id == trackID }) ?? mt.textTracks.first
        let clips = targetTrack?.clips ?? mt.textTracks.flatMap(\.clips)
        guard !clips.isEmpty else {
            status = "文字軌尚無可匯出的字幕。"
            return
        }
        let srt = SRTCodec.export(clips)
        guard !srt.isEmpty else {
            status = "文字軌尚無有效字幕內容。"
            return
        }
        let defaultName = "\(targetTrack?.name ?? "字幕").srt"
        presentSavePanel(configure: { dialog in
            dialog.title = "匯出 SRT 字幕檔"
            dialog.nameFieldStringValue = defaultName
            if let srtType = UTType(filenameExtension: "srt") {
                dialog.allowedContentTypes = [srtType]
            } else {
                dialog.allowedContentTypes = [.plainText]
            }
        }) { [weak self] url in
            guard let self else { return }
            do {
                try srt.write(to: url, atomically: true, encoding: .utf8)
                self.status = "已匯出 SRT 字幕 · \(url.lastPathComponent)"
            } catch {
                self.status = "無法寫入 SRT 檔案：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - V4 Pro Mutations (Shapes, Keyframes, Speed Ramp, Audio-AI Tracks, Proxy)

    @discardableResult
    func addShapeClip(
        kind: ShapeKind,
        at playhead: Double,
        trackID: UUID? = nil,
        label: String = ""
    ) -> TimelineSelection? {
        guard !busy else { return nil }
        var createdSelection: TimelineSelection?
        mutateMultitrack { mt in
            if mt.shapeTracks.isEmpty {
                mt.shapeTracks = [ShapeTrack(name: "S1 形狀")]
            }
            let targetIdx = mt.shapeTracks.firstIndex(where: { $0.id == trackID && !$0.locked })
                ?? mt.shapeTracks.firstIndex(where: { !$0.locked })
                ?? 0
            guard !mt.shapeTracks[targetIdx].locked else { return }
            let defaultW: Double = (kind == .line) ? 0.45 : (kind == .pill ? 0.34 : 0.24)
            let defaultH: Double = (kind == .line) ? 0.025 : (kind == .pill ? 0.10 : 0.18)
            let clip = ShapeClip(
                kind: kind.rawValue,
                timelineStart: MultitrackLayout.roundTime(max(0, playhead)),
                duration: 3.0,
                posX: 0.5,
                posY: 0.48,
                width: defaultW,
                height: defaultH,
                label: label
            )
            mt.shapeTracks[targetIdx].clips.append(clip)
            createdSelection = .shapeClip(trackID: mt.shapeTracks[targetIdx].id, clipID: clip.id)
        }
        if createdSelection != nil {
            status = "已加入形狀圖層 · \(kind.displayName)"
        }
        return createdSelection
    }

    func updateShapeClipProperties(id: UUID, _ update: (inout ShapeClip) -> Void) {
        guard !busy else { return }
        mutateMultitrack { mt in
            for tIdx in mt.shapeTracks.indices where !mt.shapeTracks[tIdx].locked {
                if let cIdx = mt.shapeTracks[tIdx].clips.firstIndex(where: { $0.id == id }) {
                    update(&mt.shapeTracks[tIdx].clips[cIdx])
                    return
                }
            }
        }
    }

    func upsertVideoKeyframe(
        clipID: UUID,
        property: KeyframeProperty,
        time: Double,
        value: Double,
        easing: KeyframeEasing
    ) {
        let roundedT = MultitrackLayout.roundTime(max(0, time))
        updateVideoClipProperties(id: clipID) { clip in
            if let existing = clip.keyframes.firstIndex(where: {
                $0.property == property.rawValue && abs($0.time - roundedT) < 0.04
            }) {
                clip.keyframes[existing].value = value
                clip.keyframes[existing].easing = easing.rawValue
            } else {
                clip.keyframes.append(ClipKeyframe(
                    property: property.rawValue,
                    time: roundedT,
                    value: value,
                    easing: easing.rawValue
                ))
                clip.keyframes.sort { $0.time < $1.time }
            }
        }
        status = "已加入關鍵影格 · \(property.displayName) @ \(String(format: "%.2fs", roundedT))"
    }

    func removeVideoKeyframe(clipID: UUID, keyframeID: UUID) {
        updateVideoClipProperties(id: clipID) { clip in
            clip.keyframes.removeAll { $0.id == keyframeID }
        }
    }

    func upsertAudioKeyframe(clipID: UUID, time: Double, value: Double, easing: KeyframeEasing) {
        let roundedT = MultitrackLayout.roundTime(max(0, time))
        updateAudioClipProperties(id: clipID) { clip in
            if let existing = clip.keyframes.firstIndex(where: {
                $0.property == KeyframeProperty.volume.rawValue && abs($0.time - roundedT) < 0.04
            }) {
                clip.keyframes[existing].value = value
                clip.keyframes[existing].easing = easing.rawValue
            } else {
                clip.keyframes.append(ClipKeyframe(
                    property: KeyframeProperty.volume.rawValue,
                    time: roundedT,
                    value: value,
                    easing: easing.rawValue
                ))
                clip.keyframes.sort { $0.time < $1.time }
            }
        }
        status = "已加入音量關鍵影格 @ \(String(format: "%.2fs", roundedT))"
    }

    func removeAudioKeyframe(clipID: UUID, keyframeID: UUID) {
        updateAudioClipProperties(id: clipID) { clip in
            clip.keyframes.removeAll { $0.id == keyframeID }
        }
    }

    func applySpeedRampPreset(clipID: UUID, preset: SpeedRampPreset) {
        updateVideoClipProperties(id: clipID) { clip in
            clip.speedCurve = preset.points
        }
        status = "已套用速度曲線 · \(preset.name)"
    }

    /// Inserts an audio asset (TTS / Voice Clone / Vocal Separation / Voiceover Recording) onto an Audio Track and adds it to the shared media library.
    @discardableResult
    func addGeneratedAudioToTrack(
        path: String,
        at playhead: Double,
        preferredTrackName: String? = nil,
        createNewTrack: Bool = false
    ) -> TimelineSelection? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if !project.media.contains(path) {
            project.media.append(path)
        }
        var createdSelection: TimelineSelection?
        mutateMultitrack { mt in
            let targetIdx: Int
            if createNewTrack || mt.audioTracks.isEmpty {
                let name = preferredTrackName ?? "A\(mt.audioTracks.count + 1) 音訊"
                mt.audioTracks.append(AudioTrack(name: name))
                targetIdx = mt.audioTracks.count - 1
            } else if let pref = preferredTrackName,
                      let found = mt.audioTracks.firstIndex(where: { $0.name == pref && !$0.locked }) {
                targetIdx = found
            } else {
                targetIdx = mt.audioTracks.firstIndex(where: { !$0.locked }) ?? 0
            }
            let clip = AudioClip(
                path: path,
                timelineStart: MultitrackLayout.roundTime(max(0, playhead))
            )
            mt.audioTracks[targetIdx].clips.append(clip)
            createdSelection = .audioClip(trackID: mt.audioTracks[targetIdx].id, clipID: clip.id)
        }
        Task { await loadMultitrackDurations() }
        return createdSelection
    }

    /// Inserts timestamped Whisper ASR subtitle segments directly onto a Text Track.
    @discardableResult
    func addASRSubtitleSegments(
        _ segments: [(start: Double, end: Double, text: String)],
        to trackID: UUID? = nil
    ) -> TimelineSelection? {
        guard !segments.isEmpty else { return nil }
        var firstSel: TimelineSelection?
        mutateMultitrack { mt in
            if mt.textTracks.isEmpty {
                mt.textTracks = [TextTrack(name: "T1 字幕")]
            }
            let targetIdx = mt.textTracks.firstIndex(where: { $0.id == trackID && !$0.locked })
                ?? mt.textTracks.firstIndex(where: { !$0.locked })
                ?? 0
            for seg in segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let dur = max(0.25, seg.end - seg.start)
                let clip = TextClip(
                    text: text,
                    timelineStart: MultitrackLayout.roundTime(max(0, seg.start)),
                    duration: MultitrackLayout.roundTime(dur)
                )
                mt.textTracks[targetIdx].clips.append(clip)
                if firstSel == nil {
                    firstSel = .textClip(trackID: mt.textTracks[targetIdx].id, clipID: clip.id)
                }
            }
        }
        if firstSel != nil {
            status = "已將 \(segments.count) 條 ASR 自動字幕加入文字軌"
        }
        return firstSel
    }
}
