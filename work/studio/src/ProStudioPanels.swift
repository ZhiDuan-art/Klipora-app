import AppKit
import AVFoundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Local Darkroom Palette & Helpers (Self-Contained)

private let proCyan = StudioTheme.neutralAccent
private let proAmber = StudioTheme.warning
private let proEmerald = StudioTheme.success
private let proViolet = StudioTheme.neutralAccent
private let proRose = StudioTheme.danger
private let proDarkWell = StudioTheme.well

private let proColorPresetHexes: [String] = [
    "#0EA5E9", "#2563EB", "#6366F1", "#7C3AED",
    "#EC4899", "#EF4444", "#F97316", "#FACC15",
    "#10B981", "#06B6D4", "#FFFFFF", "#0F172A"
]

private func proMotionDeskAppSupportDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Klipora", isDirectory: true)
}

private func proShortSHA256(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
}

private func proFormatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 MB" }
    let mb = Double(bytes) / (1024.0 * 1024.0)
    if mb >= 1024.0 {
        return String(format: "%.2f GB", mb / 1024.0)
    }
    return String(format: "%.1f MB", mb)
}

private func proLocateFFmpeg() -> String? {
    var candidates: [String] = []
    if let custom = UserDefaults.standard.string(forKey: "MotionDesk.ffmpegPath"), !custom.isEmpty {
        candidates.append(custom)
    }
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime/bin/ffmpeg").path {
        candidates.append(bundled)
    }
    candidates.append(contentsOf: [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/homebrew/Cellar/ffmpeg/8.1_1/bin/ffmpeg"
    ])
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return nil
}

/// Allocates a collision-free output file URL inside the dated folder (`<root>/YYYY-MM-DD/<stem>.<ext>` or `<stem>-2.<ext>`).
func allocateUniqueDatedOutputURL(
    under rootDir: URL,
    stem: String,
    ext: String,
    on date: Date = .now,
    in timeZone: TimeZone = .current
) -> URL {
    let dayDir = datedDirectory(under: rootDir, on: date, in: timeZone)
    try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    let cleanStem = stem
        .replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "_", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let baseStem = cleanStem.isEmpty ? "MotionDesk-Audio" : cleanStem
    let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
    let first = dayDir.appendingPathComponent("\(baseStem).\(cleanExt)")
    if !FileManager.default.fileExists(atPath: first.path) {
        return first
    }
    for idx in 2..<10_000 {
        let candidate = dayDir.appendingPathComponent("\(baseStem)-\(idx).\(cleanExt)")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return dayDir.appendingPathComponent("\(baseStem)-\(Int(Date().timeIntervalSince1970)).\(cleanExt)")
}

/// Hidden scratch directory inside `<root>/YYYY-MM-DD/.scratch-<prefix>-<uuid>` for temporary intermediate files.
func allocateHiddenDatedScratchDirectory(
    under rootDir: URL,
    prefix: String = "audio",
    on date: Date = .now,
    in timeZone: TimeZone = .current
) -> URL {
    let dayDir = datedDirectory(under: rootDir, on: date, in: timeZone)
    let scratch = dayDir.appendingPathComponent(".scratch-\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
}

// MARK: - 1. EffectsCatalogStore (24 Visual FX + 25 Audio FX)

struct ProVisualEffectItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let category: String
    let keywords: [String]
    let description: String
    let ffmpegFilter: String
}

struct ProAudioEffectItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let category: String
    let keywords: [String]
    let description: String
    let ffmpegFilter: String
}

private struct ProEffectsCatalogPayload: Codable {
    let version: String?
    let visualEffects: [ProVisualEffectItem]?
    let audioEffects: [ProAudioEffectItem]?
}

@MainActor
final class EffectsCatalogStore: ObservableObject {
    static let shared = EffectsCatalogStore()

    @Published private(set) var visualEffects: [ProVisualEffectItem]
    @Published private(set) var audioEffects: [ProAudioEffectItem]

