import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Studio Video Sequence State & Actions

extension Studio {
    /// Raw persisted video generation method without silently rewriting unsupported local selections.
    var rawVideoMethod: String {
        project.videoMethod ?? "reference"
    }

    var supportsFirstLastFrames: Bool {
        action == "colab"
    }

    var supportsMultiKeyframes: Bool {
        action == "colab"
    }

    var isCurrentVideoMethodSupported: Bool {
        videoMethodUnsupportedReason == nil
    }

    var videoMethodUnsupportedReason: String? {
        guard project.kind == "video",
              action != "colab",
              rawVideoMethod == "frames" || rawVideoMethod == "multi" else {
            return nil
        }
        let providerLabel: String = {
            switch action {
            case "wan22": return "Wan 2.2 5B"
            case "wan22_14b": return "Wan 2.2 14B (4-step)"
            case "ltxv13b": return "LTX-Video 13B"
            default: return "自訂 ComfyUI 工作流"
            }
        }()
        let modeLabel = rawVideoMethod == "frames" ? "首尾影格" : "多影格"
        return "本機 \(providerLabel) 目前僅支援「文字生成」或「單張首幀／參考素材」，不支援\(modeLabel)模式。請改選「首幀」或切換至「線上 · Google Colab」。"
    }

    var videoCapabilitySummary: String {
        if action == "colab" {
            let modelName = project.model.uppercased()
            switch rawVideoMethod {
            case "multi":
                let maxFrames = Self.maxKeyframes
                let maxSegments = max(1, maxFrames - 1)
                return "線上 Colab（\(modelName)）· 多影格 3–\(maxFrames) 張（最多 \(maxSegments) 段）· 單段 2–15 秒"
            case "frames":
                return "線上 Colab（\(modelName)）· 首尾 2 張影格 · 2–15 秒"
            case "text":
                return "線上 Colab（\(modelName)）· 文字生成 · 2–15 秒"
            default:
                return "線上 Colab（\(modelName)）· 參考圖最多 \(Self.maxCloudReferenceImages) 張 + 1 支影片 · 2–15 秒"
            }
        }
        if action == "wan22" {
            return "本機 ComfyUI（Wan 2.2 5B）· 僅支援文字或 1 張首幀圖／影片 · 2–15 秒 · 不支援首尾／多影格"
        }
        if action == "wan22_14b" {
            return "本機 ComfyUI（Wan 2.2 14B + 4-step）· 支援文字或 1 張首幀圖／影片（圖生影最佳）· 2–15 秒 · 不支援首尾／多影格"
        }
        if action == "ltxv13b" {
            return "本機 ComfyUI（LTX-Video 13B Distilled）· 8 步極速出片 · 支援文字或 1 張首幀圖／影片 · 2–15 秒"
        }
        return "本機 ComfyUI（自訂工作流）· 支援 {{IMAGE}} 單圖與 {{SECONDS}} · 不支援首尾／多影格"
    }

    /// Reorders a keyframe via drag-and-drop while preserving transitions for pairs that remain adjacent in order.
    func reorderKeyframe(from sourceIndex: Int, to destinationIndex: Int) {
        let frames = orderedFrames
        guard !busy,
              frames.indices.contains(sourceIndex),
              frames.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else {
            return
        }
        let previous = multiTransitions
        var order = Array(frames.indices)
        let moved = order.remove(at: sourceIndex)
        order.insert(moved, at: destinationIndex)
        project.keyframes = order.map { frames[$0] }
        project.segments = zip(order, order.dropFirst()).map { left, right in
            right == left + 1 && previous.indices.contains(left) ? previous[left] : FrameTransition()
        }
    }

    func swapFirstLastFrames() {
        guard !busy else { return }
        let first = project.firstFrame
        project.firstFrame = project.lastFrame
        project.lastFrame = first
    }

    func clearKeyframes() {
        guard !busy else { return }
        project.keyframes = []
        project.segments = []
        status = "已清空所有影格"
    }

    func selectVideoMethod(_ method: String) {
        guard !busy else { return }
        if (method == "frames" && !supportsFirstLastFrames) || (method == "multi" && !supportsMultiKeyframes) {
            return
        }
        project.videoMethod = method
    }
}

// MARK: - Helpers

/// Uses ObservableObject + @StateObject instead of @State to stay compatible with CommandLineTools swiftc builds.
private final class DockInteractionState: ObservableObject {
    @Published var isHovering = false
    @Published var isDropTargeted = false
}

private enum KeyframeDragPayload {
    static let prefix = "motiondesk-kf:"

    static func encode(_ index: Int) -> String {
        "\(prefix)\(index)"
    }

    static func decode(_ payload: String) -> Int? {
        guard payload.hasPrefix(prefix) else { return nil }
        return Int(payload.dropFirst(prefix.count))
    }
}

// MARK: - Generation Video Sequence Dock

struct GenerationVideoSequenceDock: View {
    @ObservedObject var app: Studio

