import AppKit
import AVFoundation
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Local Navy/Cream/Terracotta Palette & Helpers

private let setupCyan = StudioTheme.neutralAccent
private let setupAmber = StudioTheme.warning
private let setupEmerald = StudioTheme.success
private let setupViolet = StudioTheme.neutralAccent
private let setupRose = StudioTheme.danger
private let setupDarkWell = StudioTheme.well

enum SetupSectionAnchor: String, CaseIterable, Identifiable, Sendable {
    case runtime = "setup_section_runtime"
    case account = "setup_section_account"
    case models = "setup_section_models"
    case service = "setup_section_service"

    var id: String { rawValue }

    var pillarTitle: String {
        switch self {
        case .runtime: return "1. 執行環境"
        case .account: return "2. 雲端登入與 API"
        case .models: return "3. 模型快取"
        case .service: return "4. 服務連線"
        }
    }

    var navigationHint: String {
        switch self {
        case .runtime: return "捲動並展開 FFmpeg 與本機執行環境設定（不觸發網路或 GPU）"
        case .account: return "捲動並展開雲端 Colab 登入與選用 API 金鑰區塊（不自動登入或啟動 GPU）"
        case .models: return "捲動並展開本機語音與圖片模型快取設定（不自動下載模型）"
        case .service: return "捲動並展開本機 ComfyUI 服務連線設定（不自動啟動服務）"
        }
    }
}

struct HardwareEnvironmentSnapshot: Equatable {
    let osVersion: String
    let architecture: String
    let physicalMemoryGB: Double
    let availableDiskGB: Double

    static func current() -> HardwareEnvironmentSnapshot {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "Apple Silicon (arm64)"
        #else
        let arch = "x86_64"
        #endif
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let freeBytes = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        let freeGB = Double(max(0, freeBytes)) / (1024.0 * 1024.0 * 1024.0)
        return HardwareEnvironmentSnapshot(
            osVersion: os,
            architecture: arch,
            physicalMemoryGB: ramGB,
            availableDiskGB: freeGB
        )
    }

    var summaryLine: String {
        String(format: "macOS %@ · %@ · 記憶體 %.0f GB · 可用磁碟 %.1f GB", osVersion, architecture, physicalMemoryGB, availableDiskGB)
    }

    var modelRequirementsSummary: String {
        "支援模型需求參考：語音 Qwen3-TTS 1.7B 約 4.2 GB 磁碟（已量測）；單張本機圖片模型（SDXL / Z-Image / Krea2 / MOSS / FLUX）約 6–24 GB 磁碟、建議 ≥16–32 GB 統一記憶體（估算）。"
    }
}

private func setupFormatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 MB" }
    let mb = Double(bytes) / (1024.0 * 1024.0)
    if mb >= 1024.0 {
        return String(format: "%.2f GB", mb / 1024.0)
    }
    return String(format: "%.1f MB", mb)
}

private func setupCompactPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
        return "~" + String(path.dropFirst(home.count))
    }
    return path
}

private func setupDirectoryDiskBytes(at url: URL, maxFiles: Int = 1500) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants]
    ) else { return 0 }

    var total: Int64 = 0
    var count = 0
    for case let fileURL as URL in enumerator {
        count += 1
        if count > maxFiles { break }
        if let vals = try? fileURL.resourceValues(forKeys: Set(keys)),
           vals.isRegularFile == true {
            total += Int64(vals.fileAllocatedSize ?? vals.fileSize ?? 0)
        }
    }
    return total
}

private func setupAvailableDiskSpaceBytes(for url: URL) -> Int64? {
    let fm = FileManager.default
    var probe = url.standardizedFileURL
    while !fm.fileExists(atPath: probe.path) && probe.path != "/" {
        probe.deleteLastPathComponent()
    }
    if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let capacity = values.volumeAvailableCapacityForImportantUsage,
       capacity > 0 {
        return capacity
    }
    if let attrs = try? fm.attributesOfFileSystem(forPath: probe.path),
       let freeSize = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
       freeSize > 0 {
        return freeSize
    }
    return nil
}

// MARK: - 1. macOS Keychain Manager (KeychainCredentialsStore)

enum KeychainStoreError: LocalizedError, Equatable {
    case encodingFailed
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "無法編碼憑證字串。"
        case .unexpectedStatus(let status):
            if let cfMessage = SecCopyErrorMessageString(status, nil) as String? {
                return "macOS Keychain 錯誤（\(status)）：\(cfMessage)"
            }
            return "macOS Keychain 錯誤（代碼 \(status)）。"
        }
    }
}

/// Manages provider-specific API credentials in the native macOS Keychain (`kSecClassGenericPassword`).
/// Security Contract:
/// - Never logs, prints, or serializes secrets into Project JSON, UserDefaults, or log files.
/// - Never automatically imports credentials from environment variables or other applications.
enum KeychainCredentialsStore {
    static let defaultService = "local.motiondesk.studio.credentials"

    static func save(account: String, secret: String, service: String = defaultService) throws {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else {
            throw KeychainStoreError.encodingFailed
        }
        if trimmedSecret.isEmpty {
            try delete(account: trimmedAccount, service: service)
            return
        }
        guard let secretData = trimmedSecret.data(using: .utf8) else {
            throw KeychainStoreError.encodingFailed
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: trimmedAccount
        ]

        let existingStatus = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        if existingStatus == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: secretData
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(updateStatus)
            }
        } else if existingStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = secretData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        } else {
            throw KeychainStoreError.unexpectedStatus(existingStatus)
        }
    }

    static func read(account: String, service: String = defaultService) -> String? {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: trimmedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func delete(account: String, service: String = defaultService) throws {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: trimmedAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    static func hasCredential(account: String, service: String = defaultService) -> Bool {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: trimmedAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Security: never follow redirects or forward Bearer secrets to redirected URLs
        completionHandler(nil)
    }
}

private let noRedirectSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 6.0
    cfg.timeoutIntervalForResource = 6.0
    return URLSession(configuration: cfg, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
}()

// MARK: - 2. Supported API Providers & Endpoint Configuration

/// Providers that are actually supported and wired in MotionDesk's codebase.
/// No inert/unimplemented providers are invented here.
enum SupportedAPIProvider: String, CaseIterable, Identifiable, Codable {
    case huggingface = "huggingface"
    case comfyui_api = "comfyui_api"
    case voicebox_api = "voicebox_api"
    case openai_image = "openai_image"
    case gemini_image = "gemini_image"

    var id: String { rawValue }

    var isOnlineProvider: Bool {
        switch self {
        case .huggingface, .openai_image, .gemini_image: return true
        case .comfyui_api, .voicebox_api: return false
        }
    }

    var displayName: String {
        switch self {
        case .huggingface:
            return "HuggingFace Hub（模型下載來源 · HTTPS）"
        case .comfyui_api:
            return "本機 ComfyUI 端點（Loopback 繪圖與影片服務）"
        case .voicebox_api:
            return "本機語音服務端點（Loopback 語音引擎）"
        case .openai_image:
            return "OpenAI 圖片 API（選擇性付費 · 固定官方主機）"
        case .gemini_image:
            return "Gemini 圖片 API（選擇性付費 · 無免費層）"
        }
    }

    var shortName: String {
        switch self {
        case .huggingface: return "HuggingFace Hub"
        case .comfyui_api: return "本機 ComfyUI 端點"
        case .voicebox_api: return "Voicebox 本機服務"
        case .openai_image: return "OpenAI 圖片 API"
        case .gemini_image: return "Gemini 圖片 API"
        }
    }

    var keychainAccount: String {
        switch self {
        case .huggingface: return "huggingface_token"
        case .comfyui_api: return "comfyui_api_token"
        case .voicebox_api: return "voicebox_api_token"
        case .openai_image: return "openai_image_api_key"
        case .gemini_image: return "gemini_image_api_key"
        }
    }

    var urlDefaultsKey: String {
        "MotionDesk.api.\(rawValue).serviceURL"
    }

    var defaultServiceURL: String {
        switch self {
        case .huggingface:
            return "https://huggingface.co"
        case .comfyui_api:
            return "http://127.0.0.1:8188"
        case .voicebox_api:
            return "http://127.0.0.1:17495"
        case .openai_image:
            return "https://api.openai.com"
        case .gemini_image:
            return "https://generativelanguage.googleapis.com"
        }
    }

    var credentialFieldTitle: String {
        switch self {
        case .huggingface:
            return "Access Token（選填，公開模型免填）"
        case .comfyui_api:
            return "本機 Bearer Token（選填，預設無需 API Key）"
        case .voicebox_api:
            return "本機存取權杖（選填，預設免填）"
        case .openai_image:
            return "OpenAI API Key（僅存於 Keychain，付費使用）"
        case .gemini_image:
            return "Gemini API Key（僅存於 Keychain，付費使用）"
        }
    }

    var credentialPlaceholder: String {
        switch self {
        case .huggingface:
            return "hf_...（選填，公開模型免填）"
        case .comfyui_api:
            return "選填（本機 ComfyUI 預設留空）"
        case .voicebox_api:
            return "選填（本機預設留空）"
        case .openai_image:
            return "sk-...（僅存於 macOS Keychain）"
        case .gemini_image:
            return "AIza...（僅存於 macOS Keychain）"
        }
    }

    var usageNote: String {
        switch self {
        case .huggingface:
            return "公開語音模型無需 Token 即可下載；若需存取私有或受限模型，儲存之 Token 會由系統安全帶入下載環境。僅允許 HTTPS 且禁止重新導向。"
        case .comfyui_api:
            return "本機 ComfyUI 預設無需 API Key，僅支援本機 Loopback（127.0.0.1 / localhost）。若本機設有驗證代理，儲存之 Token 會在連線與生成時自動帶入。"
        case .voicebox_api:
            return "內建本機語音服務（僅限 127.0.0.1 / localhost），用於驗證服務健康狀態與載入聲音角色庫。"
        case .openai_image:
            return "固定使用官方主機 https://api.openai.com（/v1/images/generations），禁止重新導向轉送金鑰。ChatGPT 網頁版免費額度不適用於 API；需於生成頁明確勾選計費同意才會啟用。"
        case .gemini_image:
            return "固定使用官方主機 https://generativelanguage.googleapis.com（/v1beta/interactions，Api-Revision: 2026-05-20）。Gemini 圖片 API 目前不提供免費層，網頁版免費額度不適用；需於生成頁明確勾選計費同意才會啟用。"
        }
    }

    /// Validates that the service URL matches the actual supported transport contract.
    func validateEndpointURL(_ rawURL: String) -> (validURL: String?, errorMessage: String?) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased() else {
            return (nil, "請輸入有效的網址（例如 \(defaultServiceURL)）。")
        }
        if comps.user != nil || comps.password != nil || comps.query != nil || comps.fragment != nil {
            return (nil, "服務網址不可包含帳密參數、Query 或 Fragment。")
        }

        switch self {
        case .huggingface:
            guard scheme == "https" else {
                return (nil, "安全限制：HuggingFace 端點必須使用 https:// 加密傳輸，禁止透過明文 HTTP 傳送 Token。")
            }
            return (trimmed, nil)

        case .comfyui_api:
            let allowedLoopback: Set<String> = ["127.0.0.1", "localhost", "::1"]
            guard scheme == "http", allowedLoopback.contains(host), (comps.path.isEmpty || comps.path == "/") else {
                return (nil, "支援邊界限制：本機生成引擎僅支援 Loopback ComfyUI（如 http://127.0.0.1:8188），不支援遠端非本機位址。")
            }
            return (trimmed, nil)

        case .voicebox_api:
            let allowedLoopback: Set<String> = ["127.0.0.1", "localhost", "::1"]
            guard scheme == "http", allowedLoopback.contains(host), (comps.path.isEmpty || comps.path == "/") else {
                return (nil, "支援邊界限制：本機語音引擎僅限 Loopback 位址（如 http://127.0.0.1:17495）。")
            }
            return (trimmed, nil)

        case .openai_image:
            guard scheme == "https", host == "api.openai.com", (comps.path.isEmpty || comps.path == "/") else {
                return (nil, "安全限制：OpenAI 圖片 API 僅允許固定官方主機 https://api.openai.com。")
            }
            return (trimmed, nil)

        case .gemini_image:
            guard scheme == "https", host == "generativelanguage.googleapis.com", (comps.path.isEmpty || comps.path == "/") else {
                return (nil, "安全限制：Gemini 圖片 API 僅允許固定官方主機 https://generativelanguage.googleapis.com。")
            }
            return (trimmed, nil)
        }
    }
}

struct APIConnectionConfig: Identifiable, Equatable {
    let provider: SupportedAPIProvider
    var serviceURL: String
    var draftSecret: String = ""
    var hasStoredCredential: Bool = false
    var isSecretRevealed: Bool = false
    var isTesting: Bool = false
    var testSucceeded: Bool? = nil
    var testStatusMessage: String? = nil
    var lastTestedAt: Date? = nil

    var id: String { provider.rawValue }
}

// MARK: - 3. Diagnostic State Models for the 6 Cards

enum ComponentReadinessBadge: Equatable, Sendable {
    case ready(String)
    case reusable(String)
    case optionalMissing(String)
    case warning(String)
    case neutral(String)

    var label: String {
        switch self {
        case .ready(let s), .reusable(let s), .optionalMissing(let s), .warning(let s), .neutral(let s):
            return s
        }
    }

    var tintColor: Color {
        switch self {
        case .ready: return setupEmerald
        case .reusable: return StudioTheme.neutralAccent
        case .optionalMissing: return StudioTheme.textSecondary
        case .warning: return setupAmber
        case .neutral: return StudioTheme.textSecondary
        }
    }

    var iconName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .reusable: return "info.circle.fill"
        case .optionalMissing: return "circle.dashed"
        case .warning: return "exclamationmark.triangle.fill"
        case .neutral: return "circle.dotted"
        }
    }
}

/// Separate 4-pillar capability summary required by PORTABILITY_REVIEW.md:
/// - Runtime available (`執行環境可用`)
/// - Account authenticated (`帳號驗證狀態`)
/// - Model installed (`模型已安裝`)
/// - Engine ready (`引擎已就緒`)
struct FourPillarCapabilitySummary: Equatable {
    var runtimeAvailable: ComponentReadinessBadge
    var accountAuthenticated: ComponentReadinessBadge
    var modelInstalled: ComponentReadinessBadge
    var engineReady: ComponentReadinessBadge
}

struct VoiceboxModelCacheItem: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let repoID: String
    let engineLabel: String
    let expectedSizeDescription: String
    let requiresSpeechTokenizer: Bool
    let isRecommendedForChinese: Bool
    var isComplete: Bool
    var hasIncompleteBlobs: Bool
    var mainWeightsPresent: Bool
    var speechTokenizerPresent: Bool
    var diskSizeBytes: Int64
    var snapshotPath: String?
    var statusNote: String
}

enum VoiceboxRuntimeSourceKind: String, Equatable, Sendable {
    case bundledInApp = "bundled"
    case reusedInstalledApp = "reused_app"
    case missing = "missing"

    var badgeText: String {
        switch self {
        case .bundledInApp: return "已內建語音引擎"
        case .reusedInstalledApp: return "重用本機語音引擎"
        case .missing: return "未安裝執行檔"
        }
    }
}

enum DependencyDistributionKind: String, Equatable {
    case bundled = "已內建捆綁"
    case reusedOrConfigurable = "本機自動重用 / 可選路徑"
    case userTriggeredDownload = "使用者觸發官方下載"
    case externalOptional = "外部選用工具"
    case roadmapOnly = "後續規劃（未宣稱支援）"

    var color: Color {
        switch self {
        case .bundled: return setupEmerald
        case .reusedOrConfigurable: return setupCyan
        case .userTriggeredDownload: return setupAmber
        case .externalOptional: return setupViolet
        case .roadmapOnly: return .secondary
        }
    }
}

struct DependencyManifestEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let versionOrArch: String
    let distributionKind: DependencyDistributionKind
    let approxSize: String
    let license: String
    let sourceOrPath: String
    let notes: String
}

// MARK: - 4. PortabilitySetupManager (@MainActor ObservableObject)

extension Notification.Name {
    static let motionDeskVoiceboxConfigChanged = Notification.Name("MotionDesk.VoiceboxConfigChanged")
    static let motionDeskComfyConfigChanged = Notification.Name("MotionDesk.ComfyConfigChanged")
}

@MainActor
final class PortabilitySetupManager: ObservableObject {
    static let shared = PortabilitySetupManager()

    // UserDefaults Keys
    static let firstRunCompletedKey = "MotionDesk.v5.firstRunCompleted"
    static let comfyModelsRootKey = "MotionDesk.comfyui.modelsRoot"
    static let comfyModelsRootBookmarkKey = "MotionDesk.comfyui.modelsRootBookmark"
    static let comfyLastDiscoveredEndpointKey = "MotionDesk.comfyui.lastEndpoint"
    static let voiceboxDataDirKey = "MotionDesk.voicebox.dataDir"
    static let voiceboxModelsDirKey = "MotionDesk.voicebox.modelsDir"
    static let voiceboxPortKey = "MotionDesk.voicebox.port"
    static let customFFmpegPathKey = "MotionDesk.ffmpeg.customPath"
    static let preferredVideoColabGPUKey = "MotionDesk.colab.videoGPU"

    private let userDefaults: UserDefaults
    let keychainService: String
    private var activeComfyModelsSecurityScopedURL: URL? = nil

    // Sheet & Navigation State
    @Published var isSheetPresented: Bool = false
    @Published var isFirstRunMode: Bool = false
    @Published var selectedTab: SetupSheetTab = .cards
    @Published var selectedSidebar: SetupSidebarSection = .general
    @Published var statusBannerMessage: String? = nil
    @Published var showImageModelManagerSheet: Bool = false
    @Published var showVoiceModelManagerSheet: Bool = false

    // Voice Model Direct Download State
    @Published var downloadingVoiceModelRepoID: String? = nil
    @Published var voiceModelDownloadProgress: Double = 0
    @Published var voiceModelDownloadStatus: String = ""

