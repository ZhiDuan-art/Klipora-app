import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Decoding Helpers

private extension KeyedDecodingContainer {
    func decodeFirst<T: Decodable>(_ type: T.Type, keys: [K]) -> T? {
        for key in keys {
            if let value = try? decode(type, forKey: key) {
                return value
            }
        }
        return nil
    }
}

// MARK: - Codable Model Profile Schema (Single Source of Truth: model_profiles.json)

struct IntRangeSpec: Codable, Equatable, Sendable {
    let min: Int
    let max: Int
    let step: Int

    init(min: Int, max: Int, step: Int = 1) {
        self.min = min
        self.max = Swift.max(min, max)
        self.step = Swift.max(1, step)
    }

    func clamped(_ value: Int) -> Int {
        Swift.min(max, Swift.max(min, value))
    }

    private enum CodingKeys: String, CodingKey {
        case min, max, step
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            let minVal = (try? container.decode(Int.self, forKey: .min)) ?? 1
            let maxVal = (try? container.decode(Int.self, forKey: .max)) ?? Swift.max(minVal, 50)
            let stepVal = (try? container.decode(Int.self, forKey: .step)) ?? 1
            self.init(min: minVal, max: maxVal, step: stepVal)
            return
        }
        let array = try decoder.singleValueContainer().decode([Int].self)
        let minVal = array.first ?? 1
        let maxVal = array.dropFirst().first ?? Swift.max(minVal, 50)
        let stepVal = array.dropFirst(2).first ?? 1
        self.init(min: minVal, max: maxVal, step: stepVal)
    }
}

struct DoubleRangeSpec: Codable, Equatable, Sendable {
    let min: Double
    let max: Double
    let step: Double

    init(min: Double, max: Double, step: Double = 0.1) {
        self.min = min
        self.max = Swift.max(min, max)
        self.step = step > 0 ? step : 0.1
    }

    func clamped(_ value: Double) -> Double {
        let bounded = Swift.min(max, Swift.max(min, value))
        return (bounded * 100).rounded() / 100
    }

    func withDefaultStep(_ preferredStep: Double) -> DoubleRangeSpec {
        DoubleRangeSpec(min: min, max: max, step: preferredStep)
    }

    private enum CodingKeys: String, CodingKey {
        case min, max, step
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            let minVal = (try? container.decode(Double.self, forKey: .min)) ?? 0.0
            let maxVal = (try? container.decode(Double.self, forKey: .max)) ?? Swift.max(minVal, 10.0)
            let stepVal = (try? container.decode(Double.self, forKey: .step)) ?? 0.1
            self.init(min: minVal, max: maxVal, step: stepVal)
            return
        }
        let array = try decoder.singleValueContainer().decode([Double].self)
        let minVal = array.first ?? 0.0
        let maxVal = array.dropFirst().first ?? Swift.max(minVal, 10.0)
        let stepVal = array.dropFirst(2).first ?? 0.1
        self.init(min: minVal, max: maxVal, step: stepVal)
    }
}

struct RemovedModelNotice: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let title: String
    let message: String
    let reason: String?
    let removedAt: String?
    let recommendedReplacements: [String]

    init(
        id: String,
        displayName: String,
        title: String = "模型已移除",
        message: String,
        reason: String? = nil,
        removedAt: String? = nil,
        recommendedReplacements: [String] = ["redcraft", "zimage", "krea2", "moss", "iniverse_flux", "sdxl1"]
    ) {
        self.id = id
        self.displayName = displayName
        self.title = title
        self.message = message
        self.reason = reason
        self.removedAt = removedAt
        self.recommendedReplacements = recommendedReplacements
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName, display_name, name, label
        case title
        case message, reason, notice, removedAt
        case recommendedReplacement, recommended_replacement
        case recommendedReplacements, recommended_replacements, replacements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = (try? container.decode(String.self, forKey: .id)) ?? ""
        let decodedDisplayName = container.decodeFirst(String.self, keys: [.displayName, .display_name, .name, .label])
            ?? (decodedID.isEmpty ? "RealXL" : decodedID)
        let decodedTitle = (try? container.decode(String.self, forKey: .title)) ?? "模型已移除"
        let decodedReason = try? container.decode(String.self, forKey: .reason)
        let decodedRemovedAt = try? container.decode(String.self, forKey: .removedAt)
        let decodedMessage = container.decodeFirst(String.self, keys: [.message, .notice, .reason])
            ?? "模型 \(decodedDisplayName) 已移除，請改選其他本機圖片模型（不會靜默替換生成）。"

        var replacements = container.decodeFirst([String].self, keys: [.recommendedReplacements, .recommended_replacements, .replacements])
            ?? ["redcraft", "zimage", "krea2", "moss", "iniverse_flux", "sdxl1"]
        if let primary = container.decodeFirst(String.self, keys: [.recommendedReplacement, .recommended_replacement]),
           !primary.isEmpty {
            replacements.removeAll { $0 == primary }
            replacements.insert(primary, at: 0)
        }
        self.init(
            id: decodedID,
            displayName: decodedDisplayName,
            title: decodedTitle,
            message: decodedMessage,
            reason: decodedReason,
            removedAt: decodedRemovedAt,
            recommendedReplacements: replacements
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(title, forKey: .title)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(removedAt, forKey: .removedAt)
        try container.encode(recommendedReplacements, forKey: .recommendedReplacements)
    }

    func withID(_ key: String) -> RemovedModelNotice {
        guard id.isEmpty else { return self }
        return RemovedModelNotice(
            id: key,
            displayName: displayName,
            title: title,
            message: message,
            reason: reason,
            removedAt: removedAt,
            recommendedReplacements: recommendedReplacements
        )
    }
}

struct LoRAProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let filename: String
    let compatibleModels: [String]
    let defaultStrength: Double
    let triggerNote: String?

    init(
        id: String,
        name: String,
        filename: String,
        compatibleModels: [String],
        defaultStrength: Double = 0.75,
        triggerNote: String? = nil
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.compatibleModels = compatibleModels
        self.defaultStrength = defaultStrength
        self.triggerNote = triggerNote
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name, displayName, display_name, label
        case filename, file
        case compatibleModels, compatible_models, models
        case defaultStrength, default_strength, strength
        case triggerNote, trigger_note, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = (try? container.decode(String.self, forKey: .id)) ?? ""
        let decodedName = container.decodeFirst(String.self, keys: [.displayName, .name, .display_name, .label]) ?? decodedID
        let decodedFile = container.decodeFirst(String.self, keys: [.filename, .file]) ?? ""
        let compatible = container.decodeFirst([String].self, keys: [.compatibleModels, .compatible_models, .models])
            ?? ["zimage", "redcraft"]
        let strength = container.decodeFirst(Double.self, keys: [.defaultStrength, .default_strength, .strength]) ?? 0.75
        let note = container.decodeFirst(String.self, keys: [.triggerNote, .trigger_note, .note])
        self.init(
            id: decodedID,
            name: decodedName,
            filename: decodedFile,
            compatibleModels: compatible,
            defaultStrength: strength,
            triggerNote: note
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .displayName)
        try container.encode(filename, forKey: .filename)
        try container.encode(compatibleModels, forKey: .compatibleModels)
        try container.encode(defaultStrength, forKey: .defaultStrength)
        try container.encodeIfPresent(triggerNote, forKey: .triggerNote)
    }

    func withID(_ key: String) -> LoRAProfile {
        guard id.isEmpty else { return self }
        return LoRAProfile(
            id: key,
            name: name.isEmpty ? key : name,
            filename: filename,
            compatibleModels: compatibleModels,
            defaultStrength: defaultStrength,
            triggerNote: triggerNote
        )
    }
}

struct ModelDefaults: Codable, Equatable, Sendable {
    let steps: Int
    let cfg: Double
    let sampler: String
    let scheduler: String
    let shift: Double?
    let guidance: Double?
    let negativePrompt: String?
    let denoise: Double?
    let img2imgDenoise: Double?
    let fps: Int?
    let seconds: Int?

    var effectiveImg2ImgDenoise: Double {
        img2imgDenoise ?? 0.55
    }

    init(
        steps: Int,
        cfg: Double,
        sampler: String,
        scheduler: String,
        shift: Double? = nil,
        guidance: Double? = nil,
        negativePrompt: String? = nil,
        denoise: Double? = 1.0,
        img2imgDenoise: Double? = nil,
        fps: Int? = nil,
        seconds: Int? = nil
    ) {
        self.steps = steps
        self.cfg = cfg
        self.sampler = sampler
        self.scheduler = scheduler
        self.shift = shift
        self.guidance = guidance
        self.negativePrompt = negativePrompt
        self.denoise = denoise
        self.img2imgDenoise = img2imgDenoise
        self.fps = fps
        self.seconds = seconds
    }

    private enum CodingKeys: String, CodingKey {
        case steps, cfg
        case sampler, sampler_name, samplerName
        case scheduler
        case shift
        case guidance, fluxGuidance, flux_guidance
        case negativePrompt, negative_prompt, negative
        case denoise
        case img2imgDenoise, img2img_denoise
        case fps, seconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stepsVal = (try? container.decode(Int.self, forKey: .steps)) ?? 9
        let cfgVal = (try? container.decode(Double.self, forKey: .cfg)) ?? 1.0
        let samplerVal = container.decodeFirst(String.self, keys: [.sampler, .sampler_name, .samplerName]) ?? "euler"
        let schedulerVal = (try? container.decode(String.self, forKey: .scheduler)) ?? "simple"
        let shiftVal = try? container.decode(Double.self, forKey: .shift)
        let guidanceVal = container.decodeFirst(Double.self, keys: [.guidance, .fluxGuidance, .flux_guidance])
        let negVal = container.decodeFirst(String.self, keys: [.negativePrompt, .negative_prompt, .negative])
        let denoiseVal = try? container.decode(Double.self, forKey: .denoise)
        let img2imgDenoiseVal = container.decodeFirst(Double.self, keys: [.img2imgDenoise, .img2img_denoise])
        let fpsVal = try? container.decode(Int.self, forKey: .fps)
        let secondsVal = try? container.decode(Int.self, forKey: .seconds)
        self.init(
            steps: stepsVal,
            cfg: cfgVal,
            sampler: samplerVal,
            scheduler: schedulerVal,
            shift: shiftVal,
            guidance: guidanceVal,
            negativePrompt: negVal,
            denoise: denoiseVal,
            img2imgDenoise: img2imgDenoiseVal,
            fps: fpsVal,
            seconds: secondsVal
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
        try container.encode(cfg, forKey: .cfg)
        try container.encode(sampler, forKey: .sampler)
        try container.encode(scheduler, forKey: .scheduler)
        try container.encodeIfPresent(shift, forKey: .shift)
        try container.encodeIfPresent(guidance, forKey: .guidance)
        try container.encodeIfPresent(negativePrompt, forKey: .negativePrompt)
        try container.encodeIfPresent(denoise, forKey: .denoise)
        try container.encodeIfPresent(img2imgDenoise, forKey: .img2imgDenoise)
        try container.encodeIfPresent(fps, forKey: .fps)
        try container.encodeIfPresent(seconds, forKey: .seconds)
    }
}

struct ModelParameterRanges: Codable, Equatable, Sendable {
    let steps: IntRangeSpec
    let cfg: DoubleRangeSpec
    let samplers: [String]
    let schedulers: [String]
    let shift: DoubleRangeSpec?
    let guidance: DoubleRangeSpec?
    let denoise: DoubleRangeSpec?
    let seconds: IntRangeSpec?

    init(
        steps: IntRangeSpec,
        cfg: DoubleRangeSpec,
        samplers: [String],
        schedulers: [String],
        shift: DoubleRangeSpec? = nil,
        guidance: DoubleRangeSpec? = nil,
        denoise: DoubleRangeSpec? = DoubleRangeSpec(min: 0.2, max: 0.95, step: 0.05),
        seconds: IntRangeSpec? = nil
    ) {
        self.steps = steps
        self.cfg = cfg
        self.samplers = samplers
        self.schedulers = schedulers
        self.shift = shift
        self.guidance = guidance
        self.denoise = denoise
        self.seconds = seconds
    }

    private enum CodingKeys: String, CodingKey {
        case steps, cfg, samplers, schedulers, shift, guidance, denoise, seconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stepsRange = (try? container.decode(IntRangeSpec.self, forKey: .steps))
            ?? IntRangeSpec(min: 4, max: 50, step: 1)
        let rawCfg = (try? container.decode(DoubleRangeSpec.self, forKey: .cfg))
            ?? DoubleRangeSpec(min: 1.0, max: 8.0, step: 0.5)
        let cfgStep: Double = (rawCfg.max - rawCfg.min) <= 1.5 ? 0.1 : 0.5
        let cfgRange = rawCfg.withDefaultStep(cfgStep)

        let samplersList = (try? container.decode([String].self, forKey: .samplers))
            ?? ["euler", "res_multistep", "dpmpp_2m"]
        let schedulersList = (try? container.decode([String].self, forKey: .schedulers))
            ?? ["simple", "sgm_uniform", "beta"]
        let shiftRange = (try? container.decode(DoubleRangeSpec.self, forKey: .shift))?.withDefaultStep(0.5)
        let guidanceRange = (try? container.decode(DoubleRangeSpec.self, forKey: .guidance))?.withDefaultStep(0.5)
        let denoiseRange = (try? container.decode(DoubleRangeSpec.self, forKey: .denoise))?.withDefaultStep(0.05)
        let secondsRange = try? container.decode(IntRangeSpec.self, forKey: .seconds)
        self.init(
            steps: stepsRange,
            cfg: cfgRange,
            samplers: samplersList,
            schedulers: schedulersList,
            shift: shiftRange,
            guidance: guidanceRange,
            denoise: denoiseRange,
            seconds: secondsRange
        )
    }
}

struct ModelCapabilities: Codable, Equatable, Sendable {
    let supportsImg2Img: Bool
    let supportsVideoFirstFrame: Bool
    let supportsLoRA: Bool
    let supportsNegativePrompt: Bool
    let supportsShift: Bool
    let supportsGuidance: Bool
    let supportsSkipLayer: Bool
    let compatibleLoRAs: [String]
    let unsupportedNotes: [String]

    init(
        supportsImg2Img: Bool,
        supportsVideoFirstFrame: Bool = false,
        supportsLoRA: Bool,
        supportsNegativePrompt: Bool,
        supportsShift: Bool,
        supportsGuidance: Bool,
        supportsSkipLayer: Bool = false,
        compatibleLoRAs: [String] = [],
        unsupportedNotes: [String] = []
    ) {
        self.supportsImg2Img = supportsImg2Img
        self.supportsVideoFirstFrame = supportsVideoFirstFrame
        self.supportsLoRA = supportsLoRA
        self.supportsNegativePrompt = supportsNegativePrompt
        self.supportsShift = supportsShift
        self.supportsGuidance = supportsGuidance
        self.supportsSkipLayer = supportsSkipLayer
        self.compatibleLoRAs = compatibleLoRAs
        self.unsupportedNotes = unsupportedNotes
    }

