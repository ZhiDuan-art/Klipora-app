import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let kliporaOpenOnboarding = Notification.Name("Klipora.OpenOnboarding")
    static let kliporaOpenAbout = Notification.Name("Klipora.OpenAbout")
}

// MARK: - Startup Self-Check State & Adobe-Style Splash Screen

enum SelfCheckStatus: Equatable {
    case checking
    case ready
    case optionalAttention
    case warning

    var iconName: String {
        switch self {
        case .checking: return "clock.arrow.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .optionalAttention: return "circle.dashed"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .checking: return StudioTheme.textMuted
        case .ready: return StudioTheme.success
        case .optionalAttention: return StudioTheme.neutralAccent
        case .warning: return StudioTheme.warning
        }
    }
}

struct StartupCheckItem: Identifiable, Equatable {
    let id: String
    let titleKey: String
    var status: SelfCheckStatus
    var detail: String
}

@MainActor
final class KliporaStartupController: ObservableObject {
    static let shared = KliporaStartupController()
    static let onboardingCompletedKey = "Klipora.onboardingCompleted.v1"

    @Published var isSplashVisible: Bool = true
    @Published var isOnboardingPresented: Bool = false
    @Published var isAboutPresented: Bool = false
    @Published var progress: Double = 0.0
    @Published var checkComplete: Bool = false
    @Published var items: [StartupCheckItem] = [
        StartupCheckItem(id: "hw", titleKey: "splash.item.hardware", status: .checking, detail: "…"),
        StartupCheckItem(id: "engines", titleKey: "splash.item.engines", status: .checking, detail: "…"),
        StartupCheckItem(id: "ffmpeg", titleKey: "splash.item.ffmpeg", status: .checking, detail: "…"),
        StartupCheckItem(id: "comfy", titleKey: "splash.item.comfy", status: .checking, detail: "…"),
        StartupCheckItem(id: "voice", titleKey: "splash.item.voice", status: .checking, detail: "…"),
        StartupCheckItem(id: "cloud", titleKey: "splash.item.cloud", status: .checking, detail: "…"),
    ]

    var hasCriticalIssue: Bool {
        items.contains { $0.status == .warning }
    }

    func runStartupSelfCheck() {
        isSplashVisible = true
        checkComplete = false
        progress = 0.12

        Task {
            let results = await Task.detached(priority: .userInitiated) {
                Self.performLocalSelfCheck()
            }.value

            for (idx, item) in results.enumerated() {
                if idx < items.count {
                    items[idx] = item
                }
                progress = Double(idx + 1) / Double(max(1, results.count))
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            checkComplete = true

            let completedBefore = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            if !completedBefore {
                try? await Task.sleep(nanoseconds: 650_000_000)
                if isSplashVisible {
                    isSplashVisible = false
                    isOnboardingPresented = true
                }
            } else if !hasCriticalIssue {
                try? await Task.sleep(nanoseconds: 900_000_000)
                if isSplashVisible {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isSplashVisible = false
                    }
                }
            }
        }
    }

    func dismissSplash() {
        withAnimation(.easeOut(duration: 0.2)) {
            isSplashVisible = false
        }
    }

    func openOnboarding() {
        isSplashVisible = false
        isOnboardingPresented = true
    }

