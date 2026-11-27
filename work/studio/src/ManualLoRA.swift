import Foundation
import CryptoKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportedLoRA: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var filename: String
    var compatibleModels: [String]
    var defaultStrength: Double
    var triggerNote: String
}

struct ManualLoRARegistry {
    static let supportedModels: Set<String> = ["zimage", "redcraft", "krea2", "moss"]

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/user_loras.json")
    }
    static var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/models/loras", isDirectory: true)
    }
    static func load(from url: URL = Self.url) throws -> [ImportedLoRA] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ImportedLoRA].self, from: Data(contentsOf: url))
    }
    static func save(_ entries: [ImportedLoRA], to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "MotionDesk.LoRA", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func isHexSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }
    // Read only the bounded safetensors header; never deserialize executable model formats.
    static func validate(_ source: URL) throws {
        guard source.pathExtension.lowercased() == "safetensors" else { throw failure("僅接受 .safetensors LoRA。") }
        let f = try FileHandle(forReadingFrom: source); defer { try? f.close() }
        let total = try f.seekToEnd(); try f.seek(toOffset: 0)
        guard let first = try f.read(upToCount: 8), first.count == 8 else { throw failure("檔案不是有效的 safetensors。") }
        let n = first.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard n > 0, n <= 64 * 1024 * 1024, total >= 8 + n,
              let bytes = try f.read(upToCount: Int(n)), bytes.count == Int(n),
              let header = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw failure("safetensors 標頭損毀或過大。")
        }
        let tensors = header.filter { $0.key != "__metadata__" }
        let payload = total - 8 - n
        let bits: [String: UInt64] = ["F64":64,"F32":32,"BF16":16,"F16":16,"F8_E4M3":8,"F8_E4M3FN":8,"F8_E5M2":8,"I64":64,"I32":32,"I16":16,"I8":8,"U64":64,"U32":32,"U16":16,"U8":8,"BOOL":8]
        var ranges: [(UInt64, UInt64)] = []
        for (_, value) in tensors {
            guard let item = value as? [String: Any], let dtype = item["dtype"] as? String,
                  let bitCount = bits[dtype], let shape = item["shape"] as? [Int],
                  let offsets = item["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0], UInt64(offsets[1]) <= payload else {
                throw failure("權重資訊或資料範圍不正確。")
            }
            var elements: UInt64 = 1
            for dimension in shape {
                guard dimension >= 0 else { throw failure("權重維度無效。") }
                let product = elements.multipliedReportingOverflow(by: UInt64(dimension))
                guard !product.overflow else { throw failure("權重維度過大。") }; elements = product.partialValue
            }
            let size = elements.multipliedReportingOverflow(by: bitCount / 8)
            guard !size.overflow, size.partialValue == UInt64(offsets[1] - offsets[0]) else { throw failure("權重尺寸與檔案內容不符。") }
            ranges.append((UInt64(offsets[0]), UInt64(offsets[1])))
        }
        var end: UInt64 = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard range.0 == end else { throw failure("權重資料重疊或不完整。") }; end = range.1
        }
        guard end == payload else { throw failure("檔案包含不完整或額外資料。") }
        let pairs = [(".lora_A.weight", ".lora_B.weight"), (".lora_down.weight", ".lora_up.weight"), (".lora.down.weight", ".lora.up.weight")]
        var paired = 0
        for (key, _) in tensors {
            for (down, up) in pairs where key.hasSuffix(down) {
                let partner = String(key.dropLast(down.count)) + up
                guard tensors[partner] != nil else { throw failure("LoRA 缺少成對的 up/B 權重。") }; paired += 1
            }
            for (down, up) in pairs where key.hasSuffix(up) {
                guard tensors[String(key.dropLast(up.count)) + down] != nil else { throw failure("LoRA 缺少成對的 down/A 權重。") }
            }
        }
        guard paired > 0 else { throw failure("未找到支援的 LoRA A/B 或 down/up 權重；此檔案可能是主模型或其他格式。") }
    }

    @discardableResult
    static func ensureSymlink(at link: URL, to target: URL, expectedHash: String) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path), (try? sha256(of: target)) == expectedHash else {
            throw failure("中央 LoRA 目標檔案缺失或雜湊不符，已中止建立符號連結：\(target.lastPathComponent)")
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: link.path) {
            let fileType = attrs[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink {
                let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
                if dest == target.path { return false }
                let resolved = dest.hasPrefix("/")
                    ? URL(fileURLWithPath: dest)
                    : link.deletingLastPathComponent().appendingPathComponent(dest)
                guard fm.fileExists(atPath: resolved.path), (try? sha256(of: resolved)) == expectedHash else {
                    throw failure("ComfyUI 目錄中存在指向未知或失效目標的符號連結，已保留未覆寫：\(link.lastPathComponent)")
                }
                let backup = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).migrate-bak-\(UUID().uuidString)")
                try fm.moveItem(at: link, to: backup)
                do {
                    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
                    try? fm.removeItem(at: backup)
                    return true
                } catch {
                    try? fm.moveItem(at: backup, to: link)
                    throw error
                }
            }
            guard fileType == .typeRegular else {
                throw failure("ComfyUI 目標位置不是一般檔案或符號連結，已中止以避免覆寫：\(link.lastPathComponent)")
            }
            let actualHash = try sha256(of: link)
            guard actualHash == expectedHash else {
                throw failure("ComfyUI 目錄中存在雜湊不符的未知檔案，已中止以避免覆寫：\(link.lastPathComponent)")
            }
            let backup = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).migrate-bak-\(UUID().uuidString)")
            try fm.moveItem(at: link, to: backup)
            do {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
                try? fm.removeItem(at: backup)
                return true
            } catch {
                try? fm.moveItem(at: backup, to: link)
                throw error
            }
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        return true
    }

    /// Safely migrate legacy physical copies listed in `registry` from `<root>/models/loras/MotionDesk/<hash>.safetensors`
    /// into `storageRoot/<hash>.safetensors` and replace them with symlinks. Unknown or hash-mismatched files are never deleted or overwritten.
    @discardableResult
    static func migrateLegacyWeights(root: URL, storageRoot: URL = Self.storageDirectory, registry: URL = Self.url) throws -> Int {
        let entries = try load(from: registry)
        guard !entries.isEmpty else { return 0 }
        let fm = FileManager.default
        let prefix = "MotionDesk/"
        let suffix = ".safetensors"
        var hashes: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard entry.filename.hasPrefix(prefix), entry.filename.hasSuffix(suffix) else { continue }
            let hash = String(entry.filename.dropFirst(prefix.count).dropLast(suffix.count))
            guard isHexSHA256(hash), seen.insert(hash).inserted else { continue }
            hashes.append(hash)
        }
        var migrated = 0
        let comfyFolder = root.appendingPathComponent("models/loras/MotionDesk", isDirectory: true)
        for hash in hashes {
            let legacy = comfyFolder.appendingPathComponent("\(hash).safetensors")
            let central = storageRoot.appendingPathComponent("\(hash).safetensors")
            let legacyAttrs = try? fm.attributesOfItem(atPath: legacy.path)
            let legacyType = legacyAttrs?[.type] as? FileAttributeType
            if legacyType == .typeSymbolicLink {
                guard fm.fileExists(atPath: central.path), (try? sha256(of: central)) == hash else {
                    throw failure("中央 LoRA 檔案缺失或雜湊不符，無法驗證符號連結：\(central.lastPathComponent)")
                }
                if try ensureSymlink(at: legacy, to: central, expectedHash: hash) {
                    migrated += 1
                }
                continue
            }
            if legacyType == .typeRegular {
                let actualLegacyHash = try sha256(of: legacy)
                guard actualLegacyHash == hash else {
                    throw failure("舊 LoRA 檔案雜湊不符，已保留原檔未遷移：\(legacy.lastPathComponent)")
                }
                try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: central.path) {
                    let staging = storageRoot.appendingPathComponent(".migrate-\(UUID().uuidString).safetensors")
                    defer { try? fm.removeItem(at: staging) }
                    try fm.copyItem(at: legacy, to: staging)
                    guard try sha256(of: staging) == hash else {
                        throw failure("遷移複製後雜湊驗證失敗，已保留原檔：\(legacy.lastPathComponent)")
                    }
                    try fm.moveItem(at: staging, to: central)
                } else {
                    guard try sha256(of: central) == hash else {
                        throw failure("中央 LoRA 檔案雜湊不符，已保留原檔未覆寫：\(central.lastPathComponent)")
                    }
                }
                _ = try ensureSymlink(at: legacy, to: central, expectedHash: hash)
                migrated += 1
            } else if legacyAttrs == nil, fm.fileExists(atPath: central.path) {
                guard try sha256(of: central) == hash else {
                    throw failure("中央 LoRA 檔案雜湊不符，已中止建立符號連結：\(central.lastPathComponent)")
                }
                _ = try ensureSymlink(at: legacy, to: central, expectedHash: hash)
                migrated += 1
            }
        }
        return migrated
    }

    static var defaultUserModelsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Klipora/user_models.json")
    }

    static func isModelSupportedForLoRA(_ model: String, userModelsRegistry: URL = Self.defaultUserModelsURL) -> Bool {
        if supportedModels.contains(model) { return true }
        guard FileManager.default.fileExists(atPath: userModelsRegistry.path),
              let data = try? Data(contentsOf: userModelsRegistry),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]] else {
            return false
        }
        return entries.contains { entry in
            (entry["id"] as? String) == model
                && supportedModels.contains((entry["baseProfile"] as? String) ?? "")
        }
    }

    static func install(source: URL, root: URL, model: String, name: String, strength: Double,
                        registry: URL = Self.url, storageRoot: URL = Self.storageDirectory,
                        userModelsRegistry: URL = Self.defaultUserModelsURL) throws -> ImportedLoRA {
        guard isModelSupportedForLoRA(model, userModelsRegistry: userModelsRegistry),
              strength.isFinite, (0...2).contains(strength) else { throw failure("模型或強度設定無效。") }
        let fm = FileManager.default
        // Copy to staging under central storageRoot first: validation and digest describe exactly the installed bytes.
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let staging = storageRoot.appendingPathComponent(".import-\(UUID().uuidString).safetensors")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        try validate(staging)
        let digest = try sha256(of: staging)
        let relative = "MotionDesk/\(digest).safetensors"
        let central = storageRoot.appendingPathComponent("\(digest).safetensors")
        let link = root.appendingPathComponent("models/loras/MotionDesk/\(digest).safetensors")
        var entries = try load(from: registry)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = ImportedLoRA(id: "user_\(digest)_\(model)", displayName: cleanName.isEmpty ? source.deletingPathExtension().lastPathComponent : cleanName,
                                 filename: relative, compatibleModels: [model], defaultStrength: strength,
                                 triggerNote: "手動指定基底模型；尚未驗證權重相容性與生成效果。")
        let createdCentral = !fm.fileExists(atPath: central.path)
        if createdCentral {
            try fm.moveItem(at: staging, to: central)
        } else if try sha256(of: central) != digest {
            throw failure("中央 LoRA 目錄中存在雜湊不符的同名檔案，已中止以避免覆寫：\(central.lastPathComponent)")
        }
        let createdLink: Bool
        do {
            createdLink = try ensureSymlink(at: link, to: central, expectedHash: digest)
        } catch {
            if createdCentral { try? fm.removeItem(at: central) }
            throw error
        }
        entries.removeAll { $0.id == entry.id }; entries.append(entry)
        do { try save(entries, to: registry) }
        catch {
            if createdLink { try? fm.removeItem(at: link) }
            if createdCentral { try? fm.removeItem(at: central) }
            throw error
        }
        return entry
    }
}