    private enum CodingKeys: String, CodingKey {
        case supportsImg2Img, supports_img2img, img2img, supportsReference, supports_reference
        case supportsVideoFirstFrame, supports_video_first_frame, supportsVideoReference, supports_video_reference
        case supportsLoRA, supports_lora, supportsLora, lora
        case supportsNegativePrompt, supports_negative_prompt, supportsNegative, negativePrompt
        case supportsShift, supports_shift, shift
        case supportsGuidance, supports_guidance, guidance
        case supportsSkipLayer, supports_skip_layer
        case compatibleLoRAs, compatible_loras, supportedLoRAs, supported_loras, loras
        case unsupportedNotes, unsupported_notes, limitations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let img2img = container.decodeFirst(Bool.self, keys: [.supportsImg2Img, .supports_img2img, .img2img, .supportsReference, .supports_reference]) ?? false
        let videoFirst = container.decodeFirst(Bool.self, keys: [.supportsVideoFirstFrame, .supports_video_first_frame, .supportsVideoReference, .supports_video_reference]) ?? false
        let lora = container.decodeFirst(Bool.self, keys: [.supportsLoRA, .supports_lora, .supportsLora, .lora]) ?? false
        let neg = container.decodeFirst(Bool.self, keys: [.supportsNegativePrompt, .supports_negative_prompt, .supportsNegative, .negativePrompt]) ?? false
        let shift = container.decodeFirst(Bool.self, keys: [.supportsShift, .supports_shift, .shift]) ?? false
        let guidance = container.decodeFirst(Bool.self, keys: [.supportsGuidance, .supports_guidance, .guidance]) ?? false
        let skipLayer = container.decodeFirst(Bool.self, keys: [.supportsSkipLayer, .supports_skip_layer]) ?? false
        let compatLoRAs = container.decodeFirst([String].self, keys: [.compatibleLoRAs, .compatible_loras, .supportedLoRAs, .supported_loras, .loras]) ?? []
        let notes = container.decodeFirst([String].self, keys: [.unsupportedNotes, .unsupported_notes, .limitations]) ?? []
        self.init(
            supportsImg2Img: img2img,
            supportsVideoFirstFrame: videoFirst,
            supportsLoRA: lora,
            supportsNegativePrompt: neg,
            supportsShift: shift,
            supportsGuidance: guidance,
            supportsSkipLayer: skipLayer,
            compatibleLoRAs: compatLoRAs,
            unsupportedNotes: notes
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(supportsImg2Img, forKey: .supportsImg2Img)
        try container.encode(supportsVideoFirstFrame, forKey: .supportsVideoFirstFrame)
        try container.encode(supportsLoRA, forKey: .supportsLoRA)
        try container.encode(supportsNegativePrompt, forKey: .supportsNegativePrompt)
        try container.encode(supportsShift, forKey: .supportsShift)
        try container.encode(supportsGuidance, forKey: .supportsGuidance)
        try container.encode(supportsSkipLayer, forKey: .supportsSkipLayer)
        try container.encode(compatibleLoRAs, forKey: .compatibleLoRAs)
        try container.encode(unsupportedNotes, forKey: .unsupportedNotes)
    }
}

private struct SizePairProxy: Decodable {
    let width: Int
    let height: Int

    init(from decoder: Decoder) throws {
        if let arr = try? decoder.singleValueContainer().decode([Int].self), arr.count >= 2 {
            width = arr[0]
            height = arr[1]
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
    }

    private enum CodingKeys: String, CodingKey {
        case width, height
    }
}

struct LocalModelProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let shortName: String
    let kind: String
    let architecture: String
    let precision: String
    let clipType: String
    let vaeName: String
    let alignment: Int
    let maxPixels: Int
    let defaults: ModelDefaults
    let ranges: ModelParameterRanges
    let capabilities: ModelCapabilities
    let nativeSizes: [String: [Int]]
    let nativeSizeNote: String
    let recommendationNote: String
    let sourceSummary: String
    let officialSources: [String]
    let topLevelUnsupportedNotes: [String]
    let negativePromptDisabledNote: String?

    var supportsShift: Bool { capabilities.supportsShift }
    var supportsGuidance: Bool { capabilities.supportsGuidance }
    var supportsNegativePrompt: Bool { capabilities.supportsNegativePrompt }
    var supportsImg2Img: Bool { capabilities.supportsImg2Img }
    var supportsVideoFirstFrame: Bool { capabilities.supportsVideoFirstFrame }
    var supportsLoRA: Bool { capabilities.supportsLoRA }
    var supportsSkipLayer: Bool { capabilities.supportsSkipLayer }
    var compatibleLoRAs: [String] { capabilities.compatibleLoRAs }
    var unsupportedNotes: [String] {
        topLevelUnsupportedNotes.isEmpty ? capabilities.unsupportedNotes : topLevelUnsupportedNotes
    }

    init(
        id: String,
        displayName: String,
        shortName: String,
        kind: String,
        architecture: String,
        precision: String,
        clipType: String,
        vaeName: String,
        alignment: Int = 16,
        maxPixels: Int = 2_097_152,
        defaults: ModelDefaults,
        ranges: ModelParameterRanges,
        capabilities: ModelCapabilities,
        nativeSizes: [String: [Int]],
        nativeSizeNote: String,
        recommendationNote: String,
        sourceSummary: String,
        officialSources: [String] = [],
        topLevelUnsupportedNotes: [String] = [],
        negativePromptDisabledNote: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.kind = kind
        self.architecture = architecture
        self.precision = precision
        self.clipType = clipType
        self.vaeName = vaeName
        self.alignment = alignment
        self.maxPixels = maxPixels
        self.defaults = defaults
        self.ranges = ranges
        self.capabilities = capabilities
        self.nativeSizes = nativeSizes
        self.nativeSizeNote = nativeSizeNote
        self.recommendationNote = recommendationNote
        self.sourceSummary = sourceSummary
        self.officialSources = officialSources
        self.topLevelUnsupportedNotes = topLevelUnsupportedNotes
        self.negativePromptDisabledNote = negativePromptDisabledNote
    }

