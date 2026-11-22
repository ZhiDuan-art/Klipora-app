import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case en = "en"
    case ja = "ja"
    case ko = "ko"

    var id: String { rawValue }

    var nativeDisplayName: String {
        switch self {
        case .system: return "跟隨系統 / System"
        case .zhHant: return "繁體中文"
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }

    var resolvedCode: String {
        if self != .system { return rawValue }
        for preferred in Locale.preferredLanguages {
            let lower = preferred.lowercased()
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return "zh-Hant"
            }
            if lower.hasPrefix("zh") {
                return "zh-Hans"
            }
            if lower.hasPrefix("ja") { return "ja" }
            if lower.hasPrefix("ko") { return "ko" }
            if lower.hasPrefix("en") { return "en" }
        }
        return "zh-Hant"
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    static let defaultsKey = "Klipora.appLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            reloadCatalog()
        }
    }

    @Published private(set) var strings: [String: String] = [:]
    private var fallbackStrings: [String: String] = [:]

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: saved) ?? .system
        self.fallbackStrings = Self.loadJSON(code: "zh-Hant")
        self.strings = Self.loadJSON(code: self.language.resolvedCode)
    }

    func reloadCatalog() {
        let code = language.resolvedCode
        strings = Self.loadJSON(code: code)
    }

    func text(_ key: String, fallback: String? = nil) -> String {
        if let val = strings[key], !val.isEmpty { return val }
        if let val = fallbackStrings[key], !val.isEmpty { return val }
        return fallback ?? key
    }

    private static func loadJSON(code: String) -> [String: String] {
        if let url = Bundle.main.url(forResource: code, withExtension: "json", subdirectory: "locales"),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        if let url = Bundle.main.url(forResource: code, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            return dict
        }
        return [:]
    }
}

@MainActor
enum L10n {
    static func t(_ key: String, fallback: String? = nil) -> String {
        LocalizationManager.shared.text(key, fallback: fallback)
    }
}