    init(bundle: Bundle = .main) {
        var loadedVisual = Self.fallbackVisualEffects
        var loadedAudio = Self.fallbackAudioEffects

        if let url = Self.locateCatalogURL(bundle: bundle),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ProEffectsCatalogPayload.self, from: data) {
            if let v = decoded.visualEffects, !v.isEmpty {
                loadedVisual = v
            }
            if let a = decoded.audioEffects, !a.isEmpty {
                loadedAudio = a
            }
        }
        self.visualEffects = loadedVisual
        self.audioEffects = loadedAudio
    }

    private static func locateCatalogURL(bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: "effects_catalog", withExtension: "json") {
            return url
        }
        let devFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("studio-v4/staged/resources/effects_catalog.json")
        if FileManager.default.fileExists(atPath: devFallback.path) {
            return devFallback
        }
        return nil
    }

    var visualCategories: [String] {
        var seen: Set<String> = []
        var result: [String] = ["全部"]
        for item in visualEffects where !seen.contains(item.category) {
            seen.insert(item.category)
            result.append(item.category)
        }
        return result
    }

    var audioCategories: [String] {
        var seen: Set<String> = []
        var result: [String] = ["全部"]
        for item in audioEffects where !seen.contains(item.category) {
            seen.insert(item.category)
            result.append(item.category)
        }
        return result
    }

    func visualEffect(id: String) -> ProVisualEffectItem? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return visualEffects.first { $0.id.lowercased() == key }
    }

    func audioEffect(id: String) -> ProAudioEffectItem? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return audioEffects.first { $0.id.lowercased() == key }
    }

    func searchVisualEffects(query: String, category: String? = nil) -> [ProVisualEffectItem] {
        let trimmedCat = (category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return visualEffects.filter { item in
            if !trimmedCat.isEmpty && trimmedCat != "全部" && item.category != trimmedCat {
                return false
            }
            guard !tokens.isEmpty else { return true }
            let haystack = (
                [item.id, item.name, item.category, item.description] + item.keywords
            ).joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    func searchAudioEffects(query: String, category: String? = nil) -> [ProAudioEffectItem] {
        let trimmedCat = (category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        return audioEffects.filter { item in
            if !trimmedCat.isEmpty && trimmedCat != "全部" && item.category != trimmedCat {
                return false
            }
            guard !tokens.isEmpty else { return true }
            let haystack = (
                [item.id, item.name, item.category, item.description] + item.keywords
            ).joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    static func swatchColors(forVisualEffectID id: String) -> [Color] {
        switch id {
        case "rgb_split": return [Color(red: 0.95, green: 0.22, blue: 0.38), Color(red: 0.14, green: 0.72, blue: 0.96)]
        case "vhs_scan": return [Color(red: 0.56, green: 0.38, blue: 0.44), Color(red: 0.18, green: 0.16, blue: 0.24)]
        case "glitch_shift": return [Color(red: 0.08, green: 0.92, blue: 0.80), Color(red: 0.78, green: 0.12, blue: 0.68)]
        case "pixelate": return [Color(red: 0.36, green: 0.78, blue: 0.42), Color(red: 0.16, green: 0.34, blue: 0.58)]
        case "sharpen_detail": return [Color(red: 0.44, green: 0.58, blue: 0.76), Color(red: 0.16, green: 0.22, blue: 0.30)]
        case "edge_glow": return [Color(red: 0.92, green: 0.26, blue: 0.92), Color(red: 0.08, green: 0.10, blue: 0.22)]
        case "posterize": return [Color(red: 0.96, green: 0.66, blue: 0.18), Color(red: 0.26, green: 0.38, blue: 0.86)]
        case "mirror_split": return [Color(red: 0.26, green: 0.64, blue: 0.92), Color(red: 0.52, green: 0.34, blue: 0.86)]
        case "film_grain": return [Color(red: 0.56, green: 0.48, blue: 0.38), Color(red: 0.20, green: 0.18, blue: 0.16)]
        case "cinematic_teal_orange": return [Color(red: 0.92, green: 0.50, blue: 0.22), Color(red: 0.10, green: 0.44, blue: 0.52)]
        case "matte_fade": return [Color(red: 0.60, green: 0.62, blue: 0.66), Color(red: 0.34, green: 0.36, blue: 0.42)]
        case "noir_cinema": return [Color(white: 0.84), Color(white: 0.08)]
        case "sepia_warm": return [Color(red: 0.74, green: 0.56, blue: 0.34), Color(red: 0.28, green: 0.20, blue: 0.12)]
        case "negative": return [Color(red: 0.12, green: 0.86, blue: 0.86), Color(red: 0.88, green: 0.22, blue: 0.46)]
        case "thermal": return [Color(red: 0.98, green: 0.84, blue: 0.14), Color(red: 0.86, green: 0.14, blue: 0.22), Color(red: 0.18, green: 0.12, blue: 0.56)]
        case "emboss": return [Color(white: 0.68), Color(white: 0.36)]
        case "bloom_soft": return [Color(red: 0.98, green: 0.86, blue: 0.72), Color(red: 0.46, green: 0.38, blue: 0.52)]
        case "kaleido": return [Color(red: 0.88, green: 0.32, blue: 0.72), Color(red: 0.24, green: 0.74, blue: 0.84)]
        case "vignette_heavy": return [Color(red: 0.42, green: 0.46, blue: 0.52), Color(red: 0.04, green: 0.04, blue: 0.06)]
        case "bw_grain": return [Color(white: 0.72), Color(white: 0.18)]
        case "dreamy_haze": return [Color(red: 0.86, green: 0.68, blue: 0.92), Color(red: 0.48, green: 0.62, blue: 0.86)]
        case "duotone_cyber": return [Color(red: 0.92, green: 0.18, blue: 0.68), Color(red: 0.12, green: 0.48, blue: 0.96)]
        case "warm_sunset": return [Color(red: 0.98, green: 0.60, blue: 0.20), Color(red: 0.68, green: 0.22, blue: 0.24)]
        case "cold_moonlight": return [Color(red: 0.24, green: 0.46, blue: 0.78), Color(red: 0.06, green: 0.12, blue: 0.24)]
        default: return [Color(white: 0.32), Color(white: 0.14)]
        }
    }

    static func symbolName(forAudioEffectID id: String) -> String {
        switch id {
        case "telephone": return "phone.fill"
        case "robot": return "cpu"
        case "chipmunk": return "hare.fill"
        case "radio_am": return "radio.fill"
        case "megaphone": return "megaphone.fill"
        case "walkie_talkie": return "antenna.radiowaves.left.and.right"
        case "deep_voice": return "waveform.path.ecg"
        case "helium": return "balloon.fill"
        case "monster": return "flame.fill"
        case "hall_reverb": return "music.note.house.fill"
        case "room_reverb": return "square.dashed"
        case "cathedral": return "building.columns.fill"
        case "slapback_echo": return "dot.radiowaves.right"
        case "dub_delay": return "waveform.circle.fill"
        case "underwater": return "drop.fill"
        case "chorus": return "person.3.fill"
        case "flanger": return "wind"
        case "phaser": return "hurricane"
        case "tremolo": return "waveform.path"
        case "vibrato": return "scribble.variable"
        case "vinyl_lofi": return "opticaldisc.fill"
        case "bass_boost": return "speaker.wave.3.fill"
        case "vocal_presence": return "mic.fill"
        case "podcast_warm": return "headphones"
        case "de_esser": return "slider.horizontal.3"
        default: return "waveform"
        }
    }

    // Complete 24 visual effects fallback matching effects_catalog.json
    static let fallbackVisualEffects: [ProVisualEffectItem] = [
        ProVisualEffectItem(id: "rgb_split", name: "色散分離", category: "光學畸變", keywords: ["rgb", "chromatic", "aberration", "色散", "色差", "分色", "抖音", "光學"], description: "紅藍通道水平與垂直錯位，營造鏡頭色散與潮流視覺衝擊。", ffmpegFilter: "format=rgba,rgbashift=rh=-8:bv=6:bh=8"),
        ProVisualEffectItem(id: "vhs_scan", name: "VHS 掃描線", category: "復古膠片", keywords: ["vhs", "crt", "scanline", "retro", "錄影帶", "掃描線", "復古", "電視"], description: "經典類比錄影帶雜訊、偏暖褪色與交錯深色掃描線。", ffmpegFilter: "format=rgb24,noise=alls=14:allf=t+u,eq=contrast=1.08:saturation=0.82,colorbalance=rs=0.05:bs=-0.04,geq=r='if(mod(Y,4),r(X,Y),r(X,Y)*0.72)':g='if(mod(Y,4),g(X,Y),g(X,Y)*0.72)':b='if(mod(Y,4),b(X,Y),b(X,Y)*0.75)'"),
        ProVisualEffectItem(id: "glitch_shift", name: "數位故障", category: "光學畸變", keywords: ["glitch", "cyber", "tear", "故障", "撕裂", "訊號干擾", "失真", "賽博"], description: "動態水平掃描帶錯位與紅藍分離，模擬數位訊號故障撕裂感。", ffmpegFilter: "format=rgb24,geq=r='r(mod(X+if(lt(mod(Y+floor(N*17),64),8),14,0),W),Y)':g='g(X,Y)':b='b(mod(X-if(lt(mod(Y+floor(N*23),52),6),12,0),W),Y)'"),
        ProVisualEffectItem(id: "pixelate", name: "像素馬賽克", category: "藝術風格", keywords: ["pixel", "mosaic", "8bit", "retro", "像素", "馬賽克", "點陣", "復古遊戲"], description: "最近鄰降採樣再放大，產生銳利方格像素化馬賽克效果。", ffmpegFilter: "scale=max(2\\,trunc(iw/10)):max(2\\,trunc(ih/10)):flags=neighbor,scale={W}:{H}:flags=neighbor"),
        ProVisualEffectItem(id: "sharpen_detail", name: "銳利細節", category: "光學畸變", keywords: ["sharpen", "crisp", "detail", "unsharp", "銳化", "清晰", "細節", "質感"], description: "使用非銳化遮罩強化畫面微對比與邊緣輪廓清晰度。", ffmpegFilter: "unsharp=5:5:1.5:5:5:0.4"),
        ProVisualEffectItem(id: "edge_glow", name: "霓虹邊緣", category: "藝術風格", keywords: ["neon", "edge", "outline", "glow", "霓虹", "邊緣", "發光", "線稿"], description: "偵測高反差影像輪廓並融合飽和霓虹色彩邊線。", ffmpegFilter: "edgedetect=low=0.08:high=0.28:mode=colormix,eq=saturation=1.8:contrast=1.25"),
        ProVisualEffectItem(id: "posterize", name: "海報色階", category: "藝術風格", keywords: ["poster", "comic", "quantize", "海報", "色階", "漫畫", "普普", "色塊"], description: "將 RGB 亮度階數離散化，呈現鮮明平面海報色塊質感。", ffmpegFilter: "format=rgb24,lutrgb=r='trunc(val/48)*48':g='trunc(val/48)*48':b='trunc(val/48)*48'"),
        ProVisualEffectItem(id: "mirror_split", name: "左右鏡像分屏", category: "動感與鏡像", keywords: ["mirror", "split", "symmetry", "鏡像", "對稱", "分屏", "左右翻轉"], description: "裁切左半畫面並水平翻轉拼接至右半，建立完美左右對稱構圖。", ffmpegFilter: "split[{p}_a][{p}_b];[{p}_a]crop=trunc(iw/2):ih:0:0[{p}_l];[{p}_b]crop=trunc(iw/2):ih:0:0,hflip[{p}_r];[{p}_l][{p}_r]hstack=inputs=2"),
        ProVisualEffectItem(id: "film_grain", name: "底片顆粒", category: "復古膠片", keywords: ["film", "grain", "35mm", "analog", "底片", "顆粒", "膠片", "雜訊"], description: "加入動態有機 35mm 膠片顆粒並微調對比與飽和度。", ffmpegFilter: "noise=alls=18:allf=t+u,eq=contrast=1.06:saturation=0.92"),
        ProVisualEffectItem(id: "cinematic_teal_orange", name: "青橙電影", category: "調色風格", keywords: ["teal", "orange", "cinema", "movie", "青橙", "電影", "好萊塢", "調色"], description: "暗部注入冷青色調、亮部拉升暖橘膚色，經典院線電影色調。", ffmpegFilter: "colorbalance=rs=-0.12:gs=0.04:bs=0.14:rm=0.04:gm=-0.02:bm=-0.06:rh=0.16:gh=0.05:bh=-0.14,eq=contrast=1.10:saturation=1.12"),
        ProVisualEffectItem(id: "matte_fade", name: "霧面褪色", category: "調色風格", keywords: ["matte", "fade", "lifted", "soft", "霧面", "褪色", "日系", "低反差"], description: "拉高黑位並壓低純白頂點，呈現柔和日系霧面膠片氛圍。", ffmpegFilter: "curves=all='0/0.11 0.25/0.28 0.75/0.77 1/0.91',eq=saturation=0.86"),
        ProVisualEffectItem(id: "noir_cinema", name: "黑色電影", category: "復古膠片", keywords: ["noir", "bw", "monochrome", "contrast", "黑色電影", "黑白", "高對比", "經典"], description: "高反差 S 曲線單色黑白搭配深暗角，再現經典黑色電影光影。", ffmpegFilter: "hue=s=0,curves=all='0/0 0.2/0.09 0.5/0.5 0.8/0.91 1/1',vignette=PI/4"),
        ProVisualEffectItem(id: "sepia_warm", name: "懷舊褐調", category: "復古膠片", keywords: ["sepia", "vintage", "old", "brown", "懷舊", "褐調", "老照片", "復古"], description: "經典 RGB 色彩矩陣轉換為溫暖泛黃棕褐懷舊色調。", ffmpegFilter: "colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131:0,eq=contrast=1.04"),
        ProVisualEffectItem(id: "negative", name: "負片反色", category: "藝術風格", keywords: ["negative", "invert", "xray", "負片", "反色", "底片反轉", "前衛"], description: "反轉全畫面 RGB 色彩與明暗階調，呈現強烈負片視覺。", ffmpegFilter: "negate"),
        ProVisualEffectItem(id: "thermal", name: "熱像偽彩", category: "藝術風格", keywords: ["thermal", "heat", "infrared", "predator", "熱像", "紅外線", "偽彩", "熱感應"], description: "依影像亮度映射熱感應偽彩光譜（藍紫低溫至紅黃白高溫）。", ffmpegFilter: "format=yuv420p,pseudocolor=preset=heat"),
        ProVisualEffectItem(id: "emboss", name: "浮雕立體", category: "藝術風格", keywords: ["emboss", "relief", "sculpt", "3d", "浮雕", "立體", "雕刻", "紋理"], description: "透過 3×3 方向卷積核心與中性灰偏壓刻畫立體浮雕紋理。", ffmpegFilter: "format=gbrp,convolution=0m='-2 -1 0 -1 1 1 0 1 2':1m='-2 -1 0 -1 1 1 0 1 2':2m='-2 -1 0 -1 1 1 0 1 2':0bias=128:1bias=128:2bias=128"),
        ProVisualEffectItem(id: "bloom_soft", name: "柔光漫射", category: "光學畸變", keywords: ["bloom", "glow", "halation", "dream", "柔光", "漫射", "光暈", "黑柔鏡"], description: "將高光模糊層以濾色模式疊加回原畫面，模擬黑柔濾鏡光暈。", ffmpegFilter: "format=rgb24,split[{p}_b0][{p}_b1];[{p}_b1]gblur=sigma=12,eq=brightness=0.08:contrast=1.2[{p}_b2];[{p}_b0][{p}_b2]blend=all_mode=screen:all_opacity=0.45"),
        ProVisualEffectItem(id: "kaleido", name: "四象限萬花筒", category: "動感與鏡像", keywords: ["kaleidoscope", "quad", "mirror", "trippy", "萬花筒", "四象限", "對稱", "迷幻"], description: "取左上象限向水平、垂直與對角鏡像複製，構成四向對稱萬花筒。", ffmpegFilter: "split=4[{p}_k1][{p}_k2][{p}_k3][{p}_k4];[{p}_k1]crop=trunc(iw/2):trunc(ih/2):0:0[{p}_tl];[{p}_k2]crop=trunc(iw/2):trunc(ih/2):0:0,hflip[{p}_tr];[{p}_k3]crop=trunc(iw/2):trunc(ih/2):0:0,vflip[{p}_bl];[{p}_k4]crop=trunc(iw/2):trunc(ih/2):0:0,hflip,vflip[{p}_br];[{p}_tl][{p}_tr]hstack[{p}_top];[{p}_bl][{p}_br]hstack[{p}_bot];[{p}_top][{p}_bot]vstack"),
        ProVisualEffectItem(id: "vignette_heavy", name: "深邃暗角", category: "光學畸變", keywords: ["vignette", "dark", "spotlight", "focus", "暗角", "聚光", "壓暗", "電影感"], description: "強烈大角度四周暗角壓暗，將觀眾視線牢牢鎖定於畫面中央。", ffmpegFilter: "vignette=angle=PI/2.2:mode=forward,eq=contrast=1.08:brightness=-0.03"),
        ProVisualEffectItem(id: "bw_grain", name: "黑白顆粒", category: "復古膠片", keywords: ["bw", "grain", "tri-x", "documentary", "黑白", "顆粒", "紀實", "銀鹽"], description: "紀實銀鹽黑白影調搭配強烈動態底片顆粒感。", ffmpegFilter: "hue=s=0,noise=alls=22:allf=t+u,eq=contrast=1.18"),
        ProVisualEffectItem(id: "dreamy_haze", name: "夢幻薄霧", category: "光學畸變", keywords: ["dreamy", "haze", "pastel", "mist", "夢幻", "薄霧", "柔霧", "仙氣"], description: "柔焦變亮混合層結合粉紫高光偏移，打造唯美夢幻薄霧質感。", ffmpegFilter: "format=rgb24,split[{p}_d0][{p}_d1];[{p}_d1]gblur=sigma=8,eq=brightness=0.10:saturation=1.2[{p}_d2];[{p}_d0][{p}_d2]blend=all_mode=lighten:all_opacity=0.38,colorbalance=rh=0.06:bh=0.08"),
        ProVisualEffectItem(id: "duotone_cyber", name: "賽博雙色調", category: "調色風格", keywords: ["duotone", "cyberpunk", "magenta", "cyan", "賽博", "雙色調", "霓虹", "紫藍"], description: "將單色明暗映射為電光紫紅與冷青藍高反差賽博龐克雙色調。", ffmpegFilter: "hue=s=0,format=rgb24,lutrgb=r='clip(val*1.25+20,0,255)':g='clip(val*0.55+10,0,255)':b='clip(255-val*0.35,0,255)'"),
        ProVisualEffectItem(id: "warm_sunset", name: "日落金光", category: "調色風格", keywords: ["sunset", "golden", "warm", "amber", "日落", "金光", "夕陽", "暖色"], description: "全階調注入琥珀金與夕陽橘暖光並強化色彩飽和度。", ffmpegFilter: "colorbalance=rs=0.14:gs=0.04:bs=-0.12:rm=0.16:gm=0.05:bm=-0.14:rh=0.18:gh=0.08:bh=-0.10,eq=saturation=1.22:contrast=1.06"),
        ProVisualEffectItem(id: "cold_moonlight", name: "冷月藍調", category: "調色風格", keywords: ["moonlight", "cold", "blue", "night", "月光", "冷藍", "夜景", "清冷"], description: "壓低亮度與暖色飽和，營造靜謐深邃的月夜冷藍電影氛圍。", ffmpegFilter: "colorbalance=rs=-0.14:gs=-0.02:bs=0.18:rm=-0.12:gm=0.0:bm=0.16:rh=-0.08:gh=0.02:bh=0.14,eq=brightness=-0.05:contrast=1.12:saturation=0.78")
    ]

    // Complete 25 audio effects fallback matching effects_catalog.json
    static let fallbackAudioEffects: [ProAudioEffectItem] = [
        ProAudioEffectItem(id: "telephone", name: "復古電話", category: "復古通訊", keywords: ["telephone", "phone", "call", "電話", "通話", "窄頻"], description: "300–3000 Hz 語音帶通濾波與動態壓縮，模擬傳統話筒音質。", ffmpegFilter: "highpass=f=300,lowpass=f=3000,acompressor=threshold=-18dB:ratio=4"),
        ProAudioEffectItem(id: "robot", name: "機器人聲", category: "變聲趣味", keywords: ["robot", "metallic", "sci-fi", "機器人", "金屬聲", "科幻"], description: "高速 35Hz 音高調變結合極短金屬感回音，打造合成機器人聲。", ffmpegFilter: "vibrato=f=35:d=0.85,aecho=0.8:0.88:20:0.4"),
        ProAudioEffectItem(id: "chipmunk", name: "花栗鼠高音", category: "變聲趣味", keywords: ["chipmunk", "high pitch", "cartoon", "花栗鼠", "高音", "卡通", "變聲"], description: "提高音高 1.35 倍同時補償節奏速度，保留原本語速的可愛高音。", ffmpegFilter: "asetrate=48000*1.35,aresample=48000,atempo=0.74074"),
        ProAudioEffectItem(id: "radio_am", name: "AM 廣播電台", category: "復古通訊", keywords: ["radio", "am", "broadcast", "retro", "廣播", "電台", "收音機"], description: "中頻鼻音突出、10-bit 輕微失真與重壓縮，重現懷舊 AM 電台。", ffmpegFilter: "highpass=f=450,lowpass=f=2400,equalizer=f=1200:t=q:w=1.2:g=5,acrusher=bits=10:mix=0.25,acompressor=threshold=-20dB:ratio=6"),
        ProAudioEffectItem(id: "megaphone", name: "擴音大聲公", category: "復古通訊", keywords: ["megaphone", "bullhorn", "loud", "大聲公", "擴音器", "廣播喇叭"], description: "強烈 1.8kHz 號角共振峰、8-bit 破音感與硬限幅器。", ffmpegFilter: "highpass=f=550,lowpass=f=3600,equalizer=f=1800:t=q:w=1.5:g=8,acrusher=bits=8:mix=0.35,acompressor=threshold=-22dB:ratio=8,alimiter=limit=0.9"),
        ProAudioEffectItem(id: "walkie_talkie", name: "對講機通訊", category: "復古通訊", keywords: ["walkie", "talkie", "intercom", "tactical", "對講機", "無線電", "通訊"], description: "窄帶濾波搭配 7-bit 量化顆粒與高壓縮比，模擬無線對講機。", ffmpegFilter: "bandpass=f=1400:width_type=h:w=1800,acrusher=bits=7:mix=0.4,acompressor=threshold=-24dB:ratio=10,equalizer=f=2000:t=q:w=2.0:g=4"),
        ProAudioEffectItem(id: "deep_voice", name: "低沉男聲", category: "變聲趣味", keywords: ["deep", "low", "bass voice", "低沉", "低音", "大叔", "磁性"], description: "音高下移 0.80 倍並強化 120Hz 低頻共鳴，聲音渾厚低沉。", ffmpegFilter: "asetrate=48000*0.80,aresample=48000,atempo=1.25,bass=g=4:f=120"),
        ProAudioEffectItem(id: "helium", name: "氦氣尖細聲", category: "變聲趣味", keywords: ["helium", "squeaky", "high", "氦氣", "尖細", "搞怪", "變聲"], description: "音高大幅拉升至 1.55 倍並削去低頻，呈現吸入氦氣般的尖細滑稽音色。", ffmpegFilter: "asetrate=48000*1.55,aresample=48000,atempo=0.64516,highpass=f=200"),
        ProAudioEffectItem(id: "monster", name: "怪獸低吼", category: "變聲趣味", keywords: ["monster", "demon", "boss", "growl", "怪獸", "惡魔", "低吼", "反派"], description: "極低 0.68 倍降調、超低頻轟鳴、粗礪失真與洞穴短迴音。", ffmpegFilter: "asetrate=48000*0.68,aresample=48000,atempo=1.47059,bass=g=7:f=90,aecho=0.8:0.85:35:0.45,acrusher=bits=10:mix=0.25"),
        ProAudioEffectItem(id: "hall_reverb", name: "音樂廳殘響", category: "空間殘響", keywords: ["hall", "reverb", "concert", "音樂廳", "殘響", "混響", "空間"], description: "多層次中長反射延遲與柔和尾音高切，重現大型演奏廳空間感。", ffmpegFilter: "aecho=0.8:0.88:60|95|140:0.42|0.32|0.22,lowpass=f=9000"),
        ProAudioEffectItem(id: "room_reverb", name: "室內小廳", category: "空間殘響", keywords: ["room", "ambience", "studio", "室內", "小房間", "自然殘響"], description: "18ms 與 34ms 緊密早期反射，為乾聲增添自然室內空間氛圍。", ffmpegFilter: "aecho=0.85:0.82:18|34:0.35|0.22"),
        ProAudioEffectItem(id: "cathedral", name: "大教堂迴響", category: "空間殘響", keywords: ["cathedral", "church", "epic", "大教堂", "聖堂", "長殘響", "史詩"], description: "四重綿長高擴散反射（90–360ms），打造宏偉神聖教堂空間。", ffmpegFilter: "aecho=0.75:0.90:90|160|250|360:0.50|0.40|0.30|0.20,lowpass=f=7500"),
        ProAudioEffectItem(id: "slapback_echo", name: "拍擊短回音", category: "空間殘響", keywords: ["slapback", "echo", "rockabilly", "回音", "短延遲", "復古搖滾"], description: "經典 110ms 單次拍擊式短回音，適合旁白強調與復古風格。", ffmpegFilter: "aecho=0.85:0.80:110:0.48"),
        ProAudioEffectItem(id: "dub_delay", name: "雷鬼長延遲", category: "空間殘響", keywords: ["dub", "delay", "repeat", "echo", "長延遲", "迴聲", "漸弱回音"], description: "280/560/840ms 階梯衰減長延遲加上溫暖低通濾波。", ffmpegFilter: "aecho=0.80:0.85:280|560|840:0.55|0.35|0.20,lowpass=f=5000"),
        ProAudioEffectItem(id: "underwater", name: "水下悶響", category: "空間殘響", keywords: ["underwater", "muffled", "deep sea", "水下", "潛水", "悶響", "水底"], description: "420Hz 陡峭低通配合緩慢流動相位調變，模擬身處水底的聽感。", ffmpegFilter: "lowpass=f=420,equalizer=f=220:t=q:w=1.0:g=5,aphaser=in_gain=0.6:out_gain=0.74:delay=3.0:decay=0.4:speed=0.4"),
        ProAudioEffectItem(id: "chorus", name: "立體合唱", category: "調變節奏", keywords: ["chorus", "ensemble", "thick", "wide", "合唱", "加厚", "立體聲"], description: "三聲部微延遲與低頻掃頻交疊，使人聲或樂器更寬廣飽滿。", ffmpegFilter: "chorus=0.6:0.9:50|60|40:0.4|0.32|0.3:0.25|0.4|0.3:2|2.3|1.3"),
        ProAudioEffectItem(id: "flanger", name: "鑲邊掃頻", category: "調變節奏", keywords: ["flanger", "jet", "sweep", "psychedelic", "鑲邊", "掃頻", "噴射機"], description: "極短動態梳狀延遲回饋，產生迷幻噴射機般的頻率掃描聲。", ffmpegFilter: "flanger=delay=4:depth=3:regen=25:width=80:speed=0.6"),
        ProAudioEffectItem(id: "phaser", name: "相位推移", category: "調變節奏", keywords: ["phaser", "swirl", "space", "相位", "漩渦", "迷幻"], description: "週期性全通相位凹口掃描，營造夢幻旋轉流動感。", ffmpegFilter: "aphaser=in_gain=0.6:out_gain=0.8:delay=3.0:decay=0.55:speed=0.8:type=t"),
        ProAudioEffectItem(id: "tremolo", name: "顫音脈動", category: "調變節奏", keywords: ["tremolo", "pulse", "amplitude", "顫音", "音量脈動", "抖動"], description: "6.5Hz 正弦振幅調變，帶來鮮明復古電子琴與戲劇顫動感。", ffmpegFilter: "tremolo=f=6.5:d=0.65"),
        ProAudioEffectItem(id: "vibrato", name: "抖音調變", category: "調變節奏", keywords: ["vibrato", "pitch", "wobble", "抖音", "音高抖動", "飄忽"], description: "6.5Hz 連續音高微幅擺盪，製造奇幻飄忽與卡通震動效果。", ffmpegFilter: "vibrato=f=6.5:d=0.55"),
        ProAudioEffectItem(id: "vinyl_lofi", name: "黑膠復古 Lo-Fi", category: "復古通訊", keywords: ["vinyl", "lofi", "tape", "warm", "黑膠", "復古", "低保真", "磁帶"], description: "溫潤帶限、輕微 11-bit 類比質感與緩慢轉盤抖晃（Wow/Flutter）。", ffmpegFilter: "highpass=f=180,lowpass=f=3800,acrusher=bits=11:mix=0.22,vibrato=f=1.2:d=0.08,equalizer=f=300:t=q:w=1.0:g=3"),
        ProAudioEffectItem(id: "bass_boost", name: "重低音增強", category: "母帶均衡", keywords: ["bass", "sub", "punch", "edm", "重低音", "低頻", "震撼", "鼓點"], description: "100Hz 低頻強力提升 +8dB 並搭配動態壓縮與防爆音限幅。", ffmpegFilter: "bass=g=8:f=100:w=0.7,acompressor=threshold=-14dB:ratio=3,alimiter=limit=0.95"),
        ProAudioEffectItem(id: "vocal_presence", name: "人聲清晰穿透", category: "母帶均衡", keywords: ["vocal", "clarity", "presence", "speech", "人聲", "清晰", "穿透", "口白"], description: "切除 90Hz 低頻轟鳴並精準拉升 2.8kHz/5.5kHz 唇齒清晰度。", ffmpegFilter: "highpass=f=90,equalizer=f=2800:t=q:w=1.2:g=4.5,equalizer=f=5500:t=q:w=1.5:g=3,acompressor=threshold=-18dB:ratio=3:makeup=2"),
        ProAudioEffectItem(id: "podcast_warm", name: "播客溫暖厚實", category: "母帶均衡", keywords: ["podcast", "radio host", "warm", "broadcast", "播客", "電台人聲", "溫暖", "旁白"], description: "播客錄音室鏈條：低頻近講厚實感、中高頻明亮度與平順壓縮。", ffmpegFilter: "highpass=f=75,bass=g=4:f=130:w=0.8,equalizer=f=3200:t=q:w=1.2:g=2.5,acompressor=threshold=-20dB:ratio=3.5:attack=10:release=120,alimiter=limit=0.95"),
        ProAudioEffectItem(id: "de_esser", name: "齒音柔化", category: "母帶均衡", keywords: ["deesser", "sibilance", "smooth", "soft", "去齒音", "柔化", "人聲修復"], description: "針對 6.5kHz 與 8.5kHz 刺耳嘶聲頻段精準衰減，讓人聲更耐聽。", ffmpegFilter: "equalizer=f=6500:t=q:w=2.2:g=-6,equalizer=f=8500:t=q:w=2.0:g=-4,acompressor=threshold=-16dB:ratio=2.5")
    ]
}

// MARK: - 2. VoiceoverRecorderManager (Real AVFoundation Mic Recording)

@MainActor
final class VoiceoverRecorderManager: ObservableObject {
    static let shared = VoiceoverRecorderManager()

    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDeviceUniqueID: String = ""
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published var isRecording: Bool = false
    @Published var elapsedSeconds: Double = 0
    @Published var meterLevel: Double = 0
    @Published var meterDecibels: Float = -60
    @Published var lastRecordingPath: String? = nil
    @Published var statusMessage: String? = nil
    @Published var lastError: String? = nil

    private var audioRecorder: AVAudioRecorder?
    private var currentOutputURL: URL?
    private var meterTimer: Timer?
    private var recordStartTime: Date?

    init() {
        refreshDevicesAndPermission()
    }

    var authorizationLabel: String {
        switch authorizationStatus {
        case .authorized:
            return "已授權"
        case .notDetermined:
            return "尚未授權"
        case .denied, .restricted:
            return "已拒絕，請至系統設定開啟麥克風權限"
        @unknown default:
            return "尚未授權"
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    func refreshDevicesAndPermission() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        availableDevices = session.devices
        if selectedDeviceUniqueID.isEmpty || !availableDevices.contains(where: { $0.uniqueID == selectedDeviceUniqueID }) {
            selectedDeviceUniqueID = availableDevices.first?.uniqueID ?? ""
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refreshDevicesAndPermission()
        if !granted {
            lastError = "已拒絕，請至系統設定開啟麥克風權限"
        } else {
            lastError = nil
            statusMessage = "已取得麥克風存取權限"
        }
        return granted
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func startRecording(outputRootDir: URL? = nil) {
        guard !isRecording else { return }
        lastError = nil
        refreshDevicesAndPermission()

        switch authorizationStatus {
        case .notDetermined:
            Task { @MainActor in
                let granted = await requestMicrophoneAccess()
                if granted {
                    self.beginRecorderSession(outputRootDir: outputRootDir)
                }
            }
            return
        case .denied, .restricted:
            lastError = "已拒絕，請至系統設定開啟麥克風權限"
            return
        case .authorized:
            beginRecorderSession(outputRootDir: outputRootDir)
        @unknown default:
            lastError = "無法確認麥克風權限狀態"
        }
    }

    private func beginRecorderSession(outputRootDir: URL? = nil) {
        guard !availableDevices.isEmpty else {
            lastError = "未偵測到可用的音訊輸入裝置。"
            return
        }

        let resolvedRoot: URL = {
            if let outputRootDir { return outputRootDir }
            if let saved = UserDefaults.standard.string(forKey: "MotionDesk.defaultOutputPath"), !saved.isEmpty {
                return URL(fileURLWithPath: saved, isDirectory: true)
            }
            return proMotionDeskAppSupportDir().appendingPathComponent("Jobs", isDirectory: true)
        }()
        let datedDir = datedDirectory(under: resolvedRoot)
        do {
            try FileManager.default.createDirectory(at: datedDir, withIntermediateDirectories: true)
        } catch {
            lastError = "無法建立錄音儲存資料夾：\(error.localizedDescription)"
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let outURL = allocateUniqueDatedOutputURL(
            under: resolvedRoot,
            stem: "Voiceover-\(formatter.string(from: Date()))",
            ext: "wav"
        )

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: outURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                lastError = "無法啟動麥克風錄音（請確認輸入裝置正常）。"
                return
            }
            self.audioRecorder = recorder
            self.currentOutputURL = outURL
            self.recordStartTime = Date()
            self.elapsedSeconds = 0
            self.meterLevel = 0
            self.meterDecibels = -60
            self.isRecording = true
            let devName = availableDevices.first(where: { $0.uniqueID == selectedDeviceUniqueID })?.localizedName ?? "系統預設麥克風"
            self.statusMessage = "錄音中（48kHz 16-bit WAV）· \(devName)"

            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tickMeter()
                }
            }
        } catch {
            lastError = "啟動錄音失敗：\(error.localizedDescription)"
        }
    }

    private func tickMeter() {
        guard isRecording, let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let avgDb = recorder.averagePower(forChannel: 0)
        let clampedDb = max(-60.0, min(0.0, avgDb))
        meterDecibels = clampedDb
        meterLevel = Double((clampedDb + 60.0) / 60.0)
        if let start = recordStartTime {
            elapsedSeconds = max(recorder.currentTime, Date().timeIntervalSince(start))
        } else {
            elapsedSeconds = recorder.currentTime
        }
    }

    @discardableResult
    func stopAndReturnPath() -> String? {
        meterTimer?.invalidate()
        meterTimer = nil

        guard let recorder = audioRecorder, let url = currentOutputURL else {
            isRecording = false
            meterLevel = 0
            return nil
        }

        recorder.stop()
        audioRecorder = nil
        currentOutputURL = nil
        recordStartTime = nil
        isRecording = false
        meterLevel = 0
        meterDecibels = -60

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.fileExists(atPath: url.path), fileSize > 44 else {
            lastError = "錄音檔案為空，未加入音訊軌。"
            return nil
        }

        lastRecordingPath = url.path
        statusMessage = "已儲存旁白錄音 · \(url.lastPathComponent)"
        return url.path
    }
}

// MARK: - 3. AudioAIManager (Bundled audio_ai.py + Audition + 540p Proxy)

struct AudioAISpeakerOption: Identifiable, Equatable, Hashable {
    let id: Int
    let code: String
    let displayName: String

    static let chineseSpeakers: [AudioAISpeakerOption] = [
        AudioAISpeakerOption(id: 45, code: "zf_xiaobei", displayName: "曉貝（女聲）"),
        AudioAISpeakerOption(id: 46, code: "zf_xiaoni", displayName: "曉妮（女聲）"),
        AudioAISpeakerOption(id: 47, code: "zf_xiaoxiao", displayName: "曉曉（女聲）"),
        AudioAISpeakerOption(id: 48, code: "zf_xiaoyi", displayName: "曉伊（女聲）"),
        AudioAISpeakerOption(id: 49, code: "zm_yunjian", displayName: "雲健（男聲）"),
        AudioAISpeakerOption(id: 50, code: "zm_yunxi", displayName: "雲希（男聲）"),
        AudioAISpeakerOption(id: 51, code: "zm_yunxia", displayName: "雲夏（男聲）"),
        AudioAISpeakerOption(id: 52, code: "zm_yunyang", displayName: "雲揚（男聲）")
    ]
}

struct AudioAIModuleStatus: Identifiable, Equatable {
    let id: String
    let installed: Bool
    let venvInstalled: Bool
    let modelInstalled: Bool
    let displayName: String
    let modelName: String
    let sizeMB: Int
    let diskSizeBytes: Int64
    let license: String
    let sourceURL: String
    let installedPath: String

    var isReady: Bool { installed && venvInstalled && modelInstalled }

    static let defaults: [String: AudioAIModuleStatus] = [
        "vocal_sep": AudioAIModuleStatus(
            id: "vocal_sep",
            installed: false,
            venvInstalled: false,
            modelInstalled: false,
            displayName: "人聲與伴奏分離 (UVR MDX-Net)",
            modelName: "UVR-MDX-NET-Inst_HQ_3.onnx",
            sizeMB: 55,
            diskSizeBytes: 0,
            license: "MIT",
            sourceURL: "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Inst_HQ_3.onnx",
            installedPath: ""
        ),
        "asr": AudioAIModuleStatus(
            id: "asr",
            installed: false,
            venvInstalled: false,
            modelInstalled: false,
            displayName: "自動字幕 ASR (Faster-Whisper Base INT8)",
            modelName: "Systran/faster-whisper-base (INT8)",
            sizeMB: 145,
            diskSizeBytes: 0,
            license: "MIT",
            sourceURL: "https://huggingface.co/Systran/faster-whisper-base",
            installedPath: ""
        ),
        "asr_breeze26": AudioAIModuleStatus(
            id: "asr_breeze26",
            installed: false,
            venvInstalled: false,
            modelInstalled: false,
            displayName: "台灣語音自動字幕 (Breeze-ASR-26 INT8)",
            modelName: "MediaTek-Research/Breeze-ASR-26 (INT8)",
            sizeMB: 1550,
            diskSizeBytes: 0,
            license: "Apache-2.0",
            sourceURL: "https://huggingface.co/MediaTek-Research/Breeze-ASR-26",
            installedPath: ""
        ),
        "tts": AudioAIModuleStatus(
            id: "tts",
            installed: false,
            venvInstalled: false,
            modelInstalled: false,
            displayName: "中文配音 TTS (Sherpa-ONNX Kokoro INT8)",
            modelName: "kokoro-int8-multi-lang-v1_0",
            sizeMB: 132,
            diskSizeBytes: 0,
            license: "Apache-2.0",
            sourceURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2",
            installedPath: ""
        ),
        "voice_clone": AudioAIModuleStatus(
            id: "voice_clone",
            installed: false,
            venvInstalled: false,
            modelInstalled: false,
            displayName: "聲音複製 (Sherpa-ONNX ZipVoice-Distill)",
            modelName: "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia",
            sizeMB: 180,
            diskSizeBytes: 0,
            license: "Apache-2.0",
            sourceURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2",
            installedPath: ""
        )
    ]
}

struct VocalSeparationResult: Equatable {
    let vocalsPath: String
    let accompanimentPath: String
    let model: String
    let duration: Double
    let sampleRate: Int
}

struct ASRSubtitleSegment: Equatable, Identifiable {
    let id = UUID()
    let start: Double
    let end: Double
    var text: String
}

struct ASRTranscriptionResult: Equatable {
    let segments: [ASRSubtitleSegment]
    let srtPath: String
    let language: String
    let duration: Double
    let model: String
}

struct TTSGenerationResult: Equatable {
    let path: String
    let duration: Double
    let sampleRate: Int
    let speaker: Int
    let speakerName: String
    let speakerLabel: String
}

struct VoiceCloneResult: Equatable {
    let path: String
    let duration: Double
    let sampleRate: Int
    let refTextUsed: String
    let refTextAutoTranscribed: Bool
}

enum AudioAIError: LocalizedError {
    case scriptNotFound(String)
    case executionFailed(String)
    case invalidOutput(String)
    case ffmpegMissing
    case statusTimedOut(Double)
    case statusCancelled

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let name): return "找不到內建工具腳本：\(name)"
        case .executionFailed(let msg): return msg
        case .invalidOutput(let msg): return "工具回傳格式無效：\(msg)"
        case .ffmpegMissing: return "找不到可用的 FFmpeg 執行檔（/opt/homebrew/bin/ffmpeg）。"
        case .statusTimedOut(let sec): return String(format: "音訊 AI 環境狀態檢查逾時（超過 %.0f 秒），已自動中止；請點擊「重試檢查」。", sec)
        case .statusCancelled: return "已取消音訊 AI 環境狀態檢查。"
        }
    }
}

private struct ProcessCaptureResult: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

@MainActor
final class AudioAIManager: ObservableObject {
    static let shared = AudioAIManager()

    @Published var modules: [String: AudioAIModuleStatus] = AudioAIModuleStatus.defaults
    @Published var venvReady: Bool = false
    @Published var venvPythonVersion: String? = nil
    @Published var venvDiskBytes: Int64 = 0
    @Published var totalInstalledBytes: Int64 = 0
    @Published var venvDirPath: String = proMotionDeskAppSupportDir().appendingPathComponent("ai-audio-venv").path
    @Published var hasLoadedStatus: Bool = false
    @Published var isRefreshingStatus: Bool = false
    @Published var statusTimedOut: Bool = false

    @Published var busyModule: String? = nil
    @Published var progressLog: String = ""
    @Published var lastError: String? = nil
    @Published var lastStatusMessage: String? = nil

    @Published var auditioningEffectID: String? = nil
    @Published var isPlayingAudition: Bool = false
    @Published var auditionFilePath: String? = nil

    var audioAIScriptOverride: URL? = nil
    var timelineRenderScriptOverride: URL? = nil
    var statusProbeTimeoutSeconds: TimeInterval = 12.0

    private var auditionPlayer: AVAudioPlayer?
    private var auditionStopTimer: Timer?
    private var activeStatusProcess: Process?
    private var activeStatusTask: Task<Void, Never>?

    init() {}

    func resolveAudioAIScriptURL() -> URL? {
        if let override = audioAIScriptOverride, FileManager.default.fileExists(atPath: override.path) {
            return override
        }
        if let bundled = Bundle.main.url(forResource: "audio_ai", withExtension: "py") {
            return bundled
        }
        for rel in ["studio-v5/staged/resources/audio_ai.py", "studio-v4/staged/resources/audio_ai.py"] {
            let devFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: devFallback.path) {
                return devFallback
            }
        }
        return nil
    }

    func resolveTimelineRenderScriptURL() -> URL? {
        if let override = timelineRenderScriptOverride, FileManager.default.fileExists(atPath: override.path) {
            return override
        }
        if let bundled = Bundle.main.url(forResource: "timeline_render", withExtension: "py") {
            return bundled
        }
        for rel in ["studio-v5/staged/resources/timeline_render.py", "studio-v4/staged/resources/timeline_render.py"] {
            let devFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: devFallback.path) {
                return devFallback
            }
        }
        return nil
    }

    private func appendLogLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if progressLog.isEmpty {
            progressLog = trimmed
        } else {
            progressLog += "\n" + trimmed
        }
        if progressLog.count > 16000 {
            progressLog = String(progressLog.suffix(12000))
        }
    }

    private func runProcessAsync(
        executable: String,
        arguments: [String],
        streamStderr: Bool = true,
        timeoutSeconds: TimeInterval? = nil,
        trackAsStatusProbe: Bool = false
    ) async throws -> ProcessCaptureResult {
        let logSink: (@Sendable (String) -> Void)?
        if streamStderr {
            logSink = { [weak self] chunk in
                DispatchQueue.main.async {
                    self?.appendLogLine(chunk)
                }
            }
        } else {
            logSink = nil
        }

        let process = Process()
        if trackAsStatusProbe {
            self.activeStatusProcess = process
        }
        defer {
            if trackAsStatusProbe && self.activeStatusProcess === process {
                self.activeStatusProcess = nil
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            var env = ProcessInfo.processInfo.environment
            let prefix = "/opt/homebrew/bin:/usr/local/bin"
            if let existing = env["PATH"], !existing.isEmpty {
                env["PATH"] = "\(prefix):\(existing)"
            } else {
                env["PATH"] = "\(prefix):/usr/bin:/bin"
            }
            env["PYTHONUNBUFFERED"] = "1"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            final class BufferBox: @unchecked Sendable {
                private let lock = NSLock()
                var data = Data()
                var didTimeout = false
                func append(_ chunk: Data) {
                    lock.lock()
                    data.append(chunk)
                    lock.unlock()
                }
                func markTimedOut() {
                    lock.lock()
                    didTimeout = true
                    lock.unlock()
                }
                func isTimedOut() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return didTimeout
                }
                func snapshot() -> Data {
                    lock.lock()
                    defer { lock.unlock() }
                    return data
                }
            }

            let outBox = BufferBox()
            let errBox = BufferBox()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    outBox.append(chunk)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    errBox.append(chunk)
                    if let logSink, let text = String(data: chunk, encoding: .utf8) {
                        logSink(text)
                    }
                }
            }

            try process.run()
            // Close parent's write ends immediately after launch to prevent EOF hangs.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()

            var watchdogItem: DispatchWorkItem? = nil
            if let timeoutSeconds, timeoutSeconds > 0 {
                let item = DispatchWorkItem {
                    if process.isRunning {
                        outBox.markTimedOut()
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
                watchdogItem = item
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: item)
            }

            process.waitUntilExit()
            watchdogItem?.cancel()

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let remOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !remOut.isEmpty { outBox.append(remOut) }
            let remErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !remErr.isEmpty {
                errBox.append(remErr)
                if let logSink, let text = String(data: remErr, encoding: .utf8) {
                    logSink(text)
                }
            }

            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()

            let stdoutStr = String(data: outBox.snapshot(), encoding: .utf8) ?? ""
            let stderrStr = String(data: errBox.snapshot(), encoding: .utf8) ?? ""
            return ProcessCaptureResult(
                terminationStatus: process.terminationStatus,
                stdout: stdoutStr,
                stderr: stderrStr,
                timedOut: outBox.isTimedOut()
            )
        }.value
    }

    private func runAudioAICommand(
        args: [String],
        streamStderr: Bool = true,
        timeoutSeconds: TimeInterval? = nil,
        trackAsStatusProbe: Bool = false
    ) async throws -> [String: Any] {
        guard let scriptURL = resolveAudioAIScriptURL() else {
            throw AudioAIError.scriptNotFound("audio_ai.py")
        }
        // Prefer known valid isolated audio venv Python if present, avoiding unnecessary /usr/bin/python3 bootstrap overhead.
        let venvPy = proMotionDeskAppSupportDir().appendingPathComponent("ai-audio-venv/bin/python").path
        let pythonExe = FileManager.default.isExecutableFile(atPath: venvPy) ? venvPy : "/usr/bin/python3"
        let result = try await runProcessAsync(
            executable: pythonExe,
            arguments: [scriptURL.path] + args,
            streamStderr: streamStderr,
            timeoutSeconds: timeoutSeconds,
            trackAsStatusProbe: trackAsStatusProbe
        )
        if result.timedOut {
            throw AudioAIError.statusTimedOut(timeoutSeconds ?? statusProbeTimeoutSeconds)
        }
        let jsonDict = parseLastJSONObject(from: result.stdout)
        if result.terminationStatus != 0 {
            if let errMsg = jsonDict?["error"] as? String, !errMsg.isEmpty {
                throw AudioAIError.executionFailed(errMsg)
            }
            let tail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
            throw AudioAIError.executionFailed(tail.isEmpty ? "audio_ai.py 執行失敗（代碼 \(result.terminationStatus)）" : String(tail))
        }
        guard let jsonDict else {
            throw AudioAIError.invalidOutput(String(result.stdout.prefix(240)))
        }
        if let ok = jsonDict["ok"] as? Bool, !ok {
            let errMsg = (jsonDict["error"] as? String) ?? "音訊 AI 執行回傳失敗。"
            throw AudioAIError.executionFailed(errMsg)
        }
        return jsonDict
    }

    private func parseLastJSONObject(from stdout: String) -> [String: Any]? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        if let idx = trimmed.lastIndex(of: "{") {
            let slice = String(trimmed[idx...])
            if let data = slice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    // MARK: Status / Install / Uninstall

    func refreshStatus(forceRecalculateSizes: Bool = false) {
        activeStatusTask?.cancel()
        activeStatusTask = Task { @MainActor in
            await refreshStatusAsync(forceRecalculateSizes: forceRecalculateSizes)
        }
    }

    func cancelStatusRefresh() {
        if let proc = activeStatusProcess, proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                kill(pid, SIGKILL)
            }
        }
        activeStatusProcess = nil
        activeStatusTask?.cancel()
        activeStatusTask = nil
        isRefreshingStatus = false
        hasLoadedStatus = true
        statusTimedOut = false
        lastError = AudioAIError.statusCancelled.localizedDescription
    }

    func refreshStatusAsync(forceRecalculateSizes: Bool = false) async {
        if isRefreshingStatus {
            if let proc = activeStatusProcess, proc.isRunning {
                proc.terminate()
            }
        }
        isRefreshingStatus = true
        statusTimedOut = false
        defer { isRefreshingStatus = false }
        do {
            var cmdArgs = ["status"]
            if forceRecalculateSizes {
                cmdArgs.append("--refresh-sizes")
            }
            let dict = try await runAudioAICommand(
                args: cmdArgs,
                streamStderr: false,
                timeoutSeconds: statusProbeTimeoutSeconds,
                trackAsStatusProbe: true
            )
            applyStatusPayload(dict)
            hasLoadedStatus = true
            statusTimedOut = false
            lastError = nil
        } catch is CancellationError {
            hasLoadedStatus = true
            lastError = AudioAIError.statusCancelled.localizedDescription
        } catch let err as AudioAIError {
            hasLoadedStatus = true
            if case .statusTimedOut = err {
                statusTimedOut = true
            }
            lastError = err.localizedDescription
        } catch {
            hasLoadedStatus = true
            lastError = error.localizedDescription
        }
    }

    func applyStatusPayload(_ dict: [String: Any]) {
        if let vDir = dict["venvDir"] as? String, !vDir.isEmpty {
            venvDirPath = vDir
        }
        if let totalBytes = (dict["totalInstalledBytes"] as? NSNumber)?.int64Value {
            totalInstalledBytes = totalBytes
        }
        if let venvDict = dict["venv"] as? [String: Any] {
            venvReady = (venvDict["installed"] as? Bool) ?? (venvDict["ready"] as? Bool) ?? false
            venvDiskBytes = (venvDict["diskSizeBytes"] as? NSNumber)?.int64Value ?? 0
            venvPythonVersion = venvDict["pythonVersion"] as? String
        }
        guard let modsDict = dict["modules"] as? [String: Any] else { return }

        var updated = AudioAIModuleStatus.defaults
        for key in ["vocal_sep", "asr", "tts", "voice_clone"] {
            guard let m = modsDict[key] as? [String: Any] else { continue }
            let fallback = AudioAIModuleStatus.defaults[key]!
            let modelInstalled = (m["installed"] as? Bool) ?? false
            let needsVenv = (m["needsVenv"] as? Bool) ?? !venvReady
            let ready = (m["ready"] as? Bool) ?? (modelInstalled && !needsVenv)
            let displayName = (m["title"] as? String) ?? fallback.displayName
            let modelName = (m["activeModel"] as? String) ?? (m["engine"] as? String) ?? fallback.modelName
            let sizeMB = (m["estimatedSizeMB"] as? NSNumber)?.intValue ?? fallback.sizeMB
            let diskSize = (m["diskSizeBytes"] as? NSNumber)?.int64Value ?? 0
            let license = (m["license"] as? String) ?? fallback.license
            let sourceURL = (m["sourceUrl"] as? String) ?? fallback.sourceURL
            let installedPath = (m["modelPath"] as? String) ?? ""

            updated[key] = AudioAIModuleStatus(
                id: key,
                installed: ready,
                venvInstalled: !needsVenv,
                modelInstalled: modelInstalled,
                displayName: displayName,
                modelName: modelName,
                sizeMB: sizeMB,
                diskSizeBytes: diskSize,
                license: license,
                sourceURL: sourceURL,
                installedPath: installedPath
            )
        }
        // Contract consistency guard: if any module reports ready (model + venv), venv cannot be reported unready.
        if !venvReady && updated.values.contains(where: { $0.isReady }) {
            venvReady = true
        }
        modules = updated
    }

    func install(module: String) {
        guard busyModule == nil else { return }
        busyModule = module
        lastError = nil
        progressLog = "開始安裝模組：\(module)..."
        lastStatusMessage = "正在安裝 \(module)（背景下載與建立獨立環境）..."

        Task { @MainActor in
            defer { self.busyModule = nil }
            do {
                _ = try await runAudioAICommand(args: ["install", "--module", module], streamStderr: true)
                await refreshStatusAsync()
                lastStatusMessage = "已完成安裝：\(module)"
            } catch {
                lastError = error.localizedDescription
                lastStatusMessage = nil
                await refreshStatusAsync()
            }
        }
    }

    func uninstall(module: String) {
        guard busyModule == nil else { return }
        busyModule = module
        lastError = nil
        progressLog = "開始移除模組：\(module)..."
        lastStatusMessage = "正在移除 \(module)..."

        Task { @MainActor in
            defer { self.busyModule = nil }
            do {
                _ = try await runAudioAICommand(args: ["uninstall", "--module", module], streamStderr: true)
                await refreshStatusAsync()
                lastStatusMessage = "已移除：\(module)"
            } catch {
                lastError = error.localizedDescription
                lastStatusMessage = nil
                await refreshStatusAsync()
            }
        }
    }

    // MARK: Neural Inference Pipelines

    func runVocalSeparation(
        inputPath: String,
        outputDir: URL,
        vocalsOutputURL: URL? = nil,
        accompanimentOutputURL: URL? = nil
    ) async throws -> VocalSeparationResult {
        guard busyModule == nil else {
            throw AudioAIError.executionFailed("目前有其他音訊 AI 任務正在執行，請稍候。")
        }
        busyModule = "vocal_sep"
        lastError = nil
        progressLog = "啟動人聲與伴奏分離 (UVR MDX-Net)..."
        lastStatusMessage = "正在分離人聲與伴奏..."
        defer { busyModule = nil }

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            var cmdArgs = ["separate", "--input", inputPath, "--output-dir", outputDir.path]
            if let vocalsOutputURL {
                try FileManager.default.createDirectory(at: vocalsOutputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                cmdArgs.append(contentsOf: ["--vocals-output", vocalsOutputURL.path])
            }
            if let accompanimentOutputURL {
                try FileManager.default.createDirectory(at: accompanimentOutputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                cmdArgs.append(contentsOf: ["--accompaniment-output", accompanimentOutputURL.path])
            }
            let dict = try await runAudioAICommand(
                args: cmdArgs,
                streamStderr: true
            )
            guard let vocalsPath = dict["vocalsPath"] as? String,
                  let accPath = dict["accompanimentPath"] as? String else {
                throw AudioAIError.invalidOutput("缺少 vocalsPath / accompanimentPath")
            }
            let result = VocalSeparationResult(
                vocalsPath: vocalsPath,
                accompanimentPath: accPath,
                model: (dict["model"] as? String) ?? "UVR-MDX-NET",
                duration: (dict["duration"] as? NSNumber)?.doubleValue ?? 0,
                sampleRate: (dict["sampleRate"] as? NSNumber)?.intValue ?? 44100
            )
            lastStatusMessage = "人聲與伴奏分離完成"
            return result
        } catch {
            lastError = error.localizedDescription
            lastStatusMessage = nil
            throw error
        }
    }

    func runASR(
        inputPath: String,
        language: String,
        initialPrompt: String = "",
        model: String = "auto",
        outputDir: URL,
        outputSRTURL: URL? = nil
    ) async throws -> ASRTranscriptionResult {
        guard busyModule == nil else {
            throw AudioAIError.executionFailed("目前有其他音訊 AI 任務正在執行，請稍候。")
        }
        busyModule = model == "breeze26" ? "asr_breeze26" : "asr"
        lastError = nil
        progressLog = model == "breeze26"
            ? "啟動台灣語音字幕辨識 (MediaTek Breeze-ASR-26 INT8)..."
            : "啟動自動字幕辨識 (Faster-Whisper INT8)..."
        lastStatusMessage = "正在進行語音轉字幕草稿..."
        defer { busyModule = nil }

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            var cmdArgs = ["asr", "--input", inputPath, "--output-dir", outputDir.path, "--language", language, "--model", model]
            if let outputSRTURL {
                try FileManager.default.createDirectory(at: outputSRTURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                cmdArgs.append(contentsOf: ["--output-srt", outputSRTURL.path])
            }
            let trimmedPrompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                cmdArgs.append(contentsOf: ["--initial-prompt", trimmedPrompt])
            }
            let dict = try await runAudioAICommand(args: cmdArgs, streamStderr: true)
            let rawSegments = (dict["segments"] as? [[String: Any]]) ?? []
            let parsedSegments: [ASRSubtitleSegment] = rawSegments.compactMap { seg in
                guard let start = (seg["start"] as? NSNumber)?.doubleValue,
                      let end = (seg["end"] as? NSNumber)?.doubleValue,
                      let text = seg["text"] as? String else { return nil }
                return ASRSubtitleSegment(start: start, end: end, text: text)
            }
            let srtPath = (dict["srtPath"] as? String) ?? outputSRTURL?.path ?? outputDir.appendingPathComponent("subtitles.srt").path
            let modelName = (dict["model"] as? String) ?? "Systran/faster-whisper-base (INT8)"
            let result = ASRTranscriptionResult(
                segments: parsedSegments,
                srtPath: srtPath,
                language: (dict["language"] as? String) ?? language,
                duration: (dict["duration"] as? NSNumber)?.doubleValue ?? 0,
                model: modelName
            )
            lastStatusMessage = "已完成字幕草稿辨識（共 \(parsedSegments.count) 條，請檢視修正後匯入 T 軌）"
            return result
        } catch {
            lastError = error.localizedDescription
            lastStatusMessage = nil
            throw error
        }
    }

    static func formatSRTTimestamp(_ seconds: Double) -> String {
        let msTotal = max(0, Int((seconds * 1000.0).rounded()))
        let hours = msTotal / 3_600_000
        let mins = (msTotal % 3_600_000) / 60_000
        let secs = (msTotal % 60_000) / 1000
        let millis = msTotal % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, millis)
    }

    static func writeSRT(segments: [ASRSubtitleSegment], to path: String) throws {
        var lines: [String] = []
        var idx = 1
        for seg in segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append("\(idx)")
            lines.append("\(formatSRTTimestamp(seg.start)) --> \(formatSRTTimestamp(seg.end))")
            lines.append(trimmed)
            lines.append("")
            idx += 1
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func runTTS(text: String, speakerID: Int, speed: Double, outputURL: URL) async throws -> TTSGenerationResult {
        guard busyModule == nil else {
            throw AudioAIError.executionFailed("目前有其他音訊 AI 任務正在執行，請稍候。")
        }
        busyModule = "tts"
        lastError = nil
        progressLog = "啟動中文配音合成 (Kokoro INT8, speaker=\(speakerID))..."
        lastStatusMessage = "正在合成中文神經網路語音..."
        defer { busyModule = nil }

        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dict = try await runAudioAICommand(
                args: [
                    "tts",
                    "--text", text,
                    "--output", outputURL.path,
                    "--speaker", String(speakerID),
                    "--speed", String(format: "%.2f", speed)
                ],
                streamStderr: true
            )
            let outPath = (dict["path"] as? String) ?? outputURL.path
            let result = TTSGenerationResult(
                path: outPath,
                duration: (dict["duration"] as? NSNumber)?.doubleValue ?? 0,
                sampleRate: (dict["sampleRate"] as? NSNumber)?.intValue ?? 24000,
                speaker: (dict["speaker"] as? NSNumber)?.intValue ?? speakerID,
                speakerName: (dict["speakerName"] as? String) ?? "speaker_\(speakerID)",
                speakerLabel: (dict["speakerLabel"] as? String) ?? "說話人 #\(speakerID)"
            )
            lastStatusMessage = "中文配音合成完成（\(String(format: "%.1fs", result.duration))）"
            return result
        } catch {
            lastError = error.localizedDescription
            lastStatusMessage = nil
            throw error
        }
    }

    func runVoiceClone(
        refAudioPath: String,
        refText: String,
        text: String,
        speed: Double,
        outputURL: URL
    ) async throws -> VoiceCloneResult {
        guard busyModule == nil else {
            throw AudioAIError.executionFailed("目前有其他音訊 AI 任務正在執行，請稍候。")
        }
        busyModule = "voice_clone"
        lastError = nil
        progressLog = "啟動零樣本聲音複製 (ZipVoice-Distill INT8)..."
        lastStatusMessage = "正在執行聲音複製合成..."
        defer { busyModule = nil }

        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dict = try await runAudioAICommand(
                args: [
                    "voice-clone",
                    "--ref-audio", refAudioPath,
                    "--text", text,
                    "--output", outputURL.path,
                    "--ref-text", refText,
                    "--speed", String(format: "%.2f", speed),
                    "--num-steps", "4"
                ],
                streamStderr: true
            )
            let outPath = (dict["path"] as? String) ?? outputURL.path
            let result = VoiceCloneResult(
                path: outPath,
                duration: (dict["duration"] as? NSNumber)?.doubleValue ?? 0,
                sampleRate: (dict["sampleRate"] as? NSNumber)?.intValue ?? 24000,
                refTextUsed: (dict["refTextUsed"] as? String) ?? refText,
                refTextAutoTranscribed: (dict["refTextAutoTranscribed"] as? Bool) ?? false
            )
            lastStatusMessage = "聲音複製合成完成（\(String(format: "%.1fs", result.duration))）"
            return result
        } catch {
            lastError = error.localizedDescription
            lastStatusMessage = nil
            throw error
        }
    }

    // MARK: Audio FX Audition & Local Playback

    func stopAudition() {
        auditionStopTimer?.invalidate()
        auditionStopTimer = nil
        auditionPlayer?.stop()
        auditionPlayer = nil
        isPlayingAudition = false
        auditioningEffectID = nil
    }

    func playLocalAudioFile(path: String, tag: String = "local") {
        stopAudition()
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "找不到試聽音檔：\(url.lastPathComponent)"
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            self.auditionPlayer = player
            self.auditionFilePath = url.path
            self.auditioningEffectID = tag
            self.isPlayingAudition = true
            let dur = max(0.5, player.duration + 0.15)
            auditionStopTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stopAudition()
                }
            }
        } catch {
            lastError = "無法播放試聽音檔：\(error.localizedDescription)"
        }
    }

    func previewAudioEffect(sourcePath: String, effectID: String) {
        if isPlayingAudition && auditioningEffectID == effectID {
            stopAudition()
            return
        }
        stopAudition()
        lastError = nil
        auditioningEffectID = effectID
        lastStatusMessage = "正在生成音訊特效試聽（\(effectID)）..."

        Task { @MainActor in
            do {
                let previewURL = try await renderAudioFXAuditionWAV(sourcePath: sourcePath, effectID: effectID)
                lastStatusMessage = "試聽中：\(EffectsCatalogStore.shared.audioEffect(id: effectID)?.name ?? effectID)"
                playLocalAudioFile(path: previewURL.path, tag: effectID)
            } catch {
                auditioningEffectID = nil
                isPlayingAudition = false
                lastError = "音訊特效試聽失敗：\(error.localizedDescription)"
            }
        }
    }

    private func renderAudioFXAuditionWAV(sourcePath: String, effectID: String) async throws -> URL {
        let cacheDir = proMotionDeskAppSupportDir().appendingPathComponent("AudioFXPreviewCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let key = proShortSHA256("\(sourcePath)|\(effectID)")
        let outURL = cacheDir.appendingPathComponent("fx-\(effectID)-\(key).wav")

        // 1. Try bundled timeline_render.py --preview-audio-fx if supported.
        if let renderScript = resolveTimelineRenderScriptURL() {
            let res = try await runProcessAsync(
                executable: "/usr/bin/python3",
                arguments: [renderScript.path, "--preview-audio-fx", sourcePath, effectID, outURL.path],
                streamStderr: false
            )
            if res.terminationStatus == 0 && FileManager.default.fileExists(atPath: outURL.path) {
                return outURL
            }
        }

        // 2. Resilient direct FFmpeg fallback using the exact effects_catalog.json DSP filter chain.
        guard let ffmpeg = proLocateFFmpeg() else {
            throw AudioAIError.ffmpegMissing
        }
        var filterChain = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"
        if effectID != "none",
           let fx = EffectsCatalogStore.shared.audioEffect(id: effectID),
           !fx.ffmpegFilter.isEmpty {
            filterChain += ",\(fx.ffmpegFilter)"
        }
        filterChain += ",alimiter=limit=0.96,aresample=48000"

        let res = try await runProcessAsync(
            executable: ffmpeg,
            arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", sourcePath,
                "-t", "8",
                "-vn",
                "-af", filterChain,
                "-c:a", "pcm_s16le",
                "-ar", "48000",
                "-ac", "2",
                outURL.path
            ],
            streamStderr: false
        )
        guard res.terminationStatus == 0, FileManager.default.fileExists(atPath: outURL.path) else {
            let errText = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AudioAIError.executionFailed(errText.isEmpty ? "FFmpeg 音訊試聽渲染失敗（來源可能無音軌）。" : errText)
        }
        return outURL
    }

    // MARK: 540p Edit Proxy Generation

    func generateProxyForClip(sourcePath: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw AudioAIError.executionFailed("找不到原始影片檔案：\(filename(sourcePath))")
        }
        let proxyDir = proMotionDeskAppSupportDir().appendingPathComponent("Proxies", isDirectory: true)
        try FileManager.default.createDirectory(at: proxyDir, withIntermediateDirectories: true)

        let stem = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let safeStem = stem.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let hash = proShortSHA256(sourcePath)
        let outURL = proxyDir.appendingPathComponent("\(safeStem.prefix(32))-\(hash)-540p.mp4")

        // 1. Try bundled timeline_render.py --build-proxy if supported.
        if let renderScript = resolveTimelineRenderScriptURL() {
            let res = try await runProcessAsync(
                executable: "/usr/bin/python3",
                arguments: [renderScript.path, "--build-proxy", sourcePath, outURL.path],
                streamStderr: false
            )
            if res.terminationStatus == 0 && FileManager.default.fileExists(atPath: outURL.path) {
                return outURL.path
            }
        }

        // 2. Resilient direct FFmpeg 540p H.264 proxy generation fallback.
        guard let ffmpeg = proLocateFFmpeg() else {
            throw AudioAIError.ffmpegMissing
        }
        let res = try await runProcessAsync(
            executable: ffmpeg,
            arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", sourcePath,
                "-vf", "scale=-2:540",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "23",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-b:a", "128k",
                "-movflags", "+faststart",
                outURL.path
            ],
            streamStderr: false
        )
        guard res.terminationStatus == 0, FileManager.default.fileExists(atPath: outURL.path) else {
            let errText = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AudioAIError.executionFailed(errText.isEmpty ? "FFmpeg 540p 代理轉碼失敗。" : errText)
        }
        return outURL.path
    }
}