    func markOnboardingCompleted() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        isOnboardingPresented = false
    }

    nonisolated private static func performLocalSelfCheck() -> [StartupCheckItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. Hardware
        let hw = HardwareEnvironmentSnapshot.current()
        #if arch(arm64)
        let isArm = true
        #else
        let isArm = false
        #endif
        let hwItem = StartupCheckItem(
            id: "hw",
            titleKey: "splash.item.hardware",
            status: (isArm && hw.availableDiskGB >= 10) ? .ready : .warning,
            detail: String(format: "%@ · %.0f GB RAM · %.1f GB free", hw.architecture, hw.physicalMemoryGB, hw.availableDiskGB)
        )

        // 2. Bundled Engines
        let resURL = Bundle.main.resourceURL
        let hasTextRender = resURL.map { fm.isExecutableFile(atPath: $0.appendingPathComponent("textrender").path) } ?? false
        let hasNode = resURL.map { fm.isExecutableFile(atPath: $0.appendingPathComponent("runtime/bin/node").path) } ?? false
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let hasVoicebox = execDir.map { fm.isExecutableFile(atPath: $0.appendingPathComponent("voicebox-server").path) } ?? false
        let enginesReady = hasTextRender && hasNode && hasVoicebox
        let enginesItem = StartupCheckItem(
            id: "engines",
            titleKey: "splash.item.engines",
            status: enginesReady ? .ready : .warning,
            detail: enginesReady ? "CoreText · Node.js · Voicebox OK" : "Missing bundled helper"
        )

        // 3. FFmpeg
        let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        let foundFFmpeg = ffmpegPaths.first { fm.isExecutableFile(atPath: $0) }
        let ffmpegItem = StartupCheckItem(
            id: "ffmpeg",
            titleKey: "splash.item.ffmpeg",
            status: foundFFmpeg != nil ? .ready : .warning,
            detail: foundFFmpeg ?? "Not found (/opt/homebrew/bin/ffmpeg)"
        )

        // 4. ComfyUI & Central Models
        let comfyApp = ["/Applications/Comfy Desktop.app", "/Applications/ComfyUI.app"].first { fm.fileExists(atPath: $0) }
        let centralComfy = CentralComfyModelStorage.defaultRoot
        let ckpts = CentralComfyModelStorage.listWeights(in: "checkpoints", centralRoot: centralComfy)
        let diffs = CentralComfyModelStorage.listWeights(in: "diffusion_models", centralRoot: centralComfy)
        let modelCount = ckpts.count + diffs.count
        let comfyItem = StartupCheckItem(
            id: "comfy",
            titleKey: "splash.item.comfy",
            status: (comfyApp != nil || modelCount > 0) ? .ready : .optionalAttention,
            detail: "\(comfyApp != nil ? "ComfyUI App OK" : "Install optional") · \(modelCount) image weights"
        )

        // 5. Voice Library & TTS Models
        let voiceData = home.appendingPathComponent("Library/Application Support/MotionDesk/voicebox-data")
        let hfHub = home.appendingPathComponent("Library/Application Support/MotionDesk/models/huggingface/hub")
        let hasVoiceData = fm.fileExists(atPath: voiceData.path)
        let hasTTSModels = (try? fm.contentsOfDirectory(atPath: hfHub.path))?.contains(where: { $0.hasPrefix("models--") }) ?? false
        let voiceItem = StartupCheckItem(
            id: "voice",
            titleKey: "splash.item.voice",
            status: (hasVoiceData || hasTTSModels) ? .ready : .optionalAttention,
            detail: hasTTSModels ? "Local TTS models ready" : "Optional download in Setup Guide"
        )

        // 6. Cloud / Optional API (strictly offline-safe local check)
        let colabBin = home.appendingPathComponent(".local/bin/colab").path
        let hasColab = fm.isExecutableFile(atPath: colabBin)
        let hasOpenAI = KeychainCredentialsStore.hasCredential(account: SupportedAPIProvider.openai_image.keychainAccount)
        let hasGemini = KeychainCredentialsStore.hasCredential(account: SupportedAPIProvider.gemini_image.keychainAccount)
        let cloudSummary = [
            hasColab ? "Colab CLI" : nil,
            hasOpenAI ? "OpenAI Key" : nil,
            hasGemini ? "Gemini Key" : nil
        ].compactMap { $0 }.joined(separator: " · ")
        let cloudItem = StartupCheckItem(
            id: "cloud",
            titleKey: "splash.item.cloud",
            status: .ready,
            detail: cloudSummary.isEmpty ? "Local-first mode (no sign-in required)" : cloudSummary
        )

        return [hwItem, enginesItem, ffmpegItem, comfyItem, voiceItem, cloudItem]
    }
}

struct KliporaSplashOverlay: View {
    @ObservedObject var startup: KliporaStartupController
    @ObservedObject private var l10n = LocalizationManager.shared

    private var logoImage: NSImage? {
        if let url = Bundle.main.url(forResource: "KliporaLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.76)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                // Header with Klipora Icon & Aura Glow
                HStack(spacing: 14) {
                    if let img = logoImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .shadow(color: StudioTheme.coral.opacity(0.32), radius: 14, y: 4)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(l10n.text("splash.title", fallback: "Klipora"))
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Text("1.0")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(StudioTheme.coral.opacity(0.22), in: Capsule())
                                .foregroundStyle(StudioTheme.coral)
                        }
                        Text(l10n.text("app.tagline"))
                            .font(.caption)
                            .foregroundStyle(StudioTheme.textSecondary)
                        Text(startup.checkComplete
                             ? (startup.hasCriticalIssue ? l10n.text("splash.attention") : l10n.text("splash.allReady"))
                             : l10n.text("splash.subtitle"))
                            .font(.caption2)
                            .foregroundStyle(startup.hasCriticalIssue ? StudioTheme.warning : StudioTheme.textMuted)
                    }
                    Spacer()
                }
                .padding(14)
                .background(StudioWarmGlowBackground(intensity: 1.15, base: StudioTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.border))

