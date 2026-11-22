import AppKit
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Central ComfyUI Model Storage & Safe Migration Helper

enum ModelMigrationStatus: String, Codable, Equatable {
    case migrated
    case alreadyCentralized
    case symlinkRepaired
    case collisionPreserved
    case skippedUnknown
}

struct ModelMigrationItemResult: Codable, Equatable {
    let category: String
    let filename: String
    let status: ModelMigrationStatus
    let sha256: String?
    let detail: String
}

struct CentralComfyModelStorage {
    static let standardCategories: [String] = [
        "checkpoints",
        "diffusion_models",
        "text_encoders",
        "vae"
    ]
    static let sharedProtectedCategories: Set<String> = ["text_encoders", "vae"]

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MotionDesk/models/comfy", isDirectory: true)
    }

    static func categoryDirectory(_ category: String, under root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(category, isDirectory: true)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MotionDesk.CentralModels", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sanitizeFilename(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed != ".",
              trimmed != "..",
              !trimmed.hasPrefix("."),
              trimmed.lowercased().hasSuffix(".safetensors") else {
            throw failure("權重檔名無效，僅接受單層 .safetensors 檔名：\(raw)")
        }
        return trimmed
    }

    /// Validates bounded safetensors header and contiguous tensor byte offsets without executing any deserializer.
    static func validateSafetensorsHeader(at source: URL) throws {
        guard source.pathExtension.lowercased() == "safetensors" else {
            throw failure("僅接受 .safetensors 模型權重檔。")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let first = try handle.read(upToCount: 8), first.count == 8 else {
            throw failure("檔案不是有效的 safetensors 格式。")
        }
        let headerLen = first.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard headerLen > 0, headerLen <= 64 * 1024 * 1024, total >= 8 + headerLen,
              let headerBytes = try handle.read(upToCount: Int(headerLen)), headerBytes.count == Int(headerLen),
              let header = try JSONSerialization.jsonObject(with: headerBytes) as? [String: Any] else {
            throw failure("safetensors 標頭損毀或超過 64 MB 上限。")
        }
        let tensors = header.filter { $0.key != "__metadata__" }
        guard !tensors.isEmpty else {
            throw failure("safetensors 標頭不含任何權重張量。")
        }
        let payload = total - 8 - headerLen
        let bits: [String: UInt64] = [
            "F64": 64, "F32": 32, "BF16": 16, "F16": 16,
            "F8_E4M3": 8, "F8_E4M3FN": 8, "F8_E5M2": 8,
            "I64": 64, "I32": 32, "I16": 16, "I8": 8,
            "U64": 64, "U32": 32, "U16": 16, "U8": 8, "BOOL": 8
        ]
        var ranges: [(UInt64, UInt64)] = []
        for (_, value) in tensors {
            guard let item = value as? [String: Any],
                  let dtype = item["dtype"] as? String,
                  let bitCount = bits[dtype],
                  let shape = item["shape"] as? [Int],
                  let offsets = item["data_offsets"] as? [Int],
                  offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0],
                  UInt64(offsets[1]) <= payload else {
                throw failure("權重張量資訊或位元組範圍無效。")
            }
            var elements: UInt64 = 1
            for dim in shape {
                guard dim >= 0 else { throw failure("權重維度無效。") }
                let prod = elements.multipliedReportingOverflow(by: UInt64(dim))
                guard !prod.overflow else { throw failure("權重維度溢位。") }
                elements = prod.partialValue
            }
            let size = elements.multipliedReportingOverflow(by: bitCount / 8)
            guard !size.overflow, size.partialValue == UInt64(offsets[1] - offsets[0]) else {
                throw failure("權重張量尺寸與資料長度不符。")
            }
            ranges.append((UInt64(offsets[0]), UInt64(offsets[1])))
        }
        var cursor: UInt64 = 0
        for r in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard r.0 == cursor else { throw failure("權重資料區段重疊或不完整。") }
            cursor = r.1
        }
        guard cursor == payload else {
            throw failure("權重檔案尾部存在不完整或額外資料。")
        }
    }

    /// Creates or repairs a per-file symlink from `<comfyRoot>/models/<category>/<filename>` to central storage.
    /// Never overwrites unknown/hash-mismatched regular files or broken/wrong-target symlinks.
    @discardableResult
    static func ensureSymlink(at link: URL, to target: URL, expectedHash: String) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path), (try? sha256(of: target)) == expectedHash else {
            throw failure("中央模型目標檔案缺失或 SHA256 不符，已中止建立符號連結：\(target.lastPathComponent)")
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
                let backup = link.deletingLastPathComponent()
                    .appendingPathComponent(".\(link.lastPathComponent).migrate-bak-\(UUID().uuidString)")
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
                throw failure("ComfyUI 目標位置不是一般檔案或符號連結，已保留未覆寫：\(link.lastPathComponent)")
            }
            let actualHash = try sha256(of: link)
            guard actualHash == expectedHash else {
                throw failure("ComfyUI 目錄中存在雜湊不符的同名檔案，已保留未覆寫：\(link.lastPathComponent)")
            }
            let backup = link.deletingLastPathComponent()
                .appendingPathComponent(".\(link.lastPathComponent).migrate-bak-\(UUID().uuidString)")
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

    /// Hash-checked, atomic-rename migration helper with rollback and collision preservation.
    /// Designed for injectable roots so isolated unit tests never touch real user data.
    static func migrateLegacyFile(
        from legacyFile: URL,
        category: String,
        centralRoot: URL = defaultRoot,
        comfyRoot: URL? = nil,
        expectedHash: String? = nil
    ) throws -> ModelMigrationItemResult {
        let fm = FileManager.default
        let safeName = try sanitizeFilename(legacyFile.lastPathComponent)
        guard standardCategories.contains(category) else {
            throw failure("不支援的模型分類：\(category)")
        }
        let centralDir = categoryDirectory(category, under: centralRoot)
        let centralTarget = centralDir.appendingPathComponent(safeName)
        let linkLocation = comfyRoot?
            .appendingPathComponent("models/\(category)", isDirectory: true)
            .appendingPathComponent(safeName) ?? legacyFile

        guard let attrs = try? fm.attributesOfItem(atPath: legacyFile.path) else {
            return ModelMigrationItemResult(
                category: category, filename: safeName, status: .skippedUnknown,
                sha256: nil, detail: "來源檔案不存在，已略過。"
            )
        }
        let fileType = attrs[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            let dest = try fm.destinationOfSymbolicLink(atPath: legacyFile.path)
            if dest == centralTarget.path {
                guard fm.fileExists(atPath: centralTarget.path) else {
                    throw failure("中央模型檔缺失：\(centralTarget.lastPathComponent)")
                }
                let centralHash = try sha256(of: centralTarget)
                if let expectedHash, centralHash != expectedHash {
                    throw failure("中央模型檔 SHA256 與預期不符：\(safeName)")
                }
                return ModelMigrationItemResult(
                    category: category, filename: safeName, status: .alreadyCentralized,
                    sha256: centralHash, detail: "已指向中央模型儲存位置。"
                )
            }
            return ModelMigrationItemResult(
                category: category, filename: safeName, status: .skippedUnknown,
                sha256: nil, detail: "來源是指向外部目標的符號連結，已保留未動。"
            )
        }
        guard fileType == .typeRegular else {
            return ModelMigrationItemResult(
                category: category, filename: safeName, status: .skippedUnknown,
                sha256: nil, detail: "來源不是一般檔案，已保留未動。"
            )
        }

        let sourceHash = try sha256(of: legacyFile)
        if let expectedHash, sourceHash != expectedHash {
            return ModelMigrationItemResult(
                category: category, filename: safeName, status: .skippedUnknown,
                sha256: sourceHash, detail: "來源檔案雜湊與清單預期不符，已保留原檔未搬移。"
            )
        }

        try fm.createDirectory(at: centralDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: centralTarget.path) {
            let existingHash = try sha256(of: centralTarget)
            if existingHash != sourceHash {
                return ModelMigrationItemResult(
                    category: category, filename: safeName, status: .collisionPreserved,
                    sha256: sourceHash, detail: "中央目錄已存在不同內容的同名檔案，已保留兩邊檔案未覆寫。"
                )
            }
            // Identical content already exists centrally; replace legacy regular file with symlink safely.
            let repaired = try ensureSymlink(at: linkLocation, to: centralTarget, expectedHash: sourceHash)
            return ModelMigrationItemResult(
                category: category, filename: safeName,
                status: repaired ? .symlinkRepaired : .alreadyCentralized,
                sha256: sourceHash, detail: "中央已有相同 SHA256 權重，已切換為符號連結。"
            )
        }

        // Copy to staging -> verify SHA256 -> atomic move to centralTarget -> swap legacy with symlink (rollback on failure).
        let staging = centralDir.appendingPathComponent(".\(safeName).staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: legacyFile, to: staging)
        let stagedHash = try sha256(of: staging)
        guard stagedHash == sourceHash else {
            throw failure("暫存複製雜湊校驗失敗，已中止搬移：\(safeName)")
        }
        try fm.moveItem(at: staging, to: centralTarget)

        let backup = legacyFile.deletingLastPathComponent()
            .appendingPathComponent(".\(safeName).migrate-bak-\(UUID().uuidString)")
        do {
            if linkLocation.standardizedFileURL == legacyFile.standardizedFileURL {
                try fm.moveItem(at: legacyFile, to: backup)
                do {
                    try fm.createSymbolicLink(atPath: legacyFile.path, withDestinationPath: centralTarget.path)
                    try? fm.removeItem(at: backup)
                } catch {
                    try? fm.moveItem(at: backup, to: legacyFile)
                    throw error
                }
            } else {
                try ensureSymlink(at: linkLocation, to: centralTarget, expectedHash: sourceHash)
            }
        } catch {
            // Rollback central copy if linking failed so state remains clean and recoverable.
            try? fm.removeItem(at: centralTarget)
            throw error
        }

        return ModelMigrationItemResult(
            category: category, filename: safeName, status: .migrated,
            sha256: sourceHash, detail: "已驗證 SHA256 並移至中央模型儲存，ComfyUI 位置已改為符號連結。"
        )
    }

    /// Generates a ComfyUI `extra_model_paths.yaml` mapping MotionDesk central storage for managed or Desktop ComfyUI.
    static func writeExtraModelPathsYAML(
        centralRoot: URL = defaultRoot,
        loraCentralRoot: URL = ManualLoRARegistry.storageDirectory,
        to destination: URL
    ) throws {
        let base = centralRoot.standardizedFileURL.path
        let loraBase = loraCentralRoot.standardizedFileURL.path
        let yaml = """
        motiondesk_central:
          base_path: \(base)
          checkpoints: checkpoints
          diffusion_models: diffusion_models
          unet: diffusion_models
          text_encoders: text_encoders
          clip: text_encoders
          vae: vae
          loras: \(loraBase)
        """
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(yaml.utf8).write(to: destination, options: .atomic)
    }

    static func listWeights(in category: String, centralRoot: URL = defaultRoot, comfyRoot: URL? = nil) -> [String] {
        let fm = FileManager.default
        var names = Set<String>()
        let centralDir = categoryDirectory(category, under: centralRoot)
        if let items = try? fm.contentsOfDirectory(atPath: centralDir.path) {
            for item in items where item.lowercased().hasSuffix(".safetensors") && !item.hasPrefix(".") {
                names.insert(item)
            }
        }
        if let comfyRoot {
            let comfyDir = comfyRoot.appendingPathComponent("models/\(category)", isDirectory: true)
            if let items = try? fm.contentsOfDirectory(atPath: comfyDir.path) {
                for item in items where item.lowercased().hasSuffix(".safetensors") && !item.hasPrefix(".") {
                    names.insert(item)
                }
            }
        }
        return names.sorted()
    }
}