// MARK: - Shared Vector Shape Geometry (Matches TextRender.swift buildShapePath)

struct ProVectorShape: Shape {
    let kind: ShapeKind
    let cornerRadiusRatio: CGFloat
    let lineThickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let minDim = min(w, h)

        switch kind {
        case .rect:
            return Path(rect)
        case .roundedRect:
            let r = min(max(0, cornerRadiusRatio) * (minDim * 0.5), minDim * 0.5)
            return Path(roundedRect: rect, cornerRadius: r)
        case .pill:
            let r = minDim * 0.5
            return Path(roundedRect: rect, cornerRadius: r)
        case .ellipse:
            return Path(ellipseIn: rect)
        case .triangle:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        case .star:
            var p = Path()
            let cx = rect.midX
            let cy = rect.midY
            let rxOuter = w * 0.5
            let ryOuter = h * 0.5
            let innerRatio: CGFloat = 0.42
            let points = 5
            for i in 0..<(points * 2) {
                let angle = -CGFloat.pi / 2.0 + CGFloat(i) * (CGFloat.pi / CGFloat(points))
                let ratio: CGFloat = (i % 2 == 0) ? 1.0 : innerRatio
                let px = cx + cos(angle) * rxOuter * ratio
                let py = cy + sin(angle) * ryOuter * ratio
                if i == 0 {
                    p.move(to: CGPoint(x: px, y: py))
                } else {
                    p.addLine(to: CGPoint(x: px, y: py))
                }
            }
            p.closeSubpath()
            return p
        case .arrow:
            var p = Path()
            let shaftHalfH = h * 0.21
            let headX = rect.minX + w * 0.58
            p.move(to: CGPoint(x: rect.minX, y: rect.midY - shaftHalfH))
            p.addLine(to: CGPoint(x: headX, y: rect.midY - shaftHalfH))
            p.addLine(to: CGPoint(x: headX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: headX, y: rect.maxY))
            p.addLine(to: CGPoint(x: headX, y: rect.midY + shaftHalfH))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY + shaftHalfH))
            p.closeSubpath()
            return p
        case .line:
            let thickness = max(2.0, min(h, lineThickness))
            let lineRect = CGRect(x: rect.minX, y: rect.midY - thickness * 0.5, width: w, height: thickness)
            return Path(roundedRect: lineRect, cornerRadius: min(thickness * 0.5, w * 0.5))
        }
    }
}