    func downloadVoiceModel(_ item: VoiceboxModelCacheItem, app: Studio) {
        guard downloadingVoiceModelRepoID == nil else {
            statusBannerMessage = "目前已有語音模型正在下載中，請稍候完成。"
            return
        }
        let repoID = item.repoID
        let cacheRoot = voiceboxModelsDirPath
        let displayName = item.displayName
        downloadingVoiceModelRepoID = repoID
        voiceModelDownloadProgress = 0.02
        voiceModelDownloadStatus = "正在連線 HuggingFace 取得 \(displayName) 檔案清單…"
        statusBannerMessage = "開始下載語音模型：\(displayName)（背景執行中）"

        Task.detached(priority: .userInitiated) { [weak self] in
            let script = """
            import json, os, sys, urllib.request, urllib.parse
            from pathlib import Path

            repo_id = sys.argv[1]
            hub_root = Path(sys.argv[2])
            hub_root.mkdir(parents=True, exist_ok=True)

            repo_dir = hub_root / ("models--" + repo_id.replace("/", "--"))
            refs_dir = repo_dir / "refs"
            refs_dir.mkdir(parents=True, exist_ok=True)

            # Fetch repo metadata for commit SHA
            meta_url = f"https://huggingface.co/api/models/{repo_id}"
            with urllib.request.urlopen(meta_url, timeout=30) as r:
                meta = json.loads(r.read().decode("utf-8"))
            sha = meta.get("sha") or "main"
            (refs_dir / "main").write_text(sha, encoding="utf-8")

            snap_dir = repo_dir / "snapshots" / sha
            snap_dir.mkdir(parents=True, exist_ok=True)

            def list_files(prefix=""):
                url = f"https://huggingface.co/api/models/{repo_id}/tree/main" + (f"/{urllib.parse.quote(prefix)}" if prefix else "")
                with urllib.request.urlopen(url, timeout=30) as r:
                    items = json.loads(r.read().decode("utf-8"))
                out = []
                for it in items:
                    t = it.get("type")
                    p = it.get("path", "")
                    if t == "directory":
                        out.extend(list_files(p))
                    elif t == "file":
                        sz = (it.get("lfs") or {}).get("size") or it.get("size") or 0
                        out.append((p, int(sz)))
                return out

            files = list_files()
            total_bytes = max(1, sum(sz for _, sz in files))
            done_bytes = 0

            for rel_path, sz in files:
                dest = snap_dir / rel_path
                dest.parent.mkdir(parents=True, exist_ok=True)
                if dest.exists() and (sz == 0 or dest.stat().st_size == sz):
                    done_bytes += sz
                    pct = min(0.99, done_bytes / total_bytes)
                    print(f"PROGRESS|{pct:.4f}|已存在 {rel_path}", flush=True)
                    continue
                dl_url = f"https://huggingface.co/{repo_id}/resolve/main/{urllib.parse.quote(rel_path)}"
                tmp = dest.with_suffix(dest.suffix + ".part")
                req = urllib.request.Request(dl_url, headers={"User-Agent": "Klipora/1.1"})
                with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as f:
                    file_done = 0
                    while True:
                        chunk = resp.read(1024 * 512)
                        if not chunk:
                            break
                        f.write(chunk)
                        file_done += len(chunk)
                        pct = min(0.99, (done_bytes + file_done) / total_bytes)
                        print(f"PROGRESS|{pct:.4f}|下載中 {os.path.basename(rel_path)} ({int(pct*100)}%)", flush=True)
                os.replace(tmp, dest)
                done_bytes += max(sz, dest.stat().st_size)

            print("PROGRESS|1.0000|下載完成", flush=True)
            """

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = ["-u", "-c", script, repoID, cacheRoot]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            let handle = pipe.fileHandleForReading
            do {
                try proc.run()
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if let line = String(data: lineData, encoding: .utf8) {
                            if line.hasPrefix("PROGRESS|") {
                                let parts = line.split(separator: "|", maxSplits: 2)
                                if parts.count == 3, let pct = Double(parts[1]) {
                                    let msg = String(parts[2])
                                    await MainActor.run {
                                        self?.voiceModelDownloadProgress = pct
                                        self?.voiceModelDownloadStatus = msg
                                    }
                                }
                            }
                        }
                    }
                }
                proc.waitUntilExit()
                let ok = proc.terminationStatus == 0
                await MainActor.run {
                    self?.downloadingVoiceModelRepoID = nil
                    self?.voiceModelDownloadProgress = ok ? 1.0 : 0
                    self?.voiceModelDownloadStatus = ""
                    self?.statusBannerMessage = ok
                        ? "語音模型「\(displayName)」下載完成並已驗證就緒！"
                        : "語音模型「\(displayName)」下載未完成，請確認網路後重試。"
                    self?.refreshAllLocalStates(app: app, userInitiated: true)
                }
            } catch {
                await MainActor.run {
                    self?.downloadingVoiceModelRepoID = nil
                    self?.voiceModelDownloadProgress = 0
                    self?.voiceModelDownloadStatus = ""
                    self?.statusBannerMessage = "無法啟動模型下載：\(error.localizedDescription)"
                }
            }
        }
    }

    func removeVoiceModelCache(_ item: VoiceboxModelCacheItem, app: Studio) {
        let folderName = "models--" + item.repoID.replacingOccurrences(of: "/", with: "--")
        let target = URL(fileURLWithPath: voiceboxModelsDirPath, isDirectory: true).appendingPathComponent(folderName)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            statusBannerMessage = "已移除語音模型快取「\(item.displayName)」並釋放磁碟空間。"
            refreshAllLocalStates(app: app, userInitiated: true)
        } catch {
            statusBannerMessage = "無法移除語音模型快取：\(error.localizedDescription)"
        }
    }

    // Automation / MCP Server Preview Config (v1.2 foundation)
    static let automationEnabledKey = "Klipora.automation.mcpEnabled"
    static let automationPortKey = "Klipora.automation.mcpPort"
    static let automationTokenKey = "Klipora.automation.mcpToken"
    @Published var automationEnabled: Bool = false
    @Published var automationPort: Int = 17499
    @Published var automationToken: String = ""
    @Published var automationTokenRevealed: Bool = false

    var automationEndpoint: String {
        "http://127.0.0.1:\(automationPort)/mcp"
    }

    func setAutomationEnabled(_ enabled: Bool) {
        automationEnabled = enabled
        userDefaults.set(enabled, forKey: Self.automationEnabledKey)
        if enabled && automationToken.isEmpty {
            regenerateAutomationToken()
        }
    }

    func regenerateAutomationToken() {
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(32)
        automationToken = "klp_\(token)"
        userDefaults.set(automationToken, forKey: Self.automationTokenKey)
        statusBannerMessage = "已重新產生本機 Automation Access Token。"
    }

    func copyAutomationToken() {
        if automationToken.isEmpty { regenerateAutomationToken() }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(automationToken, forType: .string)
        statusBannerMessage = "已複製 Access Token 到剪貼簿。"
    }

    func copyAutomationClientCommand(for client: String) {
        if automationToken.isEmpty { regenerateAutomationToken() }
        let cmd: String
        switch client {
        case "Claude Code":
            cmd = "claude mcp add --transport http klipora \(automationEndpoint) --header \"Authorization: Bearer \(automationToken)\""
        case "Codex":
            cmd = "codex mcp add klipora --url \(automationEndpoint) --bearer-token-env-var KLIPORA_MCP_TOKEN\nexport KLIPORA_MCP_TOKEN=\"\(automationToken)\""
        default:
            cmd = """
            {
              "mcpServers": {
                "klipora": {
                  "serverUrl": "\(automationEndpoint)",
                  "headers": { "Authorization": "Bearer \(automationToken)" }
                }
              }
            }
            """
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        statusBannerMessage = "已複製 \(client) 連接設定，貼上即可使用。"
    }

    enum SetupSidebarSection: String, CaseIterable, Identifiable {
        case general = "一般"
        case localEngines = "本機引擎"
        case cloudAPI = "雲端與 API"
        case automation = "AI 代理與自動化"
        case modelsStorage = "模型與快取"
        case about = "元件與關於"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .localEngines: return "desktopcomputer"
            case .cloudAPI: return "cloud"
            case .automation: return "link"
            case .modelsStorage: return "internaldrive"
            case .about: return "info.circle"
            }
        }
    }

    // DisclosureGroup states: default false so main flow stays concise (Task / State / Action),
    // while engineering diagnostics and full paths remain one click away.
    @Published var showCard1Details: Bool = false
    @Published var showCard2Details: Bool = false
    @Published var showCard3Details: Bool = false
    @Published var showCard4Details: Bool = false
    @Published var showCard5Details: Bool = false
    @Published var showCard6Details: Bool = false

    var allDetailsExpanded: Bool {
        showCard1Details && showCard2Details && showCard3Details && showCard4Details && showCard5Details && showCard6Details
    }

    func setAllDetailsExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            showCard1Details = expanded
            showCard2Details = expanded
            showCard3Details = expanded
            showCard4Details = expanded
            showCard5Details = expanded
            showCard6Details = expanded
        }
    }

    enum SetupSheetTab: String, CaseIterable, Identifiable {
        case cards = "元件與連線設定"
        case manifest = "元件清單與授權"
        var id: String { rawValue }
    }

    // Card 1: Output Root & Dated Storage
    @Published var outputRootPath: String = ""
    @Published var todayDatedFolderPath: String = ""
    @Published var todayDatedFolderName: String = ""
    @Published var outputRootFreeBytes: Int64? = nil
    @Published var outputRootWritable: Bool = true
    @Published var isUsingCustomOutputRoot: Bool = false

    // Card 2: Local ComfyUI
    @Published var comfyModelsRootPath: String = ""
    @Published var comfyModelsDirectoryExists: Bool = false
    @Published var comfyDesktopAppPath: String? = nil
    @Published var comfyRuntimePythonPath: String? = nil
    @Published var comfyDetectedModelFilesCount: Int = 0
    @Published var comfyDetectedModelCategories: [String] = []
    @Published var comfyConfiguredEndpoint: String = "http://127.0.0.1:8188"
    @Published var comfyIsProbing: Bool = false
    @Published var comfyEndpointReachable: Bool = false
    @Published var comfyServerIdentitySummary: String? = nil
    @Published var comfyProbeMessage: String = "尚未探測端點（按需檢測，不自動啟動模型）"

    // Card 3: Voicebox Runtime, Models & Voice Library
    @Published var voiceboxRuntimeSource: VoiceboxRuntimeSourceKind = .missing
    @Published var voiceboxBinaryPath: String? = nil
    @Published var voiceboxBinarySizeBytes: Int64 = 0
    @Published var voiceboxBinaryArchitecture: String = "未偵測"
    @Published var voiceboxBackendPatchesPresent: Bool = false
    @Published var voiceboxBackendPatchesPath: String? = nil
    @Published var voiceboxDataDirPath: String = ""
    @Published var voiceboxDatabaseExists: Bool = false
    @Published var voiceboxProfileCountEstimate: Int = 0
    @Published var voiceboxDataDirSizeBytes: Int64 = 0
    @Published var voiceboxModelsDirPath: String = ""
    @Published var voiceboxModelsDirFreeBytes: Int64? = nil
    @Published var voiceboxModelItems: [VoiceboxModelCacheItem] = []
    @Published var voiceboxPort: Int = 17495

    // Card 4: Google Colab
    @Published var colabBinaryPath: String? = nil
    @Published var colabTokenFileExists: Bool = false
    @Published var colabTokenFilePath: String = ""
    @Published var colabAuthVerified: Bool? = nil
    @Published var colabIsCheckingAuth: Bool = false
    @Published var colabIsLaunchingAuth: Bool = false
    @Published var colabPendingAuthURL: String? = nil
    @Published var colabManualAuthCode: String = ""
    @Published var colabIsSubmittingCode: Bool = false
    @Published var colabAuthCheckSummary: String = "憑證狀態待驗證（點選「檢查登入與額度」確認；開啟設定不配置雲端 GPU）"
    @Published var colabPreferredVideoGPU: String = "L4"
    private var activeColabAuthProcess: Process? = nil

    // Card 5: API Connections & macOS Keychain
    @Published var apiConnections: [SupportedAPIProvider: APIConnectionConfig] = [:]

    // Card 6: FFmpeg / Runtime / AI-Audio Dependencies
    @Published var hostArchitecture: String = "arm64"
    @Published var isAppleSiliconHost: Bool = true
    @Published var bundledNodeReady: Bool = false
    @Published var bundledNodePath: String? = nil
    @Published var bundledHyperFramesReady: Bool = false
    @Published var bundledTextRenderReady: Bool = false
    @Published var bundledTextRenderPath: String? = nil
    @Published var ffmpegResolvedPath: String? = nil
    @Published var ffprobeResolvedPath: String? = nil
    @Published var ffmpegSourceDescription: String = "未找到"
    @Published var ffmpegVersionSummary: String? = nil
    @Published var ffmpegIsHomebrewLinked: Bool = false
    @Published var isProbingFFmpeg: Bool = false
    @Published var isRefreshingLocalStates: Bool = false
    @Published var localRefreshTimedOut: Bool = false
    var localScanTimeoutSeconds: Double = 2.5
    var localScanSimulatedDelaySeconds: Double = 0.0
    private var localRefreshTask: Task<Void, Never>? = nil
    private var localRefreshWatchdogTask: Task<Void, Never>? = nil
    private var localRefreshGeneration: UInt64 = 0
    private var lastLocalRefreshAt: Date? = nil

    private final class InFlightScanTracker: @unchecked Sendable {
        static let shared = InFlightScanTracker()
        private let lock = NSLock()
        private var inFlightKeys: Set<String> = []

        func tryAcquire(key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if inFlightKeys.contains(key) {
                return false
            }
            inFlightKeys.insert(key)
            return true
        }

        func release(key: String) {
            lock.lock()
            inFlightKeys.remove(key)
            lock.unlock()
        }

        func isInFlight(key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return inFlightKeys.contains(key)
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        keychainService: String = KeychainCredentialsStore.defaultService
    ) {
        self.userDefaults = userDefaults
        self.keychainService = keychainService
        self.colabPreferredVideoGPU = userDefaults.string(forKey: Self.preferredVideoColabGPUKey) ?? "L4"

        let savedPort = userDefaults.integer(forKey: Self.voiceboxPortKey)
        self.voiceboxPort = (1024...65535).contains(savedPort) ? savedPort : 17495

        self.automationEnabled = userDefaults.bool(forKey: Self.automationEnabledKey)
        let savedAutoPort = userDefaults.integer(forKey: Self.automationPortKey)
        self.automationPort = (1024...65535).contains(savedAutoPort) ? savedAutoPort : 17499
        let savedAutoToken = userDefaults.string(forKey: Self.automationTokenKey) ?? ""
        if savedAutoToken.isEmpty {
            let fresh = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(32)
            self.automationToken = "klp_\(fresh)"
            userDefaults.set(self.automationToken, forKey: Self.automationTokenKey)
        } else {
            self.automationToken = savedAutoToken
        }

        // Fast, zero-disk-scan initialization so the main window appears immediately on startup without blocking MainActor!
        self.primeDefaultsWithoutDiskScan()
        self.restoreComfyModelsBookmarkIfAvailable()
        self.loadAPIConnectionConfigs()
    }

    private func primeDefaultsWithoutDiskScan() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultJobs = home.appendingPathComponent("Library/Application Support/Klipora/Jobs", isDirectory: true)
        let savedOut = userDefaults.string(forKey: "MotionDesk.defaultOutputPath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootURL = (savedOut?.isEmpty == false)
            ? URL(fileURLWithPath: (savedOut! as NSString).expandingTildeInPath, isDirectory: true)
            : defaultJobs
        self.isUsingCustomOutputRoot = (savedOut?.isEmpty == false)
        self.outputRootPath = rootURL.path
        let datedURL = datedDirectory(under: rootURL)
        self.todayDatedFolderPath = datedURL.path
        self.todayDatedFolderName = datedURL.lastPathComponent

        let savedComfyRoot = userDefaults.string(forKey: Self.comfyModelsRootKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.comfyModelsRootPath = (savedComfyRoot?.isEmpty == false)
            ? (savedComfyRoot! as NSString).expandingTildeInPath
            : home.appendingPathComponent("Documents/ComfyUI").path
        if let savedEp = userDefaults.string(forKey: Self.comfyLastDiscoveredEndpointKey), !savedEp.isEmpty {
            self.comfyConfiguredEndpoint = savedEp
        }

        let savedVBData = userDefaults.string(forKey: Self.voiceboxDataDirKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceboxDataDirPath = (savedVBData?.isEmpty == false)
            ? (savedVBData! as NSString).expandingTildeInPath
            : home.appendingPathComponent("Library/Application Support/Klipora/voicebox-data").path

        let savedVBModels = userDefaults.string(forKey: Self.voiceboxModelsDirKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceboxModelsDirPath = (savedVBModels?.isEmpty == false)
            ? (savedVBModels! as NSString).expandingTildeInPath
            : home.appendingPathComponent("Library/Application Support/Klipora/models/huggingface/hub").path

        self.colabTokenFilePath = home.appendingPathComponent(".config/colab-cli/token.json").path
    }

    // MARK: First-Run & Sheet Presentation

    var hasCompletedFirstRun: Bool {
        userDefaults.bool(forKey: Self.firstRunCompletedKey)
    }

    func checkShouldPresentFirstRun() -> Bool {
        if CommandLine.arguments.contains("--skip-first-run") {
            return false
        }
        return !hasCompletedFirstRun
    }

    func triggerFirstRunIfNeeded(app: Studio) {
        guard checkShouldPresentFirstRun() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.checkShouldPresentFirstRun() else { return }
            self.openSetupSheet(firstRun: true, app: app)
        }
    }

    func openSetupSheet(firstRun: Bool = false, app: Studio? = nil) {
        isFirstRunMode = firstRun
        isSheetPresented = true
        refreshAllLocalStates(app: app, userInitiated: false)
    }

    func dismissForLater() {
        localRefreshGeneration &+= 1
        localRefreshTask?.cancel()
        localRefreshWatchdogTask?.cancel()
        isRefreshingLocalStates = false
        localRefreshTimedOut = false
        isSheetPresented = false
        statusBannerMessage = "已暫存目前設定，可隨時從頂部「元件與連線設定」重新開啟。"
    }

    func markFirstRunCompleted() {
        localRefreshGeneration &+= 1
        localRefreshTask?.cancel()
        localRefreshWatchdogTask?.cancel()
        isRefreshingLocalStates = false
        localRefreshTimedOut = false
        userDefaults.set(true, forKey: Self.firstRunCompletedKey)
        isFirstRunMode = false
        isSheetPresented = false
        statusBannerMessage = "已完成環境與連線設定。"
    }

    func resetFirstRunFlagForTesting() {
        userDefaults.removeObject(forKey: Self.firstRunCompletedKey)
        isFirstRunMode = true
    }

    // MARK: Four-Pillar Summary Computation

    var fourPillarSummary: FourPillarCapabilitySummary {
        // 1. Runtime available
        let runtimeBadge: ComponentReadinessBadge
        if !isAppleSiliconHost {
            runtimeBadge = .warning("非 Apple Silicon 架構")
        } else if voiceboxRuntimeSource != .missing && ffmpegResolvedPath != nil {
            runtimeBadge = .ready("語音 + FFmpeg + Node 可用")
        } else if voiceboxRuntimeSource != .missing || ffmpegResolvedPath != nil {
            runtimeBadge = .reusable("部分本機執行檔可用")
        } else {
            runtimeBadge = .optionalMissing("待設定語音或 FFmpeg")
        }

        // 2. Cloud Login & API (Honest: file presence != verified session; OAuth Colab != API keys != browser login)
        let hfCfg = apiConnections[.huggingface]
        let hfHasKey = hfCfg?.hasStoredCredential == true
        let hfVerified = hfCfg?.testSucceeded == true
        let openAIHasKey = apiConnections[.openai_image]?.hasStoredCredential == true
        let geminiHasKey = apiConnections[.gemini_image]?.hasStoredCredential == true
        let colabVerified = (colabAuthVerified == true)
        let accountBadge: ComponentReadinessBadge
        if colabAuthVerified == false {
            accountBadge = .warning("Colab 授權未通過")
        } else if colabVerified && hfVerified {
            accountBadge = .ready("Colab 與 HF 已線上驗證")
        } else if colabVerified {
            accountBadge = .ready("Colab 已線上驗證")
        } else if hfVerified && !colabTokenFileExists {
            accountBadge = .ready("HF 金鑰已驗證")
        } else if colabTokenFileExists {
            accountBadge = .neutral("Colab 授權檔已找到，尚未線上檢查")
        } else if hfHasKey || openAIHasKey || geminiHasKey {
            accountBadge = .neutral("已存選用 API 金鑰（本機免登入）")
        } else {
            accountBadge = .neutral("未設定（本機功能免登入）")
        }

        // 3. Model installed (Ready models always show ready green check, never failure/warning icon)
        let completeVoiceboxModels = voiceboxModelItems.filter(\.isComplete).count
        let modelBadge: ComponentReadinessBadge
        if completeVoiceboxModels > 0 && comfyModelsDirectoryExists && comfyDetectedModelFilesCount > 0 {
            modelBadge = .ready("語音 (\(completeVoiceboxModels)組) + 繪圖 (\(comfyDetectedModelFilesCount)檔)")
        } else if completeVoiceboxModels > 0 {
            modelBadge = .ready("語音模型就緒 (\(completeVoiceboxModels)組)")
        } else if comfyModelsDirectoryExists && comfyDetectedModelFilesCount > 0 {
            modelBadge = .ready("繪圖模型就緒 (\(comfyDetectedModelFilesCount)檔)")
        } else {
            modelBadge = .optionalMissing("尚未偵測模型（選用）")
        }

        // 4. Engine ready
        let voiceboxAPIReady = apiConnections[.voicebox_api]?.testSucceeded == true
        let engineBadge: ComponentReadinessBadge
        if comfyEndpointReachable && voiceboxAPIReady {
            engineBadge = .ready("繪圖與語音服務皆就緒")
        } else if voiceboxAPIReady {
            engineBadge = .ready("語音服務已連線")
        } else if comfyEndpointReachable {
            engineBadge = .ready("ComfyUI 服務已連線")
        } else {
            engineBadge = .neutral("待命（按需自動啟動）")
        }

        return FourPillarCapabilitySummary(
            runtimeAvailable: runtimeBadge,
            accountAuthenticated: accountBadge,
            modelInstalled: modelBadge,
            engineReady: engineBadge
        )
    }

    // MARK: Master Fast Non-Destructive Local Inspection

    private struct LocalInspectionSnapshot: Sendable {
        let hostArchitecture: String
        let isAppleSiliconHost: Bool
        let bundledNodeReady: Bool
        let bundledNodePath: String?
        let bundledHyperFramesReady: Bool
        let bundledTextRenderReady: Bool
        let bundledTextRenderPath: String?
        let ffmpegResolvedPath: String?
        let ffprobeResolvedPath: String?
        let ffmpegSourceDescription: String
        let ffmpegIsHomebrewLinked: Bool

        let outputRootPath: String
        let todayDatedFolderPath: String
        let todayDatedFolderName: String
        let outputRootFreeBytes: Int64?
        let outputRootWritable: Bool
        let isUsingCustomOutputRoot: Bool

        let comfyModelsRootPath: String
        let didScanComfyModels: Bool
        let comfyModelsDirectoryExists: Bool
        let comfyDesktopAppPath: String?
        let comfyRuntimePythonPath: String?
        let comfyDetectedModelFilesCount: Int
        let comfyDetectedModelCategories: [String]

        let voiceboxRuntimeSource: VoiceboxRuntimeSourceKind
        let voiceboxBinaryPath: String?
        let voiceboxBinarySizeBytes: Int64
        let voiceboxBinaryArchitecture: String
        let voiceboxBackendPatchesPresent: Bool
        let voiceboxBackendPatchesPath: String?
        let voiceboxDataDirPath: String
        let voiceboxDatabaseExists: Bool
        let voiceboxProfileCountEstimate: Int
        let voiceboxDataDirSizeBytes: Int64
        let voiceboxModelsDirPath: String
        let voiceboxModelsDirFreeBytes: Int64?
        let voiceboxModelItems: [VoiceboxModelCacheItem]

        let colabBinaryPath: String?
        let colabTokenFilePath: String
        let colabTokenFileExists: Bool
    }

    private nonisolated static func simulateBlockingFileSystemDelay(_ seconds: Double) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }

    private nonisolated static func computeLocalInspectionSnapshot(
        bundleURL: URL,
        homeURL: URL,
        savedOutputPath: String?,
        savedComfyRoot: String?,
        scanComfyModelsDirectory: Bool,
        savedVoiceboxDataDir: String?,
        savedVoiceboxModelsDir: String?,
        customFFmpegPath: String?
    ) -> LocalInspectionSnapshot {
        let fm = FileManager.default

        #if arch(arm64)
        let hostArch = "arm64 · Apple Silicon"
        let isAppleSilicon = true
        #elseif arch(x86_64)
        let hostArch = "x86_64 · Intel Mac（不支援 MLX 本地語音推論）"
        let isAppleSilicon = false
        #else
        let hostArch = "未知架構"
        let isAppleSilicon = false
        #endif

        // 1. Bundled runtimes & FFmpeg
        let nodeInBundle = bundleURL.appendingPathComponent("Contents/Resources/runtime/node/bin/node")
        let hfInBundle = bundleURL.appendingPathComponent("Contents/Resources/runtime/hyperframes")
        let textRenderInBundle = bundleURL.appendingPathComponent("Contents/Resources/textrender")

        let nodeReady = fm.isExecutableFile(atPath: nodeInBundle.path)
        let nodePath = nodeReady ? nodeInBundle.path : nil
        let hfReady = fm.fileExists(atPath: hfInBundle.path)
        let trReady = fm.isExecutableFile(atPath: textRenderInBundle.path)
        let trPath = trReady ? textRenderInBundle.path : nil

        let bundledFFmpeg = bundleURL.appendingPathComponent("Contents/Resources/runtime/bin/ffmpeg").path
        let bundledFFprobe = bundleURL.appendingPathComponent("Contents/Resources/runtime/bin/ffprobe").path

        var resolvedFFmpeg: String? = nil
        var ffmpegSourceDesc = "未找到"
        var ffmpegIsBrew = false

        let trimmedFF = customFFmpegPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedFF, !trimmedFF.isEmpty, fm.isExecutableFile(atPath: trimmedFF) {
            resolvedFFmpeg = trimmedFF
            ffmpegSourceDesc = "自訂路徑"
            ffmpegIsBrew = trimmedFF.hasPrefix("/opt/homebrew") || trimmedFF.hasPrefix("/usr/local/Cellar")
        } else if fm.isExecutableFile(atPath: bundledFFmpeg) {
            resolvedFFmpeg = bundledFFmpeg
            ffmpegSourceDesc = "App 內建"
            ffmpegIsBrew = false
        } else if fm.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            resolvedFFmpeg = "/opt/homebrew/bin/ffmpeg"
            ffmpegSourceDesc = "系統 Homebrew"
            ffmpegIsBrew = true
        } else if fm.isExecutableFile(atPath: "/usr/local/bin/ffmpeg") {
            resolvedFFmpeg = "/usr/local/bin/ffmpeg"
            ffmpegSourceDesc = "系統 /usr/local"
            ffmpegIsBrew = true
        }

        let resolvedFFprobe: String?
        if fm.isExecutableFile(atPath: bundledFFprobe) {
            resolvedFFprobe = bundledFFprobe
        } else if let ff = resolvedFFmpeg {
            let siblingProbe = URL(fileURLWithPath: ff).deletingLastPathComponent().appendingPathComponent("ffprobe").path
            if fm.isExecutableFile(atPath: siblingProbe) {
                resolvedFFprobe = siblingProbe
            } else {
                resolvedFFprobe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: { fm.isExecutableFile(atPath: $0) })
            }
        } else {
            resolvedFFprobe = nil
        }

        // 2. Output Root & Dated Storage (runs off MainActor so cloud/network volumes never stall UI)
        let fallbackJobs = homeURL.appendingPathComponent("Library/Application Support/Klipora/Jobs", isDirectory: true)
        let trimmedOut = savedOutputPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outRootURL: URL
        let usingCustomOut: Bool
        if let trimmedOut, !trimmedOut.isEmpty {
            outRootURL = URL(fileURLWithPath: (trimmedOut as NSString).expandingTildeInPath, isDirectory: true)
            usingCustomOut = true
        } else {
            outRootURL = fallbackJobs
            usingCustomOut = false
        }
        let datedURL = datedDirectory(under: outRootURL)
        let outFreeBytes = setupAvailableDiskSpaceBytes(for: outRootURL)
        let outWritable: Bool
        if fm.fileExists(atPath: outRootURL.path) {
            outWritable = fm.isWritableFile(atPath: outRootURL.path)
        } else {
            outWritable = fm.isWritableFile(atPath: outRootURL.deletingLastPathComponent().path)
        }

        // 3. Local ComfyUI (Respect TCC ~/Documents: skip deep ~/Documents enumeration unless scanComfyModelsDirectory is true or path is outside ~/Documents)
        let defaultComfyRoot = homeURL.appendingPathComponent("Documents/ComfyUI", isDirectory: true)
        let trimmedComfy = savedComfyRoot?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comfyRootURL: URL
        if let trimmedComfy, !trimmedComfy.isEmpty {
            comfyRootURL = URL(fileURLWithPath: (trimmedComfy as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            comfyRootURL = defaultComfyRoot
        }

        let appCandidates = [
            "/Applications/Comfy Desktop.app",
            "/Applications/ComfyUI.app",
            homeURL.appendingPathComponent("Applications/Comfy Desktop.app").path,
            homeURL.appendingPathComponent("Applications/ComfyUI.app").path
        ]
        let detectedComfyApp = appCandidates.first(where: { fm.fileExists(atPath: $0) })

        let documentsPrefix = homeURL.appendingPathComponent("Documents").path
        let isInsideTCCProtectedDocuments = comfyRootURL.path.hasPrefix(documentsPrefix)
        let shouldScanComfyDir = scanComfyModelsDirectory || !isInsideTCCProtectedDocuments

        var comfyDirExists = false
        var totalComfyModels = 0
        var populatedComfyCategories: [String] = []
        var detectedComfyPython: String? = nil

        let homeVenvPy = homeURL.appendingPathComponent("ComfyUI-Installs/ComfyUI-MPS/ComfyUI/.venv/bin/python3").path
        if fm.isExecutableFile(atPath: homeVenvPy) {
            detectedComfyPython = homeVenvPy
        }

        if shouldScanComfyDir && !Task.isCancelled {
            let modelsSubdir = comfyRootURL.appendingPathComponent("models", isDirectory: true)
            var isDir: ObjCBool = false
            let subExists = fm.fileExists(atPath: modelsSubdir.path, isDirectory: &isDir) && isDir.boolValue
            let effectiveModelsDir = subExists ? modelsSubdir : comfyRootURL
            var rootIsDir: ObjCBool = false
            let rootExists = fm.fileExists(atPath: comfyRootURL.path, isDirectory: &rootIsDir) && rootIsDir.boolValue
            comfyDirExists = subExists || rootExists

            let categoryFolders = ["checkpoints", "diffusion_models", "unet", "text_encoders", "clip", "vae", "loras"]
            let weightExts: Set<String> = ["safetensors", "ckpt", "pt", "pth", "bin", "gguf", "onnx"]
            if comfyDirExists {
                for category in categoryFolders {
                    if Task.isCancelled { break }
                    let catURL = effectiveModelsDir.appendingPathComponent(category, isDirectory: true)
                    guard let items = try? fm.contentsOfDirectory(
                        at: catURL,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) else {
                        continue
                    }
                    let matchedCount = items.prefix(500).filter { weightExts.contains($0.pathExtension.lowercased()) }.count
                    if matchedCount > 0 {
                        totalComfyModels += matchedCount
                        populatedComfyCategories.append("\(category) (\(matchedCount))")
                    }
                }
            }
            if detectedComfyPython == nil {
                let rootPy = comfyRootURL.appendingPathComponent(".venv/bin/python3").path
                if fm.isExecutableFile(atPath: rootPy) {
                    detectedComfyPython = rootPy
                }
            }
        }

        // 4. Voicebox Runtime, Data Dir & HF Model Cache
        let bundledBinary = bundleURL.appendingPathComponent("Contents/MacOS/voicebox-server")
        let bundledPatchesDir = bundleURL.appendingPathComponent("Contents/Resources/backend-patches")
        let installedAppBinary = URL(fileURLWithPath: "/Applications/Voicebox.app/Contents/MacOS/voicebox-server")
        let installedAppPatchesDir = URL(fileURLWithPath: "/Applications/Voicebox.app/Contents/Resources/backend-patches")
        let requiredPatchFiles = ["mlx_backend.py", "mlx_worker.py", "qwen_custom_voice_backend.py"]

        let vbSource: VoiceboxRuntimeSourceKind
        let vbBinPath: String?
        let vbBinSize: Int64
        let vbBinArch: String
        let vbPatchesPresent: Bool
        let vbPatchesPath: String?

        if fm.isExecutableFile(atPath: bundledBinary.path) {
            vbSource = .bundledInApp
            vbBinPath = bundledBinary.path
            let attrs = try? fm.attributesOfItem(atPath: bundledBinary.path)
            vbBinSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            vbBinArch = Self.detectMachOArchitecture(atPath: bundledBinary.path)
            vbPatchesPresent = requiredPatchFiles.allSatisfy {
                fm.fileExists(atPath: bundledPatchesDir.appendingPathComponent($0).path)
            }
            vbPatchesPath = bundledPatchesDir.path
        } else if fm.isExecutableFile(atPath: installedAppBinary.path) {
            vbSource = .reusedInstalledApp
            vbBinPath = installedAppBinary.path
            let attrs = try? fm.attributesOfItem(atPath: installedAppBinary.path)
            vbBinSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            vbBinArch = Self.detectMachOArchitecture(atPath: installedAppBinary.path)
            vbPatchesPresent = requiredPatchFiles.allSatisfy {
                fm.fileExists(atPath: installedAppPatchesDir.appendingPathComponent($0).path)
            }
            vbPatchesPath = installedAppPatchesDir.path
        } else {
            vbSource = .missing
            vbBinPath = nil
            vbBinSize = 0
            vbBinArch = "未安裝"
            vbPatchesPresent = false
            vbPatchesPath = nil
        }

        let trimmedVBData = savedVoiceboxDataDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingVoiceboxAppSupport = homeURL.appendingPathComponent("Library/Application Support/Klipora/voicebox-data", isDirectory: true)
        let cleanMotionDeskVoiceboxData = homeURL.appendingPathComponent("Library/Application Support/Klipora/voicebox-data", isDirectory: true)

        let resolvedVBDataDir: URL
        if let trimmedVBData, !trimmedVBData.isEmpty {
            resolvedVBDataDir = URL(fileURLWithPath: (trimmedVBData as NSString).expandingTildeInPath, isDirectory: true)
        } else if fm.fileExists(atPath: existingVoiceboxAppSupport.appendingPathComponent("voicebox.db").path)
                    || fm.fileExists(atPath: existingVoiceboxAppSupport.appendingPathComponent("profiles").path) {
            resolvedVBDataDir = existingVoiceboxAppSupport
        } else {
            resolvedVBDataDir = cleanMotionDeskVoiceboxData
        }

        let vbDBExists = fm.fileExists(atPath: resolvedVBDataDir.appendingPathComponent("voicebox.db").path)
        let profilesDir = resolvedVBDataDir.appendingPathComponent("profiles", isDirectory: true)
        let vbProfileEstimate = (try? fm.contentsOfDirectory(atPath: profilesDir.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
        let vbDataSize = Task.isCancelled ? 0 : setupDirectoryDiskBytes(at: resolvedVBDataDir, maxFiles: 400)

        let trimmedVBModels = savedVoiceboxModelsDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultHFHubCache = homeURL.appendingPathComponent("Library/Application Support/Klipora/models/huggingface/hub", isDirectory: true)
        let resolvedVBModelsDir: URL
        if let trimmedVBModels, !trimmedVBModels.isEmpty {
            resolvedVBModelsDir = URL(fileURLWithPath: (trimmedVBModels as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            resolvedVBModelsDir = defaultHFHubCache
        }
        let vbModelsFree = Task.isCancelled ? nil : setupAvailableDiskSpaceBytes(for: resolvedVBModelsDir)
        let vbModels = Task.isCancelled ? [] : Self.inspectQwenModelCache(in: resolvedVBModelsDir)

        // 5. Google Colab CLI & Token File
        let colabCandidates = [
            homeURL.appendingPathComponent(".local/bin/colab").path,
            "/opt/homebrew/bin/colab",
            "/usr/local/bin/colab"
        ]
        let detectedColabBin = colabCandidates.first(where: { fm.isExecutableFile(atPath: $0) })
        let tokenURL = homeURL.appendingPathComponent(".config/colab-cli/token.json")
        let tokenExists: Bool
        if let attrs = try? fm.attributesOfItem(atPath: tokenURL.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value,
           size > 16 {
            tokenExists = true
        } else {
            tokenExists = false
        }

        return LocalInspectionSnapshot(
            hostArchitecture: hostArch,
            isAppleSiliconHost: isAppleSilicon,
            bundledNodeReady: nodeReady,
            bundledNodePath: nodePath,
            bundledHyperFramesReady: hfReady,
            bundledTextRenderReady: trReady,
            bundledTextRenderPath: trPath,
            ffmpegResolvedPath: resolvedFFmpeg,
            ffprobeResolvedPath: resolvedFFprobe,
            ffmpegSourceDescription: ffmpegSourceDesc,
            ffmpegIsHomebrewLinked: ffmpegIsBrew,
            outputRootPath: outRootURL.path,
            todayDatedFolderPath: datedURL.path,
            todayDatedFolderName: datedURL.lastPathComponent,
            outputRootFreeBytes: outFreeBytes,
            outputRootWritable: outWritable,
            isUsingCustomOutputRoot: usingCustomOut,
            comfyModelsRootPath: comfyRootURL.path,
            didScanComfyModels: shouldScanComfyDir,
            comfyModelsDirectoryExists: comfyDirExists,
            comfyDesktopAppPath: detectedComfyApp,
            comfyRuntimePythonPath: detectedComfyPython,
            comfyDetectedModelFilesCount: totalComfyModels,
            comfyDetectedModelCategories: populatedComfyCategories,
            voiceboxRuntimeSource: vbSource,
            voiceboxBinaryPath: vbBinPath,
            voiceboxBinarySizeBytes: vbBinSize,
            voiceboxBinaryArchitecture: vbBinArch,
            voiceboxBackendPatchesPresent: vbPatchesPresent,
            voiceboxBackendPatchesPath: vbPatchesPath,
            voiceboxDataDirPath: resolvedVBDataDir.path,
            voiceboxDatabaseExists: vbDBExists,
            voiceboxProfileCountEstimate: vbProfileEstimate,
            voiceboxDataDirSizeBytes: vbDataSize,
            voiceboxModelsDirPath: resolvedVBModelsDir.path,
            voiceboxModelsDirFreeBytes: vbModelsFree,
            voiceboxModelItems: vbModels,
            colabBinaryPath: detectedColabBin,
            colabTokenFilePath: tokenURL.path,
            colabTokenFileExists: tokenExists
        )
    }

    private func applyLocalInspectionSnapshot(_ snap: LocalInspectionSnapshot) {
        self.hostArchitecture = snap.hostArchitecture
        self.isAppleSiliconHost = snap.isAppleSiliconHost
        self.bundledNodeReady = snap.bundledNodeReady
        self.bundledNodePath = snap.bundledNodePath
        self.bundledHyperFramesReady = snap.bundledHyperFramesReady
        self.bundledTextRenderReady = snap.bundledTextRenderReady
        self.bundledTextRenderPath = snap.bundledTextRenderPath
        self.ffmpegResolvedPath = snap.ffmpegResolvedPath
        self.ffprobeResolvedPath = snap.ffprobeResolvedPath
        self.ffmpegSourceDescription = snap.ffmpegSourceDescription
        self.ffmpegIsHomebrewLinked = snap.ffmpegIsHomebrewLinked

        self.outputRootPath = snap.outputRootPath
        self.todayDatedFolderPath = snap.todayDatedFolderPath
        self.todayDatedFolderName = snap.todayDatedFolderName
        self.outputRootFreeBytes = snap.outputRootFreeBytes
        self.outputRootWritable = snap.outputRootWritable
        self.isUsingCustomOutputRoot = snap.isUsingCustomOutputRoot

        self.comfyModelsRootPath = snap.comfyModelsRootPath
        self.comfyDesktopAppPath = snap.comfyDesktopAppPath
        if snap.didScanComfyModels {
            self.comfyModelsDirectoryExists = snap.comfyModelsDirectoryExists
            self.comfyDetectedModelFilesCount = snap.comfyDetectedModelFilesCount
            self.comfyDetectedModelCategories = snap.comfyDetectedModelCategories
            self.comfyRuntimePythonPath = snap.comfyRuntimePythonPath
        } else if self.comfyRuntimePythonPath == nil {
            self.comfyRuntimePythonPath = snap.comfyRuntimePythonPath
        }

        self.voiceboxRuntimeSource = snap.voiceboxRuntimeSource
        self.voiceboxBinaryPath = snap.voiceboxBinaryPath
        self.voiceboxBinarySizeBytes = snap.voiceboxBinarySizeBytes
        self.voiceboxBinaryArchitecture = snap.voiceboxBinaryArchitecture
        self.voiceboxBackendPatchesPresent = snap.voiceboxBackendPatchesPresent
        self.voiceboxBackendPatchesPath = snap.voiceboxBackendPatchesPath
        self.voiceboxDataDirPath = snap.voiceboxDataDirPath
        self.voiceboxDatabaseExists = snap.voiceboxDatabaseExists
        self.voiceboxProfileCountEstimate = snap.voiceboxProfileCountEstimate
        self.voiceboxDataDirSizeBytes = snap.voiceboxDataDirSizeBytes
        self.voiceboxModelsDirPath = snap.voiceboxModelsDirPath
        self.voiceboxModelsDirFreeBytes = snap.voiceboxModelsDirFreeBytes
        if !snap.voiceboxModelItems.isEmpty {
            self.voiceboxModelItems = snap.voiceboxModelItems
        }

        self.colabBinaryPath = snap.colabBinaryPath
        self.colabTokenFilePath = snap.colabTokenFilePath
        self.colabTokenFileExists = snap.colabTokenFileExists
        if snap.colabTokenFileExists {
            if self.colabAuthVerified == nil {
                self.colabAuthCheckSummary = "已偵測到本機憑證檔，待驗證（點選「檢查登入與額度」確認；開啟設定不配置雲端 GPU）"
            }
        } else {
            self.colabAuthVerified = nil
            self.colabAuthCheckSummary = "尚未登入 Google Colab（本機剪輯與配音免登入）"
        }
        self.lastLocalRefreshAt = Date()
    }

    /// Performs non-blocking, cancellable, bounded background inspection of local paths and caches.
    /// Never blocks `@MainActor` on `contentsOfDirectory`, `fileExists`, or volume statistics!
    /// Never launches models, allocates GPUs, starts downloads, or initiates network auth.
    func refreshAllLocalStates(app: Studio? = nil, userInitiated: Bool = false) {
        if !userInitiated,
           let last = lastLocalRefreshAt,
           Date().timeIntervalSince(last) < 2.0 {
            refreshKeychainStatuses(app: app)
            return
        }

        if let app, !app.endpoint.isEmpty {
            comfyConfiguredEndpoint = app.endpoint
        } else if let savedEndpoint = userDefaults.string(forKey: Self.comfyLastDiscoveredEndpointKey), !savedEndpoint.isEmpty {
            comfyConfiguredEndpoint = savedEndpoint
        }
        refreshKeychainStatuses(app: app)
        VoiceoverRecorderManager.shared.refreshDevicesAndPermission()

        let bundleURL = Bundle.main.bundleURL
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let savedOutputPath = app?.defaultOutputPath ?? userDefaults.string(forKey: "MotionDesk.defaultOutputPath")
        let savedComfyRoot = userDefaults.string(forKey: Self.comfyModelsRootKey)
        let savedVBData = userDefaults.string(forKey: Self.voiceboxDataDirKey)
        let savedVBModels = userDefaults.string(forKey: Self.voiceboxModelsDirKey)
        let customFFmpeg = userDefaults.string(forKey: Self.customFFmpegPathKey)
        let scanComfyModels = userInitiated

        let pathLockKey = [
            savedOutputPath ?? "default_out",
            savedComfyRoot ?? "default_comfy",
            savedVBData ?? "default_vbdata",
            savedVBModels ?? "default_vbmodels",
            scanComfyModels ? "comfy_scan" : "no_comfy_scan"
        ].joined(separator: "|")

        // Limit at most one unfinished synchronous filesystem worker per path signature so hung volumes never pile up threads.
        guard InFlightScanTracker.shared.tryAcquire(key: pathLockKey) else {
            if userInitiated {
                statusBannerMessage = "相同路徑的背景掃描仍在進行中，請稍候或更改目錄位置。"
            }
            return
        }

        localRefreshTask?.cancel()
        localRefreshWatchdogTask?.cancel()
        localRefreshGeneration &+= 1
        let expectedGeneration = localRefreshGeneration

        isRefreshingLocalStates = true
        localRefreshTimedOut = false

        let timeoutSec = max(0.1, localScanTimeoutSeconds)
        let simulatedDelaySec = max(0.0, localScanSimulatedDelaySeconds)

        // Independent MainActor watchdog: fires strictly at `timeoutSec` without awaiting synchronous FileManager I/O!
        localRefreshWatchdogTask = Task { @MainActor [weak self] in
            let sleepMs = max(50, Int((timeoutSec * 1000.0).rounded()))
            try? await Task.sleep(for: .milliseconds(sleepMs))
            guard let self, !Task.isCancelled else { return }
            guard self.localRefreshGeneration == expectedGeneration && self.isRefreshingLocalStates else { return }
            // Advance generation so any late result from the stuck worker is discarded.
            self.localRefreshGeneration &+= 1
            self.localRefreshTask?.cancel()
            self.isRefreshingLocalStates = false
            self.localRefreshTimedOut = true
            self.statusBannerMessage = String(format: "本機目錄背景掃描逾時（超過 %.1f 秒），已先行顯示快取狀態；若目錄位於雲端或網路磁碟，可稍後重試。", timeoutSec)
        }

        localRefreshTask = Task.detached(priority: .utility) { [weak self] in
            defer {
                InFlightScanTracker.shared.release(key: pathLockKey)
            }
            if simulatedDelaySec > 0 {
                Self.simulateBlockingFileSystemDelay(simulatedDelaySec)
            }
            guard !Task.isCancelled else { return }
            let snap = Self.computeLocalInspectionSnapshot(
                bundleURL: bundleURL,
                homeURL: homeURL,
                savedOutputPath: savedOutputPath,
                savedComfyRoot: savedComfyRoot,
                scanComfyModelsDirectory: scanComfyModels,
                savedVoiceboxDataDir: savedVBData,
                savedVoiceboxModelsDir: savedVBModels,
                customFFmpegPath: customFFmpeg
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.localRefreshGeneration == expectedGeneration else {
                    // Late result after watchdog timeout or newer refresh: discard cleanly!
                    return
                }
                self.localRefreshWatchdogTask?.cancel()
                self.applyLocalInspectionSnapshot(snap)
                self.localRefreshTimedOut = false
                self.isRefreshingLocalStates = false
                if userInitiated {
                    self.statusBannerMessage = "已完成本機路徑、模型快取與鑰匙圈狀態掃描。"
                }
            }
        }
    }

    // MARK: Card 1 — Output Root & Dated Storage

    func inspectOutputRoot(app: Studio? = nil) {
        let customPath = app?.defaultOutputPath ?? userDefaults.string(forKey: "MotionDesk.defaultOutputPath")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallbackJobs = home.appendingPathComponent("Library/Application Support/Klipora/Jobs", isDirectory: true)
        let rootURL: URL
        if let customPath, !customPath.isEmpty {
            rootURL = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath, isDirectory: true)
            isUsingCustomOutputRoot = true
        } else {
            rootURL = app?.defaultOutputDirectory ?? fallbackJobs
            isUsingCustomOutputRoot = false
        }
        outputRootPath = rootURL.path
        let datedURL = datedDirectory(under: rootURL)
        todayDatedFolderPath = datedURL.path
        todayDatedFolderName = datedURL.lastPathComponent
        refreshAllLocalStates(app: app, userInitiated: true)
    }

    func openTodayDatedOutputDirectory(app: Studio) {
        let datedURL = datedDirectory(under: app.defaultOutputDirectory)
        app.openOutputDirectory(datedURL)
        inspectOutputRoot(app: app)
    }

    // MARK: Card 2 — Local ComfyUI Discovery & Verification

    func inspectLocalComfyUI(app: Studio? = nil, userInitiated: Bool = true) {
        if let app {
            comfyConfiguredEndpoint = app.endpoint
        } else if let savedEndpoint = userDefaults.string(forKey: Self.comfyLastDiscoveredEndpointKey), !savedEndpoint.isEmpty {
            comfyConfiguredEndpoint = savedEndpoint
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultComfyRoot = home.appendingPathComponent("Documents/ComfyUI")
        let savedRoot = userDefaults.string(forKey: Self.comfyModelsRootKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootURL = (savedRoot?.isEmpty == false)
            ? URL(fileURLWithPath: (savedRoot! as NSString).expandingTildeInPath, isDirectory: true)
            : defaultComfyRoot
        comfyModelsRootPath = rootURL.path
        refreshAllLocalStates(app: app, userInitiated: userInitiated)
    }

    @discardableResult
    func restoreComfyModelsBookmarkIfAvailable() -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: Self.comfyModelsRootBookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if activeComfyModelsSecurityScopedURL?.path != resolved.path {
            activeComfyModelsSecurityScopedURL?.stopAccessingSecurityScopedResource()
            if resolved.startAccessingSecurityScopedResource() {
                activeComfyModelsSecurityScopedURL = resolved
            } else {
                activeComfyModelsSecurityScopedURL = nil
            }
        }
        if isStale,
           let refreshed = try? resolved.bookmarkData(
               options: [],
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            userDefaults.set(refreshed, forKey: Self.comfyModelsRootBookmarkKey)
        }
        comfyModelsRootPath = resolved.path
        return resolved
    }

    /// Returns the authorized ComfyUI models root URL if explicitly selected (and bookmark-backed when inside `~/Documents`),
    /// or `nil` if the user needs to confirm folder selection via `chooseComfyModelsRoot`.
    func resolveAuthorizedComfyModelsRoot() -> URL? {
        if let bookmarked = restoreComfyModelsBookmarkIfAvailable() {
            return bookmarked
        }
        guard let savedRoot = userDefaults.string(forKey: Self.comfyModelsRootKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !savedRoot.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: (savedRoot as NSString).expandingTildeInPath, isDirectory: true)
        let documentsPrefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path
        if url.path.hasPrefix(documentsPrefix) {
            return nil
        }
        return url
    }

    func chooseComfyModelsRoot(app: Studio, onSelected: ((URL) -> Void)? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = home.appendingPathComponent("Documents/ComfyUI", isDirectory: true)
        let initialDir = comfyModelsRootPath.isEmpty
            ? defaultDir
            : URL(fileURLWithPath: (comfyModelsRootPath as NSString).expandingTildeInPath, isDirectory: true)
        app.pickAsync(
            title: "選擇 ComfyUI 安裝或模型根目錄（包含 models 資料夾）",
            types: [],
            multiple: false,
            directory: true,
            initialDirectory: initialDir
        ) { [weak self] urls in
            guard let self, let picked = urls.first else { return }
            let resolved: URL
            if picked.lastPathComponent == "models" {
                resolved = picked.deletingLastPathComponent()
            } else {
                resolved = picked
            }
            self.activeComfyModelsSecurityScopedURL?.stopAccessingSecurityScopedResource()
            if resolved.startAccessingSecurityScopedResource() {
                self.activeComfyModelsSecurityScopedURL = resolved
            } else {
                self.activeComfyModelsSecurityScopedURL = nil
            }
            if let bookmark = try? resolved.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                self.userDefaults.set(bookmark, forKey: Self.comfyModelsRootBookmarkKey)
            }
            self.userDefaults.set(resolved.path, forKey: Self.comfyModelsRootKey)
            self.comfyModelsRootPath = resolved.path
            self.inspectLocalComfyUI(app: app, userInitiated: true)
            NotificationCenter.default.post(name: .motionDeskComfyConfigChanged, object: nil)
            app.status = "已更新並授權 ComfyUI 模型目錄 · \(resolved.path)"
            onSelected?(resolved)
        }
    }

    func resetComfyModelsRoot(app: Studio? = nil) {
        activeComfyModelsSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeComfyModelsSecurityScopedURL = nil
        userDefaults.removeObject(forKey: Self.comfyModelsRootKey)
        userDefaults.removeObject(forKey: Self.comfyModelsRootBookmarkKey)
        inspectLocalComfyUI(app: app, userInitiated: true)
        NotificationCenter.default.post(name: .motionDeskComfyConfigChanged, object: nil)
    }

    func openComfyOfficialDownloadGuide() {
        if let url = URL(string: "https://www.comfy.org/download") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Probes the configured ComfyUI endpoint and known loopback ports (8188, 8000) without assuming fixed 8188.
    /// Honest verification: checks `/system_stats`, `/object_info`, AND verifies that the local model directory exists (off MainActor with timeout).
    func probeComfyUIEndpoint(app: Studio? = nil) async {
        comfyIsProbing = true
        defer { comfyIsProbing = false }

        // Refresh ComfyUI local model count in a non-blocking background refresh with independent watchdog
        refreshAllLocalStates(app: app, userInitiated: true)
        let probeScanTimeoutMs = max(50, Int((min(1.5, localScanTimeoutSeconds) * 1000.0).rounded()))
        let waitDeadline = Date().addingTimeInterval(Double(probeScanTimeoutMs) / 1000.0)
        while isRefreshingLocalStates && Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        var candidates: [String] = []
        let configured = comfyConfiguredEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !configured.isEmpty {
            let validation = SupportedAPIProvider.comfyui_api.validateEndpointURL(configured)
            if let valid = validation.validURL {
                candidates.append(valid)
            } else {
                comfyEndpointReachable = false
                comfyServerIdentitySummary = nil
                comfyProbeMessage = validation.errorMessage ?? "僅支援本機 Loopback ComfyUI 端點。"
                return
            }
        }
        for fallback in ["http://127.0.0.1:8188", "http://127.0.0.1:8000", "http://127.0.0.1:8189"] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }

        let token = KeychainCredentialsStore.read(
            account: SupportedAPIProvider.comfyui_api.keychainAccount,
            service: keychainService
        )

        for candidate in candidates {
            guard let statsURL = URL(string: "\(candidate)/system_stats") else { continue }
            var request = URLRequest(url: statsURL)
            request.timeoutInterval = 3.0
            if let token, !token.isEmpty, candidate == configured {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await noRedirectSession.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let system = obj["system"] as? [String: Any] else {
                    continue
                }

                let comfyVer = (system["comfyui_version"] as? String) ?? "未知版本"
                let pyVer = (system["python_version"] as? String)?.components(separatedBy: " ").first ?? ""
                var deviceName = "Apple Silicon / MPS"
                if let devices = obj["devices"] as? [[String: Any]],
                   let firstDev = devices.first,
                   let name = firstDev["name"] as? String {
                    deviceName = name
                }

                var nodeCount = 0
                if let infoURL = URL(string: "\(candidate)/object_info") {
                    var infoReq = URLRequest(url: infoURL)
                    infoReq.timeoutInterval = 3.5
                    if let token, !token.isEmpty, candidate == configured {
                        infoReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    if let (infoData, infoResp) = try? await noRedirectSession.data(for: infoReq),
                       let infoHTTP = infoResp as? HTTPURLResponse, infoHTTP.statusCode == 200,
                       let infoDict = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] {
                        nodeCount = infoDict.count
                    }
                }

                comfyConfiguredEndpoint = candidate
                userDefaults.set(candidate, forKey: Self.comfyLastDiscoveredEndpointKey)
                if let app {
                    app.project.endpoint = candidate
                }
                if var comfyConfig = apiConnections[.comfyui_api] {
                    comfyConfig.serviceURL = candidate
                    apiConnections[.comfyui_api] = comfyConfig
                }

                if !comfyModelsDirectoryExists || comfyDetectedModelFilesCount == 0 {
                    comfyEndpointReachable = true
                    comfyServerIdentitySummary = "ComfyUI \(comfyVer) (\(deviceName)) · 節點 \(nodeCount) 個"
                    comfyProbeMessage = "已連線至 \(candidate)，但模型目錄尚未放入權重檔，請先設定或下載模型。"
                } else {
                    comfyEndpointReachable = true
                    comfyServerIdentitySummary = "ComfyUI \(comfyVer) · Python \(pyVer) · \(deviceName) · 節點 \(nodeCount) 個"
                    comfyProbeMessage = "端點 \(candidate) 已驗證就緒，共偵測到 \(comfyDetectedModelFilesCount) 個本地模型檔案。"
                }
                return
            } catch {
                continue
            }
        }

        comfyEndpointReachable = false
        comfyServerIdentitySummary = nil
        comfyProbeMessage = "未在 \(candidates.joined(separator: " / ")) 偵測到執行中的 ComfyUI 服務。可點選「開啟 Comfy Desktop」或由工作台按需啟動。"
    }

    // MARK: Card 3 — Voicebox Runtime, Models & Voice Library

    func inspectVoiceboxEnvironment() {
        refreshAllLocalStates(app: nil, userInitiated: true)
    }

    nonisolated static func inspectQwenModelCache(in hubDir: URL) -> [VoiceboxModelCacheItem] {
        let specs: [(id: String, name: String, repo: String, engine: String, size: String, recommended: Bool)] = [
            (
                "qwen3-1.7b-mlx-base",
                "Qwen3-TTS 1.7B Base（中文參考聲音複製首選）",
                "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
                "qwen (MLX 1.7B)",
                "約 4.2 GB",
                true
            ),
            (
                "qwen3-0.6b-mlx-base",
                "Qwen3-TTS 0.6B Base（輕量版）",
                "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16",
                "qwen (MLX 0.6B)",
                "約 2.5 GB",
                false
            ),
            (
                "qwen3-1.7b-customvoice",
                "Qwen3 CustomVoice 1.7B（內建多語角色聲線）",
                "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
                "qwen_custom_voice (1.7B)",
                "約 4.2 GB",
                true
            ),
            (
                "qwen3-0.6b-customvoice",
                "Qwen3 CustomVoice 0.6B（內建角色輕量版）",
                "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
                "qwen_custom_voice (0.6B)",
                "約 2.5 GB",
                false
            )
        ]

        let fm = FileManager.default
        return specs.map { spec in
            let folderName = "models--" + spec.repo.replacingOccurrences(of: "/", with: "--")
            let repoDir = hubDir.appendingPathComponent(folderName, isDirectory: true)
            let blobsDir = repoDir.appendingPathComponent("blobs", isDirectory: true)
            let snapshotsDir = repoDir.appendingPathComponent("snapshots", isDirectory: true)

            guard fm.fileExists(atPath: repoDir.path) else {
                return VoiceboxModelCacheItem(
                    id: spec.id,
                    displayName: spec.name,
                    repoID: spec.repo,
                    engineLabel: spec.engine,
                    expectedSizeDescription: spec.size,
                    requiresSpeechTokenizer: true,
                    isRecommendedForChinese: spec.recommended,
                    isComplete: false,
                    hasIncompleteBlobs: false,
                    mainWeightsPresent: false,
                    speechTokenizerPresent: false,
                    diskSizeBytes: 0,
                    snapshotPath: nil,
                    statusNote: "尚未下載"
                )
            }

            var hasIncomplete = false
            if let blobFiles = try? fm.contentsOfDirectory(atPath: blobsDir.path) {
                hasIncomplete = blobFiles.contains(where: { $0.hasSuffix(".incomplete") || $0.hasSuffix(".lock") })
            }

            var foundMainWeights = false
            var foundSpeechTokenizer = false
            var activeSnapshotPath: String? = nil

            if let snaps = try? fm.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for snap in snaps {
                    let mainModel = snap.appendingPathComponent("model.safetensors")
                    let mainIndex = snap.appendingPathComponent("model.safetensors.index.json")
                    let tokModel = snap.appendingPathComponent("speech_tokenizer/model.safetensors")

                    let mainOK = fm.fileExists(atPath: mainModel.path) || fm.fileExists(atPath: mainIndex.path)
                    let tokOK = fm.fileExists(atPath: tokModel.path)

                    if mainOK { foundMainWeights = true }
                    if tokOK { foundSpeechTokenizer = true }
                    if mainOK && tokOK {
                        activeSnapshotPath = snap.path
                        break
                    } else if activeSnapshotPath == nil {
                        activeSnapshotPath = snap.path
                    }
                }
            }

            let diskBytes = setupDirectoryDiskBytes(at: repoDir, maxFiles: 400)
            let complete = foundMainWeights && foundSpeechTokenizer && !hasIncomplete && diskBytes > 50_000_000

            let note: String
            if complete {
                note = "完整可用"
            } else if hasIncomplete {
                note = "下載未完成（可於配音面板續傳）"
            } else if foundMainWeights && !foundSpeechTokenizer {
                note = "缺少語音分詞器子元件"
            } else {
                note = "快取不完整，需重新驗證下載"
            }

            return VoiceboxModelCacheItem(
                id: spec.id,
                displayName: spec.name,
                repoID: spec.repo,
                engineLabel: spec.engine,
                expectedSizeDescription: spec.size,
                requiresSpeechTokenizer: true,
                isRecommendedForChinese: spec.recommended,
                isComplete: complete,
                hasIncompleteBlobs: hasIncomplete,
                mainWeightsPresent: foundMainWeights,
                speechTokenizerPresent: foundSpeechTokenizer,
                diskSizeBytes: diskBytes,
                snapshotPath: activeSnapshotPath,
                statusNote: note
            )
        }
    }

    func chooseVoiceboxDataDirectory(app: Studio) {
        app.pickAsync(title: "選擇語音角色庫與歷史紀錄資料夾", types: [], multiple: false, directory: true) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.userDefaults.set(url.path, forKey: Self.voiceboxDataDirKey)
            self.inspectVoiceboxEnvironment()
            NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
            app.status = "已設定語音角色庫位置 · \(url.path)"
        }
    }

    func switchToCleanVoiceboxDataDirectory(app: Studio? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cleanURL = home.appendingPathComponent("Library/Application Support/Klipora/voicebox-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: cleanURL, withIntermediateDirectories: true)
        userDefaults.set(cleanURL.path, forKey: Self.voiceboxDataDirKey)
        inspectVoiceboxEnvironment()
        NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
        app?.status = "已切換至獨立空白聲音庫 · \(cleanURL.path)"
    }

    func reuseExistingVoiceboxAppSupportDirectory(app: Studio? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let existingURL = home.appendingPathComponent("Library/Application Support/sh.voicebox.app", isDirectory: true)
        userDefaults.set(existingURL.path, forKey: Self.voiceboxDataDirKey)
        inspectVoiceboxEnvironment()
        NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
        app?.status = "已重用既有聲音庫 · \(existingURL.path)"
    }

    func chooseVoiceboxModelsCacheDirectory(app: Studio) {
        app.pickAsync(title: "選擇 HuggingFace 模型快取目錄（hub 資料夾）", types: [], multiple: false, directory: true) { [weak self] urls in
            guard let self, let picked = urls.first else { return }
            let hubCandidate = picked.appendingPathComponent("hub", isDirectory: true)
            let resolved = FileManager.default.fileExists(atPath: hubCandidate.path) ? hubCandidate : picked
            self.userDefaults.set(resolved.path, forKey: Self.voiceboxModelsDirKey)
            self.inspectVoiceboxEnvironment()
            NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
            app.status = "已設定模型快取目錄 · \(resolved.path)"
        }
    }

    func resetVoiceboxModelsCacheDirectory(app: Studio? = nil) {
        userDefaults.removeObject(forKey: Self.voiceboxModelsDirKey)
        inspectVoiceboxEnvironment()
        NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
        app?.status = "已恢復預設 HuggingFace 模型快取位置"
    }

    func openOfficialQwenModelCollection() {
        if let url = URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Card 4 — Google Colab Detection & Safe Auth Handoff

    func inspectGoogleColabCLI() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/colab").path,
            "/opt/homebrew/bin/colab",
            "/usr/local/bin/colab"
        ]
        colabBinaryPath = candidates.first(where: { fm.isExecutableFile(atPath: $0) })

        let tokenURL = home.appendingPathComponent(".config/colab-cli/token.json")
        colabTokenFilePath = tokenURL.path
        if let attrs = try? fm.attributesOfItem(atPath: tokenURL.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value,
           size > 16 {
            colabTokenFileExists = true
            if colabAuthVerified == nil {
                colabAuthCheckSummary = "已偵測到本機憑證檔，待驗證（點選「檢查登入與額度」確認；開啟設定不配置雲端 GPU）"
            }
        } else {
            colabTokenFileExists = false
            colabAuthVerified = nil
            colabAuthCheckSummary = "尚未登入 Google Colab（本機剪輯與配音免登入）"
        }
    }

    func setPreferredVideoColabGPU(_ gpu: String, app: Studio? = nil) {
        colabPreferredVideoGPU = gpu
        userDefaults.set(gpu, forKey: Self.preferredVideoColabGPUKey)
        if let app {
            app.project.cloudGPU = gpu
            app.status = "已設定雲端影片生成預設 GPU · \(gpu)"
        }
    }

    /// Checks Colab CLI login and quota status WITHOUT printing or logging any token text, and WITHOUT allocating a GPU.
    func checkColabLoginStatus() async {
        inspectGoogleColabCLI()
        guard let binary = colabBinaryPath else {
            colabAuthVerified = nil
            colabAuthCheckSummary = "未安裝 colab CLI（本機剪輯與配音不受影響）。"
            return
        }
        colabIsCheckingAuth = true
        defer { colabIsCheckingAuth = false }

        let result = await Self.runBoundedCommand(
            executable: binary,
            arguments: ["usage"],
            timeoutSeconds: 8.0
        )

        if result.timedOut {
            colabAuthVerified = nil
            colabAuthCheckSummary = "連線檢查逾時（8 秒）。目前僅偵測到本機憑證檔，尚未完成線上驗證。"
            return
        }

        let sanitizedOutput = Self.sanitizeCLIOutput(result.stdout + "\n" + result.stderr)
        if result.terminationStatus == 0 {
            colabAuthVerified = true
            let firstLines = sanitizedOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(2)
                .joined(separator: " · ")
            colabAuthCheckSummary = firstLines.isEmpty
                ? "已登入（Google Colab 帳號線上驗證通過，僅在生成時配置 GPU）。"
                : "已登入（線上驗證通過）：\(firstLines)"
        } else {
            colabAuthVerified = false
            colabAuthCheckSummary = "憑證未通過線上驗證或已過期（\(sanitizedOutput.prefix(120))）。請點選「啟動瀏覽器登入」重新授權。"
        }
    }

    func resolveBundledColabLoginScriptURL() -> URL? {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("h3/scripts/colab_login.py")
            if fm.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        let devStaged = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("studio-v5/staged/resources/h3/scripts/colab_login.py")
        if fm.fileExists(atPath: devStaged.path) {
            return devStaged
        }
        return nil
    }

    /// Launches the supported two-step Google Colab OAuth browser flow via bundled `h3/scripts/colab_login.py url`.
    func startColabBrowserAuthentication() {
        inspectGoogleColabCLI()
        guard colabBinaryPath != nil else {
            colabAuthCheckSummary = "找不到 colab CLI（~/.local/bin/colab），請先安裝 google-colab-cli。"
            return
        }
        guard let scriptURL = resolveBundledColabLoginScriptURL() else {
            colabAuthCheckSummary = "找不到內建 colab_login.py 授權腳本。"
            return
        }
        guard !colabIsLaunchingAuth else { return }

        colabIsLaunchingAuth = true
        colabAuthCheckSummary = "正在產生 Google OAuth 授權網址（可隨時取消）…"

        Task { @MainActor in
            let res = await Self.runBoundedCommand(
                executable: "/usr/bin/python3",
                arguments: [scriptURL.path, "url"],
                timeoutSeconds: 12.0
            )
            self.colabIsLaunchingAuth = false
            if res.timedOut {
                self.colabAuthCheckSummary = "產生 Google OAuth 授權網址逾時（12 秒），請點選重試。"
                return
            }
            let combined = (res.stdout + "\n" + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if res.terminationStatus == 0,
               let authURLLine = combined.components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.hasPrefix("https://accounts.google.com/") || $0.hasPrefix("https://") }) {
                self.colabPendingAuthURL = authURLLine
                self.showCard4Details = true
                if let url = URL(string: authURLLine) {
                    NSWorkspace.shared.open(url)
                }
                self.colabAuthCheckSummary = "已於瀏覽器開啟 Google 授權頁面；完成授權後請將授權碼貼入下方欄位。"
            } else {
                let sanitized = Self.sanitizeCLIOutput(combined)
                self.colabAuthCheckSummary = "無法取得 Google OAuth 授權網址（代碼 \(res.terminationStatus)）：\(sanitized.prefix(160))"
            }
        }
    }

    func submitColabAuthorizationCode() {
        let code = colabManualAuthCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            colabAuthCheckSummary = "請先貼上從瀏覽器複製的 Google OAuth 授權碼。"
            return
        }
        guard let scriptURL = resolveBundledColabLoginScriptURL() else {
            colabAuthCheckSummary = "找不到內建 colab_login.py 授權腳本。"
            return
        }
        guard !colabIsSubmittingCode else { return }

        colabIsSubmittingCode = true
        colabAuthCheckSummary = "正在向 Google 驗證授權碼並儲存憑證…"

        Task { @MainActor in
            let res = await Self.runBoundedCommand(
                executable: "/usr/bin/python3",
                arguments: [scriptURL.path, "code", code],
                timeoutSeconds: 15.0
            )
            self.colabIsSubmittingCode = false
            self.inspectGoogleColabCLI()
            if res.timedOut {
                self.colabAuthCheckSummary = "驗證授權碼逾時（15 秒），請確認網路連線或重試。"
                return
            }
            let sanitized = Self.sanitizeCLIOutput(res.stdout + "\n" + res.stderr)
            if res.terminationStatus == 0 && self.colabTokenFileExists {
                self.colabAuthVerified = true
                self.colabManualAuthCode = ""
                self.colabPendingAuthURL = nil
                self.colabAuthCheckSummary = "已登入（已完成 Google Colab OAuth 授權並驗證本機憑證）！"
            } else {
                self.colabAuthVerified = false
                self.colabAuthCheckSummary = "授權碼驗證未通過（代碼 \(res.terminationStatus)）：\(sanitized.prefix(160))"
            }
        }
    }

    func cancelColabBrowserAuthentication() {
        if let proc = activeColabAuthProcess, proc.isRunning {
            proc.terminate()
        }
        activeColabAuthProcess = nil
        colabIsLaunchingAuth = false
        colabIsSubmittingCode = false
        colabPendingAuthURL = nil
        colabManualAuthCode = ""
        colabAuthCheckSummary = "已取消 Colab 登入流程，可隨時重試或使用本機模式。"
    }

    func copyColabLoginCommandToClipboard() {
        let scriptPath = resolveBundledColabLoginScriptURL()?.path ?? "Contents/Resources/h3/scripts/colab_login.py"
        let cmd = "/usr/bin/python3 \"\(scriptPath)\" url"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        colabAuthCheckSummary = "已複製 OAuth 登入指令至剪貼簿。"
    }

    private static func sanitizeCLIOutput(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("access_token") || lower.contains("refresh_token") || lower.contains("client_secret") || lower.contains("bearer ") {
                lines.append("[憑證欄位已自動遮蔽]")
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Card 5 — API Connections & macOS Keychain

    private func loadAPIConnectionConfigs() {
        var map: [SupportedAPIProvider: APIConnectionConfig] = [:]
        for provider in SupportedAPIProvider.allCases {
            let savedURL = userDefaults.string(forKey: provider.urlDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (savedURL?.isEmpty == false) ? savedURL! : provider.defaultServiceURL
            let hasCred = KeychainCredentialsStore.hasCredential(account: provider.keychainAccount, service: keychainService)
            map[provider] = APIConnectionConfig(
                provider: provider,
                serviceURL: url,
                draftSecret: "",
                hasStoredCredential: hasCred,
                isSecretRevealed: false
            )
        }
        apiConnections = map
    }

    func refreshKeychainStatuses(app: Studio? = nil) {
        for provider in SupportedAPIProvider.allCases {
            var cfg = apiConnections[provider] ?? APIConnectionConfig(
                provider: provider,
                serviceURL: provider.defaultServiceURL
            )
            cfg.hasStoredCredential = KeychainCredentialsStore.hasCredential(
                account: provider.keychainAccount,
                service: keychainService
            )
            if provider == .comfyui_api, let app, !app.project.endpoint.isEmpty {
                cfg.serviceURL = app.project.endpoint
            } else if provider == .voicebox_api {
                let port = (1024...65535).contains(voiceboxPort) ? voiceboxPort : 17495
                if cfg.serviceURL.isEmpty {
                    cfg.serviceURL = "http://127.0.0.1:\(port)"
                }
            }
            apiConnections[provider] = cfg
        }
    }

    func updateServiceURL(for provider: SupportedAPIProvider, url: String, app: Studio? = nil) {
        guard var cfg = apiConnections[provider] else { return }
        cfg.serviceURL = url
        apiConnections[provider] = cfg
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            userDefaults.set(trimmed, forKey: provider.urlDefaultsKey)
            if provider == .comfyui_api {
                comfyConfiguredEndpoint = trimmed
                userDefaults.set(trimmed, forKey: Self.comfyLastDiscoveredEndpointKey)
                app?.project.endpoint = trimmed
            } else if provider == .voicebox_api,
                      let parsed = URL(string: trimmed),
                      let port = parsed.port,
                      (1024...65535).contains(port) {
                voiceboxPort = port
                userDefaults.set(port, forKey: Self.voiceboxPortKey)
                NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
            }
        }
    }

    func updateDraftSecret(for provider: SupportedAPIProvider, secret: String) {
        guard var cfg = apiConnections[provider] else { return }
        cfg.draftSecret = secret
        apiConnections[provider] = cfg
    }

    func toggleRevealSecret(for provider: SupportedAPIProvider) {
        guard var cfg = apiConnections[provider] else { return }
        if !cfg.isSecretRevealed {
            if cfg.draftSecret.isEmpty,
               let stored = KeychainCredentialsStore.read(account: provider.keychainAccount, service: keychainService) {
                cfg.draftSecret = stored
            }
            cfg.isSecretRevealed = true
        } else {
            cfg.isSecretRevealed = false
            if cfg.hasStoredCredential {
                cfg.draftSecret = ""
            }
        }
        apiConnections[provider] = cfg
    }

    func saveCredentialToKeychain(for provider: SupportedAPIProvider, app: Studio? = nil) {
        guard var cfg = apiConnections[provider] else { return }
        let trimmedURL = cfg.serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let validation = provider.validateEndpointURL(trimmedURL)
        guard let validURL = validation.validURL else {
            cfg.testSucceeded = false
            cfg.testStatusMessage = validation.errorMessage ?? "服務網址不符合安全規範。"
            apiConnections[provider] = cfg
            return
        }
        updateServiceURL(for: provider, url: validURL, app: app)
        cfg = apiConnections[provider] ?? cfg

        let secretToSave = cfg.draftSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secretToSave.isEmpty else {
            cfg.testSucceeded = true
            cfg.testStatusMessage = "已儲存服務網址（未變更金鑰）。"
            apiConnections[provider] = cfg
            return
        }

        do {
            try KeychainCredentialsStore.save(
                account: provider.keychainAccount,
                secret: secretToSave,
                service: keychainService
            )
            cfg.hasStoredCredential = true
            cfg.draftSecret = ""
            cfg.isSecretRevealed = false
            cfg.testSucceeded = true
            cfg.testStatusMessage = "已安全儲存憑證至 macOS 鑰匙圈。"
            apiConnections[provider] = cfg
            if provider == .huggingface {
                NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
            }
        } catch {
            cfg.testSucceeded = false
            cfg.testStatusMessage = error.localizedDescription
            apiConnections[provider] = cfg
        }
    }

    func disconnectAndRemoveCredential(for provider: SupportedAPIProvider) {
        guard var cfg = apiConnections[provider] else { return }
        do {
            try KeychainCredentialsStore.delete(account: provider.keychainAccount, service: keychainService)
            cfg.hasStoredCredential = false
            cfg.draftSecret = ""
            cfg.isSecretRevealed = false
            cfg.testSucceeded = nil
            cfg.testStatusMessage = "已從 macOS 鑰匙圈移除憑證。"
            apiConnections[provider] = cfg
            if provider == .huggingface {
                NotificationCenter.default.post(name: .motionDeskVoiceboxConfigChanged, object: nil)
            }
        } catch {
            cfg.testSucceeded = false
            cfg.testStatusMessage = error.localizedDescription
            apiConnections[provider] = cfg
        }
    }

    /// Sends a test request ONLY to the selected provider's configured endpoint.
    /// Validates scheme/host upfront, blocks HTTP redirects via `noRedirectSession`, and never prints or logs the credential.
    func testAPIConnection(for provider: SupportedAPIProvider, app: Studio? = nil) async {
        guard var cfg = apiConnections[provider] else { return }
        let validation = provider.validateEndpointURL(cfg.serviceURL)
        guard let baseURL = validation.validURL else {
            cfg.testSucceeded = false
            cfg.testStatusMessage = validation.errorMessage ?? "請輸入有效的服務網址（例如 \(provider.defaultServiceURL)）。"
            apiConnections[provider] = cfg
            return
        }

        updateServiceURL(for: provider, url: baseURL, app: app)
        cfg = apiConnections[provider] ?? cfg
        cfg.isTesting = true
        cfg.testStatusMessage = "正在測試連線至 \(baseURL)…"
        apiConnections[provider] = cfg

        let storedSecret = KeychainCredentialsStore.read(
            account: provider.keychainAccount,
            service: keychainService
        )
        let activeSecret: String?
        let trimmedDraft = cfg.draftSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDraft.isEmpty {
            activeSecret = trimmedDraft
        } else {
            activeSecret = storedSecret
        }

        var succeeded: Bool? = false
        var summary = ""

        switch provider {
        case .huggingface:
            if let token = activeSecret, !token.isEmpty {
                guard let url = URL(string: "\(baseURL)/api/whoami-v2") else {
                    summary = "網址格式無效。"
                    break
                }
                var req = URLRequest(url: url)
                req.timeoutInterval = 5.0
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                do {
                    let (data, resp) = try await noRedirectSession.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200,
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let username = obj["name"] as? String {
                        succeeded = true
                        summary = "連線成功（HTTP 200）· HuggingFace 帳號：\(username)"
                    } else if (300...399).contains(code) {
                        succeeded = false
                        summary = "已攔截重新導向（HTTP \(code)），不跨網域轉發憑證。"
                    } else if code == 401 {
                        succeeded = false
                        summary = "Token 驗證失敗（HTTP 401），請確認權杖是否有效。"
                    } else {
                        succeeded = false
                        summary = "伺服器回應 HTTP \(code)。"
                    }
                } catch {
                    succeeded = false
                    summary = "無法連線至 HuggingFace：\(error.localizedDescription)"
                }
            } else {
                guard let url = URL(string: "\(baseURL)/api/models/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16") else {
                    summary = "網址格式無效。"
                    break
                }
                var req = URLRequest(url: url)
                req.timeoutInterval = 5.0
                do {
                    let (data, resp) = try await noRedirectSession.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if (200...299).contains(code),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let modelId = obj["id"] as? String {
                        succeeded = true
                        summary = "公開模型端點連線正常（HTTP \(code) · 可匿名下載 \(modelId)）"
                    } else {
                        succeeded = false
                        summary = "端點回應 HTTP \(code)。"
                    }
                } catch {
                    succeeded = false
                    summary = "無法連線至 \(baseURL)：\(error.localizedDescription)"
                }
            }

        case .comfyui_api:
            guard let url = URL(string: "\(baseURL)/system_stats") else {
                summary = "網址格式無效。"
                break
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4.0
            if let token = activeSecret, !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, resp) = try await noRedirectSession.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(code),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sys = obj["system"] as? [String: Any] {
                    let ver = (sys["comfyui_version"] as? String) ?? "未知"
                    succeeded = true
                    let authNote = (activeSecret?.isEmpty == false) ? "已附帶本機憑證" : "免金鑰本機連線"
                    summary = "本機 ComfyUI 連線成功（v\(ver) · \(authNote)）"
                } else if (300...399).contains(code) {
                    succeeded = false
                    summary = "已攔截重新導向（HTTP \(code)）。"
                } else {
                    succeeded = false
                    summary = "端點回應 HTTP \(code)（請確認為本機 ComfyUI）。"
                }
            } catch {
                succeeded = false
                summary = "尚未偵測到執行中的本機 ComfyUI（\(baseURL)）。"
            }

        case .voicebox_api:
            guard let healthURL = URL(string: "\(baseURL)/health"),
                  let profilesURL = URL(string: "\(baseURL)/profiles") else {
                summary = "網址格式無效。"
                break
            }
            var healthReq = URLRequest(url: healthURL)
            healthReq.timeoutInterval = 4.0
            if let token = activeSecret, !token.isEmpty {
                healthReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (hData, hResp) = try await noRedirectSession.data(for: healthReq)
                let hCode = (hResp as? HTTPURLResponse)?.statusCode ?? 0
                guard hCode == 200,
                      let hObj = try? JSONSerialization.jsonObject(with: hData) as? [String: Any],
                      let statusStr = hObj["status"] as? String else {
                    succeeded = false
                    summary = "端點回應 HTTP \(hCode)，並非有效的本機語音服務。"
                    break
                }
                let backendType = (hObj["backend_type"] as? String) ?? "mlx"
                let gpuType = (hObj["gpu_type"] as? String) ?? "Apple Silicon"

                var pReq = URLRequest(url: profilesURL)
                pReq.timeoutInterval = 4.0
                if let token = activeSecret, !token.isEmpty {
                    pReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                var profileCountText = ""
                if let (pData, pResp) = try? await noRedirectSession.data(for: pReq),
                   (pResp as? HTTPURLResponse)?.statusCode == 200,
                   let arr = try? JSONSerialization.jsonObject(with: pData) as? [[String: Any]] {
                    profileCountText = " · \(arr.count) 個聲音角色"
                }
                succeeded = true
                summary = "本機語音服務已就緒（\(statusStr) · \(backendType) · \(gpuType)\(profileCountText)）"
            } catch {
                succeeded = false
                summary = "語音服務目前未在 \(baseURL) 執行（將於配音時按需自動啟動）。"
            }

        case .openai_image, .gemini_image:
            // Never trigger paid image generation during settings check; validate config, Keychain presence, and network state only.
            if NetworkReachabilityMonitor.shared.isOffline {
                succeeded = nil
                summary = "目前離線，線上圖片 API 已暫停；本機 ComfyUI 與剪輯功能仍可正常使用。"
            } else if let key = activeSecret, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                succeeded = true
                summary = "已確認官方端點 \(baseURL) 與 Keychain 金鑰存在（未發送付費生圖呼叫；生圖前須於生成頁勾選同意計費）。"
            } else {
                succeeded = nil
                summary = "未設定（選用）：僅停用 \(provider.shortName)，官方網頁按鈕與本機功能仍可使用。"
            }
        }

        var updated = apiConnections[provider] ?? cfg
        updated.isTesting = false
        updated.testSucceeded = succeeded
        updated.testStatusMessage = summary
        updated.lastTestedAt = Date()
        apiConnections[provider] = updated
    }

    // MARK: Card 6 — FFmpeg / Runtime / Architecture / AI-Audio Dependencies

    func inspectHostArchitectureAndBundledRuntimes() {
        #if arch(arm64)
        hostArchitecture = "arm64 · Apple Silicon"
        isAppleSiliconHost = true
        #elseif arch(x86_64)
        hostArchitecture = "x86_64 · Intel Mac（不支援 MLX 本地語音推論）"
        isAppleSiliconHost = false
        #else
        hostArchitecture = "未知架構"
        isAppleSiliconHost = false
        #endif

        let fm = FileManager.default
        let bundleRoot = Bundle.main.bundleURL

        let nodeInBundle = bundleRoot.appendingPathComponent("Contents/Resources/runtime/node/bin/node")
        let hfInBundle = bundleRoot.appendingPathComponent("Contents/Resources/runtime/hyperframes")
        let textRenderInBundle = bundleRoot.appendingPathComponent("Contents/Resources/textrender")

        if fm.isExecutableFile(atPath: nodeInBundle.path) {
            bundledNodeReady = true
            bundledNodePath = nodeInBundle.path
        } else {
            bundledNodeReady = false
            bundledNodePath = nil
        }

        bundledHyperFramesReady = fm.fileExists(atPath: hfInBundle.path)

        if fm.isExecutableFile(atPath: textRenderInBundle.path) {
            bundledTextRenderReady = true
            bundledTextRenderPath = textRenderInBundle.path
        } else {
            bundledTextRenderReady = false
            bundledTextRenderPath = nil
        }

        let customFFmpeg = userDefaults.string(forKey: Self.customFFmpegPathKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledFFmpeg = bundleRoot.appendingPathComponent("Contents/Resources/runtime/bin/ffmpeg").path
        let bundledFFprobe = bundleRoot.appendingPathComponent("Contents/Resources/runtime/bin/ffprobe").path

        var resolvedFFmpeg: String? = nil
        var sourceDesc = "未找到"
        var isBrew = false

        if let customFFmpeg, !customFFmpeg.isEmpty, fm.isExecutableFile(atPath: customFFmpeg) {
            resolvedFFmpeg = customFFmpeg
            sourceDesc = "自訂路徑"
            isBrew = customFFmpeg.hasPrefix("/opt/homebrew") || customFFmpeg.hasPrefix("/usr/local/Cellar")
        } else if fm.isExecutableFile(atPath: bundledFFmpeg) {
            resolvedFFmpeg = bundledFFmpeg
            sourceDesc = "App 內建"
            isBrew = false
        } else if fm.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            resolvedFFmpeg = "/opt/homebrew/bin/ffmpeg"
            sourceDesc = "系統 Homebrew"
            isBrew = true
        } else if fm.isExecutableFile(atPath: "/usr/local/bin/ffmpeg") {
            resolvedFFmpeg = "/usr/local/bin/ffmpeg"
            sourceDesc = "系統 /usr/local"
            isBrew = true
        }

        ffmpegResolvedPath = resolvedFFmpeg
        ffmpegSourceDescription = sourceDesc
        ffmpegIsHomebrewLinked = isBrew

        if fm.isExecutableFile(atPath: bundledFFprobe) {
            ffprobeResolvedPath = bundledFFprobe
        } else if let ff = resolvedFFmpeg {
            let siblingProbe = URL(fileURLWithPath: ff).deletingLastPathComponent().appendingPathComponent("ffprobe").path
            if fm.isExecutableFile(atPath: siblingProbe) {
                ffprobeResolvedPath = siblingProbe
            } else {
                ffprobeResolvedPath = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: { fm.isExecutableFile(atPath: $0) })
            }
        } else {
            ffprobeResolvedPath = nil
        }
    }

    func chooseCustomFFmpegBinary(app: Studio) {
        app.pickAsync(title: "選擇 ffmpeg 執行檔", types: [.unixExecutable, .item], multiple: false, directory: false) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                app.status = "所選檔案不是可執行檔：\(url.lastPathComponent)"
                return
            }
            self.userDefaults.set(url.path, forKey: Self.customFFmpegPathKey)
            self.inspectHostArchitectureAndBundledRuntimes()
            Task { await self.verifyFFmpegExecution() }
            app.status = "已設定自訂 FFmpeg 路徑 · \(url.path)"
        }
    }

    func resetCustomFFmpegBinary() {
        userDefaults.removeObject(forKey: Self.customFFmpegPathKey)
        inspectHostArchitectureAndBundledRuntimes()
    }

    func verifyFFmpegExecution() async {
        inspectHostArchitectureAndBundledRuntimes()
        guard let bin = ffmpegResolvedPath else {
            ffmpegVersionSummary = "找不到可用的 ffmpeg 執行檔。若在新電腦安裝，請執行 brew install ffmpeg 或指定自訂路徑。"
            return
        }
        isProbingFFmpeg = true
        defer { isProbingFFmpeg = false }

        let arch = Self.detectMachOArchitecture(atPath: bin)
        let res = await Self.runBoundedCommand(executable: bin, arguments: ["-version"], timeoutSeconds: 4.0)
        if res.terminationStatus == 0 {
            let firstLine = res.stdout.components(separatedBy: .newlines).first ?? "ffmpeg"
            ffmpegVersionSummary = "驗證成功（\(arch)）：\(firstLine)"
        } else {
            ffmpegVersionSummary = "執行失敗（代碼 \(res.terminationStatus)）：\(res.stderr.prefix(160))"
        }
    }

    func copyHomebrewFFmpegInstallCommand() {
        let cmd = "brew install ffmpeg"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        statusBannerMessage = "已複製安裝指令：brew install ffmpeg"
    }

    // MARK: Dependency & Redistribution Manifest

    var dependencyManifestEntries: [DependencyManifestEntry] {
        [
            DependencyManifestEntry(
                id: "voicebox-server",
                name: "內建語音合成後端服務 (FastAPI + MLX / Qwen3-TTS Engine)",
                versionOrArch: "v0.5.4 · arm64 Mach-O (\(voiceboxRuntimeSource.badgeText))",
                distributionKind: voiceboxRuntimeSource == .bundledInApp ? .bundled : .reusedOrConfigurable,
                approxSize: voiceboxBinarySizeBytes > 0 ? setupFormatBytes(voiceboxBinarySizeBytes) : "約 482 MB",
                license: "MIT License (Copyright 2026 Voicebox Contributors)",
                sourceOrPath: voiceboxBinaryPath ?? "Contents/MacOS/voicebox-server",
                notes: "隨應用程式內建並包含 Contents/Resources/backend-patches 語音推論修補與 MIT 授權聲明。"
            ),
            DependencyManifestEntry(
                id: "node-hyperframes",
                name: "Node.js Runtime + HyperFrames 合成引擎 + CoreText textrender",
                versionOrArch: "Node v22.23.5 · arm64",
                distributionKind: .bundled,
                approxSize: "約 178 MB",
                license: "MIT / Node.js Open Source License",
                sourceOrPath: bundledNodePath ?? "Contents/Resources/runtime",
                notes: "隨 Klipora.app 完整內建，無需外部安裝 Node.js 即可執行字卡渲染與多軌工作流。"
            ),
            DependencyManifestEntry(
                id: "qwen3-tts-models",
                name: "Qwen3-TTS 1.7B / 0.6B (Base & CustomVoice) 語音模型權重",
                versionOrArch: "MLX bf16 / Safetensors",
                distributionKind: .userTriggeredDownload,
                approxSize: "每組約 2.5 GB – 4.2 GB（共享快取，不隨 App 重複打包）",
                license: "Apache-2.0 (Qwen / Alibaba Cloud & mlx-community)",
                sourceOrPath: voiceboxModelsDirPath,
                notes: "保持共享快取（~/.cache/huggingface/hub），僅在使用者主動觸發下載時從 HuggingFace 官方來源取得。"
            ),
            DependencyManifestEntry(
                id: "local-comfyui",
                name: "Local ComfyUI / Comfy Desktop 繪圖與 Wan 2.2 影片引擎",
                versionOrArch: "Apple Silicon MPS · 動態連接埠探測",
                distributionKind: .externalOptional,
                approxSize: "外部獨立應用程式 + 模型權重依需求",
                license: "GPL-3.0 (ComfyUI Core) · 外部獨立程序通訊",
                sourceOrPath: comfyDesktopAppPath ?? comfyModelsRootPath,
                notes: "透過本機 Loopback HTTP API 通訊，不靜默下載龐大套件，亦不強制綁定固定 8188 埠。"
            ),
            DependencyManifestEntry(
                id: "ffmpeg-suite",
                name: "FFmpeg / FFprobe 影音轉碼與數位訊號濾鏡庫",
                versionOrArch: "arm64 (\(ffmpegSourceDescription))",
                distributionKind: ffmpegIsHomebrewLinked ? .externalOptional : .reusedOrConfigurable,
                approxSize: "約 80 MB – 140 MB",
                license: "LGPL v2.1+ / GPL v3（依系統安裝之 FFmpeg 組態而定）",
                sourceOrPath: ffmpegResolvedPath ?? "/opt/homebrew/bin/ffmpeg",
                notes: "用於多軌混音匯出、視覺與音訊特效及 540p 代理轉碼。全新 Mac 若未安裝 Homebrew，需另行安裝或指定 FFmpeg 路徑。"
            ),
            DependencyManifestEntry(
                id: "ai-audio-venv",
                name: "本地音訊 AI 模組 (Faster-Whisper ASR / UVR 人聲分離 / Kokoro)",
                versionOrArch: "arm64 Python venv + ONNX INT8",
                distributionKind: .userTriggeredDownload,
                approxSize: "環境與四組模型合計約 512 MB",
                license: "MIT (Faster-Whisper / UVR) & Apache-2.0 (Sherpa-ONNX)",
                sourceOrPath: AudioAIManager.shared.venvDirPath,
                notes: "選用本地音訊工具，於音訊面板按需安裝至 ~/Library/Application Support/Klipora/ai-audio-venv。"
            ),
            DependencyManifestEntry(
                id: "colab-cli",
                name: "Google Colab 雲端加速 CLI (Wan 2.2 L4 影片 / H3 A100 長稿配音)",
                versionOrArch: "OAuth 2.0 瀏覽器授權",
                distributionKind: .externalOptional,
                approxSize: "約 15 MB",
                license: "Apache-2.0 / Google Colab 服務條款",
                sourceOrPath: colabBinaryPath ?? "~/.local/bin/colab",
                notes: "外部選用雲端運算工具。未安裝或未登入時，所有本機剪輯、錄音與本機配音仍完整可用。"
            ),
            DependencyManifestEntry(
                id: "roadmap-boundaries",
                name: "跨平台與其他第三方商業語音 API（路線圖邊界聲明）",
                versionOrArch: "目前僅支援 macOS Apple Silicon (arm64)",
                distributionKind: .roadmapOnly,
                approxSize: "N/A",
                license: "N/A",
                sourceOrPath: "尚未實作（不提供無效按鈕）",
                notes: "本版針對 Apple Silicon macOS 驗證；外部選用依賴（Python / FFmpeg / ComfyUI / Colab CLI）在新電腦上仍需依上方狀態指引配置。"
            )
        ]
    }

    // MARK: Low-Level Helpers (Mach-O Arch Probe & Bounded Subprocess)

    nonisolated static func detectMachOArchitecture(atPath path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "無法讀取" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count >= 8 else { return "未知格式" }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        if magic == 0xfeedfacf || magic == 0xcffaedfe {
            let cputype = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            if cputype == 0x0100000c || cputype.byteSwapped == 0x0100000c {
                return "arm64 (Apple Silicon Mach-O)"
            } else if cputype == 0x01000007 || cputype.byteSwapped == 0x01000007 {
                return "x86_64 (Intel Mach-O)"
            }
            return "Mach-O 64-bit"
        } else if magic == 0xbebafeca || magic == 0xcafebabe {
            return "Universal (Fat Mach-O)"
        }
        return "Executable Script / Binary"
    }

    struct BoundedCommandResult: Sendable {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    static func runBoundedCommand(
        executable: String,
        arguments: [String],
        timeoutSeconds: Double
    ) async -> BoundedCommandResult {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.standardInput = FileHandle.nullDevice

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
            } catch {
                return BoundedCommandResult(
                    terminationStatus: -1,
                    stdout: "",
                    stderr: error.localizedDescription,
                    timedOut: false
                )
            }

            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            var didTimeout = false
            while proc.isRunning {
                if Date() >= deadline {
                    didTimeout = true
                    proc.terminate()
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            proc.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()

            return BoundedCommandResult(
                terminationStatus: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                timedOut: didTimeout
            )
        }.value
    }
}

// MARK: - 5. Toolbar Entry Point Button & Sheet Presentation Modifier

struct PortabilitySetupToolbarButton: View {
    @ObservedObject var app: Studio
    @ObservedObject var setupManager = PortabilitySetupManager.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        Button {
            setupManager.openSetupSheet(firstRun: false, app: app)
        } label: {
            Label(l10n.text("toolbar.settings", fallback: "元件與連線設定"), systemImage: "slider.horizontal.3")
                .lineLimit(1)
        }
        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
        .accessibilityLabel("元件與連線設定")
        .help("開啟首次設定精靈與環境、語音引擎、ComfyUI、Colab、鑰匙圈連線設定")
        .sheet(isPresented: $setupManager.isSheetPresented) {
            PortabilitySetupSheetView(app: app, manager: setupManager)
        }
        .onAppear {
            setupManager.triggerFirstRunIfNeeded(app: app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .motionDeskOpenSettings)) { _ in
            setupManager.openSetupSheet(firstRun: false, app: app)
        }
    }
}