    func effectiveSummaryLine(with overrides: LocalModelOverrides = LocalModelOverrides()) -> String {
        let steps = overrides.steps ?? defaults.steps
        let cfg = overrides.cfg ?? defaults.cfg
        let sampler = overrides.sampler ?? defaults.sampler
        let scheduler = overrides.scheduler ?? defaults.scheduler
        var tokens: [String] = [precision, "\(steps) steps", String(format: "CFG %.1f", cfg), "\(sampler)/\(scheduler)"]
        if supportsShift, let shift = overrides.shift ?? defaults.shift {
            tokens.append(String(format: "shift %.1f", shift))
        }
        if supportsGuidance, let guidance = overrides.guidance ?? defaults.guidance {
            tokens.append(String(format: "guidance %.1f", guidance))
        }
        return tokens.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var summaryLine: String {
        effectiveSummaryLine()
    }

    func nativeSizeDescription(for aspect: String) -> String {
        if let pair = nativeSizes[aspect], pair.count >= 2 {
            return "\(aspect) 預設 \(pair[0])×\(pair[1])"
        }
        let sorted = ["16:9", "9:16", "1:1"].compactMap { key -> String? in
            guard let pair = nativeSizes[key], pair.count >= 2 else { return nil }
            return "\(key) \(pair[0])×\(pair[1])"
        }
        return sorted.isEmpty ? nativeSizeNote : sorted.joined(separator: " · ")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName, display_name, name, label
        case shortName, short_name, shortLabel, short_label
        case kind
        case architecture, arch
        case precision, dtype
        case clipType, clip_type, textEncoder, text_encoder
        case vaeName, vae_name, vae
        case alignment, maxPixels
        case requiredModels
        case defaults
        case ranges
        case capabilities
        case supportsImg2Img, supports_img2img
        case supportsVideoFirstFrame, supports_video_first_frame
        case supportsLoRA, supports_lora
        case supportsNegativePrompt, supports_negative_prompt
        case supportsShift, supports_shift
        case supportsGuidance, supports_guidance
        case compatibleLoRAs, compatible_loras
        case unsupportedNotes, unsupported_notes
        case nativeSizes, native_sizes, defaultSizes, default_sizes, aspectSizes, aspect_sizes
        case nativeSizeNote, native_size_note
        case recommendationNote, recommendation_note, notes, rationale, description
        case sourceSummary, source_summary, sources, officialSources, official_sources
        case negativePromptDisabledNote, negative_prompt_disabled_note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = (try? container.decode(String.self, forKey: .id)) ?? ""
        let fallback = ModelProfileCatalog.fallback.models.first(where: { $0.id == decodedID })

        let decodedDisplay = container.decodeFirst(String.self, keys: [.displayName, .display_name, .name, .label])
            ?? fallback?.displayName
            ?? decodedID
        let decodedShort = container.decodeFirst(String.self, keys: [.shortLabel, .short_label, .shortName, .short_name])
            ?? fallback?.shortName
            ?? decodedDisplay
        let decodedKind = (try? container.decode(String.self, forKey: .kind))
            ?? fallback?.kind
            ?? (["wan22", "wan22_14b", "ltxv13b"].contains(decodedID) ? "video" : "image")
        let decodedArch = container.decodeFirst(String.self, keys: [.architecture, .arch])
            ?? fallback?.architecture
            ?? "DiT"
        let decodedPrecision: String
        if let explicit = container.decodeFirst(String.self, keys: [.precision, .dtype]) {
            decodedPrecision = explicit
        } else if decodedDisplay.uppercased().contains("FP16") {
            decodedPrecision = "FP16"
        } else if decodedDisplay.uppercased().contains("BF16") {
            decodedPrecision = "BF16"
        } else if decodedDisplay.uppercased().contains("FP8") {
            decodedPrecision = "FP8"
        } else if decodedArch.uppercased().contains("FP16") {
            decodedPrecision = "FP16"
        } else if decodedArch.uppercased().contains("BF16") {
            decodedPrecision = "BF16"
        } else if decodedArch.uppercased().contains("FP8") {
            decodedPrecision = "FP8"
        } else {
            decodedPrecision = fallback?.precision ?? "BF16"
        }

        let requiredModels = try? container.decode([String: [String]].self, forKey: .requiredModels)
        let inferredClip = requiredModels?["text_encoders"]?.joined(separator: " + ")
        let inferredVAE = requiredModels?["vae"]?.first
        let decodedClip = container.decodeFirst(String.self, keys: [.clipType, .clip_type, .textEncoder, .text_encoder])
            ?? inferredClip
            ?? fallback?.clipType
            ?? ""
        let decodedVAE = container.decodeFirst(String.self, keys: [.vaeName, .vae_name, .vae])
            ?? inferredVAE
            ?? fallback?.vaeName
            ?? ""
        let decodedAlignment = (try? container.decode(Int.self, forKey: .alignment)) ?? fallback?.alignment ?? (decodedKind == "video" ? 32 : 16)
        let decodedMaxPixels = (try? container.decode(Int.self, forKey: .maxPixels)) ?? fallback?.maxPixels ?? (decodedKind == "video" ? 901_120 : 2_097_152)

        let decodedDefaults = (try? container.decode(ModelDefaults.self, forKey: .defaults))
            ?? fallback?.defaults
            ?? ModelDefaults(steps: 9, cfg: 1.0, sampler: "euler", scheduler: "simple")
        let decodedRanges = (try? container.decode(ModelParameterRanges.self, forKey: .ranges))
            ?? fallback?.ranges
            ?? ModelParameterRanges(
                steps: IntRangeSpec(min: 4, max: 40, step: 1),
                cfg: DoubleRangeSpec(min: 1.0, max: 8.0, step: 0.5),
                samplers: [decodedDefaults.sampler, "euler", "res_multistep"],
                schedulers: [decodedDefaults.scheduler, "simple", "sgm_uniform"]
            )

        let topNotes = container.decodeFirst([String].self, keys: [.unsupportedNotes, .unsupported_notes]) ?? []
        let decodedCapabilities: ModelCapabilities
        if let caps = try? container.decode(ModelCapabilities.self, forKey: .capabilities) {
            decodedCapabilities = caps
        } else {
            let fb = fallback?.capabilities
            let img2img = container.decodeFirst(Bool.self, keys: [.supportsImg2Img, .supports_img2img]) ?? fb?.supportsImg2Img ?? false
            let videoFirst = container.decodeFirst(Bool.self, keys: [.supportsVideoFirstFrame, .supports_video_first_frame]) ?? fb?.supportsVideoFirstFrame ?? ["wan22", "wan22_14b", "ltxv13b"].contains(decodedID)
            let lora = container.decodeFirst(Bool.self, keys: [.supportsLoRA, .supports_lora]) ?? fb?.supportsLoRA ?? false
            let neg = container.decodeFirst(Bool.self, keys: [.supportsNegativePrompt, .supports_negative_prompt]) ?? fb?.supportsNegativePrompt ?? !(decodedDefaults.negativePrompt ?? "").isEmpty
            let shift = container.decodeFirst(Bool.self, keys: [.supportsShift, .supports_shift]) ?? fb?.supportsShift ?? (decodedDefaults.shift != nil)
            let guidance = container.decodeFirst(Bool.self, keys: [.supportsGuidance, .supports_guidance]) ?? fb?.supportsGuidance ?? (decodedDefaults.guidance != nil)
            let compat = container.decodeFirst([String].self, keys: [.compatibleLoRAs, .compatible_loras]) ?? fb?.compatibleLoRAs ?? []
            decodedCapabilities = ModelCapabilities(
                supportsImg2Img: img2img,
                supportsVideoFirstFrame: videoFirst,
                supportsLoRA: lora,
                supportsNegativePrompt: neg,
                supportsShift: shift,
                supportsGuidance: guidance,
                supportsSkipLayer: fb?.supportsSkipLayer ?? false,
                compatibleLoRAs: compat,
                unsupportedNotes: topNotes.isEmpty ? (fb?.unsupportedNotes ?? []) : topNotes
            )
        }

        let sizeProxyMap = container.decodeFirst(
            [String: SizePairProxy].self,
            keys: [.nativeSizes, .native_sizes, .defaultSizes, .default_sizes, .aspectSizes, .aspect_sizes]
        )
        let decodedNativeSizes: [String: [Int]]
        if let sizeProxyMap, !sizeProxyMap.isEmpty {
            decodedNativeSizes = sizeProxyMap.mapValues { [$0.width, $0.height] }
        } else {
            decodedNativeSizes = fallback?.nativeSizes ?? ["16:9": [1280, 720], "9:16": [720, 1280], "1:1": [1024, 1024]]
        }

        let defaultSizeNote = decodedKind == "video"
            ? "原生影片尺寸需為 \(decodedAlignment) 的倍數且總像素 ≤ \(decodedMaxPixels)（24 fps）。"
            : "自訂寬高建議為 \(decodedAlignment) 的倍數且總像素 ≤ 2MP，可直接走原生 latent。"
        let decodedNativeSizeNote = container.decodeFirst(String.self, keys: [.nativeSizeNote, .native_size_note])
            ?? fallback?.nativeSizeNote
            ?? defaultSizeNote
        let decodedRecNote = container.decodeFirst(String.self, keys: [.recommendationNote, .recommendation_note, .notes, .rationale, .description])
            ?? fallback?.recommendationNote
            ?? ""
        let decodedOfficialSources = container.decodeFirst([String].self, keys: [.officialSources, .official_sources, .sources])
            ?? fallback?.officialSources
            ?? []
        let decodedSourceSummary: String
        if let str = container.decodeFirst(String.self, keys: [.sourceSummary, .source_summary]) {
            decodedSourceSummary = str
        } else if !decodedOfficialSources.isEmpty {
            decodedSourceSummary = decodedOfficialSources.joined(separator: " · ")
        } else {
            decodedSourceSummary = fallback?.sourceSummary ?? ""
        }
        let decodedNegNote = container.decodeFirst(String.self, keys: [.negativePromptDisabledNote, .negative_prompt_disabled_note])
            ?? fallback?.negativePromptDisabledNote

        self.init(
            id: decodedID,
            displayName: decodedDisplay,
            shortName: decodedShort,
            kind: decodedKind,
            architecture: decodedArch,
            precision: decodedPrecision,
            clipType: decodedClip,
            vaeName: decodedVAE,
            alignment: decodedAlignment,
            maxPixels: decodedMaxPixels,
            defaults: decodedDefaults,
            ranges: decodedRanges,
            capabilities: decodedCapabilities,
            nativeSizes: decodedNativeSizes,
            nativeSizeNote: decodedNativeSizeNote,
            recommendationNote: decodedRecNote,
            sourceSummary: decodedSourceSummary,
            officialSources: decodedOfficialSources,
            topLevelUnsupportedNotes: topNotes.isEmpty ? (fallback?.unsupportedNotes ?? []) : topNotes,
            negativePromptDisabledNote: decodedNegNote
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(shortName, forKey: .shortLabel)
        try container.encode(kind, forKey: .kind)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(precision, forKey: .precision)
        try container.encode(clipType, forKey: .clipType)
        try container.encode(vaeName, forKey: .vaeName)
        try container.encode(alignment, forKey: .alignment)
        try container.encode(maxPixels, forKey: .maxPixels)
        try container.encode(defaults, forKey: .defaults)
        try container.encode(ranges, forKey: .ranges)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(nativeSizes, forKey: .nativeSizes)
        try container.encode(nativeSizeNote, forKey: .nativeSizeNote)
        try container.encode(recommendationNote, forKey: .recommendationNote)
        try container.encode(sourceSummary, forKey: .sourceSummary)
        try container.encode(officialSources, forKey: .officialSources)
        try container.encode(unsupportedNotes, forKey: .unsupportedNotes)
        try container.encodeIfPresent(negativePromptDisabledNote, forKey: .negativePromptDisabledNote)
    }

    func withID(_ key: String) -> LocalModelProfile {
        guard id.isEmpty else { return self }
        return LocalModelProfile(
            id: key,
            displayName: displayName.isEmpty ? key : displayName,
            shortName: shortName.isEmpty ? key : shortName,
            kind: kind,
            architecture: architecture,
            precision: precision,
            clipType: clipType,
            vaeName: vaeName,
            alignment: alignment,
            maxPixels: maxPixels,
            defaults: defaults,
            ranges: ranges,
            capabilities: capabilities,
            nativeSizes: nativeSizes,
            nativeSizeNote: nativeSizeNote,
            recommendationNote: recommendationNote,
            sourceSummary: sourceSummary,
            officialSources: officialSources,
            topLevelUnsupportedNotes: topLevelUnsupportedNotes,
            negativePromptDisabledNote: negativePromptDisabledNote
        )
    }
}

struct LocalModelOverrides: Codable, Equatable, Sendable {
    var steps: Int?
    var cfg: Double?
    var sampler: String?
    var scheduler: String?
    var shift: Double?
    var guidance: Double?
    var negativePrompt: String?
    var denoise: Double?

    init(
        steps: Int? = nil,
        cfg: Double? = nil,
        sampler: String? = nil,
        scheduler: String? = nil,
        shift: Double? = nil,
        guidance: Double? = nil,
        negativePrompt: String? = nil,
        denoise: Double? = nil
    ) {
        self.steps = steps
        self.cfg = cfg
        self.sampler = sampler
        self.scheduler = scheduler
        self.shift = shift
        self.guidance = guidance
        self.negativePrompt = negativePrompt
        self.denoise = denoise
    }

    var isEmpty: Bool {
        steps == nil
            && cfg == nil
            && sampler == nil
            && scheduler == nil
            && shift == nil
            && guidance == nil
            && negativePrompt == nil
            && denoise == nil
    }

    func normalized(against profile: LocalModelProfile) -> LocalModelOverrides {
        var copy = self
        if let s = copy.steps {
            let clamped = profile.ranges.steps.clamped(s)
            copy.steps = clamped == profile.defaults.steps ? nil : clamped
        }
        if let c = copy.cfg {
            let clamped = profile.ranges.cfg.clamped(c)
            copy.cfg = abs(clamped - profile.defaults.cfg) < 0.001 ? nil : clamped
        }
        if let sp = copy.sampler {
            if sp.isEmpty || sp == profile.defaults.sampler { copy.sampler = nil }
        }
        if let sc = copy.scheduler {
            if sc.isEmpty || sc == profile.defaults.scheduler { copy.scheduler = nil }
        }
        if profile.supportsShift, let sh = copy.shift {
            let clamped = profile.ranges.shift?.clamped(sh) ?? ((sh * 100).rounded() / 100)
            let def = profile.defaults.shift ?? 3.0
            copy.shift = abs(clamped - def) < 0.001 ? nil : clamped
        } else {
            copy.shift = nil
        }
        if profile.supportsGuidance, let g = copy.guidance {
            let clamped = profile.ranges.guidance?.clamped(g) ?? ((g * 100).rounded() / 100)
            let def = profile.defaults.guidance ?? 3.5
            copy.guidance = abs(clamped - def) < 0.001 ? nil : clamped
        } else {
            copy.guidance = nil
        }
        if profile.supportsNegativePrompt, let neg = copy.negativePrompt {
            let def = profile.defaults.negativePrompt ?? ""
            copy.negativePrompt = neg == def ? nil : neg
        } else {
            copy.negativePrompt = nil
        }
        if profile.supportsImg2Img && profile.kind == "image", let d = copy.denoise {
            let clamped = profile.ranges.denoise?.clamped(d) ?? ((min(1.0, max(0.1, d)) * 100).rounded() / 100)
            let def = profile.defaults.effectiveImg2ImgDenoise
            copy.denoise = abs(clamped - def) < 0.001 ? nil : clamped
        } else {
            copy.denoise = nil
        }
        return copy
    }
}

struct ModelProfileCatalog: Codable, Equatable, Sendable {
    let version: String
    let engineLabel: String
    let modelOrder: [String]
    let removedModels: [String: RemovedModelNotice]
    let loras: [LoRAProfile]
    let models: [LocalModelProfile]

    init(
        version: String,
        engineLabel: String = "本機 ComfyUI",
        modelOrder: [String] = ["zimage", "redcraft", "iniverse_flux", "moss", "krea2", "sdxl1", "wan22", "wan22_14b", "ltxv13b"],
        removedModels: [String: RemovedModelNotice],
        loras: [LoRAProfile],
        models: [LocalModelProfile]
    ) {
        self.version = version
        self.engineLabel = engineLabel
        self.modelOrder = modelOrder
        self.removedModels = removedModels
        self.loras = loras
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case version, schemaVersion
        case engineLabel, engine_label
        case modelOrder, model_order
        case removedModels, removed_models
        case loras
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let vStr = container.decodeFirst(String.self, keys: [.version, .schemaVersion]) {
            version = vStr
        } else if let vInt = container.decodeFirst(Int.self, keys: [.schemaVersion, .version]) {
            version = String(vInt)
        } else {
            version = "1"
        }

        engineLabel = container.decodeFirst(String.self, keys: [.engineLabel, .engine_label]) ?? "本機 ComfyUI"

        let rawRemoved = container.decodeFirst([String: RemovedModelNotice].self, keys: [.removedModels, .removed_models])
            ?? ModelProfileCatalog.fallback.removedModels
        var normalizedRemoved: [String: RemovedModelNotice] = [:]
        for (key, value) in rawRemoved {
            normalizedRemoved[key] = value.withID(key)
        }
        if normalizedRemoved["realxl"] == nil, let fbRealXL = ModelProfileCatalog.fallback.removedModels["realxl"] {
            normalizedRemoved["realxl"] = fbRealXL
        }
        removedModels = normalizedRemoved

        if let list = try? container.decode([LoRAProfile].self, forKey: .loras) {
            loras = list
        } else if let dict = try? container.decode([String: LoRAProfile].self, forKey: .loras) {
            let preferredOrder = ["redz15", "pixel_art"]
            loras = dict.map { $0.value.withID($0.key) }.sorted { lhs, rhs in
                let li = preferredOrder.firstIndex(of: lhs.id) ?? Int.max
                let ri = preferredOrder.firstIndex(of: rhs.id) ?? Int.max
                return li != ri ? li < ri : lhs.id < rhs.id
            }
        } else {
            loras = ModelProfileCatalog.fallback.loras
        }

        let explicitOrder = container.decodeFirst([String].self, keys: [.modelOrder, .model_order])
            ?? ["zimage", "redcraft", "iniverse_flux", "moss", "krea2", "sdxl1", "wan22", "wan22_14b", "ltxv13b"]
        modelOrder = explicitOrder

        let decodedModels: [LocalModelProfile]
        if let list = try? container.decode([LocalModelProfile].self, forKey: .models) {
            decodedModels = list
        } else if let dict = try? container.decode([String: LocalModelProfile].self, forKey: .models) {
            decodedModels = dict.map { $0.value.withID($0.key) }.sorted { lhs, rhs in
                let li = explicitOrder.firstIndex(of: lhs.id) ?? Int.max
                let ri = explicitOrder.firstIndex(of: rhs.id) ?? Int.max
                return li != ri ? li < ri : lhs.id < rhs.id
            }
        } else {
            decodedModels = ModelProfileCatalog.fallback.models
        }
        let removedIDs = Set(normalizedRemoved.keys).union(["realxl"])
        models = decodedModels.filter { !removedIDs.contains($0.id) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(engineLabel, forKey: .engineLabel)
        try container.encode(modelOrder, forKey: .modelOrder)
        try container.encode(removedModels, forKey: .removedModels)
        try container.encode(loras, forKey: .loras)
        try container.encode(models, forKey: .models)
    }

    static let fallback = ModelProfileCatalog(
        version: "1",
        engineLabel: "本機 ComfyUI",
        modelOrder: ["zimage", "redcraft", "iniverse_flux", "moss", "krea2", "sdxl1", "wan22", "wan22_14b", "ltxv13b"],
        removedModels: [
            "realxl": RemovedModelNotice(
                id: "realxl",
                displayName: "RealXL (SDXL)",
                title: "模型已移除",
                message: "RealXL 模型已移除，請改選其他本機圖片模型（不會靜默替換生成）。",
                reason: "依使用者選擇移除 RealXL（權重已移至垃圾桶）；舊專案或歷史紀錄需改選其他保留之本機模型。",
                removedAt: "2026-11-20",
                recommendedReplacements: ["redcraft", "zimage", "krea2", "moss", "iniverse_flux", "sdxl1"]
            )
        ],
        loras: [
            LoRAProfile(
                id: "redz15",
                name: "REDZ 1.5 TeenyMooddy",
                filename: "REDZ15_teenymooddy_lora_v1.1.safetensors",
                compatibleModels: ["zimage", "redcraft"],
                defaultStrength: 0.75,
                triggerNote: "適用 Z-Image Turbo / RedCraft 1.5 AIO（強度 0.75）"
            ),
            LoRAProfile(
                id: "pixel_art",
                name: "Pixel Art Style (Z-Image Turbo)",
                filename: "pixel_art_style_z_image_turbo.safetensors",
                compatibleModels: ["zimage", "redcraft"],
                defaultStrength: 1.0,
                triggerNote: "適用 Z-Image Turbo / RedCraft 1.5 AIO（強度 1.0，會自動加上 Pixel art style.）"
            )
        ],
        models: [
            LocalModelProfile(
                id: "zimage",
                displayName: "Z-Image Turbo",
                shortName: "Z-Image",
                kind: "image",
                architecture: "S3-DiT (Tongyi-MAI 6B Turbo, Flow Matching)",
                precision: "BF16",
                clipType: "qwen_3_4b.safetensors",
                vaeName: "ae.safetensors",
                alignment: 16,
                maxPixels: 2_097_152,
                defaults: ModelDefaults(
                    steps: 9,
                    cfg: 1.0,
                    sampler: "res_multistep",
                    scheduler: "simple",
                    shift: 3.0,
                    guidance: nil,
                    negativePrompt: "",
                    denoise: 1.0,
                    img2imgDenoise: 0.55
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 6, max: 16, step: 1),
                    cfg: DoubleRangeSpec(min: 1.0, max: 2.0, step: 0.1),
                    samplers: ["res_multistep", "euler"],
                    schedulers: ["simple", "sgm_uniform"],
                    shift: DoubleRangeSpec(min: 1.0, max: 7.0, step: 0.5),
                    guidance: nil,
                    denoise: DoubleRangeSpec(min: 0.2, max: 0.95, step: 0.05)
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: true,
                    supportsVideoFirstFrame: false,
                    supportsLoRA: true,
                    supportsNegativePrompt: false,
                    supportsShift: true,
                    supportsGuidance: false,
                    supportsSkipLayer: false,
                    compatibleLoRAs: ["redz15", "pixel_art"],
                    unsupportedNotes: [
                        "CFG 1.0 蒸餾模型搭配 ConditioningZeroOut，不支援文字負向提示詞與 FluxGuidance。"
                    ]
                ),
                nativeSizes: ["16:9": [1280, 720], "9:16": [720, 1280], "1:1": [1024, 1024]],
                nativeSizeNote: "自訂寬高建議為 16 的倍數且總像素 ≤ 2MP，可直接走原生 latent。",
                recommendationNote: "通義 Z-Image Turbo 6B 蒸餾模型：預設 9 步、CFG 1.0、AuraFlow shift 3.0、res_multistep / simple；實測執行約 56 秒，支援單圖圖生圖與 Z-Image LoRA。",
                sourceSummary: "https://huggingface.co/Tongyi-MAI/Z-Image-Turbo · https://docs.comfy.org/tutorials/image/z-image/z-image-turbo",
                officialSources: [
                    "https://huggingface.co/Tongyi-MAI/Z-Image-Turbo",
                    "https://docs.comfy.org/tutorials/image/z-image/z-image-turbo"
                ],
                topLevelUnsupportedNotes: [
                    "CFG 1.0 蒸餾模型搭配 ConditioningZeroOut，不支援文字負向提示詞與 FluxGuidance。"
                ],
                negativePromptDisabledNote: "此蒸餾模型使用 ConditioningZeroOut，無需負向詞。"
            ),
            LocalModelProfile(
                id: "redcraft",
                displayName: "RedCraft (RedZImage 1.5 AIO)",
                shortName: "RedCraft",
                kind: "image",
                architecture: "Z-Image Turbo Finetune (S3-DiT AIO Checkpoint)",
                precision: "BF16",
                clipType: "AIO Checkpoint",
                vaeName: "AIO Checkpoint",
                alignment: 16,
                maxPixels: 2_097_152,
                defaults: ModelDefaults(
                    steps: 10,
                    cfg: 1.0,
                    sampler: "res_multistep",
                    scheduler: "simple",
                    shift: 3.0,
                    guidance: nil,
                    negativePrompt: "",
                    denoise: 1.0,
                    img2imgDenoise: 0.55
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 8, max: 14, step: 1),
                    cfg: DoubleRangeSpec(min: 1.0, max: 2.0, step: 0.1),
                    samplers: ["res_multistep", "euler", "dpmpp_2m"],
                    schedulers: ["simple", "sgm_uniform"],
                    shift: DoubleRangeSpec(min: 2.0, max: 5.0, step: 0.5),
                    guidance: nil,
                    denoise: DoubleRangeSpec(min: 0.2, max: 0.95, step: 0.05)
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: true,
                    supportsVideoFirstFrame: false,
                    supportsLoRA: true,
                    supportsNegativePrompt: false,
                    supportsShift: true,
                    supportsGuidance: false,
                    supportsSkipLayer: false,
                    compatibleLoRAs: ["redz15", "pixel_art"],
                    unsupportedNotes: [
                        "CFG 1.0 蒸餾模型搭配 ConditioningZeroOut，不支援文字負向提示詞與 FluxGuidance。"
                    ]
                ),
                nativeSizes: ["16:9": [1280, 720], "9:16": [720, 1280], "1:1": [1024, 1024]],
                nativeSizeNote: "單檔整合 Checkpoint，建議 16 倍數原生尺寸（≤ 2MP）。",
                recommendationNote: "RedZImage 1.5 AIO 單檔整合權重，已改用獨立 redcraft.json 模板；預設 10 步、CFG 1.0、shift 3.0、res_multistep / simple，暖光與細節表現優異，支援圖生圖與 Z-Image LoRA。",
                sourceSummary: "https://civitai.com/models/redcraft-redzimage · https://docs.comfy.org/tutorials/image/z-image/z-image-turbo",
                officialSources: [
                    "https://civitai.com/models/redcraft-redzimage",
                    "https://docs.comfy.org/tutorials/image/z-image/z-image-turbo"
                ],
                topLevelUnsupportedNotes: [
                    "CFG 1.0 蒸餾模型搭配 ConditioningZeroOut，不支援文字負向提示詞與 FluxGuidance。"
                ],
                negativePromptDisabledNote: "此蒸餾模型使用 ConditioningZeroOut，無需負向詞。"
            ),
            LocalModelProfile(
                id: "iniverse_flux",
                displayName: "Iniverse FLUX (FP8)",
                shortName: "Iniverse FLUX",
                kind: "image",
                architecture: "FLUX.1-dev Merged Checkpoint (MMDiT FP8 + Dual CLIP/T5-XXL)",
                precision: "FP8",
                clipType: "clip_l + t5xxl_fp8_e4m3fn",
                vaeName: "Checkpoint VAE",
                alignment: 16,
                maxPixels: 2_097_152,
                defaults: ModelDefaults(
                    steps: 22,
                    cfg: 1.0,
                    sampler: "euler",
                    scheduler: "simple",
                    shift: nil,
                    guidance: 3.5,
                    negativePrompt: "",
                    denoise: 1.0,
                    img2imgDenoise: 0.55
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 15, max: 30, step: 1),
                    cfg: DoubleRangeSpec(min: 1.0, max: 2.0, step: 0.1),
                    samplers: ["euler", "dpmpp_2m"],
                    schedulers: ["simple", "sgm_uniform", "beta"],
                    shift: nil,
                    guidance: DoubleRangeSpec(min: 1.5, max: 5.0, step: 0.5),
                    denoise: DoubleRangeSpec(min: 0.2, max: 0.95, step: 0.05)
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: true,
                    supportsVideoFirstFrame: false,
                    supportsLoRA: false,
                    supportsNegativePrompt: false,
                    supportsShift: false,
                    supportsGuidance: true,
                    supportsSkipLayer: false,
                    compatibleLoRAs: [],
                    unsupportedNotes: [
                        "本機目前無相容 FLUX LoRA，不可套用 Z-Image LoRA。",
                        "採用 FluxGuidance 與 ConditioningZeroOut，不支援文字負向提示詞與手動 shift。"
                    ]
                ),
                nativeSizes: ["16:9": [1280, 720], "9:16": [720, 1280], "1:1": [1024, 1024]],
                nativeSizeNote: "ModelSamplingFlux 與輸出解析度連動，建議 16 倍數原生尺寸（≤ 2MP）。",
                recommendationNote: "FLUX.1-dev FP8 融合權重，已補齊 ModelSamplingFlux（width/height 與輸出解析度連動）。Guidance 預設 3.5，若欲減少人像磨皮與平滑塑膠感可調降至 2.5–3.0。",
                sourceSummary: "https://huggingface.co/black-forest-labs/FLUX.1-dev · https://comfyanonymous.github.io/ComfyUI_examples/flux/",
                officialSources: [
                    "https://huggingface.co/black-forest-labs/FLUX.1-dev",
                    "https://comfyanonymous.github.io/ComfyUI_examples/flux/"
                ],
                topLevelUnsupportedNotes: [
                    "本機目前無相容 FLUX LoRA，不可套用 Z-Image LoRA。",
                    "採用 FluxGuidance 與 ConditioningZeroOut，不支援文字負向提示詞與手動 shift。"
                ],
                negativePromptDisabledNote: "採用 FluxGuidance 與 ConditioningZeroOut，無需負向詞。"
            ),
            LocalModelProfile(
                id: "moss",
                displayName: "MOSS-Image (BF16)",
                shortName: "MOSS-Image",
                kind: "image",
                architecture: "MOSS-Image 5B Single-Stream DiT (Qwen3.5-9B + FLUX.2 Small VAE)",
                precision: "BF16",
                clipType: "qwen3.5_9b_bf16.safetensors",
                vaeName: "flux2-vae_small.safetensors",
                alignment: 16,
                maxPixels: 2_097_152,
                defaults: ModelDefaults(
                    steps: 25,
                    cfg: 2.5,
                    sampler: "euler",
                    scheduler: "simple",
                    shift: nil,
                    guidance: nil,
                    negativePrompt: "low quality, blurry, jpeg artifacts, watermark",
                    denoise: 1.0,
                    img2imgDenoise: nil
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 15, max: 50, step: 1),
                    cfg: DoubleRangeSpec(min: 1.5, max: 5.0, step: 0.5),
                    samplers: ["euler", "res_multistep"],
                    schedulers: ["simple", "sgm_uniform"],
                    shift: nil,
                    guidance: nil,
                    denoise: nil
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: false,
                    supportsVideoFirstFrame: false,
                    supportsLoRA: false,
                    supportsNegativePrompt: true,
                    supportsShift: false,
                    supportsGuidance: false,
                    supportsSkipLayer: true,
                    compatibleLoRAs: [],
                    unsupportedNotes: [
                        "flux2-vae_small 圖生圖（img2img）尚未驗證，目前僅支援文字生圖。",
                        "目前無相容本機 MOSS LoRA，不可套用 Z-Image LoRA。",
                        "ComfyUI MOSS-Image 節點已內建取樣排程，請勿額外疊加 ModelSamplingSD3。"
                    ]
                ),
                nativeSizes: ["16:9": [1280, 720], "9:16": [720, 1280], "1:1": [1024, 1024]],
                nativeSizeNote: "Flux2 VAE latent 建議 16 倍數原生尺寸（≤ 2MP）。",
                recommendationNote: "維持本機 MPS 已實測通過之基線設定：SkipLayerGuidanceDiTSimple（single_layers=22, 0–0.5）、euler / simple、25 steps、CFG 2.5，不額外串接 ModelSamplingSD3。",
                sourceSummary: "https://huggingface.co/OpenMOSS-Team/MOSS-Image · https://docs.comfy.org/tutorials/image/moss/moss-image",
                officialSources: [
                    "https://huggingface.co/OpenMOSS-Team/MOSS-Image",
                    "https://docs.comfy.org/tutorials/image/moss/moss-image"
                ],
                topLevelUnsupportedNotes: [
                    "flux2-vae_small 圖生圖（img2img）尚未驗證，目前僅支援文字生圖。",
                    "目前無相容本機 MOSS LoRA，不可套用 Z-Image LoRA。",
                    "ComfyUI MOSS-Image 節點已內建取樣排程，請勿額外疊加 ModelSamplingSD3。"
                ],
                negativePromptDisabledNote: nil
            ),
            LocalModelProfile(
                id: "krea2",
                displayName: "Krea-2 Turbo (BF16)",
                shortName: "Krea-2 Turbo",
                kind: "image",
                architecture: "Krea-2 Turbo DiT (Qwen3-VL-4B + Qwen Image VAE)",
                precision: "BF16",
                clipType: "qwen3vl_4b_bf16.safetensors",
                vaeName: "qwen_image_vae.safetensors",
                alignment: 16,
                maxPixels: 2_097_152,
                defaults: ModelDefaults(
                    steps: 8,
                    cfg: 1.0,
                    sampler: "euler",
                    scheduler: "simple",
                    shift: nil,
                    guidance: nil,
                    negativePrompt: "",
                    denoise: 1.0,
                    img2imgDenoise: nil
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 6, max: 12, step: 1),
                    cfg: DoubleRangeSpec(min: 1.0, max: 2.0, step: 0.1),
                    samplers: ["euler", "er_sde"],
                    schedulers: ["simple", "sgm_uniform"],
                    shift: nil,
                    guidance: nil,
                    denoise: nil
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: false,
                    supportsVideoFirstFrame: false,
                    supportsLoRA: false,
                    supportsNegativePrompt: false,
                    supportsShift: false,
                    supportsGuidance: false,
                    supportsSkipLayer: false,
                    compatibleLoRAs: [],
                    unsupportedNotes: [
                        "目前僅支援文字生圖，不支援參考圖片或參考影片。",
                        "本機未安裝 Krea-2 風格 LoRA，不可套用 Z-Image LoRA。",
                        "CFG 1.0 蒸餾模型搭配 ConditioningZeroOut，不支援文字負向提示詞。"
                    ]
                ),
                nativeSizes: ["16:9": [1280, 720], "9:16": [720, 1280], "1:1": [1024, 1024]],
                nativeSizeNote: "推薦 1280×720 / 1024×1024 等 16 倍數原生尺寸（≤ 2MP）。",
                recommendationNote: "依 Comfy-Org official_krea2_turbo_t2i 節點配置：8 步、CFG 1.0、euler / simple，支援文字生圖（原生 1K 級解析度）。",
                sourceSummary: "https://huggingface.co/Comfy-Org/Krea-2 · https://docs.comfy.org/tutorials/image/krea/krea-2",
                officialSources: [
                    "https://huggingface.co/Comfy-Org/Krea-2",
                    "https://docs.comfy.org/tutorials/image/krea/krea-2"
                ],
                topLevelUnsupportedNotes: [
                    "目前僅支援文字生圖，不支援參考圖片或參考影片。",
                    "本機未安裝 Krea-2 風格 LoRA，不可套用 Z-Image LoRA。",
                    "CFG 1.0 蒸餾模型搭配 ConditioningZeroOut，不支援文字負向提示詞。"
                ],
                negativePromptDisabledNote: "此蒸餾模型使用 ConditioningZeroOut，無需負向詞。"
            ),
            LocalModelProfile(
                id: "sdxl1",
                displayName: "SDXL 1.0 Base",
                shortName: "SDXL 1.0",
                kind: "image",
                architecture: "SDXL 1.0 Base (CheckpointLoaderSimple, built-in CLIP + VAE)",
                precision: "FP16",
                clipType: "Checkpoint 內含雙文字編碼器",
                vaeName: "Checkpoint 內含 VAE",
                alignment: 8,
                maxPixels: 2_097_152,
                defaults: ModelDefaults(
                    steps: 30,
                    cfg: 7.0,
                    sampler: "dpmpp_2m",
                    scheduler: "karras",
                    shift: nil,
                    guidance: nil,
                    negativePrompt: "",
                    denoise: 1.0,
                    img2imgDenoise: 0.55
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 15, max: 60, step: 1),
                    cfg: DoubleRangeSpec(min: 3.0, max: 12.0, step: 0.5),
                    samplers: ["dpmpp_2m", "dpmpp_2m_sde", "euler", "euler_ancestral"],
                    schedulers: ["karras", "normal", "sgm_uniform", "simple"],
                    shift: nil,
                    guidance: nil,
                    denoise: DoubleRangeSpec(min: 0.2, max: 0.95, step: 0.05)
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: true,
                    supportsVideoFirstFrame: false,
                    supportsLoRA: true,
                    supportsNegativePrompt: true,
                    supportsShift: false,
                    supportsGuidance: false,
                    supportsSkipLayer: false,
                    compatibleLoRAs: [],
                    unsupportedNotes: [
                        "LoRA 僅透過 LoraLoaderModelOnly 套用於 UNet 模型權重（不修改 CLIP），請僅匯入 SDXL 1.0 同基底 LoRA。"
                    ]
                ),
                nativeSizes: ["16:9": [1344, 768], "9:16": [768, 1344], "1:1": [1024, 1024]],
                nativeSizeNote: "推薦 1024×1024 / 1344×768 / 768×1344 等 8 倍數原生尺寸（≤ 2MP）。",
                recommendationNote: "官方 SDXL 1.0 Base 單一 Checkpoint（內含 CLIP 與 VAE）：預設 30 步、CFG 7.0、dpmpp_2m / karras，1024 級比例（對齊 8），支援正負向提示詞、一般圖生圖與 SDXL 同基底 LoRA。",
                sourceSummary: "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0",
                officialSources: [
                    "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0"
                ],
                topLevelUnsupportedNotes: [
                    "LoRA 僅透過 LoraLoaderModelOnly 套用於 UNet 模型權重（不修改 CLIP），請僅匯入 SDXL 1.0 同基底 LoRA。"
                ],
                negativePromptDisabledNote: nil
            ),
            LocalModelProfile(
                id: "wan22",
                displayName: "Wan 2.2 TI2V-5B (FP16)",
                shortName: "Wan 2.2",
                kind: "video",
                architecture: "Wan 2.2 TI2V-5B Video DiT (UMT5-XXL FP8 + Wan 2.2 VAE)",
                precision: "FP16",
                clipType: "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
                vaeName: "wan2.2_vae.safetensors",
                alignment: 32,
                maxPixels: 901_120,
                defaults: ModelDefaults(
                    steps: 20,
                    cfg: 5.0,
                    sampler: "euler",
                    scheduler: "simple",
                    shift: 5.0,
                    guidance: nil,
                    negativePrompt: "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走",
                    denoise: 1.0,
                    img2imgDenoise: nil,
                    fps: 24,
                    seconds: 3
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 12, max: 30, step: 1),
                    cfg: DoubleRangeSpec(min: 3.0, max: 7.0, step: 0.5),
                    samplers: ["euler", "uni_pc"],
                    schedulers: ["simple", "sgm_uniform"],
                    shift: DoubleRangeSpec(min: 3.0, max: 8.0, step: 0.5),
                    guidance: nil,
                    denoise: nil,
                    seconds: IntRangeSpec(min: 2, max: 15, step: 1)
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: false,
                    supportsVideoFirstFrame: true,
                    supportsLoRA: false,
                    supportsNegativePrompt: true,
                    supportsShift: true,
                    supportsGuidance: false,
                    supportsSkipLayer: false,
                    compatibleLoRAs: [],
                    unsupportedNotes: [
                        "uni_pc 在本機 Apple Silicon MPS 實測 832×480 與 512×288 均曾出現嚴重條紋與噪點失敗，請預設維持已驗證之 euler。",
                        "僅支援單一首幀參考（圖片或影片取首幀），不支援首尾雙幀、多影格模式與 LoRA。",
                        "VAEDecodeTiled 與 CLIPLoader device=cpu 屬官方文件／理論記憶體優化，本機尚未實測驗證，故未設為預設。"
                    ]
                ),
                nativeSizes: ["16:9": [832, 480], "9:16": [480, 832], "1:1": [640, 640]],
                nativeSizeNote: "原生影片尺寸需為 32 的倍數且總像素 ≤ 901,120（24 fps）。",
                recommendationNote: "維持本機 Apple Silicon MPS 實測通過設定：euler / simple / 20 steps / CFG 5.0 / shift 5.0 / 24fps（24×秒+1 幀）/ VAEDecode / CLIPLoader device=default（已通過人物 2 秒抬手 I2V 實測）。uni_pc 僅作進階實驗選項。",
                sourceSummary: "https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B · https://docs.comfy.org/tutorials/video/wan/wan2_2",
                officialSources: [
                    "https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B",
                    "https://docs.comfy.org/tutorials/video/wan/wan2_2"
                ],
                topLevelUnsupportedNotes: [
                    "uni_pc 在本機 Apple Silicon MPS 實測 832×480 與 512×288 均曾出現嚴重條紋與噪點失敗，請預設維持已驗證之 euler。",
                    "僅支援單一首幀參考（圖片或影片取首幀），不支援首尾雙幀、多影格模式與 LoRA。",
                    "VAEDecodeTiled 與 CLIPLoader device=cpu 屬官方文件／理論記憶體優化，本機尚未實測驗證，故未設為預設。"
                ],
                negativePromptDisabledNote: nil
            ),
            LocalModelProfile(
                id: "wan22_14b",
                displayName: "Wan 2.2 14B MoE + 4-step 加速 (FP8)",
                shortName: "Wan 2.2 14B",
                kind: "video",
                architecture: "Wan 2.2 14B Dual-Expert MoE (High/Low Noise FP8 + LightX2V 4-step LoRA + Wan 2.1 VAE)",
                precision: "FP8",
                clipType: "umt5_xxl_fp8_e4m3fn_scaled.safetensors",
                vaeName: "wan_2.1_vae.safetensors",
                alignment: 16,
                maxPixels: 921_600,
                defaults: ModelDefaults(
                    steps: 4,
                    cfg: 1.0,
                    sampler: "euler",
                    scheduler: "simple",
                    shift: 5.0,
                    guidance: nil,
                    negativePrompt: "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走",
                    denoise: 1.0,
                    img2imgDenoise: nil,
                    fps: 16,
                    seconds: 5
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 4, max: 12, step: 1),
                    cfg: DoubleRangeSpec(min: 1.0, max: 3.0, step: 0.5),
                    samplers: ["euler", "uni_pc"],
                    schedulers: ["simple", "sgm_uniform"],
                    shift: DoubleRangeSpec(min: 3.0, max: 8.0, step: 0.5),
                    guidance: nil,
                    denoise: nil,
                    seconds: IntRangeSpec(min: 2, max: 15, step: 1)
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: false,
                    supportsVideoFirstFrame: true,
                    supportsLoRA: false,
                    supportsNegativePrompt: true,
                    supportsShift: true,
                    supportsGuidance: false,
                    supportsSkipLayer: false,
                    compatibleLoRAs: [],
                    unsupportedNotes: [
                        "本工作流已內建 LightX2V 4-step 加速 LoRA（CFG 1.0），不支援額外外掛 LoRA。",
                        "僅支援單一首幀參考（圖生影效果最佳）或文字生成，不支援首尾雙幀與多影格模式。",
                        "需先於「可選模型下載」下載 5 個檔案（合計約 31.3 GB，共用既有 UMT5-XXL）。"
                    ]
                ),
                nativeSizes: ["16:9": [832, 480], "9:16": [480, 832], "1:1": [640, 640]],
                nativeSizeNote: "原生影片尺寸需為 16 的倍數且總像素 ≤ 921,600（16 fps）。",
                recommendationNote: "高畫質人物動作與手部物理首選（建議 36GB+ RAM）：採用 ComfyUI 原生 FP8 雙專家（High/Low Noise）搭配 LightX2V 4-step 加速 LoRA，僅需 4–8 步（CFG 1.0、16fps）即可完成，手部與互動穩定度遠勝 5B。",
                sourceSummary: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged · https://docs.comfy.org/tutorials/video/wan/wan2_2",
                officialSources: [
                    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
                    "https://docs.comfy.org/tutorials/video/wan/wan2_2"
                ],
                topLevelUnsupportedNotes: [
                    "本工作流已內建 LightX2V 4-step 加速 LoRA（CFG 1.0），不支援額外外掛 LoRA。",
                    "僅支援單一首幀參考（圖生影效果最佳）或文字生成，不支援首尾雙幀與多影格模式。"
                ],
                negativePromptDisabledNote: nil
            ),
            LocalModelProfile(
                id: "ltxv13b",
                displayName: "LTX-Video 13B Distilled (FP8)",
                shortName: "LTX-Video 13B",
                kind: "video",
                architecture: "LTX-Video 0.9.7 13B Distilled FP8 (T5-XXL FP8 + Built-in VAE)",
                precision: "FP8",
                clipType: "t5xxl_fp8_e4m3fn.safetensors",
                vaeName: "Built-in LTXV VAE",
                alignment: 32,
                maxPixels: 921_600,
                defaults: ModelDefaults(
                    steps: 8,
                    cfg: 1.0,
                    sampler: "euler",
                    scheduler: "simple",
                    shift: nil,
                    guidance: nil,
                    negativePrompt: "low quality, worst quality, deformed, distorted, disfigured, motion smear, motion artifacts, fused fingers, bad anatomy, weird hand, ugly",
                    denoise: 1.0,
                    img2imgDenoise: nil,
                    fps: 24,
                    seconds: 4
                ),
                ranges: ModelParameterRanges(
                    steps: IntRangeSpec(min: 4, max: 16, step: 1),
                    cfg: DoubleRangeSpec(min: 1.0, max: 3.5, step: 0.5),
                    samplers: ["euler", "res_multistep"],
                    schedulers: ["simple", "normal"],
                    shift: nil,
                    guidance: nil,
                    denoise: nil,
                    seconds: IntRangeSpec(min: 2, max: 15, step: 1)
                ),
                capabilities: ModelCapabilities(
                    supportsImg2Img: false,
                    supportsVideoFirstFrame: true,
                    supportsLoRA: false,
                    supportsNegativePrompt: true,
                    supportsShift: false,
                    supportsGuidance: false,
                    supportsSkipLayer: false,
                    compatibleLoRAs: [],
                    unsupportedNotes: [
                        "LTX-Video 13B Distilled 建議維持 8 steps / CFG 1.0 與 32 倍數尺寸（預設 768×512），幀數自動對齊 8n+1（24fps）。",
                        "僅支援文字生成或單一首幀圖／影片參考，不支援首尾雙幀、多影格模式與 LoRA。"
                    ]
                ),
                nativeSizes: ["16:9": [768, 512], "9:16": [512, 768], "1:1": [640, 640]],
                nativeSizeNote: "原生影片尺寸需為 32 的倍數且總像素 ≤ 921,600（24 fps，8n+1 幀）。",
                recommendationNote: "Apple Silicon 極速出片首選（建議 32GB+ RAM）：8 步蒸餾模型、鏡頭運動流暢，5 秒影片僅約 1–3 分鐘即可完成，極適合快速試錯與大量剪輯鏡頭（約 15.7 GB，共用既有 T5-XXL）。",
                sourceSummary: "https://huggingface.co/Lightricks/LTX-Video · https://docs.comfy.org/tutorials/video/ltx/ltx-video",
                officialSources: [
                    "https://huggingface.co/Lightricks/LTX-Video",
                    "https://docs.comfy.org/tutorials/video/ltx/ltx-video"
                ],
                topLevelUnsupportedNotes: [
                    "LTX-Video 13B Distilled 建議維持 8 steps / CFG 1.0 與 32 倍數尺寸（預設 768×512）。",
                    "僅支援文字生成或單一首幀圖／影片參考，不支援首尾雙幀、多影格模式與 LoRA。"
                ],
                negativePromptDisabledNote: nil
            )
        ]
    )
}

