import AppKit
import Foundation
import SwiftUI

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

        // 1. Detect installed Agent CLIs
        var searchDirs: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".volta/bin").path,
            "/Applications/Antigravity.app/Contents/Resources/app/bin",
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
                Text(mgr.isUnlocked ? "已解鎖「動態圖形」" : "未安裝 Skill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((mgr.isUnlocked ? StudioTheme.success : StudioTheme.textMuted).opacity(0.16), in: Capsule())
                    .foregroundStyle(mgr.isUnlocked ? StudioTheme.success : StudioTheme.textSecondary)
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
                    .controlSize(.mini)
            }

            HStack(spacing: 8) {
                Text("工作區：\(mgr.workspacePath)")
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("選擇目錄…") { mgr.chooseWorkspaceFolder() }
                    .controlSize(.mini)
            }

            HStack(spacing: 8) {
                Button {
                    mgr.copyInstallPrompt()
                } label: {
                    Label("複製安裝指令給 Agent", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.coral)
                .controlSize(.small)

                if let url = URL(string: "https://github.com/mografy/mografy") {
                    Link(destination: url) {
                        Label("Mografy GitHub", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                }
                Spacer()
            }

            if let msg = mgr.copiedBanner {
                Text(msg)
                    .font(.system(size: 10.5))
                    .foregroundStyle(StudioTheme.success)
            }
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear { mgr.refresh() }
    }
}