                // Progress bar
                ProgressView(value: startup.progress)
                    .tint(StudioTheme.coral)

                // Component Self-Check List
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(startup.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.status.iconName)
                                .font(.system(size: 12))
                                .foregroundStyle(item.status.tint)
                                .frame(width: 16)
                            Text(l10n.text(item.titleKey))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(StudioTheme.textPrimary)
                            Spacer(minLength: 8)
                            Text(item.detail)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(12)
                .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.border))

                // Footer actions
                HStack {
                    Button(l10n.text("splash.openWizard")) {
                        startup.openOnboarding()
                    }
                    .controlSize(.regular)

                    Spacer()

                    Button(l10n.text("splash.enter")) {
                        startup.dismissSplash()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.coral)
                    .foregroundStyle(StudioTheme.textPrimary)
                }
            }
            .padding(20)
            .frame(width: 560)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StudioTheme.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 36, y: 12)
        }
    }
}

// MARK: - First-Run Multi-Model Guided Onboarding Wizard

struct StarterModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    let category: String // "checkpoints", "diffusion_models", or "tts"
    let filename: String
    let sizeGB: Double
    let minRAMGB: Int
    let summary: String
    let officialURL: URL?

    var isInstalledLocally: Bool {
        if category == "tts" {
            let hub = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MotionDesk/models/huggingface/hub")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? []
            return entries.contains { $0.lowercased().contains(filename.lowercased()) }
        }
        let target = CentralComfyModelStorage.categoryDirectory(category).appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: target.path)
    }

    static let catalog: [StarterModelOption] = [
        StarterModelOption(
            id: "sdxl1",
            name: "SDXL 1.0 Base（官方基礎圖片模型）",
            category: "checkpoints",
            filename: "sd_xl_base_1.0.safetensors",
            sizeGB: 6.94,
            minRAMGB: 16,
            summary: "穩定通用、支援文生圖／圖生圖與 LoRA（StabilityAI 官方授權）",
            officialURL: URL(string: "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors")
        ),
        StarterModelOption(
            id: "zimage",
            name: "Z-Image Turbo BF16（高速高畫質圖片）",
            category: "diffusion_models",
            filename: "z_image_turbo_bf16.safetensors",
            sizeGB: 12.30,
            minRAMGB: 24,
            summary: "8 步快速生圖、自然紀實表現佳（需搭配 Qwen3-4B 與 AE VAE）",
            officialURL: URL(string: "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors")
        ),
        StarterModelOption(
            id: "qwen3_tts_06b",
            name: "Qwen3-TTS 0.6B MLX（輕量本機語音）",
            category: "tts",
            filename: "qwen3-tts-12hz-0.6b",
            sizeGB: 2.50,
            minRAMGB: 16,
            summary: "快速本機旁白與配音（Apache-2.0 官方 MLX 權重）",
            officialURL: nil
        ),
        StarterModelOption(
            id: "qwen3_tts_17b",
            name: "Qwen3-TTS 1.7B MLX（高擬真中英語音）",
            category: "tts",
            filename: "qwen3-tts-12hz-1.7b",
            sizeGB: 4.20,
            minRAMGB: 16,
            summary: "高擬真聲音克隆與旁白合成（Apache-2.0 官方 MLX 權重）",
            officialURL: nil
        ),
    ]
}

@MainActor
final class KliporaOnboardingViewModel: ObservableObject {
    @Published var step: Int = 0
    @Published var hardware: HardwareEnvironmentSnapshot = .current()
    @Published var comfyDetectedPath: String? = nil
    @Published var configStatusMessage: String = ""
    @Published var selectedModelIDs: Set<String> = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStatus: String = ""
    private var downloadTask: Task<Void, Never>? = nil

    init() {
        refreshEnvironment()
    }