// MARK: - Native LoRA controls
private typealias LoRAViewState<Value> = SwiftUI.State<Value>

struct ManualLoRAControls: View {
    @ObservedObject var app: Studio
    @LoRAViewState private var importing = false
    @LoRAViewState private var registryError = ""
    private var entries: [LoRAProfile] { app.profileStore.compatibleLoRAs(for: app.action) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("LoRA").font(.callout.weight(.semibold)); Spacer(); openLocationButton; importButton }
                VStack(alignment: .leading, spacing: 6) {
                    Text("LoRA").font(.callout.weight(.semibold))
                    HStack(spacing: 6) { openLocationButton; importButton }
                }
            }
            Picker("套用 LoRA", selection: Binding(get: {
                let current = app.project.localImageLoRA ?? ""
                return entries.contains(where: { $0.id == current }) ? current : ""
            }, set: { id in
                app.project.localImageLoRA = id
                app.project.localLoRAStrength = entries.first(where: { $0.id == id })?.defaultStrength
            })) {
                Text("無").tag("")
                ForEach(entries) { entry in Text(entry.name).tag(entry.id) }
            }.labelsHidden().frame(maxWidth: .infinity)
            if let entry = entries.first(where: { $0.id == (app.project.localImageLoRA ?? "") }) {
                HStack {
                    Text("強度")
                    Slider(value: Binding(get: { app.project.localLoRAStrength ?? entry.defaultStrength }, set: { app.project.localLoRAStrength = $0 }), in: 0...2, step: 0.05)
                    Text((app.project.localLoRAStrength ?? entry.defaultStrength).formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                }
                if let note = entry.triggerNote { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if entry.id.hasPrefix("user_") {
                    Button("移除登錄（保留權重檔）", role: .destructive) {
                        do {
                            var imported = try ManualLoRARegistry.load(); imported.removeAll { $0.id == entry.id }
                            try ManualLoRARegistry.save(imported); app.project.localImageLoRA = ""; app.project.localLoRAStrength = nil
                            app.objectWillChange.send(); app.status = "已移除 LoRA 登錄；中央權重檔與原始檔保留。"
                        } catch { registryError = error.localizedDescription }
                    }.controlSize(.small)
                }
            }
            Text("權重唯一實體存於 ~/Library/Application Support/Klipora/models/loras/，並於已授權 ComfyUI 的 models/loras/MotionDesk/ 建立共用符號連結。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !registryError.isEmpty { Text(registryError).font(.caption).foregroundStyle(.orange) }
        }
        .disabled(app.busy)
        .sheet(isPresented: $importing) { ManualLoRAImportSheet(app: app) }
        .onAppear {
            if app.unsupportedLocalLoRAInfo != nil {
                app.project.localImageLoRA = ""
                app.project.localLoRAStrength = nil
            }
            do {
                _ = try ManualLoRARegistry.load()
                if let root = PortabilitySetupManager.shared.resolveAuthorizedComfyModelsRoot() {
                    DispatchQueue.global(qos: .utility).async {
                        _ = try? ManualLoRARegistry.migrateLegacyWeights(root: root)
                    }
                }
            } catch {
                registryError = "LoRA 清單讀取失敗：\(error.localizedDescription)"
            }
        }
    }
    private var openLocationButton: some View {
        Button {
            let dir = ManualLoRARegistry.storageDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        } label: { Label("開啟 LoRA 位置", systemImage: "folder") }
            .controlSize(.small).help("在 Finder 開啟中央 LoRA 權重目錄：~/Library/Application Support/Klipora/models/loras/")
    }
    private var importButton: some View {
        Button { importing = true } label: { Label("匯入 LoRA…", systemImage: "square.and.arrow.down") }
            .controlSize(.small).help("選擇 safetensors，指定基底模型後存至中央 LoRA 目錄並於 ComfyUI 建立符號連結。")
    }
}