// MARK: - Persistent Local Image Model Registry (user_models.json)

struct UserImageModelEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var baseProfile: String
    var primaryCategory: String
    var primaryWeight: String
    var secondaryWeights: [String: String]
    var weightSHA256: String?
    var notes: String
    var isBuiltInOverride: Bool

    init(
        id: String,
        displayName: String,
        baseProfile: String,
        primaryCategory: String,
        primaryWeight: String,
        secondaryWeights: [String: String] = [:],
        weightSHA256: String? = nil,
        notes: String = "",
        isBuiltInOverride: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseProfile = baseProfile
        self.primaryCategory = primaryCategory
        self.primaryWeight = primaryWeight
        self.secondaryWeights = secondaryWeights
        self.weightSHA256 = weightSHA256
        self.notes = notes
        self.isBuiltInOverride = isBuiltInOverride
    }
}

struct UserModelState: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var entries: [UserImageModelEntry] = []
    var hiddenBuiltInIds: [String] = []
}

struct UserModelRegistry {
    static let supportedBaseProfiles: [String] = ["zimage", "redcraft", "iniverse_flux", "moss", "krea2", "sdxl1"]

    /// Explicit base-profile loader category map matching model_profiles.json templates:
    /// - CheckpointLoaderSimple -> checkpoints: redcraft, iniverse_flux, sdxl1
    /// - UNETLoader -> diffusion_models: zimage, moss, krea2
    static let baseProfilePrimaryCategory: [String: String] = [
        "zimage": "diffusion_models",
        "redcraft": "checkpoints",
        "iniverse_flux": "checkpoints",
        "moss": "diffusion_models",
        "krea2": "diffusion_models",
        "sdxl1": "checkpoints"
    ]

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MotionDesk/user_models.json")
    }

    static func primaryCategory(for baseProfile: String) -> String {
        baseProfilePrimaryCategory[baseProfile] ?? "diffusion_models"
    }

    static func load(from url: URL = Self.url) throws -> UserModelState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return UserModelState()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UserModelState.self, from: data)
    }

    static func safeLoad(from url: URL = Self.url) -> UserModelState {
        (try? load(from: url)) ?? UserModelState()
    }

    static func save(_ state: UserModelState, to url: URL = Self.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MotionDesk.UserModels", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Imports a `.safetensors` primary weight into central `models/comfy/<category>/` and links it to ComfyUI root if provided.
    static func importWeight(
        from source: URL,
        category: String,
        centralRoot: URL = CentralComfyModelStorage.defaultRoot,
        comfyRoot: URL? = nil
    ) throws -> (filename: String, sha256: String) {
        guard CentralComfyModelStorage.standardCategories.contains(category) else {
            throw failure("不支援的模型分類：\(category)")
        }
        try CentralComfyModelStorage.validateSafetensorsHeader(at: source)
        let safeName = try CentralComfyModelStorage.sanitizeFilename(source.lastPathComponent)
        let hash = try CentralComfyModelStorage.sha256(of: source)
        let centralDir = CentralComfyModelStorage.categoryDirectory(category, under: centralRoot)
        let fm = FileManager.default
        try fm.createDirectory(at: centralDir, withIntermediateDirectories: true)
        let target = centralDir.appendingPathComponent(safeName)

        if fm.fileExists(atPath: target.path) {
            let existingHash = try CentralComfyModelStorage.sha256(of: target)
            if existingHash != hash {
                throw failure("中央模型目錄已存在同名但內容不同的檔案（\(safeName)），請先重新命名後再匯入。")
            }
        } else {
            let staging = centralDir.appendingPathComponent(".\(safeName).staging-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            guard try CentralComfyModelStorage.sha256(of: staging) == hash else {
                throw failure("複製權重檔後 SHA256 校驗不符，已取消匯入。")
            }
            try fm.moveItem(at: staging, to: target)
        }

        if let comfyRoot {
            let link = comfyRoot.appendingPathComponent("models/\(category)/\(safeName)")
            _ = try CentralComfyModelStorage.ensureSymlink(at: link, to: target, expectedHash: hash)
        }
        return (safeName, hash)
    }

    /// Adds or updates a persistent local image model entry.
    @discardableResult
    static func upsertEntry(
        id: String? = nil,
        displayName: String,
        baseProfile: String,
        primaryWeight: String,
        secondaryWeights: [String: String] = [:],
        weightSHA256: String? = nil,
        notes: String = "",
        isBuiltInOverride: Bool = false,
        registryURL: URL = Self.url
    ) throws -> UserImageModelEntry {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw failure("請輸入模型顯示名稱。") }
        guard supportedBaseProfiles.contains(baseProfile) else {
            throw failure("不支援的基底架構設定檔：\(baseProfile)。請從已知相容架構中手動選擇。")
        }
        let safePrimary = try CentralComfyModelStorage.sanitizeFilename(primaryWeight)
        var cleanSecondary: [String: String] = [:]
        for (slot, file) in secondaryWeights where !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanSecondary[slot] = try CentralComfyModelStorage.sanitizeFilename(file)
        }
        let category = primaryCategory(for: baseProfile)
        var state = try load(from: registryURL)
        let entryID: String
        if let id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entryID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
            entryID = "umodel_\(token)"
        }
        let entry = UserImageModelEntry(
            id: entryID,
            displayName: trimmedName,
            baseProfile: baseProfile,
            primaryCategory: category,
            primaryWeight: safePrimary,
            secondaryWeights: cleanSecondary,
            weightSHA256: weightSHA256,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltInOverride: isBuiltInOverride
        )
        if let idx = state.entries.firstIndex(where: { $0.id == entryID }) {
            state.entries[idx] = entry
        } else {
            state.entries.append(entry)
        }
        state.hiddenBuiltInIds.removeAll(where: { $0 == entryID })
        try save(state, to: registryURL)
        return entry
    }

    static func hideBuiltIn(id: String, registryURL: URL = Self.url) throws {
        guard supportedBaseProfiles.contains(id) else {
            throw failure("僅可隱藏內建圖片模型項目：\(id)")
        }
        var state = try load(from: registryURL)
        if !state.hiddenBuiltInIds.contains(id) {
            state.hiddenBuiltInIds.append(id)
        }
        try save(state, to: registryURL)
    }

    static func restoreBuiltIn(id: String, registryURL: URL = Self.url) throws {
        var state = try load(from: registryURL)
        state.hiddenBuiltInIds.removeAll(where: { $0 == id })
        try save(state, to: registryURL)
    }

    static func restoreAllBuiltIns(registryURL: URL = Self.url) throws {
        var state = try load(from: registryURL)
        state.hiddenBuiltInIds.removeAll()
        try save(state, to: registryURL)
    }

    /// Checks whether a weight file is shared (TEXT_ENCODER/VAE or referenced by built-in defaults or another user entry).
    static func isWeightSharedOrProtected(
        filename: String,
        category: String,
        excludingEntryID: String,
        state: UserModelState,
        builtInWeights: Set<String> = defaultBuiltInProtectedWeights
    ) -> Bool {
        if CentralComfyModelStorage.sharedProtectedCategories.contains(category) {
            return true
        }
        if builtInWeights.contains(filename) {
            return true
        }
        for other in state.entries where other.id != excludingEntryID {
            if other.primaryWeight == filename && other.primaryCategory == category {
                return true
            }
            if other.secondaryWeights.values.contains(filename) {
                return true
            }
        }
        return false
    }

    /// Known default built-in primary & shared weights that must never be blindly deleted via model removal.
    static let defaultBuiltInProtectedWeights: Set<String> = [
        "z_image_turbo_bf16.safetensors",
        "redcraftRedzimageUpdatedDEC03_redzimage15AIO.safetensors",
        "iniverseMixSFWNSFW_flux1DNsfwFp8V10.safetensors",
        "moss_image_base_bf16.safetensors",
        "krea2_turbo_bf16.safetensors",
        "sd_xl_base_1.0.safetensors",
        "qwen_3_4b.safetensors",
        "clip_l.safetensors",
        "t5xxl_fp8_e4m3fn.safetensors",
        "qwen3.5_9b_bf16.safetensors",
        "qwen3vl_4b_bf16.safetensors",
        "ae.safetensors",
        "flux2-vae_small.safetensors",
        "qwen_image_vae.safetensors"
    ]

    /// Removes a user model entry. By default (`deleteWeightFile: false`), only removes the registry entry and keeps all files.
    /// If `deleteWeightFile == true`, refuses to delete shared TEXT_ENCODER/VAE or built-in/shared weights; only removes
    /// an exclusively owned primary weight in `centralRoot` (plus its matching symlink in `comfyRoot` if any).
    static func removeEntry(
        id: String,
        deleteWeightFile: Bool = false,
        centralRoot: URL = CentralComfyModelStorage.defaultRoot,
        comfyRoot: URL? = nil,
        registryURL: URL = Self.url
    ) throws -> Bool {
        var state = try load(from: registryURL)
        guard let idx = state.entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let targetEntry = state.entries[idx]
        var deletedWeight = false

        if deleteWeightFile {
            guard !targetEntry.isBuiltInOverride else {
                throw failure("內建模型覆寫項目不可刪除實際權重檔，已中止。")
            }
            guard !isWeightSharedOrProtected(
                filename: targetEntry.primaryWeight,
                category: targetEntry.primaryCategory,
                excludingEntryID: id,
                state: state
            ) else {
                throw failure("權重檔「\(targetEntry.primaryWeight)」屬於共用依賴或仍被其他模型引用，禁止自動刪除。")
            }
            let centralFile = CentralComfyModelStorage
                .categoryDirectory(targetEntry.primaryCategory, under: centralRoot)
                .appendingPathComponent(targetEntry.primaryWeight)
            let fm = FileManager.default
            if let comfyRoot {
                let link = comfyRoot
                    .appendingPathComponent("models/\(targetEntry.primaryCategory)/\(targetEntry.primaryWeight)")
                if let attrs = try? fm.attributesOfItem(atPath: link.path),
                   (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
                   let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                   dest == centralFile.path {
                    try? fm.removeItem(at: link)
                }
            }
            if fm.fileExists(atPath: centralFile.path) {
                try fm.removeItem(at: centralFile)
                deletedWeight = true
            }
        }

        state.entries.remove(at: idx)
        try save(state, to: registryURL)
        return deletedWeight
    }
}

