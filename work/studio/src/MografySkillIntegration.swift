import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MografyAttachmentItem: Identifiable, Equatable {
    let id = UUID()
    let path: String

    var url: URL { URL(fileURLWithPath: path) }
    var filename: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    static let visualExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "svg", "gif", "tif", "tiff"]
    static let spreadsheetExtensions: Set<String> = ["xlsx", "xls", "csv", "tsv"]
    static let documentExtensions: Set<String> = ["docx", "doc", "rtf", "pages"]
    static let textDataExtensions: Set<String> = ["pdf", "md", "markdown", "txt", "json", "yaml", "yml"]
    static let supportedExtensions: Set<String> = visualExtensions
        .union(spreadsheetExtensions)
        .union(documentExtensions)
        .union(textDataExtensions)

    var isVisualAsset: Bool { Self.visualExtensions.contains(ext) }

    var badgeLabel: String {
        if Self.visualExtensions.contains(ext) { return "圖片/Logo" }
        if Self.spreadsheetExtensions.contains(ext) { return "Excel/表格" }
        if Self.documentExtensions.contains(ext) { return "Word 文件" }
        if ext == "pdf" { return "PDF" }
        return "資料檔"
    }

    var iconName: String {
        if Self.visualExtensions.contains(ext) { return "photo" }
        if Self.spreadsheetExtensions.contains(ext) { return "tablecells" }
        if Self.documentExtensions.contains(ext) { return "doc.richtext" }
        if ext == "pdf" { return "doc.text.fill" }
        return "doc.plaintext"
    }
}

enum AgentCLIKind: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity"
        }
    }

    var binaryNames: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex: return ["codex"]
        case .antigravity: return ["agy", "antigravity"]
        }
    }
}

@MainActor
final class MografySkillManager: ObservableObject {
    static let shared = MografySkillManager()

    private static let workspaceKey = "Klipora.mografy.workspacePath"
    private static let agentKey = "Klipora.mografy.selectedAgent"

    @Published var workspacePath: String {
        didSet {
            UserDefaults.standard.set(workspacePath, forKey: Self.workspaceKey)
            refresh()
        }
    }

    @Published var selectedAgent: AgentCLIKind {
        didSet {
            UserDefaults.standard.set(selectedAgent.rawValue, forKey: Self.agentKey)
        }
    }

    @Published var detectedAgents: [AgentCLIKind: String] = [:]
    @Published var skillInstalledPath: String? = nil
    @Published var workspaceReady: Bool = false
    @Published var copiedBanner: String? = nil
    @Published var attachments: [MografyAttachmentItem] = []