    func refreshEnvironment() {
        hardware = .current()
        let fm = FileManager.default
        comfyDetectedPath = ["/Applications/Comfy Desktop.app", "/Applications/ComfyUI.app"]
            .first { fm.fileExists(atPath: $0) }
    }

    var totalSelectedGB: Double {
        StarterModelOption.catalog
            .filter { selectedModelIDs.contains($0.id) && !$0.isInstalledLocally }
            .reduce(0.0) { $0 + $1.sizeGB }
    }

    var exceedsDiskSpace: Bool {
        totalSelectedGB > max(0.0, hardware.availableDiskGB - 2.0)
    }

    func toggleModel(_ id: String) {
        if selectedModelIDs.contains(id) {
            selectedModelIDs.remove(id)
        } else {
            selectedModelIDs.insert(id)
        }
    }

    func writeDefaultComfyPathsYAML() {
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MotionDesk/extra_model_paths.yaml")
        do {
            try CentralComfyModelStorage.writeExtraModelPathsYAML(to: dest)
            configStatusMessage = "已寫入預設路徑設定：\(dest.path)"
        } catch {
            configStatusMessage = "寫入失敗：\(error.localizedDescription)"
        }
    }

    func startDownloads() {
        let targets = StarterModelOption.catalog.filter { selectedModelIDs.contains($0.id) && !$0.isInstalledLocally }
        guard !targets.isEmpty else {
            downloadStatus = "所選模型均已存在於本機。"
            return
        }
        guard !exceedsDiskSpace else {
            downloadStatus = L10n.t("wizard.models.diskWarn")
            return
        }
        isDownloading = true
        downloadProgress = 0.0
        downloadTask?.cancel()
        downloadTask = Task {
            for (idx, option) in targets.enumerated() {
                if Task.isCancelled { break }
                if option.category == "tts" {
                    downloadStatus = "語音模型「\(option.name)」請透過元件設定頁的官方 Voicebox 下載器下載（已完成標記）。"
                    downloadProgress = Double(idx + 1) / Double(targets.count)
                    continue
                }
                guard let url = option.officialURL else { continue }
                downloadStatus = "正在下載 \(option.name)（\(String(format: "%.2f", option.sizeGB)) GB）…"
                do {
                    let (tempURL, response) = try await URLSession.shared.download(from: url)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(code) else {
                        downloadStatus = "\(option.name) 下載失敗（HTTP \(code)）。"
                        continue
                    }
                    let dir = CentralComfyModelStorage.categoryDirectory(option.category)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(option.filename)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    downloadProgress = Double(idx + 1) / Double(targets.count)
                    downloadStatus = "已完成下載：\(option.filename)"
                } catch {
                    if Task.isCancelled {
                        downloadStatus = "已取消下載。"
                    } else {
                        downloadStatus = "\(option.name) 下載中斷：\(error.localizedDescription)"
                    }
                }
            }
            isDownloading = false
        }
    }

    func cancelDownloads() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadStatus = "已取消下載。"
    }
}