// MARK: - ModelProfileStore

final class ModelProfileStore: Sendable {
    static let shared = ModelProfileStore()

    let catalog: ModelProfileCatalog
    let loadedFromBundle: Bool

    init(url: URL? = nil) {
        let candidateURL = url ?? Bundle.main.url(forResource: "model_profiles", withExtension: "json")
        if let candidateURL,
           let data = try? Data(contentsOf: candidateURL),
           let decoded = try? JSONDecoder().decode(ModelProfileCatalog.self, from: data),
           !decoded.models.isEmpty {
            self.catalog = decoded
            self.loadedFromBundle = true
        } else {
            self.catalog = ModelProfileCatalog.fallback
            self.loadedFromBundle = false
        }
    }

    var builtInImageModels: [LocalModelProfile] {
        catalog.models.filter { $0.kind == "image" && !isRemoved($0.id) }
    }

    private func synthesizeUserProfile(from entry: UserImageModelEntry) -> LocalModelProfile? {
        guard let base = catalog.models.first(where: { $0.id == entry.baseProfile && $0.kind == "image" }) else {
            return nil
        }
        let weightNote = "自訂本機模型（基底架構：\(base.displayName) · 權重：\(entry.primaryWeight)）"
        let note = entry.notes.isEmpty ? weightNote : "\(weightNote)\n\(entry.notes)"
        return LocalModelProfile(
            id: entry.id,
            displayName: entry.displayName,
            shortName: entry.displayName,
            kind: base.kind,
            architecture: base.architecture,
            precision: base.precision,
            clipType: base.clipType,
            vaeName: entry.secondaryWeights["vae"] ?? base.vaeName,
            alignment: base.alignment,
            maxPixels: base.maxPixels,
            defaults: base.defaults,
            ranges: base.ranges,
            capabilities: base.capabilities,
            nativeSizes: base.nativeSizes,
            nativeSizeNote: base.nativeSizeNote,
            recommendationNote: note,
            sourceSummary: "使用者自訂本機模型 · \(entry.primaryCategory)/\(entry.primaryWeight)",
            officialSources: base.officialSources,
            topLevelUnsupportedNotes: base.topLevelUnsupportedNotes,
            negativePromptDisabledNote: base.negativePromptDisabledNote
        )
    }