    func addAttachmentURLs(_ urls: [URL]) {
        let fm = FileManager.default
        var existingPaths = Set(attachments.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        var added: [MografyAttachmentItem] = []
        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        let ext = child.pathExtension.lowercased()
                        guard MografyAttachmentItem.supportedExtensions.contains(ext) else { continue }
                        let std = child.standardizedFileURL.path
                        if existingPaths.insert(std).inserted {
                            added.append(MografyAttachmentItem(path: std))
                        }
                    }
                }
            } else {
                let ext = url.pathExtension.lowercased()
                guard MografyAttachmentItem.supportedExtensions.contains(ext) else { continue }
                let std = url.path
                if existingPaths.insert(std).inserted {
                    added.append(MografyAttachmentItem(path: std))
                }
            }
        }
        if !added.isEmpty {
            attachments.append(contentsOf: added)
        }
    }

    func pickAttachments() {
        let panel = NSOpenPanel()
        panel.title = "選擇動態圖形參考素材與資料檔案（可多選）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.image, .svg, .pdf, .plainText, .commaSeparatedText, .tabSeparatedText, .json, .spreadsheet, .rtf]
        for ext in ["docx", "doc", "xlsx", "xls", "md", "yaml", "yml"] {
            if let ut = UTType(filenameExtension: ext) {
                types.append(ut)
            }
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK {
            addAttachmentURLs(panel.urls)
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        attachments.removeAll()
    }

    var isUnlocked: Bool {
        skillInstalledPath != nil && !detectedAgents.isEmpty
    }

    var availableAgents: [AgentCLIKind] {
        AgentCLIKind.allCases.filter { detectedAgents[$0] != nil }
    }

    var activeAgentBinaryPath: String? {
        if let direct = detectedAgents[selectedAgent] { return direct }
        if let fallback = availableAgents.first { return detectedAgents[fallback] }
        return nil
    }

    var effectiveAgent: AgentCLIKind {
        if detectedAgents[selectedAgent] != nil { return selectedAgent }
        return availableAgents.first ?? selectedAgent
    }

    private init() {
        let savedPath = UserDefaults.standard.string(forKey: Self.workspaceKey) ?? ""
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/mografy").path
        self.workspacePath = savedPath.isEmpty ? Self.discoverDefaultWorkspace(fallback: defaultPath) : savedPath
        let savedAgent = UserDefaults.standard.string(forKey: Self.agentKey) ?? ""
        self.selectedAgent = AgentCLIKind(rawValue: savedAgent) ?? .claude
        refresh()
    }

    private static func discoverDefaultWorkspace(fallback: String) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            fallback,
            home.appendingPathComponent("mografy").path,
            home.appendingPathComponent("Documents/mografy").path,
            home.appendingPathComponent("Projects/mografy").path,
        ]
        for path in candidates {
            if fm.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("package.json").path) {
                return path
            }
        }
        return fallback
    }

    func refresh() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. Detect installed Agent CLIs (including desktop app bundles & package manager bins)
        var searchDirs: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent("Library/pnpm").path,
            home.appendingPathComponent(".bun/bin").path,
            "/Applications/Gemini.app/Contents/Helpers",
            home.appendingPathComponent("Applications/Gemini.app/Contents/Helpers").path,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS",
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS").path,
            "/Applications/Antigravity.app/Contents/Resources/app/bin",
            home.appendingPathComponent("Applications/Antigravity.app/Contents/Resources/app/bin").path,
            "/Applications/Claude.app/Contents/MacOS",
            home.appendingPathComponent("Applications/Claude.app/Contents/MacOS").path,
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            searchDirs.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        // Also scan nvm node bin folders if present
        let nvmDir = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir.path) {
            for v in versions.sorted().reversed() {
                searchDirs.append(nvmDir.appendingPathComponent("\(v)/bin").path)
            }
        }

        var found: [AgentCLIKind: String] = [:]
        for kind in AgentCLIKind.allCases {
            outer: for dir in searchDirs {
                for bin in kind.binaryNames {
                    let full = URL(fileURLWithPath: dir).appendingPathComponent(bin).path
                    if fm.isExecutableFile(atPath: full) {
                        found[kind] = full
                        break outer
                    }
                }
            }
        }
        detectedAgents = found
        if found[selectedAgent] == nil, let first = AgentCLIKind.allCases.first(where: { found[$0] != nil }) {
            selectedAgent = first
        }

        // 2. Detect Mografy workspace & installed Skill
        let wsURL = URL(fileURLWithPath: workspacePath)
        workspaceReady = fm.fileExists(atPath: wsURL.appendingPathComponent("package.json").path)

        let skillCandidates: [URL] = [
            wsURL.appendingPathComponent(".agents/skills/mografy/SKILL.md"),
            wsURL.appendingPathComponent(".claude/skills/mografy/SKILL.md"),
            home.appendingPathComponent(".claude/skills/mografy/SKILL.md"),
            home.appendingPathComponent(".codex/skills/mografy/SKILL.md"),
            home.appendingPathComponent(".agents/skills/mografy/SKILL.md"),
            home.appendingPathComponent(".gemini/antigravity/skills/mografy/SKILL.md"),
        ]
        skillInstalledPath = skillCandidates.first(where: { fm.fileExists(atPath: $0.path) })?.path
    }

    func installPromptText() -> String {
        """
        請幫我安裝 Mografy（https://github.com/mografy/mografy）並設定好 mografy Skill 供 Klipora 呼叫：
        1. 將倉庫 clone 到：\(workspacePath)
        2. 確認本機 Node.js >= 22.12 與 pnpm，於該目錄執行 `pnpm install`
        3. 確認 `.agents/skills/mografy/SKILL.md` 存在，並視我使用的工具建立符號連結到 `~/.claude/skills/mografy`、`~/.codex/skills/mografy` 或 `~/.gemini/antigravity/skills/mografy`
        4. 安裝完成後回報即可，我回到 Klipora 點「重新偵測」就會解鎖「動態圖形」分頁。
        """
    }

    func copyInstallPrompt() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(installPromptText(), forType: .string)
        copiedBanner = "已複製安裝指令！請貼到 Claude Code / Codex / Antigravity 執行，完成後點「重新偵測」。"
    }

    func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.title = "選擇 Mografy 工作區資料夾"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
        }
    }
}

struct MografySkillSetupCard: View {
    @ObservedObject private var mgr = MografySkillManager.shared

    private var statusBadgeTitle: String {
        if mgr.isUnlocked {
            return "已解鎖「動態圖形」"
        } else if mgr.skillInstalledPath != nil {
            return "未偵測到 Agent CLI"
        } else {
            return "未安裝 Skill"
        }
    }