// MARK: - SwiftUI Controls & Model Manager Sheet

@MainActor
private final class LocalModelControlsState: ObservableObject {
    @Published var showManagerSheet = false
}

struct LocalModelManagerControls: View {
    @ObservedObject var app: Studio
    @StateObject private var ui = LocalModelControlsState()

    var body: some View {
        HStack(spacing: 6) {
            Button("管理本機模型…") { ui.showManagerSheet = true }
                .disabled(app.busy)
            Button("開啟模型儲存位置") {
                try? FileManager.default.createDirectory(
                    at: CentralComfyModelStorage.defaultRoot,
                    withIntermediateDirectories: true
                )
                NSWorkspace.shared.activateFileViewerSelecting([CentralComfyModelStorage.defaultRoot])
            }
            .help("開啟 MotionDesk 中央圖片模型儲存資料夾（~/Library/Application Support/MotionDesk/models/comfy）")
        }
        .font(.caption)
        .sheet(isPresented: $ui.showManagerSheet) {
            LocalModelManagerSheet(app: app)
        }
    }
}

@MainActor
private final class LocalModelManagerSheetState: ObservableObject {
    @Published var userState: UserModelState = UserModelRegistry.safeLoad()
    @Published var showAddForm = false
    @Published var editingEntry: UserImageModelEntry? = nil
    @Published var draftName = ""
    @Published var draftBaseProfile = "sdxl1"
    @Published var draftPrimaryWeight = ""
    @Published var draftImportedHash: String? = nil
    @Published var draftNotes = ""
    @Published var isImportingWeight = false
    @Published var statusMessage = ""
    @Published var errorMessage = ""
    @Published var pendingDeleteEntry: UserImageModelEntry? = nil
}

