import AppKit
import Foundation
import Network
import SwiftUI

extension Notification.Name {
    static let motionDeskOpenSettings = Notification.Name("MotionDesk.OpenSettings")
}

// MARK: - Conservative NWPathMonitor Reachability

enum NetworkAvailabilityState: Equatable {
    case checking
    case online
    case offline

    var label: String {
        switch self {
        case .checking: return "網路狀態確認中"
        case .online: return "已連線（可使用線上項目）"
        case .offline: return "離線（僅停用線上項目，本機功能完全可用）"
        }
    }
}

@MainActor
final class NetworkReachabilityMonitor: ObservableObject {
    static let shared = NetworkReachabilityMonitor()

    @Published private(set) var state: NetworkAvailabilityState = .checking
    @Published private(set) var lastCheckedAt: Date? = nil

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "local.motiondesk.network-monitor")

    /// Conservative check: only `.offline` disables online providers; `.checking` never globally blocks the app.
    var isOffline: Bool { state == .offline }
    var isOnline: Bool { state == .online }

    init(autoStart: Bool = true) {
        if autoStart {
            startMonitoring()
        }
    }

    func startMonitoring() {
        monitor?.cancel()
        let nextMonitor = NWPathMonitor()
        nextMonitor.pathUpdateHandler = { [weak self] path in
            let nextState: NetworkAvailabilityState = (path.status == .satisfied) ? .online : .offline
            Task { @MainActor [weak self] in
                self?.state = nextState
                self?.lastCheckedAt = Date()
            }
        }
        nextMonitor.start(queue: queue)
        self.monitor = nextMonitor
    }

    func recheckNow() {
        state = .checking
        startMonitoring()
    }

    /// Loopback endpoints must remain usable regardless of external internet availability.
    static func isLoopbackURL(_ rawURL: String) -> Bool {
        guard let comps = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = comps.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

// MARK: - Online Image Provider Specification (OpenAI & Gemini)

enum OnlineImageProvider: String, CaseIterable, Identifiable, Codable {
    case openai = "openai_image"
    case gemini = "gemini_image"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI（圖片）"
        case .gemini: return "Gemini（圖片）"
        }
    }

    var webButtonTitle: String {
        switch self {
        case .openai: return "在瀏覽器開啟 ChatGPT 官網"
        case .gemini: return "在瀏覽器開啟 Gemini 官網"
        }
    }

    var webURL: URL {
        switch self {
        case .openai: return URL(string: "https://chatgpt.com/")!
        case .gemini: return URL(string: "https://gemini.google.com/")!
        }
    }

    var docsURL: URL {
        switch self {
        case .openai: return URL(string: "https://developers.openai.com/api/docs/guides/image-generation")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/image-generation")!
        }
    }

    var pricingURL: URL {
        switch self {
        case .openai: return URL(string: "https://developers.openai.com/api/docs/pricing")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!
        }
    }

    var fixedAPIHost: String {
        switch self {
        case .openai: return "api.openai.com"
        case .gemini: return "generativelanguage.googleapis.com"
        }
    }

    var defaultModelID: String {
        switch self {
        case .openai: return "gpt-image-2.5-flare"
        case .gemini: return "gemini-nano-banana-2.1"
        }
    }

    var keychainProvider: SupportedAPIProvider {
        switch self {
        case .openai: return .openai_image
        case .gemini: return .gemini_image
        }
    }

    var billingDisclaimer: String {
        switch self {
        case .openai:
            return "API 呼叫依 OpenAI 官方定價計費；ChatGPT 網頁版免費額度不適用於 API。金鑰僅存於 macOS Keychain，不會寫入專案檔或紀錄。"
        case .gemini:
            return "Gemini 圖片 API 目前不提供免費層（Free Tier Not Available），網頁版免費額度不適用於 API。金鑰僅存於 macOS Keychain，不會寫入專案檔或紀錄。"
        }
    }

    var modelDefaultsKey: String { "MotionDesk.onlineImage.\(rawValue).modelID" }
    var billingAckDefaultsKey: String { "MotionDesk.onlineImage.\(rawValue).billingAcknowledged" }
    var qualityDefaultsKey: String { "MotionDesk.onlineImage.\(rawValue).quality" }
    var imageSizeDefaultsKey: String { "MotionDesk.onlineImage.\(rawValue).imageSize" }

    func savedModelID(defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: modelDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultModelID : value
    }

    func setSavedModelID(_ value: String, defaults: UserDefaults = .standard) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed.isEmpty ? defaultModelID : trimmed, forKey: modelDefaultsKey)
    }

    func isBillingAcknowledged(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: billingAckDefaultsKey)
    }

    func setBillingAcknowledged(_ accepted: Bool, defaults: UserDefaults = .standard) {
        defaults.set(accepted, forKey: billingAckDefaultsKey)
    }

    func savedOpenAIQuality(defaults: UserDefaults = .standard) -> String {
        let q = defaults.string(forKey: qualityDefaultsKey) ?? "low"
        return ["low", "medium", "high"].contains(q) ? q : "low"
    }

    func setSavedOpenAIQuality(_ quality: String, defaults: UserDefaults = .standard) {
        defaults.set(quality, forKey: qualityDefaultsKey)
    }

    func savedGeminiImageSize(defaults: UserDefaults = .standard) -> String {
        let s = defaults.string(forKey: imageSizeDefaultsKey) ?? "1K"
        return ["1K", "2K"].contains(s) ? s : "1K"
    }

    func setSavedGeminiImageSize(_ size: String, defaults: UserDefaults = .standard) {
        defaults.set(size, forKey: imageSizeDefaultsKey)
    }

    func hasKeychainCredential(service: String = KeychainCredentialsStore.defaultService) -> Bool {
        KeychainCredentialsStore.hasCredential(account: keychainProvider.keychainAccount, service: service)
    }

    /// Strict opt-in API gate: requires Keychain key + explicit billing acknowledgement + network online.
    static func canInvokeAPI(
        provider: OnlineImageProvider,
        hasKey: Bool,
        billingAccepted: Bool,
        networkState: NetworkAvailabilityState
    ) -> (allowed: Bool, reason: String?) {
        if networkState == .offline {
            return (false, "目前處於離線狀態，已停用 \(provider.displayName) 線上 API；本機圖片、影片與語音功能仍可正常使用。")
        }
        if !hasKey {
            return (false, "尚未在「元件與連線設定」的 macOS Keychain 設定 \(provider.displayName) API 金鑰。")
        }
        if !billingAccepted {
            return (false, "請先勾選同意 \(provider.displayName) 官方 API 計費與額度說明後，才可啟用線上 API 生成。")
        }
        return (true, nil)
    }
}