    func baseProfileID(for modelID: String, userState: UserModelState = UserModelRegistry.safeLoad()) -> String {
        if let entry = userState.entries.first(where: { $0.id == modelID }) {
            return entry.baseProfile
        }
        return modelID
    }

    func profile(for id: String) -> LocalModelProfile? {
        guard !isRemoved(id) else { return nil }
        let userState = UserModelRegistry.safeLoad()
        if let entry = userState.entries.first(where: { $0.id == id }),
           let custom = synthesizeUserProfile(from: entry) {
            return custom
        }
        return catalog.models.first(where: { $0.id == id })
    }

    func removedNotice(for id: String) -> RemovedModelNotice? {
        catalog.removedModels[id]
    }

    func isRemoved(_ id: String) -> Bool {
        catalog.removedModels[id] != nil || id == "realxl"
    }

    var imageModels: [LocalModelProfile] {
        let userState = UserModelRegistry.safeLoad()
        let hidden = Set(userState.hiddenBuiltInIds)
        let overrides = Dictionary(uniqueKeysWithValues: userState.entries.map { ($0.id, $0) })
        var result: [LocalModelProfile] = []
        for base in builtInImageModels where !hidden.contains(base.id) {
            if let overrideEntry = overrides[base.id], let custom = synthesizeUserProfile(from: overrideEntry) {
                result.append(custom)
            } else {
                result.append(base)
            }
        }
        let builtInIDs = Set(builtInImageModels.map(\.id))
        for entry in userState.entries where !builtInIDs.contains(entry.id) {
            if let custom = synthesizeUserProfile(from: entry) {
                result.append(custom)
            }
        }
        return result
    }

    var videoModels: [LocalModelProfile] {
        catalog.models.filter { $0.kind == "video" && !isRemoved($0.id) }
    }

    var allLoRAs: [LoRAProfile] {
        let imported = (try? ManualLoRARegistry.load()) ?? []
        return catalog.loras + imported.filter { $0.id.hasPrefix("user_") }.map {
            LoRAProfile(id: $0.id, name: $0.displayName, filename: $0.filename,
                        compatibleModels: $0.compatibleModels, defaultStrength: $0.defaultStrength, triggerNote: $0.triggerNote)
        }
    }

    func compatibleLoRAs(for modelID: String) -> [LoRAProfile] {
        guard let profile = profile(for: modelID), profile.supportsLoRA else { return [] }
        let baseID = baseProfileID(for: modelID)
        let allowed = Set(profile.compatibleLoRAs)
        return allLoRAs.filter { lora in
            let matchesModel = lora.compatibleModels.contains(modelID) || lora.compatibleModels.contains(baseID)
            return (lora.id.hasPrefix("user_") || allowed.isEmpty || allowed.contains(lora.id)) && matchesModel
        }
    }

    func loraProfile(for id: String) -> LoRAProfile? {
        allLoRAs.first(where: { $0.id == id })
    }

    func displayName(for modelID: String) -> String {
        if let profile = profile(for: modelID) { return profile.displayName }
        if let removed = removedNotice(for: modelID) { return "\(removed.displayName)（已移除）" }
        if modelID.hasPrefix("workflow_"), let wf = CustomWorkflowRegistry.entry(for: modelID) {
            return "工作流 · \(wf.displayName)"
        }
        switch modelID {
        case "colab": return "線上 · Google Colab"
        case "openai_image": return "線上 · OpenAI（圖片）"
        case "gemini_image": return "線上 · Gemini（圖片）"
        case "comfy": return "自訂 ComfyUI 工作流"
        default: return modelID
        }
    }

    func quickReplacementModels(for notice: RemovedModelNotice) -> [LocalModelProfile] {
        let preferredOrder = ["redcraft", "zimage", "krea2", "moss", "iniverse_flux", "sdxl1"]
        var ordered: [LocalModelProfile] = []
        var seen = Set<String>()
        for id in notice.recommendedReplacements + preferredOrder {
            if let profile = profile(for: id), profile.kind == "image", seen.insert(profile.id).inserted {
                ordered.append(profile)
            }
        }
        for profile in imageModels where seen.insert(profile.id).inserted {
            ordered.append(profile)
        }
        return ordered
    }
}

// MARK: - Local Workflow Export State (No Extra Stored Properties Required on Studio)

@MainActor final class LocalWorkflowExportState: ObservableObject {
    static let shared = LocalWorkflowExportState()

    @Published private var pathsByStudio: [ObjectIdentifier: [String]] = [:]
    @Published var isExporting = false

    func paths(for studio: Studio) -> [String] {
        pathsByStudio[ObjectIdentifier(studio)] ?? []
    }

    func setPaths(_ paths: [String], for studio: Studio) {
        pathsByStudio[ObjectIdentifier(studio)] = paths
        studio.objectWillChange.send()
    }
}

// MARK: - Extended Recorded Generation Inspector Data

struct RecordedGenerationDetail: Equatable, Sendable {
    let assetPath: String
    let jobFolder: URL
    let action: String
    let kind: String
    let originalPrompt: String?
    let submittedPrompt: String
    let seed: Int
    let aspect: String
    let nativeWidth: Int?
    let nativeHeight: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let model: String
    let resolution: String
    let seconds: Int
    let lora: String?
    let reference: String?
    let referenceVideo: String?
    let referenceImages: [String]
    let workflow: String?
    let localOnly: Bool
    let videoMethod: String?
    let modelParams: [String: String]
    let savedOverrides: LocalModelOverrides?
    let savedWorkflowFiles: [String]

    var isRemovedModel: Bool {
        ModelProfileStore.shared.isRemoved(action)
    }

    var removedNotice: RemovedModelNotice? {
        ModelProfileStore.shared.removedNotice(for: action)
    }