private func proLinearGradientPoints(angleDegrees: Double) -> (start: UnitPoint, end: UnitPoint) {
    let rad = angleDegrees * Double.pi / 180.0
    let dx = cos(rad) * 0.5
    let dy = sin(rad) * 0.5
    return (
        UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
        UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
    )
}

// MARK: - 4.1 ShapesLibrarySectionView (All 8 Editable Shapes)

struct ShapesLibrarySectionView: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    var searchQuery: String

    init(
        app: Studio,
        state: MultitrackEditState,
        playback: MultitrackPlaybackController,
        searchQuery: String = ""
    ) {
        self.app = app
        self.state = state
        self.playback = playback
        self.searchQuery = searchQuery
    }

    private var filteredShapes: [ShapeKind] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return ShapeKind.allCases }
        return ShapeKind.allCases.filter { kind in
            let keywords: String
            switch kind {
            case .rect: keywords = "rect rectangle 矩形 方塊 色塊"
            case .roundedRect: keywords = "rounded rect card 圓角 卡片 標註框"
            case .ellipse: keywords = "ellipse circle oval 圓形 橢圓 圈選"
            case .triangle: keywords = "triangle 三角形 幾何"
            case .star: keywords = "star 五角星 星星 勳章"
            case .arrow: keywords = "arrow pointer 箭頭 指示 方向"
            case .pill: keywords = "pill capsule badge 膠囊 標籤 徽章"
            case .line: keywords = "line divider 分隔線 線條 裝飾線"
            }
            return (kind.rawValue + " " + kind.displayName + " " + keywords).lowercased().contains(q)
        }
    }

    private func accentPair(for kind: ShapeKind) -> (Color, Color) {
        switch kind {
        case .rect: return (Color(red: 0.15, green: 0.39, blue: 0.92), Color(red: 0.49, green: 0.23, blue: 0.93))
        case .roundedRect: return (Color(red: 0.06, green: 0.65, blue: 0.91), Color(red: 0.39, green: 0.40, blue: 0.95))
        case .ellipse: return (Color(red: 0.93, green: 0.28, blue: 0.60), Color(red: 0.96, green: 0.62, blue: 0.04))
        case .triangle: return (Color(red: 0.06, green: 0.73, blue: 0.51), Color(red: 0.02, green: 0.71, blue: 0.83))
        case .star: return (Color(red: 0.98, green: 0.80, blue: 0.08), Color(red: 0.98, green: 0.45, blue: 0.09))
        case .arrow: return (Color(red: 0.94, green: 0.27, blue: 0.27), Color(red: 0.98, green: 0.45, blue: 0.09))
        case .pill: return (Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.93, green: 0.28, blue: 0.60))
        case .line: return (Color(red: 0.22, green: 0.74, blue: 0.97), Color(red: 0.51, green: 0.55, blue: 0.97))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "square.on.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(proCyan)
                Text("可編輯向量形狀（8 種）")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("加入於 \(TimelineLayout.formatTimecode(playback.playhead))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if filteredShapes.isEmpty {
                Text("沒有符合「\(searchQuery)」的形狀項目。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(filteredShapes) { kind in
                        let colors = accentPair(for: kind)
                        Button {
                            let defaultLabel = (kind == .pill) ? "精選標註" : ""
                            if let sel = app.addShapeClip(kind: kind, at: playback.playhead, label: defaultLabel) {
                                state.selection = sel
                                state.previewMode = .timeline
                                playback.syncLayout(app.currentMultitrackLayout())
                            }
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(proDarkWell)
                                    ProVectorShape(
                                        kind: kind,
                                        cornerRadiusRatio: kind == .roundedRect ? 0.30 : 0.0,
                                        lineThickness: 4
                                    )
                                    .fill(
                                        LinearGradient(
                                            colors: [colors.0, colors.1],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay {
                                        if kind != .line {
                                            ProVectorShape(
                                                kind: kind,
                                                cornerRadiusRatio: kind == .roundedRect ? 0.30 : 0.0,
                                                lineThickness: 4
                                            )
                                            .stroke(.white.opacity(0.75), lineWidth: 1.2)
                                        }
                                    }
                                    .frame(
                                        width: kind == .line ? 60 : (kind == .pill ? 56 : 40),
                                        height: kind == .line ? 14 : (kind == .pill ? 22 : 28)
                                    )
                                }
                                .frame(height: 44)

                                HStack(spacing: 3) {
                                    Text(kind.displayName)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(proCyan.opacity(0.85))
                                }
                            }
                            .padding(6)
                            .background(surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(app.busy)
                    }
                }
            }
        }
    }
}