struct KliporaOnboardingSheet: View {
    @ObservedObject var startup: KliporaStartupController
    @ObservedObject private var l10n = LocalizationManager.shared
    @StateObject private var vm = KliporaOnboardingViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 12) {
                if let url = Bundle.main.url(forResource: "KliporaLogo", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable().scaledToFit()
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.text("wizard.title"))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(l10n.text("wizard.subtitle"))
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button(l10n.text("wizard.skip")) {
                    vm.cancelDownloads()
                    startup.markOnboardingCompleted()
                }
                .controlSize(.small)
            }

            // Step tabs
            HStack(spacing: 6) {
                stepChip(index: 0, title: l10n.text("wizard.step1"))
                stepChip(index: 1, title: l10n.text("wizard.step2"))
                stepChip(index: 2, title: l10n.text("wizard.step3"))
                stepChip(index: 3, title: l10n.text("wizard.step4"))
            }

            Divider().overlay(StudioTheme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch vm.step {
                    case 0: step1HardwareAndLanguage
                    case 1: step2ComfyUIGuide
                    case 2: step3StarterModels
                    default: step4OptionalLogin
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().overlay(StudioTheme.border)

            // Footer navigation
            HStack {
                if vm.step > 0 {
                    Button(l10n.text("wizard.back")) { vm.step -= 1 }
                }
                Spacer()
                if vm.step < 3 {
                    Button(l10n.text("wizard.next")) { vm.step += 1 }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.coral)
                        .foregroundStyle(StudioTheme.textPrimary)
                } else {
                    Button(l10n.text("wizard.finish")) {
                        startup.markOnboardingCompleted()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.coral)
                    .foregroundStyle(StudioTheme.textPrimary)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 500, idealHeight: 560)
        .background(StudioTheme.panel)
        .tint(StudioTheme.neutralAccent)
        .preferredColorScheme(.dark)
    }

    private func stepChip(index: Int, title: String) -> some View {
        Button {
            vm.step = index
        } label: {
            Text(title)
                .font(.caption.weight(vm.step == index ? .semibold : .regular))
                .foregroundStyle(vm.step == index ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(vm.step == index ? StudioTheme.elevated : StudioTheme.well, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(vm.step == index ? StudioTheme.coral : StudioTheme.border))
        }
        .buttonStyle(.plain)
    }

    private var step1HardwareAndLanguage: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.text("settings.language"))
                    .font(.subheadline.weight(.semibold))
                Picker(l10n.text("settings.language"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeDisplayName).tag(lang)
                    }
                }
                .labelsHidden()
                Text(l10n.text("settings.languageHint"))
                    .font(.caption2).foregroundStyle(StudioTheme.textMuted)
            }
            .padding(12)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cpu").foregroundStyle(StudioTheme.neutralAccent)
                    Text(l10n.text("wizard.hw.title")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(l10n.text("wizard.comfy.recheckBtn")) { vm.refreshEnvironment() }.controlSize(.small)
                }
                Text(vm.hardware.summaryLine)
                    .font(.callout.monospaced())
                    .foregroundStyle(StudioTheme.textPrimary)
                let isGood = vm.hardware.architecture.contains("arm64") && vm.hardware.availableDiskGB >= 15
                HStack(spacing: 6) {
                    Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isGood ? StudioTheme.success : StudioTheme.warning)
                    Text(isGood ? l10n.text("wizard.hw.compatible") : l10n.text("wizard.hw.warning"))
                        .font(.caption)
                        .foregroundStyle(isGood ? StudioTheme.success : StudioTheme.warning)
                }
                Text(vm.hardware.modelRequirementsSummary)
                    .font(.caption2).foregroundStyle(StudioTheme.textMuted)
            }
            .padding(12)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var step2ComfyUIGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text("wizard.comfy.title"))
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Image(systemName: vm.comfyDetectedPath != nil ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(vm.comfyDetectedPath != nil ? StudioTheme.success : StudioTheme.neutralAccent)
                Text(vm.comfyDetectedPath != nil
                     ? "\(l10n.text("wizard.comfy.detected"))：\(vm.comfyDetectedPath!)"
                     : l10n.text("wizard.comfy.notDetected"))
                    .font(.callout)
                Spacer()
                Button(l10n.text("wizard.comfy.recheckBtn")) { vm.refreshEnvironment() }.controlSize(.small)
            }
            HStack(spacing: 8) {
                Button(l10n.text("wizard.comfy.downloadBtn")) {
                    if let url = URL(string: "https://www.comfy.org/download") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(l10n.text("wizard.comfy.writeConfigBtn")) {
                    vm.writeDefaultComfyPathsYAML()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.coral)
                .foregroundStyle(StudioTheme.textPrimary)
            }
            if !vm.configStatusMessage.isEmpty {
                Text(vm.configStatusMessage)
                    .font(.caption).foregroundStyle(StudioTheme.success)
            }
            Text("中央模型路徑：\(CentralComfyModelStorage.defaultRoot.path)（與舊 MotionDesk 資料完全共用，無需搬移或重複占用硬碟）。")
                .font(.caption2).foregroundStyle(StudioTheme.textMuted)
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var step3StarterModels: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text("wizard.models.title")).font(.subheadline.weight(.semibold))
            Text(l10n.text("wizard.models.desc")).font(.caption).foregroundStyle(StudioTheme.textSecondary)

            ForEach(StarterModelOption.catalog) { option in
                let installed = option.isInstalledLocally
                let checked = vm.selectedModelIDs.contains(option.id)
                HStack(spacing: 10) {
                    Button {
                        if !installed { vm.toggleModel(option.id) }
                    } label: {
                        Image(systemName: installed ? "checkmark.seal.fill" : (checked ? "checkmark.square.fill" : "square"))
                            .foregroundStyle(installed ? StudioTheme.success : (checked ? StudioTheme.coral : StudioTheme.textMuted))
                    }
                    .buttonStyle(.plain)
                    .disabled(installed || vm.isDownloading)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(option.name).font(.callout.weight(.medium)).foregroundStyle(StudioTheme.textPrimary)
                            if installed {
                                Text(l10n.text("wizard.models.installed"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(StudioTheme.success.opacity(0.18), in: Capsule())
                                    .foregroundStyle(StudioTheme.success)
                            }
                        }
                        Text(option.summary).font(.caption2).foregroundStyle(StudioTheme.textMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2f GB", option.sizeGB))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Text("≥\(option.minRAMGB) GB RAM")
                            .font(.caption2).foregroundStyle(StudioTheme.textMuted)
                    }
                }
                .padding(10)
                .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Text("\(l10n.text("wizard.models.selectedTotal"))：\(String(format: "%.2f GB", vm.totalSelectedGB)) · \(l10n.text("wizard.models.freeDisk"))：\(String(format: "%.1f GB", vm.hardware.availableDiskGB))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(vm.exceedsDiskSpace ? StudioTheme.danger : StudioTheme.textSecondary)
                Spacer()
                if vm.isDownloading {
                    Button(l10n.text("wizard.models.cancelDownload"), role: .destructive) { vm.cancelDownloads() }
                } else {
                    Button(l10n.text("wizard.models.startDownload")) { vm.startDownloads() }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.coral)
                        .foregroundStyle(StudioTheme.textPrimary)
                        .disabled(vm.totalSelectedGB <= 0 || vm.exceedsDiskSpace)
                }
            }
            if vm.exceedsDiskSpace {
                Text(l10n.text("wizard.models.diskWarn")).font(.caption).foregroundStyle(StudioTheme.danger)
            }
            if vm.isDownloading {
                ProgressView(value: vm.downloadProgress).tint(StudioTheme.coral)
            }
            if !vm.downloadStatus.isEmpty {
                Text(vm.downloadStatus).font(.caption).foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var step4OptionalLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.text("wizard.login.title")).font(.subheadline.weight(.semibold))
            Text(l10n.text("wizard.login.desc")).font(.caption).foregroundStyle(StudioTheme.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                Label(l10n.text("wizard.login.colab"), systemImage: "cloud.bolt.fill")
                    .font(.callout.weight(.medium))
                Label(l10n.text("wizard.login.api"), systemImage: "key.fill")
                    .font(.callout.weight(.medium))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))

            Button(l10n.text("wizard.login.openSettings")) {
                startup.markOnboardingCompleted()
                NotificationCenter.default.post(name: .motionDeskOpenSettings, object: nil)
            }
            .controlSize(.regular)
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - About & Copyright Page