    var sizeSummary: String {
        if let nw = nativeWidth, let nh = nativeHeight {
            if let pw = pixelWidth, let ph = pixelHeight, (pw != nw || ph != nh) {
                return "原生 \(nw)×\(nh) → 輸出 \(pw)×\(ph)（\(aspect)）"
            }
            return "\(nw)×\(nh)（\(aspect)）"
        }
        if let pw = pixelWidth, let ph = pixelHeight {
            return "\(pw)×\(ph)（\(aspect)）"
        }
        if let profile = ModelProfileStore.shared.profile(for: action),
           let pair = profile.nativeSizes[aspect], pair.count >= 2 {
            return "預設 \(pair[0])×\(pair[1])（\(aspect)）"
        }
        return aspect
    }

    var sourceLabel: String {
        if action == "colab" { return "線上 · Google Colab" }
        return "本機 ComfyUI · \(ModelProfileStore.shared.displayName(for: action))"
    }

    static var defaultJobsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klipora/Jobs", isDirectory: true)
    }

    static func read(asset: String, jobs: URL = defaultJobsDirectory) -> RecordedGenerationDetail? {
        guard !asset.isEmpty else { return nil }
        let media = URL(fileURLWithPath: asset).standardizedFileURL
        let jobsRoot = jobs.standardizedFileURL
        let containingFolder = media.deletingLastPathComponent()
        let original = containingFolder.lastPathComponent == "out"
            ? containingFolder.deletingLastPathComponent() : containingFolder
        let stem = media.deletingPathExtension().lastPathComponent
        let identifier = String(stem.suffix(36))
        let isPublished = (
            stem.hasPrefix("Klipora-Image-") || stem.hasPrefix("Klipora-Video-")
            || stem.hasPrefix("MotionDesk-Image-") || stem.hasPrefix("MotionDesk-Video-")
        )
            && UUID(uuidString: identifier) != nil
        let day = containingFolder.lastPathComponent
        let isDateFolder = day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        let datedJobs = jobsRoot.appendingPathComponent(day, isDirectory: true)
        let folders = isPublished
            ? (isDateFolder ? [datedJobs.appendingPathComponent(".\(identifier)"),
                               datedJobs.appendingPathComponent(identifier)] : [])
                + [jobsRoot.appendingPathComponent(identifier)]
            : [original]

        for folder in folders {
            if let detail = read(media: media, folder: folder, jobs: jobsRoot) {
                return detail
            }
        }
        return nil
    }

    private static func read(media: URL, folder: URL, jobs: URL) -> RecordedGenerationDetail? {
        let parent = folder.deletingLastPathComponent()
        let isDatedJob = parent.deletingLastPathComponent().path == jobs.path
            && parent.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        let name = folder.lastPathComponent
        let identifier = name.hasPrefix(".") ? String(name.dropFirst()) : name
        guard (parent.path == jobs.path || isDatedJob),
              UUID(uuidString: identifier) != nil,
              let resultData = try? Data(contentsOf: folder.appendingPathComponent("result.json")),
              let resultObj = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any],
              let paths = resultObj["paths"] as? [String],
              (paths + (resultObj["originalPaths"] as? [String] ?? [])).contains(where: {
                  URL(fileURLWithPath: $0).standardizedFileURL.path == media.path
              }),
              let reqData = try? Data(contentsOf: folder.appendingPathComponent("request.json")),
              let reqObj = (try? JSONSerialization.jsonObject(with: reqData)) as? [String: Any],
              let kind = reqObj["kind"] as? String, ["image", "video"].contains(kind),
              let action = reqObj["action"] as? String else {
            return nil
        }

        let submittedPrompt = (resultObj["submittedPrompt"] as? String)
            ?? (resultObj["finalPrompt"] as? String)
            ?? (reqObj["prompt"] as? String)
            ?? ""
        let rawOriginal = (resultObj["originalPrompt"] as? String)
            ?? (reqObj["originalPrompt"] as? String)
            ?? (reqObj["rawPrompt"] as? String)
        let originalPrompt = (rawOriginal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? rawOriginal : nil

        let seed = (resultObj["seed"] as? Int) ?? (reqObj["seed"] as? Int) ?? 0
        let aspect = (resultObj["generationAspect"] as? String) ?? (reqObj["aspect"] as? String) ?? "16:9"
        let model = (reqObj["model"] as? String) ?? "upd5"
        let resolution = (reqObj["resolution"] as? String) ?? "480P"
        let seconds = (reqObj["seconds"] as? Int) ?? 5
        let lora = reqObj["lora"] as? String
        let reference = reqObj["reference"] as? String
        let referenceVideo = reqObj["referenceVideo"] as? String
        let referenceImages = reqObj["referenceImages"] as? [String] ?? []
        let workflow = reqObj["workflow"] as? String
        let localOnly = (reqObj["localOnly"] as? Bool) ?? false
        let videoMethod = reqObj["videoMethod"] as? String

        let pixelDict = reqObj["pixelSize"] as? [String: Any]
        let pixelW = pixelDict?["width"] as? Int
        let pixelH = pixelDict?["height"] as? Int

        let (nativeW, nativeH) = extractSize(from: resultObj["nativeSize"] ?? resultObj["nativePixelSize"] ?? reqObj["nativeSize"])

        let rawParams = (resultObj["modelParams"] as? [String: Any])
            ?? (resultObj["effectiveParams"] as? [String: Any])
            ?? (reqObj["modelParams"] as? [String: Any])
            ?? [:]
        var formattedParams: [String: String] = [:]
        for (k, v) in rawParams {
            if let num = v as? Double {
                if abs(num.rounded() - num) < 0.0001 && k == "steps" {
                    formattedParams[k] = String(Int(num))
                } else {
                    formattedParams[k] = String(format: "%.2f", num).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
                }
            } else if let str = v as? String, !str.isEmpty {
                formattedParams[k] = str
            }
        }

        let overrides = decodeOverrides(from: rawParams)
        let workflowFiles = discoverSavedWorkflowFiles(resultObj: resultObj, folder: folder, media: media)

        return RecordedGenerationDetail(
            assetPath: media.path,
            jobFolder: folder,
            action: action,
            kind: kind,
            originalPrompt: originalPrompt,
            submittedPrompt: submittedPrompt,
            seed: seed,
            aspect: aspect,
            nativeWidth: nativeW,
            nativeHeight: nativeH,
            pixelWidth: pixelW,
            pixelHeight: pixelH,
            model: model,
            resolution: resolution,
            seconds: seconds,
            lora: lora,
            reference: reference,
            referenceVideo: referenceVideo,
            referenceImages: referenceImages,
            workflow: workflow,
            localOnly: localOnly,
            videoMethod: videoMethod,
            modelParams: formattedParams,
            savedOverrides: overrides,
            savedWorkflowFiles: workflowFiles
        )
    }

    private static func extractSize(from value: Any?) -> (Int?, Int?) {
        if let dict = value as? [String: Any],
           let w = dict["width"] as? Int,
           let h = dict["height"] as? Int {
            return (w, h)
        }
        if let arr = value as? [Int], arr.count >= 2 {
            return (arr[0], arr[1])
        }
        return (nil, nil)
    }

    private static func decodeOverrides(from dict: [String: Any]) -> LocalModelOverrides? {
        guard !dict.isEmpty else { return nil }
        var overrides = LocalModelOverrides()
        if let s = dict["steps"] as? Int { overrides.steps = s }
        if let c = dict["cfg"] as? Double { overrides.cfg = c }
        else if let c = dict["cfg"] as? Int { overrides.cfg = Double(c) }
        if let sp = (dict["sampler"] as? String) ?? (dict["sampler_name"] as? String) { overrides.sampler = sp }
        if let sc = dict["scheduler"] as? String { overrides.scheduler = sc }
        if let sh = dict["shift"] as? Double { overrides.shift = sh }
        else if let sh = dict["shift"] as? Int { overrides.shift = Double(sh) }
        if let g = dict["guidance"] as? Double { overrides.guidance = g }
        else if let g = dict["guidance"] as? Int { overrides.guidance = Double(g) }
        if let neg = (dict["negativePrompt"] as? String) ?? (dict["negative_prompt"] as? String) {
            overrides.negativePrompt = neg
        }
        if let d = dict["denoise"] as? Double { overrides.denoise = d }
        return overrides.isEmpty ? nil : overrides
    }

    private static func discoverSavedWorkflowFiles(resultObj: [String: Any], folder: URL, media: URL) -> [String] {
        var candidates: [String] = []
        let keys = ["workflowApiPath", "workflowCanvasPath", "apiWorkflowPath", "canvasWorkflowPath", "apiPath", "workflowPath", "canvasPath"]
        for key in keys {
            if let path = resultObj[key] as? String, !path.isEmpty {
                candidates.append(path)
            }
        }
        if let array = resultObj["workflowFiles"] as? [String] {
            candidates.append(contentsOf: array)
        }
        if let dict = resultObj["workflows"] as? [String: Any] {
            for val in dict.values {
                if let path = val as? String, !path.isEmpty {
                    candidates.append(path)
                }
            }
        }
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for url in entries {
                let lower = url.lastPathComponent.lowercased()
                if lower.hasSuffix(".api.json") || lower.hasSuffix(".workflow.json") || lower.hasSuffix(".canvas.json") {
                    candidates.append(url.path)
                }
            }
        }
        let stem = media.deletingPathExtension().path
        for ext in [".api.json", ".workflow.json"] {
            let sibling = stem + ext
            if fm.fileExists(atPath: sibling) {
                candidates.append(sibling)
            }
        }
        var seen = Set<String>()
        return candidates.filter { path in
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            return fm.fileExists(atPath: std) && seen.insert(std).inserted
        }.sorted()
    }
}

// MARK: - Studio Extension: Local Model Profiles, Capability Guardrails & Same-Source Workflow Export

extension Studio {
    var profileStore: ModelProfileStore {
        ModelProfileStore.shared
    }

    var activeLocalProfile: LocalModelProfile? {
        guard source != "colab", action != "comfy" else { return nil }
        return profileStore.profile(for: localModel)
    }

    var removedModelNotice: RemovedModelNotice? {
        guard source != "colab" else { return nil }
        return profileStore.removedNotice(for: localModel)
    }

    var isRemovedModelSelected: Bool {
        removedModelNotice != nil
    }

    var localModelSupportsReference: Bool {
        if source == "colab" || action == "comfy" { return true }
        if isRemovedModelSelected { return false }
        guard let profile = activeLocalProfile else { return false }
        return project.kind == "video" ? profile.supportsVideoFirstFrame : profile.supportsImg2Img
    }

    var localModelSupportsLoRA: Bool {
        if source == "colab" || action == "comfy" { return false }
        guard project.kind == "image", let profile = activeLocalProfile else { return false }
        return profile.supportsLoRA && !profileStore.compatibleLoRAs(for: profile.id).isEmpty
    }