// MARK: - 4.2 ShapeCanvasOverlayView (Interactive Canvas Shape Rendering)

@MainActor
private final class ShapeOverlayDragState: ObservableObject {
    @Published var originPosX: Double? = nil
    @Published var originPosY: Double? = nil
    @Published var originWidth: Double? = nil
    @Published var originHeight: Double? = nil
}

struct ShapeCanvasOverlayView: View {
    let seg: ShapeSegmentLayout
    let canvasSize: CGSize
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController

    @StateObject private var dragState = ShapeOverlayDragState()

    var body: some View {
        let clip = seg.clip
        let kind = ShapeKind.resolved(clip.kind)
        let isSelected = state.selection == .shapeClip(trackID: seg.trackID, clipID: seg.id)
        let layout = app.currentMultitrackLayout()
        let locked = layout.shapeTracks.first(where: { $0.id == seg.trackID })?.track.locked ?? false

        let scaleFactor = max(0.1, canvasSize.height / 1080.0)
        let shapeW = max(16.0, CGFloat(min(1.0, max(0.02, clip.width))) * canvasSize.width)
        let shapeH = max(10.0, CGFloat(min(1.0, max(0.015, clip.height))) * canvasSize.height)
        let centerX = CGFloat(min(0.98, max(0.02, clip.posX))) * canvasSize.width
        let centerY = CGFloat(min(0.98, max(0.02, clip.posY))) * canvasSize.height

        let fillColor = MultitrackColorHex.color(from: clip.fillColorHex, fallback: proCyan)
        let endColor = MultitrackColorHex.color(from: clip.fillGradientEndHex, fallback: proViolet)
        let strokeColor = MultitrackColorHex.color(from: clip.strokeColorHex, fallback: .white)
        let labelColor = MultitrackColorHex.color(from: clip.labelColorHex, fallback: .white)
        let scaledStroke = CGFloat(max(0, clip.strokeWidth)) * scaleFactor
        let scaledLineThick = max(scaledStroke, max(3.0, 10.0 * scaleFactor))
        let scaledLabelFont = max(8.0, CGFloat(clip.labelFontSize) * scaleFactor)
        let gradPts = proLinearGradientPoints(angleDegrees: clip.fillGradientAngle)

        let shapeGeo = ProVectorShape(
            kind: kind,
            cornerRadiusRatio: CGFloat(min(1.0, max(0.0, clip.cornerRadius))),
            lineThickness: scaledLineThick
        )

        ZStack {
            Group {
                if clip.fillGradientEnabled {
                    shapeGeo.fill(
                        LinearGradient(
                            colors: [fillColor, endColor],
                            startPoint: gradPts.start,
                            endPoint: gradPts.end
                        )
                    )
                } else {
                    shapeGeo.fill(fillColor)
                }
            }
            .shadow(
                color: clip.shadowEnabled ? .black.opacity(0.55) : .clear,
                radius: clip.shadowEnabled ? max(2, 10 * scaleFactor) : 0,
                x: 0,
                y: clip.shadowEnabled ? max(1, 4 * scaleFactor) : 0
            )

            if scaledStroke > 0.25 && kind != .line {
                shapeGeo.stroke(
                    strokeColor,
                    style: StrokeStyle(lineWidth: scaledStroke, lineCap: .round, lineJoin: .round)
                )
            }

            let trimmedLabel = clip.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLabel.isEmpty {
                Text(clip.label)
                    .font(.custom("PingFang TC", size: scaledLabelFont).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(labelColor)
                    .shadow(color: clip.shadowEnabled ? .black.opacity(0.65) : .clear, radius: 2, x: 0, y: 1)
                    .padding(.horizontal, max(4, shapeW * 0.07))
                    .frame(maxWidth: shapeW * 0.9, maxHeight: shapeH * 0.9)
            }
        }
        .frame(width: shapeW, height: shapeH)
        .opacity(min(1.0, max(0.0, clip.opacity)))
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(proCyan, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                    .overlay(alignment: .bottomTrailing) {
                        resizeHandle(clip: clip, locked: locked)
                            .offset(x: 6, y: 6)
                    }
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .fill(proCyan)
                            .frame(width: 7, height: 7)
                            .offset(x: -3.5, y: -3.5)
                    }
            }
        }
        .rotationEffect(.degrees(clip.rotation))
        .contentShape(Rectangle())
        .position(x: centerX, y: centerY)
        .onTapGesture {
            state.selection = .shapeClip(trackID: seg.trackID, clipID: seg.id)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard !app.busy && !locked else { return }
                    if dragState.originPosX == nil {
                        dragState.originPosX = clip.posX
                        dragState.originPosY = clip.posY
                        state.selection = .shapeClip(trackID: seg.trackID, clipID: seg.id)
                        playback.pause()
                    }
                    let bx = dragState.originPosX ?? clip.posX
                    let by = dragState.originPosY ?? clip.posY
                    let nx = min(0.98, max(0.02, bx + Double(value.translation.width / max(1, canvasSize.width))))
                    let ny = min(0.98, max(0.02, by + Double(value.translation.height / max(1, canvasSize.height))))
                    app.updateShapeClipProperties(id: seg.id) {
                        $0.posX = (nx * 1000).rounded() / 1000
                        $0.posY = (ny * 1000).rounded() / 1000
                    }
                }
                .onEnded { _ in
                    dragState.originPosX = nil
                    dragState.originPosY = nil
                    playback.syncLayout(app.currentMultitrackLayout())
                }
        )
    }

    private func resizeHandle(clip: ShapeClip, locked: Bool) -> some View {
        ZStack {
            Circle()
                .fill(canvas)
                .frame(width: 12, height: 12)
            Circle()
                .strokeBorder(proCyan, lineWidth: 2)
                .frame(width: 12, height: 12)
        }
        .contentShape(Rectangle().size(width: 22, height: 22))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard !app.busy && !locked else { return }
                    if dragState.originWidth == nil {
                        dragState.originWidth = clip.width
                        dragState.originHeight = clip.height
                        playback.pause()
                    }
                    let bw = dragState.originWidth ?? clip.width
                    let bh = dragState.originHeight ?? clip.height
                    let dw = Double(value.translation.width / max(1, canvasSize.width)) * 2.0
                    let dh = Double(value.translation.height / max(1, canvasSize.height)) * 2.0
                    let nw = min(1.0, max(0.04, bw + dw))
                    let nh = min(1.0, max(0.02, bh + dh))
                    app.updateShapeClipProperties(id: seg.id) {
                        $0.width = (nw * 1000).rounded() / 1000
                        $0.height = (nh * 1000).rounded() / 1000
                    }
                }
                .onEnded { _ in
                    dragState.originWidth = nil
                    dragState.originHeight = nil
                    playback.syncLayout(app.currentMultitrackLayout())
                }
        )
    }
}

// MARK: - 4.3 ShapeInspectorView (Full Shape Property Editor)

struct ShapeInspectorView: View {
    let seg: ShapeSegmentLayout
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController

    private var clip: ShapeClip { seg.clip }