private struct ManualLoRAImportSheet: View {
    @ObservedObject var app: Studio
    @Environment(\.dismiss) private var dismiss
    @LoRAViewState private var source: URL?
    @LoRAViewState private var name = ""
    @LoRAViewState private var model = ""
    @LoRAViewState private var strength = 1.0
    @LoRAViewState private var confirmed = false
    @LoRAViewState private var working = false
    @LoRAViewState private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("匯入 LoRA").font(.title2.weight(.semibold))
            Text("選擇發布者標示的基底模型；不同架構的 LoRA 無法通用。匯入只檢查檔案格式，生成前仍需確認相容性。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(source?.lastPathComponent ?? "選擇 .safetensors 檔案…") {
                app.pickAsync(title: "選擇 LoRA", types: [UTType(filenameExtension: "safetensors") ?? .data]) { urls in
                    if let url = urls.first { source = url; name = url.deletingPathExtension().lastPathComponent }
                }
            }.lineLimit(2)
            TextField("顯示名稱", text: $name)
            Picker("基底模型", selection: $model) {
                Text("請選擇").tag("")
                ForEach(app.profileStore.imageModels.filter { $0.supportsLoRA }) { Text($0.displayName).tag($0.id) }
            }
            HStack { Text("預設強度"); Slider(value: $strength, in: 0...2, step: 0.05); Text(strength.formatted(.number.precision(.fractionLength(2)))).monospacedDigit() }
            Toggle("已確認發布頁標示的基底模型與此選項一致", isOn: $confirmed)
            Text("權重唯一實體會複製到 ~/Library/Application Support/Klipora/models/loras/（依 SHA256 去重），並於所選 ComfyUI 根目錄的 models/loras/MotionDesk/ 建立符號連結供 Desktop 與 Klipora 共用；原始檔保留。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("正在檢查與複製…") }
                Spacer()
                Button("取消") { dismiss() }.disabled(working)
                Button("匯入並選用") { beginImport() }.buttonStyle(.borderedProminent)
                    .disabled(source == nil || model.isEmpty || !confirmed || working)
            }
        }.padding(24).frame(width: 460).disabled(working)
        .interactiveDismissDisabled(working)
        .onAppear { model = app.activeLocalProfile?.id ?? "" }
    }
    private func beginImport() {
        if let root = PortabilitySetupManager.shared.resolveAuthorizedComfyModelsRoot() { copy(to: root) }
        else { PortabilitySetupManager.shared.chooseComfyModelsRoot(app: app) { root in copy(to: root) } }
    }
    private func copy(to root: URL) {
        guard let source else { return }
        working = true; message = ""
        let target = model, label = name, value = strength
        let accessing = source.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                _ = try? ManualLoRARegistry.migrateLegacyWeights(root: root)
                return try ManualLoRARegistry.install(source: source, root: root, model: target, name: label, strength: value)
            }
            if accessing { source.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                working = false
                switch result {
                case .success(let entry):
                    app.selectLocalModel(target); app.project.localImageLoRA = entry.id; app.project.localLoRAStrength = value
                    app.objectWillChange.send(); app.status = "LoRA 已匯入至中央目錄並建立共用連結；若 ComfyUI 未列出新檔案，請重新整理或重啟服務。"
                    dismiss()
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }
}