    var unsupportedLocalReferencePath: String {
        guard source != "colab", project.kind == "image", action != "comfy" else { return "" }
        guard let profile = activeLocalProfile, !profile.supportsImg2Img else { return "" }
        return (project.imageReference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var unsupportedLocalLoRAInfo: (id: String, label: String)? {
        guard source != "colab", project.kind == "image", action != "comfy" else { return nil }
        guard let profile = activeLocalProfile else { return nil }
        let rawLoRA = (project.localImageLoRA ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLoRA.isEmpty else { return nil }
        let compatible = profileStore.compatibleLoRAs(for: profile.id).contains(where: { $0.id == rawLoRA })
        guard !compatible else { return nil }
        let label = profileStore.loraProfile(for: rawLoRA)?.name ?? rawLoRA
        return (rawLoRA, label)
    }

    var hasUnsupportedLocalCapabilityIssue: String? {
        guard source != "colab" else { return nil }
        if let notice = removedModelNotice {
            return notice.message
        }
        guard action != "comfy", let profile = activeLocalProfile else { return nil }

        var issues: [String] = []
        if !unsupportedLocalReferencePath.isEmpty {
            issues.append("\(profile.displayName) 目前僅支援文字生圖，不支援參考圖片，請先移除參考圖片或切換其他模型。")
        }
        if let badLoRA = unsupportedLocalLoRAInfo {
            issues.append("\(profile.displayName) 不支援風格 LoRA（\(badLoRA.label)），請先清除 LoRA 或改選其指定的基底模型。")
        }
        if project.kind == "video", ["frames", "multi"].contains(project.videoMethod ?? "") {
            issues.append("\(profile.displayName) 僅支援文字生片或單一首幀參考，不支援首尾／多影格模式。")
        }
        return issues.isEmpty ? nil : issues.joined(separator: " ")
    }

    func overrides(for modelID: String) -> LocalModelOverrides {
        project.localModelOverrides?[modelID] ?? LocalModelOverrides()
    }

    func hasCustomOverrides(for modelID: String) -> Bool {
        let current = overrides(for: modelID)
        guard let profile = profileStore.profile(for: modelID) else {
            return !current.isEmpty
        }
        return !current.normalized(against: profile).isEmpty
    }

    func updateOverride(for modelID: String, _ mutate: (inout LocalModelOverrides) -> Void) {
        guard !busy else { return }
        var map = project.localModelOverrides ?? [:]
        var entry = map[modelID] ?? LocalModelOverrides()
        mutate(&entry)
        if let profile = profileStore.profile(for: modelID) {
            entry = entry.normalized(against: profile)
        }
        if entry.isEmpty {
            map.removeValue(forKey: modelID)
        } else {
            map[modelID] = entry
        }
        project.localModelOverrides = map.isEmpty ? nil : map
    }

    func resetOverrides(for modelID: String) {
        guard !busy else { return }
        guard var map = project.localModelOverrides else { return }
        map.removeValue(forKey: modelID)
        project.localModelOverrides = map.isEmpty ? nil : map
        let name = profileStore.displayName(for: modelID)
        status = "已恢復 \(name) 原生預設參數"
    }

    func effectiveModelParamsPayload(for modelID: String) -> [String: Any] {
        guard let profile = profileStore.profile(for: modelID) else { return [:] }
        let ov = overrides(for: modelID).normalized(against: profile)
        var payload: [String: Any] = [
            "steps": profile.ranges.steps.clamped(ov.steps ?? profile.defaults.steps),
            "cfg": profile.ranges.cfg.clamped(ov.cfg ?? profile.defaults.cfg),
            "sampler": ov.sampler ?? profile.defaults.sampler,
            "scheduler": ov.scheduler ?? profile.defaults.scheduler
        ]
        if profile.supportsShift, let shiftVal = ov.shift ?? profile.defaults.shift {
            payload["shift"] = profile.ranges.shift?.clamped(shiftVal) ?? ((shiftVal * 100).rounded() / 100)
        }
        if profile.supportsGuidance, let guidanceVal = ov.guidance ?? profile.defaults.guidance {
            payload["guidance"] = profile.ranges.guidance?.clamped(guidanceVal) ?? ((guidanceVal * 100).rounded() / 100)
        }
        if profile.supportsNegativePrompt {
            payload["negativePrompt"] = ov.negativePrompt ?? profile.defaults.negativePrompt ?? ""
        }
        if profile.supportsImg2Img && profile.kind == "image" {
            let denoiseVal = ov.denoise ?? profile.defaults.effectiveImg2ImgDenoise
            payload["denoise"] = profile.ranges.denoise?.clamped(denoiseVal) ?? ((min(1.0, max(0.1, denoiseVal)) * 100).rounded() / 100)
        }
        if modelID == localModel, let id = project.localImageLoRA, !id.isEmpty,
           profileStore.compatibleLoRAs(for: modelID).contains(where: { $0.id == id }),
           let strength = project.localLoRAStrength, strength.isFinite {
            payload["loraStrength"] = min(2, max(0, strength))
        }
        return payload
    }

    func currentModelParamsPayload() -> [String: Any] {
        guard source != "colab", action != "comfy", !isRemovedModelSelected else { return [:] }
        return effectiveModelParamsPayload(for: localModel)
    }

    var lastExportedWorkflowPaths: [String] {
        get { LocalWorkflowExportState.shared.paths(for: self) }
        set { LocalWorkflowExportState.shared.setPaths(newValue, for: self) }
    }

    func clearUnsupportedLocalCapabilities() {
        guard !busy else { return }
        var cleared: [String] = []
        if !unsupportedLocalReferencePath.isEmpty {
            project.imageReference = ""
            cleared.append("參考圖片")
        }
        if unsupportedLocalLoRAInfo != nil {
            project.localImageLoRA = ""
            cleared.append("風格 LoRA")
        }
        if !cleared.isEmpty {
            status = "已清除不支援項目：\(cleared.joined(separator: "、"))"
        }
    }

    func replaceRemovedModel(with newModelID: String) {
        guard !busy, let profile = profileStore.profile(for: newModelID), profile.kind == "image" else { return }
        project.source = "zimage"
        project.kind = "image"
        project.localImageModel = profile.id
        status = "已改選本機 ComfyUI 模型：\(profile.displayName)"
    }

    func openComfyWebUI() {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host) else {
            status = "本機 ComfyUI 位址無效，請填入如 http://127.0.0.1:8188。"
            return
        }
        if NSWorkspace.shared.open(url) {
            status = "已開啟本機 ComfyUI 網頁 · \(trimmed)"
        } else {
            status = "無法開啟瀏覽器前往 \(trimmed)。"
        }
    }

    func revealExportedWorkflowFiles(_ explicitPaths: [String]? = nil) {
        let paths = (explicitPaths ?? lastExportedWorkflowPaths).filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !paths.isEmpty else {
            status = "找不到已匯出的工作流檔案。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    func buildExportWorkflowRequest(destinationDirectory: URL, baseName: String) -> [String: Any] {
        let seedText = (project.fixedSeed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = UInt32(seedText) ?? UInt32.random(in: 1...2147483646)
        let ref = localModelSupportsReference ? referenceImage.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let refVideo = (project.kind == "video" && ["wan22", "wan22_14b", "ltxv13b"].contains(localModel)) ? (project.referenceVideo ?? "") : ""
        let cleanBase = baseName.isEmpty ? "\(localModel)-workflow" : baseName
        let apiURL = destinationDirectory.appendingPathComponent("\(cleanBase).api.json")
        let workflowURL = destinationDirectory.appendingPathComponent("\(cleanBase).workflow.json")

        var req: [String: Any] = [
            "action": "export_workflow",
            "preset": localModel,
            "endpoint": endpoint,
            "workflow": selectedWorkflow,
            "kind": project.kind,
            "prompt": referencePrompt,
            "originalPrompt": project.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "aspect": project.aspect,
            "seconds": generationSeconds,
            "seed": Int(seed),
            "lora": localModelSupportsLoRA ? (project.localImageLoRA ?? "") : "",
            "reference": ref,
            "referenceVideo": refVideo,
            "localOnly": project.localOnly == true,
            "modelParams": effectiveModelParamsPayload(for: localModel),
            "destinationDir": destinationDirectory.path,
            "outputDir": destinationDirectory.path,
            "baseName": cleanBase,
            "destination": destinationDirectory.appendingPathComponent(cleanBase).path,
            "apiPath": apiURL.path,
            "workflowPath": workflowURL.path
        ]
        if let size = outputDimensions?.pixels {
            req["pixelSize"] = size
        }
        return req
    }

    func exportCurrentWorkflow() {
        exportCurrentWorkflowFiles()
    }

    func exportCurrentWorkflowFiles() {
        guard !busy, !LocalWorkflowExportState.shared.isExporting else { return }
        guard source != "colab" else {
            status = "請切換至本機 ComfyUI 模式後再匯出工作流。"
            return
        }
        if let notice = removedModelNotice {
            status = notice.message
            return
        }
        if let issue = hasUnsupportedLocalCapabilityIssue {
            status = issue
            return
        }
        if action == "comfy" && selectedWorkflow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "請先選擇自訂 ComfyUI API 工作流。"
            return
        }

        let modelName = localModel
        let dayDir = datedDirectory(under: generationOutputDirectory)
        let preparedDir = prepareOutputDirectory(dayDir) ? dayDir : nil
        presentSavePanel(configure: { dialog in
            dialog.title = "匯出本機 ComfyUI 同源工作流"
            dialog.message = "將以目前模型與實際參數同時匯出 <名稱>.api.json（API 執行圖）與 <名稱>.workflow.json（ComfyUI 畫布工作流）。"
            dialog.prompt = "匯出工作流"
            dialog.canCreateDirectories = true
            dialog.nameFieldStringValue = "\(modelName)-workflow"
            if let preparedDir {
                dialog.directoryURL = preparedDir
            }
        }) { [weak self] selectedURL in
            guard let self, !self.busy else { return }
            var rawName = selectedURL.lastPathComponent
            for suffix in [".workflow.json", ".api.json", ".canvas.json", ".json"] {
                if rawName.lowercased().hasSuffix(suffix) {
                    rawName = String(rawName.dropLast(suffix.count))
                    break
                }
            }
            let baseName = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(modelName)-workflow" : rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let destDir = selectedURL.deletingLastPathComponent()
            guard self.prepareOutputDirectory(destDir) else { return }

            let request = self.buildExportWorkflowRequest(destinationDirectory: destDir, baseName: baseName)
            self.runExportWorkflowWorker(request: request)
        }
    }

    private func runExportWorkflowWorker(request: [String: Any]) {
        guard let script = Bundle.main.url(forResource: "worker", withExtension: "py") else {
            status = "找不到本機 ComfyUI 工作流匯出腳本（worker.py）。"
            return
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("MotionDesk-WorkflowExport-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let inputURL = workDir.appendingPathComponent("request.json")
            let outputURL = workDir.appendingPathComponent("result.json")
            let logURL = workDir.appendingPathComponent("activity.log")
            let reqData = try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted])
            try reqData.write(to: inputURL, options: .atomic)
            _ = fm.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", script.path, inputURL.path, outputURL.path]
            process.standardOutput = logHandle
            process.standardError = logHandle

            LocalWorkflowExportState.shared.isExporting = true
            busy = true
            status = "正在匯出本機 ComfyUI 同源工作流…"

            process.terminationHandler = { [weak self] proc in
                try? logHandle.close()
                let code = proc.terminationStatus
                Task { @MainActor in
                    guard let self else { return }
                    LocalWorkflowExportState.shared.isExporting = false
                    self.busy = false
                    if let text = try? String(contentsOf: logURL, encoding: .utf8), !text.isEmpty {
                        self.log = String(text.suffix(16000))
                    }
                    defer { try? FileManager.default.removeItem(at: workDir) }
                    guard let data = try? Data(contentsOf: outputURL),
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        self.status = "匯出工作流未完成（代碼 \(code)）。請查看工作紀錄。"
                        return
                    }
                    if let err = obj["error"] as? String {
                        self.status = err
                        return
                    }
                    var exported: [String] = []
                    if let paths = obj["paths"] as? [String] { exported.append(contentsOf: paths) }
                    for key in ["apiPath", "workflowPath", "canvasPath", "workflowApiPath", "workflowCanvasPath"] {
                        if let p = obj[key] as? String, !p.isEmpty { exported.append(p) }
                    }
                    var seen = Set<String>()
                    let validPaths = exported.filter {
                        FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted
                    }
                    self.lastExportedWorkflowPaths = validPaths
                    if validPaths.isEmpty {
                        self.status = "本機 ComfyUI 工作流匯出完成，但未回傳檔案路徑。"
                    } else {
                        let names = validPaths.map(filename).joined(separator: "、")
                        self.status = "已匯出本機 ComfyUI 工作流 · \(names)"
                    }
                }
            }
            try process.run()
        } catch {
            LocalWorkflowExportState.shared.isExporting = false
            busy = false
            status = "匯出本機 ComfyUI 工作流失敗：\(error.localizedDescription)"
        }
    }

    func recordedGenerationDetail(for path: String) -> RecordedGenerationDetail? {
        RecordedGenerationDetail.read(asset: path)
    }

    func restoreGenerationDetail(_ detail: RecordedGenerationDetail, replacingRemovedModelWith replacementModelID: String? = nil) {
        guard !busy else { return }
        if detail.isRemovedModel {
            guard let replacementModelID, let targetProfile = profileStore.profile(for: replacementModelID) else {
                status = detail.removedNotice?.message ?? "模型 RealXL 已移除，請改選其他本機圖片模型（不會靜默替換生成）。"
                return
            }
            project.source = "zimage"
            project.kind = "image"
            project.localImageModel = targetProfile.id
            project.aspect = detail.aspect
            if let pw = detail.pixelWidth, let ph = detail.pixelHeight {
                outputDimensions = OutputDimensions(width: String(pw), height: String(ph))
            } else if let nw = detail.nativeWidth, let nh = detail.nativeHeight {
                outputDimensions = OutputDimensions(width: String(nw), height: String(nh))
            } else {
                outputDimensions = nil
            }
            project.fixedSeed = String(detail.seed)
            project.prompt = detail.originalPrompt ?? detail.submittedPrompt
            project.optimize = false
            editedPrompt = nil
            workspace = .generate
            status = "已改用 \(targetProfile.displayName) 載入原提示詞與 Seed \(detail.seed)"
            return
        }

        if let recorded = recordedGeneration(for: detail.assetPath) {
            restoreGeneration(recorded)
            if let saved = detail.savedOverrides, detail.action != "colab", detail.action != "comfy" {
                updateOverride(for: detail.action) { $0 = saved }
            }
        }
    }
}

// MARK: - RemovedModelBanner

struct RemovedModelBanner: View {
    @ObservedObject var app: Studio

    private let buttonColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        if let notice = app.removedModelNotice {
            let replacements = app.profileStore.quickReplacementModels(for: notice)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.32))
                    Text(notice.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.45))
                    Spacer(minLength: 0)
                    Text(notice.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(canvas, in: Capsule())
                }

                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)

                Text("請直接點選下方任一本機 ComfyUI 圖片模型以繼續生成：")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: buttonColumns, alignment: .leading, spacing: 6) {
                    ForEach(replacements) { profile in
                        Button {
                            app.replaceRemovedModel(with: profile.id)
                        } label: {
                            Text(profile.shortName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(studioAccent)
                        .disabled(app.busy)
                    }
                }
            }
            .padding(10)
            .background(Color(red: 0.22, green: 0.11, blue: 0.09), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(red: 1.0, green: 0.42, blue: 0.24).opacity(0.75), lineWidth: 1.2)
            )
        }
    }
}

// MARK: - LocalModelProfilePanel

@MainActor private final class LocalModelProfilePanelUIState: ObservableObject {
    @Published var isExpanded = false
    @Published var showHistoryPopover = false
}

struct LocalModelProfilePanel: View {
    @ObservedObject var app: Studio
    @ObservedObject private var exportState = LocalWorkflowExportState.shared
    @StateObject private var ui = LocalModelProfilePanelUIState()

    var body: some View {
        if app.source != "colab" {
            if let profile = app.activeLocalProfile {
                profileCard(profile)
            } else if app.action == "comfy" {
                customComfyBar
            }
        }
    }