    private var statusBadgeColor: Color {
        if mgr.isUnlocked {
            return StudioTheme.success
        } else if mgr.skillInstalledPath != nil {
            return StudioTheme.warning
        } else {
            return StudioTheme.textMuted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(mgr.isUnlocked ? StudioTheme.success : StudioTheme.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mografy 動態圖形（Motion Graphics Skill）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text("透過 Claude Code / Codex / Antigravity 搭配 Mografy Skill，以自然語言撰寫並渲染 MP4 動態圖形直接入庫。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(statusBadgeTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusBadgeColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(mgr.isUnlocked ? StudioTheme.success : (mgr.skillInstalledPath != nil ? StudioTheme.warning : StudioTheme.textSecondary))
            }

            HStack(spacing: 10) {
                ForEach(AgentCLIKind.allCases) { kind in
                    let ready = mgr.detectedAgents[kind] != nil
                    HStack(spacing: 4) {
                        Circle()
                            .fill(ready ? StudioTheme.success : StudioTheme.textMuted.opacity(0.45))
                            .frame(width: 6, height: 6)
                        Text(kind.displayName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(ready ? StudioTheme.textPrimary : StudioTheme.textMuted)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudioTheme.well, in: Capsule())
                }
                Spacer()
                Button("重新偵測") { mgr.refresh() }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            }

            HStack(spacing: 8) {
                Text("工作區：\(mgr.workspacePath)")
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("選擇目錄") { mgr.chooseWorkspaceFolder() }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
            }

            HStack(spacing: 8) {
                Button {
                    mgr.copyInstallPrompt()
                } label: {
                    Label("複製安裝指令", systemImage: "doc.on.doc")
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))

                if let url = URL(string: "https://github.com/mografy/mografy") {
                    Link(destination: url) {
                        Label("Mografy GitHub", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                }
                Spacer()
            }

            if let msg = mgr.copiedBanner {
                Text(msg)
                    .font(.system(size: 10.5))
                    .foregroundStyle(StudioTheme.success)
            }
        }
        .padding(14)
        .background(Color(red: 0.114, green: 0.118, blue: 0.133), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear { mgr.refresh() }
    }
}

@MainActor
private final class MografyDropHighlightState: ObservableObject {
    @Published var isTargeted = false
}

struct MografyAttachmentsSection: View {
    @ObservedObject private var mgr = MografySkillManager.shared
    @StateObject private var dropState = MografyDropHighlightState()
    var disabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("參考素材與資料檔案", systemImage: "paperclip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                if !mgr.attachments.isEmpty {
                    Text("\(mgr.attachments.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(StudioTheme.coral.opacity(0.22), in: Capsule())
                        .foregroundStyle(StudioTheme.coral)
                }
                Spacer()
                if !mgr.attachments.isEmpty {
                    Button("清空") { mgr.clearAttachments() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .disabled(disabled)
                }
                Button {
                    mgr.pickAttachments()
                } label: {
                    Label("上傳多檔…", systemImage: "plus.circle")
                }
                .controlSize(.mini)
                .disabled(disabled)
            }

            if mgr.attachments.isEmpty {
                VStack(spacing: 4) {
                    Text("拖放或點「上傳多檔…」加入圖片、Logo (PNG/SVG)、Word、Excel、CSV 或 PDF")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(dropState.isTargeted ? StudioTheme.coral.opacity(0.12) : Color.white.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            dropState.isTargeted ? StudioTheme.coral : Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: dropState.isTargeted ? 1.5 : 1, dash: [4, 3])
                        )
                )
            } else {
                VStack(spacing: 4) {
                    ForEach(mgr.attachments) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.iconName)
                                .font(.caption)
                                .foregroundStyle(item.isVisualAsset ? StudioTheme.coral : StudioTheme.neutralAccent)
                                .frame(width: 14)
                            Text(item.filename)
                                .font(.caption)
                                .foregroundStyle(StudioTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(item.badgeLabel)
                                .font(.system(size: 9.5, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.07), in: Capsule())
                                .foregroundStyle(.secondary)
                            Button {
                                mgr.removeAttachment(item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(disabled)
                            .help("移除此附件")
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(dropState.isTargeted ? StudioTheme.coral.opacity(0.10) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(dropState.isTargeted ? StudioTheme.coral : Color.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { items, _ in
            guard !disabled, !items.isEmpty else { return false }
            mgr.addAttachmentURLs(items)
            return true
        } isTargeted: { targeted in
            dropState.isTargeted = targeted
        }
    }
}