struct KliporaAboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var l10n = LocalizationManager.shared

    private var logoImage: NSImage? {
        if let url = Bundle.main.url(forResource: "KliporaLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }

    private var thirdPartyText: String {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "Third-party notices are located in Contents/Resources/THIRD_PARTY_NOTICES.md."
    }

    var body: some View {
        VStack(spacing: 14) {
            if let img = logoImage {
                Image(nsImage: img)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .shadow(color: StudioTheme.coral.opacity(0.28), radius: 14, y: 4)
            }

            VStack(spacing: 4) {
                Text("Klipora")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text("Version 1.0")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(StudioTheme.textSecondary)
                Text(l10n.text("app.tagline"))
                    .font(.caption)
                    .foregroundStyle(StudioTheme.textMuted)
            }

            Divider().overlay(StudioTheme.border)

            VStack(spacing: 4) {
                Text("© 2026 Chih Tuan Chang")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Link("meteor199311@gmail.com", destination: URL(string: "mailto:meteor199311@gmail.com")!)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.neutralAccent)
                Text("All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.textMuted)
            }

            DisclosureGroup("Third-Party Open Source Notices") {
                ScrollView {
                    Text(thirdPartyText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: 120)
                .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))
            }
            .font(.caption)
            .foregroundStyle(StudioTheme.textSecondary)

            Button("關閉") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.coral)
                .foregroundStyle(StudioTheme.textPrimary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 420)
        .background(StudioTheme.panel)
        .preferredColorScheme(.dark)
    }
}