// MARK: - 6. Main First-Run Wizard & Settings Sheet View (PortabilitySetupSheetView)

@MainActor
private final class HardwareEnvironmentStore: ObservableObject {
    @Published var snapshot: HardwareEnvironmentSnapshot = .current()
    @Published var highlightedAnchor: SetupSectionAnchor? = nil
    @Published var showHardwareDetails: Bool = false
    private var clearHighlightTask: Task<Void, Never>? = nil

    func refresh() { snapshot = .current() }

    func focus(_ anchor: SetupSectionAnchor) {
        clearHighlightTask?.cancel()
        highlightedAnchor = anchor
        clearHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled {
                self?.highlightedAnchor = nil
            }
        }
    }
}

struct PortabilitySetupSheetView: View {
    @ObservedObject var app: Studio
    @ObservedObject var manager = PortabilitySetupManager.shared
    @ObservedObject private var recorder = VoiceoverRecorderManager.shared
    @ObservedObject private var audioAI = AudioAIManager.shared
    @ObservedObject private var network = NetworkReachabilityMonitor.shared
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var mografy = MografySkillManager.shared
    @StateObject private var hardwareStore = HardwareEnvironmentStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                settingsSidebar
                Divider().overlay(Color.white.opacity(0.08))
                VStack(spacing: 0) {
                    if let banner = manager.statusBannerMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(setupCyan)
                                .font(.system(size: 12))
                            Text(banner)
                                .font(.system(size: 11.5))
                                .foregroundStyle(StudioTheme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("關閉") {
                                manager.statusBannerMessage = nil
                            }
                            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(setupCyan.opacity(0.10))
                        Divider().overlay(Color.white.opacity(0.07))
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: manager.selectedSidebar.iconName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textSecondary)
                                Text(manager.selectedSidebar.rawValue)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textPrimary)
                                Spacer()
                                Button {
                                    manager.refreshAllLocalStates(app: app, userInitiated: true)
                                    hardwareStore.refresh()
                                    mografy.refresh()
                                    manager.statusBannerMessage = "正在重新掃描本機環境與連線狀態…"
                                } label: {
                                    Label(manager.isRefreshingLocalStates ? "掃描中…" : "重新掃描", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                            }
                            .padding(.bottom, 2)

                            switch manager.selectedSidebar {
                            case .general:
                                generalSettingsPane
                            case .localEngines:
                                localEnginesSettingsPane
                            case .cloudAPI:
                                cloudAPISettingsPane
                            case .automation:
                                automationSettingsPane
                            case .modelsStorage:
                                modelsStorageSettingsPane
                            case .about:
                                manifestAndLicensesSection
                            }
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(red: 0.082, green: 0.084, blue: 0.094))
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            footerBar
        }
        .frame(minWidth: 740, idealWidth: 880, maxWidth: 1020, minHeight: 540, idealHeight: 650, maxHeight: 780)
        .background(panel)
        .tint(StudioTheme.neutralAccent)
        .preferredColorScheme(.dark)
        .onAppear {
            manager.refreshAllLocalStates(app: app, userInitiated: false)
            mografy.refresh()
        }
        .onChange(of: manager.colabPendingAuthURL) { _, newValue in
            if newValue != nil {
                manager.showCard4Details = true
            }
        }
        .sheet(isPresented: $manager.showImageModelManagerSheet) {
            LocalModelManagerSheet(app: app)
        }
        .sheet(isPresented: $manager.showVoiceModelManagerSheet) {
            LocalVoiceModelManagerSheet(app: app, manager: manager)
        }
    }

    // MARK: Edits-Style Left Sidebar

    private func sidebarStatusColor(for section: PortabilitySetupManager.SetupSidebarSection) -> Color? {
        let summary = manager.fourPillarSummary
        switch section {
        case .general:
            return network.isOffline ? StudioTheme.warning : StudioTheme.success
        case .localEngines:
            return summary.engineReady.tintColor
        case .cloudAPI:
            let hasAny = manager.apiConnections[.openai_image]?.hasStoredCredential == true
                || manager.apiConnections[.gemini_image]?.hasStoredCredential == true
                || manager.colabTokenFileExists
            return hasAny ? StudioTheme.success : nil
        case .automation:
            return (manager.automationEnabled || mografy.isUnlocked) ? StudioTheme.success : nil
        case .modelsStorage:
            return summary.modelInstalled.tintColor
        case .about:
            return nil
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(manager.isFirstRunMode ? "首次設定" : "設定")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Spacer()
                Text("v1.1")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ForEach(PortabilitySetupManager.SetupSidebarSection.allCases) { section in
                let isSelected = manager.selectedSidebar == section
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        manager.selectedSidebar = section
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.iconName)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : StudioTheme.textSecondary)
                            .frame(width: 18)
                        Text(section.rawValue)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .white : StudioTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let dotColor = sidebarStatusColor(for: section) {
                            Circle()
                                .fill(dotColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected ? Color.white.opacity(0.11) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Silicon")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(hardwareStore.snapshot.summaryLine)
                    .font(.system(size: 9.5))
                    .foregroundStyle(StudioTheme.textMuted)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 204)
        .background(Color(red: 0.068, green: 0.070, blue: 0.080))
    }

    // MARK: Tab 1 — General

    private var generalSettingsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            KliporaGroupedCard {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("介面語言")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text("即時切換 Klipora 操作介面語言")
                                .font(.system(size: 10.5))
                                .foregroundStyle(StudioTheme.textMuted)
                        }
                        Spacer()
                        Picker(l10n.text("settings.language"), selection: $l10n.language) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.nativeDisplayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    .padding(.vertical, 4)

                    Divider().overlay(Color.white.opacity(0.07)).padding(.vertical, 10)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("網路與連線狀態")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(StudioTheme.textPrimary)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(network.isOffline ? StudioTheme.warning : (network.isOnline ? StudioTheme.success : StudioTheme.textMuted))
                                    .frame(width: 7, height: 7)
                                Text(network.state.label)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(StudioTheme.textSecondary)
                            }
                        }
                        Spacer()
                        Button("重試網路") {
                            network.recheckNow()
                            hardwareStore.refresh()
                        }
                        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                    }
                    .padding(.vertical, 4)

                    Divider().overlay(Color.white.opacity(0.07)).padding(.vertical, 10)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("首次安裝引導")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text("重新檢查硬體相容性、ComfyUI 路徑與預設模型下載")
                                .font(.system(size: 10.5))
                                .foregroundStyle(StudioTheme.textMuted)
                        }
                        Spacer()
                        Button("開啟引導") {
                            manager.isSheetPresented = false
                            KliporaStartupController.shared.openOnboarding()
                        }
                        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                    }
                    .padding(.vertical, 4)
                }
            }

            card1OutputRootSection
        }
    }

    // MARK: Tab 2 — Local Engines

    private var localEnginesSettingsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            card2LocalComfyUISection
            KliporaGroupedCard {
                apiProviderRow(for: .comfyui_api)
            }
            card3VoiceboxSection
            KliporaGroupedCard {
                apiProviderRow(for: .voicebox_api)
            }
        }
    }

    // MARK: Tab 3 — Cloud & API

    private var cloudAPISettingsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            KliporaGroupedCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("官方 API 金鑰僅加密儲存於 macOS Keychain，絕不寫入專案檔；未設定時對應功能會自動保持精簡隱藏。")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    apiProviderRow(for: .openai_image)
                    Divider().overlay(Color.white.opacity(0.07))
                    apiProviderRow(for: .gemini_image)
                    Divider().overlay(Color.white.opacity(0.07))
                    apiProviderRow(for: .huggingface)
                }
            }

            card4GoogleColabSection
        }
    }

    // MARK: Tab 4 — AI Agents & Automation (Edits-Inspired + Progressive Disclosure)

    private var automationSettingsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Card 1: Enable Automation Server (MCP)
            KliporaGroupedCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Automation Server")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StudioTheme.textPrimary)
                            if !manager.automationEnabled {
                                Text("開啟後可讓 Claude Code、Codex、Antigravity 透過本機 MCP 連接 Klipora（v1.2 自動化介面）。")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(StudioTheme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: Binding(
                            get: { manager.automationEnabled },
                            set: { val in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    manager.setAutomationEnabled(val)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(.vertical, 2)

                    if manager.automationEnabled {
                        Divider().overlay(Color.white.opacity(0.07)).padding(.vertical, 12)

                        HStack {
                            Text("Port")
                                .font(.system(size: 12.5))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Spacer()
                            Text("\(manager.automationPort)")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(StudioTheme.textPrimary)
                        }

                        Divider().overlay(Color.white.opacity(0.07)).padding(.vertical, 12)

                        HStack {
                            Text("Endpoint")
                                .font(.system(size: 12.5))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Spacer()
                            Text(manager.automationEndpoint)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // Progressive disclosure: Access Token & Connect an AI client only appear when Automation Server is enabled
            if manager.automationEnabled {
                KliporaGroupedCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Access token")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Spacer()
                            Button {
                                manager.automationTokenRevealed.toggle()
                            } label: {
                                Image(systemName: manager.automationTokenRevealed ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                        }

                        Text(manager.automationTokenRevealed ? manager.automationToken : String(repeating: "•", count: 28))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(StudioTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .textSelection(.enabled)

                        HStack(spacing: 8) {
                            Spacer()
                            Button("複製") {
                                manager.copyAutomationToken()
                            }
                            .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                            Button("重新產生") {
                                manager.regenerateAutomationToken()
                            }
                            .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                        }
                    }
                }

                KliporaGroupedCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("連接 AI 代理")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioTheme.textPrimary)

                        automationClientRow(
                            name: "Claude Code",
                            subtitle: "複製指令並在終端機執行，即可將 Klipora 加入 Claude Code。",
                            detected: mografy.detectedAgents[.claude] != nil
                        )
                        Divider().overlay(Color.white.opacity(0.06))
                        automationClientRow(
                            name: "Codex",
                            subtitle: "啟動 Codex 前於終端機執行複製的設定指令。",
                            detected: mografy.detectedAgents[.codex] != nil
                        )
                        Divider().overlay(Color.white.opacity(0.06))
                        automationClientRow(
                            name: "Antigravity",
                            subtitle: "複製 MCP 設定貼入 Antigravity，開啟新對話即可連接。",
                            detected: mografy.detectedAgents[.antigravity] != nil
                        )
                    }
                }
            }

            // Mografy Motion Graphics Skill Card
            MografySkillSetupCard()
        }
    }

    private func automationClientRow(name: String, subtitle: String, detected: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    if detected {
                        Circle()
                            .fill(StudioTheme.success)
                            .frame(width: 6, height: 6)
                            .help("已偵測到本機 \(name) CLI")
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("複製") {
                manager.copyAutomationClientCommand(for: name)
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
        }
    }

    // MARK: Tab 5 — Models & Storage

    private var modelsStorageSettingsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            KliporaGroupedCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("中央模型儲存目錄")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text(hardwareStore.snapshot.modelRequirementsSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(StudioTheme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 8) {
                            Button("管理圖片模型") {
                                manager.showImageModelManagerSheet = true
                            }
                            .buttonStyle(KliporaPillButtonStyle(variant: .accent, compact: true))
                            Button("管理語音模型") {
                                manager.showVoiceModelManagerSheet = true
                            }
                            .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                            Button("開啟目錄") {
                                try? FileManager.default.createDirectory(at: CentralComfyModelStorage.defaultRoot, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([CentralComfyModelStorage.defaultRoot])
                            }
                            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                        }
                    }
                }
            }

            card6FFmpegAndDependenciesSection
        }
    }

    private var hardwareSummaryLead: some View {
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(StudioTheme.neutralAccent)
            Text(hardwareStore.snapshot.summaryLine)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(StudioTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(hardwareStore.showHardwareDetails ? "收合需求" : "模型需求與目錄") {
                hardwareStore.showHardwareDetails.toggle()
            }
            .buttonStyle(.link)
            .font(.system(size: 10))
        }
    }

    private var networkStatusControls: some View {
        HStack(spacing: 6) {
            Picker(l10n.text("settings.language"), selection: $l10n.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.nativeDisplayName).tag(lang)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 120)
            .help(l10n.text("settings.languageHint"))

            Button(l10n.text("toolbar.onboarding", fallback: "安裝引導")) {
                manager.isSheetPresented = false
                KliporaStartupController.shared.openOnboarding()
            }
            .font(.system(size: 10))
            .controlSize(.mini)

            Circle()
                .fill(network.isOffline ? StudioTheme.warning : (network.isOnline ? StudioTheme.success : StudioTheme.textMuted))
                .frame(width: 7, height: 7)
            Text(network.state.label)
                .font(.system(size: 10))
                .foregroundStyle(network.isOffline ? StudioTheme.warning : StudioTheme.textSecondary)
                .lineLimit(1)
            Button("重試網路") {
                network.recheckNow()
                hardwareStore.refresh()
            }
            .font(.system(size: 10))
            .controlSize(.mini)
        }
    }

    private func setupGroupHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textPrimary)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(StudioTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    /// Click handler for the 4 top status cards: switches to Cards tab, expands relevant details,
    /// highlights the target section, and scrolls via ScrollViewReader without triggering network/login/GPU.
    private func navigateToSection(_ anchor: SetupSectionAnchor, using scrollProxy: ScrollViewProxy) {
        if manager.selectedTab != .cards {
            manager.selectedTab = .cards
        }
        switch anchor {
        case .runtime:
            manager.showCard6Details = true
        case .account:
            manager.showCard4Details = true
        case .models:
            manager.showCard3Details = true
        case .service:
            manager.showCard2Details = true
        }
        hardwareStore.focus(anchor)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    // MARK: Header Bar (Adaptive across narrow & wide sheets)

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    headerTitleCluster
                    Spacer(minLength: 8)
                    headerControlsCluster
                }
                VStack(alignment: .leading, spacing: 8) {
                    headerTitleCluster
                    HStack {
                        headerControlsCluster
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(panel)
    }

    private var headerTitleCluster: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(studioAccent.opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: manager.isFirstRunMode ? "sparkles.rectangle.stack.fill" : "slider.horizontal.2.square.on.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(studioAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(manager.isFirstRunMode ? "首次環境與連線設定" : "元件與連線設定")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Apple Silicon")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(setupCyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(setupCyan.opacity(0.14), in: Capsule())
                }
                Text("設定輸出目錄、本機配音與繪圖服務（僅檢查本機狀態，不自動啟動模型或配置付費 GPU）。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var headerControlsCluster: some View {
        HStack(spacing: 8) {
            Picker("顯示分頁", selection: $manager.selectedTab) {
                ForEach(PortabilitySetupManager.SetupSheetTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .accessibilityLabel("切換元件設定或授權清單分頁")
            .help("切換「元件與連線設定」與「元件清單與授權」分頁")

            if manager.selectedTab == .cards {
                Button {
                    manager.setAllDetailsExpanded(!manager.allDetailsExpanded)
                } label: {
                    Label(manager.allDetailsExpanded ? "收合細節" : "展開細節", systemImage: manager.allDetailsExpanded ? "chevron.up.circle" : "chevron.down.circle")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(manager.allDetailsExpanded ? "收合全部診斷細節" : "展開全部診斷細節")
                .help("展開或收合所有卡片中的詳細路徑與技術診斷資訊")
            }

            Button {
                manager.refreshAllLocalStates(app: app, userInitiated: true)
                manager.statusBannerMessage = "正在背景重新掃描本機路徑、模型快取與鑰匙圈狀態…"
            } label: {
                Label(manager.isRefreshingLocalStates ? "掃描中…" : "重新掃描", systemImage: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("重新掃描本機環境狀態")
            .help("快速檢查本機目錄、模型快取與鑰匙圈狀態（不觸發網路或 GPU）")
        }
    }

    // MARK: 4-Pillar Capability Separation Bar (Clickable Navigation Buttons)

    private func fourPillarStatusBar(scrollProxy: ScrollViewProxy) -> some View {
        let summary = manager.fourPillarSummary
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
            spacing: 8
        ) {
            pillarTile(anchor: .runtime, badge: summary.runtimeAvailable, scrollProxy: scrollProxy)
            pillarTile(anchor: .account, badge: summary.accountAuthenticated, scrollProxy: scrollProxy)
            pillarTile(anchor: .models, badge: summary.modelInstalled, scrollProxy: scrollProxy)
            pillarTile(anchor: .service, badge: summary.engineReady, scrollProxy: scrollProxy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(setupDarkWell)
    }

    private func pillarTile(anchor: SetupSectionAnchor, badge: ComponentReadinessBadge, scrollProxy: ScrollViewProxy) -> some View {
        let isFocused = hardwareStore.highlightedAnchor == anchor
        return Button {
            navigateToSection(anchor, using: scrollProxy)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(anchor.pillarTitle)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isFocused ? StudioTheme.coral : StudioTheme.textMuted)
                }
                HStack(spacing: 4) {
                    Image(systemName: badge.iconName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(badge.tintColor)
                    Text(badge.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StudioTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                (isFocused ? StudioTheme.elevated : surface.opacity(0.65)),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isFocused ? StudioTheme.coral.opacity(0.75) : badge.tintColor.opacity(0.26),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(anchor.pillarTitle)：\(badge.label)")
        .accessibilityHint(anchor.navigationHint)
        .help(anchor.navigationHint)
    }

    // MARK: Card 1 — Output Root & Dated Storage

    private var card1OutputRootSection: some View {
        let freeText = manager.outputRootFreeBytes.map(setupFormatBytes) ?? "未知"
        return setupCardContainer(
            number: "01",
            icon: "folder.fill.badge.gearshape",
            title: "輸出目錄與當日資料夾（Jobs / \(manager.todayDatedFolderName)）",
            accent: setupEmerald,
            badge: manager.outputRootWritable
                ? .ready(manager.isUsingCustomOutputRoot ? "自訂輸出目錄 · 可用 \(freeText)" : "預設 Jobs · 可用 \(freeText)")
                : .warning("目錄無寫入權限")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                // Concise Task & Status
                HStack(spacing: 8) {
                    Text("所有圖片、影片、配音與錄音成品皆自動歸檔至當日資料夾（\(setupCompactPath(manager.todayDatedFolderPath))）。")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }

                // Primary Actions
                adaptiveButtonRow {
                    Button {
                        app.chooseDefaultOutputDirectory()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            manager.inspectOutputRoot(app: app)
                        }
                    } label: {
                        Label("更改輸出位置…", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(setupEmerald)
                    .controlSize(.small)
                    .accessibilityLabel("更改預設輸出儲存位置")
                    .help("選擇生圖、影片與配音成品的預設儲存根目錄")

                    Button {
                        manager.openTodayDatedOutputDirectory(app: app)
                    } label: {
                        Label("開啟今日資料夾 (\(manager.todayDatedFolderName))", systemImage: "calendar.badge.clock")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("開啟今日成品資料夾 \(manager.todayDatedFolderName)")
                    .help("於 Finder 開啟今日（\(manager.todayDatedFolderName)）成品輸出資料夾")

                    Button {
                        app.openOutputDirectory(app.defaultOutputDirectory)
                        manager.inspectOutputRoot(app: app)
                    } label: {
                        Label("開啟根目錄", systemImage: "folder")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("開啟預設輸出根目錄")
                    .help("於 Finder 開啟輸出根目錄")

                    if manager.isUsingCustomOutputRoot {
                        Button("恢復預設位置") {
                            app.resetDefaultOutputDirectory()
                            manager.inspectOutputRoot(app: app)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("恢復預設 Jobs 輸出位置")
                        .help("將輸出位置重設為預設的 Application Support/Klipora/Jobs")
                    }
                }

                // Expandable Details
                DisclosureGroup("檢視完整輸出路徑與磁碟狀態", isExpanded: $manager.showCard1Details) {
                    VStack(alignment: .leading, spacing: 5) {
                        keyValuePathRow(label: "輸出根目錄完整路徑", path: manager.outputRootPath)
                        keyValuePathRow(label: "今日成品子資料夾", path: manager.todayDatedFolderPath)
                        keyValuePathRow(
                            label: "寫入權限與可用空間",
                            path: "\(manager.outputRootWritable ? "可正常建立日期子資料夾並寫入" : "目標路徑無法寫入，請更換資料夾") · 磁碟可用 \(freeText)"
                        )
                    }
                    .padding(9)
                    .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Card 2 — Local ComfyUI

    private var card2LocalComfyUISection: some View {
        let badge: ComponentReadinessBadge = {
            if manager.comfyEndpointReachable && manager.comfyModelsDirectoryExists && manager.comfyDetectedModelFilesCount > 0 {
                return .ready("已連線 · \(manager.comfyDetectedModelFilesCount) 個模型就緒")
            } else if manager.comfyEndpointReachable {
                return .warning("已連線但缺少模型權重")
            } else if manager.comfyModelsDirectoryExists && manager.comfyDetectedModelFilesCount > 0 {
                return .reusable("已備妥 \(manager.comfyDetectedModelFilesCount) 個模型 · 服務待命")
            } else {
                return .optionalMissing("選用元件（未啟動或未設定模型）")
            }
        }()

        return setupCardContainer(
            number: "02",
            icon: "cpu.fill",
            title: "本機 ComfyUI 繪圖與影片引擎",
            accent: StudioTheme.neutralAccent,
            badge: badge,
            isHighlighted: hardwareStore.highlightedAnchor == .service
        ) {
            VStack(alignment: .leading, spacing: 8) {
                // Concise Task & Status
                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.comfyProbeMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(manager.comfyEndpointReachable && manager.comfyDetectedModelFilesCount > 0 ? setupEmerald : .white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    if let identity = manager.comfyServerIdentitySummary {
                        Text(identity)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(setupCyan)
                    }
                }

                // Primary Actions + Compact Endpoint Field
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        comfyEndpointFieldCluster
                        comfyPrimaryButtonsCluster
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        comfyEndpointFieldCluster
                        comfyPrimaryButtonsCluster
                    }
                }

                // Expandable Details
                DisclosureGroup("檢視模型目錄路徑與進階控制", isExpanded: $manager.showCard2Details) {
                    VStack(alignment: .leading, spacing: 6) {
                        keyValuePathRow(label: "ComfyUI 模型根目錄", path: manager.comfyModelsRootPath)
                        keyValuePathRow(
                            label: "Comfy Desktop 應用程式",
                            path: manager.comfyDesktopAppPath ?? "未於 /Applications 偵測到 Comfy Desktop.app（選用）"
                        )
                        keyValuePathRow(
                            label: "模型檔案統計",
                            path: manager.comfyModelsDirectoryExists
                                ? (manager.comfyDetectedModelFilesCount > 0
                                    ? "共 \(manager.comfyDetectedModelFilesCount) 個模型（\(manager.comfyDetectedModelCategories.joined(separator: "、"))）"
                                    : "models 資料夾存在但尚無權重檔")
                                : "尚未找到 \(manager.comfyModelsRootPath)/models 目錄"
                        )
                        Text("記憶體保護提示：請避免同時滿載執行本機大型影片生成與本地大型語音合成，以確保 Apple Silicon 統一記憶體穩定。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        if manager.comfyRuntimePythonPath != nil && manager.comfyModelsDirectoryExists {
                            HStack(spacing: 8) {
                                Button {
                                    app.toggleEngine()
                                } label: {
                                    Label(app.engineRunning ? "停止內建 ComfyUI 程序" : "由工作台啟動本機 ComfyUI", systemImage: app.engineRunning ? "stop.circle" : "play.circle")
                                }
                                .controlSize(.small)
                                .accessibilityLabel(app.engineRunning ? "停止內建 ComfyUI 程序" : "由工作台啟動本機 ComfyUI")
                                .help("由 Klipora 直接啟動或停止本機 ComfyUI 服務")

                                Button("重設預設模型目錄") {
                                    manager.resetComfyModelsRoot(app: app)
                                }
                                .controlSize(.small)
                                .accessibilityLabel("重設 ComfyUI 預設模型目錄")
                                .help("將 ComfyUI 模型目錄恢復為預設 ~/Documents/ComfyUI")
                            }
                        }
                    }
                    .padding(9)
                    .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var comfyEndpointFieldCluster: some View {
        HStack(spacing: 6) {
            Text("本機位址：")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("http://127.0.0.1:8188", text: Binding(
                get: { manager.comfyConfiguredEndpoint },
                set: { val in
                    manager.comfyConfiguredEndpoint = val
                    manager.updateServiceURL(for: .comfyui_api, url: val, app: app)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(minWidth: 165, maxWidth: 210)
            .accessibilityLabel("本機 ComfyUI 端點網址")
            .help("輸入本機 ComfyUI 服務位址（預設 http://127.0.0.1:8188）")
        }
    }

    private var comfyPrimaryButtonsCluster: some View {
        HStack(spacing: 6) {
            Button {
                manager.showImageModelManagerSheet = true
            } label: {
                Label("管理圖片模型", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .accent, compact: true))
            .help("開啟本機圖片模型管理頁面，新增或管理 .safetensors 模型")

            Button {
                Task { await manager.probeComfyUIEndpoint(app: app) }
            } label: {
                Label(manager.comfyIsProbing ? "探測中…" : "探測端點", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
            .disabled(manager.comfyIsProbing)
            .help("自動探測本機 ComfyUI 連接埠並檢查本地模型目錄是否就緒")

            Button {
                manager.chooseComfyModelsRoot(app: app)
            } label: {
                Label("模型目錄", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            .help("指定本機 ComfyUI 的安裝或 models 根目錄")

            Button {
                app.openComfyDesktop()
            } label: {
                Label("Comfy Desktop", systemImage: "macwindow")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            .help("啟動已安裝於 /Applications 的 Comfy Desktop")

            Button {
                manager.openComfyOfficialDownloadGuide()
            } label: {
                Text("安裝指南")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            .help("於瀏覽器開啟 ComfyUI 官方下載頁面")
        }
    }

    // MARK: Card 3 — Voicebox Runtime, Models & Voice Library

    private var card3VoiceboxSection: some View {
        let completeCount = manager.voiceboxModelItems.filter(\.isComplete).count
        let badge: ComponentReadinessBadge = {
            if manager.voiceboxRuntimeSource == .bundledInApp && manager.voiceboxBackendPatchesPresent && completeCount > 0 {
                return .ready("內建引擎 + \(completeCount) 組模型就緒")
            } else if manager.voiceboxRuntimeSource != .missing && completeCount > 0 {
                return .reusable("\(manager.voiceboxRuntimeSource.badgeText) + \(completeCount) 組模型")
            } else if manager.voiceboxRuntimeSource != .missing {
                return .optionalMissing("引擎可用 · 待準備語音模型")
            } else {
                return .warning("未偵測到語音服務執行檔")
            }
        }()

        return setupCardContainer(
            number: "03",
            icon: "waveform.badge.mic",
            title: "本機語音合成引擎、聲音角色庫與模型快取",
            accent: StudioTheme.neutralAccent,
            badge: badge,
            isHighlighted: hardwareStore.highlightedAnchor == .models
        ) {
            VStack(alignment: .leading, spacing: 8) {
                // Concise Task & Status
                let profileSummary = manager.voiceboxDatabaseExists
                    ? "已連結 \(manager.voiceboxProfileCountEstimate) 個聲音角色"
                    : "使用全新空白角色庫"
                let modelSummary = completeCount > 0
                    ? "已驗證 \(completeCount) 組 Qwen3-TTS 語音模型完整可用"
                    : "尚未偵測到完整的 Qwen3-TTS 語音模型快取"

                Text("\(manager.voiceboxRuntimeSource.badgeText) · \(profileSummary) · \(modelSummary)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                // Compact Interactive Model Status Pills (Click un-downloaded models to start direct HF download!)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 440), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(manager.voiceboxModelItems) { item in
                        let isDownloading = manager.downloadingVoiceModelRepoID == item.repoID
                        Button {
                            if !item.isComplete && !isDownloading {
                                manager.downloadVoiceModel(item, app: app)
                            } else {
                                manager.showVoiceModelManagerSheet = true
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Image(systemName: item.isComplete ? "checkmark.seal.fill" : (isDownloading ? "arrow.down.circle.fill" : "icloud.and.arrow.down"))
                                        .foregroundStyle(item.isComplete ? setupEmerald : (isDownloading ? StudioTheme.neutralAccent : setupAmber))
                                        .font(.system(size: 11))
                                    Text(item.displayName)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(isDownloading ? "\(Int(manager.voiceModelDownloadProgress * 100))%" : (item.isComplete ? "已就緒" : "點此下載"))
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(item.isComplete ? setupEmerald : (isDownloading ? StudioTheme.neutralAccent : setupAmber))
                                }
                                if isDownloading {
                                    ProgressView(value: manager.voiceModelDownloadProgress)
                                        .tint(StudioTheme.neutralAccent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(setupDarkWell, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.well, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: StudioTheme.Radius.well, style: .continuous)
                                    .strokeBorder(isDownloading ? StudioTheme.neutralAccent.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.downloadingVoiceModelRepoID != nil && !isDownloading)
                        .help(item.isComplete ? "點選開啟語音模型管理頁" : "點選直接從 HuggingFace 下載 \(item.displayName)（\(item.expectedSizeDescription)）")
                    }
                }

                if manager.downloadingVoiceModelRepoID != nil && !manager.voiceModelDownloadStatus.isEmpty {
                    Text(manager.voiceModelDownloadStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(StudioTheme.neutralAccent)
                }

                // Primary Actions (Unified Capsule Pills)
                adaptiveButtonRow {
                    Button {
                        manager.showVoiceModelManagerSheet = true
                    } label: {
                        Label("管理語音模型", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .accent, compact: true))
                    .help("開啟本機語音模型管理頁，檢視完整名稱、下載或移除模型")

                    Button {
                        manager.chooseVoiceboxDataDirectory(app: app)
                    } label: {
                        Label("聲音角色庫", systemImage: "folder.badge.person.crop")
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                    .help("選擇包含 voicebox.db 與 profiles 的既有聲音角色庫資料夾")

                    Button {
                        manager.chooseVoiceboxModelsCacheDirectory(app: app)
                    } label: {
                        Label("快取目錄", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                    .help("指定已下載 Qwen3-TTS 模型的 HuggingFace hub 快取資料夾")

                    Button {
                        let url = URL(fileURLWithPath: manager.voiceboxDataDirPath, isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("開啟資料夾", systemImage: "folder")
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                    .help("在 Finder 中檢視目前使用的聲音角色庫目錄")
                }

                // Expandable Details
                DisclosureGroup("檢視語音執行檔、聲音庫切換與模型快取診斷細節", isExpanded: $manager.showCard3Details) {
                    VStack(alignment: .leading, spacing: 6) {
                        keyValuePathRow(label: "語音服務執行檔", path: manager.voiceboxBinaryPath ?? "未偵測到 Contents/MacOS/voicebox-server")
                        keyValuePathRow(
                            label: "執行檔架構與補丁",
                            path: "\(manager.voiceboxBinaryArchitecture) · \(manager.voiceboxBinarySizeBytes > 0 ? setupFormatBytes(manager.voiceboxBinarySizeBytes) : "0 MB") · \(manager.voiceboxBackendPatchesPresent ? "MLX/Qwen 補丁已驗證" : "補丁未找到")"
                        )
                        keyValuePathRow(
                            label: "目前聲音角色庫目錄",
                            path: "\(manager.voiceboxDataDirPath)（佔用 \(setupFormatBytes(manager.voiceboxDataDirSizeBytes))）"
                        )
                        keyValuePathRow(
                            label: "目前模型快取目錄",
                            path: "\(manager.voiceboxModelsDirPath)（可用空間 \(manager.voiceboxModelsDirFreeBytes.map(setupFormatBytes) ?? "未知")）"
                        )

                        ForEach(manager.voiceboxModelItems) { item in
                            HStack(spacing: 6) {
                                Text("• \(item.repoID)：")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("\(item.statusNote)（預估 \(item.expectedSizeDescription)\(item.diskSizeBytes > 0 ? "，目前 \(setupFormatBytes(item.diskSizeBytes))" : "")）")
                                    .font(.system(size: 10))
                                    .foregroundStyle(item.isComplete ? setupEmerald : .white.opacity(0.85))
                            }
                        }

                        HStack(spacing: 8) {
                            Button("重用既有 sh.voicebox.app 角色庫") {
                                manager.reuseExistingVoiceboxAppSupportDirectory(app: app)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("重用既有 sh.voicebox.app 聲音角色庫")
                            .help("切換至 ~/Library/Application Support/sh.voicebox.app 既有角色庫")

                            Button("切換為全新空白角色庫") {
                                manager.switchToCleanVoiceboxDataDirectory(app: app)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("切換為全新獨立空白聲音角色庫")
                            .help("切換至 Klipora 獨立空白聲音角色庫，不影響原始資料")

                            Button("恢復預設模型快取位置") {
                                manager.resetVoiceboxModelsCacheDirectory(app: app)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("恢復預設 HuggingFace 模型快取位置")
                            .help("將模型快取路徑重設為 ~/.cache/huggingface/hub")
                        }
                        .padding(.top, 2)
                    }
                    .padding(9)
                    .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Card 4 — Google Colab (Honest Credential Detected vs Verified Logged-In State)

    private var card4GoogleColabSection: some View {
        // Honest badge contract: token file presence is NEVER labeled "已登入" until online usage check succeeds!
        let badge: ComponentReadinessBadge = {
            if manager.colabAuthVerified == true {
                return .ready("已線上驗證登入")
            } else if manager.colabAuthVerified == false {
                return .warning("授權未通過 · 請重新登入")
            } else if manager.colabBinaryPath != nil && manager.colabTokenFileExists {
                return .neutral("Colab 授權檔已找到，尚未線上檢查")
            } else if manager.colabBinaryPath != nil {
                return .neutral("CLI 可用 · 尚未登入（選用）")
            } else {
                return .neutral("未安裝 Colab CLI（選用）")
            }
        }()

        let summaryColor: Color = {
            if manager.colabAuthVerified == true {
                return setupEmerald
            } else if manager.colabAuthVerified == false {
                return setupAmber
            } else {
                return StudioTheme.textSecondary
            }
        }()

        return setupCardContainer(
            number: "04",
            icon: "cloud.bolt.fill",
            title: "Google Colab OAuth 登入（雲端影片 / H3 配音 · 選用）",
            accent: StudioTheme.neutralAccent,
            badge: badge,
            isHighlighted: hardwareStore.highlightedAnchor == .account
        ) {
            VStack(alignment: .leading, spacing: 8) {
                // Concise Task & Status
                Text(manager.colabAuthCheckSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(summaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                // Primary Controls Row: Video GPU Picker + Primary Auth Actions
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        colabGPUPickerCluster
                        Spacer(minLength: 4)
                        colabPrimaryActionButtons
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        colabGPUPickerCluster
                        colabPrimaryActionButtons
                    }
                }

                // Expandable Details (Auto-expands when two-step OAuth URL is generated)
                DisclosureGroup("檢視兩階段授權碼綁定、CLI 路徑與雲端 GPU 策略", isExpanded: $manager.showCard4Details) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Two-Step OAuth Code Input (preserved real colab_login.py url / code workflow)
                        VStack(alignment: .leading, spacing: 6) {
                            if let authURL = manager.colabPendingAuthURL {
                                HStack(spacing: 6) {
                                    Image(systemName: "link.circle.fill")
                                        .foregroundStyle(setupCyan)
                                    Text("Google 授權網址已產生：")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Button("開啟授權網頁") {
                                        if let url = URL(string: authURL) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .controlSize(.mini)
                                    .accessibilityLabel("開啟 Google OAuth 授權網頁")
                                    .help("於瀏覽器開啟 Google OAuth 授權網址")

                                    Button("複製網址") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(authURL, forType: .string)
                                        manager.colabAuthCheckSummary = "已複製 Google OAuth 授權網址至剪貼簿。"
                                    }
                                    .controlSize(.mini)
                                    .accessibilityLabel("複製 Google OAuth 授權網址")
                                    .help("將 Google OAuth 授權網址複製到剪貼簿")
                                }
                            }

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    colabAuthCodeInputField
                                    colabSubmitAuthCodeButton
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    colabAuthCodeInputField
                                    colabSubmitAuthCodeButton
                                }
                            }
                        }
                        .padding(8)
                        .background(surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))

                        keyValuePathRow(
                            label: "Colab CLI 執行檔",
                            path: manager.colabBinaryPath ?? "未偵測到 ~/.local/bin/colab（本機功能不受影響）"
                        )
                        keyValuePathRow(
                            label: "本機憑證狀態",
                            path: manager.colabTokenFileExists
                                ? (manager.colabAuthVerified == true
                                    ? "已偵測到憑證檔且已通過線上 usage 驗證"
                                    : "已偵測到本機憑證檔（尚未執行線上驗證，不直接標示為已登入）")
                                : "尚未建立本機憑證檔"
                        )
                        Text("雲端 GPU 策略：影片生成（Wan 2.2）預設採用 L4（可選 G4）以節省點數；長稿線上配音（H3 Ref2VA）依既有工作流需使用 A100。開啟設定或檢查額度絕不會配置付費 GPU。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var colabGPUPickerCluster: some View {
        HStack(spacing: 6) {
            Text("影片預設 GPU：")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Picker("影片預設雲端 GPU", selection: Binding(
                get: { manager.colabPreferredVideoGPU },
                set: { manager.setPreferredVideoColabGPU($0, app: app) }
            )) {
                Text("L4 (推薦)").tag("L4")
                Text("G4").tag("G4")
                Text("A100").tag("A100")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .accessibilityLabel("選擇雲端影片生成預設 GPU")
            .help("影片生成預設使用 L4 GPU；長稿線上配音則固定使用 A100 工作流")
        }
    }

    private var colabPrimaryActionButtons: some View {
        HStack(spacing: 6) {
            Button {
                Task { await manager.checkColabLoginStatus() }
            } label: {
                Label(manager.colabIsCheckingAuth ? "驗證中…" : "檢查登入與額度", systemImage: "person.badge.shield.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(setupCyan)
            .controlSize(.small)
            .disabled(manager.colabIsCheckingAuth || manager.colabBinaryPath == nil)
            .accessibilityLabel("檢查 Google Colab 登入與額度狀態")
            .help("連線驗證本機 Colab 憑證是否有效並查詢目前額度（不配置 GPU）")

            if manager.colabIsLaunchingAuth || manager.colabIsSubmittingCode {
                Button("取消登入流程") {
                    manager.cancelColabBrowserAuthentication()
                }
                .buttonStyle(.borderedProminent)
                .tint(setupRose)
                .controlSize(.small)
                .accessibilityLabel("取消 Google Colab 瀏覽器登入流程")
                .help("中止目前進行中的 Colab OAuth 授權流程")
            } else {
                Button {
                    manager.showCard4Details = true
                    manager.startColabBrowserAuthentication()
                } label: {
                    Label("啟動瀏覽器登入…", systemImage: "globe.badge.chevron.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(setupAmber)
                .controlSize(.small)
                .disabled(manager.colabBinaryPath == nil)
                .accessibilityLabel("啟動 Google Colab 瀏覽器登入")
                .help("開啟瀏覽器進行 Google Colab OAuth 登入並取得授權碼")
            }

            Button {
                manager.copyColabLoginCommandToClipboard()
            } label: {
                Label("複製登入指令", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            .accessibilityLabel("複製 Google Colab 登入指令")
            .help("複製終端機兩階段 OAuth 登入指令至剪貼簿")
        }
    }

    private var colabAuthCodeInputField: some View {
        HStack(spacing: 6) {
            Text("授權碼：")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            SecureField("貼上瀏覽器顯示的 Google 授權碼 (4/0A...)", text: $manager.colabManualAuthCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 220)
                .accessibilityLabel("Google Colab OAuth 授權碼輸入欄")
                .help("於瀏覽器完成 Google 登入後，將頁面上顯示的授權碼貼入此處")
        }
    }

    private var colabSubmitAuthCodeButton: some View {
        Button {
            manager.submitColabAuthorizationCode()
        } label: {
            Label(manager.colabIsSubmittingCode ? "驗證中…" : "送出授權碼並儲存憑證", systemImage: "checkmark.seal.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(setupEmerald)
        .controlSize(.small)
        .disabled(manager.colabIsSubmittingCode || manager.colabManualAuthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("送出 Google Colab 授權碼並儲存憑證")
        .help("驗證所貼上的 Google 授權碼並寫入本機 Colab 憑證")
    }

    // MARK: Card 5 — API Connections & macOS Keychain

    private var card5APIConnectionsSection: some View {
        let savedCount = SupportedAPIProvider.allCases.filter { manager.apiConnections[$0]?.hasStoredCredential == true }.count
        return setupCardContainer(
            number: "05",
            icon: "key.radiowaves.forward.fill",
            title: "API 金鑰與服務端點（macOS Keychain · 選用）",
            accent: StudioTheme.neutralAccent,
            badge: savedCount > 0 ? .ready("已存 \(savedCount) 組選用金鑰") : .neutral("未設定（選用 · 本機免金鑰可用）"),
            isHighlighted: hardwareStore.highlightedAnchor == .account
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("OpenAI / Gemini API 金鑰與 Google Colab 登入及瀏覽器官網登入彼此獨立；未設定時僅停用對應付費 API，官網按鈕與本機功能皆正常可用。金鑰僅加密保存於 macOS Keychain，絕不寫入專案檔。")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(SupportedAPIProvider.allCases) { provider in
                    apiProviderRow(for: provider)
                }

                DisclosureGroup("檢視安全傳輸規範與端點說明", isExpanded: $manager.showCard5Details) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(SupportedAPIProvider.allCases) { provider in
                            Text("• \(provider.shortName)：\(provider.usageNote)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(9)
                    .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func apiProviderRow(for provider: SupportedAPIProvider) -> some View {
        let cfg = manager.apiConnections[provider] ?? APIConnectionConfig(
            provider: provider,
            serviceURL: provider.defaultServiceURL
        )
        let isFixedOfficialHost = (provider == .openai_image || provider == .gemini_image)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: cfg.hasStoredCredential ? "lock.shield.fill" : "circle.dashed")
                        .font(.system(size: 9.5))
                    Text(cfg.hasStoredCredential ? "已存於 Keychain" : "未設定（選用）")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundStyle(cfg.hasStoredCredential ? setupEmerald : StudioTheme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((cfg.hasStoredCredential ? setupEmerald : StudioTheme.cream).opacity(0.10), in: Capsule())
            }

            if isFixedOfficialHost {
                HStack(spacing: 6) {
                    Text("固定官方主機：\(provider.defaultServiceURL)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StudioTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                apiSecretField(for: provider, cfg: cfg)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        apiURLField(for: provider, cfg: cfg)
                            .frame(width: 210)
                        apiSecretField(for: provider, cfg: cfg)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        apiURLField(for: provider, cfg: cfg)
                        apiSecretField(for: provider, cfg: cfg)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    apiActionButtons(for: provider, cfg: cfg)
                    Spacer(minLength: 4)
                    apiTestResultLabel(cfg: cfg)
                }
                VStack(alignment: .leading, spacing: 5) {
                    apiActionButtons(for: provider, cfg: cfg)
                    apiTestResultLabel(cfg: cfg)
                }
            }
        }
        .padding(9)
        .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 6))
    }

    private func apiURLField(for provider: SupportedAPIProvider, cfg: APIConnectionConfig) -> some View {
        TextField(provider.defaultServiceURL, text: Binding(
            get: { cfg.serviceURL },
            set: { manager.updateServiceURL(for: provider, url: $0, app: app) }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11, design: .monospaced))
        .accessibilityLabel("\(provider.shortName) 服務網址")
        .help("設定 \(provider.shortName) 的服務網址（預設 \(provider.defaultServiceURL)）")
    }

    private func apiSecretField(for provider: SupportedAPIProvider, cfg: APIConnectionConfig) -> some View {
        HStack(spacing: 6) {
            if cfg.isSecretRevealed {
                TextField(provider.credentialPlaceholder, text: Binding(
                    get: { cfg.draftSecret },
                    set: { manager.updateDraftSecret(for: provider, secret: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .accessibilityLabel("\(provider.shortName) 金鑰明文輸入欄")
            } else {
                SecureField(
                    cfg.hasStoredCredential ? "••••••••••••（已存於 Keychain）" : provider.credentialPlaceholder,
                    text: Binding(
                        get: { cfg.draftSecret },
                        set: { manager.updateDraftSecret(for: provider, secret: $0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .accessibilityLabel("\(provider.shortName) 金鑰密碼輸入欄")
            }

            Button {
                manager.toggleRevealSecret(for: provider)
            } label: {
                Image(systemName: cfg.isSecretRevealed ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(cfg.isSecretRevealed ? "隱藏 \(provider.shortName) 金鑰" : "顯示 \(provider.shortName) 金鑰")
            .help(cfg.isSecretRevealed ? "隱藏金鑰內容" : "顯示金鑰內容")
        }
    }

    private func apiActionButtons(for provider: SupportedAPIProvider, cfg: APIConnectionConfig) -> some View {
        HStack(spacing: 8) {
            Button {
                manager.saveCredentialToKeychain(for: provider, app: app)
            } label: {
                Text("儲存")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
            .accessibilityLabel("儲存 \(provider.shortName) 網址與金鑰至 Keychain")
            .help("驗證網址並將 \(provider.shortName) 金鑰安全寫入 macOS 鑰匙圈")

            Button {
                Task { await manager.testAPIConnection(for: provider, app: app) }
            } label: {
                Text(cfg.isTesting ? "測試中…" : "測試連線")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            .disabled(cfg.isTesting)
            .accessibilityLabel("測試 \(provider.shortName) 連線")
            .help("向 \(provider.shortName) 端點發送連線與身分驗證測試")

            if cfg.hasStoredCredential {
                Button(role: .destructive) {
                    manager.disconnectAndRemoveCredential(for: provider)
                } label: {
                    Text("移除")
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .destructive, compact: true))
                .accessibilityLabel("從 Keychain 移除 \(provider.shortName) 憑證")
                .help("從 macOS 鑰匙圈刪除已儲存的 \(provider.shortName) 金鑰")
            }
        }
    }

    @ViewBuilder
    private func apiTestResultLabel(cfg: APIConnectionConfig) -> some View {
        if let msg = cfg.testStatusMessage {
            HStack(spacing: 4) {
                Image(systemName: cfg.testSucceeded == true ? "checkmark.circle.fill" : (cfg.testSucceeded == false ? "exclamationmark.triangle.fill" : "info.circle"))
                    .foregroundStyle(cfg.testSucceeded == true ? setupEmerald : (cfg.testSucceeded == false ? setupRose : setupCyan))
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(cfg.testSucceeded == true ? setupEmerald : (cfg.testSucceeded == false ? setupRose : .white.opacity(0.85)))
                    .lineLimit(2)
            }
        }
    }

    // MARK: Card 6 — FFmpeg / Runtime / Architecture / AI-Audio Dependencies

    private var card6FFmpegAndDependenciesSection: some View {
        let readyModules = audioAI.modules.values.filter(\.isReady).count
        let badge: ComponentReadinessBadge = {
            if !manager.isAppleSiliconHost {
                return .warning("非 arm64 架構")
            } else if manager.ffmpegResolvedPath != nil && manager.bundledNodeReady {
                return .ready("arm64 執行環境與 FFmpeg 就緒")
            } else if manager.bundledNodeReady {
                return .optionalMissing("內建 Node 可用 · 待設定 FFmpeg")
            } else {
                return .reusable("開發環境模式")
            }
        }()

        return setupCardContainer(
            number: "06",
            icon: "wrench.and.screwdriver.fill",
            title: "FFmpeg 影音轉碼、本地音訊工具與麥克風權限",
            accent: StudioTheme.neutralAccent,
            badge: badge,
            isHighlighted: hardwareStore.highlightedAnchor == .runtime
        ) {
            VStack(alignment: .leading, spacing: 8) {
                // Concise Task & Status
                let ffmpegText = manager.ffmpegResolvedPath != nil
                    ? "FFmpeg 已就緒（\(manager.ffmpegSourceDescription)）"
                    : "尚未找到 FFmpeg（請安裝或指定路徑）"
                let audioAIText = audioAI.hasLoadedStatus
                    ? (audioAI.venvReady ? "本地音訊 AI 已就緒（\(readyModules)/4 模組）" : "本地音訊 AI 選用未安裝")
                    : "本地音訊 AI 按需載入"

                Text("主機架構：\(manager.hostArchitecture) · \(ffmpegText) · \(audioAIText) · 麥克風：\(recorder.authorizationLabel)。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                if let ver = manager.ffmpegVersionSummary {
                    Text(ver)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(setupEmerald)
                }

                // Primary Actions
                adaptiveButtonRow {
                    Button {
                        Task { await manager.verifyFFmpegExecution() }
                    } label: {
                        Label(manager.isProbingFFmpeg ? "驗證中…" : "驗證 FFmpeg", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(setupEmerald)
                    .controlSize(.small)
                    .disabled(manager.isProbingFFmpeg)
                    .accessibilityLabel("驗證 FFmpeg 執行檔與架構")
                    .help("執行 ffmpeg -version 驗證轉碼執行檔可用性與硬體架構")

                    Button {
                        manager.chooseCustomFFmpegBinary(app: app)
                    } label: {
                        Label("指定 FFmpeg 路徑…", systemImage: "folder")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("選擇自訂 FFmpeg 執行檔路徑")
                    .help("手動選擇本機上的 ffmpeg 可執行檔")

                    Button {
                        manager.copyHomebrewFFmpegInstallCommand()
                    } label: {
                        Label("複製安裝指令", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("複製 Homebrew FFmpeg 安裝指令")
                    .help("複製 brew install ffmpeg 指令至剪貼簿")

                    Button {
                        audioAI.refreshStatus()
                    } label: {
                        Label(audioAI.isRefreshingStatus ? "檢查中…" : "檢查音訊 AI", systemImage: "waveform")
                    }
                    .controlSize(.small)
                    .disabled(audioAI.isRefreshingStatus)
                    .accessibilityLabel("檢查本地音訊 AI 模組狀態")
                    .help("檢查 Faster-Whisper ASR 與人聲分離等選用音訊模組安裝狀態")

                    if recorder.authorizationStatus == .denied || recorder.authorizationStatus == .restricted {
                        Button("開啟麥克風權限設定") {
                            recorder.openMicrophonePrivacySettings()
                        }
                        .controlSize(.small)
                        .accessibilityLabel("開啟系統設定中的麥克風隱私權限")
                        .help("前往 macOS 系統設定開啟 Klipora 的麥克風錄音權限")
                    }
                }

                // Expandable Details
                DisclosureGroup("檢視內建執行檔路徑與跨電腦安裝提示", isExpanded: $manager.showCard6Details) {
                    VStack(alignment: .leading, spacing: 5) {
                        keyValuePathRow(
                            label: "FFmpeg 執行檔路徑",
                            path: manager.ffmpegResolvedPath ?? "未找到 ffmpeg（新電腦請執行 brew install ffmpeg 或指定路徑）"
                        )
                        keyValuePathRow(
                            label: "FFprobe 執行檔路徑",
                            path: manager.ffprobeResolvedPath ?? "未找到 ffprobe（自動以 AVFoundation 讀取片長）"
                        )
                        keyValuePathRow(
                            label: "內建 Node.js / 字卡引擎",
                            path: "\(manager.bundledNodeReady ? "已內建 Node.js" : "外部 Node") · \(manager.bundledHyperFramesReady ? "已內建 HyperFrames" : "開發路徑") · \(manager.bundledTextRenderReady ? "已內建 CoreText textrender" : "開發路徑")"
                        )
                        if manager.ffmpegIsHomebrewLinked {
                            Text("跨電腦安裝提示：目前使用系統 Homebrew 的 FFmpeg。若將應用程式移至未安裝 Homebrew 的全新 Mac，請於新電腦安裝 FFmpeg 或指定獨立靜態編譯執行檔。")
                                .font(.system(size: 10))
                                .foregroundStyle(setupAmber)
                        }
                    }
                    .padding(9)
                    .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Tab 2 — Dependency & Redistribution Manifest + Licenses

    private var manifestAndLicensesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("捆綁與選用元件清單、授權聲明與功能邊界")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                Text("明確區分「隨 App 內建捆綁」、「本機自動重用」、「使用者按需下載」與「外部選用工具」，不將外部選用依賴誇稱為已完整內建。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            ForEach(manager.dependencyManifestEntries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(entry.name)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            manifestBadge(for: entry)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(.white)
                            manifestBadge(for: entry)
                        }
                    }

                    HStack(spacing: 14) {
                        Text("規格：\(entry.versionOrArch)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(setupCyan)
                        Text("容量：\(entry.approxSize)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("授權：\(entry.license)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(setupEmerald)
                    }

                    keyValuePathRow(label: "路徑 / 來源", path: entry.sourceOrPath)

                    Text(entry.notes)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(entry.distributionKind.color.opacity(0.25), lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("整合語音後端開源授權聲明（MIT License）", systemImage: "doc.text.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                Text("""
Copyright (c) 2026 Voicebox Contributors.
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

注意：應用程式授權不自動涵蓋第三方大型模型權重（如 Qwen3-TTS 採 Apache-2.0、ComfyUI 採 GPL-3.0）或使用者系統自行安裝之外部 FFmpeg / Python 執行檔；各項元件均依其原始官方授權條款提供。
""")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(setupDarkWell, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func manifestBadge(for entry: DependencyManifestEntry) -> some View {
        Text(entry.distributionKind.rawValue)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(entry.distributionKind.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(entry.distributionKind.color.opacity(0.14), in: Capsule())
    }

    // MARK: Footer Bar

    private var footerBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                footerNoteLabel
                Spacer(minLength: 8)
                footerActionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                footerNoteLabel
                HStack {
                    Spacer()
                    footerActionButtons
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(panel)
    }

    private var footerNoteLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(setupEmerald)
                .font(.system(size: 11))
            Text("設定已即時保存，可隨時從工作台頂部「元件與連線設定」重新開啟。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var footerActionButtons: some View {
        HStack(spacing: 10) {
            Button("稍後設定") {
                manager.dismissForLater()
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: false))
            .accessibilityLabel("稍後設定，先進入工作台")
            .help("暫時關閉此設定視窗並進入工作台，所有已設定路徑均會保留")

            Button {
                manager.markFirstRunCompleted()
            } label: {
                Label(manager.isFirstRunMode ? "完成並開始使用" : "完成", systemImage: "checkmark")
            }
            .buttonStyle(KliporaPillButtonStyle(variant: .primary, compact: false))
            .accessibilityLabel(manager.isFirstRunMode ? "完成首次設定並開始使用" : "完成設定並返回工作台")
            .help("儲存並返回 Klipora 工作台")
        }
    }

    // MARK: Reusable Card Layout Helpers

    private func adaptiveButtonRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            content()
            Spacer(minLength: 0)
        }
    }

    private func setupCardContainer<Content: View>(
        number: String,
        icon: String,
        title: String,
        accent: Color,
        badge: ComponentReadinessBadge,
        isHighlighted: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    cardHeaderLeft(number: number, icon: icon, title: title, accent: accent)
                    Spacer(minLength: 6)
                    cardHeaderBadge(badge: badge)
                }
                VStack(alignment: .leading, spacing: 5) {
                    cardHeaderLeft(number: number, icon: icon, title: title, accent: accent)
                    cardHeaderBadge(badge: badge)
                }
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isHighlighted ? StudioTheme.elevated : Color(red: 0.114, green: 0.118, blue: 0.133)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isHighlighted ? StudioTheme.coral.opacity(0.70) : Color.white.opacity(0.075),
                    lineWidth: isHighlighted ? 1.5 : 1
                )
        )
    }

    private func cardHeaderLeft(number: String, icon: String, title: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private func cardHeaderBadge(badge: ComponentReadinessBadge) -> some View {
        HStack(spacing: 4) {
            Image(systemName: badge.iconName)
                .font(.system(size: 10))
            Text(badge.label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(badge.tintColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(badge.tintColor.opacity(0.14), in: Capsule())
    }

    private func keyValuePathRow(label: String, path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label)：")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 7. Dedicated Local Voice Model Manager Sheet (Symmetrical with LocalModelManagerSheet)

struct LocalVoiceModelManagerSheet: View {
    @ObservedObject var app: Studio
    @ObservedObject var manager: PortabilitySetupManager
    @ObservedObject private var voicebox = VoiceboxServiceController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本機語音模型管理")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text("直接從 HuggingFace 官方倉庫下載或移除 Qwen3-TTS 本機語音模型，完成後即可於配音工作台選用。")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textMuted)
                }
                Spacer()
                Button("開啟快取目錄") {
                    let url = URL(fileURLWithPath: manager.voiceboxModelsDirPath, isDirectory: true)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                Button("關閉") { dismiss() }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            }
            .padding(18)
            .background(panel)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KliporaGroupedCard(padding: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.fill")
                                .foregroundStyle(StudioTheme.neutralAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("語音模型快取路徑：\(manager.voiceboxModelsDirPath)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(StudioTheme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("可用磁碟空間：\(manager.voiceboxModelsDirFreeBytes.map(setupFormatBytes) ?? "未知") · 共連結 \(manager.voiceboxProfileCountEstimate) 個聲音角色")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(StudioTheme.textMuted)
                            }
                            Spacer()
                        }
                    }

                    ForEach(manager.voiceboxModelItems) { item in
                        let isDownloading = manager.downloadingVoiceModelRepoID == item.repoID
                        KliporaGroupedCard(padding: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .center, spacing: 10) {
                                    Image(systemName: item.isComplete ? "checkmark.seal.fill" : (isDownloading ? "arrow.down.circle.fill" : "icloud.and.arrow.down"))
                                        .font(.system(size: 16))
                                        .foregroundStyle(item.isComplete ? setupEmerald : (isDownloading ? StudioTheme.neutralAccent : setupAmber))
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(item.displayName)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(StudioTheme.textPrimary)
                                            Text(item.engineLabel)
                                                .font(.system(size: 9.5, weight: .semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(Color.white.opacity(0.08), in: Capsule())
                                                .foregroundStyle(StudioTheme.textSecondary)
                                        }
                                        Text("\(item.repoID) · 預估 \(item.expectedSizeDescription)\(item.diskSizeBytes > 0 ? "（本機已佔用 \(setupFormatBytes(item.diskSizeBytes))）" : "")")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(StudioTheme.textMuted)
                                    }
                                    Spacer(minLength: 8)
                                    if isDownloading {
                                        Text("\(Int(manager.voiceModelDownloadProgress * 100))%")
                                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(StudioTheme.neutralAccent)
                                    } else if item.isComplete {
                                        Button("移除釋放空間") {
                                            manager.removeVoiceModelCache(item, app: app)
                                        }
                                        .buttonStyle(KliporaPillButtonStyle(variant: .destructive, compact: true))
                                        .disabled(manager.downloadingVoiceModelRepoID != nil)
                                    } else {
                                        Button {
                                            manager.downloadVoiceModel(item, app: app)
                                        } label: {
                                            Label("下載模型", systemImage: "arrow.down.circle")
                                        }
                                        .buttonStyle(KliporaPillButtonStyle(variant: .accent, compact: true))
                                        .disabled(manager.downloadingVoiceModelRepoID != nil)
                                    }
                                }
                                if isDownloading {
                                    ProgressView(value: manager.voiceModelDownloadProgress)
                                        .tint(StudioTheme.neutralAccent)
                                    if !manager.voiceModelDownloadStatus.isEmpty {
                                        Text(manager.voiceModelDownloadStatus)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(StudioTheme.textSecondary)
                                    }
                                }
                            }
                        }
                    }

                    // MediaTek BreezyVoice (Taiwanese Mandarin Zero-Shot TTS sharing all 68 voice profiles)
                    KliporaGroupedCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: voicebox.isBreezyVoiceInstalled ? "checkmark.seal.fill" : (voicebox.breezyVoiceInstalling ? "arrow.down.circle.fill" : "waveform.badge.mic"))
                                    .font(.system(size: 16))
                                    .foregroundStyle(voicebox.isBreezyVoiceInstalled ? setupEmerald : (voicebox.breezyVoiceInstalling ? StudioTheme.neutralAccent : setupAmber))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("MediaTek BreezyVoice（台灣國語 · 共用 68 聲線）")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(StudioTheme.textPrimary)
                                        Text("Apache-2.0")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Color.white.opacity(0.08), in: Capsule())
                                            .foregroundStyle(StudioTheme.textSecondary)
                                    }
                                    Text("MediaTek-Research/BreezyVoice · 預估 ~2.8 GB\(voicebox.breezyVoiceDiskBytes > 0 ? "（本機已佔用 \(setupFormatBytes(voicebox.breezyVoiceDiskBytes))）" : "")")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(StudioTheme.textMuted)
                                    Text("預設台灣國語語音引擎，支援注音多音字標註（如 [:ㄏㄠ3]），直接共用現有 68 個聲音角色。")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                }
                                Spacer(minLength: 8)
                                if voicebox.breezyVoiceInstalling {
                                    Button("取消") {
                                        voicebox.cancelBreezyVoiceInstall()
                                    }
                                    .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                                } else if voicebox.isBreezyVoiceInstalled {
                                    Button("移除釋放空間") {
                                        voicebox.uninstallBreezyVoice(removeAll: false)
                                    }
                                    .buttonStyle(KliporaPillButtonStyle(variant: .destructive, compact: true))
                                } else {
                                    Button {
                                        voicebox.installBreezyVoice()
                                    } label: {
                                        Label("一鍵安裝", systemImage: "arrow.down.circle")
                                    }
                                    .buttonStyle(KliporaPillButtonStyle(variant: .accent, compact: true))
                                }
                            }
                            if voicebox.breezyVoiceInstalling {
                                ProgressView(value: voicebox.breezyVoiceInstallProgress)
                                    .tint(StudioTheme.neutralAccent)
                                if !voicebox.breezyVoiceInstallStage.isEmpty {
                                    Text(voicebox.breezyVoiceInstallStage)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(StudioTheme.textSecondary)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(red: 0.082, green: 0.084, blue: 0.094))
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 460, idealHeight: 540)
        .background(panel)
        .preferredColorScheme(.dark)
    }
}
