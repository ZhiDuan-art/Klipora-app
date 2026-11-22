import Foundation
import CryptoKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportedWorkflow: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var filename: String
    var kind: String
    var nodeCount: Int
    var hasPromptPlaceholder: Bool
    var hasSeedPlaceholder: Bool
    var hasImagePlaceholder: Bool
}

struct WorkflowInspection: Equatable {
    var nodeCount: Int
    var hasPromptPlaceholder: Bool
    var hasSeedPlaceholder: Bool
    var hasImagePlaceholder: Bool
}

struct CustomWorkflowRegistry {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/user_workflows.json")
    }
    static var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/workflows", isDirectory: true)
    }
    static func load(from url: URL = Self.url) throws -> [ImportedWorkflow] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ImportedWorkflow].self, from: Data(contentsOf: url))
    }
    static func safeLoad(from url: URL = Self.url) -> [ImportedWorkflow] {
        (try? load(from: url)) ?? []
    }
    static func entry(for id: String, from url: URL = Self.url) -> ImportedWorkflow? {
        guard id.hasPrefix("workflow_") else { return nil }
        return safeLoad(from: url).first(where: { $0.id == id })
    }
    static func fileURL(for entry: ImportedWorkflow, storageRoot: URL = Self.storageDirectory) -> URL {
        storageRoot.appendingPathComponent(entry.filename)
    }
    static func save(_ entries: [ImportedWorkflow], to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "MotionDesk.Workflow", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Parse JSON strictly as data only; never deserialize executable formats.
    static func inspect(_ source: URL) throws -> WorkflowInspection {
        guard source.pathExtension.lowercased() == "json" else {
            throw failure("僅接受 .json 工作流檔案。")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= 16 * 1024 * 1024 else {
            throw failure("JSON 檔案為空或超過 16 MB 上限。")
        }
        let data = try Data(contentsOf: source)
        guard let top = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw failure("JSON 頂層結構必須為物件。")
        }
        let candidateGraph: [String: Any]
        if let wrapped = top["prompt"] as? [String: Any] {
            candidateGraph = wrapped
        } else if top["nodes"] is [Any] || top["links"] is [Any] {
            throw failure("偵測到 ComfyUI 畫布（Canvas）格式 JSON，無法直接提交生成。請在 ComfyUI 開啟「Enable Dev mode Options」後點選「Save (API Format)」匯出 API JSON 再匯入。")
        } else {
            candidateGraph = top
        }
        guard !candidateGraph.isEmpty else {
            throw failure("API 工作流內容為空。")
        }
        for (_, rawNode) in candidateGraph {
            guard let node = rawNode as? [String: Any],
                  let classType = node["class_type"] as? String,
                  !classType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  node["inputs"] is [String: Any] else {
                throw failure("不是有效的 ComfyUI API 工作流 JSON（每個節點須含 class_type 與 inputs）。若為畫布 JSON，請改以 Save (API Format) 匯出。")
            }
        }
        let normalizedData = try JSONSerialization.data(withJSONObject: candidateGraph, options: [])
        let text = String(data: normalizedData, encoding: .utf8) ?? ""
        return WorkflowInspection(
            nodeCount: candidateGraph.count,
            hasPromptPlaceholder: text.contains("{{PROMPT}}"),
            hasSeedPlaceholder: text.contains("{{SEED}}"),
            hasImagePlaceholder: text.contains("{{IMAGE}}")
        )
    }

    static func install(source: URL, name: String, registry: URL = Self.url,
                        storageRoot: URL = Self.storageDirectory) throws -> ImportedWorkflow {
        let fm = FileManager.default
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let staging = storageRoot.appendingPathComponent(".import-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let info = try inspect(staging)
        let digest = try sha256(of: staging)
        let filename = "\(digest).json"
        let destination = storageRoot.appendingPathComponent(filename)
        var entries = try load(from: registry)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = ImportedWorkflow(
            id: "workflow_\(digest)",
            displayName: cleanName.isEmpty ? source.deletingPathExtension().lastPathComponent : cleanName,
            filename: filename,
            kind: "image",
            nodeCount: info.nodeCount,
            hasPromptPlaceholder: info.hasPromptPlaceholder,
            hasSeedPlaceholder: info.hasSeedPlaceholder,
            hasImagePlaceholder: info.hasImagePlaceholder
        )
        let created = !fm.fileExists(atPath: destination.path)
        if created {
            try fm.moveItem(at: staging, to: destination)
        } else if try sha256(of: destination) != digest {
            throw failure("中央工作流目錄中存在雜湊不符的同名檔案，已中止以避免覆寫：\(filename)")
        }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        do {
            try save(entries, to: registry)
        } catch {
            if created { try? fm.removeItem(at: destination) }
            throw error
        }
        return entry
    }

    static func remove(id: String, registry: URL = Self.url) throws {
        var entries = try load(from: registry)
        entries.removeAll { $0.id == id }
        try save(entries, to: registry)
    }
}

// MARK: - Native Custom Workflow Controls
private typealias WorkflowViewState<Value> = SwiftUI.State<Value>

struct CustomWorkflowControls: View {
    @ObservedObject var app: Studio
    @WorkflowViewState private var importing = false
    @WorkflowViewState private var registryError = ""

    private var selectedEntry: ImportedWorkflow? {
        CustomWorkflowRegistry.entry(for: app.localModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { importing = true } label: {
                    Label("匯入工作流…", systemImage: "doc.badge.plus")
                }
                .controlSize(.small)
                .help("匯入 ComfyUI API 格式 JSON 至中央工作流目錄，加入本機圖片模型清單（不自動執行）。")

                Button {
                    let dir = CustomWorkflowRegistry.storageDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                } label: {
                    Label("開啟工作流位置", systemImage: "folder")
                }
                .controlSize(.small)
                .help("在 Finder 開啟中央工作流目錄：~/Library/Application Support/Klipora/workflows/")
            }

            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已選用受管工作流：\(entry.displayName)（\(entry.nodeCount) 節點）")
                        .font(.caption.weight(.medium))
                    Text("占位符偵測：\(entry.hasPromptPlaceholder ? "✓ {{PROMPT}}" : "✗ 缺 {{PROMPT}}") · \(entry.hasSeedPlaceholder ? "✓ {{SEED}}" : "未設 {{SEED}}") · \(entry.hasImagePlaceholder ? "✓ {{IMAGE}}" : "未設 {{IMAGE}}")")
                        .font(.caption2).foregroundStyle(.secondary)
                    if !entry.hasPromptPlaceholder {
                        Text("警告：此工作流不含 {{PROMPT}} 占位符，改寫 MotionDesk 提示詞不會自動套用，提交生成前請先於正向提示詞節點設為 {{PROMPT}}。")
                            .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("匯入不自動執行；請確認本機 ComfyUI 已安裝所需模型與自訂節點。唯一實體存於 ~/Library/Application Support/Klipora/workflows/。")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("移除工作流登錄（保留原始檔）", role: .destructive) {
                        do {
                            try CustomWorkflowRegistry.remove(id: entry.id)
                            app.selectLocalModel("zimage")
                            app.objectWillChange.send()
                            app.status = "已移除自訂工作流登錄；原始檔與受管檔保留。"
                        } catch {
                            registryError = error.localizedDescription
                        }
                    }.controlSize(.small)
                }
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }

            if !registryError.isEmpty {
                Text(registryError).font(.caption).foregroundStyle(.orange)
            }
        }
        .disabled(app.busy)
        .sheet(isPresented: $importing) { CustomWorkflowImportSheet(app: app) }
        .onAppear {
            do { _ = try CustomWorkflowRegistry.load() }
            catch { registryError = "工作流清單讀取失敗：\(error.localizedDescription)" }
        }
    }
}

