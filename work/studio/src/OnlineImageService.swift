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

    private var installedDesktopAppURL: URL? {
        let appName = provider == .openai ? "ChatGPT.app" : "Gemini.app"
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/\(appName)"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(appName)"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section 1: Official Desktop App & Web Browser Entry
            VStack(alignment: .leading, spacing: 8) {
                Text("官方桌面程式與網頁入口（免 API 金鑰）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                HStack(spacing: 6) {
                    if let appURL = installedDesktopAppURL {
                        Button {
                            NSWorkspace.shared.open(appURL)
                        } label: {
                            Label(provider == .openai ? "開啟 ChatGPT 桌面版" : "開啟 Gemini 桌面版", systemImage: "macwindow")
                                .lineLimit(1)
                        }
                        .buttonStyle(KliporaPillButtonStyle(variant: .accent, compact: true))
                    }
                    Button {
                        NSWorkspace.shared.open(provider.webURL)
                    } label: {
                        Label("開啟官網", systemImage: "safari")
                            .lineLimit(1)
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                    .disabled(network.isOffline)

                    Button {
                        NSWorkspace.shared.open(provider.pricingURL)
                    } label: {
                        Text("定價")
                            .lineLimit(1)
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                    .disabled(network.isOffline)
                }
                Text("可用既有訂閱於桌面版／網頁生圖後，直接拖入 Klipora 左側素材庫。")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))

            // Section 2: Opt-in Official REST API (progressive disclosure: hide parameters when API key is not configured)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("官方 REST API")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Spacer()
                    Text(gate.allowed ? "已就緒" : (vm.hasKey ? "待確認計費" : "未啟用"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background((gate.allowed ? StudioTheme.success : StudioTheme.textMuted).opacity(0.18), in: Capsule())
                        .foregroundStyle(gate.allowed ? StudioTheme.success : StudioTheme.textSecondary)
                }

                if network.isOffline {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash").foregroundStyle(StudioTheme.warning)
                        Text("目前離線，線上 API 暫時停用；本機 ComfyUI 與剪輯不受影響。")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.warning)
                        Spacer()
                        Button("重試") { network.recheckNow() }
                            .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                    }
                }

                if vm.hasKey {
                    Text("支援純文字與最多 8 張多參考圖（角色三視圖／場景／物品）。")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text("模型 ID")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.textSecondary)
                            .fixedSize()
                        TextField(provider.defaultModelID, text: $vm.modelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                            .onChange(of: vm.modelID) { _, newValue in
                                provider.setSavedModelID(newValue)
                            }
                    }
                    .disabled(network.isOffline)

                    if provider == .openai {
                        HStack(spacing: 8) {
                            Text("品質")
                                .font(.caption)
                                .foregroundStyle(StudioTheme.textSecondary)
                                .fixedSize()
                            KliporaSegmentedControl(
                                options: [("low", "低"), ("medium", "中"), ("high", "高")],
                                selection: $vm.openAIQuality
                            )
                            .disabled(network.isOffline)
                            .onChange(of: vm.openAIQuality) { _, val in provider.setSavedOpenAIQuality(val) }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("解析度")
                                .font(.caption)
                                .foregroundStyle(StudioTheme.textSecondary)
                                .fixedSize()
                            KliporaSegmentedControl(
                                options: [("1K", "1K"), ("2K", "2K")],
                                selection: $vm.geminiImageSize
                            )
                            .disabled(network.isOffline)
                            .onChange(of: vm.geminiImageSize) { _, val in provider.setSavedGeminiImageSize(val) }
                        }
                    }

                    Toggle(isOn: $vm.billingAccepted) {
                        Text("我了解此操作將呼叫 \(provider.fixedAPIHost) 官方付費 API。")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(network.isOffline)
                    .onChange(of: vm.billingAccepted) { _, val in provider.setBillingAcknowledged(val) }

                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(StudioTheme.success)
                            .font(.caption2)
                        Text("已設定 API 金鑰")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.success)
                        Spacer()
                        Button("管理金鑰") {
                            PortabilitySetupManager.shared.selectedSidebar = .cloudAPI
                            NotificationCenter.default.post(name: .motionDeskOpenSettings, object: nil)
                        }
                        .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("設定 API 金鑰後即可在 Klipora 內直接生圖（支援多圖參考）。")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("設定金鑰") {
                            PortabilitySetupManager.shared.selectedSidebar = .cloudAPI
                            NotificationCenter.default.post(name: .motionDeskOpenSettings, object: nil)
                        }
                        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                    }
                }
            }
            .padding(11)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
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
