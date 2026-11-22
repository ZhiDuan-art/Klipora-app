import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import SwiftUI

// MARK: - Local Darkroom Palette for Voicebox Integration

private let vbCyan = Color(red: 0.28, green: 0.82, blue: 0.96)
private let vbAmber = Color(red: 0.96, green: 0.72, blue: 0.34)
private let vbEmerald = Color(red: 0.34, green: 0.84, blue: 0.58)
private let vbViolet = Color(red: 0.65, green: 0.54, blue: 0.98)
private let vbRose = Color(red: 0.96, green: 0.38, blue: 0.44)
private let vbDarkWell = Color(red: 0.055, green: 0.060, blue: 0.074)

// MARK: - 1. Voicebox Data Models

struct VoiceboxProfile: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var description: String?
    var language: String
    var voice_type: String?
    var preset_engine: String?
    var preset_voice_id: String?
    var design_prompt: String?
    var default_engine: String?
    var generation_count: Int?
    var sample_count: Int?

    init(
        id: String,
        name: String,
        description: String? = nil,
        language: String = "zh",
        voice_type: String? = "cloned",
        preset_engine: String? = nil,
        preset_voice_id: String? = nil,
        design_prompt: String? = nil,
        default_engine: String? = nil,
        generation_count: Int? = 0,
        sample_count: Int? = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.language = language
        self.voice_type = voice_type
        self.preset_engine = preset_engine
        self.preset_voice_id = preset_voice_id
        self.design_prompt = design_prompt
        self.default_engine = default_engine
        self.generation_count = generation_count
        self.sample_count = sample_count
    }

    var voiceType: String {
        let raw = (voice_type ?? "cloned").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "cloned" : raw
    }

    var isPreset: Bool {
        voiceType == "preset"
    }

    var isCloned: Bool {
        voiceType == "cloned"
    }

    var voiceTypeTag: String {
        switch voiceType {
        case "preset":
            return "內建預設"
        case "designed":
            return "音色設計"
        default:
            return "參考音訊"
        }
    }
}

struct VoiceboxSample: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var profile_id: String
    var audio_path: String
    var reference_text: String
}

struct VoiceboxHistoryItem: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var profile_id: String
    var profile_name: String?
    var text: String
    var language: String
    var audio_path: String?
    var duration: Double?
    var engine: String?
    var model_size: String?
    var status: String?
    var error: String?
    var instruct: String?
}

struct VoiceboxHistoryListResponse: Codable, Equatable {
    var items: [VoiceboxHistoryItem]
    var total: Int
}

struct VoiceboxModelStatus: Codable, Identifiable, Equatable, Hashable {
    var id: String { model_name }
    var model_name: String
    var display_name: String
    var hf_repo_id: String?
    var downloaded: Bool
    var downloading: Bool?
    var size_mb: Double?
    var loaded: Bool?
}

struct VoiceboxModelStatusListResponse: Codable, Equatable {
    var models: [VoiceboxModelStatus]
}

struct VoiceboxHealthResponse: Codable, Equatable {
    var status: String
    var model_loaded: Bool?
    var model_downloaded: Bool?
    var model_size: String?
    var gpu_available: Bool?
    var gpu_type: String?
    var backend_type: String?
    var backend_variant: String?
}

struct VoiceboxActiveDownloadTask: Codable, Equatable {
    var model_name: String
    var status: String
    var error: String?
    var progress: Double?
    var current: Int64?
    var total: Int64?
    var filename: String?
}

struct VoiceboxActiveGenerationTask: Codable, Equatable {
    var task_id: String
    var profile_id: String
    var text_preview: String?
}

struct VoiceboxActiveTasksResponse: Codable, Equatable {
    var downloads: [VoiceboxActiveDownloadTask]
    var generations: [VoiceboxActiveGenerationTask]
}

struct VoiceboxColabJobResponse: Codable, Equatable {
    var id: String
    var status: String?
    var stage: String?
    var error: String?
    var profile_id: String?
    var profile_name: String?
    var text: String?
    var duration: Double?
    var generation_id: String?
    var progress: Double?
}

// MARK: - Voicebox Engine Catalog & Compatibility Rules

struct VoiceboxEngineOption: Codable, Identifiable, Equatable, Hashable {
    var id: String { model_name }
    let engine: String
    let model_size: String?
    let model_name: String
    let display_name: String
    let supportsClonedVoices: Bool
    let supportsPresetVoices: Bool
    let presetEngineMatch: String?
    let languages: [String]
    let isRecommendedChinese: Bool
    let englishOnly: Bool
    let supportsInstruct: Bool
    let caveat: String?

    var modelSize: String? { model_size }
    var modelName: String { model_name }
    var displayName: String { display_name }

    var compactDisplayName: String {
        switch model_name {
        case "qwen-tts-1.7B":
            return "Qwen3 1.7B Base（推薦中文）"
        case "qwen-tts-0.6B":
            return "Qwen3 0.6B Base（輕量）"
        case "qwen-custom-voice-1.7B":
            return "Qwen3 Custom 1.7B"
        case "qwen-custom-voice-0.6B":
            return "Qwen3 Custom 0.6B（輕量）"
        case "kokoro":
            return "Kokoro 82M"
        case "chatterbox-tts":
            return "Chatterbox 多語"
        case "luxtts":
            return "LuxTTS（英文）"
        case "chatterbox-turbo":
            return "Chatterbox Turbo（英文）"
        case "tada-1b":
            return "TADA 1B（英文）"
        default:
            return display_name
        }
    }

    static let allOptions: [VoiceboxEngineOption] = [
        VoiceboxEngineOption(
            engine: "qwen",
            model_size: "1.7B",
            model_name: "qwen-tts-1.7B",
            display_name: "Qwen3-TTS 1.7B Base（推薦中文聲音參考）",
            supportsClonedVoices: true,
            supportsPresetVoices: false,
            presetEngineMatch: nil,
            languages: ["zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"],
            isRecommendedChinese: true,
            englishOnly: false,
            supportsInstruct: true,
            caveat: nil
        ),
        VoiceboxEngineOption(
            engine: "qwen",
            model_size: "0.6B",
            model_name: "qwen-tts-0.6B",
            display_name: "Qwen3-TTS 0.6B Base（輕量 · 中文讀音較不準）",
            supportsClonedVoices: true,
            supportsPresetVoices: false,
            presetEngineMatch: nil,
            languages: ["zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"],
            isRecommendedChinese: false,
            englishOnly: false,
            supportsInstruct: true,
            caveat: "0.6B 為輕量模型，中文測試有讀音不準，建議使用 1.7B 製作中文旁白。"
        ),
        VoiceboxEngineOption(
            engine: "qwen_custom_voice",
            model_size: "1.7B",
            model_name: "qwen-custom-voice-1.7B",
            display_name: "Qwen3 CustomVoice 1.7B（內建聲音 Serena 等）",
            supportsClonedVoices: false,
            supportsPresetVoices: true,
            presetEngineMatch: "qwen_custom_voice",
            languages: ["zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"],
            isRecommendedChinese: true,
            englishOnly: false,
            supportsInstruct: true,
            caveat: nil
        ),
        VoiceboxEngineOption(
            engine: "qwen_custom_voice",
            model_size: "0.6B",
            model_name: "qwen-custom-voice-0.6B",
            display_name: "Qwen3 CustomVoice 0.6B（輕量 · 中文讀音較不準）",
            supportsClonedVoices: false,
            supportsPresetVoices: true,
            presetEngineMatch: "qwen_custom_voice",
            languages: ["zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"],
            isRecommendedChinese: false,
            englishOnly: false,
            supportsInstruct: true,
            caveat: "0.6B 中文讀音較不穩定，建議優先使用 1.7B。"
        ),
        VoiceboxEngineOption(
            engine: "kokoro",
            model_size: nil,
            model_name: "kokoro",
            display_name: "Kokoro 82M（內建聲音）",
            supportsClonedVoices: false,
            supportsPresetVoices: true,
            presetEngineMatch: "kokoro",
            languages: ["zh", "en", "ja", "fr", "es", "it", "pt", "hi"],
            isRecommendedChinese: false,
            englishOnly: false,
            supportsInstruct: false,
            caveat: nil
        ),
        VoiceboxEngineOption(
            engine: "chatterbox",
            model_size: nil,
            model_name: "chatterbox-tts",
            display_name: "Chatterbox Multilingual（多語聲音參考）",
            supportsClonedVoices: true,
            supportsPresetVoices: false,
            presetEngineMatch: nil,
            languages: ["zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"],
            isRecommendedChinese: false,
            englishOnly: false,
            supportsInstruct: false,
            caveat: nil
        ),
        VoiceboxEngineOption(
            engine: "luxtts",
            model_size: nil,
            model_name: "luxtts",
            display_name: "LuxTTS（僅英文 · CPU 快速）",
            supportsClonedVoices: true,
            supportsPresetVoices: false,
            presetEngineMatch: nil,
            languages: ["en"],
            isRecommendedChinese: false,
            englishOnly: true,
            supportsInstruct: false,
            caveat: "此引擎僅支援英文（en），不適用於中文旁白。"
        ),
        VoiceboxEngineOption(
            engine: "chatterbox_turbo",
            model_size: nil,
            model_name: "chatterbox-turbo",
            display_name: "Chatterbox Turbo（僅英文）",
            supportsClonedVoices: true,
            supportsPresetVoices: false,
            presetEngineMatch: nil,
            languages: ["en"],
            isRecommendedChinese: false,
            englishOnly: true,
            supportsInstruct: false,
            caveat: "此引擎僅支援英文（en），不適用於中文旁白。"
        ),
        VoiceboxEngineOption(
            engine: "tada",
            model_size: "1B",
            model_name: "tada-1b",
            display_name: "TADA 1B（僅英文）",
            supportsClonedVoices: true,
            supportsPresetVoices: false,
            presetEngineMatch: nil,
            languages: ["en"],
            isRecommendedChinese: false,
            englishOnly: true,
            supportsInstruct: false,
            caveat: "此引擎僅支援英文（en），不適用於中文旁白。"
        )
    ]

    static let cloningEngineNames: Set<String> = [
        "qwen", "chatterbox", "luxtts", "chatterbox_turbo", "tada"
    ]

    static func compatibleOptions(for profile: VoiceboxProfile) -> [VoiceboxEngineOption] {
        if profile.voiceType == "preset" {
            let targetEngine = (profile.preset_engine?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "qwen_custom_voice"
            return allOptions.filter { $0.engine == targetEngine }
        } else {
            return allOptions.filter { cloningEngineNames.contains($0.engine) }
        }
    }

    static func preferredDefault(for profile: VoiceboxProfile) -> VoiceboxEngineOption {
        let compatible = compatibleOptions(for: profile)
        if let defEngine = profile.default_engine,
           let matched = compatible.first(where: { $0.engine == defEngine && ($0.model_size == "1.7B" || $0.model_size == nil) }) {
            return matched
        }
        if let rec = compatible.first(where: { $0.isRecommendedChinese }) {
            return rec
        }
        return compatible.first ?? allOptions[0]
    }
}

enum VoiceboxGenerationMode: String, CaseIterable, Identifiable {
    case local = "local"
    case colab = "colab"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "本機 Qwen3-TTS"
        case .colab:
            return "雲端 Colab H3"
        }
    }
}

enum VoiceboxIntegrationError: LocalizedError {
    case unsupportedArchitecture
    case binaryMissing
    case serviceNotReady(String)
    case incompatibleEngine(String)
    case emptyScript
    case sampleRequired
    case serverError(String)
    case generationFailed(String)
    case generationCancelled
    case invalidAudioExport

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "目前僅支援 Apple Silicon (arm64) 架構執行本機 Voicebox 語音引擎。"
        case .binaryMissing:
            return "找不到內建或已安裝的 voicebox-server 服務執行檔。"
        case .serviceNotReady(let reason):
            return reason
        case .incompatibleEngine(let msg):
            return msg
        case .emptyScript:
            return "請先輸入要生成的旁白稿件內容。"
        case .sampleRequired:
            return "Colab H3 線上生成需要選擇此聲音的一個參考樣本。"
        case .serverError(let msg):
            return msg
        case .generationFailed(let msg):
            return msg
        case .generationCancelled:
            return "已取消語音生成。"
        case .invalidAudioExport:
            return "匯出的 WAV 音檔無效或為空。"
        }
    }
}

// MARK: - 2. Voicebox Service Ownership & Lifecycle Controller

@MainActor
final class VoiceboxServiceController: ObservableObject {
    static let shared = VoiceboxServiceController()

    enum ServiceOwnership: String, Equatable {
        case stopped
        case starting
        case ownedByMotionDesk
        case externalReused
        case failed
    }

    static let dataDirDefaultsKey = "MotionDesk.voicebox.dataDir"
    static let modelsDirDefaultsKey = "MotionDesk.voicebox.modelsDir"
    static let portDefaultsKey = "MotionDesk.voicebox.port"
    static let bridgePortDefaultsKey = "MotionDesk.voicebox.bridgePort"