// MARK: - SwiftUI Controls in Generation Dock

@MainActor
private final class OnlineImageControlsState: ObservableObject {
    @Published var modelID: String = ""
    @Published var billingAccepted: Bool = false
    @Published var openAIQuality: String = "low"
    @Published var geminiImageSize: String = "1K"
    @Published var hasKey: Bool = false
}

struct OnlineImageControls: View {
    let provider: OnlineImageProvider
    @ObservedObject var network: NetworkReachabilityMonitor = .shared
    @StateObject private var vm = OnlineImageControlsState()

    private var gate: (allowed: Bool, reason: String?) {
        OnlineImageProvider.canInvokeAPI(
            provider: provider,
            hasKey: vm.hasKey,
            billingAccepted: vm.billingAccepted,
            networkState: network.state
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section 1: Official Web Browser Button
            VStack(alignment: .leading, spacing: 6) {
                Text("官方網頁入口（免 API 金鑰）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(provider.webURL)
                    } label: {
                        Label(provider.webButtonTitle, systemImage: "safari")
                    }
                    .disabled(network.isOffline)
                    Button("官方定價與文件") {
                        NSWorkspace.shared.open(provider.pricingURL)
                    }
                    .font(.caption)
                    .disabled(network.isOffline)
                }
                Text("以您的瀏覽器正常登入官網生圖並下載，再匯入 MotionDesk 素材庫；不讀取瀏覽器 Cookie 或重複使用工作階段權杖。")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.textMuted)
            }
            .padding(9)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))

            // Section 2: Opt-in Official REST API
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("官方 REST API（純文字生圖 · 選擇性啟用）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Spacer()
                    Text(gate.allowed ? "API 已就緒" : "API 已停用")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((gate.allowed ? StudioTheme.success : StudioTheme.warning).opacity(0.2), in: Capsule())
                        .foregroundStyle(gate.allowed ? StudioTheme.success : StudioTheme.warning)
                }

                Text("本版官方 API 僅支援純文字生圖（Text-to-Image），不支援參考圖片、參考影片或本機 LoRA；若專案已選取這些項目，生成前須先清除。")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.warmHighlight)

                if network.isOffline {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash").foregroundStyle(StudioTheme.warning)
                        Text("目前離線，線上 API 與官網按鈕已暫時停用；本機 ComfyUI 與剪輯功能不受影響。")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.warning)
                        Spacer()
                        Button("重試") { network.recheckNow() }.font(.caption2)
                    }
                }

                HStack(spacing: 8) {
                    Text("模型 ID")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                    TextField(provider.defaultModelID, text: $vm.modelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .onChange(of: vm.modelID) { _, newValue in
                            provider.setSavedModelID(newValue)
                        }
                }
                .disabled(network.isOffline)

                if provider == .openai {
                    Picker("品質（Quality）", selection: $vm.openAIQuality) {
                        Text("低（low）").tag("low")
                        Text("中（medium）").tag("medium")
                        Text("高（high）").tag("high")
                    }
                    .pickerStyle(.segmented)
                    .font(.caption)
                    .disabled(network.isOffline)
                    .onChange(of: vm.openAIQuality) { _, val in provider.setSavedOpenAIQuality(val) }
                } else {
                    Picker("解析度（image_size）", selection: $vm.geminiImageSize) {
                        Text("1K").tag("1K")
                        Text("2K").tag("2K")
                    }
                    .pickerStyle(.segmented)
                    .font(.caption)
                    .disabled(network.isOffline)
                    .onChange(of: vm.geminiImageSize) { _, val in provider.setSavedGeminiImageSize(val) }
                }

                Toggle(isOn: $vm.billingAccepted) {
                    Text("我了解此操作將呼叫 \(provider.fixedAPIHost) 官方付費 API，且網頁版免費額度不適用。")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                .toggleStyle(.checkbox)
                .disabled(network.isOffline)
                .onChange(of: vm.billingAccepted) { _, val in provider.setBillingAcknowledged(val) }

                Text(provider.billingDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.textMuted)

                HStack(spacing: 8) {
                    Image(systemName: vm.hasKey ? "key.fill" : "key.slash")
                        .foregroundStyle(vm.hasKey ? StudioTheme.success : StudioTheme.warning)
                    Text(vm.hasKey ? "Keychain 已設定 API 金鑰" : "Keychain 尚未設定 API 金鑰")
                        .font(.caption2)
                        .foregroundStyle(vm.hasKey ? StudioTheme.success : StudioTheme.warning)
                    Spacer()
                    Button("前往元件與連線設定…") {
                        NotificationCenter.default.post(name: .motionDeskOpenSettings, object: nil)
                    }
                    .font(.caption2)
                }
            }
            .padding(9)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))
            .opacity(network.isOffline ? 0.65 : 1.0)
        }
        .onAppear { syncState() }
        .onChange(of: provider) { _, _ in syncState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.hasKey = provider.hasKeychainCredential()
        }
    }

    private func syncState() {
        vm.modelID = provider.savedModelID()
        vm.billingAccepted = provider.isBillingAcknowledged()
        vm.openAIQuality = provider.savedOpenAIQuality()
        vm.geminiImageSize = provider.savedGeminiImageSize()
        vm.hasKey = provider.hasKeychainCredential()
    }
}