struct LocalModelManagerSheet: View {
    @ObservedObject var app: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = LocalModelManagerSheetState()

    private var activeComfyRoot: URL? {
        PortabilitySetupManager.shared.resolveAuthorizedComfyModelsRoot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本機圖片模型管理")
                        .font(.headline)
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text("不自動猜測未知模型架構；新增模型時請手動選擇相容的基底架構設定檔。")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("新增模型…") { beginNewEntry() }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.coral)
                Button("關閉") { dismiss() }
            }

            // Central storage info strip
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(StudioTheme.neutralAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("中央模型儲存位置：\(CentralComfyModelStorage.defaultRoot.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(StudioTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("所有匯入與中央化權重統一保存於 models/comfy/{checkpoints,diffusion_models,text_encoders,vae}，並以符號連結或映射提供給 ComfyUI。")
                        .font(.caption2)
                        .foregroundStyle(StudioTheme.textMuted)
                }
                Spacer()
                Button("開啟資料夾") {
                    try? FileManager.default.createDirectory(at: CentralComfyModelStorage.defaultRoot, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([CentralComfyModelStorage.defaultRoot])
                }
                .font(.caption)
            }
            .padding(10)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioTheme.border))

            if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage).font(.caption).foregroundStyle(StudioTheme.success)
            }
            if !vm.errorMessage.isEmpty {
                Text(vm.errorMessage).font(.caption).foregroundStyle(StudioTheme.danger)
            }

            if vm.showAddForm {
                addOrEditForm
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Custom user models
                    Text("自訂模型項目（\(vm.userState.entries.filter { !$0.isBuiltInOverride }.count)）")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudioTheme.textPrimary)

                    let customEntries = vm.userState.entries.filter { !$0.isBuiltInOverride }
                    if customEntries.isEmpty {
                        Text("尚未新增自訂圖片模型。點選右上角「新增模型…」可掛載自己的 .safetensors 權重並綁定基底架構。")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.textMuted)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        ForEach(customEntries) { entry in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.displayName)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(StudioTheme.textPrimary)
                                    Text("基底：\(entry.baseProfile) · 類別：\(entry.primaryCategory) · 權重：\(entry.primaryWeight)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(StudioTheme.textSecondary)
                                    if !entry.notes.isEmpty {
                                        Text(entry.notes).font(.caption2).foregroundStyle(StudioTheme.textMuted)
                                    }
                                }
                                Spacer()
                                Button("編輯") { beginEdit(entry) }.font(.caption)
                                Button("移除…") { vm.pendingDeleteEntry = entry }
                                    .font(.caption)
                                    .foregroundStyle(StudioTheme.danger)
                            }
                            .padding(10)
                            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioTheme.border))
                        }
                    }

                    Divider().overlay(StudioTheme.border)

                    // Built-in models (show/hide/restore)
                    HStack {
                        Text("內建圖片模型設定檔")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudioTheme.textPrimary)
                        Spacer()
                        if !vm.userState.hiddenBuiltInIds.isEmpty {
                            Button("全部還原內建項目") {
                                do {
                                    try UserModelRegistry.restoreAllBuiltIns()
                                    reloadState("已還原所有隱藏的內建圖片模型。")
                                } catch { vm.errorMessage = error.localizedDescription }
                            }
                            .font(.caption)
                        }
                    }

                    ForEach(ModelProfileStore.shared.builtInImageModels) { profile in
                        let isHidden = vm.userState.hiddenBuiltInIds.contains(profile.id)
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(profile.displayName)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(isHidden ? StudioTheme.textMuted : StudioTheme.textPrimary)
                                    if isHidden {
                                        Text("已隱藏")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(StudioTheme.warning.opacity(0.2), in: Capsule())
                                            .foregroundStyle(StudioTheme.warning)
                                    }
                                }
                                Text("\(profile.id) · \(profile.architecture) · \(profile.precision)")
                                    .font(.caption2)
                                    .foregroundStyle(StudioTheme.textSecondary)
                            }
                            Spacer()
                            if isHidden {
                                Button("還原顯示") {
                                    do {
                                        try UserModelRegistry.restoreBuiltIn(id: profile.id)
                                        reloadState("已還原內建模型「\(profile.displayName)」。")
                                    } catch { vm.errorMessage = error.localizedDescription }
                                }.font(.caption)
                            } else {
                                Button("從選單隱藏") {
                                    do {
                                        try UserModelRegistry.hideBuiltIn(id: profile.id)
                                        if app.project.localImageModel == profile.id,
                                           let fallback = ModelProfileStore.shared.imageModels.first {
                                            app.project.localImageModel = fallback.id
                                        }
                                        reloadState("已隱藏內建模型「\(profile.displayName)」（保留實際權重檔，隨時可還原）。")
                                    } catch { vm.errorMessage = error.localizedDescription }
                                }.font(.caption)
                            }
                        }
                        .padding(9)
                        .background(StudioTheme.well, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .background(StudioTheme.panel)
        .confirmationDialog(
            "移除自訂模型項目",
            isPresented: Binding(get: { vm.pendingDeleteEntry != nil }, set: { if !$0 { vm.pendingDeleteEntry = nil } }),
            titleVisibility: .visible
        ) {
            if let entry = vm.pendingDeleteEntry {
                Button("僅移除清單項目（保留權重檔）") {
                    remove(entry, deleteWeight: false)
                }
                let isProtected = UserModelRegistry.isWeightSharedOrProtected(
                    filename: entry.primaryWeight,
                    category: entry.primaryCategory,
                    excludingEntryID: entry.id,
                    state: vm.userState
                )
                if !isProtected {
                    Button("移除項目並刪除專屬權重檔（\(entry.primaryWeight)）", role: .destructive) {
                        remove(entry, deleteWeight: true)
                    }
                }
                Button("取消", role: .cancel) { vm.pendingDeleteEntry = nil }
            }
        } message: {
            if vm.pendingDeleteEntry != nil {
                Text("共用 Text Encoder / VAE 與內建權重受保護不會被刪除。建議預設僅移除清單項目，保留磁碟權重檔。")
            }
        }
    }

    private var addOrEditForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.editingEntry == nil ? "新增本機圖片模型" : "編輯模型：\(vm.editingEntry?.displayName ?? "")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudioTheme.coral)
            TextField("顯示名稱（例如：我的 SDXL 寫實模型）", text: $vm.draftName)
                .textFieldStyle(.roundedBorder)
            Picker("相容基底架構設定檔", selection: $vm.draftBaseProfile) {
                ForEach(UserModelRegistry.supportedBaseProfiles, id: \.self) { base in
                    let label = ModelProfileStore.shared.builtInImageModels.first(where: { $0.id == base })?.displayName ?? base
                    Text("\(label)（\(base) · \(UserModelRegistry.primaryCategory(for: base))）").tag(base)
                }
            }
            HStack(spacing: 8) {
                TextField("主權重檔名（.safetensors）", text: $vm.draftPrimaryWeight)
                    .textFieldStyle(.roundedBorder)
                Button(vm.isImportingWeight ? "驗證複製中…" : "選擇 .safetensors 匯入…") {
                    importSafetensorsWeight()
                }
                .disabled(vm.isImportingWeight)
            }
            let category = UserModelRegistry.primaryCategory(for: vm.draftBaseProfile)
            let available = CentralComfyModelStorage.listWeights(in: category, comfyRoot: activeComfyRoot)
            if !available.isEmpty {
                Picker("或選擇已存在於 \(category) 的權重", selection: $vm.draftPrimaryWeight) {
                    Text("— 選擇現有權重 —").tag("")
                    ForEach(available, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .font(.caption)
            }
            TextField("備註（選填）", text: $vm.draftNotes)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") {
                    vm.showAddForm = false
                    vm.editingEntry = nil
                }
                Spacer()
                Button("儲存模型項目") { saveDraft() }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.coral)
                    .disabled(vm.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.draftPrimaryWeight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.coral.opacity(0.45)))
    }

    private func beginNewEntry() {
        vm.editingEntry = nil
        vm.draftName = ""
        vm.draftBaseProfile = "sdxl1"
        vm.draftPrimaryWeight = ""
        vm.draftImportedHash = nil
        vm.draftNotes = ""
        vm.errorMessage = ""
        vm.showAddForm = true
    }

    private func beginEdit(_ entry: UserImageModelEntry) {
        vm.editingEntry = entry
        vm.draftName = entry.displayName
        vm.draftBaseProfile = entry.baseProfile
        vm.draftPrimaryWeight = entry.primaryWeight
        vm.draftImportedHash = entry.weightSHA256
        vm.draftNotes = entry.notes
        vm.errorMessage = ""
        vm.showAddForm = true
    }

    private func importSafetensorsWeight() {
        let panel = NSOpenPanel()
        panel.title = "選擇 .safetensors 模型權重檔"
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let category = UserModelRegistry.primaryCategory(for: vm.draftBaseProfile)
        let comfyRoot = activeComfyRoot
        vm.isImportingWeight = true
        vm.errorMessage = ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try UserModelRegistry.importWeight(from: url, category: category, comfyRoot: comfyRoot)
                DispatchQueue.main.async {
                    vm.draftPrimaryWeight = result.filename
                    vm.draftImportedHash = result.sha256
                    if vm.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vm.draftName = url.deletingPathExtension().lastPathComponent
                    }
                    vm.isImportingWeight = false
                    vm.statusMessage = "已驗證並匯入至中央儲存：\(category)/\(result.filename)"
                }
            } catch {
                DispatchQueue.main.async {
                    vm.isImportingWeight = false
                    vm.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveDraft() {
        do {
            let entry = try UserModelRegistry.upsertEntry(
                id: vm.editingEntry?.id,
                displayName: vm.draftName,
                baseProfile: vm.draftBaseProfile,
                primaryWeight: vm.draftPrimaryWeight,
                weightSHA256: vm.draftImportedHash,
                notes: vm.draftNotes
            )
            vm.showAddForm = false
            vm.editingEntry = nil
            reloadState("已儲存本機圖片模型「\(entry.displayName)」（基底：\(entry.baseProfile)）。")
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    private func remove(_ entry: UserImageModelEntry, deleteWeight: Bool) {
        vm.pendingDeleteEntry = nil
        do {
            let deletedFile = try UserModelRegistry.removeEntry(
                id: entry.id,
                deleteWeightFile: deleteWeight,
                comfyRoot: activeComfyRoot
            )
            if app.project.localImageModel == entry.id,
               let fallback = ModelProfileStore.shared.imageModels.first {
                app.project.localImageModel = fallback.id
            }
            reloadState(deletedFile
                ? "已移除「\(entry.displayName)」並刪除專屬權重檔 \(entry.primaryWeight)。"
                : "已移除「\(entry.displayName)」（保留實際權重檔）。")
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    private func reloadState(_ message: String) {
        vm.userState = UserModelRegistry.safeLoad()
        vm.statusMessage = message
        vm.errorMessage = ""
        app.objectWillChange.send()
    }
}