private struct CustomWorkflowImportSheet: View {
    @ObservedObject var app: Studio
    @Environment(\.dismiss) private var dismiss
    @WorkflowViewState private var source: URL?
    @WorkflowViewState private var name = ""
    @WorkflowViewState private var inspection: WorkflowInspection?
    @WorkflowViewState private var message = ""
    @WorkflowViewState private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("匯入 ComfyUI API 工作流").font(.title2.weight(.semibold))
            Text("僅支援 ComfyUI API 格式 JSON（含 prompt 包裝）。普通畫布（Canvas）JSON 請先於 ComfyUI 開啟 Dev mode Options 並以 Save (API Format) 匯出。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Button(source?.lastPathComponent ?? "選擇 API 工作流 .json…") {
                app.pickAsync(title: "選擇 ComfyUI API 工作流", types: [.json]) { urls in
                    guard let url = urls.first else { return }
                    source = url
                    name = url.deletingPathExtension().lastPathComponent
                    message = ""
                    inspection = nil
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        inspection = try CustomWorkflowRegistry.inspect(url)
                    } catch {
                        message = error.localizedDescription
                    }
                }
            }.lineLimit(2)

            TextField("顯示名稱", text: $name)

            if let info = inspection {
                VStack(alignment: .leading, spacing: 4) {
                    Text("格式檢查通過：共 \(info.nodeCount) 個 API 節點。").font(.caption.weight(.medium))
                    Text("占位符：\(info.hasPromptPlaceholder ? "✓ {{PROMPT}}" : "✗ 缺少 {{PROMPT}}") · \(info.hasSeedPlaceholder ? "✓ {{SEED}}" : "未含 {{SEED}}") · \(info.hasImagePlaceholder ? "✓ {{IMAGE}}" : "未含 {{IMAGE}}")")
                        .font(.caption).foregroundStyle(.secondary)
                    if !info.hasPromptPlaceholder {
                        Text("提醒：未偵測到 {{PROMPT}} 占位符，匯入後修改 MotionDesk 提示詞不會自動套用，且執行時需先於正向節點填入 {{PROMPT}}。")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("匯入後不會自動執行；權重/自訂節點須於本機 ComfyUI 就緒。檔案會依 SHA256 去重存至 ~/Library/Application Support/Klipora/workflows/，原始檔保留。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working { ProgressView().controlSize(.small); Text("正在驗證並匯入…") }
                Spacer()
                Button("取消") { dismiss() }.disabled(working)
                Button("匯入並選用") { beginImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || inspection == nil || working)
            }
        }
        .padding(24)
        .frame(width: 480)
        .disabled(working)
        .interactiveDismissDisabled(working)
    }

    private func beginImport() {
        guard let source else { return }
        working = true; message = ""
        let label = name
        let accessing = source.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CustomWorkflowRegistry.install(source: source, name: label) }
            if accessing { source.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                working = false
                switch result {
                case .success(let entry):
                    app.selectLocalModel(entry.id)
                    app.objectWillChange.send()
                    app.status = "已匯入自訂工作流「\(entry.displayName)」（未自動執行）。"
                    dismiss()
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }
}
