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
                || UserDefaults.standard.bool(forKey: PortabilitySetupManager.firstRunCompletedKey)
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

    func openOnboarding(step: Int = 0) {
        KliporaOnboardingViewModel.shared.step = max(0, min(3, step))
        KliporaOnboardingViewModel.shared.refreshEnvironment()
        isSplashVisible = false
        isOnboardingPresented = true
    }

    func markOnboardingCompleted() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        UserDefaults.standard.set(true, forKey: PortabilitySetupManager.firstRunCompletedKey)
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

        // 3. FFmpeg (prefer bundled runtime/bin/ffmpeg first, then Homebrew / system)
        var ffmpegPaths: [String] = []
        if let bundledFFmpeg = resURL?.appendingPathComponent("runtime/bin/ffmpeg").path {
            ffmpegPaths.append(bundledFFmpeg)
        }
        ffmpegPaths.append(contentsOf: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"])
        let foundFFmpeg = ffmpegPaths.first { fm.isExecutableFile(atPath: $0) }
        let ffmpegItem = StartupCheckItem(
            id: "ffmpeg",
            titleKey: "splash.item.ffmpeg",
            status: foundFFmpeg != nil ? .ready : .warning,
            detail: foundFFmpeg.map { $0.contains(".app/") ? "Bundled FFmpeg OK" : $0 } ?? "Not found (install in Setup Guide)"
        )

        // 4. ComfyUI & Central Models
        let managedComfy = home.appendingPathComponent("ComfyUI-Installs/ComfyUI-MPS/ComfyUI/main.py").path
        let comfyApp = ["/Applications/Comfy Desktop.app", "/Applications/ComfyUI.app"].first { fm.fileExists(atPath: $0) }
            ?? (fm.fileExists(atPath: managedComfy) ? managedComfy : nil)
        let centralComfy = CentralComfyModelStorage.defaultRoot
        let ckpts = CentralComfyModelStorage.listWeights(in: "checkpoints", centralRoot: centralComfy)
        let diffs = CentralComfyModelStorage.listWeights(in: "diffusion_models", centralRoot: centralComfy)
        let modelCount = ckpts.count + diffs.count
        let comfyItem = StartupCheckItem(
            id: "comfy",
            titleKey: "splash.item.comfy",
            status: (comfyApp != nil || modelCount > 0) ? .ready : .optionalAttention,
            detail: "\(comfyApp != nil ? "ComfyUI OK" : "Install optional") · \(modelCount) image weights"
        )

        // 5. Voice Library & TTS Models
        let voiceData = home.appendingPathComponent("Library/Application Support/Klipora/voicebox-data")
        let hfHubs = [
            home.appendingPathComponent("Library/Application Support/Klipora/models/huggingface/hub"),
            home.appendingPathComponent("Library/Application Support/MotionDesk/models/huggingface/hub")
        ]
        let breezyVenv = home.appendingPathComponent("Library/Application Support/Klipora/breezyvoice-venv/bin/python3")
        let breezyModel = home.appendingPathComponent("Library/Application Support/Klipora/breezyvoice-models/BreezyVoice/llm.pt")
        let hasVoiceData = fm.fileExists(atPath: voiceData.path)
        let hasBreezy = fm.isExecutableFile(atPath: breezyVenv.path) && fm.fileExists(atPath: breezyModel.path)
        let hasTTSModels = hasBreezy || hfHubs.contains { hub in
            (try? fm.contentsOfDirectory(atPath: hub.path))?.contains(where: { $0.hasPrefix("models--") }) ?? false
        }
        let voiceItem = StartupCheckItem(
            id: "voice",
            titleKey: "splash.item.voice",
            status: (hasVoiceData || hasTTSModels) ? .ready : .optionalAttention,
            detail: hasTTSModels ? (hasBreezy ? "BreezyVoice & Local TTS ready" : "Local TTS models ready") : "Optional download in Setup Guide"
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
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1")
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

struct StarterModelFile: Equatable {
    let category: String // "checkpoints", "diffusion_models", "loras", "vae", "text_encoders", "tts", "breezyvoice", or "asr"
    let filename: String
    let sizeGB: Double
    let officialURL: URL?

    var isInstalledLocally: Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if category == "breezyvoice" {
            let base = home.appendingPathComponent("Library/Application Support/Klipora")
            let py = base.appendingPathComponent("breezyvoice-venv/bin/python3")
            let repo = base.appendingPathComponent("breezyvoice-repo/single_inference.py")
            let modelDir = base.appendingPathComponent("breezyvoice-models/BreezyVoice")
            return fm.isExecutableFile(atPath: py.path)
                && fm.fileExists(atPath: repo.path)
                && fm.fileExists(atPath: modelDir.appendingPathComponent("llm.pt").path)
                && fm.fileExists(atPath: modelDir.appendingPathComponent("flow.pt").path)
                && fm.fileExists(atPath: modelDir.appendingPathComponent("hift.pt").path)
                && fm.fileExists(atPath: modelDir.appendingPathComponent("cosyvoice.yaml").path)
        }
        if category == "asr" {
            let asrModelBin = home.appendingPathComponent(
                "Library/Application Support/MotionDesk/ai-models/asr/faster-whisper-Breeze-ASR-26-int8/model.bin"
            )
            if fm.fileExists(atPath: asrModelBin.path) { return true }
            let asrDir = home.appendingPathComponent("Library/Application Support/MotionDesk/ai-models/asr")
            let entries = (try? fm.contentsOfDirectory(atPath: asrDir.path)) ?? []
            return entries.contains { name in
                name.lowercased().contains("breeze")
                    && fm.fileExists(atPath: asrDir.appendingPathComponent(name).appendingPathComponent("model.bin").path)
            }
        }
        if category == "tts" {
            let hubs = [
                home.appendingPathComponent("Library/Application Support/MotionDesk/models/huggingface/hub"),
                home.appendingPathComponent("Library/Application Support/Klipora/models/huggingface/hub")
            ]
            for hub in hubs {
                let entries = (try? fm.contentsOfDirectory(atPath: hub.path)) ?? []
                if entries.contains(where: { $0.lowercased().contains(filename.lowercased()) }) {
                    return true
                }
            }
            return false
        }
        let central = CentralComfyModelStorage.categoryDirectory(category).appendingPathComponent(filename)
        if fm.fileExists(atPath: central.path) { return true }
        let userComfy = home.appendingPathComponent("Documents/ComfyUI/models/\(category)/\(filename)")
        if fm.fileExists(atPath: userComfy.path) { return true }
        let managedComfy = home.appendingPathComponent("ComfyUI-Installs/ComfyUI-MPS/ComfyUI/models/\(category)/\(filename)")
        return fm.fileExists(atPath: managedComfy.path)
    }

    func destinationDirectory() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userComfyRoot = home.appendingPathComponent("Documents/ComfyUI/models")
        if fm.fileExists(atPath: userComfyRoot.path) {
            return userComfyRoot.appendingPathComponent(category, isDirectory: true)
        }
        let managedComfyRoot = home.appendingPathComponent("ComfyUI-Installs/ComfyUI-MPS/ComfyUI/models")
        if fm.fileExists(atPath: managedComfyRoot.path) {
            return managedComfyRoot.appendingPathComponent(category, isDirectory: true)
        }
        return CentralComfyModelStorage.categoryDirectory(category)
    }
}