    @Published var dataDirPath: String {
        didSet {
            UserDefaults.standard.set(dataDirPath, forKey: Self.dataDirDefaultsKey)
        }
    }

    @Published var modelsCachePath: String {
        didSet {
            UserDefaults.standard.set(modelsCachePath, forKey: Self.modelsDirDefaultsKey)
        }
    }

    @Published var localAPIPort: Int {
        didSet {
            UserDefaults.standard.set(localAPIPort, forKey: Self.portDefaultsKey)
        }
    }

    @Published var bridgePort: Int {
        didSet {
            UserDefaults.standard.set(bridgePort, forKey: Self.bridgePortDefaultsKey)
        }
    }

    @Published var ownership: ServiceOwnership = .stopped
    @Published var activePort: Int = 17495
    @Published var activeBridgePort: Int = 17494
    @Published var binarySource: String = "checking"
    @Published var isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    @Published var health: VoiceboxHealthResponse? = nil
    @Published var profiles: [VoiceboxProfile] = []
    @Published var samplesByProfileID: [String: [VoiceboxSample]] = [:]
    @Published var modelStatuses: [VoiceboxModelStatus] = []
    @Published var recentHistory: [VoiceboxHistoryItem] = []

    @Published var activeDownloads: [String: VoiceboxActiveDownloadTask] = [:]
    @Published var isGenerating: Bool = false
    @Published var activeGenerationID: String? = nil
    @Published var activeColabJobID: String? = nil
    @Published var generationStage: String = ""
    @Published var generationProgress: Double? = nil

    @Published var previewingProfileID: String? = nil
    @Published var isPreviewPlaying: Bool = false

    @Published var lastGeneratedWAVPath: String? = nil
    @Published var lastGeneratedDuration: Double? = nil
    @Published var lastGeneratedProfileName: String? = nil
    @Published var statusMessage: String? = nil
    @Published var lastError: String? = nil

    var ownedServerProcess: Process? = nil
    var ownedBridgeProcess: Process? = nil
    private var serverLogFileHandle: FileHandle? = nil
    private var bridgeLogFileHandle: FileHandle? = nil
    private var bridgeToken: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private var startupInFlightTask: Task<Bool, Never>? = nil
    private var activeGenerationTask: Task<URL, Error>? = nil
    private var downloadPollTask: Task<Void, Never>? = nil
    private var previewPlayer: AVAudioPlayer? = nil
    private var previewStopTimer: Timer? = nil
    private var terminationObserver: NSObjectProtocol? = nil
    private var configChangeObserver: NSObjectProtocol? = nil
    private var activeServerHFTokenSet: Bool = false

    private static func readStoredHuggingFaceToken() -> String? {
        if let token = KeychainCredentialsStore.read(account: "huggingface_token"),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let existingVoiceboxDir = home.appendingPathComponent("Library/Application Support/Klipora/voicebox-data", isDirectory: true)
        let existingVoiceboxDB = existingVoiceboxDir.appendingPathComponent("voicebox.db")
        let cleanMotionDeskDataDir = home.appendingPathComponent("Library/Application Support/Klipora/voicebox-data", isDirectory: true)

        if let savedDataDir = UserDefaults.standard.string(forKey: Self.dataDirDefaultsKey),
           !savedDataDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.dataDirPath = (savedDataDir as NSString).expandingTildeInPath
        } else if FileManager.default.fileExists(atPath: existingVoiceboxDB.path) {
            self.dataDirPath = existingVoiceboxDir.path
        } else {
            self.dataDirPath = cleanMotionDeskDataDir.path
        }