    private struct ModeOption: Identifiable {
        let id: String
        let title: String
        let icon: String
        let requiresColab: Bool
    }

    private let modeOptions: [ModeOption] = [
        ModeOption(id: "text", title: "文字", icon: "text.alignleft", requiresColab: false),
        ModeOption(id: "reference", title: "首幀/參考", icon: "photo.on.rectangle", requiresColab: false),
        ModeOption(id: "frames", title: "首尾影格", icon: "rectangle.split.2x1", requiresColab: true),
        ModeOption(id: "multi", title: "多影格", icon: "rectangle.on.rectangle.angled", requiresColab: true),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            modeAndCapabilityHeader
            Divider().overlay(.white.opacity(0.07))
            if let reason = app.videoMethodUnsupportedReason {
                unsupportedModeCard(reason: reason)
            } else {
                switch app.rawVideoMethod {
                case "frames":
                    FirstLastSequenceSection(app: app)
                case "multi":
                    MultiKeyframeSequenceSection(app: app)
                case "text":
                    TextVideoSequenceSection(app: app)
                default:
                    ReferenceSequenceSection(app: app)
                }
            }
        }
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
    }

    private var modeAndCapabilityHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                modeButtonsRow
                Spacer(minLength: 8)
                capabilityBadge
            }
            VStack(alignment: .leading, spacing: 7) {
                modeButtonsRow
                capabilityBadge
            }
        }
    }

    private var modeButtonsRow: some View {
        HStack(spacing: 6) {
            ForEach(modeOptions) { option in
                modeButton(option)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func modeButton(_ option: ModeOption) -> some View {
        let isSelected = app.rawVideoMethod == option.id
        let isLocked = option.requiresColab && app.action != "colab"
        let isUnsupportedSelected = isSelected && isLocked

        return Button {
            app.selectVideoMethod(option.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isLocked ? "lock.fill" : option.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(option.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(
                isUnsupportedSelected ? Color.orange
                    : isSelected ? studioAccent
                    : isLocked ? .secondary.opacity(0.65)
                    : .primary.opacity(0.88)
            )
            .background(
                (isUnsupportedSelected ? Color.orange.opacity(0.16)
                    : isSelected ? studioAccent.opacity(0.18)
                    : canvas.opacity(isLocked ? 0.45 : 0.78)),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isUnsupportedSelected ? Color.orange.opacity(0.65)
                            : isSelected ? studioAccent.opacity(0.7)
                            : .white.opacity(isLocked ? 0.06 : 0.1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(app.busy || isLocked)
        .opacity(isLocked && !isUnsupportedSelected ? 0.58 : 1.0)
        .accessibilityLabel(isLocked ? "\(option.title)（本機不支援，需切換至線上 Colab）" : option.title)
        .help(isLocked
              ? "目前為本機引擎，不支援「\(option.title)」。請切換至「線上 · Google Colab」以使用首尾影格與 3–\(Studio.maxKeyframes) 張多影格。"
              : "切換影片生成方式：\(option.title)")
    }

    private var capabilityBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: app.action == "colab" ? "cloud.fill" : "desktopcomputer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(app.action == "colab" ? studioAccent : .secondary)
            Text(app.videoCapabilitySummary)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(canvas.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .help(app.videoCapabilitySummary)
    }

    private func unsupportedModeCard(reason: String) -> some View {
        let modeName = app.rawVideoMethod == "frames" ? "首尾影格" : "多影格"
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("本機模式不支援「\(modeName)」")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        app.selectVideoMethod("reference")
                    } label: {
                        Label("改用首幀模式", systemImage: "photo")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(app.busy)

                    if app.project.localOnly != true {
                        Button {
                            app.selectSource("colab")
                        } label: {
                            Label("切換至線上 Colab", systemImage: "cloud")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(app.busy)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.45)))
    }
}

// MARK: - First & Last Frames Section

private struct FirstLastSequenceSection: View {
    @ObservedObject var app: Studio

    private var clampedSeconds: Int {
        min(15, max(2, app.project.seconds))
    }

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { clampedSeconds },
            set: { app.project.seconds = min(15, max(2, $0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                FirstLastFrameSlotCard(
                    title: "首幀",
                    path: $app.project.firstFrame,
                    app: app
                )

                Button {
                    app.swapFirstLastFrames()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                        Text("互換")
                            .font(.caption2)
                    }
                    .foregroundStyle(studioAccent)
                    .frame(width: 38, height: 112)
                    .background(canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(app.busy || (app.project.firstFrame == nil && app.project.lastFrame == nil))
                .accessibilityLabel("互換首尾影格")
                .help("互換首幀與尾幀")

                FirstLastFrameSlotCard(
                    title: "尾幀",
                    path: $app.project.lastFrame,
                    app: app
                )

                promptArea
                    .frame(maxWidth: .infinity)
            }

            Divider().overlay(.white.opacity(0.06))

            HStack(spacing: 10) {
                Button {
                    app.pickReferences(title: "選擇首尾影格資料夾", directory: true, receive: app.attachFirstLastFromFolder)
                } label: {
                    Label("從資料夾取首尾", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
                .disabled(app.busy)
                .help("依檔名順序自動選取資料夾內的第一張與最後一張圖片")

                Text("首尾過渡 · \(clampedSeconds) 秒")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(studioAccent)

                Spacer()

                Text("片長")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("片長秒數", value: secondsBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .monospacedDigit()
                    .accessibilityLabel("首尾影格片長秒數")
                Text("秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("首尾影格片長", value: secondsBinding, in: 2...15)
                    .labelsHidden()
                    .controlSize(.small)
                Text("2–15 秒")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(app.busy)
    }

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("整段轉場描述")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("預覽／編輯送出提示詞", action: app.previewPrompt)
                    .controlSize(.mini)
                    .disabled(app.project.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if app.editedPrompt != nil {
                    Button("還原") { app.editedPrompt = nil }
                        .controlSize(.mini)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $app.project.prompt)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("首尾影格轉場描述")
                if app.project.prompt.isEmpty {
                    Text("描述首幀到尾幀之間的動作、運鏡與節奏變化。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(6)
            .frame(height: 92)
            .background(canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.09)))
        }
    }
}

private struct FirstLastFrameSlotCard: View {
    let title: String
    @Binding var path: String?
    @ObservedObject var app: Studio
    @StateObject private var interaction = DockInteractionState()

    private var hasImage: Bool { path != nil }

    private var captionText: String {
        if let currentPath = path { return filename(currentPath) }
        return "尚未設定\(title)"
    }

    private var helpText: String {
        if let currentPath = path {
            return "\(title)：\(filename(currentPath))（點擊更換圖片，或拖入新圖片）"
        }
        return "點擊選擇\(title)圖片，或從素材庫／Finder 拖入"
    }

    var body: some View {
        let borderColor: Color = interaction.isDropTargeted
            ? studioAccent
            : hasImage ? studioAccent.opacity(0.4) : .white.opacity(0.1)

        VStack(alignment: .leading, spacing: 5) {
            Button {
                app.pickReferences(title: "選擇\(title)", types: [.image]) { urls in
                    app.attachFrame(urls, to: $path)
                }
            } label: {
                VStack(spacing: 6) {
                    slotThumbnail
                    Text(captionText)
                        .font(.caption2)
                        .foregroundStyle(hasImage ? Color.primary.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 120, alignment: .leading)
                }
                .padding(6)
                .background(canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(borderColor, lineWidth: interaction.isDropTargeted ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(app.busy)
            .accessibilityLabel("選擇\(title)")
            .help(helpText)

            if let currentPath = path {
                HStack(spacing: 6) {
                    Button {
                        app.generateSelection = currentPath
                    } label: {
                        Image(systemName: "eye")
                    }
                    .controlSize(.mini)
                    .help("在中央監看預覽\(title)")
                    .accessibilityLabel("預覽\(title)")

                    Spacer(minLength: 0)

                    Button("移除") {
                        path = nil
                    }
                    .controlSize(.mini)
                    .disabled(app.busy)
                    .accessibilityLabel("移除\(title)")
                }
                .frame(width: 132)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            app.attachFrame(urls, to: $path)
        } isTargeted: { targeted in
            interaction.isDropTargeted = targeted
        }
    }

    private var slotThumbnail: some View {
        ZStack(alignment: .topLeading) {
            if let currentPath = path {
                MediaThumbnail(path: currentPath, width: 120, height: 88, reloadToken: app.mediaReloadToken)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(canvas.opacity(0.85))
                    .frame(width: 120, height: 88)
                    .overlay(
                        VStack(spacing: 5) {
                            Image(systemName: "plus.viewfinder")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(studioAccent)
                            Text("點擊或拖入圖片")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            }

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(hasImage ? canvas : .white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(hasImage ? studioAccent : panel.opacity(0.9), in: Capsule())
                .padding(5)
        }
    }
}

// MARK: - Multi-Keyframe Sequence Section

private struct MultiKeyframeSequenceSection: View {
    @ObservedObject var app: Studio
    @StateObject private var interaction = DockInteractionState()

    var body: some View {
        let frames = app.orderedFrames
        let count = frames.count
        let transitions = app.multiTransitions
        let atLimit = count >= Studio.maxKeyframes

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("\(count) / \(Studio.maxKeyframes) 張影格")
                        .foregroundStyle(.primary)
                        .fontWeight(.semibold)
                    Text("· \(transitions.count) 段過渡 · 共 \(app.generationSeconds) 秒 · 單段上限 2–15 秒")
                        .foregroundStyle(transitions.isEmpty ? .secondary : studioAccent)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 8)

                Button {
                    app.pickReferences(title: "依順序加入影格", types: [.image], multiple: true) { urls in
                        app.addKeyframes(urls)
                    }
                } label: {
                    Label("加入圖片", systemImage: "photo.badge.plus")
                }
                .controlSize(.small)
                .disabled(app.busy || atLimit)
                .help("一次多選加入影格圖片，上限 \(Studio.maxKeyframes) 張")

                Button {
                    app.pickReferences(title: "選擇影格資料夾", directory: true) { urls in
                        app.addKeyframes(urls)
                    }
                } label: {
                    Label("加入資料夾", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
                .disabled(app.busy || atLimit)
                .help("依檔名順序批次加入資料夾內的圖片，上限 \(Studio.maxKeyframes) 張")

                Button("清空") {
                    app.clearKeyframes()
                }
                .controlSize(.small)
                .disabled(app.busy || count == 0)
                .help("清空目前所有多影格與過渡設定")
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { index, path in
                        SequenceKeyframeCard(
                            index: index,
                            total: count,
                            path: path,
                            app: app
                        )
                        if index < transitions.count {
                            SequenceTransitionTile(
                                index: index,
                                fromPath: path,
                                toPath: frames[index + 1],
                                transition: transitions[index],
                                app: app
                            )
                            .id("\(index)-\(path)-\(frames[index + 1])")
                        }
                    }

                    if !atLimit {
                        Button {
                            app.pickReferences(title: "依順序加入影格", types: [.image], multiple: true) { urls in
                                app.addKeyframes(urls)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(studioAccent)
                                Text(count == 0 ? "加入影格" : "影格 \(count + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 96, height: 102)
                            .background(canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(app.busy)
                        .accessibilityLabel("加入影格")
                        .help("選擇一張或多張圖片加入序列（最多 \(Studio.maxKeyframes) 張）")
                    }

                    if count == 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("選擇或拖入 3–\(Studio.maxKeyframes) 張圖片")
                                .font(.callout.weight(.medium))
                            Text("支援從左側素材庫或 Finder 直接拖放圖片與資料夾")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 6)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(height: 118)
            .padding(.horizontal, 6)
            .background(canvas.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        interaction.isDropTargeted ? studioAccent : .white.opacity(0.07),
                        lineWidth: interaction.isDropTargeted ? 2 : 1
                    )
            )
            .dropDestination(for: URL.self) { urls, _ in
                app.addKeyframes(urls)
            } isTargeted: { targeted in
                interaction.isDropTargeted = targeted
            }

            HStack {
                if count == 0 {
                    Text("支援最多 \(Studio.maxKeyframes) 張影格（最多 \(max(1, Studio.maxKeyframes - 1)) 段過渡），拖曳卡片可隨時重排順序。")
                } else if count < 3 {
                    Text("還差 \(3 - count) 張圖片即可生成（需至少 3 張，最多 \(Studio.maxKeyframes) 張）。")
                        .foregroundStyle(.orange)
                } else {
                    Text("點 T 編輯每段過渡描述與 2–15 秒片長；拖曳影格卡片可重排順序，點擊縮圖於上方預覽。")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct SequenceKeyframeCard: View {
    let index: Int
    let total: Int
    let path: String
    @ObservedObject var app: Studio
    @StateObject private var interaction = DockInteractionState()

    private var isSelected: Bool {
        app.generateSelection == path
    }

    var body: some View {
        let borderColor: Color = interaction.isDropTargeted
            ? studioAccent
            : isSelected ? studioAccent.opacity(0.85) : .white.opacity(0.14)
        let borderWidth: CGFloat = interaction.isDropTargeted ? 2.5 : (isSelected ? 1.5 : 1)

        VStack(spacing: 4) {
            thumbnailWithOverlays
            Text(filename(path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 92, alignment: .leading)
        }
        .padding(4)
        .background(panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .overlay(alignment: .leading) {
            if interaction.isDropTargeted {
                Capsule()
                    .fill(studioAccent)
                    .frame(width: 3, height: 92)
                    .offset(x: -5)
            }
        }
        .onHover { hovering in
            interaction.isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("影格 \(index + 1)，\(filename(path))")
        .help("\(filename(path))（點擊預覽，拖曳可重排順序，右鍵開啟選單）")
        .draggable(KeyframeDragPayload.encode(index)) {
            dragPreview
        }
        .dropDestination(for: String.self) { items, _ in
            handleStringDrop(items)
        } isTargeted: { targeted in
            interaction.isDropTargeted = targeted
        }
        .contextMenu {
            Button("於中央預覽") {
                app.generateSelection = path
            }
            Divider()
            Button("向左移動") {
                app.moveKeyframe(index, offset: -1)
            }
            .disabled(app.busy || index == 0)
            Button("向右移動") {
                app.moveKeyframe(index, offset: 1)
            }
            .disabled(app.busy || index == total - 1)
            Divider()
            Button("移除影格", role: .destructive) {
                app.removeKeyframe(index)
            }
            .disabled(app.busy)
        }
    }

    private var thumbnailWithOverlays: some View {
        ZStack {
            MediaThumbnail(path: path, width: 92, height: 74, reloadToken: app.mediaReloadToken)

            VStack {
                HStack {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(isSelected ? canvas : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? studioAccent : .black.opacity(0.75), in: Capsule())
                    Spacer()
                    if interaction.isHovering && !app.busy {
                        Button {
                            app.removeKeyframe(index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, .black.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除影格 \(index + 1)")
                        .help("移除影格 \(index + 1)")
                    }
                }
                Spacer()
                if interaction.isHovering && !app.busy && total > 1 {
                    moveButtonsRow
                }
            }
            .padding(4)
        }
        .frame(width: 92, height: 74)
        .contentShape(Rectangle())
        .onTapGesture {
            app.generateSelection = path
        }
    }

    private var moveButtonsRow: some View {
        HStack(spacing: 4) {
            Button {
                app.moveKeyframe(index, offset: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 16)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .opacity(index == 0 ? 0.35 : 1)
            .help("向左移動")

            Spacer()

            Button {
                app.moveKeyframe(index, offset: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 16)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(index == total - 1)
            .opacity(index == total - 1 ? 0.35 : 1)
            .help("向右移動")
        }
        .foregroundStyle(.white)
    }

    private var dragPreview: some View {
        VStack(spacing: 3) {
            MediaThumbnail(path: path, width: 76, height: 60, reloadToken: app.mediaReloadToken)
            Text("影格 \(index + 1)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(5)
        .background(panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(studioAccent))
    }

    private func handleStringDrop(_ items: [String]) -> Bool {
        guard !app.busy else { return false }
        if let payload = items.first,
           let sourceIndex = KeyframeDragPayload.decode(payload) {
            guard sourceIndex != index else { return false }
            app.reorderKeyframe(from: sourceIndex, to: index)
            return true
        }
        let fileURLs = items.compactMap { item -> URL? in
            guard let url = URL(string: item), url.isFileURL else { return nil }
            return url
        }
        if !fileURLs.isEmpty {
            return app.addKeyframes(fileURLs)
        }
        return false
    }
}

// MARK: - Sequence Transition Tile & Popover

private final class SequenceTransitionDraft: ObservableObject {
    @Published var isPresented = false
    @Published var prompt = ""
    @Published var seconds = ""
    @Published var applyToAll = false

    var validSeconds: Int? {
        guard let value = Int(seconds.trimmingCharacters(in: .whitespacesAndNewlines)),
              (2...15).contains(value) else { return nil }
        return value
    }

    func open(_ transition: FrameTransition) {
        prompt = transition.prompt
        seconds = String(transition.seconds)
        applyToAll = false
        isPresented = true
    }
}

private struct SequenceTransitionTile: View {
    let index: Int
    let fromPath: String
    let toPath: String
    let transition: FrameTransition
    @ObservedObject var app: Studio

    @StateObject private var draft = SequenceTransitionDraft()

    var body: some View {
        let hasPrompt = !transition.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Button {
            draft.open(transition)
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    Text("T")
                        .font(.system(.callout, design: .monospaced).weight(.bold))
                    if hasPrompt {
                        Circle()
                            .fill(studioAccent)
                            .frame(width: 5, height: 5)
                    }
                }
                Text("\(transition.seconds) 秒")
                    .font(.caption2.monospacedDigit().weight(.medium))
            }
            .foregroundStyle(hasPrompt || draft.isPresented ? studioAccent : .white.opacity(0.78))
            .frame(width: 48, height: 74)
            .background(panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(hasPrompt || draft.isPresented ? studioAccent : .white.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .disabled(app.busy)
        .accessibilityLabel("第 \(index + 1) 段過渡，\(transition.seconds) 秒")
        .help(hasPrompt ? "第 \(index + 1) 段過渡（\(transition.seconds) 秒）：\(transition.prompt)" : "點擊編輯第 \(index + 1) 段過渡提示詞與秒數")
        .popover(isPresented: $draft.isPresented, arrowEdge: .top) {
            SequenceTransitionPopover(
                index: index,
                fromPath: fromPath,
                toPath: toPath,
                app: app,
                prompt: $draft.prompt,
                secondsText: $draft.seconds,
                applyToAll: $draft.applyToAll,
                validSeconds: draft.validSeconds,
                onDismiss: { draft.isPresented = false }
            )
        }
    }
}

struct SequenceTransitionPopover: View {
    private enum Field: Hashable {
        case prompt
        case seconds
    }

    let index: Int
    let fromPath: String
    let toPath: String
    @ObservedObject var app: Studio
    @Binding var prompt: String
    @Binding var secondsText: String
    @Binding var applyToAll: Bool
    let validSeconds: Int?
    let onDismiss: () -> Void

    @FocusState private var focusedField: Field?

    private var stepperBinding: Binding<Int> {
        Binding(
            get: { validSeconds ?? 3 },
            set: { secondsText = String(min(15, max(2, $0))) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MediaThumbnail(path: fromPath, width: 38, height: 28, reloadToken: app.mediaReloadToken)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(studioAccent)
                MediaThumbnail(path: toPath, width: 38, height: 28, reloadToken: app.mediaReloadToken)
                VStack(alignment: .leading, spacing: 2) {
                    Text("影格 \(index + 1) → \(index + 2)")
                        .font(.headline)
                    Text("第 \(index + 1) 段過渡設定")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($focusedField, equals: .prompt)
                    .accessibilityLabel("過渡提示詞")
                if prompt.isEmpty {
                    Text("描述這兩張影格之間的動作、運鏡與過渡細節")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 118)
            .background(canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.1)))

            HStack(spacing: 8) {
                Text("片長")
                TextField("秒數", text: $secondsText)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 44)
                    .focused($focusedField, equals: .seconds)
                Stepper("過渡秒數", value: stepperBinding, in: 2...15)
                    .labelsHidden()
                    .controlSize(.small)
                Text("秒（2–15）")
                    .foregroundStyle(validSeconds == nil ? .orange : .secondary)
                Spacer()
                Toggle("套用到全部過渡段", isOn: $applyToAll)
                    .toggleStyle(.checkbox)
                    .help("將此過渡提示詞與秒數套用到所有過渡段")
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("取消", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("確認") {
                    guard let seconds = validSeconds else { return }
                    app.updateTransition(index, seconds: seconds, prompt: prompt, applyToAll: applyToAll)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(app.busy || validSeconds == nil)
            }
        }
        .padding(16)
        .frame(width: 390)
        .tint(studioAccent)
        .onAppear { focusedField = .prompt }
        .onKeyPress(phases: .down, action: handleKeyPress)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .escape {
            onDismiss()
            return .handled
        }
        let backTab = KeyEquivalent("\u{19}")
        guard keyPress.key == .tab || keyPress.key == backTab,
              keyPress.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        let backward = keyPress.modifiers.contains(.shift) || keyPress.key == backTab
        if focusedField == .prompt && !backward {
            focusedField = .seconds
            return .handled
        }
        if focusedField == .seconds && backward {
            focusedField = .prompt
            return .handled
        }
        return .ignored
    }
}

// MARK: - Shared Qwen3-VL Image-to-Prompt Draft Card

struct VLMPromptDraftCard: View {
    @ObservedObject var app: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(studioAccent)
                Text("看圖產生提示詞草稿（可先編修再套用）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                if !app.vlmDraftSourcePath.isEmpty {
                    Text("· \(filename(app.vlmDraftSourcePath))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button {
                    app.dismissVLMDraft()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("關閉看圖提示詞草稿")
                .help("關閉草稿（不影響現有提示詞稿件）")
            }

            TextEditor(text: $app.vlmDraftPrompt)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(minHeight: 74, maxHeight: 110)
                .background(canvas, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(studioAccent.opacity(0.35)))
                .accessibilityLabel("看圖產生提示詞草稿編輯框")

            HStack(spacing: 8) {
                Button {
                    app.applyVLMDraftToPrompt(append: false)
                } label: {
                    Label("套用到提示詞", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(studioAccent)
                .foregroundStyle(canvas)
                .controlSize(.small)
                .disabled(app.vlmDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("套用到提示詞")
                .help("將上方草稿套用至「畫面與動作」提示詞框")

                if !app.project.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        app.applyVLMDraftToPrompt(append: true)
                    } label: {
                        Label("附加到現有提示詞後", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(app.vlmDraftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("附加到現有提示詞後")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(studioAccent.opacity(0.4)))
    }
}

// MARK: - Reference / First Frame Section

private struct ReferenceSequenceSection: View {
    @ObservedObject var app: Studio
    @StateObject private var interaction = DockInteractionState()

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { app.generationSeconds },
            set: { app.project.seconds = min(app.secondsRange.upperBound, max(app.secondsRange.lowerBound, $0)) }
        )
    }

    var body: some View {
        Group {
            if app.action == "colab" {
                colabReferenceStrip
            } else {
                localReferenceSlot
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            app.attachReferences(urls)
        } isTargeted: { targeted in
            interaction.isDropTargeted = targeted
        }
        .disabled(app.busy)
    }

    private var localReferenceSlot: some View {
        let imagePath = app.referenceImages.first
        let videoPath = app.acceptsVideoReference ? app.project.referenceVideo.flatMap { $0.isEmpty ? nil : $0 } : nil
        let activePath = imagePath ?? videoPath
        let activeIsVideo = imagePath == nil && videoPath != nil
        let slotLabel = app.isBuiltinLocalVideoAction ? (activeIsVideo ? "首幀影片" : "首幀圖片") : "參考圖片"
        let borderColor: Color = interaction.isDropTargeted
            ? studioAccent
            : activePath != nil ? studioAccent.opacity(0.45) : .white.opacity(0.1)

        return HStack(alignment: .center, spacing: 12) {
            Button {
                let types: [UTType] = app.acceptsVideoReference ? [.image, .movie] : [.image]
                app.pickReferences(title: "選擇首幀參考素材", types: types, multiple: false) { urls in
                    app.attachReferences(urls)
                }
            } label: {
                ZStack(alignment: .topLeading) {
                    if let activePath {
                        MediaThumbnail(path: activePath, width: 124, height: 86, reloadToken: app.mediaReloadToken)
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(canvas.opacity(0.85))
                            .frame(width: 124, height: 86)
                            .overlay(
                                VStack(spacing: 5) {
                                    Image(systemName: app.acceptsVideoReference ? "photo.on.rectangle.angled" : "photo.badge.plus")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(studioAccent)
                                    Text(app.acceptsVideoReference ? "加入首幀圖／影片" : "加入參考圖")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                    }

                    Text(slotLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(activePath != nil ? canvas : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(activePath != nil ? studioAccent : panel.opacity(0.9), in: Capsule())
                        .padding(5)
                }
                .padding(4)
                .background(canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(borderColor, lineWidth: interaction.isDropTargeted ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("選擇\(slotLabel)")
            .help(activePath.map { "\(slotLabel)：\(filename($0))（點擊替換或拖入新檔案）" } ?? "點擊選擇或拖入首幀素材")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if let activePath {
                        Text(filename(activePath))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            app.generateSelection = activePath
                        } label: {
                            Image(systemName: "eye")
                        }
                        .controlSize(.mini)
                        .help("於中央監看預覽")
                        Button("移除") {
                            if activeIsVideo {
                                app.project.referenceVideo = nil
                            } else {
                                app.removeReferenceImage(activePath)
                            }
                        }
                        .controlSize(.mini)
                    } else {
                        Text(app.isBuiltinLocalVideoAction ? "尚未指定首幀素材（不加入則依文字生成）" : "尚未指定參考圖片")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text(app.isBuiltinLocalVideoAction
                     ? "本機內建影片模型單次支援 1 張首幀圖或 1 支參考影片（支援從左側素材庫／Finder 拖放）。"
                     : "本機自訂 ComfyUI 工作流會透過 {{IMAGE}} 讀取 1 張參考圖片，並以 {{SECONDS}} 傳入目標片長。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        let types: [UTType] = app.acceptsVideoReference ? [.image, .movie] : [.image]
                        app.pickReferences(title: "選擇參考素材", types: types, multiple: false) { urls in
                            app.attachReferences(urls)
                        }
                    } label: {
                        Label(activePath == nil ? "選擇檔案" : "替換檔案", systemImage: "folder")
                    }
                    .controlSize(.small)

                    if let activePath {
                        Button {
                            app.interrogateReferenceImage(path: activePath)
                        } label: {
                            Label("看圖產生提示詞", systemImage: "sparkles.rectangle.stack")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(studioAccent)
                        .foregroundStyle(canvas)
                        .disabled(app.busy)
                        .accessibilityLabel("看圖產生提示詞")
                        .help("使用本機 ComfyUI 的 Qwen3-VL-8B 模型分析首幀並產生可編輯提示詞草稿")
                    }

                    Spacer()

                    Text("片長")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("片長秒數", value: secondsBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .monospacedDigit()
                        .accessibilityLabel("影片片長秒數")
                    Text("秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper("影片片長", value: secondsBinding, in: app.secondsRange)
                        .labelsHidden()
                        .controlSize(.small)
                    Text("\(app.secondsRange.lowerBound)–\(app.secondsRange.upperBound) 秒")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var colabReferenceStrip: some View {
        let images = app.referenceImages
        let video = app.acceptsVideoReference ? app.project.referenceVideo.flatMap { $0.isEmpty ? nil : $0 } : nil
        let canAddMore = images.count < Studio.maxCloudReferenceImages || video == nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("參考素材 · 圖片 \(images.count)/\(Studio.maxCloudReferenceImages)\(video != nil ? " · 影片 1/1" : "")")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 6)

                Button {
                    let types: [UTType] = app.acceptsVideoReference ? [.image, .movie] : [.image]
                    app.pickReferences(title: "選擇參考素材", types: types, multiple: true) { urls in
                        app.attachReferences(urls)
                    }
                } label: {
                    Label("加入檔案", systemImage: "plus")
                }
                .controlSize(.small)

                Button {
                    app.pickReferences(title: "選擇參考素材資料夾", directory: true) { urls in
                        app.attachReferences(urls)
                    }
                } label: {
                    Label("加入資料夾", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)

                if let firstImg = images.first ?? video {
                    Button {
                        app.interrogateReferenceImage(path: firstImg)
                    } label: {
                        Label("看圖產生提示詞", systemImage: "sparkles.rectangle.stack")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(studioAccent)
                    .foregroundStyle(canvas)
                    .disabled(app.busy)
                    .accessibilityLabel("看圖產生提示詞")
                }

                Divider().frame(height: 16).overlay(.white.opacity(0.1))

                Text("片長")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("片長秒數", value: secondsBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 46)
                    .monospacedDigit()
                    .accessibilityLabel("影片片長秒數")
                Text("秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("影片片長", value: secondsBinding, in: app.secondsRange)
                    .labelsHidden()
                    .controlSize(.small)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element) { index, path in
                        ReferenceThumbnailTile(
                            badge: "@圖片\(index + 1)",
                            path: path,
                            isVideo: false,
                            isSelected: app.generateSelection == path,
                            reloadToken: app.mediaReloadToken,
                            onSelect: { app.generateSelection = path },
                            onRemove: { app.removeReferenceImage(path) }
                        )
                    }

                    if let video {
                        ReferenceThumbnailTile(
                            badge: "@影片1",
                            path: video,
                            isVideo: true,
                            isSelected: app.generateSelection == video,
                            reloadToken: app.mediaReloadToken,
                            onSelect: { app.generateSelection = video },
                            onRemove: { app.project.referenceVideo = nil }
                        )
                    }

                    if canAddMore {
                        Button {
                            let types: [UTType] = app.acceptsVideoReference ? [.image, .movie] : [.image]
                            app.pickReferences(title: "選擇參考素材", types: types, multiple: true) { urls in
                                app.attachReferences(urls)
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(studioAccent)
                                Text("加入參考")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 88, height: 92)
                            .background(canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("加入參考素材")
                    }

                    if images.isEmpty && video == nil {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("拖入最多 \(Studio.maxCloudReferenceImages) 張圖片與 1 支影片")
                                .font(.callout.weight(.medium))
                            Text("可在提示詞以 @圖片1、@影片1 指定角色、風格或運鏡來源")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(height: 106)
            .padding(.horizontal, 6)
            .background(canvas.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        interaction.isDropTargeted ? studioAccent : .white.opacity(0.07),
                        lineWidth: interaction.isDropTargeted ? 2 : 1
                    )
            )

            Text("預設全部參考；亦可在提示詞使用 @圖片1…@圖片\(Studio.maxCloudReferenceImages)、@影片1 指定。支援從左側素材庫或 Finder 直接拖放。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReferenceThumbnailTile: View {
    let badge: String
    let path: String
    let isVideo: Bool
    let isSelected: Bool
    let reloadToken: Int
    let onSelect: () -> Void
    let onRemove: () -> Void

    @StateObject private var interaction = DockInteractionState()

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                MediaThumbnail(path: path, width: 88, height: 68, reloadToken: reloadToken)

                VStack {
                    HStack {
                        HStack(spacing: 2) {
                            if isVideo {
                                Image(systemName: "film")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            Text(badge)
                                .font(.caption2.monospacedDigit().weight(.semibold))
                        }
                        .foregroundStyle(isSelected ? canvas : .white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isSelected ? studioAccent : .black.opacity(0.75), in: Capsule())

                        Spacer()

                        if interaction.isHovering {
                            Button(action: onRemove) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white, .black.opacity(0.72))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除\(badge)")
                            .help("移除\(badge)")
                        }
                    }
                    Spacer()
                }
                .padding(4)
            }
            .frame(width: 88, height: 68)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            Text(filename(path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 88, alignment: .leading)
        }
        .padding(4)
        .background(panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? studioAccent : .white.opacity(0.14), lineWidth: isSelected ? 1.5 : 1)
        )
        .onHover { interaction.isHovering = $0 }
        .help("\(badge) · \(filename(path))（點擊預覽）")
        .contextMenu {
            Button("於中央預覽", action: onSelect)
            Button("移除\(badge)", role: .destructive, action: onRemove)
        }
    }
}

// MARK: - Text Video Sequence Section

private struct TextVideoSequenceSection: View {
    @ObservedObject var app: Studio

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { app.generationSeconds },
            set: { app.project.seconds = min(app.secondsRange.upperBound, max(app.secondsRange.lowerBound, $0)) }
        )
    }

    private var modelBadgeText: String {
        if app.action == "colab" {
            return "線上 Colab · \(app.project.model.uppercased())"
        }
        if app.action == "wan22" {
            return "本機 · Wan 2.2 5B"
        }
        if app.action == "wan22_14b" {
            return "本機 · Wan 2.2 14B (4-step)"
        }
        if app.action == "ltxv13b" {
            return "本機 · LTX-Video 13B"
        }
        return "本機 · 自訂 ComfyUI"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.callout)
                .foregroundStyle(studioAccent)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("文字生成影片")
                        .font(.caption.weight(.semibold))
                    Text(modelBadgeText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(canvas.opacity(0.75), in: Capsule())
                }
                Text("直接於右側撰寫提示詞；若想指定畫面起點或參考素材，可隨時切換至「首幀/參考」。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text("片長")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("片長秒數", value: secondsBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 46)
                    .monospacedDigit()
                    .accessibilityLabel("影片片長秒數")
                Text("秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("影片片長", value: secondsBinding, in: app.secondsRange)
                    .labelsHidden()
                    .controlSize(.small)
                Text("\(app.secondsRange.lowerBound)–\(app.secondsRange.upperBound) 秒")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("改用首幀/參考") {
                app.selectVideoMethod("reference")
            }
            .controlSize(.small)
        }
        .disabled(app.busy)
    }
}