    private var customComfyBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("本機 ComfyUI 自訂工作流", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    app.openComfyWebUI()
                } label: {
                    Label("開啟本機 ComfyUI 頁面", systemImage: "safari")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(9)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func profileCard(_ profile: LocalModelProfile) -> some View {
        let currentOverrides = app.overrides(for: profile.id)
        let isCustomized = app.hasCustomOverrides(for: profile.id)
        let exportedPaths = exportState.paths(for: app)
        let selectedDetail = app.selection.isEmpty ? nil : app.recordedGenerationDetail(for: app.selection)
        let historyWorkflowPaths = selectedDetail?.savedWorkflowFiles ?? []
        let revealablePaths = !exportedPaths.isEmpty ? exportedPaths : historyWorkflowPaths

        return VStack(alignment: .leading, spacing: 8) {
            // Compact Header & Summary Strip
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            ui.isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: ui.isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 10)
                            Text("本機 ComfyUI 參數")
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)

                    if isCustomized {
                        Text("已自訂")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(canvas)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(studioAccent, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    if isCustomized {
                        Button("恢復模型預設") {
                            app.resetOverrides(for: profile.id)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                        .disabled(app.busy)
                    }
                }

                Text(profile.effectiveSummaryLine(with: currentOverrides))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Active Capability Conflict Warning (always visible so nothing is silently ignored)
            if !app.unsupportedLocalReferencePath.isEmpty || app.unsupportedLocalLoRAInfo != nil {
                activeUnsupportedBanner(for: profile)
            }

            // Always-visible Img2Img Denoise control with live effect explanation when a reference image is attached
            if profile.supportsImg2Img, profile.kind == "image",
               !app.referenceImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                denoiseControlCard(for: profile, overrides: currentOverrides)
            }

            // Expanded Model Details & Controls
            if ui.isExpanded {
                Divider().opacity(0.5)
                expandedControls(for: profile, overrides: currentOverrides, isCustomized: isCustomized)
            }

            Divider().opacity(0.4)

            // Same-Source ComfyUI Workflow Action Bar
            workflowActionBar(
                revealablePaths: revealablePaths,
                isFromExport: !exportedPaths.isEmpty,
                selectedDetail: selectedDetail
            )
        }
        .padding(9)
        .background(surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    app.hasUnsupportedLocalCapabilityIssue != nil
                        ? Color.orange.opacity(0.55)
                        : .white.opacity(0.06)
                )
        )
    }

    private func activeUnsupportedBanner(for profile: LocalModelProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("偵測到不支援項目（不會靜默忽略）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if !app.unsupportedLocalReferencePath.isEmpty {
                HStack(spacing: 6) {
                    Text("\(profile.shortName) 不支援參考圖片：\(filename(app.unsupportedLocalReferencePath))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("移除參考圖") {
                        app.project.imageReference = ""
                    }
                    .controlSize(.mini)
                    .disabled(app.busy)
                }
            }

            if let badLoRA = app.unsupportedLocalLoRAInfo {
                HStack(spacing: 6) {
                    Text("\(profile.shortName) 不支援 LoRA（\(badLoRA.label)）")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("清除 LoRA") {
                        app.project.localImageLoRA = ""
                    }
                    .controlSize(.mini)
                    .disabled(app.busy)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.4)))
    }

    private func denoiseEffectDescription(for value: Double) -> String {
        switch value {
        case ..<0.46:
            return "極低重繪：幾乎完全鎖定原圖姿勢、臉部與服裝，僅微調質感與光影。"
        case ..<0.61:
            return "輕度重繪：保留原圖臉部與動作，適合小幅修飾（大改動作／換裝反應較弱）。"
        case ..<0.76:
            return "中度重繪：能明顯更換服裝與背景，同時盡量維持原本構圖與人物輪廓。"
        default:
            return "大幅重繪：可大幅改變動作、穿搭與場景，但數值越高越容易改變原圖臉部特徵。"
        }
    }

    private func denoiseControlCard(for profile: LocalModelProfile, overrides: LocalModelOverrides) -> some View {
        let denoiseRange = profile.ranges.denoise ?? DoubleRangeSpec(min: 0.2, max: 0.95, step: 0.05)
        let effectiveDenoise = denoiseRange.clamped(overrides.denoise ?? profile.defaults.effectiveImg2ImgDenoise)
        let binding = Binding<Double>(
            get: { effectiveDenoise },
            set: { newVal in
                let snapped = (newVal / denoiseRange.step).rounded() * denoiseRange.step
                app.updateOverride(for: profile.id) { $0.denoise = denoiseRange.clamped(snapped) }
            }
        )
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("參考圖重繪強度 (Denoise)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f", effectiveDenoise))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(studioAccent)
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper("", value: binding, in: denoiseRange.min...denoiseRange.max, step: denoiseRange.step)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            Slider(value: binding, in: denoiseRange.min...denoiseRange.max, step: denoiseRange.step)
                .controlSize(.mini)
                .tint(studioAccent)
            Text(denoiseEffectDescription(for: effectiveDenoise))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
            Text("數值越低越貼近原圖；數值越高改動越大（換裝建議 0.65–0.75）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder
    private func expandedControls(
        for profile: LocalModelProfile,
        overrides: LocalModelOverrides,
        isCustomized: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            // Recommendation & Native Size Card
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.architecture)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(studioAccent)
                    .fixedSize(horizontal: false, vertical: true)
                if !profile.clipType.isEmpty {
                    Text("Encoder: \(profile.clipType)" + (profile.vaeName.isEmpty ? "" : " · VAE: \(profile.vaeName)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !profile.recommendationNote.isEmpty {
                    Text(profile.recommendationNote)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !profile.sourceSummary.isEmpty {
                    Text("來源：\(profile.sourceSummary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("原生尺寸：\(profile.nativeSizeDescription(for: app.project.aspect)) · \(profile.nativeSizeNote)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(7)
            .background(canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))

            // Steps
            let effectiveSteps = profile.ranges.steps.clamped(overrides.steps ?? profile.defaults.steps)
            HStack {
                Text("步數 (Steps)").font(.caption)
                Spacer()
                Text("\(effectiveSteps)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(minWidth: 28, alignment: .trailing)
                Stepper(
                    "",
                    value: Binding(
                        get: { effectiveSteps },
                        set: { newVal in
                            app.updateOverride(for: profile.id) { $0.steps = newVal }
                        }
                    ),
                    in: profile.ranges.steps.min...profile.ranges.steps.max,
                    step: profile.ranges.steps.step
                )
                .labelsHidden()
                .controlSize(.small)
            }

            // CFG
            let effectiveCfg = profile.ranges.cfg.clamped(overrides.cfg ?? profile.defaults.cfg)
            HStack {
                Text("CFG").font(.caption)
                Spacer()
                Text(String(format: "%.1f", effectiveCfg))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(minWidth: 32, alignment: .trailing)
                Stepper(
                    "",
                    value: Binding(
                        get: { effectiveCfg },
                        set: { newVal in
                            app.updateOverride(for: profile.id) { $0.cfg = newVal }
                        }
                    ),
                    in: profile.ranges.cfg.min...profile.ranges.cfg.max,
                    step: profile.ranges.cfg.step
                )
                .labelsHidden()
                .controlSize(.small)
            }

            // Sampler
            let effectiveSampler = overrides.sampler ?? profile.defaults.sampler
            let samplerOptions = profile.ranges.samplers.contains(effectiveSampler)
                ? profile.ranges.samplers
                : [effectiveSampler] + profile.ranges.samplers
            HStack {
                Text("Sampler").font(.caption)
                Spacer(minLength: 8)
                Picker("Sampler", selection: Binding(
                    get: { effectiveSampler },
                    set: { newVal in
                        app.updateOverride(for: profile.id) { $0.sampler = newVal }
                    }
                )) {
                    ForEach(samplerOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 168)
            }

            if profile.id == "wan22" && effectiveSampler == "uni_pc" {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text("實驗性 Sampler：uni_pc 在 Apple Silicon MPS 上可能出現條紋偽影，正式輸出建議維持 euler。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Scheduler
            let effectiveScheduler = overrides.scheduler ?? profile.defaults.scheduler
            let schedulerOptions = profile.ranges.schedulers.contains(effectiveScheduler)
                ? profile.ranges.schedulers
                : [effectiveScheduler] + profile.ranges.schedulers
            HStack {
                Text("Scheduler").font(.caption)
                Spacer(minLength: 8)
                Picker("Scheduler", selection: Binding(
                    get: { effectiveScheduler },
                    set: { newVal in
                        app.updateOverride(for: profile.id) { $0.scheduler = newVal }
                    }
                )) {
                    ForEach(schedulerOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 168)
            }

            // Shift (only when model supports shift)
            if profile.supportsShift {
                let shiftRange = profile.ranges.shift ?? DoubleRangeSpec(min: 1.0, max: 8.0, step: 0.5)
                let effectiveShift = shiftRange.clamped(overrides.shift ?? profile.defaults.shift ?? 3.0)
                HStack {
                    Text("Shift").font(.caption)
                    Spacer()
                    Text(String(format: "%.1f", effectiveShift))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .frame(minWidth: 32, alignment: .trailing)
                    Stepper(
                        "",
                        value: Binding(
                            get: { effectiveShift },
                            set: { newVal in
                                app.updateOverride(for: profile.id) { $0.shift = newVal }
                            }
                        ),
                        in: shiftRange.min...shiftRange.max,
                        step: shiftRange.step
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Flux Guidance (only when model supports guidance)
            if profile.supportsGuidance {
                let guidanceRange = profile.ranges.guidance ?? DoubleRangeSpec(min: 1.5, max: 5.0, step: 0.5)
                let effectiveGuidance = guidanceRange.clamped(overrides.guidance ?? profile.defaults.guidance ?? 3.5)
                HStack {
                    Text("Flux Guidance").font(.caption)
                    Spacer()
                    Text(String(format: "%.1f", effectiveGuidance))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .frame(minWidth: 32, alignment: .trailing)
                    Stepper(
                        "",
                        value: Binding(
                            get: { effectiveGuidance },
                            set: { newVal in
                                app.updateOverride(for: profile.id) { $0.guidance = newVal }
                            }
                        ),
                        in: guidanceRange.min...guidanceRange.max,
                        step: guidanceRange.step
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Negative Prompt
            if profile.supportsNegativePrompt {
                VStack(alignment: .leading, spacing: 4) {
                    Text("負向提示詞").font(.caption)
                    TextField(
                        "輸入不想出現的元素",
                        text: Binding(
                            get: { overrides.negativePrompt ?? profile.defaults.negativePrompt ?? "" },
                            set: { newVal in
                                app.updateOverride(for: profile.id) { $0.negativePrompt = newVal }
                            }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                }
            } else {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text(profile.negativePromptDisabledNote ?? "此蒸餾模型使用 ConditioningZeroOut，無需負向詞。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Unsupported Capabilities Explicit Notice
            if !profile.unsupportedNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("能力與限制說明")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(profile.unsupportedNotes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 5) {
                            Text("•").font(.caption2).foregroundStyle(.secondary)
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(7)
                .background(canvas.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }

            if isCustomized {
                Button {
                    app.resetOverrides(for: profile.id)
                } label: {
                    Label("恢復 \(profile.shortName) 原生預設", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true, fullWidth: true))
                .disabled(app.busy)
            }
        }
        .disabled(app.busy)
    }

    private func workflowActionBar(
        revealablePaths: [String],
        isFromExport: Bool,
        selectedDetail: RecordedGenerationDetail?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ComfyUI 同源工作流")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button {
                    app.exportCurrentWorkflowFiles()
                } label: {
                    Label("匯出工作流", systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true, fullWidth: true))
                .disabled(app.busy || app.isRemovedModelSelected)
                .help("以同源引擎輸出當下實際參數的 .api.json 與 .workflow.json")

                Button {
                    app.openComfyWebUI()
                } label: {
                    Label("本機 ComfyUI", systemImage: "safari")
                        .lineLimit(1)
                }
                .buttonStyle(KliporaPillButtonStyle(variant: .subtle, compact: true))
                .help("在瀏覽器開啟 \(app.endpoint)")
            }

            if !revealablePaths.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.caption2)
                        .foregroundStyle(studioAccent)
                    Text(revealablePaths.map(filename).joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button(isFromExport ? "在 Finder 顯示匯出檔" : "顯示歷史工作流") {
                        app.revealExportedWorkflowFiles(revealablePaths)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                }
            }

            if let detail = selectedDetail {
                HStack(spacing: 6) {
                    Text(detail.isRemovedModel
                         ? "所選成品為已移除模型（\(detail.removedNotice?.displayName ?? detail.action)）"
                         : "所選成品 · Seed \(detail.seed)")
                        .font(.caption2)
                        .foregroundStyle(detail.isRemovedModel ? Color.orange : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("檢視生成參數") {
                        ui.showHistoryPopover.toggle()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .popover(isPresented: $ui.showHistoryPopover, arrowEdge: .leading) {
                        RecordedGenerationInspectorPopover(app: app, detail: detail, onDismiss: {
                            ui.showHistoryPopover = false
                        })
                    }
                }
            }
        }
    }
}

// MARK: - RecordedGenerationInspectorPopover & Summary Card

struct RecordedGenerationInspectorPopover: View {
    @ObservedObject var app: Studio
    let detail: RecordedGenerationDetail
    var onDismiss: (() -> Void)?

    init(app: Studio, detail: RecordedGenerationDetail, onDismiss: (() -> Void)? = nil) {
        self.app = app
        self.detail = detail
        self.onDismiss = onDismiss
    }

    init?(app: Studio, assetPath: String, onDismiss: (() -> Void)? = nil) {
        guard let loaded = app.recordedGenerationDetail(for: assetPath) else { return nil }
        self.app = app
        self.detail = loaded
        self.onDismiss = onDismiss
    }

    private let buttonColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("生成紀錄與同源參數", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if let onDismiss {
                    Button("關閉", action: onDismiss)
                        .controlSize(.small)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let notice = detail.removedNotice {
                        removedHistoryWarning(notice)
                    }

                    // Key Metadata Grid
                    VStack(alignment: .leading, spacing: 6) {
                        metaRow("生成來源", value: detail.sourceLabel)
                        metaRow("Seed", value: String(detail.seed), monospaced: true)
                        metaRow("原生／輸出尺寸", value: detail.sizeSummary, monospaced: true)
                        if let lora = detail.lora, !lora.isEmpty {
                            let label = app.profileStore.loraProfile(for: lora)?.name ?? lora
                            metaRow("風格 LoRA", value: label)
                        }
                        if !detail.modelParams.isEmpty {
                            let orderedKeys = ["steps", "cfg", "sampler", "scheduler", "shift", "guidance", "denoise"]
                            let summaryParts = orderedKeys.compactMap { key -> String? in
                                guard let val = detail.modelParams[key] else { return nil }
                                return "\(key): \(val)"
                            }
                            if !summaryParts.isEmpty {
                                metaRow("實際採樣參數", value: summaryParts.joined(separator: " · "), monospaced: true)
                            }
                            if let neg = detail.modelParams["negativePrompt"], !neg.isEmpty {
                                metaRow("負向提示詞", value: neg)
                            }
                        }
                    }
                    .padding(9)
                    .background(surface, in: RoundedRectangle(cornerRadius: 8))

                    // Original Prompt vs Actual Submitted Prompt
                    if let original = detail.originalPrompt, original != detail.submittedPrompt {
                        promptBox(title: "原提示詞", text: original)
                        promptBox(title: "實際送出提示詞", text: detail.submittedPrompt)
                    } else {
                        promptBox(title: "實際送出提示詞（與原文相同）", text: detail.submittedPrompt)
                    }

                    // Saved ComfyUI API / Canvas Workflow Files
                    if !detail.savedWorkflowFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("已保存的同源 ComfyUI 工作流", systemImage: "point.3.connected.trianglepath.dotted")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Button("在 Finder 顯示") {
                                    app.revealExportedWorkflowFiles(detail.savedWorkflowFiles)
                                }
                                .controlSize(.small)
                            }
                            ForEach(detail.savedWorkflowFiles, id: \.self) { path in
                                Text(filename(path))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                            }
                        }
                        .padding(9)
                        .background(surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            if !detail.isRemovedModel {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        app.restoreGenerationDetail(detail)
                        onDismiss?()
                    } label: {
                        Label("載入原生成設定", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(studioAccent)
                    .foregroundStyle(canvas)
                    .disabled(app.busy)
                }
            }
        }
        .padding(14)
        .frame(width: 430)
        .frame(minHeight: 280, maxHeight: 540)
        .background(panel)
        .preferredColorScheme(.dark)
    }

    private func removedHistoryWarning(_ notice: RemovedModelNotice) -> some View {
        let replacements = app.profileStore.quickReplacementModels(for: notice)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.32))
                Text("歷史紀錄使用已移除模型（\(notice.displayName)）")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.45))
            }
            Text("\(notice.message) 可選擇以下任一模型帶入此紀錄的提示詞、Seed 與尺寸：")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: buttonColumns, alignment: .leading, spacing: 6) {
                ForEach(replacements) { profile in
                    Button {
                        app.restoreGenerationDetail(detail, replacingRemovedModelWith: profile.id)
                        onDismiss?()
                    } label: {
                        Text("改用 \(profile.shortName)")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(studioAccent)
                    .disabled(app.busy)
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.22, green: 0.11, blue: 0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(red: 1.0, green: 0.42, blue: 0.24).opacity(0.75))
        )
    }

    private func metaRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospacedDigit() : .caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func promptBox(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "（無）" : text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
        }
    }
}

@MainActor private final class RecordedGenerationSummaryCardUIState: ObservableObject {
    @Published var showInspector = false
}

struct RecordedGenerationSummaryCard: View {
    @ObservedObject var app: Studio
    let assetPath: String
    @StateObject private var ui = RecordedGenerationSummaryCardUIState()

    var body: some View {
        if let detail = app.recordedGenerationDetail(for: assetPath) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: detail.isRemovedModel ? "exclamationmark.triangle.fill" : "sparkles.rectangle.stack")
                        .foregroundStyle(detail.isRemovedModel ? Color.orange : studioAccent)
                        .font(.caption)
                    Text(detail.isRemovedModel
                         ? "模型 \(detail.removedNotice?.displayName ?? detail.action) 已移除"
                         : detail.sourceLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(detail.isRemovedModel ? Color.orange : .white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("詳情") { ui.showInspector.toggle() }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                        .popover(isPresented: $ui.showInspector, arrowEdge: .leading) {
                            RecordedGenerationInspectorPopover(app: app, detail: detail, onDismiss: {
                                ui.showInspector = false
                            })
                        }
                }
                Text("Seed \(detail.seed) · \(detail.sizeSummary)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !detail.savedWorkflowFiles.isEmpty {
                    HStack(spacing: 6) {
                        Text("已附 \(detail.savedWorkflowFiles.count) 個 ComfyUI 工作流檔")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Finder 顯示") {
                            app.revealExportedWorkflowFiles(detail.savedWorkflowFiles)
                        }
                        .controlSize(.mini)
                    }
                }
            }
            .padding(8)
            .background(surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(detail.isRemovedModel ? Color.orange.opacity(0.55) : .white.opacity(0.06))
            )
        }
    }
}