    private func mutateShape(_ update: @escaping (inout ShapeClip) -> Void) {
        app.updateShapeClipProperties(id: seg.id, update)
        playback.syncLayout(app.currentMultitrackLayout())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: ShapeKind.resolved(clip.kind).symbolName)
                        .foregroundStyle(proCyan)
                    Text("形狀圖層屬性")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button(role: .destructive) {
                        state.deleteSelected(app: app, playback: playback)
                    } label: {
                        Label("刪除", systemImage: "trash")
                            .font(.system(size: 10.5))
                    }
                    .controlSize(.small)
                    .disabled(app.busy)
                }

                // Shape Kind Picker
                VStack(alignment: .leading, spacing: 5) {
                    Text("形狀類型")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], spacing: 4) {
                        ForEach(ShapeKind.allCases) { kind in
                            let active = ShapeKind.resolved(clip.kind) == kind
                            Button {
                                mutateShape { $0.kind = kind.rawValue }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: kind.symbolName)
                                        .font(.system(size: 9.5))
                                    Text(kind.displayName)
                                        .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(active ? canvas : .white.opacity(0.88))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 5)
                                .background(active ? proCyan : surface, in: RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().overlay(.white.opacity(0.08))

                // Optional Centered Label
                VStack(alignment: .leading, spacing: 6) {
                    Text("內嵌文字標籤（選填）")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("輸入置中繁中文字標籤...", text: Binding(
                        get: { clip.label },
                        set: { val in mutateShape { $0.label = val } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                    proSliderRow(
                        title: "標籤字級",
                        value: Binding(
                            get: { clip.labelFontSize },
                            set: { val in mutateShape { $0.labelFontSize = val.rounded() } }
                        ),
                        range: 12...140,
                        valueText: "\(Int(clip.labelFontSize)) pt"
                    )

                    colorSwatchRow(
                        title: "標籤顏色",
                        selectedHex: clip.labelColorHex,
                        onSelect: { hex in mutateShape { $0.labelColorHex = hex } }
                    )
                }

                Divider().overlay(.white.opacity(0.08))

                // Fill & Gradient
                VStack(alignment: .leading, spacing: 6) {
                    Text("填色與漸層")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    colorSwatchRow(
                        title: "主填色",
                        selectedHex: clip.fillColorHex,
                        onSelect: { hex in mutateShape { $0.fillColorHex = hex } }
                    )

                    Toggle("啟用線性漸層", isOn: Binding(
                        get: { clip.fillGradientEnabled },
                        set: { val in mutateShape { $0.fillGradientEnabled = val } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))

                    if clip.fillGradientEnabled {
                        colorSwatchRow(
                            title: "漸層終點色",
                            selectedHex: clip.fillGradientEndHex,
                            onSelect: { hex in mutateShape { $0.fillGradientEndHex = hex } }
                        )
                        proSliderRow(
                            title: "漸層角度",
                            value: Binding(
                                get: { clip.fillGradientAngle },
                                set: { val in mutateShape { $0.fillGradientAngle = val.rounded() } }
                            ),
                            range: 0...360,
                            valueText: "\(Int(clip.fillGradientAngle))°"
                        )
                    }
                }

                Divider().overlay(.white.opacity(0.08))

                // Stroke, Corner Radius & Shadow
                VStack(alignment: .leading, spacing: 6) {
                    Text("描邊、圓角與陰影")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    colorSwatchRow(
                        title: "描邊顏色",
                        selectedHex: clip.strokeColorHex,
                        onSelect: { hex in mutateShape { $0.strokeColorHex = hex } }
                    )

                    proSliderRow(
                        title: "描邊寬度",
                        value: Binding(
                            get: { clip.strokeWidth },
                            set: { val in mutateShape { $0.strokeWidth = (val * 2).rounded() / 2 } }
                        ),
                        range: 0...24,
                        valueText: String(format: "%.1f px", clip.strokeWidth)
                    )

                    if ShapeKind.resolved(clip.kind) == .roundedRect {
                        proSliderRow(
                            title: "圓角比例",
                            value: Binding(
                                get: { clip.cornerRadius },
                                set: { val in mutateShape { $0.cornerRadius = (val * 100).rounded() / 100 } }
                            ),
                            range: 0...1.0,
                            valueText: "\(Int((clip.cornerRadius * 100).rounded()))%"
                        )
                    }

                    Toggle("投射陰影", isOn: Binding(
                        get: { clip.shadowEnabled },
                        set: { val in mutateShape { $0.shadowEnabled = val } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
                }

                Divider().overlay(.white.opacity(0.08))

                // Transform & Opacity
                VStack(alignment: .leading, spacing: 6) {
                    Text("幾何變換與透明度")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    proSliderRow(
                        title: "不透明度",
                        value: Binding(
                            get: { clip.opacity },
                            set: { val in mutateShape { $0.opacity = (val * 100).rounded() / 100 } }
                        ),
                        range: 0...1.0,
                        valueText: "\(Int((clip.opacity * 100).rounded()))%"
                    )

                    proSliderRow(
                        title: "旋轉角度",
                        value: Binding(
                            get: { clip.rotation },
                            set: { val in mutateShape { $0.rotation = val.rounded() } }
                        ),
                        range: -180...180,
                        valueText: "\(Int(clip.rotation))°"
                    )

                    proSliderRow(
                        title: "寬度比例",
                        value: Binding(
                            get: { clip.width },
                            set: { val in mutateShape { $0.width = (val * 1000).rounded() / 1000 } }
                        ),
                        range: 0.04...1.0,
                        valueText: "\(Int((clip.width * 100).rounded()))%"
                    )

                    proSliderRow(
                        title: "高度比例",
                        value: Binding(
                            get: { clip.height },
                            set: { val in mutateShape { $0.height = (val * 1000).rounded() / 1000 } }
                        ),
                        range: 0.02...1.0,
                        valueText: "\(Int((clip.height * 100).rounded()))%"
                    )

                    proSliderRow(
                        title: "水平位置 X",
                        value: Binding(
                            get: { clip.posX },
                            set: { val in mutateShape { $0.posX = (val * 1000).rounded() / 1000 } }
                        ),
                        range: 0.02...0.98,
                        valueText: "\(Int((clip.posX * 100).rounded()))%"
                    )

                    proSliderRow(
                        title: "垂直位置 Y",
                        value: Binding(
                            get: { clip.posY },
                            set: { val in mutateShape { $0.posY = (val * 1000).rounded() / 1000 } }
                        ),
                        range: 0.02...0.98,
                        valueText: "\(Int((clip.posY * 100).rounded()))%"
                    )
                }

                Divider().overlay(.white.opacity(0.08))

                // Timing (Start & Duration)
                VStack(alignment: .leading, spacing: 6) {
                    Text("時間軸區間")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text("起始時間")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2fs", clip.timelineStart))
                            .font(.system(size: 10.5, design: .monospaced))
                        Stepper("", value: Binding(
                            get: { clip.timelineStart },
                            set: { val in mutateShape { $0.timelineStart = MultitrackLayout.roundTime(max(0, val)) } }
                        ), in: 0...3600, step: 0.25)
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Text("持續秒數")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2fs", clip.duration))
                            .font(.system(size: 10.5, design: .monospaced))
                        Stepper("", value: Binding(
                            get: { clip.duration },
                            set: { val in mutateShape { $0.duration = MultitrackLayout.roundTime(max(0.2, val)) } }
                        ), in: 0.2...600, step: 0.5)
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    HStack(spacing: 4) {
                        ForEach([1.0, 3.0, 5.0, 10.0], id: \.self) { sec in
                            let isCur = abs(clip.duration - sec) < 0.05
                            Button(String(format: "%.0fs", sec)) {
                                mutateShape { $0.duration = sec }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5, weight: isCur ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(isCur ? canvas : .white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(isCur ? proCyan : surface, in: RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer()
                    }
                }
            }
            .padding(10)
        }
        .background(panel)
    }

    private func colorSwatchRow(title: String, selectedHex: String, onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selectedHex.uppercased())
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(proColorPresetHexes, id: \.self) { hex in
                    let isSel = selectedHex.uppercased() == hex.uppercased()
                    Button {
                        onSelect(hex)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MultitrackColorHex.color(from: hex))
                            .frame(height: 18)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(isSel ? proCyan : .white.opacity(0.2), lineWidth: isSel ? 2 : 0.75)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 4.4 ProVisualEffectsLibraryTab (8 Filters + 24 Visual FX + Blend + Masks + DSP + Chroma + Proxy)

@MainActor
private final class ProVisualEffectsLocalState: ObservableObject {
    @Published var selectedCategory: String = "全部"
    @Published var proxyBusyClipID: UUID? = nil
    @Published var proxyMessage: String? = nil
    @Published var proxyError: String? = nil
}

struct ProVisualEffectsLibraryTab: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    var searchQuery: String

    @ObservedObject private var catalog = EffectsCatalogStore.shared
    @ObservedObject private var audioAI = AudioAIManager.shared
    @StateObject private var local = ProVisualEffectsLocalState()

    init(
        app: Studio,
        state: MultitrackEditState,
        playback: MultitrackPlaybackController,
        searchQuery: String = ""
    ) {
        self.app = app
        self.state = state
        self.playback = playback
        self.searchQuery = searchQuery
    }

    private var selectedVideoSeg: VideoSegmentLayout? {
        state.selectedVideoSegment(in: app.currentMultitrackLayout())
    }

    private func mutateSelectedVideo(_ update: @escaping (inout VideoClip) -> Void, status: String? = nil) {
        guard let seg = selectedVideoSeg else { return }
        app.updateVideoClipProperties(id: seg.id, update)
        if let status {
            app.status = status
        }
        playback.syncLayout(app.currentMultitrackLayout())
    }

    var body: some View {
        let seg = selectedVideoSeg
        let filteredFX = catalog.searchVisualEffects(query: searchQuery, category: local.selectedCategory)
        let qLower = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        GeometryReader { geo in
            let availW = max(160, geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Target Video Clip Banner
                    targetBanner(seg: seg)

                    // 1. 8 Color Filter Presets
                    let matchingFilters = VideoFilterPreset.allCases.filter { preset in
                        qLower.isEmpty || preset.displayName.lowercased().contains(qLower) || preset.rawValue.lowercased().contains(qLower)
                    }
                    if !matchingFilters.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            proSectionHeader(icon: "camera.filters", title: "基礎調色濾鏡（8 種）", accent: proCyan)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                                ForEach(matchingFilters) { preset in
                                    let active = seg.map { VideoFilterPreset.resolved($0.clip.filterPreset) == preset } ?? false
                                    Button {
                                        mutateSelectedVideo({ $0.filterPreset = preset.rawValue }, status: "已套用濾鏡 · \(preset.displayName)")
                                    } label: {
                                        HStack(spacing: 6) {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(LinearGradient(colors: preset.swatchColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                                .frame(width: 24, height: 18)
                                            Text(preset.displayName)
                                                .font(.system(size: 10, weight: active ? .semibold : .regular))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 5)
                                        .background(active ? proCyan.opacity(0.20) : surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? proCyan : .white.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(seg == nil || app.busy)
                                }
                            }
                        }
                    }

                    Divider().overlay(.white.opacity(0.08))

                    // 2. 24 Distinct FFmpeg Visual Effects
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            proSectionHeader(icon: "sparkles.tv", title: "專業視覺特效（24 種 FFmpeg）", accent: proViolet)
                            Spacer()
                            if let seg, seg.clip.effectId != "none" && !seg.clip.effectId.isEmpty {
                                Button("清除特效") {
                                    mutateSelectedVideo({ $0.effectId = "none" }, status: "已清除視覺特效")
                                }
                                .controlSize(.mini)
                                .disabled(app.busy)
                            }
                        }

                        // Category filter pills
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(catalog.visualCategories, id: \.self) { cat in
                                    let active = local.selectedCategory == cat
                                    Button(cat) {
                                        local.selectedCategory = cat
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                                    .foregroundStyle(active ? canvas : .white.opacity(0.85))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(active ? proViolet : surface, in: Capsule())
                                }
                            }
                        }

                        if filteredFX.isEmpty {
                            Text("找不到符合條件的視覺特效。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                                ForEach(filteredFX) { fx in
                                    let active = seg?.clip.effectId == fx.id
                                    Button {
                                        mutateSelectedVideo({ $0.effectId = fx.id }, status: "已套用視覺特效 · \(fx.name)")
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(
                                                    LinearGradient(
                                                        colors: EffectsCatalogStore.swatchColors(forVisualEffectID: fx.id),
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                                .frame(height: 28)
                                                .overlay(alignment: .topTrailing) {
                                                    Text(fx.category)
                                                        .font(.system(size: 8, weight: .medium))
                                                        .foregroundStyle(.white.opacity(0.92))
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 1.5)
                                                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                                                        .padding(3)
                                                }
                                            Text(fx.name)
                                                .font(.system(size: 10, weight: active ? .semibold : .medium))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(fx.description)
                                                .font(.system(size: 8.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(active ? proViolet.opacity(0.22) : surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? proViolet : .white.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(seg == nil || app.busy)
                                }
                            }
                        }
                    }

                    Divider().overlay(.white.opacity(0.08))

                    // 3. Blend Modes (8 modes)
                    VStack(alignment: .leading, spacing: 6) {
                        proSectionHeader(icon: "square.2.layers.3d.top.filled", title: "圖層混合模式（8 種）", accent: proCyan)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                            ForEach(VideoBlendMode.allCases) { mode in
                                let active = seg.map { VideoBlendMode.resolved($0.clip.blendMode) == mode } ?? false
                                Button(mode.displayName) {
                                    mutateSelectedVideo({ $0.blendMode = mode.rawValue }, status: "已設定混合模式 · \(mode.displayName)")
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? canvas : .white.opacity(0.88))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(active ? proCyan : surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                                .disabled(seg == nil || app.busy)
                            }
                        }
                    }

                    Divider().overlay(.white.opacity(0.08))

                    // 4. Masks (Rect / Ellipse / Linear Fade + Feather + Invert)
                    VStack(alignment: .leading, spacing: 6) {
                        proSectionHeader(icon: "circle.dashed.inset.filled", title: "畫面遮罩（Mask）", accent: proAmber)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                            ForEach(VideoMaskKind.allCases) { kind in
                                let active = seg.map { VideoMaskKind.resolved($0.clip.maskKind) == kind } ?? false
                                Button {
                                    mutateSelectedVideo({ $0.maskKind = kind.rawValue }, status: "已設定遮罩 · \(kind.displayName)")
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: kind.symbolName)
                                            .font(.system(size: 10))
                                        Text(kind.displayName)
                                            .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .foregroundStyle(active ? canvas : .white.opacity(0.88))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(active ? proAmber : surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                                .disabled(seg == nil || app.busy)
                            }
                        }

                        if let seg, VideoMaskKind.resolved(seg.clip.maskKind) != .none {
                            proSliderRow(
                                title: "遮罩羽化",
                                value: Binding(
                                    get: { seg.clip.maskFeather },
                                    set: { val in mutateSelectedVideo({ $0.maskFeather = (val * 100).rounded() / 100 }) }
                                ),
                                range: 0...0.45,
                                valueText: "\(Int((seg.clip.maskFeather * 100).rounded()))%"
                            )
                            Toggle("反轉遮罩區域", isOn: Binding(
                                get: { seg.clip.maskInvert },
                                set: { val in mutateSelectedVideo({ $0.maskInvert = val }, status: val ? "已反轉遮罩" : "已關閉反轉遮罩") }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 10.5))
                        }
                    }

                    Divider().overlay(.white.opacity(0.08))

                    // 5. Video Stabilization & Clarity Enhancement (Explicitly Signal-Processing, NOT AI)
                    VStack(alignment: .leading, spacing: 6) {
                        proSectionHeader(icon: "gyroscope", title: "防手震與畫質清晰強化（訊號處理，非 AI）", accent: proEmerald)
                        Text("採用 FFmpeg 經典數位訊號演算法（deshake / hqdn3d + unsharp），輸出穩定且無神經網路幻覺。")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("畫面防手震穩定（FFmpeg deshake）", isOn: Binding(
                                get: { seg?.clip.stabilizeEnabled ?? false },
                                set: { val in mutateSelectedVideo({ $0.stabilizeEnabled = val }, status: val ? "已啟用 FFmpeg deshake 防手震" : "已關閉防手震") }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 10.5))
                            .disabled(seg == nil || app.busy)

                            if let seg, seg.clip.stabilizeEnabled {
                                proSliderRow(
                                    title: "穩定強度",
                                    value: Binding(
                                        get: { seg.clip.stabilizeStrength },
                                        set: { val in mutateSelectedVideo({ $0.stabilizeStrength = (val * 100).rounded() / 100 }) }
                                    ),
                                    range: 0.1...1.0,
                                    valueText: "\(Int((seg.clip.stabilizeStrength * 100).rounded()))%"
                                )
                            }

                            proSliderRow(
                                title: "清晰降噪強化（hqdn3d+unsharp）",
                                value: Binding(
                                    get: { seg?.clip.enhanceClarity ?? 0 },
                                    set: { val in mutateSelectedVideo({ $0.enhanceClarity = (val * 100).rounded() / 100 }) }
                                ),
                                range: 0...1.0,
                                valueText: "\(Int(((seg?.clip.enhanceClarity ?? 0) * 100).rounded()))%"
                            )
                            .disabled(seg == nil || app.busy)
                        }
                        .padding(8)
                        .background(surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Divider().overlay(.white.opacity(0.08))

                    // 6. Green Screen Chroma Key One-Click Card
                    VStack(alignment: .leading, spacing: 6) {
                        proSectionHeader(icon: "person.and.background.dotted", title: "綠幕去背（Chroma Key）", accent: proEmerald)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("一鍵啟用綠幕去背")
                                        .font(.system(size: 10.5, weight: .semibold))
                                    Text("濾除背景綠幕（#00FF00），與下方軌道無縫合成。")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(seg?.clip.chromaKeyEnabled == true ? "已啟用" : "一鍵去背") {
                                    let next = !(seg?.clip.chromaKeyEnabled ?? false)
                                    mutateSelectedVideo({ $0.chromaKeyEnabled = next }, status: next ? "已開啟綠幕去背" : "已關閉綠幕去背")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(seg?.clip.chromaKeyEnabled == true ? proEmerald : surface)
                                .controlSize(.small)
                                .disabled(seg == nil || app.busy)
                            }

                            if let seg, seg.clip.chromaKeyEnabled {
                                proSliderRow(
                                    title: "色彩容差",
                                    value: Binding(
                                        get: { seg.clip.chromaKeySimilarity },
                                        set: { val in mutateSelectedVideo({ $0.chromaKeySimilarity = (val * 100).rounded() / 100 }) }
                                    ),
                                    range: 0.02...0.50,
                                    valueText: String(format: "%.2f", seg.clip.chromaKeySimilarity)
                                )
                                proSliderRow(
                                    title: "邊緣羽化",
                                    value: Binding(
                                        get: { seg.clip.chromaKeyBlend },
                                        set: { val in mutateSelectedVideo({ $0.chromaKeyBlend = (val * 100).rounded() / 100 }) }
                                    ),
                                    range: 0.0...0.35,
                                    valueText: String(format: "%.2f", seg.clip.chromaKeyBlend)
                                )
                            }
                        }
                        .padding(8)
                        .background(surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Divider().overlay(.white.opacity(0.08))

                    // 7. 540p Edit Proxy Generator
                    VStack(alignment: .leading, spacing: 6) {
                        proSectionHeader(icon: "bolt.horizontal.circle", title: "540p 剪輯代理（Edit Proxy）", accent: proCyan)
                        VStack(alignment: .leading, spacing: 6) {
                            if let seg {
                                if let proxyPath = seg.clip.proxyPath, !proxyPath.isEmpty {
                                    HStack(spacing: 5) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(proEmerald)
                                            .font(.system(size: 11))
                                        Text("已連結代理：\(filename(proxyPath))")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                } else {
                                    Text("針對高解析度 4K 影片生成輕量 540p H.264 剪輯代理，輸出時仍自動使用原始高畫質母帶。")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 6) {
                                    Button {
                                        generateProxy(for: seg)
                                    } label: {
                                        if local.proxyBusyClipID == seg.id {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Label("生成 540p 代理", systemImage: "film.stack")
                                                .font(.system(size: 10))
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(proCyan)
                                    .controlSize(.small)
                                    .disabled(seg.clip.still || local.proxyBusyClipID != nil || app.busy)

                                    if seg.clip.proxyPath != nil {
                                        Button("清除代理") {
                                            mutateSelectedVideo({ $0.proxyPath = nil }, status: "已清除 540p 剪輯代理")
                                            local.proxyMessage = nil
                                        }
                                        .controlSize(.small)
                                        .disabled(local.proxyBusyClipID != nil || app.busy)
                                    }
                                }
                            } else {
                                Text("請先選擇一段影片片段以建立 540p 代理。")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }

                            if let msg = local.proxyMessage {
                                Text(msg)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(proEmerald)
                            }
                            if let err = local.proxyError {
                                Text(err)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(proRose)
                            }
                        }
                        .padding(8)
                        .background(surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(8)
                .frame(width: availW, alignment: .leading)
                .clipped()
            }
            .frame(width: availW, alignment: .topLeading)
        }
        .background(panel)
    }

    private func targetBanner(seg: VideoSegmentLayout?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: seg != nil ? "film.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(seg != nil ? proCyan : proAmber)
            if let seg {
                Text("套用目標：\(filename(seg.clip.path))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Text("請先於時間軸點選影片或圖片片段")
                    .font(.system(size: 10))
                    .foregroundStyle(proAmber)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(proDarkWell, in: RoundedRectangle(cornerRadius: 5))
    }

    private func generateProxy(for seg: VideoSegmentLayout) {
        local.proxyBusyClipID = seg.id
        local.proxyError = nil
        local.proxyMessage = "正在轉碼 540p 代理影片..."
        Task { @MainActor in
            defer { local.proxyBusyClipID = nil }
            do {
                let proxyPath = try await audioAI.generateProxyForClip(sourcePath: seg.clip.path)
                app.updateVideoClipProperties(id: seg.id) { $0.proxyPath = proxyPath }
                app.status = "已生成 540p 剪輯代理 · \(filename(proxyPath))"
                local.proxyMessage = "代理完成：\(filename(proxyPath))"
                playback.syncLayout(app.currentMultitrackLayout())
            } catch {
                local.proxyError = error.localizedDescription
                local.proxyMessage = nil
            }
        }
    }
}

// MARK: - 4.5 AudioAndVoiceoverLibraryTab (Real Mic Recorder + 25 Audio FX + Audition)

@MainActor
private final class AudioLibraryLocalState: ObservableObject {
    static let shared = AudioLibraryLocalState()
    @Published var selectedCategory: String = "全部"
}

struct AudioAndVoiceoverLibraryTab: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    var searchQuery: String

    @ObservedObject private var recorder = VoiceoverRecorderManager.shared
    @ObservedObject private var catalog = EffectsCatalogStore.shared
    @ObservedObject private var audioAI = AudioAIManager.shared
    @ObservedObject private var local = AudioLibraryLocalState.shared

    init(
        app: Studio,
        state: MultitrackEditState,
        playback: MultitrackPlaybackController,
        searchQuery: String = ""
    ) {
        self.app = app
        self.state = state
        self.playback = playback
        self.searchQuery = searchQuery
    }

    private enum AudioFXTarget {
        case audio(AudioSegmentLayout)
        case video(VideoSegmentLayout)

        var path: String {
            switch self {
            case .audio(let s): return s.clip.path
            case .video(let s): return s.clip.path
            }
        }
        var activeEffect: String {
            switch self {
            case .audio(let s): return s.clip.audioEffect
            case .video(let s): return s.clip.audioEffect
            }
        }
        var voiceCleanup: Bool {
            switch self {
            case .audio(let s): return s.clip.voiceCleanup
            case .video(let s): return s.clip.voiceCleanup
            }
        }
        var label: String {
            switch self {
            case .audio(let s): return "音訊軌 · \(filename(s.clip.path))"
            case .video(let s): return "影片原聲 · \(filename(s.clip.path))"
            }
        }
    }

    private var currentTarget: AudioFXTarget? {
        let layout = app.currentMultitrackLayout()
        guard let sel = state.selection else { return nil }
        switch sel {
        case .audioClip(let tid, let cid):
            if let seg = layout.audioSegment(trackID: tid, clipID: cid) {
                return .audio(seg)
            }
        case .videoClip(let tid, let cid):
            if let seg = layout.videoSegment(trackID: tid, clipID: cid), !seg.clip.still {
                return .video(seg)
            }
        default:
            break
        }
        return nil
    }

    private func applyAudioEffect(_ effectID: String, to target: AudioFXTarget) {
        switch target {
        case .audio(let seg):
            app.updateAudioClipProperties(id: seg.id) { $0.audioEffect = effectID }
        case .video(let seg):
            app.updateVideoClipProperties(id: seg.id) { $0.audioEffect = effectID }
        }
        let fxName = effectID == "none" ? "原聲" : (catalog.audioEffect(id: effectID)?.name ?? effectID)
        app.status = "已套用音訊特效 · \(fxName)"
        playback.syncLayout(app.currentMultitrackLayout())
    }

    private func setVoiceCleanup(_ enabled: Bool, on target: AudioFXTarget) {
        switch target {
        case .audio(let seg):
            app.updateAudioClipProperties(id: seg.id) { $0.voiceCleanup = enabled }
        case .video(let seg):
            app.updateVideoClipProperties(id: seg.id) { $0.voiceCleanup = enabled }
        }
        app.status = enabled ? "已開啟人聲降噪與響度正規化（afftdn+loudnorm）" : "已關閉人聲降噪"
        playback.syncLayout(app.currentMultitrackLayout())
    }

    var body: some View {
        let target = currentTarget
        let filteredFX = catalog.searchAudioEffects(query: searchQuery, category: local.selectedCategory)

        GeometryReader { geo in
            let availW = max(160, geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // SECTION 0: Integrated Voicebox Speech Studio (Local Qwen3-TTS 1.7B/0.6B/CustomVoice + Colab MiniMax H3)
                    VoiceboxStudioSectionView(
                        app: app,
                        state: state,
                        playback: playback,
                        searchQuery: searchQuery,
                        onOpenComponentSettings: {
                            PortabilitySetupManager.shared.openSetupSheet(firstRun: false, app: app)
                        }
                    )

                    Divider().overlay(.white.opacity(0.08))

                    // SECTION A: Real Microphone Voiceover Recorder
                    voiceoverRecorderSection

                    Divider().overlay(.white.opacity(0.08))

                    // SECTION B: 25 Audio FX + Voice Cleanup
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            proSectionHeader(icon: "waveform.badge.magnifyingglass", title: "25 種音訊特效", accent: proEmerald)
                            Spacer(minLength: 2)
                            if audioAI.isPlayingAudition {
                                Button {
                                    audioAI.stopAudition()
                                } label: {
                                    Label("停止", systemImage: "stop.fill")
                                        .font(.system(size: 9.5))
                                }
                                .controlSize(.mini)
                            }
                        }

                        // Target audio/video banner
                        HStack(spacing: 6) {
                            Image(systemName: target != nil ? "speaker.wave.2.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(target != nil ? proEmerald : proAmber)
                            Text(target?.label ?? "請先點選音訊片段或含音軌影片")
                                .font(.system(size: 10))
                                .foregroundStyle(target != nil ? .white : proAmber)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(proDarkWell, in: RoundedRectangle(cornerRadius: 5))

                        // Voice Cleanup (afftdn + loudnorm) one-click toggle
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("一鍵人聲降噪與響度標準化")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .lineLimit(1)
                                Text("FFmpeg afftdn + loudnorm (-16 LUFS)")
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 2)
                            Toggle("", isOn: Binding(
                                get: { target?.voiceCleanup ?? false },
                                set: { val in
                                    if let target { setVoiceCleanup(val, on: target) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(target == nil || app.busy)
                        }
                        .padding(8)
                        .background(surface.opacity(0.58), in: RoundedRectangle(cornerRadius: 6))

                        // Category filter + Reset to Dry
                        HStack(spacing: 4) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(catalog.audioCategories, id: \.self) { cat in
                                        let active = local.selectedCategory == cat
                                        Button(cat) {
                                            local.selectedCategory = cat
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                                        .foregroundStyle(active ? canvas : .white.opacity(0.85))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(active ? proEmerald : surface, in: Capsule())
                                    }
                                }
                            }

                            if let target, target.activeEffect != "none" && !target.activeEffect.isEmpty {
                                Button("原聲") {
                                    applyAudioEffect("none", to: target)
                                }
                                .controlSize(.mini)
                                .disabled(app.busy)
                            }
                        }

                        // Audio FX Cards (Compact & Narrow-Safe at 232pt)
                        if filteredFX.isEmpty {
                            Text("沒有符合條件的音訊特效。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            LazyVStack(spacing: 5) {
                                ForEach(filteredFX) { fx in
                                    let isApplied = target?.activeEffect == fx.id
                                    let isAuditioning = audioAI.auditioningEffectID == fx.id
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 5) {
                                            Image(systemName: EffectsCatalogStore.symbolName(forAudioEffectID: fx.id))
                                                .font(.system(size: 11))
                                                .foregroundStyle(isApplied ? proEmerald : proCyan)
                                                .frame(width: 15)
                                            Text(fx.name)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Spacer(minLength: 2)
                                            Text(fx.category)
                                                .font(.system(size: 8.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(proDarkWell, in: Capsule())
                                        }

                                        Text(fx.description)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)

                                        HStack(spacing: 5) {
                                            // Audition button (real FFmpeg DSP preview)
                                            Button {
                                                if let target {
                                                    audioAI.previewAudioEffect(sourcePath: target.path, effectID: fx.id)
                                                } else if let rec = recorder.lastRecordingPath {
                                                    audioAI.previewAudioEffect(sourcePath: rec, effectID: fx.id)
                                                }
                                            } label: {
                                                HStack(spacing: 3) {
                                                    Image(systemName: isAuditioning ? "stop.circle.fill" : "play.circle")
                                                        .font(.system(size: 11))
                                                    Text(isAuditioning ? "停止" : "試聽")
                                                        .font(.system(size: 10))
                                                        .lineLimit(1)
                                                }
                                                .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .disabled(target == nil && recorder.lastRecordingPath == nil)

                                            // Apply button
                                            Button {
                                                if let target {
                                                    applyAudioEffect(fx.id, to: target)
                                                }
                                            } label: {
                                                Text(isApplied ? "已套用" : "套用特效")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .lineLimit(1)
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(isApplied ? proEmerald : proCyan)
                                            .controlSize(.mini)
                                            .disabled(target == nil || app.busy)
                                        }
                                    }
                                    .padding(7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(isApplied ? proEmerald.opacity(0.16) : surface.opacity(0.58), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isApplied ? proEmerald : .white.opacity(0.07)))
                                }
                            }
                        }

                        if let err = audioAI.lastError {
                            Text(err)
                                .font(.system(size: 9.5))
                                .foregroundStyle(proRose)
                        }
                    }
                }
                .padding(8)
                .frame(width: availW, alignment: .leading)
                .clipped()
            }
            .frame(width: availW, alignment: .topLeading)
        }
        .background(panel)
        .onAppear {
            recorder.refreshDevicesAndPermission()
        }
    }

    private var voiceoverRecorderSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                proSectionHeader(icon: "mic.circle.fill", title: "麥克風旁白錄音（48kHz WAV）", accent: proRose)
                Spacer()
                Button {
                    recorder.refreshDevicesAndPermission()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                // Honest TCC Permission Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.isAuthorized ? proEmerald : (recorder.authorizationStatus == .notDetermined ? proAmber : proRose))
                        .frame(width: 7, height: 7)
                    Text("麥克風權限：\(recorder.authorizationLabel)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    if recorder.authorizationStatus == .notDetermined {
                        Button("要求授權") {
                            Task { _ = await recorder.requestMicrophoneAccess() }
                        }
                        .controlSize(.mini)
                    } else if recorder.authorizationStatus == .denied || recorder.authorizationStatus == .restricted {
                        Button("開啟系統設定") {
                            recorder.openMicrophonePrivacySettings()
                        }
                        .controlSize(.mini)
                    }
                }

                // Device Selector (Custom Menu so long hardware names never inflate VStack intrinsic width in narrow 232pt sidebar)
                HStack(spacing: 6) {
                    Text("輸入裝置")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    if recorder.availableDevices.isEmpty {
                        Text("未偵測到麥克風")
                            .font(.system(size: 11))
                            .foregroundStyle(proAmber)
                        Spacer()
                    } else {
                        let activeDevName = recorder.availableDevices.first(where: { $0.uniqueID == recorder.selectedDeviceUniqueID })?.localizedName
                            ?? recorder.availableDevices.first?.localizedName
                            ?? "預設麥克風"
                        Menu {
                            ForEach(recorder.availableDevices, id: \.uniqueID) { dev in
                                Button {
                                    recorder.selectedDeviceUniqueID = dev.uniqueID
                                } label: {
                                    Text(dev.localizedName)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(activeDevName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(proDarkWell, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.10)))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(recorder.isRecording)
                        .accessibilityLabel("選擇麥克風輸入裝置")
                    }
                }

                // Live dB Meter Bar
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(recorder.isRecording ? "錄音中" : "待機電平")
                            .font(.system(size: 9))
                            .foregroundStyle(recorder.isRecording ? proRose : .secondary)
                        Spacer()
                        Text(String(format: "%.1f dB · %02d:%04.1f",
                                    recorder.meterDecibels,
                                    Int(recorder.elapsedSeconds) / 60,
                                    recorder.elapsedSeconds.truncatingRemainder(dividingBy: 60)))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(proDarkWell)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [proEmerald, proAmber, proRose],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * CGFloat(min(1.0, max(0.0, recorder.meterLevel)))))
                                .animation(.linear(duration: 0.05), value: recorder.meterLevel)
                        }
                    }
                    .frame(height: 8)
                }

                // Record / Stop & Insert Button
                HStack(spacing: 6) {
                    Button {
                        if recorder.isRecording {
                            if let wavPath = recorder.stopAndReturnPath() {
                                if let sel = app.addGeneratedAudioToTrack(
                                    path: wavPath,
                                    at: playback.playhead,
                                    preferredTrackName: "A 旁白錄音"
                                ) {
                                    state.selection = sel
                                    state.previewMode = .timeline
                                    app.status = "已插入旁白錄音 · \(filename(wavPath))"
                                    playback.syncLayout(app.currentMultitrackLayout())
                                }
                            }
                        } else {
                            playback.pause()
                            recorder.startRecording(outputRootDir: app.audioOutputDirectory)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                            Text(recorder.isRecording ? "停止並插入音訊軌" : "開始錄製旁白")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.isRecording ? proRose : proCyan)
                    .controlSize(.small)
                    .disabled(app.busy || (!recorder.isRecording && (recorder.authorizationStatus == .denied || recorder.authorizationStatus == .restricted)))

                    if let lastPath = recorder.lastRecordingPath, !recorder.isRecording {
                        Button {
                            audioAI.playLocalAudioFile(path: lastPath, tag: "voiceover_last")
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .controlSize(.small)
                        .help("試聽最近一次錄音")
                    }
                }

                if let msg = recorder.statusMessage {
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundStyle(proEmerald)
                }
                if let err = recorder.lastError {
                    Text(err)
                        .font(.system(size: 9))
                        .foregroundStyle(proRose)
                }
            }
            .padding(8)
            .background(surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recorder.isRecording ? proRose.opacity(0.7) : .white.opacity(0.08)))
        }
    }
}

// MARK: - 4.6 AIToolsStudioTab (4 Local ONNX/CTranslate2 Audio AI Tools)

@MainActor
private final class AIToolsLocalState: ObservableObject {
    static let shared = AIToolsLocalState()
    @Published var asrLanguage: String = "zh"
    @Published var asrModelChoice: String = "auto"
    @Published var asrPrompt: String = ""
    @Published var asrDraftSegments: [ASRSubtitleSegment] = []
    @Published var asrDraftBaseOffset: Double = 0
    @Published var asrDraftSourceName: String = ""
    @Published var asrModelUsed: String = ""
    @Published var lastSRTPath: String? = nil

    @Published var ttsText: String = "歡迎使用 Klipora 本地神經網路中文配音。"
    @Published var ttsSpeakerID: Int = 45
    @Published var ttsSpeed: Double = 1.0
    @Published var lastTTSPath: String? = nil

    @Published var cloneRefAudioPath: String = ""
    @Published var cloneRefText: String = ""
    @Published var cloneTargetText: String = "這是使用零樣本聲音複製模型在本地端合成的測試語音。"
    @Published var cloneSpeed: Double = 1.0
    @Published var lastClonePath: String? = nil

    @Published var showProgressLog: Bool = false
}

struct AIToolsStudioTab: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    var searchQuery: String

    @ObservedObject private var audioAI = AudioAIManager.shared
    @ObservedObject private var local = AIToolsLocalState.shared

    init(
        app: Studio,
        state: MultitrackEditState,
        playback: MultitrackPlaybackController,
        searchQuery: String = ""
    ) {
        self.app = app
        self.state = state
        self.playback = playback
        self.searchQuery = searchQuery
    }

    private var selectedMediaForAI: (path: String, timelineStart: Double)? {
        let layout = app.currentMultitrackLayout()
        guard let sel = state.selection else { return nil }
        switch sel {
        case .audioClip(let tid, let cid):
            if let seg = layout.audioSegment(trackID: tid, clipID: cid) {
                return (seg.clip.path, seg.timelineStart)
            }
        case .videoClip(let tid, let cid):
            if let seg = layout.videoSegment(trackID: tid, clipID: cid), !seg.clip.still {
                return (seg.clip.path, seg.timelineStart)
            }
        default:
            break
        }
        return nil
    }

    private func matchesSearch(_ keywords: String) -> Bool {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return keywords.lowercased().contains(q)
    }

    var body: some View {
        let vocalStatus = audioAI.modules["vocal_sep"] ?? AudioAIModuleStatus.defaults["vocal_sep"]!
        let asrStatus = audioAI.modules["asr"] ?? AudioAIModuleStatus.defaults["asr"]!
        let breeze26Status = audioAI.modules["asr_breeze26"] ?? AudioAIModuleStatus.defaults["asr_breeze26"]!
        let ttsStatus = audioAI.modules["tts"] ?? AudioAIModuleStatus.defaults["tts"]!
        let cloneStatus = audioAI.modules["voice_clone"] ?? AudioAIModuleStatus.defaults["voice_clone"]!

        GeometryReader { geo in
            let availW = max(160, geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Environment Header Card
                    envStatusHeaderCard

                    // 1. Vocal Separation
                    if matchesSearch("vocal separation stem 人聲 伴奏 分離 uvr mdx onnx") {
                        aiModuleCard(status: vocalStatus, icon: "music.mic", accent: proCyan) {
                            let target = selectedMediaForAI
                            VStack(alignment: .leading, spacing: 6) {
                                Text(target.map { "來源片段：\(filename($0.path))" } ?? "請於時間軸選取音訊或含音軌影片，或點此選檔分離。")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(target != nil ? .white.opacity(0.9) : .secondary)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Button {
                                        runVocalSep(source: target)
                                    } label: {
                                        Label(target != nil ? "分離為人聲軌 + 伴奏軌" : "選擇檔案並分離", systemImage: "waveform.path.ecg")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(proCyan)
                                    .controlSize(.small)
                                    .disabled(!vocalStatus.isReady || audioAI.busyModule != nil || app.busy)
                                }
                            }
                        }
                    }

                    // 2A. Taiwan Breeze-ASR-26 (Taigi / Mandarin / English Code-Switching Subtitles)
                    if matchesSearch("breeze asr 26 台灣 台語 閩南語 國台英 字幕 語音 辨識 mediatek") {
                        aiModuleCard(status: breeze26Status, icon: "waveform.and.mic", accent: proEmerald) {
                            let target = selectedMediaForAI
                            VStack(alignment: .leading, spacing: 6) {
                                Text("聯發創新基地 MediaTek Breeze-ASR-26（Apache 2.0）：專為台灣台語與國／台／英夾雜日常對話優化，直接輸出台灣繁體漢字字幕。")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 6) {
                                    Button {
                                        runASRTask(source: target, modelOverride: "breeze26")
                                    } label: {
                                        Label("以 Breeze-ASR-26 辨識台灣字幕", systemImage: "captions.bubble.fill")
                                            .font(.system(size: 10, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(KliporaPillButtonStyle(variant: .accent, compact: true))
                                    .disabled(!breeze26Status.isReady || audioAI.busyModule != nil || app.busy)
                                }
                            }
                        }
                    }

                    // 2B. ASR Auto Subtitles (Glossary Prompt + Editable Review Flow)
                    if matchesSearch("asr whisper subtitle 字幕 自動 語音 辨識 srt 繁體中文 校對 詞彙") {
                        aiModuleCard(status: asrStatus, icon: "captions.bubble.fill", accent: proAmber) {
                            let target = selectedMediaForAI
                            VStack(alignment: .leading, spacing: 6) {
                                Text(target.map { "來源片段：\(filename($0.path))" } ?? "請先選取影片／音訊片段，或點按鈕選檔辨識字幕。")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(target != nil ? .white.opacity(0.9) : .secondary)
                                    .lineLimit(1)

                                TextField("專有名詞／詞彙提示（選填，例如：湖畔工作室、語音合成）", text: $local.asrPrompt)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 9.5))

                                HStack(spacing: 6) {
                                    Picker("語言", selection: $local.asrLanguage) {
                                        Text("繁體中文").tag("zh")
                                        Text("English").tag("en")
                                        Text("日本語").tag("ja")
                                        Text("自動偵測").tag("auto")
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 84)

                                    Button {
                                        runASRTask(source: target)
                                    } label: {
                                        Label("辨識字幕草稿", systemImage: "text.bubble.fill")
                                            .font(.system(size: 10, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(proAmber)
                                    .controlSize(.small)
                                    .disabled(!asrStatus.isReady || audioAI.busyModule != nil || app.busy)
                                }

                                if !local.asrDraftSegments.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "pencil.and.outline")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(proAmber)
                                            Text("字幕草稿校對（\(local.asrDraftSegments.count) 條）· 輕量模型可能出現同音錯字，請直接編修後匯入 T 軌")
                                                .font(.system(size: 8.5))
                                                .foregroundStyle(.secondary)
                                        }

                                        ForEach(Array(local.asrDraftSegments.enumerated()), id: \.element.id) { idx, seg in
                                            HStack(alignment: .center, spacing: 5) {
                                                Text(String(format: "%.1f–%.1fs", seg.start, seg.end))
                                                    .font(.system(size: 8.5, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 58, alignment: .leading)
                                                TextField(
                                                    "字幕內容",
                                                    text: Binding(
                                                        get: {
                                                            idx < local.asrDraftSegments.count ? local.asrDraftSegments[idx].text : ""
                                                        },
                                                        set: { nextVal in
                                                            if idx < local.asrDraftSegments.count {
                                                                local.asrDraftSegments[idx].text = nextVal
                                                            }
                                                        }
                                                    )
                                                )
                                                .textFieldStyle(.roundedBorder)
                                                .font(.system(size: 9.5))
                                                Button {
                                                    if idx < local.asrDraftSegments.count {
                                                        local.asrDraftSegments.remove(at: idx)
                                                    }
                                                } label: {
                                                    Image(systemName: "trash")
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(proRose)
                                                }
                                                .buttonStyle(.borderless)
                                                .help("刪除此行草稿")
                                            }
                                        }

                                        HStack(spacing: 6) {
                                            Button {
                                                commitASRDraftToTimeline()
                                            } label: {
                                                Label("確認匯入 T 軌並更新 SRT", systemImage: "checkmark.circle.fill")
                                                    .font(.system(size: 9.5, weight: .semibold))
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(proEmerald)
                                            .controlSize(.small)

                                            Button("清除草稿") {
                                                local.asrDraftSegments = []
                                            }
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(6)
                                    .background(proDarkWell, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(proAmber.opacity(0.3)))
                                }

                                if let srt = local.lastSRTPath {
                                    Text("SRT 檔案：\(filename(srt))")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(proEmerald)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // 3. Chinese TTS (Kokoro INT8)
                    if matchesSearch("tts kokoro 中文 配音 語音 合成 旁白 說話人") {
                        aiModuleCard(status: ttsStatus, icon: "waveform.and.mic", accent: proEmerald) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextEditor(text: $local.ttsText)
                                    .font(.system(size: 10.5))
                                    .frame(height: 54)
                                    .scrollContentBackground(.hidden)
                                    .padding(4)
                                    .background(proDarkWell, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.08)))

                                HStack(spacing: 6) {
                                    Text("說話人")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                    Picker("", selection: $local.ttsSpeakerID) {
                                        ForEach(AudioAISpeakerOption.chineseSpeakers) { sp in
                                            Text(sp.displayName).tag(sp.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .controlSize(.small)
                                }

                                proSliderRow(
                                    title: "語速",
                                    value: $local.ttsSpeed,
                                    range: 0.6...1.6,
                                    valueText: String(format: "%.2fx", local.ttsSpeed)
                                )

                                HStack(spacing: 6) {
                                    Button {
                                        runTTSTask()
                                    } label: {
                                        Label("合成並加入音訊軌", systemImage: "waveform.badge.plus")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(proEmerald)
                                    .controlSize(.small)
                                    .disabled(!ttsStatus.isReady || local.ttsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audioAI.busyModule != nil || app.busy)

                                    if let lastTTS = local.lastTTSPath {
                                        Button {
                                            audioAI.playLocalAudioFile(path: lastTTS, tag: "tts_last")
                                        } label: {
                                            Label("試聽", systemImage: "play.fill")
                                                .font(.system(size: 9.5))
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }

                    // 4. Zero-Shot Voice Clone (ZipVoice-Distill INT8)
                    if matchesSearch("voice clone zipvoice 聲音 複製 克隆 音色 zero shot") {
                        aiModuleCard(status: cloneStatus, icon: "person.wave.2.fill", accent: proViolet) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 5) {
                                    Text(local.cloneRefAudioPath.isEmpty ? "尚未選擇參考音訊" : "參考音訊：\(filename(local.cloneRefAudioPath))")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(local.cloneRefAudioPath.isEmpty ? Color.secondary : Color.white)
                                        .lineLimit(1)
                                    Spacer()
                                }

                                HStack(spacing: 5) {
                                    Button("選擇檔案") {
                                        pickAudioOrVideoFile(title: "選擇參考聲音檔案（建議 3–12 秒清晰人聲）") { chosen in
                                            local.cloneRefAudioPath = chosen
                                        }
                                    }
                                    .controlSize(.mini)

                                    if let target = selectedMediaForAI {
                                        Button("使用目前選取片段") {
                                            local.cloneRefAudioPath = target.path
                                        }
                                        .controlSize(.mini)
                                    }
                                }

                                TextField("參考音訊逐字稿（選填；留空且已裝 ASR 時自動辨識）", text: $local.cloneRefText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10))

                                TextEditor(text: $local.cloneTargetText)
                                    .font(.system(size: 10.5))
                                    .frame(height: 52)
                                    .scrollContentBackground(.hidden)
                                    .padding(4)
                                    .background(proDarkWell, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.08)))

                                proSliderRow(
                                    title: "語速",
                                    value: $local.cloneSpeed,
                                    range: 0.7...1.4,
                                    valueText: String(format: "%.2fx", local.cloneSpeed)
                                )

                                HStack(spacing: 6) {
                                    Button {
                                        runVoiceCloneTask()
                                    } label: {
                                        Label("執行聲音複製並入軌", systemImage: "sparkles")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(proViolet)
                                    .controlSize(.small)
                                    .disabled(!cloneStatus.isReady
                                              || local.cloneRefAudioPath.isEmpty
                                              || local.cloneTargetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                              || audioAI.busyModule != nil
                                              || app.busy)

                                    if let lastClone = local.lastClonePath {
                                        Button {
                                            audioAI.playLocalAudioFile(path: lastClone, tag: "clone_last")
                                        } label: {
                                            Label("試聽", systemImage: "play.fill")
                                                .font(.system(size: 9.5))
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(width: availW, alignment: .leading)
                .clipped()
            }
            .frame(width: availW, alignment: .topLeading)
        }
        .background(panel)
        .onAppear {
            if !audioAI.hasLoadedStatus {
                audioAI.refreshStatus()
            }
        }
    }

    private var envStatusHeaderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(proCyan)
                    .font(.system(size: 11))
                Text("本地輕量音訊 AI（ONNX）")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                if audioAI.isRefreshingStatus || !audioAI.hasLoadedStatus {
                    Button {
                        audioAI.cancelStatusRefresh()
                    } label: {
                        Label("取消", systemImage: "xmark.circle")
                            .font(.system(size: 9.5))
                    }
                    .controlSize(.mini)
                    .tint(proRose)
                } else {
                    Button {
                        audioAI.refreshStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(audioAI.busyModule != nil)
                    .help("重新整理本地 AI 環境狀態")

                    Button {
                        audioAI.refreshStatus(forceRecalculateSizes: true)
                    } label: {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(audioAI.busyModule != nil)
                    .help("強制重新統計 ai-audio-venv 與模型目錄磁碟大小")
                }
            }

            if !audioAI.hasLoadedStatus || audioAI.isRefreshingStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("檢查本地 AI 環境中（上限 \(Int(audioAI.statusProbeTimeoutSeconds)) 秒）…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                }
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(audioAI.venvReady ? proEmerald : proAmber)
                        .frame(width: 7, height: 7)
                    Text(
                        audioAI.venvReady
                            ? "Python \(audioAI.venvPythonVersion ?? "3.12") 就緒（ai-audio-venv）"
                            : "尚未建立獨立環境（ai-audio-venv）"
                    )
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Text(proFormatBytes(audioAI.totalInstalledBytes))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 6) {
                    if !audioAI.venvReady {
                        Button("安裝獨立環境") {
                            audioAI.install(module: "venv")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(proCyan)
                        .controlSize(.mini)
                        .disabled(audioAI.busyModule != nil)
                    }

                    if audioAI.totalInstalledBytes > 0 {
                        Button("移除 AI 環境", role: .destructive) {
                            audioAI.uninstall(module: "all")
                        }
                        .controlSize(.mini)
                        .disabled(audioAI.busyModule != nil)
                    }

                    Spacer(minLength: 2)

                    if !audioAI.progressLog.isEmpty {
                        Button(local.showProgressLog ? "隱藏日誌" : "日誌") {
                            local.showProgressLog.toggle()
                        }
                        .controlSize(.mini)
                    }
                }
            }

            if let busy = audioAI.busyModule {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(audioAI.lastStatusMessage ?? "執行中：\(busy)...")
                        .font(.system(size: 9.5))
                        .foregroundStyle(proCyan)
                        .lineLimit(2)
                }
            } else if let msg = audioAI.lastStatusMessage {
                Text(msg)
                    .font(.system(size: 9.5))
                    .foregroundStyle(proEmerald)
            }

            if let err = audioAI.lastError {
                HStack(spacing: 6) {
                    Image(systemName: audioAI.statusTimedOut ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(proRose)
                    Text(err)
                        .font(.system(size: 9.5))
                        .foregroundStyle(proRose)
                    Spacer()
                    Button("重試檢查") {
                        audioAI.refreshStatus()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(proAmber)
                    .controlSize(.mini)
                    .disabled(audioAI.isRefreshingStatus)
                }
            }

            if local.showProgressLog && !audioAI.progressLog.isEmpty {
                ScrollView {
                    Text(audioAI.progressLog)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
                .padding(5)
                .background(proDarkWell, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
    }

    private func aiModuleCard<Content: View>(
        status: AudioAIModuleStatus,
        icon: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(status.isReady ? accent : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 5) {
                        Text("約 \(status.sizeMB) MB")
                        Text("·")
                        Text(status.license)
                    }
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if !audioAI.hasLoadedStatus || audioAI.isRefreshingStatus {
                    Text("檢查中…")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(proCyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(proCyan.opacity(0.16), in: Capsule())
                } else if audioAI.statusTimedOut {
                    Text("檢查逾時")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(proRose)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(proRose.opacity(0.16), in: Capsule())
                } else {
                    Text(status.isReady ? "已安裝" : (status.modelInstalled ? "需環境" : "未安裝"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(status.isReady ? proEmerald : proAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((status.isReady ? proEmerald : proAmber).opacity(0.16), in: Capsule())
                }
            }

            if !audioAI.hasLoadedStatus || audioAI.isRefreshingStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在檢查模型狀態…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") {
                        audioAI.cancelStatusRefresh()
                    }
                    .controlSize(.mini)
                }
            } else if audioAI.statusTimedOut {
                HStack(spacing: 6) {
                    Text("狀態探測逾時，請點擊重試檢查以載入此模組。")
                        .font(.system(size: 9))
                        .foregroundStyle(proRose)
                    Spacer()
                    Button("重試檢查") {
                        audioAI.refreshStatus()
                    }
                    .controlSize(.mini)
                }
            } else {
                HStack(spacing: 6) {
                    if !status.isReady {
                        Button {
                            audioAI.install(module: status.id)
                        } label: {
                            Label("安裝模型（~\(status.sizeMB) MB）", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .controlSize(.mini)
                        .disabled(audioAI.busyModule != nil)
                    } else {
                        Text("已就緒 · \(proFormatBytes(status.diskSizeBytes))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("移除模型", role: .destructive) {
                            audioAI.uninstall(module: status.id)
                        }
                        .controlSize(.mini)
                        .disabled(audioAI.busyModule != nil)
                    }
                }

                if status.isReady {
                    Divider().overlay(.white.opacity(0.06))
                    content()
                } else {
                    Text("尚未安裝此模組；請先點擊上方「安裝模型」下載權重後方可使用。")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(surface.opacity(0.58), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(status.isReady ? accent.opacity(0.35) : .white.opacity(0.08)))
    }

    private func pickAudioOrVideoFile(title: String, receive: @escaping (String) -> Void) {
        app.pickAsync(
            title: title,
            types: [.audio, .movie, .mpeg4Movie, .wav, .mp3],
            multiple: false,
            directory: false
        ) { urls in
            if let url = urls.first {
                receive(url.path)
            }
        }
    }

    private func runVocalSep(source: (path: String, timelineStart: Double)?) {
        if let source {
            executeVocalSep(inputPath: source.path, insertAt: source.timelineStart)
        } else {
            let at = playback.playhead
            pickAudioOrVideoFile(title: "選擇要進行人聲與伴奏分離的音訊或影片") { picked in
                executeVocalSep(inputPath: picked, insertAt: at)
            }
        }
    }

    private func executeVocalSep(inputPath: String, insertAt: Double) {
        let now = Date()
        let rootDir = app.audioOutputDirectory
        guard app.prepareOutputDirectory(datedDirectory(under: rootDir, on: now)) else { return }
        let inputStem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let cleanStem = inputStem.isEmpty ? "Audio" : inputStem
        let vocalsURL = allocateUniqueDatedOutputURL(under: rootDir, stem: "MotionDesk-Vocals-\(cleanStem)", ext: "wav", on: now)
        let accompURL = allocateUniqueDatedOutputURL(under: rootDir, stem: "MotionDesk-Accompaniment-\(cleanStem)", ext: "wav", on: now)
        let scratchDir = allocateHiddenDatedScratchDirectory(under: rootDir, prefix: "vocalsep", on: now)

        Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: scratchDir)
            }
            do {
                let res = try await audioAI.runVocalSeparation(
                    inputPath: inputPath,
                    outputDir: scratchDir,
                    vocalsOutputURL: vocalsURL,
                    accompanimentOutputURL: accompURL
                )
                let selVocal = app.addGeneratedAudioToTrack(
                    path: res.vocalsPath,
                    at: insertAt,
                    preferredTrackName: "人聲軌",
                    createNewTrack: !app.activeMultitrack.audioTracks.contains(where: { $0.name == "人聲軌" })
                )
                _ = app.addGeneratedAudioToTrack(
                    path: res.accompanimentPath,
                    at: insertAt,
                    preferredTrackName: "伴奏軌",
                    createNewTrack: !app.activeMultitrack.audioTracks.contains(where: { $0.name == "伴奏軌" })
                )
                if let selVocal {
                    state.selection = selVocal
                }
                state.previewMode = .timeline
                app.status = "已分離為人聲軌與伴奏軌 · \(filename(res.vocalsPath))"
                playback.syncLayout(app.currentMultitrackLayout())
            } catch {
                app.status = "人聲分離失敗：\(error.localizedDescription)"
            }
        }
    }

    private func runASRTask(source: (path: String, timelineStart: Double)?, modelOverride: String? = nil) {
        let model = modelOverride ?? local.asrModelChoice
        if let source {
            executeASRTask(inputPath: source.path, baseOffset: source.timelineStart, model: model)
        } else {
            let at = playback.playhead
            pickAudioOrVideoFile(title: "選擇要辨識自動字幕的音訊或影片") { picked in
                executeASRTask(inputPath: picked, baseOffset: at, model: model)
            }
        }
    }

    private func executeASRTask(inputPath: String, baseOffset: Double, model: String = "auto") {
        let now = Date()
        let rootDir = app.audioOutputDirectory
        guard app.prepareOutputDirectory(datedDirectory(under: rootDir, on: now)) else { return }
        let inputStem = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
        let cleanStem = inputStem.isEmpty ? "Subtitles" : inputStem
        let srtURL = allocateUniqueDatedOutputURL(under: rootDir, stem: "MotionDesk-ASR-\(cleanStem)", ext: "srt", on: now)
        let scratchDir = allocateHiddenDatedScratchDirectory(under: rootDir, prefix: "asr", on: now)
        let lang = local.asrLanguage
        let promptHint = local.asrPrompt
        Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: scratchDir)
            }
            do {
                let res = try await audioAI.runASR(
                    inputPath: inputPath,
                    language: lang,
                    initialPrompt: promptHint,
                    model: model,
                    outputDir: scratchDir,
                    outputSRTURL: srtURL
                )
                local.lastSRTPath = res.srtPath
                local.asrDraftSegments = res.segments
                local.asrDraftBaseOffset = baseOffset
                local.asrDraftSourceName = filename(inputPath)
                local.asrModelUsed = res.model
                app.status = "已產生 \(res.segments.count) 條字幕草稿（\(filename(res.srtPath))），請於 AI 工具面板校對後匯入 T 軌"
            } catch {
                app.status = "自動字幕辨識失敗：\(error.localizedDescription)"
            }
        }
    }

    private func commitASRDraftToTimeline() {
        let cleaned = local.asrDraftSegments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cleaned.isEmpty else { return }

        if let srtPath = local.lastSRTPath {
            try? AudioAIManager.writeSRT(segments: cleaned, to: srtPath)
        } else {
            let now = Date()
            let rootDir = app.audioOutputDirectory
            if app.prepareOutputDirectory(datedDirectory(under: rootDir, on: now)) {
                let fallbackSRT = allocateUniqueDatedOutputURL(under: rootDir, stem: "MotionDesk-ASR-Subtitles", ext: "srt", on: now)
                try? AudioAIManager.writeSRT(segments: cleaned, to: fallbackSRT.path)
                local.lastSRTPath = fallbackSRT.path
            }
        }
        let baseOffset = local.asrDraftBaseOffset
        let shifted = cleaned.map {
            (start: baseOffset + $0.start, end: baseOffset + $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let firstSel = app.addASRSubtitleSegments(shifted, to: state.activeTextTrackID) {
            state.selection = firstSel
            state.previewMode = .timeline
            playback.syncLayout(app.currentMultitrackLayout())
            app.status = "已匯入 \(shifted.count) 條校對後字幕至 T 軌並更新 SRT"
            local.asrDraftSegments = []
        }
    }

    private func runTTSTask() {
        let text = local.ttsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = Date()
        let rootDir = app.audioOutputDirectory
        guard app.prepareOutputDirectory(datedDirectory(under: rootDir, on: now)) else { return }
        let outURL = allocateUniqueDatedOutputURL(under: rootDir, stem: "MotionDesk-TTS", ext: "wav", on: now)
        let speaker = local.ttsSpeakerID
        let speed = local.ttsSpeed
        let at = playback.playhead

        Task { @MainActor in
            do {
                let res = try await audioAI.runTTS(text: text, speakerID: speaker, speed: speed, outputURL: outURL)
                local.lastTTSPath = res.path
                if let sel = app.addGeneratedAudioToTrack(
                    path: res.path,
                    at: at,
                    preferredTrackName: "AI 配音軌"
                ) {
                    state.selection = sel
                    state.previewMode = .timeline
                    app.status = "已合成中文配音並加入音訊軌 · \(filename(res.path))"
                    playback.syncLayout(app.currentMultitrackLayout())
                }
            } catch {
                app.status = "中文配音合成失敗：\(error.localizedDescription)"
            }
        }
    }

    private func runVoiceCloneTask() {
        let refPath = local.cloneRefAudioPath
        let text = local.cloneTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refPath.isEmpty, !text.isEmpty else { return }
        let now = Date()
        let rootDir = app.audioOutputDirectory
        guard app.prepareOutputDirectory(datedDirectory(under: rootDir, on: now)) else { return }
        let outURL = allocateUniqueDatedOutputURL(under: rootDir, stem: "MotionDesk-VoiceClone", ext: "wav", on: now)
        let refText = local.cloneRefText
        let speed = local.cloneSpeed
        let at = playback.playhead

        Task { @MainActor in
            do {
                let res = try await audioAI.runVoiceClone(
                    refAudioPath: refPath,
                    refText: refText,
                    text: text,
                    speed: speed,
                    outputURL: outURL
                )
                local.lastClonePath = res.path
                if res.refTextAutoTranscribed && local.cloneRefText.isEmpty {
                    local.cloneRefText = res.refTextUsed
                }
                if let sel = app.addGeneratedAudioToTrack(
                    path: res.path,
                    at: at,
                    preferredTrackName: "AI 聲音複製軌"
                ) {
                    state.selection = sel
                    state.previewMode = .timeline
                    app.status = "已完成聲音複製並加入音訊軌 · \(filename(res.path))"
                    playback.syncLayout(app.currentMultitrackLayout())
                }
            } catch {
                app.status = "聲音複製失敗：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 4.7 KeyframeAndSpeedRampInspectorSection (Keyframes + Speed Ramp Curves)

@MainActor
private final class KeyframeInspectorLocalState: ObservableObject {
    @Published var selectedProperty: KeyframeProperty = .scale
    @Published var selectedEasing: KeyframeEasing = .easeInOut
}

struct KeyframeAndSpeedRampInspectorSection: View {
    let seg: VideoSegmentLayout
    @ObservedObject var app: Studio
    @ObservedObject var playback: MultitrackPlaybackController

    @StateObject private var local = KeyframeInspectorLocalState()

    private let videoProperties: [KeyframeProperty] = [.posX, .posY, .scale, .rotation, .opacity]

    private var localTime: Double {
        let raw = playback.playhead - seg.timelineStart
        return MultitrackLayout.roundTime(min(max(0, raw), max(0, seg.duration)))
    }

    private func currentBaseValue(for prop: KeyframeProperty) -> Double {
        switch prop {
        case .posX: return seg.clip.posX
        case .posY: return seg.clip.posY
        case .scale: return seg.clip.scale
        case .rotation: return seg.clip.rotation
        case .opacity: return seg.clip.opacity
        case .volume: return seg.clip.volume
        }
    }

    private func formattedValue(_ val: Double, for prop: KeyframeProperty) -> String {
        switch prop {
        case .posX, .posY: return String(format: "%.0f%%", val * 100)
        case .scale: return String(format: "%.2fx", val)
        case .rotation: return String(format: "%.0f°", val)
        case .opacity, .volume: return String(format: "%.0f%%", val * 100)
        }
    }

    private func matchingSpeedRampPresetID() -> String? {
        let pts = seg.clip.speedCurve
        if pts.isEmpty { return "none" }
        for preset in SpeedRampPreset.presets where preset.points.count == pts.count {
            let same = zip(preset.points, pts).allSatisfy {
                abs($0.progress - $1.progress) < 0.01 && abs($0.speed - $1.speed) < 0.02
            }
            if same { return preset.id }
        }
        return nil
    }

    var body: some View {
        let currentProp = local.selectedProperty
        let baseVal = currentBaseValue(for: currentProp)
        let evalVal = KeyframeEvaluator.evaluate(
            keyframes: seg.clip.keyframes,
            property: currentProp,
            localTime: localTime,
            fallback: baseVal
        )
        let sortedKeyframes = seg.clip.keyframes.sorted {
            if abs($0.time - $1.time) > 0.001 { return $0.time < $1.time }
            return $0.property < $1.property
        }

        VStack(alignment: .leading, spacing: 10) {
            // Part 1: Keyframes
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    proSectionHeader(icon: "diamond.fill", title: "關鍵影格動畫（Keyframes）", accent: proAmber)
                    Spacer()
                    Text("片段時間 \(String(format: "%.2fs", localTime))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Property chips
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4)], spacing: 4) {
                    ForEach(videoProperties) { prop in
                        let active = local.selectedProperty == prop
                        Button(prop.displayName) {
                            local.selectedProperty = prop
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? canvas : .white.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .background(active ? proAmber : surface, in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                // Easing curve chips
                HStack(spacing: 4) {
                    Text("緩動")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    ForEach(KeyframeEasing.allCases) { ease in
                        let active = local.selectedEasing == ease
                        Button(ease.displayName) {
                            local.selectedEasing = ease
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? canvas : .white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(active ? proCyan : surface, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                }

                // Add / Update Keyframe Action
                HStack(spacing: 6) {
                    Button {
                        app.upsertVideoKeyframe(
                            clipID: seg.id,
                            property: currentProp,
                            time: localTime,
                            value: baseVal,
                            easing: local.selectedEasing
                        )
                        playback.syncLayout(app.currentMultitrackLayout())
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "diamond.fill")
                                .font(.system(size: 9))
                            Text("加入／更新 \(currentProp.displayName)（\(formattedValue(baseVal, for: currentProp))）")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(proAmber)
                    .controlSize(.small)
                    .disabled(app.busy)
                }

                Text("目前播放頭插值：\(formattedValue(evalVal, for: currentProp))（調整上方變換數值後再次點擊即可寫入新關鍵點）")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)

                // Existing Keyframe Chips (Click to seek, X to delete)
                if !sortedKeyframes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("已設定關鍵影格（\(sortedKeyframes.count)）")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("清除全部") {
                                app.updateVideoClipProperties(id: seg.id) { $0.keyframes = [] }
                                playback.syncLayout(app.currentMultitrackLayout())
                            }
                            .controlSize(.mini)
                            .disabled(app.busy)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 4)], spacing: 4) {
                            ForEach(sortedKeyframes) { kf in
                                let prop = KeyframeProperty(rawValue: kf.property) ?? .scale
                                HStack(spacing: 4) {
                                    Button {
                                        playback.pause()
                                        playback.seek(to: seg.timelineStart + kf.time, exact: true)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "diamond.fill")
                                                .font(.system(size: 7))
                                                .foregroundStyle(proAmber)
                                            Text("\(prop.displayName) \(String(format: "%.2fs", kf.time))")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text(formattedValue(kf.value, for: prop))
                                                .font(.system(size: 8.5, design: .monospaced))
                                                .foregroundStyle(proCyan)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    Spacer(minLength: 2)

                                    Button {
                                        app.removeVideoKeyframe(clipID: seg.id, keyframeID: kf.id)
                                        playback.syncLayout(app.currentMultitrackLayout())
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(app.busy)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(proDarkWell, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.08)))
                            }
                        }
                    }
                }
            }

            Divider().overlay(.white.opacity(0.08))

            // Part 2: Speed Ramp Curves
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    proSectionHeader(icon: "speedometer", title: "曲線變速（Speed Ramp）", accent: proCyan)
                    Spacer()
                    if !seg.clip.speedCurve.isEmpty {
                        Text("\(seg.clip.speedCurve.count) 個控制點")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(proCyan)
                    }
                }

                // Miniature Speed Ramp Curve Graph
                speedCurveGraph(points: seg.clip.speedCurve)
                    .frame(height: 54)
                    .background(proDarkWell, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.08)))

                // Speed Ramp Preset Cards
                let activePresetID = matchingSpeedRampPresetID()
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                    ForEach(SpeedRampPreset.presets) { preset in
                        let isCur = activePresetID == preset.id
                        Button {
                            app.applySpeedRampPreset(clipID: seg.id, preset: preset)
                            playback.syncLayout(app.currentMultitrackLayout())
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.system(size: 10, weight: isCur ? .semibold : .medium))
                                    .foregroundStyle(isCur ? canvas : .white)
                                Text(preset.description)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(isCur ? canvas.opacity(0.82) : .secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(isCur ? proCyan : surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isCur ? proCyan : .white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(seg.clip.still || app.busy)
                    }
                }
            }
        }
        .padding(8)
        .background(surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
    }

    private func speedCurveGraph(points: [SpeedRampPoint]) -> some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let pad: CGFloat = 8

            // 1.0x horizontal baseline
            let y1x = h - pad - ((1.0 - 0.25) / 3.75) * (h - pad * 2)
            var baseLine = Path()
            baseLine.move(to: CGPoint(x: pad, y: y1x))
            baseLine.addLine(to: CGPoint(x: w - pad, y: y1x))
            ctx.stroke(baseLine, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            let sorted = points.sorted { $0.progress < $1.progress }
            let drawPts: [CGPoint] = {
                if sorted.count >= 2 {
                    return sorted.map { pt in
                        let x = pad + CGFloat(pt.progress) * (w - pad * 2)
                        let norm = (min(4.0, max(0.25, pt.speed)) - 0.25) / 3.75
                        let y = h - pad - CGFloat(norm) * (h - pad * 2)
                        return CGPoint(x: x, y: y)
                    }
                } else {
                    return [CGPoint(x: pad, y: y1x), CGPoint(x: w - pad, y: y1x)]
                }
            }()

            var curve = Path()
            if let first = drawPts.first {
                curve.move(to: first)
                for pt in drawPts.dropFirst() {
                    curve.addLine(to: pt)
                }
            }
            ctx.stroke(curve, with: .color(sorted.count >= 2 ? proCyan : .secondary), lineWidth: 2)

            for pt in drawPts {
                let dot = Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6))
                ctx.fill(dot, with: .color(sorted.count >= 2 ? proAmber : .secondary))
            }
        }
    }
}

// MARK: - Shared Private UI Building Blocks

private func proSectionHeader(icon: String, title: String, accent: Color) -> some View {
    HStack(spacing: 5) {
        Image(systemName: icon)
            .font(.system(size: 10.5))
            .foregroundStyle(accent)
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
    }
}

private func proSliderRow(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    valueText: String
) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(valueText)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
        }
        Slider(value: value, in: range)
            .controlSize(.mini)
    }
}