        let defaultModelsDir = home.appendingPathComponent("Library/Application Support/Klipora/models/huggingface/hub", isDirectory: true).path
        if let savedModelsDir = UserDefaults.standard.string(forKey: Self.modelsDirDefaultsKey),
           !savedModelsDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.modelsCachePath = (savedModelsDir as NSString).expandingTildeInPath
        } else {
            self.modelsCachePath = defaultModelsDir
        }

        let savedPort = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        let resolvedLocalPort = (savedPort > 1024 && savedPort < 65535) ? savedPort : 17495
        self.localAPIPort = resolvedLocalPort

        let savedBridgePort = UserDefaults.standard.integer(forKey: Self.bridgePortDefaultsKey)
        let resolvedBridgePort = (savedBridgePort > 1024 && savedBridgePort < 65535) ? savedBridgePort : 17494
        self.bridgePort = resolvedBridgePort

        self.activePort = resolvedLocalPort
        self.activeBridgePort = resolvedBridgePort

        let resolved = resolveServerBinaryURL()
        self.binarySource = resolved.source

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopOwnedServiceIfIdle(forceOnAppQuit: true)
            }
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .motionDeskVoiceboxConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadSettingsAndRestartIfNeeded()
            }
        }
    }

    func reloadSettingsAndRestartIfNeeded() {
        let savedDataDir = UserDefaults.standard.string(forKey: Self.dataDirDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedDataDir, !savedDataDir.isEmpty {
            let expanded = (savedDataDir as NSString).expandingTildeInPath
            if expanded != dataDirPath {
                dataDirPath = expanded
            }
        }
        let savedModelsDir = UserDefaults.standard.string(forKey: Self.modelsDirDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedModelsDir, !savedModelsDir.isEmpty {
            let expanded = (savedModelsDir as NSString).expandingTildeInPath
            if expanded != modelsCachePath {
                modelsCachePath = expanded
            }
        }
        let savedPort = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        if (1025...65534).contains(savedPort), savedPort != localAPIPort {
            localAPIPort = savedPort
        }
        if !isGenerating {
            Task { @MainActor in
                await restartForPathChange()
            }
        }
    }

    var effectiveDataDir: URL {
        let expanded = (dataDirPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    var effectiveModelsCacheDir: URL {
        let expanded = (modelsCachePath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    var modelLoaded: Bool {
        if health?.model_loaded == true {
            return true
        }
        return modelStatuses.contains(where: { $0.loaded == true })
    }

    var serviceStatusBadgeText: String {
        switch ownership {
        case .ownedByMotionDesk:
            return "本機服務已就緒 · 127.0.0.1:\(activePort)"
        case .externalReused:
            return "重用既有服務 · 127.0.0.1:\(activePort)"
        case .starting:
            return "啟動中…"
        case .failed:
            return "服務未就緒"
        case .stopped:
            return "未啟動"
        }
    }

    // MARK: Binary & Resource Resolution

    func resolveServerBinaryURL() -> (url: URL?, source: String) {
        let fm = FileManager.default
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundledBin = execDir.appendingPathComponent("voicebox-server")
            let bundledPatch = Bundle.main.resourceURL?.appendingPathComponent("backend-patches/mlx_backend.py")
            if fm.isExecutableFile(atPath: bundledBin.path) {
                if let patchURL = bundledPatch, fm.fileExists(atPath: patchURL.path) {
                    return (bundledBin, "bundled")
                }
            }
        }

        return (nil, "missing")
    }

    func resolveColabBridgeScriptURL() -> URL? {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("colab/bridge.py")
            if fm.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        return nil
    }

    // MARK: SSE Parsing & Collision-Safe Output Helpers (Testable Pure Functions)

    static func parseSSEDataLine(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payloadPart = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payloadPart.isEmpty,
              let data = payloadPart.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func uniqueOutputURL(in directory: URL, baseName: String, ext: String = "wav") -> URL {
        let fm = FileManager.default
        let sanitizedBase = sanitizeFilenameComponent(baseName)
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let firstCandidate = directory.appendingPathComponent("\(sanitizedBase).\(cleanExt)")
        if !fm.fileExists(atPath: firstCandidate.path) {
            return firstCandidate
        }
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(sanitizedBase)-\(counter).\(cleanExt)")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    static func sanitizeFilenameComponent(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>.\n\r\t")
        let joined = raw
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "Voicebox" : String(joined.prefix(48))
    }

    /// Pure testable profile filter: searches name, description, voiceTypeTag, language, and preset_voice_id.
    static func filterProfiles(
        _ profiles: [VoiceboxProfile],
        query: String,
        preservingSelectedID: String? = nil
    ) -> [VoiceboxProfile] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return profiles }
        var matched = profiles.filter { p in
            if p.name.lowercased().contains(q) { return true }
            if let desc = p.description?.lowercased(), desc.contains(q) { return true }
            if p.voiceTypeTag.lowercased().contains(q) { return true }
            if p.language.lowercased().contains(q) { return true }
            if let pv = p.preset_voice_id?.lowercased(), pv.contains(q) { return true }
            return false
        }
        if let selID = preservingSelectedID,
           !selID.isEmpty,
           !matched.contains(where: { $0.id == selID }),
           let sel = profiles.first(where: { $0.id == selID }) {
            matched.insert(sel, at: 0)
        }
        return matched
    }

    // MARK: Port & Identity Validation

    static func isLoopbackPortOccupied(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let polled = poll(&pfd, 1, 200)
            if polled > 0 {
                var soError: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 && soError == 0 {
                    return true
                }
            }
        }
        return false
    }

    static func findAvailableLoopbackPort(startingAt startPort: Int, maxPort: Int = 17515) -> Int {
        let lower = max(1025, startPort)
        let upper = max(lower, maxPort)
        for candidate in lower...upper {
            if !isLoopbackPortOccupied(candidate) {
                return candidate
            }
        }
        return startPort
    }

    func validateVoiceboxService(onPort port: Int) async -> (isValid: Bool, health: VoiceboxHealthResponse?, reason: String?) {
        guard let healthURL = URL(string: "http://127.0.0.1:\(port)/health"),
              let profilesURL = URL(string: "http://127.0.0.1:\(port)/profiles") else {
            return (false, nil, "無效的本機服務網址")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 4.0
        let session = URLSession(configuration: config)

        do {
            var healthReq = URLRequest(url: healthURL)
            healthReq.timeoutInterval = 4.0
            let (hData, hResp) = try await session.data(for: healthReq)
            guard let hHttp = hResp as? HTTPURLResponse else {
                return (false, nil, "連接埠 \(port) 回應非 HTTP 協定")
            }
            guard hHttp.statusCode == 200 else {
                return (false, nil, "連接埠 \(port) 已被非 Voicebox 服務佔用")
            }
            guard let decodedHealth = try? JSONDecoder().decode(VoiceboxHealthResponse.self, from: hData),
                  decodedHealth.status == "healthy" else {
                return (false, nil, "連接埠 \(port) 已被非 Voicebox 服務佔用")
            }

            var profReq = URLRequest(url: profilesURL)
            profReq.timeoutInterval = 4.0
            let (pData, pResp) = try await session.data(for: profReq)
            guard let pHttp = pResp as? HTTPURLResponse,
                  pHttp.statusCode == 200,
                  let jsonObj = try? JSONSerialization.jsonObject(with: pData),
                  jsonObj is [Any] else {
                return (false, nil, "連接埠 \(port) 已被非 Voicebox 服務佔用")
            }

            return (true, decodedHealth, nil)
        } catch {
            if Self.isLoopbackPortOccupied(port) {
                return (false, nil, "連接埠 \(port) 已被非 Voicebox 服務佔用")
            }
            return (false, nil, "本機連接埠 \(port) 尚未啟動服務")
        }
    }

    // MARK: Starting & Reusing Service

    @discardableResult
    func ensureServiceReady() async -> Bool {
        if !isAppleSilicon {
            ownership = .failed
            lastError = VoiceboxIntegrationError.unsupportedArchitecture.localizedDescription
            return false
        }

        if let existingTask = startupInFlightTask {
            return await existingTask.value
        }

        let task = Task<Bool, Never> { @MainActor in
            await self.performEnsureServiceReady()
        }
        startupInFlightTask = task
        let ready = await task.value
        startupInFlightTask = nil
        return ready
    }

    private func performEnsureServiceReady() async -> Bool {
        let resolved = resolveServerBinaryURL()
        binarySource = resolved.source

        // Step 1: Prevent duplicate startup on GPU-busy health timeout if our owned server is alive
        if let proc = ownedServerProcess, proc.isRunning {
            ownership = .ownedByMotionDesk
            if isGenerating {
                return true
            }
            let check = await validateVoiceboxService(onPort: activePort)
            if let h = check.health {
                self.health = h
            }
            await refreshCatalogData()
            return true
        }

        // Step 2: Probe configured localAPIPort
        let preferredPort = localAPIPort
        let probe = await validateVoiceboxService(onPort: preferredPort)
        if probe.isValid {
            activePort = preferredPort
            health = probe.health
            if ownedServerProcess?.isRunning == true {
                ownership = .ownedByMotionDesk
            } else {
                ownership = .externalReused
            }
            lastError = nil
            await refreshCatalogData()
            return true
        }

        // Also check activePort if it was previously shifted due to port collision
        if activePort != preferredPort {
            let shiftedProbe = await validateVoiceboxService(onPort: activePort)
            if shiftedProbe.isValid {
                health = shiftedProbe.health
                ownership = (ownedServerProcess?.isRunning == true) ? .ownedByMotionDesk : .externalReused
                lastError = nil
                await refreshCatalogData()
                return true
            }
        }

        // Step 3: If preferredPort is occupied by an unrelated non-Voicebox service, pick a free loopback port
        var targetPort = preferredPort
        if Self.isLoopbackPortOccupied(preferredPort) {
            let freePort = Self.findAvailableLoopbackPort(startingAt: max(17495, preferredPort + 1), maxPort: 17515)
            statusMessage = "連接埠 \(preferredPort) 已被其他服務佔用，已自動切換至 \(freePort)。"
            targetPort = freePort
        }
        activePort = targetPort

        // Step 4: Resolve voicebox-server binary
        guard let serverBinaryURL = resolved.url else {
            ownership = .failed
            lastError = "找不到內建或已安裝的 voicebox-server 服務執行檔。"
            return false
        }

        // Step 5: Launch owned voicebox-server
        ownership = .starting
        lastError = nil

        let fm = FileManager.default
        let dataDir = effectiveDataDir
        let modelsDir = effectiveModelsCacheDir
        let logsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/logs", isDirectory: true)

        do {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

            let logURL = logsDir.appendingPathComponent("voicebox-server.log")
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            try? serverLogFileHandle?.close()
            let logHandle = try FileHandle(forWritingTo: logURL)
            _ = try? logHandle.seekToEnd()
            self.serverLogFileHandle = logHandle

            let proc = Process()
            proc.executableURL = serverBinaryURL
            proc.arguments = [
                "--host", "127.0.0.1",
                "--port", String(targetPort),
                "--data-dir", dataDir.path,
                "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
            ]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = logHandle
            proc.standardError = logHandle

            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_CACHE"] = modelsDir.path
            env["VOICEBOX_MODELS_DIR"] = modelsDir.path
            if let hfToken = Self.readStoredHuggingFaceToken() {
                env["HF_TOKEN"] = hfToken
                env["HUGGING_FACE_HUB_TOKEN"] = hfToken
                self.activeServerHFTokenSet = true
            } else {
                env.removeValue(forKey: "HF_TOKEN")
                env.removeValue(forKey: "HUGGING_FACE_HUB_TOKEN")
                self.activeServerHFTokenSet = false
            }
            if let hfEndpoint = UserDefaults.standard.string(forKey: SupportedAPIProvider.huggingface.urlDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hfEndpoint.isEmpty,
               hfEndpoint != "https://huggingface.co" {
                env["HF_ENDPOINT"] = hfEndpoint
            }
            env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PYTHONUNBUFFERED"] = "1"
            proc.environment = env

            try proc.run()
            self.ownedServerProcess = proc
        } catch {
            ownership = .failed
            lastError = "啟動本機語音服務失敗：\(error.localizedDescription)"
            return false
        }

        // Step 6: Poll readiness up to 50 seconds (every 0.5s) without blocking main thread
        for _ in 0..<100 {
            if ownedServerProcess?.isRunning != true {
                ownership = .failed
                lastError = "voicebox-server 啟動後異常退出，請檢查服務環境或連接埠。"
                return false
            }
            let check = await validateVoiceboxService(onPort: targetPort)
            if check.isValid {
                ownership = .ownedByMotionDesk
                health = check.health
                lastError = nil
                await refreshCatalogData()
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        ownership = .failed
        lastError = "本機 Voicebox 服務啟動逾時（50 秒），請點選重試或檢查元件設定。"
        return false
    }

    func stopOwnedServiceIfIdle(forceOnAppQuit: Bool = false) {
        if ownership == .externalReused {
            // Never kill an externally owned user/Voicebox service
            return
        }
        if isGenerating && !forceOnAppQuit {
            return
        }

        if let bridgeProc = ownedBridgeProcess, bridgeProc.isRunning {
            bridgeProc.terminate()
        }
        ownedBridgeProcess = nil
        try? bridgeLogFileHandle?.close()
        bridgeLogFileHandle = nil

        if let serverProc = ownedServerProcess, serverProc.isRunning {
            serverProc.terminate()
        }
        ownedServerProcess = nil
        try? serverLogFileHandle?.close()
        serverLogFileHandle = nil

        if ownership == .ownedByMotionDesk || ownership == .starting {
            ownership = .stopped
        }
    }

    func restartForPathChange() async {
        stopOwnedServiceIfIdle(forceOnAppQuit: false)
        samplesByProfileID.removeAll()
        _ = await ensureServiceReady()
    }

    // MARK: Catalog Refresh (Profiles, Samples, Models, History)

    func refreshCatalogData() async {
        async let hTask: Void = refreshHealth()
        async let pTask: Void = refreshProfiles()
        async let mTask: Void = refreshModelStatuses()
        async let histTask: Void = refreshRecentHistory()
        _ = await (hTask, pTask, mTask, histTask)
    }

    func refreshHealth() async {
        if isGenerating && ownedServerProcess?.isRunning == true {
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(activePort)/health") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode(VoiceboxHealthResponse.self, from: data) {
            self.health = decoded
        }
    }

    func refreshProfiles() async {
        guard let url = URL(string: "http://127.0.0.1:\(activePort)/profiles") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode([VoiceboxProfile].self, from: data)
            self.profiles = decoded.filter { $0.voiceType != "import" && $0.name != "Imported Audio" }
        } catch {
            // Keep existing profiles on transient timeout
        }
    }

    @discardableResult
    func fetchSamples(for profileID: String, forceRefresh: Bool = false) async -> [VoiceboxSample] {
        if !forceRefresh, let cached = samplesByProfileID[profileID] {
            return cached
        }
        guard let url = URL(string: "http://127.0.0.1:\(activePort)/profiles/\(profileID)/samples") else {
            return []
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode([VoiceboxSample].self, from: data)
            samplesByProfileID[profileID] = decoded
            return decoded
        } catch {
            return samplesByProfileID[profileID] ?? []
        }
    }

    struct DerivedReferenceOverrideEntry: Codable, Equatable {
        var audio_sha256: String
        var sample_id: String
        var reference_text: String
    }

    struct DerivedReferenceOverrideManifest: Codable, Equatable {
        var version: Int = 1
        var entries: [DerivedReferenceOverrideEntry] = []
    }

    static var derivedReferenceOverridesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/cache/voicebox-reference-overrides.json")
    }

    static func loadDerivedReferenceOverrideManifest() -> DerivedReferenceOverrideManifest {
        let url = derivedReferenceOverridesFileURL
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(DerivedReferenceOverrideManifest.self, from: data) else {
            return DerivedReferenceOverrideManifest()
        }
        return manifest
    }

    private func computeSampleAudioSHA256(for sample: VoiceboxSample) async -> String? {
        let fm = FileManager.default
        let directURL = URL(fileURLWithPath: sample.audio_path)
        let dataDirCandidate = effectiveDataDir.appendingPathComponent(sample.audio_path)
        let previewCacheCandidate = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/cache/voicebox-previews/sample-\(sample.id).wav")

        for candidate in [directURL, dataDirCandidate, previewCacheCandidate] {
            if fm.isReadableFile(atPath: candidate.path),
               let fileData = try? Data(contentsOf: candidate),
               fileData.count > 44 {
                return SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
            }
        }

        if let sampleEndpoint = URL(string: "http://127.0.0.1:\(activePort)/samples/\(sample.id)"),
           let (remoteData, resp) = try? await URLSession.shared.data(from: sampleEndpoint),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           remoteData.count > 44 {
            try? fm.createDirectory(at: previewCacheCandidate.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? remoteData.write(to: previewCacheCandidate, options: .atomic)
            return SHA256.hash(data: remoteData).map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    func effectiveReferenceText(for sample: VoiceboxSample) async -> (text: String, isDerivedOverride: Bool) {
        let manifest = Self.loadDerivedReferenceOverrideManifest()
        guard !manifest.entries.isEmpty,
              let sha256 = await computeSampleAudioSHA256(for: sample) else {
            return (sample.reference_text, false)
        }
        if let matched = manifest.entries.first(where: {
            $0.audio_sha256.lowercased() == sha256.lowercased()
            && ($0.sample_id.isEmpty || $0.sample_id == sample.id)
        }) {
            let trimmed = matched.reference_text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (trimmed, true)
            }
        }
        return (sample.reference_text, false)
    }

    func saveDerivedSampleReferenceOverride(
        sample: VoiceboxSample,
        overrideText: String?
    ) async throws {
        guard let sha256 = await computeSampleAudioSHA256(for: sample) else {
            throw VoiceboxIntegrationError.serverError("無法讀取樣本音檔以計算 SHA-256 校驗雜湊。")
        }
        let url = Self.derivedReferenceOverridesFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var manifest = Self.loadDerivedReferenceOverrideManifest()
        manifest.entries.removeAll {
            $0.audio_sha256.lowercased() == sha256.lowercased() || $0.sample_id == sample.id
        }

        if let trimmed = overrideText?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            manifest.entries.append(
                DerivedReferenceOverrideEntry(
                    audio_sha256: sha256,
                    sample_id: sample.id,
                    reference_text: trimmed
                )
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)

        if let cacheURL = URL(string: "http://127.0.0.1:\(activePort)/cache/clear") {
            var cReq = URLRequest(url: cacheURL)
            cReq.httpMethod = "POST"
            cReq.timeoutInterval = 6.0
            _ = try? await URLSession.shared.data(for: cReq)
        }
    }

    func refreshModelStatuses() async {
        guard let url = URL(string: "http://127.0.0.1:\(activePort)/models/status") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8.0
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(VoiceboxModelStatusListResponse.self, from: data)
            self.modelStatuses = decoded.models
        } catch {
            // Ignore transient decode/network errors
        }
    }

    func refreshRecentHistory(profileID: String? = nil) async {
        var comps = URLComponents(string: "http://127.0.0.1:\(activePort)/history")
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "20")]
        if let profileID, !profileID.isEmpty {
            items.append(URLQueryItem(name: "profile_id", value: profileID))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6.0
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode(VoiceboxHistoryListResponse.self, from: data) {
            self.recentHistory = decoded.items
        }
    }

    func modelStatus(for option: VoiceboxEngineOption) -> VoiceboxModelStatus? {
        modelStatuses.first { $0.model_name == option.model_name }
    }

    func isOptionDownloaded(_ option: VoiceboxEngineOption) -> Bool {
        if let status = modelStatus(for: option) {
            return status.downloaded
        }
        // Fallback disk cache check if service isn't started yet
        let repoMap: [String: String] = [
            "qwen-tts-1.7B": "mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16",
            "qwen-tts-0.6B": "mlx-community--Qwen3-TTS-12Hz-0.6B-Base-bf16",
            "qwen-custom-voice-1.7B": "mlx-community--Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16",
            "qwen-custom-voice-0.6B": "mlx-community--Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
            "kokoro": "hexgrad--Kokoro-82M",
            "chatterbox-tts": "ResembleAI--chatterbox",
            "chatterbox-turbo": "ResembleAI--chatterbox-turbo",
            "luxtts": "YatharthS--LuxTTS",
            "tada-1b": "HumeAI--tada-1b"
        ]
        guard let folderPrefix = repoMap[option.model_name] else { return false }
        let repoDir = effectiveModelsCacheDir.appendingPathComponent("models--\(folderPrefix)", isDirectory: true)
        let snapshotsDir = repoDir.appendingPathComponent("snapshots", isDirectory: true)
        let blobsDir = repoDir.appendingPathComponent("blobs", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshotsDir.path) else { return false }
        if let blobEntries = try? fm.contentsOfDirectory(atPath: blobsDir.path),
           blobEntries.contains(where: { $0.hasSuffix(".incomplete") }) {
            return false
        }
        if let enumerator = fm.enumerator(at: snapshotsDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ["safetensors", "bin", "pt", "pth", "npz"].contains(ext) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: GPU Memory Protection (Unload Local Models)

    func unloadLocalModels() async {
        guard let url = URL(string: "http://127.0.0.1:\(activePort)/models/unload") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                statusMessage = "已從 GPU／統一記憶體卸載 Voicebox 語音模型。"
                await refreshHealth()
                await refreshModelStatuses()
            }
        } catch {
            lastError = "卸載語音模型失敗：\(error.localizedDescription)"
        }
    }

    // MARK: 3. Previewing Voice Profiles Without Inference

    func stopPreview() {
        previewStopTimer?.invalidate()
        previewStopTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewPlaying = false
        previewingProfileID = nil
    }

    func previewProfile(_ profile: VoiceboxProfile) {
        if isPreviewPlaying && previewingProfileID == profile.id {
            stopPreview()
            return
        }
        stopPreview()
        AudioAIManager.shared.stopAudition()
        lastError = nil
        previewingProfileID = profile.id

        Task { @MainActor in
            let ready = await ensureServiceReady()
            guard ready else {
                previewingProfileID = nil
                return
            }

            let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Klipora/cache/voicebox-previews", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            // Step 1: Check existing samples for this profile
            let samples = await fetchSamples(for: profile.id)
            if let firstSample = samples.first {
                let destURL = cacheDir.appendingPathComponent("sample-\(firstSample.id).wav")
                if FileManager.default.fileExists(atPath: destURL.path),
                   let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value,
                   size > 44 {
                    playPreviewFile(at: destURL, profile: profile, label: "樣本試聽")
                    return
                }
                if let sampleURL = URL(string: "http://127.0.0.1:\(activePort)/samples/\(firstSample.id)"),
                   let (data, resp) = try? await URLSession.shared.data(from: sampleURL),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   data.count > 44 {
                    try? data.write(to: destURL, options: .atomic)
                    playPreviewFile(at: destURL, profile: profile, label: "樣本試聽")
                    return
                }
            }

            // Step 2: Check existing completed history for this profile (e.g. preset voices like Serena)
            var comps = URLComponents(string: "http://127.0.0.1:\(activePort)/history")
            comps?.queryItems = [
                URLQueryItem(name: "profile_id", value: profile.id),
                URLQueryItem(name: "limit", value: "10")
            ]
            if let histURL = comps?.url,
               let (hData, hResp) = try? await URLSession.shared.data(from: histURL),
               (hResp as? HTTPURLResponse)?.statusCode == 200,
               let list = try? JSONDecoder().decode(VoiceboxHistoryListResponse.self, from: hData),
               let completedItem = list.items.first(where: { ($0.status ?? "completed") == "completed" }) {
                let destURL = cacheDir.appendingPathComponent("history-\(completedItem.id).wav")
                if FileManager.default.fileExists(atPath: destURL.path),
                   let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.int64Value,
                   size > 44 {
                    playPreviewFile(at: destURL, profile: profile, label: "歷史音檔試聽")
                    return
                }
                if let exportURL = URL(string: "http://127.0.0.1:\(activePort)/history/\(completedItem.id)/export-audio"),
                   let (audioData, aResp) = try? await URLSession.shared.data(from: exportURL),
                   (aResp as? HTTPURLResponse)?.statusCode == 200,
                   audioData.count > 44 {
                    try? audioData.write(to: destURL, options: .atomic)
                    playPreviewFile(at: destURL, profile: profile, label: "歷史音檔試聽")
                    return
                }
            }

            // Step 3: Neither sample nor completed history exists — never trigger inference!
            previewingProfileID = nil
            isPreviewPlaying = false
            statusMessage = "此聲音尚無現成樣本或歷史音檔可供試聽（不會自動啟動推論）。"
        }
    }

    private func playPreviewFile(at url: URL, profile: VoiceboxProfile, label: String) {
        stopPreview()
        AudioAIManager.shared.stopAudition()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            self.previewPlayer = player
            self.previewingProfileID = profile.id
            self.isPreviewPlaying = true
            self.statusMessage = "正在試聽「\(profile.name)」· \(label)"
            let duration = max(0.5, player.duration + 0.15)
            previewStopTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stopPreview()
                }
            }
        } catch {
            previewingProfileID = nil
            isPreviewPlaying = false
            lastError = "無法播放試聽音檔：\(error.localizedDescription)"
        }
    }

    // MARK: 4. Local Generation Flow & SSE / History Polling

    func generateLocal(
        profile: VoiceboxProfile,
        text: String,
        language: String = "zh",
        engineOption: VoiceboxEngineOption,
        seed: Int? = nil,
        instruct: String? = nil,
        outputRootDir: URL
    ) async throws -> URL {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw VoiceboxIntegrationError.emptyScript
        }

        let compatible = VoiceboxEngineOption.compatibleOptions(for: profile)
        guard compatible.contains(where: { $0.model_name == engineOption.model_name }) else {
            throw VoiceboxIntegrationError.incompatibleEngine(
                "所選引擎「\(engineOption.display_name)」與聲音「\(profile.name)（\(profile.voiceTypeTag)）」不相容。"
            )
        }

        let ready = await ensureServiceReady()
        guard ready else {
            throw VoiceboxIntegrationError.serviceNotReady(lastError ?? "本機 Voicebox 服務尚未就緒。")
        }

        if profile.isCloned {
            _ = await fetchSamples(for: profile.id, forceRefresh: false)
        }

        isGenerating = true
        generationStage = "正在提交本機生成工作..."
        generationProgress = nil
        lastError = nil
        statusMessage = nil

        let task = Task<URL, Error> { @MainActor in
            defer {
                self.isGenerating = false
                self.activeGenerationID = nil
                self.activeGenerationTask = nil
                self.generationStage = ""
                self.generationProgress = nil
            }

            guard let genURL = URL(string: "http://127.0.0.1:\(self.activePort)/generate") else {
                throw VoiceboxIntegrationError.serverError("無效的生成端點網址。")
            }

            var payload: [String: Any] = [
                "profile_id": profile.id,
                "text": trimmedText,
                "language": engineOption.englishOnly ? "en" : language,
                "engine": engineOption.engine,
                "personality": false,
                "normalize": true
            ]
            if let modelSize = engineOption.modelSize, !modelSize.isEmpty {
                payload["model_size"] = modelSize
            }
            if let seed {
                payload["seed"] = seed
            }
            if engineOption.supportsInstruct,
               let instruct = instruct?.trimmingCharacters(in: .whitespacesAndNewlines),
               !instruct.isEmpty {
                payload["instruct"] = instruct
            }

            var req = URLRequest(url: genURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 30.0
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (respData, resp) = try await URLSession.shared.data(for: req)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode != 200 {
                let errDetail = Self.extractErrorDetail(from: respData) ?? "HTTP \(statusCode)"
                throw VoiceboxIntegrationError.serverError("啟動語音生成失敗：\(errDetail)")
            }

            let createdItem = try JSONDecoder().decode(VoiceboxHistoryItem.self, from: respData)
            let genID = createdItem.id
            self.activeGenerationID = genID
            self.generationStage = "載入模型中..."

            // Monitor status via SSE with /history/{id} JSON polling fallback
            let completedItem = try await self.waitForLocalGeneration(id: genID)

            self.generationStage = "正在匯出 WAV 音檔..."
            let finalURL = try await self.exportGenerationAudioToDatedJobs(
                generationID: genID,
                profileName: profile.name,
                durationHint: completedItem.duration,
                outputRootDir: outputRootDir
            )

            await self.refreshHealth()
            await self.refreshModelStatuses()
            await self.refreshRecentHistory()
            return finalURL
        }

        self.activeGenerationTask = task
        return try await task.value
    }

    func waitForLocalGeneration(id: String) async throws -> VoiceboxHistoryItem {
        guard let sseURL = URL(string: "http://127.0.0.1:\(activePort)/generate/\(id)/status") else {
            return try await pollHistoryUntilTerminal(id: id)
        }

        // Launch SSE reader task and fallback history poll concurrently so it never hangs
        var sseReq = URLRequest(url: sseURL)
        sseReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        sseReq.timeoutInterval = 600.0

        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: sseReq)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let dict = Self.parseSSEDataLine(line) else { continue }
                    let status = (dict["status"] as? String) ?? "generating"
                    let errorMsg = dict["error"] as? String
                    let duration = (dict["duration"] as? NSNumber)?.doubleValue

                    if status == "loading_model" {
                        self.generationStage = "載入模型中..."
                    } else if status == "generating" {
                        self.generationStage = "本機神經網路生成中..."
                    } else if status == "completed" {
                        return VoiceboxHistoryItem(
                            id: id,
                            profile_id: "",
                            profile_name: nil,
                            text: "",
                            language: "zh",
                            audio_path: nil,
                            duration: duration,
                            engine: nil,
                            model_size: nil,
                            status: "completed",
                            error: nil,
                            instruct: nil
                        )
                    } else if status == "failed" || status == "not_found" {
                        throw VoiceboxIntegrationError.generationFailed(errorMsg ?? "語音生成失敗（\(status)）。")
                    }
                }
            }
        } catch is CancellationError {
            throw VoiceboxIntegrationError.generationCancelled
        } catch let vbErr as VoiceboxIntegrationError {
            throw vbErr
        } catch {
            // Fall through to history polling if SSE stream disconnects early
        }

        return try await pollHistoryUntilTerminal(id: id)
    }

    private func pollHistoryUntilTerminal(id: String) async throws -> VoiceboxHistoryItem {
        guard let histURL = URL(string: "http://127.0.0.1:\(activePort)/history/\(id)") else {
            throw VoiceboxIntegrationError.serverError("無效的歷史查詢網址")
        }

        for _ in 0..<600 {
            try Task.checkCancellation()
            var req = URLRequest(url: histURL)
            req.timeoutInterval = 8.0
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let item = try? JSONDecoder().decode(VoiceboxHistoryItem.self, from: data) {
                let st = item.status ?? "completed"
                if st == "loading_model" {
                    self.generationStage = "載入模型中..."
                } else if st == "generating" {
                    self.generationStage = "本機神經網路生成中..."
                } else if st == "completed" {
                    return item
                } else if st == "failed" {
                    throw VoiceboxIntegrationError.generationFailed(item.error ?? "語音生成失敗。")
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw VoiceboxIntegrationError.generationFailed("等待語音生成結果逾時。")
    }

    func exportGenerationAudioToDatedJobs(
        generationID: String,
        profileName: String,
        durationHint: Double?,
        outputRootDir: URL
    ) async throws -> URL {
        guard let exportURL = URL(string: "http://127.0.0.1:\(activePort)/history/\(generationID)/export-audio") else {
            throw VoiceboxIntegrationError.invalidAudioExport
        }
        var req = URLRequest(url: exportURL)
        req.timeoutInterval = 30.0
        let (audioBytes, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, audioBytes.count > 44 else {
            throw VoiceboxIntegrationError.invalidAudioExport
        }

        let datedDir = datedDirectory(under: outputRootDir)
        try FileManager.default.createDirectory(at: datedDir, withIntermediateDirectories: true)

        let safeProfile = Self.sanitizeFilenameComponent(profileName)
        let shortID = String(generationID.prefix(8))
        let baseName = "Voicebox-\(safeProfile)-\(shortID)"
        let finalURL = Self.uniqueOutputURL(in: datedDir, baseName: baseName, ext: "wav")

        try audioBytes.write(to: finalURL, options: .atomic)

        let attrs = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard FileManager.default.isReadableFile(atPath: finalURL.path), fileSize > 44 else {
            throw VoiceboxIntegrationError.invalidAudioExport
        }

        var resolvedDuration = durationHint
        if resolvedDuration == nil || (resolvedDuration ?? 0) <= 0 {
            if let player = try? AVAudioPlayer(contentsOf: finalURL) {
                resolvedDuration = player.duration
            }
        }

        self.lastGeneratedWAVPath = finalURL.path
        self.lastGeneratedDuration = resolvedDuration
        self.lastGeneratedProfileName = profileName
        self.statusMessage = "已生成配音：\(finalURL.lastPathComponent)"
        return finalURL
    }

    func cancelActiveGeneration() {
        let localID = activeGenerationID
        let colabID = activeColabJobID
        activeGenerationTask?.cancel()

        Task { @MainActor in
            if let localID {
                if let cancelURL = URL(string: "http://127.0.0.1:\(activePort)/generate/\(localID)/cancel") {
                    var req = URLRequest(url: cancelURL)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 8.0
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
            if let colabID {
                if let cancelURL = URL(string: "http://127.0.0.1:\(activeBridgePort)/colab/jobs/\(colabID)/cancel") {
                    var req = URLRequest(url: cancelURL)
                    req.httpMethod = "POST"
                    req.setValue("127.0.0.1:\(activeBridgePort)", forHTTPHeaderField: "Host")
                    req.setValue(bridgeToken, forHTTPHeaderField: "X-Colab-Token")
                    req.timeoutInterval = 15.0
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
            self.isGenerating = false
            self.activeGenerationID = nil
            self.activeColabJobID = nil
            self.generationStage = ""
            self.generationProgress = nil
            self.statusMessage = "已取消語音生成。"
        }
    }

    // MARK: 5. Colab Long-Form Voicebox Generation (MiniMax H3 · A100)

    private func ensureColabBridgeReady() async throws {
        if let proc = ownedBridgeProcess, proc.isRunning {
            if await isColabBridgeHealthy(onPort: activeBridgePort) {
                return
            }
        }

        guard let bridgeScriptURL = resolveColabBridgeScriptURL() else {
            throw VoiceboxIntegrationError.serverError("找不到內建或已安裝的 colab/bridge.py 腳本。")
        }

        var targetBridgePort = bridgePort
        if Self.isLoopbackPortOccupied(targetBridgePort) {
            targetBridgePort = Self.findAvailableLoopbackPort(startingAt: max(17494, targetBridgePort + 1), maxPort: 17530)
            if targetBridgePort == activePort {
                targetBridgePort = Self.findAvailableLoopbackPort(startingAt: activePort + 1, maxPort: 17535)
            }
        }
        activeBridgePort = targetBridgePort
        bridgeToken = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let fm = FileManager.default
        let colabJobsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/colab-jobs", isDirectory: true)
        let logsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/logs", isDirectory: true)
        try fm.createDirectory(at: colabJobsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let logURL = logsDir.appendingPathComponent("voicebox-colab-bridge.log")
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        try? bridgeLogFileHandle?.close()
        let logHandle = try FileHandle(forWritingTo: logURL)
        _ = try? logHandle.seekToEnd()
        self.bridgeLogFileHandle = logHandle

        let pythonExec: String = {
            for candidate in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return "/usr/bin/python3"
        }()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExec)
        proc.arguments = [
            bridgeScriptURL.path,
            "--data-dir", colabJobsDir.path,
            "--port", String(targetBridgePort),
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
        ]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        var env = ProcessInfo.processInfo.environment
        env["VOICEBOX_LOCAL_API"] = "http://127.0.0.1:\(activePort)"
        env["VOICEBOX_COLAB_TOKEN"] = bridgeToken
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        try proc.run()
        self.ownedBridgeProcess = proc

        for _ in 0..<40 {
            if proc.isRunning {
                let healthy = await isColabBridgeHealthy(onPort: targetBridgePort)
                if healthy {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw VoiceboxIntegrationError.serverError("啟動 Colab 橋接服務（bridge.py）逾時。")
    }

    private func isColabBridgeHealthy(onPort port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/colab/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["ok"] as? Bool) == true else {
            return false
        }
        return true
    }

    func generateColab(
        profile: VoiceboxProfile,
        sampleID: String,
        text: String,
        seed: Int? = nil,
        outputRootDir: URL
    ) async throws -> URL {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw VoiceboxIntegrationError.emptyScript
        }
        guard !sampleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceboxIntegrationError.sampleRequired
        }

        let ready = await ensureServiceReady()
        guard ready else {
            throw VoiceboxIntegrationError.serviceNotReady(lastError ?? "本機 Voicebox 服務尚未就緒。")
        }

        if profile.isCloned {
            _ = await fetchSamples(for: profile.id, forceRefresh: false)
        }

        isGenerating = true
        generationStage = "正在啟動 Colab 橋接服務..."
        generationProgress = 0
        lastError = nil
        statusMessage = nil

        let task = Task<URL, Error> { @MainActor in
            defer {
                self.isGenerating = false
                self.activeColabJobID = nil
                self.activeGenerationTask = nil
                self.generationStage = ""
                self.generationProgress = nil
            }

            try await self.ensureColabBridgeReady()

            guard let jobsURL = URL(string: "http://127.0.0.1:\(self.activeBridgePort)/colab/jobs") else {
                throw VoiceboxIntegrationError.serverError("無效的 Colab 工作端點。")
            }

            var payload: [String: Any] = [
                "profile_id": profile.id,
                "sample_id": sampleID,
                "text": trimmedText,
                "language": "zh"
            ]
            if let seed {
                payload["seed"] = seed
            }

            var req = URLRequest(url: jobsURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("127.0.0.1:\(self.activeBridgePort)", forHTTPHeaderField: "Host")
            req.setValue(self.bridgeToken, forHTTPHeaderField: "X-Colab-Token")
            req.timeoutInterval = 30.0
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (respData, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 202 && code != 200 {
                let detail = Self.extractErrorDetail(from: respData) ?? "HTTP \(code)"
                throw VoiceboxIntegrationError.serverError(detail)
            }

            let createdJob = try JSONDecoder().decode(VoiceboxColabJobResponse.self, from: respData)
            let jobID = createdJob.id
            self.activeColabJobID = jobID
            self.generationStage = createdJob.stage ?? "準備 Colab 工作階段..."
            self.generationProgress = createdJob.progress ?? 2

            guard let pollURL = URL(string: "http://127.0.0.1:\(self.activeBridgePort)/colab/jobs/\(jobID)") else {
                throw VoiceboxIntegrationError.serverError("無效的 Colab 狀態查詢網址。")
            }

            for _ in 0..<2700 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000_000)

                var pollReq = URLRequest(url: pollURL)
                pollReq.setValue("127.0.0.1:\(self.activeBridgePort)", forHTTPHeaderField: "Host")
                pollReq.setValue(self.bridgeToken, forHTTPHeaderField: "X-Colab-Token")
                pollReq.timeoutInterval = 10.0

                guard let (pData, pResp) = try? await URLSession.shared.data(for: pollReq),
                      (pResp as? HTTPURLResponse)?.statusCode == 200,
                      let jobState = try? JSONDecoder().decode(VoiceboxColabJobResponse.self, from: pData) else {
                    continue
                }

                if let stage = jobState.stage, !stage.isEmpty {
                    self.generationStage = stage
                }
                if let prog = jobState.progress {
                    self.generationProgress = prog
                }

                let st = jobState.status ?? "running"
                if st == "completed" {
                    guard let genID = jobState.generation_id, !genID.isEmpty else {
                        throw VoiceboxIntegrationError.generationFailed("Colab 工作完成但未回傳 generation_id。")
                    }
                    let finalURL = try await self.exportGenerationAudioToDatedJobs(
                        generationID: genID,
                        profileName: profile.name,
                        durationHint: jobState.duration,
                        outputRootDir: outputRootDir
                    )
                    await self.refreshRecentHistory()
                    return finalURL
                } else if st == "error" || st == "failed" {
                    throw VoiceboxIntegrationError.generationFailed(jobState.error ?? "Colab 長稿生成失敗。")
                } else if st == "cancelled" {
                    throw VoiceboxIntegrationError.generationCancelled
                }
            }

            throw VoiceboxIntegrationError.generationFailed("Colab 線上長稿生成逾時。")
        }

        self.activeGenerationTask = task
        return try await task.value
    }

    // MARK: 6. Model Download / Cancel / Retry via Official Endpoints

    func startModelDownload(modelName: String) {
        Task { @MainActor in
            let currentHasToken = (Self.readStoredHuggingFaceToken() != nil)
            if ownership == .ownedByMotionDesk && currentHasToken != activeServerHFTokenSet && !isGenerating {
                await restartForPathChange()
            }
            let ready = await ensureServiceReady()
            guard ready else { return }

            guard let url = URL(string: "http://127.0.0.1:\(activePort)/models/download") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model_name": modelName])
            req.timeoutInterval = 15.0

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    activeDownloads[modelName] = VoiceboxActiveDownloadTask(
                        model_name: modelName,
                        status: "downloading",
                        error: nil,
                        progress: 0,
                        current: 0,
                        total: 0,
                        filename: "正在連線至 HuggingFace..."
                    )
                    statusMessage = "已開始下載模型：\(modelName)"
                    startPollingDownloadTasksIfNeeded()
                } else {
                    let detail = Self.extractErrorDetail(from: data) ?? "HTTP \(code)"
                    lastError = "無法啟動模型下載：\(detail)"
                }
            } catch {
                lastError = "啟動模型下載失敗：\(error.localizedDescription)"
            }
        }
    }

    func cancelModelDownload(modelName: String) {
        Task { @MainActor in
            guard let url = URL(string: "http://127.0.0.1:\(activePort)/models/download/cancel") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model_name": modelName])
            req.timeoutInterval = 10.0

            _ = try? await URLSession.shared.data(for: req)
            activeDownloads.removeValue(forKey: modelName)
            statusMessage = "已取消下載模型：\(modelName)"
            await refreshModelStatuses()
        }
    }

    private func startPollingDownloadTasksIfNeeded() {
        guard downloadPollTask == nil else { return }
        downloadPollTask = Task { @MainActor in
            defer { self.downloadPollTask = nil }
            while !Task.isCancelled {
                guard let url = URL(string: "http://127.0.0.1:\(self.activePort)/tasks/active") else { break }
                var req = URLRequest(url: url)
                req.timeoutInterval = 6.0
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   let activeResp = try? JSONDecoder().decode(VoiceboxActiveTasksResponse.self, from: data) {
                    var nextMap: [String: VoiceboxActiveDownloadTask] = [:]
                    for dl in activeResp.downloads {
                        if dl.status == "error", let err = dl.error {
                            self.lastError = "模型 \(dl.model_name) 下載失敗：\(err)"
                        } else {
                            nextMap[dl.model_name] = dl
                        }
                    }
                    self.activeDownloads = nextMap
                    await self.refreshModelStatuses()
                    if nextMap.isEmpty {
                        break
                    }
                } else {
                    await self.refreshModelStatuses()
                    if self.activeDownloads.isEmpty {
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    private static func extractErrorDetail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = obj["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let err = obj["error"] as? String, !err.isEmpty {
            return err
        }
        if let msg = obj["message"] as? String, !msg.isEmpty {
            return msg
        }
        return nil
    }
}

// MARK: - 7. Shared Per-Project Native Voice Workspace Store & Native UI (12-14pt Readable Workbench)

struct NativeVoiceProjectDraftSnapshot: Codable, Equatable {
    var selectedProfileID: String
    var profileSearchQuery: String
    var modeRaw: String
    var selectedEngineModelName: String
    var selectedSampleID: String
    var scriptText: String
    var instructText: String
    var seedText: String
}

@MainActor
final class NativeVoiceWorkspaceStore: ObservableObject {
    static let shared = NativeVoiceWorkspaceStore()

    private static let selectedProfileKey = "MotionDesk.nativeVoice.selectedProfileID"
    private static let profileSearchKey = "MotionDesk.nativeVoice.profileSearchQuery"
    private static let modeKey = "MotionDesk.nativeVoice.mode"
    private static let engineModelKey = "MotionDesk.nativeVoice.selectedEngineModelName"
    private static let sampleIDKey = "MotionDesk.nativeVoice.selectedSampleID"
    private static let scriptTextKey = "MotionDesk.nativeVoice.scriptText"
    private static let instructTextKey = "MotionDesk.nativeVoice.instructText"
    private static let seedTextKey = "MotionDesk.nativeVoice.seedText"
    private static let autoInsertKey = "MotionDesk.nativeVoice.autoInsertToTrack"
    private static let projectDraftsKey = "MotionDesk.nativeVoice.perProjectDrafts"

    static let defaultWelcomeScript = "你好，歡迎來到 Klipora 語音工作室，讓我們一起把想法變成聲音。"

    private var activeProjectScopeKey: String = "__untitled_session__"
    private var isRestoringProjectScope: Bool = false
    private var perProjectSnapshots: [String: NativeVoiceProjectDraftSnapshot] = [:]

    @Published var selectedProfileID: String {
        didSet {
            UserDefaults.standard.set(selectedProfileID, forKey: Self.selectedProfileKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var profileSearchQuery: String {
        didSet {
            UserDefaults.standard.set(profileSearchQuery, forKey: Self.profileSearchKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var mode: VoiceboxGenerationMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var selectedEngineModelName: String {
        didSet {
            UserDefaults.standard.set(selectedEngineModelName, forKey: Self.engineModelKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var selectedSampleID: String {
        didSet {
            UserDefaults.standard.set(selectedSampleID, forKey: Self.sampleIDKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var scriptText: String {
        didSet {
            UserDefaults.standard.set(scriptText, forKey: Self.scriptTextKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var instructText: String {
        didSet {
            UserDefaults.standard.set(instructText, forKey: Self.instructTextKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var seedText: String {
        didSet {
            UserDefaults.standard.set(seedText, forKey: Self.seedTextKey)
            persistCurrentProjectSnapshot()
        }
    }

    @Published var autoInsertToTrack: Bool {
        didSet {
            UserDefaults.standard.set(autoInsertToTrack, forKey: Self.autoInsertKey)
        }
    }

    @Published var showEngineDetails: Bool = false
    @Published var showCentralVoiceWorkspace: Bool = true
    @Published var editingSampleReferenceText: String = ""
    @Published var editingSampleID: String = ""
    @Published var editingSampleIsDerivedOverride: Bool = false
    @Published var isSavingSampleReferenceText: Bool = false

    init() {
        let defaults = UserDefaults.standard
        if let rawData = defaults.data(forKey: Self.projectDraftsKey),
           let decoded = try? JSONDecoder().decode([String: NativeVoiceProjectDraftSnapshot].self, from: rawData) {
            self.perProjectSnapshots = decoded
        }
        self.selectedProfileID = defaults.string(forKey: Self.selectedProfileKey) ?? ""
        self.profileSearchQuery = defaults.string(forKey: Self.profileSearchKey) ?? ""
        if let rawMode = defaults.string(forKey: Self.modeKey),
           let parsedMode = VoiceboxGenerationMode(rawValue: rawMode) {
            self.mode = parsedMode
        } else {
            self.mode = .local
        }
        let savedEngine = defaults.string(forKey: Self.engineModelKey) ?? "qwen-tts-1.7B"
        self.selectedEngineModelName = savedEngine.isEmpty ? "qwen-tts-1.7B" : savedEngine
        self.selectedSampleID = defaults.string(forKey: Self.sampleIDKey) ?? ""
        if let savedScript = defaults.object(forKey: Self.scriptTextKey) as? String {
            self.scriptText = savedScript
        } else {
            self.scriptText = Self.defaultWelcomeScript
        }
        self.instructText = defaults.string(forKey: Self.instructTextKey) ?? ""
        self.seedText = defaults.string(forKey: Self.seedTextKey) ?? ""
        if defaults.object(forKey: Self.autoInsertKey) != nil {
            self.autoInsertToTrack = defaults.bool(forKey: Self.autoInsertKey)
        } else {
            self.autoInsertToTrack = true
        }
    }

    /// Called when the user saves the current project (First-time Save from untitled or Save As to a target URL).
    /// Copies the active draft snapshot to `targetURL` and switches `activeProjectScopeKey` to `targetURL`
    /// so the user's edited script, voice role, mode, and parameters are 100% preserved across subsequent tab/workspace switches.
    func migrateProjectScopeOnSave(to targetURL: URL) {
        persistCurrentProjectSnapshot()
        let targetKey = targetURL.standardizedFileURL.path
        let currentSnap = perProjectSnapshots[activeProjectScopeKey] ?? NativeVoiceProjectDraftSnapshot(
            selectedProfileID: selectedProfileID,
            profileSearchQuery: profileSearchQuery,
            modeRaw: mode.rawValue,
            selectedEngineModelName: selectedEngineModelName,
            selectedSampleID: selectedSampleID,
            scriptText: scriptText,
            instructText: instructText,
            seedText: seedText
        )
        perProjectSnapshots[targetKey] = currentSnap
        activeProjectScopeKey = targetKey
        if let encoded = try? JSONEncoder().encode(perProjectSnapshots) {
            UserDefaults.standard.set(encoded, forKey: Self.projectDraftsKey)
        }
    }

    /// Called when the user explicitly opens a project file from disk (`Studio.openProject(at:)`).
    /// Saves the previous project's snapshot under its own key, switches to `openedURL`'s scope,
    /// and loads `openedURL`'s saved snapshot (or resets to `defaultWelcomeScript` if `openedURL` had no prior voice draft).
    func switchProjectScopeOnOpen(to openedURL: URL) {
        persistCurrentProjectSnapshot()
        let newKey = openedURL.standardizedFileURL.path
        activeProjectScopeKey = newKey
        isRestoringProjectScope = true
        defer { isRestoringProjectScope = false }

        if let saved = perProjectSnapshots[newKey] {
            self.selectedProfileID = saved.selectedProfileID
            self.profileSearchQuery = saved.profileSearchQuery
            if let m = VoiceboxGenerationMode(rawValue: saved.modeRaw) {
                self.mode = m
            }
            if !saved.selectedEngineModelName.isEmpty {
                self.selectedEngineModelName = saved.selectedEngineModelName
            }
            self.selectedSampleID = saved.selectedSampleID
            self.scriptText = saved.scriptText
            self.instructText = saved.instructText
            self.seedText = saved.seedText
        } else {
            self.scriptText = Self.defaultWelcomeScript
            self.instructText = ""
            self.seedText = ""
        }
        let snap = NativeVoiceProjectDraftSnapshot(
            selectedProfileID: selectedProfileID,
            profileSearchQuery: profileSearchQuery,
            modeRaw: mode.rawValue,
            selectedEngineModelName: selectedEngineModelName,
            selectedSampleID: selectedSampleID,
            scriptText: scriptText,
            instructText: instructText,
            seedText: seedText
        )
        perProjectSnapshots[newKey] = snap
        if let encoded = try? JSONEncoder().encode(perProjectSnapshots) {
            UserDefaults.standard.set(encoded, forKey: Self.projectDraftsKey)
        }
    }

    /// Synchronizes draft state with a project scope so tool/workspace tab switches and first-time saves preserve drafts 100%,
    /// while opening a different saved project does not blindly overwrite or get polluted by another project's draft.
    func bindProjectScope(projectURL: URL?, projectRevision: Int) {
        let newKey = projectURL?.standardizedFileURL.path ?? "__untitled_session__"
        guard newKey != activeProjectScopeKey else { return }
        let oldKey = activeProjectScopeKey
        persistCurrentProjectSnapshot()
        activeProjectScopeKey = newKey
        isRestoringProjectScope = true
        defer { isRestoringProjectScope = false }

        if let saved = perProjectSnapshots[newKey] {
            self.selectedProfileID = saved.selectedProfileID
            self.profileSearchQuery = saved.profileSearchQuery
            if let m = VoiceboxGenerationMode(rawValue: saved.modeRaw) {
                self.mode = m
            }
            if !saved.selectedEngineModelName.isEmpty {
                self.selectedEngineModelName = saved.selectedEngineModelName
            }
            self.selectedSampleID = saved.selectedSampleID
            self.scriptText = saved.scriptText
            self.instructText = saved.instructText
            self.seedText = saved.seedText
        } else if oldKey == "__untitled_session__", let migrated = perProjectSnapshots[oldKey] {
            // Untitled session was just saved to a new projectURL: migrate the untitled session's draft to the saved project scope!
            perProjectSnapshots[newKey] = migrated
            if let encoded = try? JSONEncoder().encode(perProjectSnapshots) {
                UserDefaults.standard.set(encoded, forKey: Self.projectDraftsKey)
            }
        } else if projectURL != nil {
            // Freshly opened saved project that had no prior voice draft: keep clean default script without overwriting project data
            self.scriptText = Self.defaultWelcomeScript
            self.instructText = ""
            self.seedText = ""
            let snap = NativeVoiceProjectDraftSnapshot(
                selectedProfileID: selectedProfileID,
                profileSearchQuery: profileSearchQuery,
                modeRaw: mode.rawValue,
                selectedEngineModelName: selectedEngineModelName,
                selectedSampleID: selectedSampleID,
                scriptText: scriptText,
                instructText: instructText,
                seedText: seedText
            )
            perProjectSnapshots[newKey] = snap
            if let encoded = try? JSONEncoder().encode(perProjectSnapshots) {
                UserDefaults.standard.set(encoded, forKey: Self.projectDraftsKey)
            }
        }
    }

    private func persistCurrentProjectSnapshot() {
        guard !isRestoringProjectScope else { return }
        let snap = NativeVoiceProjectDraftSnapshot(
            selectedProfileID: selectedProfileID,
            profileSearchQuery: profileSearchQuery,
            modeRaw: mode.rawValue,
            selectedEngineModelName: selectedEngineModelName,
            selectedSampleID: selectedSampleID,
            scriptText: scriptText,
            instructText: instructText,
            seedText: seedText
        )
        perProjectSnapshots[activeProjectScopeKey] = snap
        if let encoded = try? JSONEncoder().encode(perProjectSnapshots) {
            UserDefaults.standard.set(encoded, forKey: Self.projectDraftsKey)
        }
    }

    static func resolvePreferredDefaultProfile(in profiles: [VoiceboxProfile]) -> VoiceboxProfile? {
        if let yuhan = profiles.first(where: { $0.name == "渝函" }) {
            return yuhan
        }
        return profiles.first
    }
}

struct VoiceboxStudioSectionView: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    var searchQuery: String = ""
    var isCentralLayout: Bool = false
    var onOpenComponentSettings: (() -> Void)? = nil

    @ObservedObject private var controller = VoiceboxServiceController.shared
    @ObservedObject private var audioAI = AudioAIManager.shared
    @ObservedObject private var store = NativeVoiceWorkspaceStore.shared

    private var selectedProfile: VoiceboxProfile? {
        if !store.selectedProfileID.isEmpty,
           let match = controller.profiles.first(where: { $0.id == store.selectedProfileID }) {
            return match
        }
        return NativeVoiceWorkspaceStore.resolvePreferredDefaultProfile(in: controller.profiles)
    }

    private var effectiveProfileFilterQuery: String {
        let localQ = store.profileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localQ.isEmpty { return localQ }
        return searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredProfiles: [VoiceboxProfile] {
        VoiceboxServiceController.filterProfiles(
            controller.profiles,
            query: effectiveProfileFilterQuery,
            preservingSelectedID: nil
        )
    }

    private var compatibleEngines: [VoiceboxEngineOption] {
        guard let profile = selectedProfile else {
            return VoiceboxEngineOption.allOptions.filter { $0.supportsClonedVoices }
        }
        return VoiceboxEngineOption.compatibleOptions(for: profile)
    }

    private var selectedEngineOption: VoiceboxEngineOption {
        if let match = compatibleEngines.first(where: { $0.model_name == store.selectedEngineModelName }) {
            return match
        }
        if let profile = selectedProfile {
            return VoiceboxEngineOption.preferredDefault(for: profile)
        }
        return compatibleEngines.first ?? VoiceboxEngineOption.allOptions[0]
    }

    private var samplesForSelectedProfile: [VoiceboxSample] {
        guard let profile = selectedProfile else { return [] }
        return controller.samplesByProfileID[profile.id] ?? []
    }

    private var activeSelectedSample: VoiceboxSample? {
        let samples = samplesForSelectedProfile
        if let matched = samples.first(where: { $0.id == store.selectedSampleID }) {
            return matched
        }
        return samples.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            VStack(alignment: .leading, spacing: 10) {
                if controller.ownership == .starting || controller.ownership == .failed {
                    compactTransientStatusRow
                }

                if app.engineRunning && store.mode == .local && (isCentralLayout || !store.showCentralVoiceWorkspace) {
                    comfyUIMemoryCoordinationNotice
                }

                // When the spacious central voice workspace is active, the narrow left sidebar
                // acts exclusively as a clean 12-13pt Voice Role Picker (zero duplicate script/generate forms
                // and zero duplicate onAppear/onChange callbacks). In the central workspace itself, we only
                // render the active selected voice summary bar + script editor + model/generate controls
                // (without duplicating the 68-row profile list!).
                if isCentralLayout {
                    centralSelectedVoiceHeaderBar
                } else {
                    profileSelectorSection
                }

                if !isCentralLayout && store.showCentralVoiceWorkspace {
                    sidebarCentralWorkspaceActiveHint
                } else {
                    modeAndEngineSection

                    scriptEditorSection

                    actionBarSection

                    if let lastWAV = controller.lastGeneratedWAVPath,
                       FileManager.default.fileExists(atPath: lastWAV) {
                        lastGeneratedOutputCard(path: lastWAV)
                    }

                    if let msg = controller.statusMessage {
                        Text(msg)
                            .font(.system(size: 11.5))
                            .foregroundStyle(vbEmerald)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let err = controller.lastError {
                        Text(err)
                            .font(.system(size: 11.5))
                            .foregroundStyle(vbRose)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    engineAndSampleDetailsDisclosure
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface.opacity(0.60), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.08)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !isCentralLayout else { return }
            store.bindProjectScope(projectURL: app.projectURL, projectRevision: app.projectRevision)
            Task { @MainActor in
                let ready = await controller.ensureServiceReady()
                if ready {
                    syncSelectedProfileAndEngine()
                }
            }
        }
        .onChange(of: app.projectRevision) { _, newRev in
            guard !isCentralLayout else { return }
            store.bindProjectScope(projectURL: app.projectURL, projectRevision: newRev)
        }
        .onChange(of: app.projectURL) { _, newURL in
            guard !isCentralLayout else { return }
            store.bindProjectScope(projectURL: newURL, projectRevision: app.projectRevision)
        }
        .onChange(of: controller.profiles) { _, _ in
            guard !isCentralLayout else { return }
            syncSelectedProfileAndEngine()
        }
    }

    private var sidebarCentralWorkspaceActiveHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.right.square.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(vbCyan)
                Text("配音稿件與生成操作於中央工作區")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("於上方點選角色與試聽，並在中央寬敞工作區編輯稿件與生成入軌。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(vbCyan.opacity(0.28)))
    }

    private var centralSelectedVoiceHeaderBar: some View {
        Group {
            if let profile = selectedProfile {
                let isPlayingThis = controller.isPreviewPlaying && controller.previewingProfileID == profile.id
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(vbCyan)

                        // Role name is ALWAYS displayed first with high layout priority so it is never pushed out by prefixes!
                        Text(profile.name)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(2)

                        Text(profile.voiceTypeTag)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(profile.isPreset ? vbAmber : vbCyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((profile.isPreset ? vbAmber : vbCyan).opacity(0.16), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)

                        Text("目前配音")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)

                        Spacer(minLength: 4)

                        Button {
                            controller.previewProfile(profile)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isPlayingThis ? "stop.circle.fill" : "play.circle.fill")
                                Text(isPlayingThis ? "停止" : "試聽樣本")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(isPlayingThis ? vbAmber : vbCyan)
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(isPlayingThis ? "停止試聽目前角色 \(profile.name)" : "試聽目前角色 \(profile.name)")
                    }

                    Text("\(profileSubtitle(profile)) · 可從左欄角色清單搜尋與切換 \(controller.profiles.count) 位角色")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbCyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(vbCyan.opacity(0.42), lineWidth: 1))
            }
        }
    }

    // MARK: Native Header & Transient Status (13-14pt Readable Typography)

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(vbCyan)
            Text("AI 旁白配音")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)

            if controller.ownership == .ownedByMotionDesk || controller.ownership == .externalReused {
                Circle()
                    .fill(vbEmerald)
                    .frame(width: 7, height: 7)
                    .help("本機語音引擎已就緒")
            }

            if !isCentralLayout {
                Button {
                    store.showCentralVoiceWorkspace.toggle()
                } label: {
                    Image(systemName: store.showCentralVoiceWorkspace ? "rectangle.inset.filled" : "rectangle.expand.vertical")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.showCentralVoiceWorkspace ? vbCyan : .secondary)
                .accessibilityLabel(store.showCentralVoiceWorkspace ? "切換回中央影片預覽" : "於中央展開大型配音工作台")
                .help(store.showCentralVoiceWorkspace ? "切換中央區為畫面預覽" : "於中央展開寬敞配音工作台")
            }

            Button {
                store.showEngineDetails.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.showEngineDetails ? vbCyan : .secondary)
            .accessibilityLabel("切換配音引擎與樣本進階設定")
            .help("檢視參考音訊逐字稿、引擎記憶體與聲音庫路徑")

            if let onOpenComponentSettings {
                Button {
                    onOpenComponentSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("開啟元件與連線設定")
                .help("開啟元件與連線設定")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactTransientStatusRow: some View {
        HStack(spacing: 6) {
            if controller.ownership == .starting {
                ProgressView().controlSize(.small)
                Text("正在準備本機語音引擎…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(vbAmber)
                    .lineLimit(1)
            } else {
                Circle()
                    .fill(vbRose)
                    .frame(width: 7, height: 7)
                Text("語音引擎尚未就緒")
                    .font(.system(size: 11.5))
                    .foregroundStyle(vbRose)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Task { @MainActor in
                    let ok = await controller.ensureServiceReady()
                    if ok {
                        await controller.refreshCatalogData()
                        syncSelectedProfileAndEngine()
                    }
                }
            } label: {
                Text("重試")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .controlSize(.small)
            .disabled(controller.ownership == .starting)
            .accessibilityLabel("重試啟動語音引擎")
            .help("重新連線或啟動本機語音引擎")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 5))
    }

    private var comfyUIMemoryCoordinationNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(vbAmber)
                Text("ComfyUI 執行中，建議先停止以釋放統一記憶體")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("停止 ComfyUI 釋放記憶體") {
                app.stopEngine()
            }
            .controlSize(.small)
            .disabled(app.busy)
            .accessibilityLabel("停止 ComfyUI 釋放記憶體")
            .help("停止閒置的本機 ComfyUI 服務以保護語音推論記憶體")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(vbAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(vbAmber.opacity(0.35)))
    }

    // MARK: Voice Profiles Selector & Preview (Bounded + Searchable + 12-13pt Typography)

    private var profileSelectorSection: some View {
        let displayedProfiles = filteredProfiles
        return VStack(alignment: .leading, spacing: 7) {
            // 1. Pinned Selected Voice Summary Bar (always visible even when searching or scrolling 68+ voices)
            if let profile = selectedProfile {
                let isPlayingThis = controller.isPreviewPlaying && controller.previewingProfileID == profile.id
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(vbCyan)
                        Text(profile.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(profile.voiceTypeTag)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(profile.isPreset ? vbAmber : vbCyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background((profile.isPreset ? vbAmber : vbCyan).opacity(0.16), in: Capsule())
                        Spacer(minLength: 2)
                        Button {
                            controller.previewProfile(profile)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isPlayingThis ? "stop.circle.fill" : "play.circle.fill")
                                Text(isPlayingThis ? "停止" : "試聽")
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(isPlayingThis ? vbAmber : vbCyan)
                        .controlSize(.small)
                        .accessibilityLabel(isPlayingThis ? "停止試聽目前角色 \(profile.name)" : "試聽目前角色 \(profile.name)")
                        .help("試聽「\(profile.name)」的現有樣本或歷史音檔（不觸發推論）")
                    }
                    Text(profileSubtitle(profile))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbCyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(vbCyan.opacity(0.42), lineWidth: 1))
            }

            // 2. Voice Search Field & Count Header
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextField("搜尋角色（如：渝函、麗珠）", text: $store.profileSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(minWidth: 36, maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("搜尋配音角色")
                    if !store.profileSearchQuery.isEmpty {
                        Button {
                            store.profileSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除角色搜尋")
                        .help("清除角色搜尋字詞")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))

                Text("\(displayedProfiles.count)/\(controller.profiles.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 3. Bounded Independently Scrollable Single-Column Voice List (12.5pt names, maxHeight 146pt)
            if controller.profiles.isEmpty {
                Text(controller.ownership == .starting ? "正在載入聲音角色…" : "尚無聲音角色，可於下方設定切換聲音庫資料夾。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else if displayedProfiles.isEmpty {
                Text("無符合「\(effectiveProfileFilterQuery)」的角色（仍保留：\(selectedProfile?.name ?? "無")）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(vbAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(displayedProfiles) { profile in
                            let isSelected = selectedProfile?.id == profile.id
                            let isPreviewing = controller.isPreviewPlaying && controller.previewingProfileID == profile.id
                            HStack(spacing: 6) {
                                Button {
                                    selectProfile(profile)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 12))
                                            .foregroundStyle(isSelected ? vbCyan : .secondary)
                                        Text(profile.name)
                                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        if profile.isPreset {
                                            Text("內建")
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundStyle(vbAmber)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(vbAmber.opacity(0.16), in: Capsule())
                                        }
                                        Spacer(minLength: 2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("選擇配音角色 \(profile.name)")

                                Button {
                                    controller.previewProfile(profile)
                                } label: {
                                    Image(systemName: isPreviewing ? "stop.circle.fill" : "speaker.wave.2.circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(isPreviewing ? vbAmber : vbCyan.opacity(0.92))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isPreviewing ? "停止試聽 \(profile.name)" : "試聽 \(profile.name) 樣本")
                                .help("試聽「\(profile.name)」樣本（不觸發推論）")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isSelected ? vbCyan.opacity(0.20) : vbDarkWell, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(isSelected ? vbCyan : .white.opacity(0.07), lineWidth: isSelected ? 1.1 : 0.6)
                            )
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 104, maxHeight: isCentralLayout ? 200 : 144)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbDarkWell.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileSubtitle(_ profile: VoiceboxProfile) -> String {
        if profile.isPreset {
            return "內建音色 · \(profile.preset_voice_id ?? profile.preset_engine ?? "Built-in")"
        }
        let sCount = profile.sample_count ?? controller.samplesByProfileID[profile.id]?.count ?? 0
        if let desc = profile.description, !desc.isEmpty {
            return "\(sCount) 樣本 · \(desc)"
        }
        return "\(sCount) 個參考樣本 · \(profile.language)"
    }

    private func selectProfile(_ profile: VoiceboxProfile) {
        store.selectedProfileID = profile.id
        let preferred = VoiceboxEngineOption.preferredDefault(for: profile)
        let compat = VoiceboxEngineOption.compatibleOptions(for: profile)
        if !compat.contains(where: { $0.model_name == store.selectedEngineModelName }) {
            store.selectedEngineModelName = preferred.model_name
        }
        if profile.isPreset && store.mode == .colab {
            store.mode = .local
        }
        Task { @MainActor in
            let samples = await controller.fetchSamples(for: profile.id)
            if let first = samples.first {
                store.selectedSampleID = first.id
                let resolved = await controller.effectiveReferenceText(for: first)
                store.editingSampleID = first.id
                store.editingSampleReferenceText = resolved.text
                store.editingSampleIsDerivedOverride = resolved.isDerivedOverride
            } else {
                store.selectedSampleID = ""
                store.editingSampleID = ""
                store.editingSampleReferenceText = ""
                store.editingSampleIsDerivedOverride = false
            }
        }
    }

    private func syncSelectedProfileAndEngine() {
        guard !controller.profiles.isEmpty else { return }
        if let current = selectedProfile {
            if store.selectedProfileID != current.id {
                store.selectedProfileID = current.id
            }
            let compat = VoiceboxEngineOption.compatibleOptions(for: current)
            if !compat.contains(where: { $0.model_name == store.selectedEngineModelName }) {
                store.selectedEngineModelName = VoiceboxEngineOption.preferredDefault(for: current).model_name
            }
            Task { @MainActor in
                let samples = await controller.fetchSamples(for: current.id)
                if store.selectedSampleID.isEmpty || !samples.contains(where: { $0.id == store.selectedSampleID }) {
                    store.selectedSampleID = samples.first?.id ?? ""
                }
                if let sample = samples.first(where: { $0.id == store.selectedSampleID }) ?? samples.first {
                    if store.editingSampleID != sample.id {
                        let resolved = await controller.effectiveReferenceText(for: sample)
                        store.editingSampleID = sample.id
                        store.editingSampleReferenceText = resolved.text
                        store.editingSampleIsDerivedOverride = resolved.isDerivedOverride
                    }
                }
            }
        }
    }

    // MARK: Mode & Engine Section (Narrow-Safe Pill Toggle + Custom Menu Button that never expands VStack width)

    private var modeAndEngineSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                modePillButton(title: "本機生成", icon: "cpu", targetMode: .local, accent: vbCyan)
                modePillButton(title: "雲端長稿", icon: "cloud.bolt", targetMode: .colab, accent: vbViolet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.mode == .local {
                localEngineControls
            } else {
                colabEngineControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modePillButton(
        title: String,
        icon: String,
        targetMode: VoiceboxGenerationMode,
        accent: Color
    ) -> some View {
        let active = store.mode == targetMode
        return Button {
            store.mode = targetMode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? canvas : .white.opacity(0.92))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(active ? accent : vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? accent : .white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切換至\(title)模式")
    }

    private var localEngineControls: some View {
        let option = selectedEngineOption
        let status = controller.modelStatus(for: option)
        let downloaded = controller.isOptionDownloaded(option)
        let activeDL = controller.activeDownloads[option.model_name]
        let isDownloading = (status?.downloading == true) || (activeDL != nil)

        return VStack(alignment: .leading, spacing: 7) {
            // Custom Menu button instead of NSPopUpButton Picker so long model names NEVER inflate VStack intrinsic width!
            Menu {
                ForEach(compatibleEngines) { opt in
                    Button {
                        store.selectedEngineModelName = opt.modelName
                    } label: {
                        HStack {
                            Text(opt.displayName)
                            if opt.modelName == option.modelName {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11.5))
                        .foregroundStyle(vbCyan)
                    Text(option.compactDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("選擇相容配音模型，目前為 \(option.compactDisplayName)")

            // Model Download Status Badge & Explicit Download/Cancel Action
            if !downloaded || isDownloading {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isDownloading ? vbCyan : vbAmber)
                        .frame(width: 7, height: 7)

                    if isDownloading {
                        let progText: String = {
                            if let p = activeDL?.progress, p > 0 {
                                return String(format: "下載中 %.0f%%", p)
                            }
                            return "正在下載模型…"
                        }()
                        Text(progText)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(vbCyan)
                            .lineLimit(1)
                    } else {
                        Text("模型尚未下載")
                            .font(.system(size: 11.5))
                            .foregroundStyle(vbAmber)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if isDownloading {
                        Button("取消") {
                            controller.cancelModelDownload(modelName: option.model_name)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("取消下載模型")
                    } else {
                        Button {
                            controller.startModelDownload(modelName: option.model_name)
                        } label: {
                            Label("下載模型", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(vbCyan)
                        .controlSize(.small)
                        .accessibilityLabel("下載所選語音模型")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 5))
            }

            if let caveat = option.caveat, !caveat.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(vbAmber)
                    Text(caveat)
                        .font(.system(size: 11))
                        .foregroundStyle(vbAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if option.supportsInstruct {
                TextField("語氣指示（選填，如：溫和沉穩旁白）", text: $store.instructText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("語氣與風格指示")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colabEngineControls: some View {
        let samples = samplesForSelectedProfile
        let currentSample = activeSelectedSample
        return VStack(alignment: .leading, spacing: 7) {
            if let profile = selectedProfile, profile.isPreset {
                Text("內建預設聲音不含參考樣本，請改選參考音訊角色或切換回本機生成。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(vbAmber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if samples.isEmpty {
                Text("此角色尚無參考樣本")
                    .font(.system(size: 11.5))
                    .foregroundStyle(vbAmber)
            } else {
                Menu {
                    ForEach(samples) { sample in
                        Button {
                            store.selectedSampleID = sample.id
                        } label: {
                            let label = sample.reference_text.isEmpty ? sample.id : String(sample.reference_text.prefix(28))
                            Text(label)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11.5))
                            .foregroundStyle(vbViolet)
                        let activeLabel = currentSample.map {
                            $0.reference_text.isEmpty ? $0.id : String($0.reference_text.prefix(20))
                        } ?? "選擇參考聲音樣本"
                        Text("樣本：\(activeLabel)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("選擇參考聲音樣本")
            }

            Text("使用 Colab A100 與 MiniMax H3 自動依標點分段生成並合併 WAV，完成後自動停止雲端工作階段。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Script Editor & Adaptive Action Bar (12-13.5pt Readable Controls)

    private var scriptEditorSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("旁白稿件")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer(minLength: 2)
                Text("\(store.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).count) 字")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $store.scriptText)
                .font(.system(size: 13))
                .frame(minHeight: isCentralLayout ? 110 : 72, maxHeight: isCentralLayout ? 180 : 96)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
                .accessibilityLabel("旁白稿件輸入框")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isGenerating {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(controller.generationStage.isEmpty ? "正在生成配音…" : controller.generationStage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(vbCyan)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2)
                        Button(role: .destructive) {
                            controller.cancelActiveGeneration()
                        } label: {
                            Text("取消")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .controlSize(.small)
                        .accessibilityLabel("取消生成配音")
                    }

                    if let prog = controller.generationProgress {
                        ProgressView(value: min(100, max(0, prog)), total: 100)
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    primaryGenerateAndInsertButton
                    secondaryGenerateOnlyButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryGenerateAndInsertButton: some View {
        Button {
            triggerGeneration(insertToTrack: true)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 12.5))
                Text("生成配音並加入音訊軌")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .tint(store.mode == .local ? vbCyan : vbViolet)
        .controlSize(.regular)
        .disabled(!canStartGeneration)
        .accessibilityLabel("生成配音並加入音訊軌")
        .help("生成配音 WAV 並直接插入目前時間軸播放頭所在的 A 音訊軌")
    }

    private var secondaryGenerateOnlyButton: some View {
        Button {
            triggerGeneration(insertToTrack: false)
        } label: {
            Text("僅生成配音檔案")
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canStartGeneration)
        .accessibilityLabel("僅生成配音")
        .help("僅生成配音 WAV 檔案並存入今日輸出資料夾，不自動插入時間軸")
    }

    private var canStartGeneration: Bool {
        guard !app.busy,
              !controller.isGenerating,
              let profile = selectedProfile,
              !store.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if store.mode == .colab {
            return !profile.isPreset && !store.selectedSampleID.isEmpty
        }
        return true
    }

    private func triggerGeneration(insertToTrack: Bool) {
        guard let profile = selectedProfile else { return }
        let script = store.scriptText
        let playhead = playback.playhead
        let outputRoot = app.audioOutputDirectory
        let seedVal = Int(store.seedText.trimmingCharacters(in: .whitespacesAndNewlines))

        Task { @MainActor in
            do {
                let finalURL: URL
                if store.mode == .local {
                    finalURL = try await controller.generateLocal(
                        profile: profile,
                        text: script,
                        language: "zh",
                        engineOption: selectedEngineOption,
                        seed: seedVal,
                        instruct: store.instructText,
                        outputRootDir: outputRoot
                    )
                } else {
                    finalURL = try await controller.generateColab(
                        profile: profile,
                        sampleID: store.selectedSampleID,
                        text: script,
                        seed: seedVal,
                        outputRootDir: outputRoot
                    )
                }

                if insertToTrack {
                    if let sel = app.addGeneratedAudioToTrack(
                        path: finalURL.path,
                        at: playhead,
                        preferredTrackName: "A 配音 · \(profile.name)"
                    ) {
                        state.selection = sel
                        state.previewMode = .timeline
                        playback.syncLayout(app.currentMultitrackLayout())
                        app.status = "已生成配音並加入音訊軌 · \(finalURL.lastPathComponent)"
                    }
                } else {
                    app.status = "已生成配音 · \(finalURL.lastPathComponent)"
                }
            } catch {
                controller.lastError = error.localizedDescription
                app.status = "配音生成失敗：\(error.localizedDescription)"
            }
        }
    }

    // MARK: Last Generated Output Card (12pt Readable & Narrow-Safe)

    private func lastGeneratedOutputCard(path: String) -> some View {
        let isAuditioningThis = audioAI.isPlayingAudition && audioAI.auditioningEffectID == "voicebox_last_output"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(vbEmerald)
                Text(filename(path))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                if let dur = controller.lastGeneratedDuration, dur > 0 {
                    Text(String(format: "%.1fs", dur))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(vbCyan)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    auditionLastOutputButton(path: path, isAuditioning: isAuditioningThis)
                    insertLastOutputToTrackButton(path: path)
                }
                revealLastOutputInFinderButton(path: path)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(vbEmerald.opacity(0.35)))
    }

    private func auditionLastOutputButton(path: String, isAuditioning: Bool) -> some View {
        Button {
            if isAuditioning {
                audioAI.stopAudition()
            } else {
                controller.stopPreview()
                audioAI.playLocalAudioFile(path: path, tag: "voicebox_last_output")
            }
        } label: {
            Label(isAuditioning ? "停止試聽" : "試聽成品", systemImage: isAuditioning ? "stop.fill" : "play.fill")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .accessibilityLabel(isAuditioning ? "停止試聽最新生成配音" : "試聽最新生成配音成品")
    }

    private func insertLastOutputToTrackButton(path: String) -> some View {
        Button {
            let profileName = controller.lastGeneratedProfileName ?? selectedProfile?.name ?? "配音"
            if let sel = app.addGeneratedAudioToTrack(
                path: path,
                at: playback.playhead,
                preferredTrackName: "A 配音 · \(profileName)"
            ) {
                state.selection = sel
                state.previewMode = .timeline
                playback.syncLayout(app.currentMultitrackLayout())
                app.status = "已將配音成品加入音訊軌 · \(filename(path))"
            }
        } label: {
            Label("入 A 軌", systemImage: "plus.rectangle.on.folder.fill")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .disabled(app.busy)
        .accessibilityLabel("將最新生成配音加入播放頭音訊軌")
    }

    private func revealLastOutputInFinderButton(path: String) -> some View {
        Button {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("在 Finder 顯示", systemImage: "folder")
                .font(.system(size: 11.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .accessibilityLabel("在 Finder 顯示最新配音檔案")
    }

    // MARK: Collapsible Non-Destructive Reference Transcript Override & Engine Details

    private var engineAndSampleDetailsDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.showEngineDetails.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.showEngineDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("參考音訊逐字稿與引擎設定")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展開或收合參考音訊逐字稿與引擎設定")

            if store.showEngineDetails {
                VStack(alignment: .leading, spacing: 8) {
                    // 1. Non-destructive reference sample transcript override editor (saves to MotionDesk cache, never mutates original voicebox.db)
                    if let profile = selectedProfile, profile.isCloned, let sample = activeSelectedSample {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("參考音訊逐字稿校正（\(profile.name)）")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(vbCyan)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if store.editingSampleIsDerivedOverride {
                                    Text("衍生校正")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(vbEmerald)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(vbEmerald.opacity(0.16), in: Capsule())
                                }
                            }

                            TextEditor(text: $store.editingSampleReferenceText)
                                .font(.system(size: 12))
                                .frame(height: 54)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.10)))
                                .accessibilityLabel("參考音訊逐字稿編輯框")

                            HStack(spacing: 6) {
                                Button {
                                    saveDerivedSampleTranscript(sample: sample, restoreOriginal: false)
                                } label: {
                                    Text(store.isSavingSampleReferenceText ? "儲存中…" : "儲存校正快取")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .controlSize(.small)
                                .disabled(
                                    store.isSavingSampleReferenceText
                                    || store.editingSampleReferenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                )
                                .accessibilityLabel("儲存參考音訊逐字稿校正快取")
                                .help("儲存至 Klipora 衍生校正快取並清除語音提示快取，不修改原始聲音庫資料庫")

                                Button {
                                    saveDerivedSampleTranscript(sample: sample, restoreOriginal: true)
                                } label: {
                                    Text("還原原始值")
                                        .font(.system(size: 11.5))
                                }
                                .controlSize(.small)
                                .disabled(store.isSavingSampleReferenceText)
                                .accessibilityLabel("還原原始參考音訊逐字稿")
                            }
                        }
                    }

                    Divider().overlay(.white.opacity(0.06))

                    // 2. Concise engine status + unload / refresh actions
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(serviceBadgeColor)
                                .frame(width: 7, height: 7)
                            Text(controller.serviceStatusBadgeText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 2)
                        }

                        HStack(spacing: 6) {
                            if controller.modelLoaded {
                                Button("卸載模型記憶體") {
                                    Task { await controller.unloadLocalModels() }
                                }
                                .controlSize(.small)
                                .disabled(controller.isGenerating)
                                .accessibilityLabel("從記憶體卸載語音模型")
                            }

                            Button("重新整理角色與狀態") {
                                Task { @MainActor in
                                    let ok = await controller.ensureServiceReady()
                                    if ok {
                                        await controller.refreshCatalogData()
                                        syncSelectedProfileAndEngine()
                                    }
                                }
                            }
                            .controlSize(.small)
                            .disabled(controller.ownership == .starting || controller.isGenerating)
                            .accessibilityLabel("重新整理語音引擎與角色列表")
                        }
                    }

                    // 3. Data & Models folder pickers
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text("聲音庫")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(controller.dataDirPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 2)
                            Button("變更…") {
                                app.pickAsync(
                                    title: "選擇聲音資料庫資料夾（如 sh.voicebox.app）",
                                    types: [],
                                    multiple: false,
                                    directory: true
                                ) { urls in
                                    if let folder = urls.first {
                                        controller.dataDirPath = folder.path
                                        Task {
                                            await controller.restartForPathChange()
                                            syncSelectedProfileAndEngine()
                                        }
                                    }
                                }
                            }
                            .controlSize(.small)
                            .accessibilityLabel("變更聲音資料庫資料夾")
                        }

                        HStack(spacing: 5) {
                            Text("模型庫")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(controller.modelsCachePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 2)
                            Button("變更…") {
                                app.pickAsync(
                                    title: "選擇 HuggingFace 模型快取資料夾（hub）",
                                    types: [],
                                    multiple: false,
                                    directory: true
                                ) { urls in
                                    if let folder = urls.first {
                                        controller.modelsCachePath = folder.path
                                        Task {
                                            await controller.restartForPathChange()
                                        }
                                    }
                                }
                            }
                            .controlSize(.small)
                            .accessibilityLabel("變更模型快取資料夾")
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(vbDarkWell, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveDerivedSampleTranscript(sample: VoiceboxSample, restoreOriginal: Bool) {
        store.isSavingSampleReferenceText = true
        Task { @MainActor in
            defer { store.isSavingSampleReferenceText = false }
            do {
                if restoreOriginal {
                    try await controller.saveDerivedSampleReferenceOverride(sample: sample, overrideText: nil)
                    let resolved = await controller.effectiveReferenceText(for: sample)
                    store.editingSampleReferenceText = resolved.text
                    store.editingSampleIsDerivedOverride = resolved.isDerivedOverride
                    controller.statusMessage = "已還原參考逐字稿預設值（原始聲音庫未更動）。"
                } else {
                    let newText = store.editingSampleReferenceText.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await controller.saveDerivedSampleReferenceOverride(sample: sample, overrideText: newText)
                    store.editingSampleReferenceText = newText
                    store.editingSampleIsDerivedOverride = true
                    controller.statusMessage = "已儲存參考逐字稿衍生校正快取（保留原始聲音庫不變）。"
                }
            } catch {
                controller.lastError = error.localizedDescription
            }
        }
    }

    private var serviceBadgeColor: Color {
        switch controller.ownership {
        case .ownedByMotionDesk, .externalReused:
            return vbEmerald
        case .starting:
            return vbAmber
        case .failed:
            return vbRose
        case .stopped:
            return .secondary
        }
    }
}

// MARK: - 8. Spacious Central Native Voice Workspace (`NativeVoiceCentralWorkspaceView`)

struct NativeVoiceCentralWorkspaceView: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController

    @ObservedObject private var store = NativeVoiceWorkspaceStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("中央配音工作台", systemImage: "waveform.badge.mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        store.showCentralVoiceWorkspace = false
                    } label: {
                        Label("切換至時間軸畫面預覽", systemImage: "tv")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("切換至時間軸畫面預覽")
                }

                VoiceboxStudioSectionView(
                    app: app,
                    state: state,
                    playback: playback,
                    searchQuery: state.librarySearchQuery,
                    isCentralLayout: true,
                    onOpenComponentSettings: {
                        PortabilitySetupManager.shared.openSetupSheet(firstRun: false, app: app)
                    }
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvas)
    }
}