struct StarterModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    let group: String // "圖片" / "影片" / "語音與字幕"
    let category: String
    let filename: String
    let sizeGB: Double
    let minRAMGB: Int
    let summary: String
    let officialURL: URL?
    let files: [StarterModelFile]

    init(
        id: String,
        name: String,
        group: String = "圖片",
        category: String,
        filename: String,
        sizeGB: Double,
        minRAMGB: Int,
        summary: String,
        officialURL: URL?,
        files: [StarterModelFile]? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.category = category
        self.filename = filename
        self.sizeGB = sizeGB
        self.minRAMGB = minRAMGB
        self.summary = summary
        self.officialURL = officialURL
        self.files = files ?? [
            StarterModelFile(category: category, filename: filename, sizeGB: sizeGB, officialURL: officialURL)
        ]
    }

    var isInstalledLocally: Bool {
        !files.isEmpty && files.allSatisfy { $0.isInstalledLocally }
    }

    var remainingSizeGB: Double {
        files.filter { !$0.isInstalledLocally }.reduce(0.0) { $0 + $1.sizeGB }
    }

    static let catalog: [StarterModelOption] = [
        StarterModelOption(
            id: "zimage",
            name: "Z-Image Turbo BF16（完整 3 檔推薦包）",
            group: "圖片",
            category: "diffusion_models",
            filename: "z_image_turbo_bf16.safetensors",
            sizeGB: 18.41,
            minRAMGB: 24,
            summary: "9 步極速生圖、強中文理解，支援圖生圖與 LoRA（含 DiT + Qwen3-4B + AE VAE，下載完直接可用）。",
            officialURL: URL(string: "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors"),
            files: [
                StarterModelFile(
                    category: "diffusion_models",
                    filename: "z_image_turbo_bf16.safetensors",
                    sizeGB: 12.30,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors")
                ),
                StarterModelFile(
                    category: "text_encoders",
                    filename: "qwen_3_4b.safetensors",
                    sizeGB: 5.78,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors")
                ),
                StarterModelFile(
                    category: "vae",
                    filename: "ae.safetensors",
                    sizeGB: 0.33,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors")
                )
            ]
        ),
        StarterModelOption(
            id: "krea2",
            name: "Krea-2 Turbo BF16（完整 3 檔包）",
            group: "圖片",
            category: "diffusion_models",
            filename: "krea2_turbo_bf16.safetensors",
            sizeGB: 19.05,
            minRAMGB: 24,
            summary: "8 步攝影光影文生圖（含 Krea-2 DiT + Qwen3-VL-4B + Qwen Image VAE）。",
            officialURL: URL(string: "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/split_files/diffusion_models/krea2_turbo_bf16.safetensors"),
            files: [
                StarterModelFile(
                    category: "diffusion_models",
                    filename: "krea2_turbo_bf16.safetensors",
                    sizeGB: 11.60,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/split_files/diffusion_models/krea2_turbo_bf16.safetensors")
                ),
                StarterModelFile(
                    category: "text_encoders",
                    filename: "qwen3vl_4b_bf16.safetensors",
                    sizeGB: 7.20,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/split_files/text_encoders/qwen3vl_4b_bf16.safetensors")
                ),
                StarterModelFile(
                    category: "vae",
                    filename: "qwen_image_vae.safetensors",
                    sizeGB: 0.25,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/split_files/vae/qwen_image_vae.safetensors")
                )
            ]
        ),
        StarterModelOption(
            id: "wan22_14b",
            name: "Wan 2.2 14B MoE + 4-step（完整 6 檔本機影片包）",
            group: "影片",
            category: "video",
            filename: "wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors",
            sizeGB: 38.04,
            minRAMGB: 36,
            summary: "本機高畫質圖生影（含 High/Low 雙專家 + 雙 4-step LoRA + UMT5-XXL + Wan 2.1 VAE，支援 Apple Silicon MPS）。",
            officialURL: URL(string: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"),
            files: [
                StarterModelFile(
                    category: "diffusion_models",
                    filename: "wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors",
                    sizeGB: 14.29,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors")
                ),
                StarterModelFile(
                    category: "diffusion_models",
                    filename: "wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors",
                    sizeGB: 14.29,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors")
                ),
                StarterModelFile(
                    category: "loras",
                    filename: "wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors",
                    sizeGB: 1.23,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors")
                ),
                StarterModelFile(
                    category: "loras",
                    filename: "wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors",
                    sizeGB: 1.23,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors")
                ),
                StarterModelFile(
                    category: "text_encoders",
                    filename: "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
                    sizeGB: 6.74,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors")
                ),
                StarterModelFile(
                    category: "vae",
                    filename: "wan_2.1_vae.safetensors",
                    sizeGB: 0.25,
                    officialURL: URL(string: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors")
                )
            ]
        ),
        StarterModelOption(
            id: "breezyvoice",
            name: "MediaTek BreezyVoice（台灣國語預設 · 68 聲線）",
            group: "語音與字幕",
            category: "breezyvoice",
            filename: "breezyvoice-venv",
            sizeGB: 2.80,
            minRAMGB: 16,
            summary: "自然台灣國語零樣本語音合成，直接共用內建 68 聲線（獨立 venv 背景安裝）。",
            officialURL: nil
        ),
        StarterModelOption(
            id: "qwen3_tts_17b",
            name: "Qwen3-TTS 1.7B MLX（高擬真中英多語克隆）",
            group: "語音與字幕",
            category: "tts",
            filename: "qwen3-tts-12hz-1.7b",
            sizeGB: 4.20,
            minRAMGB: 16,
            summary: "高擬真多語聲音克隆與旁白合成（Apache-2.0 官方 MLX 權重）。",
            officialURL: nil
        ),
        StarterModelOption(
            id: "asr_breeze26",
            name: "Breeze-ASR-26（台灣國語離線自動字幕）",
            group: "語音與字幕",
            category: "asr",
            filename: "breeze-asr-26",
            sizeGB: 1.50,
            minRAMGB: 16,
            summary: "聯發創新基地台灣國語精準語音辨識，剪輯頁一鍵自動上字幕。",
            officialURL: nil
        ),
    ]
}

@MainActor
final class KliporaOnboardingViewModel: ObservableObject {
    static let shared = KliporaOnboardingViewModel()

    @Published var step: Int = 0
    @Published var hardware: HardwareEnvironmentSnapshot = .current()
    @Published var comfyDetectedPath: String? = nil
    @Published var audioVenvReady: Bool = false
    @Published var colabCLIReady: Bool = false
    @Published var consentWriteComfyYAML: Bool = true
    @Published var consentInstallAudioVenv: Bool = true
    @Published var consentInstallColabCLI: Bool = true
    @Published var isSettingUpEngines: Bool = false
    @Published var engineSetupStatus: String = ""
    @Published var selectedModelIDs: Set<String> = ["breezyvoice", "asr_breeze26"]
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStatus: String = ""
    @Published var skippedColab: Bool = false
    private var downloadTask: Task<Void, Never>? = nil
    private var engineTask: Task<Void, Never>? = nil

    private init() {
        refreshEnvironment()
    }

    func refreshEnvironment() {
        hardware = .current()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let managedComfy = home.appendingPathComponent("ComfyUI-Installs/ComfyUI-MPS/ComfyUI/main.py").path
        comfyDetectedPath = ["/Applications/Comfy Desktop.app", "/Applications/ComfyUI.app"]
            .first { fm.fileExists(atPath: $0) }
            ?? (fm.fileExists(atPath: managedComfy) ? managedComfy : nil)
        let audioPy = home.appendingPathComponent("Library/Application Support/MotionDesk/ai-audio-venv/bin/python3").path
        audioVenvReady = fm.isExecutableFile(atPath: audioPy)
        let colabBin = home.appendingPathComponent(".local/bin/colab").path
        colabCLIReady = fm.isExecutableFile(atPath: colabBin)
    }

    /// Deduplicated remaining size across all checked models.
    var totalSelectedGB: Double {
        var seenFiles = Set<String>()
        var total = 0.0
        for option in StarterModelOption.catalog where selectedModelIDs.contains(option.id) && !option.isInstalledLocally {
            for f in option.files where !f.isInstalledLocally {
                let key = "\(f.category)/\(f.filename)"
                if seenFiles.insert(key).inserted {
                    total += f.sizeGB
                }
            }
        }
        return total
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

    func runConsentedEngineSetup(app: Studio) {
        guard !isSettingUpEngines else { return }
        isSettingUpEngines = true
        engineSetupStatus = "正在背景建置已同意的基礎引擎…"
        engineTask?.cancel()
        let doYAML = consentWriteComfyYAML
        let doAudio = consentInstallAudioVenv && !audioVenvReady
        let doColab = consentInstallColabCLI && !colabCLIReady

        engineTask = Task {
            var failures: [String] = []
            if doYAML {
                let dest = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Klipora/extra_model_paths.yaml")
                do {
                    try CentralComfyModelStorage.writeExtraModelPathsYAML(to: dest)
                    engineSetupStatus = "✅ 已寫入 ComfyUI 共用模型路徑設定"
                } catch {
                    failures.append("ComfyUI 路徑設定")
                    engineSetupStatus = "⚠️ 寫入 ComfyUI 路徑設定失敗：\(error.localizedDescription)"
                }
            }
            if doAudio {
                engineSetupStatus = "⏳ 正在背景建立音訊 AI 隔離環境（人聲分離／字幕用）…"
                let ok = await Self.runBundledPythonTool(scriptName: "audio_ai", args: ["install", "--module", "venv"])
                if !ok { failures.append("音訊 AI 隔離環境") }
            }
            if doColab {
                engineSetupStatus = "⏳ 正在檢查並安裝 google-colab-cli…"
                let ok = await Self.installColabCLI()
                if !ok { failures.append("google-colab-cli") }
            }
            refreshEnvironment()
            PortabilitySetupManager.shared.refreshAllLocalStates(app: app, userInitiated: false)
            isSettingUpEngines = false
            if failures.isEmpty {
                engineSetupStatus = "✅ 基礎引擎檢查與建置完成。"
            } else {
                engineSetupStatus = "⚠️ 以下項目未完成：\(failures.joined(separator: "、"))，可稍後於設定頁重試。"
            }
        }
    }

    func installColabCLIOnly(app: Studio) {
        guard !isSettingUpEngines else { return }
        isSettingUpEngines = true
        engineSetupStatus = "⏳ 正在安裝 google-colab-cli…"
        Task {
            _ = await Self.installColabCLI()
            refreshEnvironment()
            PortabilitySetupManager.shared.refreshAllLocalStates(app: app, userInitiated: true)
            isSettingUpEngines = false
            engineSetupStatus = colabCLIReady ? "✅ google-colab-cli 已安裝就緒。" : "⚠️ 自動安裝未完成，請確認已安裝 uv 或至終端機執行 uv tool install google-colab-cli。"
        }
    }

    @discardableResult
    private nonisolated static func runBundledPythonTool(scriptName: String, args: [String]) async -> Bool {
        guard let scriptURL = Bundle.main.url(forResource: scriptName, withExtension: "py") else { return false }
        return await Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = ["-u", scriptURL.path] + args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    @discardableResult
    private nonisolated static func installColabCLI() async -> Bool {
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser.path
            let uvCandidates = [
                "\(home)/.local/bin/uv",
                "/opt/homebrew/bin/uv",
                "/usr/local/bin/uv"
            ]
            guard let uvPath = uvCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
                return false
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: uvPath)
            proc.arguments = ["tool", "install", "--upgrade", "google-colab-cli"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    func startDownloads(app: Studio) {
        let targets = StarterModelOption.catalog.filter { selectedModelIDs.contains($0.id) && !$0.isInstalledLocally }
        guard !targets.isEmpty else {
            downloadStatus = "所選模型均已安裝於本機。"
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
            var seenKeys = Set<String>()
            var pendingFiles: [(optionName: String, file: StarterModelFile)] = []
            for option in targets {
                for f in option.files where !f.isInstalledLocally {
                    let key = "\(f.category)/\(f.filename)"
                    if seenKeys.insert(key).inserted {
                        pendingFiles.append((option.name, f))
                    }
                }
            }
            let totalCount = max(1, pendingFiles.count)
            var failedNames: [String] = []
            for (idx, item) in pendingFiles.enumerated() {
                if Task.isCancelled { break }
                let file = item.file
                if file.category == "breezyvoice" {
                    downloadStatus = "[\(idx + 1)/\(totalCount)] 正在背景安裝 MediaTek BreezyVoice…"
                    VoiceboxServiceController.shared.installBreezyVoice()
                    downloadProgress = Double(idx + 1) / Double(totalCount)
                    continue
                }
                if file.category == "asr" {
                    downloadStatus = "[\(idx + 1)/\(totalCount)] 正在下載台灣國語字幕模型 Breeze-ASR-26…"
                    let ok = await Self.runBundledPythonTool(scriptName: "audio_ai", args: ["install", "--module", "asr_breeze26"])
                    if !ok { failedNames.append("Breeze-ASR-26") }
                    downloadProgress = Double(idx + 1) / Double(totalCount)
                    continue
                }
                if file.category == "tts" {
                    downloadStatus = "[\(idx + 1)/\(totalCount)] 已啟動背景下載：\(item.optionName)…"
                    let mgr = PortabilitySetupManager.shared
                    if let cacheItem = mgr.voiceboxModelItems.first(where: { $0.repoID.lowercased().contains("1.7b-base") }) {
                        mgr.downloadVoiceModel(cacheItem, app: app)
                    }
                    downloadProgress = Double(idx + 1) / Double(totalCount)
                    continue
                }
                guard let url = file.officialURL else { continue }
                downloadStatus = "[\(idx + 1)/\(totalCount)] 正在下載 \(file.filename)（\(String(format: "%.2f", file.sizeGB)) GB）…"
                do {
                    let (tempURL, response) = try await URLSession.shared.download(from: url)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(code) else {
                        failedNames.append(file.filename)
                        downloadStatus = "\(file.filename) 下載失敗（HTTP \(code)）。"
                        continue
                    }
                    let dir = file.destinationDirectory()
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(file.filename)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    downloadProgress = Double(idx + 1) / Double(totalCount)
                    downloadStatus = "[\(idx + 1)/\(totalCount)] 已完成下載：\(file.filename)"
                } catch {
                    if Task.isCancelled {
                        downloadStatus = "已取消下載。"
                    } else {
                        failedNames.append(file.filename)
                        downloadStatus = "\(file.filename) 下載中斷：\(error.localizedDescription)"
                    }
                }
            }
            refreshEnvironment()
            PortabilitySetupManager.shared.refreshAllLocalStates(app: app, userInitiated: false)
            isDownloading = false
            if !Task.isCancelled {
                if failedNames.isEmpty {
                    downloadStatus = "✅ 所選模型下載／背景安裝任務已完成。"
                } else {
                    downloadStatus = "⚠️ 部分項目下載失敗：\(failedNames.joined(separator: "、"))，請確認網路後重試。"
                }
            }
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
    @ObservedObject var app: Studio
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var vm = KliporaOnboardingViewModel.shared
    @ObservedObject private var portability = PortabilitySetupManager.shared
    @ObservedObject private var voicebox = VoiceboxServiceController.shared

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
                    Text(l10n.text("wizard.title", fallback: "歡迎使用 Klipora"))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text("全新環境快速設定：基礎引擎授權、完整模型包下載與 Colab 雲端連線（隨時可跳過並在設定頁重開）")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("略過並進入") {
                    startup.markOnboardingCompleted()
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            }

            // Step tabs
            HStack(spacing: 6) {
                stepChip(index: 0, title: "1. 基礎引擎")
                stepChip(index: 1, title: "2. 模型下載")
                stepChip(index: 2, title: "3. Colab 雲端")
                stepChip(index: 3, title: "4. 完成摘要")
            }

            Divider().overlay(StudioTheme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch vm.step {
                    case 0: step1HardwareAndEngines
                    case 1: step2StarterModels
                    case 2: step3ColabSetup
                    default: step4Summary
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().overlay(StudioTheme.border)

            // Footer navigation
            HStack {
                if vm.step > 0 {
                    Button("上一步") { vm.step -= 1 }
                        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                }
                if vm.isDownloading || vm.isSettingUpEngines || voicebox.breezyVoiceInstalling || portability.downloadingVoiceModelRepoID != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("背景安裝／下載執行中，關閉視窗也不會中斷")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }
                Spacer()
                if vm.step < 3 {
                    Button("下一步") { vm.step += 1 }
                        .buttonStyle(KliporaPillButtonStyle(variant: .primary, compact: true))
                } else {
                    Button("進入 Klipora 工作台") {
                        startup.markOnboardingCompleted()
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .primary, compact: true))
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 740, minHeight: 540, idealHeight: 600)
        .background(StudioTheme.panel)
        .tint(StudioTheme.neutralAccent)
        .preferredColorScheme(.dark)
        .onAppear {
            vm.refreshEnvironment()
            portability.refreshAllLocalStates(app: app, userInitiated: false)
        }
    }

    private func stepChip(index: Int, title: String) -> some View {
        let isActive = vm.step == index
        return Button {
            vm.step = index
        } label: {
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? .white : StudioTheme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(isActive ? StudioTheme.neutralAccent : StudioTheme.well, in: Capsule())
                .overlay(Capsule().strokeBorder(isActive ? Color.clear : StudioTheme.border))
                .contentShape(.interaction, Capsule())
        }
        .buttonStyle(.plain)
    }

    private var step1HardwareAndEngines: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.text("settings.language", fallback: "介面語言"))
                        .font(.subheadline.weight(.semibold))
                    Picker(l10n.text("settings.language"), selection: $l10n.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.nativeDisplayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu").foregroundStyle(StudioTheme.neutralAccent)
                        Text(vm.hardware.summaryLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(StudioTheme.textPrimary)
                    }
                    let isGood = vm.hardware.architecture.contains("arm64") && vm.hardware.availableDiskGB >= 15
                    Text(isGood ? "Apple Silicon 硬體與空間檢查通過" : "請留意剩餘硬碟空間（建議預留 25 GB 以上）")
                        .font(.caption2)
                        .foregroundStyle(isGood ? StudioTheme.success : StudioTheme.warning)
                }
            }
            .padding(12)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("基礎引擎下載與背景建置同意書")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("重新偵測") { vm.refreshEnvironment() }
                        .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                }
                Text("以下基礎元件可由 Klipora 自動在背景建置（您可取消勾選不需要的項目）：")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.textSecondary)

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(StudioTheme.success)
                    Text("App 內建核心：FFmpeg、Node.js + HyperFrames、CoreText 字幕與 Voicebox 語音引擎（已就緒）")
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))

                Toggle("寫入 ComfyUI 共用模型路徑（extra_model_paths.yaml）", isOn: $vm.consentWriteComfyYAML)
                    .font(.callout)
                HStack(spacing: 8) {
                    Image(systemName: vm.comfyDetectedPath != nil ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(vm.comfyDetectedPath != nil ? StudioTheme.success : StudioTheme.neutralAccent)
                    Text(vm.comfyDetectedPath != nil
                         ? "已偵測本機 ComfyUI：\(vm.comfyDetectedPath!)"
                         : "尚未偵測到 ComfyUI Desktop（若需本機生圖／生影片，可點右側下載官方安裝檔）")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    if vm.comfyDetectedPath == nil {
                        Button("下載 ComfyUI") {
                            if let url = URL(string: "https://www.comfy.org/download") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                    }
                }
                .padding(.leading, 22)

                Toggle(
                    vm.audioVenvReady
                    ? "本機音訊 AI 隔離環境（已就緒 · 人聲分離／自動字幕）"
                    : "背景建立本機音訊 AI 隔離環境（約 600 MB，供人聲分離與自動字幕使用）",
                    isOn: $vm.consentInstallAudioVenv
                )
                .font(.callout)
                .disabled(vm.audioVenvReady)

                Toggle(
                    vm.colabCLIReady
                    ? "Google Colab CLI（已安裝 · 雲端 L4 / G4 / A100 加速）"
                    : "自動安裝 Google Colab CLI（選用，用於雲端加速生成）",
                    isOn: $vm.consentInstallColabCLI
                )
                .font(.callout)
                .disabled(vm.colabCLIReady)

                HStack(spacing: 10) {
                    Button(vm.isSettingUpEngines ? "背景建置中…" : "同意並於背景建置基礎引擎") {
                        vm.runConsentedEngineSetup(app: app)
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .primary, compact: true))
                    .disabled(vm.isSettingUpEngines)

                    if !vm.engineSetupStatus.isEmpty {
                        Text(vm.engineSetupStatus)
                            .font(.caption)
                            .foregroundStyle(StudioTheme.textSecondary)
                    }
                }
            }
            .padding(12)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
        }
    }

    private var step2StarterModels: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("勾選要下載的 AI 模型完整包")
                        .font(.subheadline.weight(.semibold))
                    Text("每組模型均自動打包必備 Encoder／VAE／LoRA（並自動去重共用檔），下載完即可直接跑。")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("略過，之後再下載") { vm.step = 2 }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            }

            ForEach(["圖片", "影片", "語音與字幕"], id: \.self) { groupName in
                let groupItems = StarterModelOption.catalog.filter { $0.group == groupName }
                if !groupItems.isEmpty {
                    Text(groupName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.neutralAccent)
                        .padding(.top, 2)
                    ForEach(groupItems) { option in
                        let installed = option.isInstalledLocally
                        let checked = vm.selectedModelIDs.contains(option.id)
                        HStack(spacing: 10) {
                            Button {
                                if !installed { vm.toggleModel(option.id) }
                            } label: {
                                Image(systemName: installed ? "checkmark.seal.fill" : (checked ? "checkmark.square.fill" : "square"))
                                    .foregroundStyle(installed ? StudioTheme.success : (checked ? StudioTheme.coral : StudioTheme.textMuted))
                                    .frame(width: 22, height: 22)
                                    .contentShape(.interaction, Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(installed || vm.isDownloading)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(option.name).font(.callout.weight(.medium)).foregroundStyle(StudioTheme.textPrimary)
                                    if installed {
                                        Text("已安裝")
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
                                Text(installed ? "已就緒" : String(format: "%.1f GB", option.remainingSizeGB))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(installed ? StudioTheme.success : StudioTheme.textPrimary)
                                Text("建議 ≥\(option.minRAMGB) GB")
                                    .font(.caption2).foregroundStyle(StudioTheme.textMuted)
                            }
                        }
                        .padding(10)
                        .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            HStack {
                Text("已選待下載：\(String(format: "%.1f GB", vm.totalSelectedGB)) · 剩餘空間：\(String(format: "%.1f GB", vm.hardware.availableDiskGB))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(vm.exceedsDiskSpace ? StudioTheme.danger : StudioTheme.textSecondary)
                Spacer()
                if vm.isDownloading {
                    Button("取消下載", role: .destructive) { vm.cancelDownloads() }
                        .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                } else {
                    Button("開始背景下載所選模型") { vm.startDownloads(app: app) }
                        .buttonStyle(KliporaPillButtonStyle(variant: .primary, compact: true))
                        .disabled(vm.totalSelectedGB <= 0 || vm.exceedsDiskSpace)
                }
            }
            if vm.exceedsDiskSpace {
                Text("可用磁碟空間不足以容納所選模型，請取消部分勾選。").font(.caption).foregroundStyle(StudioTheme.danger)
            }
            if vm.isDownloading {
                ProgressView(value: vm.downloadProgress).tint(StudioTheme.coral)
            }
            if !vm.downloadStatus.isEmpty {
                Text(vm.downloadStatus).font(.caption).foregroundStyle(StudioTheme.textSecondary)
            }
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
    }

    private var step3ColabSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Colab 雲端 GPU 加速（選用）")
                        .font(.subheadline.weight(.semibold))
                    Text("連接後可使用 L4 / G4 / A100 跑 H3 影片（UPD5 / 10Eros-Max 8-step / PRISM，最長 60 秒自動續接）與多圖融合。")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("略過（純本機模式）") {
                    vm.skippedColab = true
                    vm.step = 3
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: vm.colabCLIReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(vm.colabCLIReady ? StudioTheme.success : StudioTheme.warning)
                    Text(vm.colabCLIReady ? "Colab CLI 已就緒（~/.local/bin/colab）" : "尚未安裝 google-colab-cli")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if !vm.colabCLIReady {
                        Button("一鍵安裝 CLI") { vm.installColabCLIOnly(app: app) }
                            .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                            .disabled(vm.isSettingUpEngines)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: portability.colabTokenFileExists ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(portability.colabTokenFileExists ? StudioTheme.success : StudioTheme.neutralAccent)
                    Text(portability.colabAuthCheckSummary.isEmpty
                         ? (portability.colabTokenFileExists ? "已偵測本機 OAuth 憑證，可點右側檢查額度" : "尚未登入 Google Colab OAuth")
                         : portability.colabAuthCheckSummary)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button("啟動瀏覽器登入…") {
                        portability.startColabBrowserAuthentication()
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .primary, compact: true))

                    Button("檢查登入與額度") {
                        Task { await portability.checkColabLoginStatus() }
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                }

                Divider().overlay(StudioTheme.border)

                HStack(spacing: 12) {
                    Text("預設雲端 GPU")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.textSecondary)
                    KliporaPillMenuPicker(
                        options: [("L4", "L4（省點推薦）"), ("G4", "G4"), ("A100", "A100（高速）")],
                        selection: Binding(
                            get: { portability.colabPreferredVideoGPU },
                            set: { portability.setPreferredVideoColabGPU($0, app: app) }
                        )
                    )
                    Spacer()
                    Toggle("跑完保留熱機 15 分鐘", isOn: $app.keepColabWarm)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                }
            }
            .padding(12)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
    }

    private var step4Summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("設定完成總覽")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                summaryRow(
                    ready: true,
                    title: "內建剪輯與語音基礎引擎",
                    detail: "FFmpeg、Node.js、Voicebox、CoreText 字幕皆已就緒"
                )
                summaryRow(
                    ready: vm.comfyDetectedPath != nil,
                    title: "本機 ComfyUI",
                    detail: vm.comfyDetectedPath != nil ? "已偵測並可立即使用" : "已略過（之後可隨時安裝 ComfyUI Desktop）"
                )
                let installedModels = StarterModelOption.catalog.filter { $0.isInstalledLocally }.count
                summaryRow(
                    ready: installedModels > 0 || vm.isDownloading,
                    title: "本機 AI 模型套件",
                    detail: vm.isDownloading ? "正在背景下載中（關閉視窗會繼續執行）" : "本機已就緒 \(installedModels) 組套件"
                )
                summaryRow(
                    ready: portability.colabTokenFileExists,
                    title: "Google Colab 雲端加速",
                    detail: portability.colabTokenFileExists
                        ? "已設定 OAuth（預設 GPU：\(portability.colabPreferredVideoGPU)），下次開啟會自動重連"
                        : "已略過（純本機模式）"
                )
            }
            .padding(12)
            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(StudioTheme.neutralAccent)
                Text("忘記裝某個模型或想之後再接 Colab？隨時可在右上角「元件與連線設定 → 一般」最上方重新開啟此安裝引導，直接跳到任一步驟補裝。")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(StudioTheme.neutralAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
    }

    private func summaryRow(ready: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? StudioTheme.success : StudioTheme.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
        }
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
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1")")
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
