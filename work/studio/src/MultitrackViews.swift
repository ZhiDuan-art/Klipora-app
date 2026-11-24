import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palette, Tabs & Shared Edit State

private let mtPlayheadRed = StudioTheme.coral
private let mtSnapYellow = StudioTheme.warmHighlight
private let mtCyanAccent = StudioTheme.neutralAccent
private let mtVideoFill = Color(red: 0.145, green: 0.195, blue: 0.275)
private let mtVideoAccent = Color(red: 0.45, green: 0.68, blue: 0.98)
private let mtStillFill = Color(red: 0.135, green: 0.220, blue: 0.235)
private let mtStillAccent = Color(red: 0.40, green: 0.80, blue: 0.74)
private let mtAudioFill = Color(red: 0.125, green: 0.230, blue: 0.178)
private let mtAudioAccent = Color(red: 0.36, green: 0.84, blue: 0.56)
private let mtTextFill = Color(red: 0.245, green: 0.192, blue: 0.128)
private let mtTextAccent = Color(red: 0.96, green: 0.72, blue: 0.34)
private let mtDarkWell = StudioTheme.well

enum MultitrackPreviewMode: String {
    case timeline
    case source
}

enum MultitrackLibraryTab: String, CaseIterable, Identifiable {
    case media
    case text
    case transitions
    case filters
    case audioVoice
    case aiTools

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .media: return L10n.t("tab.media", fallback: "素材")
        case .text: return L10n.t("tab.text", fallback: "文字")
        case .transitions: return L10n.t("tab.transitions", fallback: "轉場")
        case .filters: return L10n.t("tab.filters", fallback: "特效濾鏡")
        case .audioVoice: return L10n.t("tab.audioVoice", fallback: "音訊配音")
        case .aiTools: return L10n.t("tab.aiTools", fallback: "AI工具")
        }
    }

    var symbolName: String {
        switch self {
        case .media: return "square.stack.fill"
        case .text: return "t.square"
        case .transitions: return "rectangle.on.rectangle.angled"
        case .filters: return "camera.filters"
        case .audioVoice: return "waveform.badge.mic"
        case .aiTools: return "sparkles"
        }
    }
}

enum MultitrackInspectorTab: String, CaseIterable, Identifiable {
    case transform
    case colorKey
    case audio
    case transition
    case text
    case shape
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transform: return "變換"
        case .colorKey: return "濾鏡/去背"
        case .audio: return "音訊"
        case .transition: return "轉場"
        case .text: return "文字"
        case .shape: return "形狀"
        case .output: return "輸出"
        }
    }
}

@MainActor final class MultitrackEditState: ObservableObject {
    @Published var selection: TimelineSelection? = nil {
        didSet {
            if selection != oldValue {
                syncInspectorTabForSelection()
            }
        }
    }
    @Published var pixelsPerSecond: CGFloat = 56
    @Published var previewMode: MultitrackPreviewMode = .timeline
    @Published var viewportWidth: CGFloat = 700
    @Published var activeTrackID: UUID? = nil
    @Published var activeVideoTrackID: UUID? = nil
    @Published var activeAudioTrackID: UUID? = nil
    @Published var activeTextTrackID: UUID? = nil
    @Published var activeShapeTrackID: UUID? = nil
    @Published var librarySearchQuery: String = ""
    @Published var rippleDelete: Bool = true
    @Published var snapThresholdPx: CGFloat = 10
    @Published var activeSnapGuideTime: Double? = nil
    @Published var dragPreviewHint: String? = nil
    @Published var hoveredJunctionID: String? = nil
    @Published var dropTargetTrackID: UUID? = nil
    @Published var editingTrackRenameID: UUID? = nil
    @Published var trackRenameDraft: String = ""
    @Published var libraryTab: MultitrackLibraryTab = .media
    @Published var inspectorTab: MultitrackInspectorTab = .transform
    @Published var animationTargetIsOut: Bool = false
    @Published var transitionDefaultSeconds: Double = 0.5
    @Published var editingSequenceRenameID: UUID? = nil
    @Published var sequenceRenameDraft: String = ""
    var keyMonitor: Any?

    static let minZoom: CGFloat = 14
    static let maxZoom: CGFloat = 240

    func availableInspectorTabs() -> [MultitrackInspectorTab] {
        switch selection {
        case .videoClip:
            return [.transform, .colorKey, .audio, .output]
        case .transition:
            return [.transition, .output]
        case .textClip:
            return [.text, .output]
        case .shapeClip:
            return [.shape, .output]
        case .audioClip:
            return [.audio, .output]
        case nil:
            return [.output]
        }
    }

    func syncInspectorTabForSelection() {
        let allowed = availableInspectorTabs()
        if !allowed.contains(inspectorTab) {
            inspectorTab = allowed.first ?? .output
        }
    }

    func zoomIn() {
        pixelsPerSecond = min(Self.maxZoom, (pixelsPerSecond * 1.25).rounded())
    }

    func zoomOut() {
        pixelsPerSecond = max(Self.minZoom, (pixelsPerSecond / 1.25).rounded())
    }

    func fit(totalDuration: Double) {
        let available = max(160, viewportWidth - 64)
        let target = available / CGFloat(max(1.0, totalDuration))
        pixelsPerSecond = min(Self.maxZoom, max(Self.minZoom, target))
    }

    func selectActiveTrack(_ id: UUID, kind: TrackKind) {
        activeTrackID = id
        switch kind {
        case .video: activeVideoTrackID = id
        case .audio: activeAudioTrackID = id
        case .text: activeTextTrackID = id
        case .shape: activeShapeTrackID = id
        }
    }

    func preferredTargetTrackID(for path: String, in timeline: MultitrackTimeline) -> UUID? {
        if isAudioMediaPath(path) {
            if let activeAudioTrackID, timeline.audioTracks.contains(where: { $0.id == activeAudioTrackID }) {
                return activeAudioTrackID
            }
            return timeline.audioTracks.first?.id
        } else {
            if let activeVideoTrackID, timeline.videoTracks.contains(where: { $0.id == activeVideoTrackID }) {
                return activeVideoTrackID
            }
            return timeline.videoTracks.first?.id
        }
    }

    func preferredTextTrackID(in timeline: MultitrackTimeline) -> UUID? {
        if let activeTextTrackID, timeline.textTracks.contains(where: { $0.id == activeTextTrackID }) {
            return activeTextTrackID
        }
        return timeline.textTracks.first?.id
    }

    func targetJunction(in layout: MultitrackLayout, playhead: Double) -> TrackJunctionLayout? {
        if case .transition(let tid, let afterID, let beforeID) = selection,
           let j = layout.junction(trackID: tid, afterID: afterID, beforeID: beforeID) {
            return j
        }
        var best: TrackJunctionLayout?
        var bestDist = Double.infinity
        for vt in layout.videoTracks where !vt.track.locked {
            for j in vt.junctions {
                let d = abs(j.seamTime - playhead)
                if d < bestDist {
                    bestDist = d
                    best = j
                }
            }
        }
        return best
    }

    func selectedVideoSegment(in layout: MultitrackLayout) -> VideoSegmentLayout? {
        if case .videoClip(let tid, let cid) = selection {
            return layout.videoSegment(trackID: tid, clipID: cid)
        }
        return nil
    }

    func reconcileSelection(with layout: MultitrackLayout) {
        if let activeVideoTrackID, !layout.videoTracks.contains(where: { $0.id == activeVideoTrackID }) {
            self.activeVideoTrackID = layout.videoTracks.first?.id
        } else if activeVideoTrackID == nil {
            activeVideoTrackID = layout.videoTracks.first?.id
        }
        if let activeAudioTrackID, !layout.audioTracks.contains(where: { $0.id == activeAudioTrackID }) {
            self.activeAudioTrackID = layout.audioTracks.first?.id
        } else if activeAudioTrackID == nil {
            activeAudioTrackID = layout.audioTracks.first?.id
        }
        if let activeTextTrackID, !layout.textTracks.contains(where: { $0.id == activeTextTrackID }) {
            self.activeTextTrackID = layout.textTracks.first?.id
        } else if activeTextTrackID == nil {
            activeTextTrackID = layout.textTracks.first?.id
        }

        guard let current = selection else {
            syncInspectorTabForSelection()
            return
        }
        switch current {
        case .videoClip(let tid, let cid):
            if layout.videoSegment(trackID: tid, clipID: cid) == nil {
                selection = firstAvailableSelection(in: layout)
            }
        case .audioClip(let tid, let cid):
            if layout.audioSegment(trackID: tid, clipID: cid) == nil {
                selection = firstAvailableSelection(in: layout)
            }
        case .textClip(let tid, let cid):
            if layout.textSegment(trackID: tid, clipID: cid) == nil {
                selection = firstAvailableSelection(in: layout)
            }
        case .shapeClip(let tid, let cid):
            if layout.shapeSegment(trackID: tid, clipID: cid) == nil {
                selection = firstAvailableSelection(in: layout)
            }
        case .transition(let tid, let afterID, let beforeID):
            if layout.junction(trackID: tid, afterID: afterID, beforeID: beforeID) == nil {
                selection = firstAvailableSelection(in: layout)
            }
        }
        syncInspectorTabForSelection()
    }

    private func firstAvailableSelection(in layout: MultitrackLayout) -> TimelineSelection? {
        for vt in layout.videoTracks {
            if let seg = vt.segments.first { return .videoClip(trackID: vt.id, clipID: seg.id) }
        }
        for tt in layout.textTracks {
            if let seg = tt.segments.first { return .textClip(trackID: tt.id, clipID: seg.id) }
        }
        for st in layout.shapeTracks {
            if let seg = st.segments.first { return .shapeClip(trackID: st.id, clipID: seg.id) }
        }
        for at in layout.audioTracks {
            if let seg = at.segments.first { return .audioClip(trackID: at.id, clipID: seg.id) }
        }
        return nil
    }

    func splitSelectedAtPlayhead(app: Studio, playback: MultitrackPlaybackController) {
        playback.pause()
        let time = playback.playhead
        if let newSel = app.splitMultitrackClip(at: time, selection: selection) {
            selection = newSel
            previewMode = .timeline
            let updated = app.currentMultitrackLayout()
            playback.syncLayout(updated)
            playback.seek(to: time, exact: true)
        }
    }

    func deleteSelected(app: Studio, playback: MultitrackPlaybackController) {
        guard let current = selection else { return }
        playback.pause()
        let nextSel = app.deleteMultitrackSelection(current, ripple: rippleDelete)
        selection = nextSel
        let updated = app.currentMultitrackLayout()
        reconcileSelection(with: updated)
        playback.syncLayout(updated)
    }

    func insertFreezeAtPlayhead(app: Studio, playback: MultitrackPlaybackController) {
        playback.pause()
        let time = playback.playhead
        if let newSel = app.insertFreezeFrame(at: time, selection: selection) {
            selection = newSel
            previewMode = .timeline
            let updated = app.currentMultitrackLayout()
            playback.syncLayout(updated)
            playback.seek(to: time, exact: true)
        }
    }
}

// MARK: - Left Multi-Category Library Panel (Concat-Style Darkroom)

struct MultitrackLibraryPanel: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    @StateObject private var libraryInteraction = LibraryInteractionState()

    private var layout: MultitrackLayout {
        app.currentMultitrackLayout()
    }

    var body: some View {
        GeometryReader { panelGeo in
            let availW = max(160, panelGeo.size.width)
            VStack(spacing: 0) {
                categoryTabBar
                    .frame(width: availW)
                Divider().overlay(.white.opacity(0.08))
                librarySearchBar
                    .frame(width: availW)
                Divider().overlay(.white.opacity(0.06))
                Group {
                    switch state.libraryTab {
                    case .media:
                        mediaLibraryTab
                    case .text:
                        textAndShapesLibraryTab
                    case .transitions:
                        transitionsLibraryTab
                    case .filters:
                        ProVisualEffectsLibraryTab(
                            app: app,
                            state: state,
                            playback: playback,
                            searchQuery: state.librarySearchQuery
                        )
                    case .audioVoice:
                        AudioAndVoiceoverLibraryTab(
                            app: app,
                            state: state,
                            playback: playback,
                            searchQuery: state.librarySearchQuery
                        )
                    case .aiTools:
                        AIToolsStudioTab(
                            app: app,
                            state: state,
                            playback: playback,
                            searchQuery: state.librarySearchQuery
                        )
                    }
                }
                .frame(width: availW, alignment: .topLeading)
                .frame(maxHeight: .infinity)
                .clipped()
            }
            .frame(width: availW, height: max(120, panelGeo.size.height), alignment: .topLeading)
            .clipped()
        }
        .background(panel)
    }

    private var librarySearchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("搜尋角色、特效、音效…", text: $state.librarySearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(minWidth: 24, maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("搜尋配音角色與素材特效")
            if !state.librarySearchQuery.isEmpty {
                Button {
                    state.librarySearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mtDarkWell.opacity(0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var textAndShapesLibraryTab: some View {
        GeometryReader { geo in
            let availW = max(160, geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ShapesLibrarySectionView(
                        app: app,
                        state: state,
                        playback: playback,
                        searchQuery: state.librarySearchQuery
                    )
                    Divider().overlay(.white.opacity(0.08))
                    textPresetsTab
                }
                .frame(width: availW, alignment: .leading)
                .clipped()
            }
            .frame(width: availW, alignment: .topLeading)
        }
    }

    // MARK: Top 5-Tab Bar

    private var categoryTabBar: some View {
        HStack(spacing: 2) {
            ForEach(MultitrackLibraryTab.allCases) { tab in
                let active = state.libraryTab == tab
                Button {
                    state.libraryTab = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 11, weight: active ? .semibold : .regular))
                        Text(tab.title)
                            .font(.system(size: 9.5, weight: active ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? mtCyanAccent : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(active ? mtCyanAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.control, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if active {
                            Capsule()
                                .fill(mtCyanAccent)
                                .frame(height: 2)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(mtDarkWell)
    }

    // MARK: Tab 1 — Shared Media Library (2-Column Dense Grid)

    private var mediaLibraryTab: some View {
        let batch = app.libraryBatchSelection
        return GeometryReader { geo in
            let availW = max(160, geo.size.width)
            VStack(alignment: .leading, spacing: 0) {
                // Compact Header + Actions
                HStack(spacing: 5) {
                    Text("素材庫")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(app.project.media.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(surface, in: Capsule())
                    Spacer(minLength: 2)

                    if batch != nil {
                        Button("完成") { app.libraryBatchSelection = nil }
                            .controlSize(.mini)
                    } else {
                        Button("多選") { app.libraryBatchSelection = [] }
                            .controlSize(.mini)
                            .disabled(app.project.media.isEmpty)
                            .help("勾選多個項目後一起從素材庫移除")
                        Button { app.importMedia() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(mtCyanAccent)
                        .foregroundStyle(canvas)
                        .help("匯入影片、圖片或音訊素材")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: availW, alignment: .leading)

                // Default Storage Folder Strip
                HStack(spacing: 5) {
                    Button {
                        app.openOutputDirectory(app.defaultOutputDirectory)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                            Text((app.defaultOutputDirectory.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("開啟預設儲存位置：\(app.defaultOutputDirectory.path)")

                    Spacer(minLength: 2)

                    Menu {
                        Button("開啟預設位置") {
                            app.openOutputDirectory(app.defaultOutputDirectory)
                        }
                        Button("開啟今日成品") {
                            app.openOutputDirectory(datedDirectory(under: app.defaultOutputDirectory))
                        }
                        Divider()
                        Button("更改預設位置…", action: app.chooseDefaultOutputDirectory)
                        if app.defaultOutputPath != nil {
                            Button("恢復原始位置", action: app.resetDefaultOutputDirectory)
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                    .help("預設儲存位置設定")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .frame(width: availW, alignment: .leading)

                Divider().overlay(.white.opacity(0.06))

                if app.project.media.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("尚無素材")
                            .font(.caption.weight(.medium))
                        Text("直接拖曳影片、圖片或音檔至此，或按下方按鈕匯入。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("匯入素材…", action: app.importMedia)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .tint(mtCyanAccent)
                            .foregroundStyle(canvas)
                    }
                    .padding(14)
                    .frame(width: availW)
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .frame(minWidth: availW, minHeight: max(180, geo.size.height - 110))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if app.libraryBatchSelection != nil {
                                        app.libraryBatchSelection = nil
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 5, coordinateSpace: .named("kliporaEditLibrarySpace"))
                                        .onChanged { value in
                                            libraryInteraction.updateMarquee(value: value, app: app)
                                        }
                                        .onEnded { _ in
                                            libraryInteraction.endMarquee(app: app)
                                        }
                                )

                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                ForEach(app.project.media, id: \.self) { path in
                                    mediaGridTile(path: path, batch: batch)
                                }
                            }
                            .padding(9)
                            .frame(width: availW, alignment: .leading)

                            LibraryMarqueeBoxOverlay(rect: libraryInteraction.marqueeRect)
                        }
                        .coordinateSpace(name: "kliporaEditLibrarySpace")
                        .onPreferenceChange(LibraryItemFramePreferenceKey.self) { frames in
                            libraryInteraction.itemFrames = frames
                        }
                    }
                    .frame(width: availW, alignment: .topLeading)
                }

                if let batch {
                    Divider().overlay(.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("已選 \(batch.count) 項")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(batch.count == app.project.media.count && !batch.isEmpty ? "取消全選" : "全選") {
                                app.libraryBatchSelection = batch.count == app.project.media.count
                                    ? [] : Set(app.project.media)
                            }
                            .controlSize(.mini)
                        }
                        HStack(spacing: 6) {
                            Button {
                                let ordered = app.project.media.filter { batch.contains($0) }
                                for path in ordered {
                                    addMediaPathToActiveTrack(path)
                                }
                            } label: {
                                Text("加入軌道")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .tint(mtCyanAccent)
                            .foregroundStyle(canvas)
                            .disabled(batch.isEmpty || app.busy)

                            Button(role: .destructive) {
                                app.removeFromLibrary(batch)
                            } label: {
                                Text("移除所選")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
                            .disabled(batch.isEmpty)
                            .help("只從此專案的素材庫移除，保留磁碟上的檔案")
                        }
                    }
                    .padding(8)
                    .frame(width: availW, alignment: .leading)
                    .background(mtDarkWell)
                } else if !app.editSelection.isEmpty {
                    Divider().overlay(.white.opacity(0.08))
                    let ext = URL(fileURLWithPath: app.editSelection).pathExtension.lowercased()
                    HStack(spacing: 6) {
                        Button {
                            state.previewMode = state.previewMode == .source ? .timeline : .source
                        } label: {
                            Label(state.previewMode == .source ? "回時間軸" : "檢視原檔", systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.mini)

                        Button {
                            addMediaPathToActiveTrack(app.editSelection)
                        } label: {
                            Label("加入軌道", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(mtCyanAccent)
                        .foregroundStyle(canvas)
                        .disabled(app.busy || !multitrackMediaTypes.contains(ext))
                    }
                    .padding(7)
                    .frame(width: availW, alignment: .leading)
                    .background(mtDarkWell)
                }
            }
            .frame(width: availW, height: max(120, geo.size.height), alignment: .topLeading)
            .clipped()
            .overlay { LibraryDropHighlightOverlay(isTargeted: libraryInteraction.isDropTargeted) }
            .dropDestination(for: URL.self) { urls, _ in
                libraryInteraction.isDropTargeted = false
                return app.importDroppedMediaURLs(urls, selectingIn: .edit)
            } isTargeted: { targeted in
                libraryInteraction.isDropTargeted = targeted
            }
        }
    }

    private func mediaGridTile(path: String, batch: Set<String>?) -> some View {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let isAudio = audioTypes.contains(ext)
        let isImage = imageTypes.contains(ext)
        let isSelected = batch?.contains(path) ?? (app.editSelection == path)
        let dur = app.timelineDurations[path] ?? app.sourceDuration(for: path)

        return VStack(alignment: .leading, spacing: 3) {
            ZStack {
                if isAudio {
                    ZStack {
                        mtAudioFill
                        Image(systemName: "waveform")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(mtAudioAccent)
                    }
                    .frame(height: 64)
                } else {
                    MediaThumbnail(path: path, width: 120, height: 64, reloadToken: app.mediaReloadToken)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .clipped()
                }

                // Top-left type badge / batch checkbox
                VStack {
                    HStack {
                        if let batch {
                            Image(systemName: batch.contains(path) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(batch.contains(path) ? mtCyanAccent : .white.opacity(0.85))
                                .padding(3)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text(isAudio ? "音" : (isImage ? "圖" : "影"))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    (isAudio ? mtAudioAccent : (isImage ? mtStillAccent : mtVideoAccent)).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 3)
                                )
                        }
                        Spacer()
                        if batch == nil && multitrackMediaTypes.contains(ext) {
                            Button {
                                addMediaPathToActiveTrack(path)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(canvas)
                                    .frame(width: 17, height: 17)
                                    .background(mtCyanAccent, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(app.busy)
                            .help("加入目前作用中軌道")
                        }
                    }
                    Spacer()
                    if let dur, dur > 0 {
                        HStack {
                            Spacer()
                            Text(formatCompactDuration(dur))
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(mtDarkWell)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(4)
        .background(isSelected ? mtCyanAccent.opacity(0.16) : surface.opacity(0.55), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? mtCyanAccent : .white.opacity(0.07), lineWidth: isSelected ? 1.2 : 0.8)
        )
        .contentShape(Rectangle())
        .background(
            GeometryReader { itemGeo in
                Color.clear.preference(
                    key: LibraryItemFramePreferenceKey.self,
                    value: [path: itemGeo.frame(in: .named("kliporaEditLibrarySpace"))]
                )
            }
        )
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                var selected = app.libraryBatchSelection ?? []
                if selected.contains(path) { selected.remove(path) }
                else { selected.insert(path) }
                app.libraryBatchSelection = selected.isEmpty ? nil : selected
            } else if var selected = app.libraryBatchSelection {
                if selected.contains(path) { selected.remove(path) }
                else { selected.insert(path) }
                app.libraryBatchSelection = selected
            } else {
                app.editSelection = path
                app.selection = path
            }
        }
        .onTapGesture(count: 2) {
            if app.libraryBatchSelection == nil {
                addMediaPathToActiveTrack(path)
            }
        }
        .modifier(ConditionalLibraryDragModifier(enabled: batch == nil, url: url, onMarqueeChanged: { value in
            libraryInteraction.updateMarquee(value: value, app: app)
        }, onMarqueeEnded: {
            libraryInteraction.endMarquee(app: app)
        }))
        .contextMenu {
            if multitrackMediaTypes.contains(ext) {
                Button(isAudio ? "加入音訊軌" : "加入時間軸") {
                    addMediaPathToActiveTrack(path)
                }.disabled(app.busy)
                Button("檢視素材原檔") {
                    app.editSelection = path
                    state.previewMode = .source
                }
            }
            if (app.takesReference && imageTypes.contains(ext)) || (app.acceptsVideoReference && movieTypes.contains(ext)) {
                Button("加入生成參考") { app.attachReference(url) }.disabled(app.busy)
            }
            if app.project.kind == "video", app.usesMultiFrames, imageTypes.contains(ext) {
                Button("加入多影格") { app.addKeyframes([url]) }
                    .disabled(app.busy || app.orderedFrames.count >= Studio.maxKeyframes)
            }
            if let settings = app.recordedGeneration(for: path) {
                Button("載入原生成設定") { app.restoreGeneration(settings) }.disabled(app.busy)
            }
            Divider()
            Button("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("從素材庫移除", role: .destructive) { app.removeFromLibrary([path]) }
        }
        .help("\(filename(path))（雙擊或點 + 加入軌道，或直接拖曳至時間軸）")
    }

    private func addMediaPathToActiveTrack(_ path: String) {
        let target = state.preferredTargetTrackID(for: path, in: app.activeMultitrack)
        if let sel = app.addMediaToMultitrack(path, targetTrackID: target) {
            state.selection = sel
            state.previewMode = .timeline
            playback.syncLayout(app.currentMultitrackLayout())
        }
    }

    private func formatCompactDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: Tab 2 — Traditional Chinese Text Style Presets + SRT

    private var textPresetsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("繁中文字樣式")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("匯入 SRT") {
                    let target = state.preferredTextTrackID(in: app.activeMultitrack)
                    app.importSRTFile(to: target) { sel in
                        state.selection = sel
                        state.previewMode = .timeline
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
                }
                .controlSize(.mini)
                .disabled(app.busy)

                Button("匯出") {
                    app.exportSRTFile(from: state.preferredTextTrackID(in: app.activeMultitrack))
                }
                .controlSize(.mini)
                .disabled(app.busy || layout.textTracks.allSatisfy(\.segments.isEmpty))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider().overlay(.white.opacity(0.06))

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(TextStylePreset.presets) { preset in
                        Button {
                            let target = state.preferredTextTrackID(in: app.activeMultitrack)
                            if let sel = app.addStyledTextClip(preset, at: playback.playhead, trackID: target) {
                                state.selection = sel
                                state.previewMode = .timeline
                                playback.syncLayout(app.currentMultitrackLayout())
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(mtDarkWell)
                                    Text(preset.sampleText.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(MultitrackColorHex.color(from: preset.textColorHex, fallback: .white))
                                        .lineLimit(1)
                                        .padding(.horizontal, preset.backgroundEnabled ? 8 : 4)
                                        .padding(.vertical, preset.backgroundEnabled ? 3 : 1)
                                        .background {
                                            if preset.backgroundEnabled {
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(MultitrackColorHex.color(
                                                        from: preset.backgroundColorHex,
                                                        opacity: preset.backgroundOpacity,
                                                        fallback: .black
                                                    ))
                                            }
                                        }
                                        .shadow(color: preset.shadowEnabled ? .black : .clear, radius: 1.5, x: 0, y: 1)
                                }
                                .frame(height: 36)

                                HStack {
                                    Text(preset.name)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text("\(Int(preset.fontSize))pt · 點擊加入")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(6)
                            .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(app.busy)
                    }
                }
                .padding(7)
            }
        }
    }

    // MARK: Tab 3 — 14 Animated Transition Cards

    private var transitionsLibraryTab: some View {
        let targetJ = state.targetJunction(in: layout, playhead: playback.playhead)
        let activeKind = targetJ?.transition?.kind ?? "cut"

        return GeometryReader { geo in
            let availW = max(160, geo.size.width)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text("14 種轉場效果")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if let j = targetJ, !j.isCut {
                            Button("硬切") {
                                app.setMultitrackTransition(
                                    trackID: j.trackID,
                                    after: j.afterID,
                                    before: j.beforeID,
                                    kind: "cut",
                                    seconds: 0
                                )
                                playback.syncLayout(app.currentMultitrackLayout())
                            }
                            .controlSize(.mini)
                            .disabled(app.busy)
                        }
                    }

                    // Target seam status + duration chips
                    HStack(spacing: 4) {
                        if let j = targetJ {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                                .foregroundStyle(mtCyanAccent)
                            Text("目標接縫 \(TimelineLayout.formatTimecode(j.seamTime))")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("請先於同軌放置相鄰片段")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                    }

                    HStack(spacing: 4) {
                        Text("秒數")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        ForEach([0.3, 0.5, 1.0, 1.5], id: \.self) { sec in
                            let currentDur = targetJ?.transition?.seconds ?? state.transitionDefaultSeconds
                            let isCur = abs(currentDur - sec) < 0.05
                            Button(String(format: "%.1fs", sec)) {
                                state.transitionDefaultSeconds = sec
                                if let j = targetJ, !j.isCut, let kind = j.transition?.kind {
                                    app.setMultitrackTransition(
                                        trackID: j.trackID,
                                        after: j.afterID,
                                        before: j.beforeID,
                                        kind: kind,
                                        seconds: sec
                                    )
                                    playback.syncLayout(app.currentMultitrackLayout())
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5, weight: isCur ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(isCur ? canvas : .white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isCur ? mtCyanAccent : surface, in: RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer(minLength: 2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: availW, alignment: .leading)

                Divider().overlay(.white.opacity(0.06))

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(TimelineTransitionKind.allCases) { kind in
                            let isSel = (targetJ != nil && !(targetJ?.isCut ?? true) && activeKind == kind.rawValue)
                            Button {
                                applyTransitionFromLibrary(kind: kind)
                            } label: {
                                TransitionCardAnimatedPreview(
                                    kindRaw: kind.rawValue,
                                    title: kind.displayName,
                                    isSelected: isSel
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(app.busy)
                            .draggable("md-transition:\(kind.rawValue)")
                            .help("點選套用「\(kind.displayName)」至目標接縫，或直接拖曳到時間軸接縫")
                        }
                    }
                    .padding(7)
                    .frame(width: availW, alignment: .leading)
                    .clipped()
                }
                .frame(width: availW, alignment: .topLeading)
            }
            .frame(width: availW, height: max(120, geo.size.height), alignment: .topLeading)
            .clipped()
        }
    }

    private func applyTransitionFromLibrary(kind: TimelineTransitionKind) {
        guard let j = state.targetJunction(in: layout, playhead: playback.playhead) else {
            app.status = "請先在同一影片軌放置至少兩段相鄰片段，再套用轉場。"
            return
        }
        let sec = j.transition?.seconds ?? state.transitionDefaultSeconds
        app.setMultitrackTransition(
            trackID: j.trackID,
            after: j.afterID,
            before: j.beforeID,
            kind: kind.rawValue,
            seconds: sec
        )
        state.selection = .transition(trackID: j.trackID, afterID: j.afterID, beforeID: j.beforeID)
        state.previewMode = .timeline
        let updated = app.currentMultitrackLayout()
        playback.syncLayout(updated)
        if let updatedJ = updated.junction(trackID: j.trackID, afterID: j.afterID, beforeID: j.beforeID) {
            playback.pause()
            playback.seek(to: updatedJ.seamTime, exact: true)
        }
    }

    // MARK: Tab 4 — 8 Filter Presets + Green Screen Chroma Key Card

    private var filtersLibraryTab: some View {
        let selectedSeg = state.selectedVideoSegment(in: layout)
        let activePreset = selectedSeg?.clip.filterPreset ?? "none"
        let chromaOn = selectedSeg?.clip.chromaKeyEnabled ?? false

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("濾鏡與去背")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let seg = selectedSeg {
                    Text(filename(seg.clip.path))
                        .font(.system(size: 9.5))
                        .foregroundStyle(mtCyanAccent)
                        .lineLimit(1)
                } else {
                    Text("請先選取影片片段")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider().overlay(.white.opacity(0.06))

            ScrollView {
                VStack(spacing: 8) {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(VideoFilterPreset.allCases) { preset in
                            let isSel = selectedSeg != nil && activePreset == preset.rawValue
                            Button {
                                guard let seg = selectedSeg else {
                                    app.status = "請先在時間軸點選影片片段，再套用濾鏡。"
                                    return
                                }
                                app.updateVideoClipProperties(id: seg.id) { clip in
                                    clip.filterPreset = preset.rawValue
                                    if preset == .none {
                                        clip.brightness = 0
                                        clip.contrast = 1.0
                                        clip.saturation = 1.0
                                        clip.blur = 0
                                        clip.vignette = false
                                    } else if preset == .vignette {
                                        clip.vignette = true
                                    } else if preset == .soft {
                                        clip.blur = max(clip.blur, 3.0)
                                    }
                                }
                                state.inspectorTab = .colorKey
                                app.status = "已套用濾鏡 · \(preset.displayName)"
                            } label: {
                                VStack(spacing: 4) {
                                    ZStack {
                                        LinearGradient(
                                            colors: preset.swatchColors,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        Image(systemName: preset.symbolName)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                    .frame(height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                    Text(preset.displayName)
                                        .font(.system(size: 10, weight: isSel ? .semibold : .medium))
                                        .foregroundStyle(isSel ? mtCyanAccent : .white)
                                        .lineLimit(1)
                                }
                                .padding(4)
                                .background(isSel ? mtCyanAccent.opacity(0.16) : surface.opacity(0.6), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(isSel ? mtCyanAccent : .white.opacity(0.08), lineWidth: isSel ? 1.3 : 0.8)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(app.busy)
                        }
                    }

                    // One-click Green Screen Chroma Key Card
                    Button {
                        guard let seg = selectedSeg else {
                            app.status = "請先在時間軸點選影片片段，再開啟綠幕去背。"
                            return
                        }
                        app.updateVideoClipProperties(id: seg.id) { clip in
                            clip.chromaKeyEnabled.toggle()
                        }
                        state.inspectorTab = .colorKey
                        app.status = chromaOn ? "已關閉綠幕色度去背" : "已啟用綠幕色度去背（右側可微調相似度與柔邊）"
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.and.background.dotted")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(chromaOn ? canvas : Color(red: 0.28, green: 0.90, blue: 0.45))
                                .frame(width: 34, height: 34)
                                .background(
                                    chromaOn ? Color(red: 0.28, green: 0.90, blue: 0.45) : Color(red: 0.10, green: 0.26, blue: 0.15),
                                    in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("綠幕去背（色度鍵）")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(chromaOn ? "已啟用 · 點此關閉或右側微調" : "一鍵去背綠幕／藍幕背景")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(chromaOn ? "開" : "關")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(chromaOn ? canvas : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(chromaOn ? Color(red: 0.28, green: 0.90, blue: 0.45) : mtDarkWell, in: Capsule())
                        }
                        .padding(7)
                        .background(chromaOn ? Color(red: 0.14, green: 0.28, blue: 0.19) : surface.opacity(0.65), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(chromaOn ? Color(red: 0.28, green: 0.90, blue: 0.45) : .white.opacity(0.09), lineWidth: chromaOn ? 1.3 : 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy)
                }
                .padding(7)
            }
        }
    }

    // MARK: Tab 5 — Entry / Exit Animations

    private var animationsLibraryTab: some View {
        let selectedSeg = state.selectedVideoSegment(in: layout)
        let currentAnim = state.animationTargetIsOut
            ? (selectedSeg?.clip.animationOut ?? "none")
            : (selectedSeg?.clip.animationIn ?? "none")
        let currentDur = selectedSeg?.clip.animationDuration ?? 0.4

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("片段進出場動畫")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                Picker("動畫類型", selection: $state.animationTargetIsOut) {
                    Text("進場動畫").tag(false)
                    Text("出場動畫").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                HStack(spacing: 4) {
                    Text("時長")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    ForEach([0.2, 0.4, 0.8, 1.2], id: \.self) { sec in
                        let isCur = abs(currentDur - sec) < 0.05
                        Button(String(format: "%.1fs", sec)) {
                            guard let seg = selectedSeg else { return }
                            app.updateVideoClipProperties(id: seg.id) { $0.animationDuration = sec }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: isCur ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(isCur ? canvas : .white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isCur ? mtCyanAccent : surface, in: RoundedRectangle(cornerRadius: 4))
                        .disabled(selectedSeg == nil || app.busy)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider().overlay(.white.opacity(0.06))

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(ClipAnimationKind.allCases) { anim in
                        let isSel = selectedSeg != nil && currentAnim == anim.rawValue
                        Button {
                            guard let seg = selectedSeg else {
                                app.status = "請先在時間軸點選影片片段，再套用動畫。"
                                return
                            }
                            app.updateVideoClipProperties(id: seg.id) { clip in
                                if state.animationTargetIsOut {
                                    clip.animationOut = anim.rawValue
                                } else {
                                    clip.animationIn = anim.rawValue
                                }
                            }
                            let label = state.animationTargetIsOut ? "出場動畫" : "進場動畫"
                            app.status = "已套用\(label) · \(anim.displayName)"
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: anim.symbolName)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(isSel ? mtCyanAccent : .white.opacity(0.85))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
                                Text(anim.displayName)
                                    .font(.system(size: 10, weight: isSel ? .semibold : .medium))
                                    .foregroundStyle(isSel ? mtCyanAccent : .white)
                                    .lineLimit(1)
                            }
                            .padding(5)
                            .background(isSel ? mtCyanAccent.opacity(0.16) : surface.opacity(0.6), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isSel ? mtCyanAccent : .white.opacity(0.08), lineWidth: isSel ? 1.3 : 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(app.busy)
                    }
                }
                .padding(7)
            }
        }
    }
}

// MARK: - Live Visual Grading & Crop Helpers

private struct CropInsetShape: Shape {
    let top: CGFloat
    let bottom: CGFloat
    let left: CGFloat
    let right: CGFloat

    func path(in rect: CGRect) -> Path {
        let l = min(0.45, max(0, left))
        let r = min(0.45, max(0, right))
        let t = min(0.45, max(0, top))
        let b = min(0.45, max(0, bottom))
        let x = rect.minX + rect.width * l
        let y = rect.minY + rect.height * t
        let w = max(1, rect.width * (1.0 - l - r))
        let h = max(1, rect.height * (1.0 - t - b))
        return Path(CGRect(x: x, y: y, width: w, height: h))
    }
}

private struct ClipLiveAnimationTransform {
    let opacity: Double
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    static func evaluate(clip: VideoClip, seg: VideoSegmentLayout, playhead: Double, canvasSize: CGSize) -> ClipLiveAnimationTransform {
        let local = max(0, playhead - seg.timelineStart)
        let remaining = max(0, seg.timelineEnd - playhead)
        let dur = min(seg.duration * 0.5, max(0.05, clip.animationDuration))

        var opacity = 1.0
        var scale: CGFloat = 1.0
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0

        let inKind = ClipAnimationKind.resolved(clip.animationIn)
        if inKind != .none && local < dur {
            let p = min(1.0, max(0.0, local / dur))
            let eased = 1.0 - pow(1.0 - p, 3.0)
            switch inKind {
            case .none: break
            case .fade:
                opacity *= eased
            case .slideLeft:
                offsetX += CGFloat(1.0 - eased) * canvasSize.width * 0.35
                opacity *= min(1.0, p * 2.0)
            case .slideUp:
                offsetY += CGFloat(1.0 - eased) * canvasSize.height * 0.30
                opacity *= min(1.0, p * 2.0)
            case .zoom:
                scale *= CGFloat(0.72 + 0.28 * eased)
                opacity *= min(1.0, p * 2.0)
            }
        }

        let outKind = ClipAnimationKind.resolved(clip.animationOut)
        if outKind != .none && remaining < dur {
            let p = min(1.0, max(0.0, remaining / dur))
            let eased = 1.0 - pow(1.0 - p, 3.0)
            switch outKind {
            case .none: break
            case .fade:
                opacity *= eased
            case .slideLeft:
                offsetX -= CGFloat(1.0 - eased) * canvasSize.width * 0.35
                opacity *= min(1.0, p * 2.0)
            case .slideUp:
                offsetY -= CGFloat(1.0 - eased) * canvasSize.height * 0.30
                opacity *= min(1.0, p * 2.0)
            case .zoom:
                scale *= CGFloat(1.0 + 0.22 * (1.0 - eased))
                opacity *= min(1.0, p * 2.0)
            }
        }

        return ClipLiveAnimationTransform(opacity: opacity, scale: scale, offsetX: offsetX, offsetY: offsetY)
    }
}

@MainActor private final class CanvasTransformDragState: ObservableObject {
    var originPosX: Double?
    var originPosY: Double?
    var originScale: Double?
    var originFontSize: Double?
}

// MARK: - Multitrack Preview Monitor (Real 14-Transition Cache + Live Compositor + Direct Canvas Transform)

struct MultitrackPreviewMonitor: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    @ObservedObject private var transitionCache = TransitionPreviewCache.shared
    @ObservedObject private var clipEffectCache = ClipEffectPreviewCache.shared
    @ObservedObject private var voiceStore = NativeVoiceWorkspaceStore.shared
    @StateObject private var canvasDrag = CanvasTransformDragState()

    private var layout: MultitrackLayout {
        app.currentMultitrackLayout()
    }

    private var outputPixelSize: CGSize {
        if let pixels = app.timelineOutput.dimensions?.pixels,
           let w = pixels["width"], let h = pixels["height"], w > 0, h > 0 {
            return CGSize(width: CGFloat(w), height: CGFloat(h))
        }
        switch app.timelineOutput.aspect {
        case "9:16": return CGSize(width: 1080, height: 1920)
        case "1:1": return CGSize(width: 1080, height: 1080)
        default: return CGSize(width: 1920, height: 1080)
        }
    }

    private var outputAspectRatio: CGFloat {
        let size = outputPixelSize
        return max(0.1, size.width / max(1, size.height))
    }

    private var outputSpecLabel: String {
        let size = outputPixelSize
        let fps = app.timelineOutput.fps ?? 24
        let vCount = layout.videoTracks.count
        let aCount = layout.audioTracks.count
        let tCount = layout.textTracks.count
        return "\(Int(size.width))×\(Int(size.height)) · \(fps)fps · \(vCount)V/\(aCount)A/\(tCount)T"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if state.libraryTab == .audioVoice && voiceStore.showCentralVoiceWorkspace {
                NativeVoiceCentralWorkspaceView(
                    app: app,
                    state: state,
                    playback: playback
                )
            } else {
                Group {
                    if state.previewMode == .source {
                        sourcePreviewStage
                    } else {
                        timelinePreviewStage
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .padding(.horizontal, 8)

                if state.previewMode == .timeline {
                    transportBar
                } else {
                    sourceBottomBar
                }
            }
        }
        .background(canvas)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            KliporaSegmentedControl(
                options: [(MultitrackPreviewMode.timeline, "時間軸"), (MultitrackPreviewMode.source, "素材原檔")],
                selection: $state.previewMode
            )
            .frame(width: 152)

            Text(outputSpecLabel)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if state.libraryTab == .audioVoice {
                Button {
                    voiceStore.showCentralVoiceWorkspace.toggle()
                } label: {
                    Label(
                        voiceStore.showCentralVoiceWorkspace ? "畫面預覽" : "中央配音工作台",
                        systemImage: voiceStore.showCentralVoiceWorkspace ? "tv" : "waveform.badge.mic"
                    )
                }
                .buttonStyle(KliporaPillButtonStyle(variant: voiceStore.showCentralVoiceWorkspace ? .primary : .secondary, compact: true))
                .accessibilityLabel(voiceStore.showCentralVoiceWorkspace ? "切換至時間軸畫面預覽" : "切換至中央配音工作台")
            }

            if state.previewMode == .source && !app.editSelection.isEmpty {
                Text(filename(app.editSelection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if state.previewMode == .timeline,
                      let activeLayer = playback.activeVideoLayers.last(where: { $0.transitionCacheRequest != nil }),
                      let req = activeLayer.transitionCacheRequest,
                      transitionCache.renderingKeys.contains(req.key) {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                    Text("轉場快取中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(surface.opacity(0.85), in: Capsule())
            } else if state.previewMode == .timeline,
                      let fxLayer = playback.activeVideoLayers.last(where: {
                          if let fx = $0.clipEffectCacheRequest { return clipEffectCache.renderingKeys.contains(fx.key) }
                          return false
                      }),
                      fxLayer.clipEffectCacheRequest != nil {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).scaleEffect(0.75)
                    Text("效果快取中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(surface.opacity(0.85), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var sourcePreviewStage: some View {
        Group {
            if !app.editSelection.isEmpty && isAudioMediaPath(app.editSelection) {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(mtAudioAccent)
                    Text(filename(app.editSelection))
                        .font(.callout.weight(.semibold))
                    if let dur = app.sourceDuration(for: app.editSelection) {
                        Text("音訊長度 · \(TimelineLayout.formatTimecode(dur))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    NativePlayer(path: app.editSelection)
                        .frame(maxWidth: 420, maxHeight: 54)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(mtDarkWell)
            } else {
                MediaSurface(path: app.editSelection)
            }
        }
    }

    private var sourceBottomBar: some View {
        HStack(spacing: 10) {
            Text("素材原檔檢視模式")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !app.editSelection.isEmpty {
                let ext = URL(fileURLWithPath: app.editSelection).pathExtension.lowercased()
                Button("加入時間軸") {
                    let target = state.preferredTargetTrackID(for: app.editSelection, in: app.activeMultitrack)
                    if let sel = app.addMediaToMultitrack(app.editSelection, targetTrackID: target) {
                        state.selection = sel
                        state.previewMode = .timeline
                    }
                }
                .controlSize(.small)
                .disabled(app.busy || !multitrackMediaTypes.contains(ext))
            }
            Button("回到時間軸預覽") { state.previewMode = .timeline }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var timelinePreviewStage: some View {
        ZStack {
            Color(red: 0.039, green: 0.043, blue: 0.055)
            if layout.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(mtCyanAccent)
                        .frame(width: 50, height: 50)
                        .background(surface, in: RoundedRectangle(cornerRadius: 12))
                    Text("多軌時間軸尚無內容")
                        .font(.system(size: 15, weight: .semibold))
                    Text("從左側素材庫點「+」或拖曳影片／圖片／音檔到下方任意軌道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        if !app.editSelection.isEmpty {
                            let ext = URL(fileURLWithPath: app.editSelection).pathExtension.lowercased()
                            if multitrackMediaTypes.contains(ext) {
                                Button("加入所選素材 · \(filename(app.editSelection))") {
                                    let target = state.preferredTargetTrackID(for: app.editSelection, in: app.activeMultitrack)
                                    if let sel = app.addMediaToMultitrack(app.editSelection, targetTrackID: target) {
                                        state.selection = sel
                                    }
                                }
                                .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                            }
                        }
                        Button("新增字幕") {
                            if let sel = app.addTextClip(at: 0, trackID: state.preferredTextTrackID(in: app.activeMultitrack)) {
                                state.selection = sel
                            }
                        }
                        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true))
                    }
                    .padding(.top, 2)
                }
                .padding(16)
            } else {
                GeometryReader { geo in
                    let fitted = fittedSize(in: geo.size, aspect: outputAspectRatio)
                    let scaleToCanvas = fitted.height / max(1, outputPixelSize.height)
                    ZStack {
                        Color.black

                        // 1. Render active video layers from bottom (V1: z=10) to top (Vn: z=10+10n)
                        ForEach(playback.activeVideoLayers) { layer in
                            videoLayerView(layer: layer, canvasSize: fitted)
                                .zIndex(Double(10 + layer.trackIndex * 10))
                        }

                        // 2. Host ALL interactive top overlays (transform boxes, T1..Tn subtitles, status badges, errors)
                        // inside a dedicated AppKit NSHostingView layer with zPosition=1000 so native AVPlayerView
                        // layers (V1/V2 PiP) NEVER visually cover subtitles or intercept mouse clicks/drags.
                        MonitorOverlayHostView(zOrder: 1000, interactive: true) {
                            ZStack {
                                // 2a. Interactive direct-manipulation selection boxes for overlay/selected video clips
                                ForEach(playback.activeVideoLayers) { layer in
                                    if layer.activeJunction == nil {
                                        videoDirectTransformOverlay(layer: layer, canvasSize: fitted)
                                    }
                                }

                                // 2a-bis. Active editable vector/gradient shapes composited above video & below text
                                ForEach(playback.activeShapeClips) { shapeSeg in
                                    ShapeCanvasOverlayView(
                                        seg: shapeSeg,
                                        canvasSize: fitted,
                                        app: app,
                                        state: state,
                                        playback: playback
                                    )
                                }

                                // 2b. Active text/subtitle layers ALWAYS composited above V1..Vn (matching FFmpeg export)
                                ForEach(playback.activeTextClips) { textSeg in
                                    interactiveTextOverlayView(seg: textSeg, canvasSize: fitted, scaleFactor: scaleToCanvas)
                                }

                                // 2c. Permission / load error overlay
                                if let errorText = playback.playbackError {
                                    VStack(spacing: 8) {
                                        Image(systemName: playback.playbackNeedsPermission ? "lock.doc" : "exclamationmark.triangle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(.orange)
                                        Text(playback.playbackNeedsPermission ? "無法讀取素材資料夾" : "無法載入預覽畫面")
                                            .font(.callout.weight(.semibold))
                                        Text(errorText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .frame(maxWidth: 340)
                                        HStack(spacing: 8) {
                                            if playback.playbackNeedsPermission {
                                                Button("授權素材資料夾…") { app.grantMediaFolderAccess() }
                                                    .buttonStyle(.borderedProminent)
                                                    .buttonBorderShape(.capsule)
                                                    .controlSize(.small)
                                            }
                                            Button("重試讀取") { app.retryMediaLoad() }
                                                .buttonStyle(.bordered)
                                                .buttonBorderShape(.capsule)
                                                .controlSize(.small)
                                        }
                                    }
                                    .padding(16)
                                    .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 10))
                                }

                                // 2d. Honest top-right rendering / live chroma-key badge (also above AVPlayerView)
                                VStack {
                                    HStack {
                                        Spacer()
                                        monitorStatusBadge
                                    }
                                    Spacer()
                                }
                                .allowsHitTesting(false)
                            }
                            .frame(width: max(1, fitted.width), height: max(1, fitted.height))
                        }
                        .frame(width: max(1, fitted.width), height: max(1, fitted.height))
                        .zIndex(1000)
                    }
                    .frame(width: max(1, fitted.width), height: max(1, fitted.height))
                    .clipped()
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    .position(x: max(1, geo.size.width) / 2, y: max(1, geo.size.height) / 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var monitorStatusBadge: some View {
        if let activeLayer = playback.activeVideoLayers.last(where: { $0.activeJunction != nil }),
           let req = activeLayer.transitionCacheRequest,
           transitionCache.renderingKeys.contains(req.key) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
                Text(TimelineTransitionKind.label(for: req.kind))
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().strokeBorder(mtCyanAccent.opacity(0.5), lineWidth: 0.8))
            .padding(8)
        } else if let fxLayer = playback.activeVideoLayers.last(where: {
            if let fx = $0.clipEffectCacheRequest { return clipEffectCache.renderingKeys.contains(fx.key) }
            return false
        }), fxLayer.clipEffectCacheRequest != nil {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
                Text(fxLayer.segment.clip.chromaKeyEnabled ? "去背預覽計算中" : "效果預覽計算中")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().strokeBorder(mtCyanAccent.opacity(0.5), lineWidth: 0.8))
            .padding(8)
        } else if let errLayer = playback.activeVideoLayers.last(where: {
            if let fx = $0.clipEffectCacheRequest { return clipEffectCache.errors[fx.key] != nil }
            return false
        }), let fx = errLayer.clipEffectCacheRequest, let errText = clipEffectCache.errors[fx.key] {
            Label("效果快取失敗：\(errText.prefix(28))", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.78), in: Capsule())
                .padding(8)
        } else if let keyedLayer = playback.activeVideoLayers.last(where: {
            $0.segment.clip.chromaKeyEnabled && $0.clipEffectCacheRequest.map { clipEffectCache.isReadyForDisplay(req: $0) } == true
        }), keyedLayer.segment.clip.chromaKeyEnabled {
            Label("色度去背 · 同源即時合成", systemImage: "person.and.background.dotted")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(red: 0.36, green: 0.94, blue: 0.54))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(8)
        }
    }

    @ViewBuilder
    private func videoLayerView(layer: ActiveVideoLayer, canvasSize: CGSize) -> some View {
        let clip = layer.segment.clip
        let layerZ = CGFloat(10 + layer.trackIndex * 10)

        if let req = layer.transitionCacheRequest,
           let junction = layer.activeJunction,
           let tr = junction.transition {
            // Real 14-transition rendering: switch to same-source timeline_render.py cache ONLY after AVPlayer is primed & ready (zero black flash).
            if transitionCache.isPlayerReadyForDisplay(key: req.key),
               let cachedPlayer = transitionCache.player(for: req.key) {
                TimelinePlayerLayerView(player: cachedPlayer, zOrder: layerZ)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .scaleEffect(max(0.05, CGFloat(clip.scale)))
                    .offset(x: CGFloat(clip.posX) * canvasSize.width, y: CGFloat(clip.posY) * canvasSize.height)
                    .opacity(layer.effectiveOpacity)
                    .allowsHitTesting(false)
            } else {
                LiveTransitionCompositorView(
                    kind: tr.kind,
                    progress: layer.transitionProgress,
                    leading: {
                        singleClipSurface(
                            seg: layer.segment,
                            player: playback.player(forVideoTrackID: layer.trackID),
                            canvasSize: canvasSize,
                            zOrder: layerZ
                        )
                    },
                    trailing: {
                        if let trailingSeg = layer.transitionTrailingSegment {
                            singleClipSurface(
                                seg: trailingSeg,
                                player: playback.secondaryPlayer(forVideoTrackID: layer.trackID),
                                canvasSize: canvasSize,
                                zOrder: layerZ + 1
                            )
                        } else {
                            Color.black.frame(width: canvasSize.width, height: canvasSize.height)
                        }
                    }
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(max(0.05, CGFloat(clip.scale)))
                .offset(x: CGFloat(clip.posX) * canvasSize.width, y: CGFloat(clip.posY) * canvasSize.height)
                .opacity(layer.effectiveOpacity)
                .allowsHitTesting(false)
            }
        } else {
            let anim = ClipLiveAnimationTransform.evaluate(
                clip: clip,
                seg: layer.segment,
                playhead: playback.playhead,
                canvasSize: canvasSize
            )
            let kfLocalTime = max(0, playback.playhead - layer.segment.timelineStart)
            let kfScale = KeyframeEvaluator.evaluate(keyframes: clip.keyframes, property: .scale, localTime: kfLocalTime, fallback: clip.scale)
            let kfPosX = KeyframeEvaluator.evaluate(keyframes: clip.keyframes, property: .posX, localTime: kfLocalTime, fallback: clip.posX)
            let kfPosY = KeyframeEvaluator.evaluate(keyframes: clip.keyframes, property: .posY, localTime: kfLocalTime, fallback: clip.posY)
            let kfOpacity = KeyframeEvaluator.evaluate(keyframes: clip.keyframes, property: .opacity, localTime: kfLocalTime, fallback: layer.effectiveOpacity)
            let kfRotationDelta = clip.keyframes.contains(where: { $0.property == KeyframeProperty.rotation.rawValue })
                ? (KeyframeEvaluator.evaluate(keyframes: clip.keyframes, property: .rotation, localTime: kfLocalTime, fallback: clip.rotation) - clip.rotation)
                : 0.0
            let blend = VideoBlendMode.resolved(clip.blendMode)
            Group {
                if let fxReq = layer.clipEffectCacheRequest,
                   clipEffectCache.isReadyForDisplay(req: fxReq) {
                    // Same-source FFmpeg processed clip preview: exact crop-then-rescale,
                    // warm/cool/vintage/bw/vivid/soft/vignette, speed/reverse/freeze, and
                    // real alpha transparency for green-screen chromaKey / masks!
                    switch fxReq.alphaMode {
                    case .rgbaPNG:
                        if let keyedImg = clipEffectCache.image(for: fxReq.key) {
                            MonitorOverlayHostView(zOrder: layerZ, interactive: false) {
                                Image(nsImage: keyedImg)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: canvasSize.width, height: canvasSize.height)
                            }
                            .frame(width: canvasSize.width, height: canvasSize.height)
                        } else {
                            singleClipSurface(
                                seg: layer.segment,
                                player: playback.player(forVideoTrackID: layer.trackID),
                                canvasSize: canvasSize,
                                zOrder: layerZ
                            )
                        }
                    case .stackedAlphaMP4:
                        if let cachedPlayer = clipEffectCache.player(for: fxReq),
                           let output = clipEffectCache.videoOutput(for: fxReq.key) {
                            TimelineAlphaStackedPlayerView(
                                player: cachedPlayer,
                                videoOutput: output,
                                localTime: layer.clipLocalTime,
                                isPlaying: playback.isPlaying,
                                zOrder: layerZ
                            )
                            .frame(width: canvasSize.width, height: canvasSize.height)
                        } else {
                            singleClipSurface(
                                seg: layer.segment,
                                player: playback.player(forVideoTrackID: layer.trackID),
                                canvasSize: canvasSize,
                                zOrder: layerZ
                            )
                        }
                    case .opaqueMP4:
                        if let cachedPlayer = clipEffectCache.player(for: fxReq) {
                            TimelinePlayerLayerView(player: cachedPlayer, zOrder: layerZ)
                                .frame(width: canvasSize.width, height: canvasSize.height)
                        } else {
                            singleClipSurface(
                                seg: layer.segment,
                                player: playback.player(forVideoTrackID: layer.trackID),
                                canvasSize: canvasSize,
                                zOrder: layerZ
                            )
                        }
                    }
                } else {
                    singleClipSurface(
                        seg: layer.segment,
                        player: playback.player(forVideoTrackID: layer.trackID),
                        canvasSize: canvasSize,
                        zOrder: layerZ
                    )
                }
            }
            .rotationEffect(.degrees(kfRotationDelta))
            .scaleEffect(max(0.05, CGFloat(kfScale)) * anim.scale)
            .offset(
                x: CGFloat(kfPosX) * canvasSize.width + anim.offsetX,
                y: CGFloat(kfPosY) * canvasSize.height + anim.offsetY
            )
            .opacity(min(1.0, max(0.0, kfOpacity)) * anim.opacity)
            .blendMode(blend.swiftUIBlendMode)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func singleClipSurface(seg: VideoSegmentLayout, player: AVPlayer, canvasSize: CGSize, zOrder: CGFloat) -> some View {
        let clip = seg.clip
        let preset = VideoFilterPreset.resolved(clip.filterPreset)

        let combinedBrightness: Double = {
            var b = clip.brightness
            if preset == .warm { b += 0.03 }
            if preset == .vintage { b += 0.04 }
            return min(0.6, max(-0.6, b))
        }()
        let combinedContrast: Double = {
            var c = clip.contrast
            switch preset {
            case .bw: c *= 1.25
            case .vintage: c *= 0.88
            case .vivid: c *= 1.12
            case .cool: c *= 1.06
            default: break
            }
            return min(2.4, max(0.3, c))
        }()
        let combinedSaturation: Double = {
            switch preset {
            case .bw: return 0.0
            case .vintage: return clip.saturation * 0.65
            case .vivid: return clip.saturation * 1.40
            case .cool: return clip.saturation * 0.90
            case .warm: return clip.saturation * 1.12
            default: return clip.saturation
            }
        }()
        let combinedBlur = max(0, clip.blur + (preset == .soft && clip.blur < 0.1 ? 2.8 : 0))
        let showVignette = clip.vignette || preset == .vignette

        ZStack {
            if playback.missingPaths.contains(clip.path) {
                MonitorOverlayHostView(zOrder: zOrder, interactive: false) {
                    ContentUnavailableView("找不到素材", systemImage: "exclamationmark.triangle", description: Text(filename(clip.path)))
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
            } else if clip.still {
                if let img = playback.stillImages[clip.path] {
                    MonitorOverlayHostView(zOrder: zOrder, interactive: false) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: canvasSize.width, height: canvasSize.height)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                }
            } else {
                TimelinePlayerLayerView(player: player, zOrder: zOrder)
                    .frame(width: canvasSize.width, height: canvasSize.height)
            }

            // Preset color wash
            if preset == .warm {
                Color(red: 1.0, green: 0.62, blue: 0.28).opacity(0.14).blendMode(.overlay)
            } else if preset == .cool {
                Color(red: 0.22, green: 0.56, blue: 1.0).opacity(0.16).blendMode(.overlay)
            } else if preset == .vintage {
                Color(red: 0.72, green: 0.54, blue: 0.34).opacity(0.22).blendMode(.softLight)
            }

            if showVignette {
                RadialGradient(
                    colors: [.clear, .clear, .black.opacity(0.68)],
                    center: .center,
                    startRadius: min(canvasSize.width, canvasSize.height) * 0.22,
                    endRadius: max(canvasSize.width, canvasSize.height) * 0.68
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .brightness(combinedBrightness)
        .contrast(combinedContrast)
        .saturation(combinedSaturation)
        .blur(radius: combinedBlur)
        .clipShape(CropInsetShape(
            top: CGFloat(clip.cropTop),
            bottom: CGFloat(clip.cropBottom),
            left: CGFloat(clip.cropLeft),
            right: CGFloat(clip.cropRight)
        ))
        .scaleEffect(x: clip.flipH ? -1 : 1, y: clip.flipV ? -1 : 1)
        .rotationEffect(.degrees(clip.rotation))
    }

    // MARK: Concat-Style Direct On-Canvas Bounding Box & Corner Handles

    @ViewBuilder
    private func videoDirectTransformOverlay(layer: ActiveVideoLayer, canvasSize: CGSize) -> some View {
        let clip = layer.segment.clip
        let isSelected = state.selection == .videoClip(trackID: layer.trackID, clipID: layer.segment.id)
        let isOverlayOrScaled = layer.trackIndex > 0
            || abs(clip.scale - 1.0) > 0.01
            || abs(clip.posX) > 0.01
            || abs(clip.posY) > 0.01

        if isOverlayOrScaled || isSelected {
            let boxW = max(24, canvasSize.width * CGFloat(max(0.08, clip.scale)))
            let boxH = max(24, canvasSize.height * CGFloat(max(0.08, clip.scale)))
            let centerX = canvasSize.width * 0.5 + CGFloat(clip.posX) * canvasSize.width
            let centerY = canvasSize.height * 0.5 + CGFloat(clip.posY) * canvasSize.height
            let locked = layout.videoTracks.first(where: { $0.id == layer.trackID })?.track.locked ?? false

            ZStack {
                // Click/drag interior to select & move posX/posY
                Rectangle()
                    .fill(.white.opacity(0.001))
                    .overlay {
                        if isSelected {
                            Rectangle()
                                .strokeBorder(mtCyanAccent, lineWidth: 1.5)
                        }
                    }
                    .onTapGesture {
                        state.selection = .videoClip(trackID: layer.trackID, clipID: layer.segment.id)
                        state.selectActiveTrack(layer.trackID, kind: .video)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { value in
                                guard !app.busy && !locked else { return }
                                if canvasDrag.originPosX == nil {
                                    canvasDrag.originPosX = clip.posX
                                    canvasDrag.originPosY = clip.posY
                                    state.selection = .videoClip(trackID: layer.trackID, clipID: layer.segment.id)
                                    playback.pause()
                                }
                                let bx = canvasDrag.originPosX ?? clip.posX
                                let by = canvasDrag.originPosY ?? clip.posY
                                let nx = min(0.8, max(-0.8, bx + Double(value.translation.width / max(1, canvasSize.width))))
                                let ny = min(0.8, max(-0.8, by + Double(value.translation.height / max(1, canvasSize.height))))
                                app.updateVideoClipProperties(id: layer.segment.id) {
                                    $0.posX = (nx * 1000).rounded() / 1000
                                    $0.posY = (ny * 1000).rounded() / 1000
                                }
                            }
                            .onEnded { _ in
                                canvasDrag.originPosX = nil
                                canvasDrag.originPosY = nil
                            }
                    )

                // Four corner resize handles when selected
                if isSelected && !app.busy && !locked {
                    videoCornerHandle(clip: clip, segID: layer.segment.id, canvasSize: canvasSize, signX: -1, signY: -1)
                        .position(x: 0, y: 0)
                    videoCornerHandle(clip: clip, segID: layer.segment.id, canvasSize: canvasSize, signX: 1, signY: -1)
                        .position(x: boxW, y: 0)
                    videoCornerHandle(clip: clip, segID: layer.segment.id, canvasSize: canvasSize, signX: -1, signY: 1)
                        .position(x: 0, y: boxH)
                    videoCornerHandle(clip: clip, segID: layer.segment.id, canvasSize: canvasSize, signX: 1, signY: 1)
                        .position(x: boxW, y: boxH)
                }
            }
            .frame(width: boxW, height: boxH)
            .position(x: centerX, y: centerY)
        }
    }

    private func videoCornerHandle(
        clip: VideoClip,
        segID: UUID,
        canvasSize: CGSize,
        signX: CGFloat,
        signY: CGFloat
    ) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(mtCyanAccent, lineWidth: 2))
            .frame(width: 11, height: 11)
            .contentShape(Rectangle().size(width: 22, height: 22))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if canvasDrag.originScale == nil {
                            canvasDrag.originScale = clip.scale
                            playback.pause()
                        }
                        let baseScale = canvasDrag.originScale ?? clip.scale
                        let dx = (value.translation.width * signX) / max(1, canvasSize.width)
                        let dy = (value.translation.height * signY) / max(1, canvasSize.height)
                        let delta = Double((dx + dy))
                        let nextScale = min(2.0, max(0.1, baseScale + delta))
                        app.updateVideoClipProperties(id: segID) {
                            $0.scale = (nextScale * 100).rounded() / 100
                        }
                    }
                    .onEnded { _ in
                        canvasDrag.originScale = nil
                    }
            )
    }

    private func interactiveTextOverlayView(seg: TextSegmentLayout, canvasSize: CGSize, scaleFactor: CGFloat) -> some View {
        let clip = seg.clip
        let isSelected = state.selection == .textClip(trackID: seg.trackID, clipID: seg.id)
        let locked = layout.textTracks.first(where: { $0.id == seg.trackID })?.track.locked ?? false
        let scaledFontSize = max(8, CGFloat(clip.fontSize) * scaleFactor)
        let scaledStroke = max(0, CGFloat(clip.strokeWidth) * scaleFactor)
        let padH = max(4, scaledFontSize * 0.36)
        let padV = max(2, scaledFontSize * 0.18)
        let textColor = MultitrackColorHex.color(from: clip.textColorHex, fallback: .white)
        let strokeColor = MultitrackColorHex.color(from: clip.strokeColorHex, fallback: .black)
        let bgColor = MultitrackColorHex.color(from: clip.backgroundColorHex, opacity: clip.backgroundOpacity, fallback: .black)

        let baseFont: Font = {
            if let nsFont = NSFont(name: clip.fontFamily, size: scaledFontSize) {
                return Font(nsFont)
            }
            return .system(size: scaledFontSize, weight: .semibold)
        }()

        let strokeOffsets: [(CGFloat, CGFloat)] = scaledStroke >= 0.4 ? [
            (-scaledStroke, 0), (scaledStroke, 0), (0, -scaledStroke), (0, scaledStroke),
            (-scaledStroke * 0.72, -scaledStroke * 0.72), (scaledStroke * 0.72, -scaledStroke * 0.72),
            (-scaledStroke * 0.72, scaledStroke * 0.72), (scaledStroke * 0.72, scaledStroke * 0.72)
        ] : []

        return ZStack {
            ForEach(Array(strokeOffsets.enumerated()), id: \.offset) { _, offset in
                Text(clip.text)
                    .font(baseFont)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(strokeColor)
                    .offset(x: offset.0, y: offset.1)
            }
            Text(clip.text)
                .font(baseFont)
                .multilineTextAlignment(.center)
                .foregroundStyle(textColor)
        }
        .shadow(
            color: clip.shadowEnabled ? .black.opacity(0.85) : .clear,
            radius: clip.shadowEnabled ? max(1, scaledFontSize * 0.08) : 0,
            x: 0,
            y: clip.shadowEnabled ? max(1, scaledFontSize * 0.05) : 0
        )
        .padding(.horizontal, clip.backgroundEnabled ? padH : 4)
        .padding(.vertical, clip.backgroundEnabled ? padV : 2)
        .background {
            if clip.backgroundEnabled {
                RoundedRectangle(cornerRadius: max(3, scaledFontSize * 0.16))
                    .fill(bgColor)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(mtCyanAccent, lineWidth: 1.5)
                    .overlay(alignment: .topLeading) { textCornerHandle(clip: clip, segID: seg.id, sign: -1, locked: locked).offset(x: -5, y: -5) }
                    .overlay(alignment: .topTrailing) { textCornerHandle(clip: clip, segID: seg.id, sign: 1, locked: locked).offset(x: 5, y: -5) }
                    .overlay(alignment: .bottomLeading) { textCornerHandle(clip: clip, segID: seg.id, sign: -1, locked: locked).offset(x: -5, y: 5) }
                    .overlay(alignment: .bottomTrailing) { textCornerHandle(clip: clip, segID: seg.id, sign: 1, locked: locked).offset(x: 5, y: 5) }
            }
        }
        .frame(maxWidth: canvasSize.width * 0.92)
        .contentShape(Rectangle())
        .onTapGesture {
            state.selection = .textClip(trackID: seg.trackID, clipID: seg.id)
            state.selectActiveTrack(seg.trackID, kind: .text)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard !app.busy && !locked else { return }
                    if canvasDrag.originPosX == nil {
                        canvasDrag.originPosX = clip.posX
                        canvasDrag.originPosY = clip.posY
                        state.selection = .textClip(trackID: seg.trackID, clipID: seg.id)
                        playback.pause()
                    }
                    let bx = canvasDrag.originPosX ?? clip.posX
                    let by = canvasDrag.originPosY ?? clip.posY
                    let nx = min(0.95, max(0.05, bx + Double(value.translation.width / max(1, canvasSize.width))))
                    let ny = min(0.95, max(0.05, by + Double(value.translation.height / max(1, canvasSize.height))))
                    app.updateTextClipProperties(id: seg.id) {
                        $0.posX = (nx * 1000).rounded() / 1000
                        $0.posY = (ny * 1000).rounded() / 1000
                    }
                }
                .onEnded { _ in
                    canvasDrag.originPosX = nil
                    canvasDrag.originPosY = nil
                }
        )
        .position(
            x: CGFloat(min(1, max(0, clip.posX))) * canvasSize.width,
            y: CGFloat(min(1, max(0, clip.posY))) * canvasSize.height
        )
    }

    @ViewBuilder
    private func textCornerHandle(clip: TextClip, segID: UUID, sign: CGFloat, locked: Bool) -> some View {
        if !app.busy && !locked {
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(mtCyanAccent, lineWidth: 1.8))
                .frame(width: 10, height: 10)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if canvasDrag.originFontSize == nil {
                                canvasDrag.originFontSize = clip.fontSize
                                playback.pause()
                            }
                            let baseSize = canvasDrag.originFontSize ?? clip.fontSize
                            let delta = Double((value.translation.width * sign + value.translation.height * 0.4) * 0.35)
                            let nextSize = min(140, max(14, baseSize + delta))
                            app.updateTextClipProperties(id: segID) {
                                $0.fontSize = nextSize.rounded()
                            }
                        }
                        .onEnded { _ in
                            canvasDrag.originFontSize = nil
                        }
                )
        }
    }

    private var transportBar: some View {
        let isEmpty = layout.isEmpty
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(TimelineLayout.formatTimecode(playback.playhead))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mtCyanAccent)
                Text("/")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(TimelineLayout.formatTimecode(layout.totalDuration))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Button { playback.jumpToStart() } label: {
                    Image(systemName: "backward.end.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("跳至開頭（Home）")

                Button { playback.stepFrames(-1) } label: {
                    Image(systemName: "backward.frame.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("上一影格（←）")

                Button {
                    state.previewMode = .timeline
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isEmpty ? .secondary : canvas)
                        .frame(width: 34, height: 24)
                        .background(isEmpty ? surface : mtCyanAccent, in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
                .help(playback.isPlaying ? "暫停（Space）" : "播放（Space）")

                Button { playback.stepFrames(1) } label: {
                    Image(systemName: "forward.frame.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("下一影格（→）")

                Button { playback.jumpToEnd() } label: {
                    Image(systemName: "forward.end.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)
                .help("跳至片尾（End）")
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                let vCnt = playback.activeVideoLayers.count
                let aCnt = playback.activeAudioLayers.count
                let tCnt = playback.activeTextClips.count
                if vCnt + aCnt + tCnt > 0 {
                    Text("\(vCnt)V · \(aCnt)A · \(tCnt)T")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(surface.opacity(0.7), in: Capsule())
                } else {
                    Text("空白區段")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 100, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func fittedSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        let safeW = max(1, container.width - 12)
        let safeH = max(1, container.height - 12)
        let safeAspect = max(0.1, min(10.0, aspect))
        if safeW / safeH > safeAspect {
            return CGSize(width: safeH * safeAspect, height: safeH)
        } else {
            return CGSize(width: safeW, height: safeW / safeAspect)
        }
    }
}

// MARK: - Multitrack Timeline Dock View (Multi-Timeline Tabs + Filmstrips + Waveforms + Transition Capsules)

struct MultitrackTimelineDockView: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController

    private let headerWidth: CGFloat = 152
    private let rulerHeight: CGFloat = 22
    private let textRowHeight: CGFloat = 38
    private let videoRowHeight: CGFloat = 58
    private let audioRowHeight: CGFloat = 46

    private var layout: MultitrackLayout {
        app.currentMultitrackLayout()
    }

    private var snapEnabled: Bool {
        app.activeMultitrack.snapEnabled
    }

    func splitSelectedAtPlayhead() {
        state.splitSelectedAtPlayhead(app: app, playback: playback)
    }

    func deleteSelected() {
        state.deleteSelected(app: app, playback: playback)
    }

    private var visibleShapeTracks: [ShapeTrackLayout] {
        layout.shapeTracks.filter { !$0.segments.isEmpty }
    }

    private var totalLanesHeight: CGFloat {
        let tH = CGFloat(layout.textTracks.count) * (textRowHeight + 1)
        let sH = CGFloat(visibleShapeTracks.count) * (textRowHeight + 1)
        let vH = CGFloat(layout.videoTracks.count) * (videoRowHeight + 1)
        let aH = CGFloat(layout.audioTracks.count) * (audioRowHeight + 1)
        return max(120, tH + sH + vH + aH)
    }

    var body: some View {
        VStack(spacing: 0) {
            sequenceTabsBar
            Divider().overlay(.white.opacity(0.08))
            toolbar
            Divider().overlay(.white.opacity(0.08))
            GeometryReader { outerGeo in
                let canvasViewport = max(240, outerGeo.size.width - headerWidth - 1)
                let pxPerSec = state.pixelsPerSecond
                let displaySeconds = max(layout.totalDuration + 4.0, 12.0)
                let contentWidth = max(canvasViewport, CGFloat(displaySeconds) * pxPerSec + 80)

                ScrollView(.vertical, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        trackHeadersColumn
                            .frame(width: headerWidth)
                        Divider()
                        ScrollView(.horizontal, showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    MultitrackRulerView(
                                        contentWidth: contentWidth,
                                        pixelsPerSecond: pxPerSec,
                                        totalDuration: layout.totalDuration,
                                        onScrub: { targetTime, finished in
                                            state.previewMode = .timeline
                                            playback.pause()
                                            playback.seek(to: targetTime, exact: finished)
                                        }
                                    )
                                    .frame(width: contentWidth, height: rulerHeight)
                                    Divider()

                                    // 1. Text Tracks (topmost)
                                    ForEach(layout.textTracks.reversed()) { tt in
                                        textTrackLane(trackLayout: tt, contentWidth: contentWidth, pxPerSec: pxPerSec)
                                            .frame(width: contentWidth, height: textRowHeight)
                                        Divider().overlay(.white.opacity(0.06))
                                    }

                                    // 1-bis. Shape Tracks (shown whenever shapes exist on timeline)
                                    ForEach(visibleShapeTracks.reversed()) { st in
                                        shapeTrackLane(trackLayout: st, contentWidth: contentWidth, pxPerSec: pxPerSec)
                                            .frame(width: contentWidth, height: textRowHeight)
                                        Divider().overlay(.white.opacity(0.06))
                                    }

                                    // 2. Video Tracks (top overlay -> bottom V1 base)
                                    ForEach(layout.videoTracks.reversed()) { vt in
                                        videoTrackLane(trackLayout: vt, contentWidth: contentWidth, pxPerSec: pxPerSec)
                                            .frame(width: contentWidth, height: videoRowHeight)
                                        Divider().overlay(.white.opacity(0.06))
                                    }

                                    // 3. Audio Tracks
                                    ForEach(layout.audioTracks) { at in
                                        audioTrackLane(trackLayout: at, contentWidth: contentWidth, pxPerSec: pxPerSec)
                                            .frame(width: contentWidth, height: audioRowHeight)
                                        Divider().overlay(.white.opacity(0.06))
                                    }
                                }

                                // Snap guide vertical indicator
                                if let guide = state.activeSnapGuideTime {
                                    let gx = CGFloat(guide) * pxPerSec
                                    Path { p in
                                        p.move(to: CGPoint(x: gx, y: rulerHeight))
                                        p.addLine(to: CGPoint(x: gx, y: rulerHeight + 1 + totalLanesHeight))
                                    }
                                    .stroke(mtSnapYellow, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .allowsHitTesting(false)
                                }

                                // Playhead needle spanning ruler + all lanes
                                MultitrackPlayheadNeedle(
                                    x: CGFloat(playback.playhead) * pxPerSec,
                                    totalHeight: rulerHeight + 1 + totalLanesHeight
                                )
                            }
                            .frame(width: contentWidth, height: rulerHeight + 1 + totalLanesHeight, alignment: .topLeading)
                            .coordinateSpace(name: "mtCanvas")
                        }
                        .background(mtDarkWell)
                    }
                }
                .onAppear { state.viewportWidth = canvasViewport }
                .onChange(of: outerGeo.size.width) { _, newW in
                    state.viewportWidth = max(240, newW - headerWidth - 1)
                }
            }
        }
        .background(panel)
    }

    // MARK: Multi-Timeline Sequence Tab Bar

    private var sequenceTabsBar: some View {
        let sequences = app.timelineSequences
        let activeID = app.activeSequenceID

        return HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(sequences) { seq in
                        let isActive = seq.id == activeID
                        let isRenaming = state.editingSequenceRenameID == seq.id

                        HStack(spacing: 4) {
                            Image(systemName: "timeline.selection")
                                .font(.system(size: 9))
                                .foregroundStyle(isActive ? mtCyanAccent : .secondary)

                            if isRenaming {
                                TextField("時間軸名稱", text: $state.sequenceRenameDraft)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .frame(width: 84)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(canvas, in: RoundedRectangle(cornerRadius: 3))
                                    .onSubmit {
                                        app.renameTimelineSequence(seq.id, name: state.sequenceRenameDraft)
                                        state.editingSequenceRenameID = nil
                                    }
                            } else {
                                Text(seq.name)
                                    .font(.system(size: 10.5, weight: isActive ? .semibold : .regular))
                                    .foregroundStyle(isActive ? .white : .secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(isActive ? surface : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(alignment: .bottom) {
                            if isActive {
                                Rectangle().fill(mtCyanAccent).frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isActive {
                                playback.pause()
                                app.selectTimelineSequence(seq.id)
                                let nextLayout = app.currentMultitrackLayout()
                                state.selection = nil
                                state.reconcileSelection(with: nextLayout)
                                playback.syncLayout(nextLayout)
                                playback.seek(to: 0, exact: true)
                            }
                        }
                        .onTapGesture(count: 2) {
                            state.sequenceRenameDraft = seq.name
                            state.editingSequenceRenameID = seq.id
                        }
                        .contextMenu {
                            Button("重新命名") {
                                state.sequenceRenameDraft = seq.name
                                state.editingSequenceRenameID = seq.id
                            }
                            Button("複製此時間軸為新版本") {
                                playback.pause()
                                if !isActive { app.selectTimelineSequence(seq.id) }
                                _ = app.addTimelineSequence(duplicateCurrent: true)
                                let nextLayout = app.currentMultitrackLayout()
                                state.reconcileSelection(with: nextLayout)
                                playback.syncLayout(nextLayout)
                            }
                            Divider()
                            Button("刪除此時間軸", role: .destructive) {
                                playback.pause()
                                app.deleteTimelineSequence(seq.id)
                                let nextLayout = app.currentMultitrackLayout()
                                state.selection = nil
                                state.reconcileSelection(with: nextLayout)
                                playback.syncLayout(nextLayout)
                                playback.seek(to: 0, exact: true)
                            }
                            .disabled(sequences.count <= 1)
                        }
                    }

                    // Add sequence button & menu
                    Menu {
                        Button("新增空白時間軸") {
                            playback.pause()
                            _ = app.addTimelineSequence(duplicateCurrent: false)
                            let nextLayout = app.currentMultitrackLayout()
                            state.selection = nil
                            state.reconcileSelection(with: nextLayout)
                            playback.syncLayout(nextLayout)
                            playback.seek(to: 0, exact: true)
                        }
                        Button("複製目前時間軸版本") {
                            playback.pause()
                            _ = app.addTimelineSequence(duplicateCurrent: true)
                            let nextLayout = app.currentMultitrackLayout()
                            state.reconcileSelection(with: nextLayout)
                            playback.syncLayout(nextLayout)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .disabled(app.busy)
                    .help("新增或複製剪輯版本時間軸")
                }
            }

            Spacer(minLength: 4)

            Text("共 \(sequences.count) 個剪輯版本")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(mtDarkWell)
    }

    // MARK: Compact NLE Toolbar

    private var toolbar: some View {
        HStack(spacing: 5) {
            Button { splitSelectedAtPlayhead() } label: {
                Label("分割", systemImage: "scissors")
            }
            .controlSize(.small)
            .disabled(app.busy || layout.isEmpty)
            .help("在播放頭位置分割目前選取或所在軌道片段（快捷鍵 S）")

            Button { state.insertFreezeAtPlayhead(app: app, playback: playback) } label: {
                Label("定格", systemImage: "camera.metering.center.weighted")
            }
            .controlSize(.small)
            .disabled(app.busy || layout.isEmpty)
            .help("在播放頭位置插入 2.0 秒定格畫面")

            Button { deleteSelected() } label: {
                Label("刪除", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(app.busy || state.selection == nil)
            .help(state.rippleDelete ? "刪除所選片段並自動向左接合（Delete）" : "刪除所選片段並保留空白（Delete）")

            Button {
                state.rippleDelete.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: state.rippleDelete ? "arrow.left.to.line.compact" : "rectangle.split.2x1")
                    Text("自動接合")
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(state.rippleDelete ? mtCyanAccent : .secondary)
            .help("開啟時刪除片段會將同軌後續片段自動向左接合")

            Button {
                app.toggleMultitrackSnap()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "magnet")
                    Text("吸附")
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(snapEnabled ? mtSnapYellow : .secondary)
            .help("拖曳片段時自動吸附到播放頭與其他軌道片段起迄點")

            Divider().frame(height: 14)

            Button("+影片軌") {
                let id = app.addVideoTrack()
                state.selectActiveTrack(id, kind: .video)
            }
            .controlSize(.small)
            .disabled(app.busy)

            Button("+音訊軌") {
                let id = app.addAudioTrack()
                state.selectActiveTrack(id, kind: .audio)
            }
            .controlSize(.small)
            .disabled(app.busy)

            Button("+文字軌") {
                let id = app.addTextTrack()
                state.selectActiveTrack(id, kind: .text)
            }
            .controlSize(.small)
            .disabled(app.busy)

            Button {
                let target = state.preferredTextTrackID(in: app.activeMultitrack)
                if let sel = app.addTextClip(at: playback.playhead, trackID: target) {
                    state.selection = sel
                    state.previewMode = .timeline
                    playback.syncLayout(app.currentMultitrackLayout())
                }
            } label: {
                Label("+字幕", systemImage: "text.bubble")
            }
            .controlSize(.small)
            .disabled(app.busy)

            if let hint = state.dragPreviewHint {
                Text(hint)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(canvas)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(mtCyanAccent, in: Capsule())
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button { state.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Slider(value: $state.pixelsPerSecond, in: MultitrackEditState.minZoom...MultitrackEditState.maxZoom)
                    .frame(width: 78)
                    .controlSize(.small)
                Button { state.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button("適合") { state.fit(totalDuration: layout.totalDuration) }
                    .controlSize(.small)
                    .disabled(layout.isEmpty)
                    .help("縮放至完整檢視所有軌道（快捷鍵 0）")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(panel)
    }

    // MARK: Left Track Headers

    private var trackHeadersColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(app.timelineOutput.fps ?? 24)fps · 軌道")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: rulerHeight)
            .background(canvas.opacity(0.65))
            Divider()

            // Text headers (topmost)
            ForEach(layout.textTracks.reversed()) { tt in
                trackHeaderRow(
                    id: tt.id,
                    kind: .text,
                    badge: "T\(tt.trackIndex + 1)",
                    roleTag: tt.trackIndex == layout.textTracks.count - 1 ? "頂層" : "字幕",
                    name: tt.track.name,
                    accent: mtTextAccent,
                    muted: false,
                    hidden: tt.track.hidden,
                    locked: tt.track.locked,
                    canMute: false,
                    canHide: true,
                    canDelete: true,
                    isActive: state.activeTextTrackID == tt.id,
                    rowHeight: textRowHeight
                )
                Divider().overlay(.white.opacity(0.06))
            }

            // Shape headers (when shapes exist)
            ForEach(visibleShapeTracks.reversed()) { st in
                trackHeaderRow(
                    id: st.id,
                    kind: .shape,
                    badge: "S\(st.trackIndex + 1)",
                    roleTag: "形狀",
                    name: st.track.name,
                    accent: mtCyanAccent,
                    muted: false,
                    hidden: st.track.hidden,
                    locked: st.track.locked,
                    canMute: false,
                    canHide: true,
                    canDelete: true,
                    isActive: state.activeShapeTrackID == st.id,
                    rowHeight: textRowHeight
                )
                Divider().overlay(.white.opacity(0.06))
            }

            // Video headers (top overlay -> V1 bottom base)
            ForEach(layout.videoTracks.reversed()) { vt in
                trackHeaderRow(
                    id: vt.id,
                    kind: .video,
                    badge: "V\(vt.trackIndex + 1)",
                    roleTag: vt.trackIndex == 0 ? "主軌" : "疊加",
                    name: vt.track.name,
                    accent: mtVideoAccent,
                    muted: vt.track.muted,
                    hidden: vt.track.hidden,
                    locked: vt.track.locked,
                    canMute: true,
                    canHide: true,
                    canDelete: layout.videoTracks.count > 1 || !vt.segments.isEmpty,
                    isActive: state.activeVideoTrackID == vt.id,
                    rowHeight: videoRowHeight
                )
                Divider().overlay(.white.opacity(0.06))
            }

            // Audio headers
            ForEach(layout.audioTracks) { at in
                trackHeaderRow(
                    id: at.id,
                    kind: .audio,
                    badge: "A\(at.trackIndex + 1)",
                    roleTag: "音訊",
                    name: at.track.name,
                    accent: mtAudioAccent,
                    muted: at.track.muted,
                    hidden: false,
                    locked: at.track.locked,
                    canMute: true,
                    canHide: false,
                    canDelete: true,
                    isActive: state.activeAudioTrackID == at.id,
                    rowHeight: audioRowHeight
                )
                Divider().overlay(.white.opacity(0.06))
            }
        }
        .background(panel)
    }

    private func trackHeaderRow(
        id: UUID,
        kind: TrackKind,
        badge: String,
        roleTag: String,
        name: String,
        accent: Color,
        muted: Bool,
        hidden: Bool,
        locked: Bool,
        canMute: Bool,
        canHide: Bool,
        canDelete: Bool,
        isActive: Bool,
        rowHeight: CGFloat
    ) -> some View {
        let isEditingName = state.editingTrackRenameID == id

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(badge)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? canvas : accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isActive ? accent : accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))

                if isEditingName {
                    TextField("軌道名稱", text: $state.trackRenameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(canvas, in: RoundedRectangle(cornerRadius: 3))
                        .onSubmit {
                            app.renameTrack(id: id, kind: kind, name: state.trackRenameDraft)
                            state.editingTrackRenameID = nil
                        }
                    Button {
                        app.renameTrack(id: id, kind: kind, name: state.trackRenameDraft)
                        state.editingTrackRenameID = nil
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(mtCyanAccent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(hidden ? Color.secondary : Color.white)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            state.trackRenameDraft = name
                            state.editingTrackRenameID = id
                        }
                }
                Spacer(minLength: 2)
                if !isEditingName {
                    Text(roleTag)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(surface.opacity(0.75), in: Capsule())
                }
            }

            HStack(spacing: 4) {
                if canMute {
                    Button { app.toggleTrackMuted(id: id, kind: kind) } label: {
                        Text("M")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(muted ? canvas : .secondary)
                            .frame(width: 16, height: 14)
                            .background(muted ? Color.orange : surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy)
                    .help(muted ? "取消靜音" : "靜音此軌道")
                }

                if canHide {
                    Button { app.toggleTrackHidden(id: id, kind: kind) } label: {
                        Image(systemName: hidden ? "eye.slash" : "eye")
                            .font(.system(size: 8.5))
                            .foregroundStyle(hidden ? Color.orange : .secondary)
                            .frame(width: 17, height: 14)
                            .background(surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy)
                    .help(hidden ? "顯示此軌道" : "隱藏此軌道")
                }

                Button { app.toggleTrackLocked(id: id, kind: kind) } label: {
                    Image(systemName: locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 8.5))
                        .foregroundStyle(locked ? mtSnapYellow : .secondary)
                        .frame(width: 17, height: 14)
                        .background(surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .disabled(app.busy)
                .help(locked ? "解鎖此軌道" : "鎖定此軌道")

                Spacer(minLength: 2)

                Button {
                    app.deleteTrack(id: id, kind: kind)
                    state.reconcileSelection(with: app.currentMultitrackLayout())
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 8.5))
                        .foregroundStyle(canDelete ? Color.secondary : Color.secondary.opacity(0.3))
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
                .disabled(app.busy || !canDelete)
                .help(kind == .video && layout.videoTracks.count == 1 ? "清空 V1 主軌" : "刪除此軌道")
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
        .background(isActive ? accent.opacity(0.08) : panel)
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectActiveTrack(id, kind: kind)
        }
        .contextMenu {
            Button("重新命名軌道") {
                state.trackRenameDraft = name
                state.editingTrackRenameID = id
            }
            if canMute { Button(muted ? "取消靜音" : "靜音") { app.toggleTrackMuted(id: id, kind: kind) } }
            if canHide { Button(hidden ? "顯示軌道" : "隱藏軌道") { app.toggleTrackHidden(id: id, kind: kind) } }
            Button(locked ? "解鎖軌道" : "鎖定軌道") { app.toggleTrackLocked(id: id, kind: kind) }
            Divider()
            Button(kind == .video && layout.videoTracks.count == 1 ? "清空 V1 片段" : "刪除軌道", role: .destructive) {
                app.deleteTrack(id: id, kind: kind)
                state.reconcileSelection(with: app.currentMultitrackLayout())
            }
            .disabled(!canDelete)
        }
    }

    // MARK: Unified Drop Payload (avoids SwiftUI stacked dropDestination shadowing on macOS)

    private enum MultitrackDropItem: Transferable {
        case fileURL(URL)
        case payload(String)

        static var transferRepresentation: some TransferRepresentation {
            ProxyRepresentation<MultitrackDropItem, URL>(importing: { .fileURL($0) })
            ProxyRepresentation<MultitrackDropItem, String>(importing: { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
                    return .fileURL(url)
                }
                if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) {
                    return .fileURL(URL(fileURLWithPath: trimmed))
                }
                return .payload(trimmed)
            })
        }
    }

    // MARK: Track Lanes

    private func laneGridBackground(pxPerSec: CGFloat) -> some View {
        Canvas { context, size in
            let step = MultitrackRulerView.majorStep(for: pxPerSec)
            let maxSec = Double(size.width / pxPerSec)
            var t = 0.0
            while t <= maxSec {
                let x = CGFloat(t) * pxPerSec
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(0.035)), lineWidth: 1)
                t += step
            }
        }
        .allowsHitTesting(false)
    }

    private func videoTrackLane(trackLayout: VideoTrackLayout, contentWidth: CGFloat, pxPerSec: CGFloat) -> some View {
        let isTargeted = state.dropTargetTrackID == trackLayout.id
        return ZStack(alignment: .leading) {
            laneGridBackground(pxPerSec: pxPerSec)
            if isTargeted {
                Rectangle().fill(mtVideoAccent.opacity(0.10))
            }

            if trackLayout.segments.isEmpty {
                Text(trackLayout.trackIndex == 0 ? "拖曳影片或圖片至此 V1 主軌" : "拖曳疊加素材或畫中畫至此 \(trackLayout.track.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.65))
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }

            // Video clip blocks (with continuous filmstrip thumbnails)
            ForEach(trackLayout.segments) { seg in
                let x = CGFloat(seg.timelineStart) * pxPerSec
                let w = max(8, CGFloat(seg.duration) * pxPerSec)
                MultitrackVideoClipBlock(
                    app: app,
                    state: state,
                    playback: playback,
                    layout: layout,
                    trackLayout: trackLayout,
                    segment: seg,
                    width: w,
                    height: videoRowHeight - 8,
                    pixelsPerSecond: pxPerSec
                )
                .offset(x: x)
            }

            // Same-track transition overlap capsule blocks & cut seam markers
            ForEach(trackLayout.junctions) { junction in
                if !junction.isCut {
                    transitionCapsuleBlock(junction: junction, pxPerSec: pxPerSec)
                } else {
                    cutSeamMarker(junction: junction, pxPerSec: pxPerSec)
                }
            }
        }
        .frame(width: contentWidth, height: videoRowHeight, alignment: .leading)
        .opacity(trackLayout.track.hidden ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .dropDestination(for: MultitrackDropItem.self) { items, location in
            state.dropTargetTrackID = nil
            guard !trackLayout.track.locked else {
                app.status = "軌道 \(trackLayout.track.name) 已鎖定。"
                return false
            }

            let urls: [URL] = items.compactMap {
                if case .fileURL(let url) = $0 { return url }
                return nil
            }
            if !urls.isEmpty {
                let rawTime = max(0, Double(location.x / pxPerSec))
                let dropTime = snapEnabled
                    ? layout.snap(time: rawTime, playhead: playback.playhead, thresholdSeconds: Double(state.snapThresholdPx / pxPerSec)).snapped
                    : rawTime
                if let sel = app.addURLsToMultitrack(urls, targetTrackID: trackLayout.id, at: dropTime) {
                    state.selectActiveTrack(trackLayout.id, kind: .video)
                    state.selection = sel
                    state.previewMode = .timeline
                    playback.syncLayout(app.currentMultitrackLayout())
                    return true
                }
                return false
            }

            guard let payload = items.compactMap({ item -> String? in
                if case .payload(let s) = item { return s }
                return nil
            }).first else { return false }

            // Support dropping a transition card directly onto a video track lane (snaps to nearest seam)
            if payload.hasPrefix("md-transition:") {
                let kindRaw = String(payload.dropFirst("md-transition:".count))
                guard TimelineTransitionKind.supportedRawValues.contains(kindRaw) else { return false }
                let dropSec = max(0, Double(location.x / pxPerSec))
                guard let nearest = trackLayout.junctions.min(by: { abs($0.seamTime - dropSec) < abs($1.seamTime - dropSec) }) else {
                    app.status = "此軌道尚無相鄰影片接縫可套用轉場。"
                    return false
                }
                let sec = nearest.transition?.seconds ?? state.transitionDefaultSeconds
                app.setMultitrackTransition(
                    trackID: nearest.trackID,
                    after: nearest.afterID,
                    before: nearest.beforeID,
                    kind: kindRaw,
                    seconds: sec
                )
                state.selection = .transition(trackID: nearest.trackID, afterID: nearest.afterID, beforeID: nearest.beforeID)
                playback.syncLayout(app.currentMultitrackLayout())
                return true
            }

            // Cross-track clip drag
            guard payload.hasPrefix("md-clip:video:"),
                  let clipID = UUID(uuidString: String(payload.dropFirst("md-clip:video:".count))) else {
                return false
            }
            let rawTime = max(0, Double(location.x / pxPerSec))
            let dropTime = snapEnabled
                ? layout.snap(time: rawTime, playhead: playback.playhead, thresholdSeconds: Double(state.snapThresholdPx / pxPerSec), excludingClipID: clipID).snapped
                : rawTime
            app.moveVideoClip(id: clipID, toStart: dropTime, targetTrackID: trackLayout.id)
            state.selectActiveTrack(trackLayout.id, kind: .video)
            state.selection = .videoClip(trackID: trackLayout.id, clipID: clipID)
            playback.syncLayout(app.currentMultitrackLayout())
            return true
        } isTargeted: { targeted in
            state.dropTargetTrackID = targeted ? trackLayout.id : (state.dropTargetTrackID == trackLayout.id ? nil : state.dropTargetTrackID)
        }
    }

    private func transitionCapsuleBlock(junction: TrackJunctionLayout, pxPerSec: CGFloat) -> some View {
        let startX = CGFloat(junction.overlapStart) * pxPerSec
        let overlapW = CGFloat(junction.overlapDuration) * pxPerSec
        let displayW = max(24, overlapW)
        let centerX = CGFloat(junction.seamTime) * pxPerSec
        let capsuleX = overlapW >= 24 ? startX : (centerX - displayW * 0.5)
        let selTarget = TimelineSelection.transition(trackID: junction.trackID, afterID: junction.afterID, beforeID: junction.beforeID)
        let isSel = state.selection == selTarget
        let kindRaw = junction.transition?.kind ?? "dissolve"
        let sec = junction.transition?.seconds ?? junction.overlapDuration
        let accent: Color = junction.isValid ? mtCyanAccent : .orange
        let labelText = "\(TimelineTransitionKind.label(for: kindRaw)) \(TimelineLayout.formatTrimSeconds(sec))s"

        return Button {
            state.selection = selTarget
            state.previewMode = .timeline
            playback.pause()
            playback.seek(to: junction.seamTime, exact: true)
        } label: {
            ZStack {
                // Full-height subtle translucent overlap band
                RoundedRectangle(cornerRadius: 4)
                    .fill(accent.opacity(isSel ? 0.30 : 0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(accent.opacity(isSel ? 0.95 : 0.65), lineWidth: isSel ? 1.5 : 1)
                    )
                    .frame(width: displayW, height: videoRowHeight - 8)

                // Prominent centered transition pill
                HStack(spacing: 3) {
                    Image(systemName: TimelineTransitionKind.symbol(for: kindRaw))
                        .font(.system(size: 9, weight: .bold))
                    if displayW >= 96 {
                        Text(labelText)
                            .font(.system(size: 9.5, weight: .semibold))
                            .lineLimit(1)
                    } else if displayW >= 48 {
                        Text("\(TimelineLayout.formatTrimSeconds(sec))s")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isSel ? canvas : .white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isSel ? accent : Color(red: 0.08, green: 0.14, blue: 0.19).opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(accent.opacity(0.85), lineWidth: 1))
            }
            .frame(width: displayW, height: videoRowHeight - 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: max(0, capsuleX))
        .help("\(labelText) · 點選調整轉場類型與秒數")
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first, payload.hasPrefix("md-transition:") else { return false }
            let newKind = String(payload.dropFirst("md-transition:".count))
            guard TimelineTransitionKind.supportedRawValues.contains(newKind) else { return false }
            app.setMultitrackTransition(
                trackID: junction.trackID,
                after: junction.afterID,
                before: junction.beforeID,
                kind: newKind,
                seconds: sec
            )
            state.selection = selTarget
            playback.syncLayout(app.currentMultitrackLayout())
            return true
        }
    }

    private func cutSeamMarker(junction: TrackJunctionLayout, pxPerSec: CGFloat) -> some View {
        let x = CGFloat(junction.seamTime) * pxPerSec
        let selTarget = TimelineSelection.transition(trackID: junction.trackID, afterID: junction.afterID, beforeID: junction.beforeID)
        let isSelected = state.selection == selTarget
        let isHovered = state.hoveredJunctionID == junction.id

        return Button {
            state.selection = selTarget
        } label: {
            ZStack {
                if isSelected || isHovered {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? mtCyanAccent : panel.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(mtCyanAccent.opacity(0.75), lineWidth: 1)
                        )
                        .frame(width: 18, height: 18)
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? canvas : mtCyanAccent)
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.24))
                        .frame(width: 3, height: 22)
                }
            }
            .frame(width: 20, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { state.hoveredJunctionID = junction.id }
            else if state.hoveredJunctionID == junction.id { state.hoveredJunctionID = nil }
        }
        .offset(x: x - 10)
        .help("同軌相鄰接縫（硬切）· 點擊或拖入轉場卡片設定 14 種轉場")
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first, payload.hasPrefix("md-transition:") else { return false }
            let newKind = String(payload.dropFirst("md-transition:".count))
            guard TimelineTransitionKind.supportedRawValues.contains(newKind) else { return false }
            app.setMultitrackTransition(
                trackID: junction.trackID,
                after: junction.afterID,
                before: junction.beforeID,
                kind: newKind,
                seconds: state.transitionDefaultSeconds
            )
            state.selection = selTarget
            playback.syncLayout(app.currentMultitrackLayout())
            return true
        }
    }

    private func audioTrackLane(trackLayout: AudioTrackLayout, contentWidth: CGFloat, pxPerSec: CGFloat) -> some View {
        let isTargeted = state.dropTargetTrackID == trackLayout.id
        return ZStack(alignment: .leading) {
            laneGridBackground(pxPerSec: pxPerSec)
            if isTargeted {
                Rectangle().fill(mtAudioAccent.opacity(0.10))
            }
            if trackLayout.segments.isEmpty {
                Text("拖曳 MP3 / WAV / M4A / AAC / FLAC 音檔至此 \(trackLayout.track.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.65))
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }

            ForEach(trackLayout.segments) { seg in
                let x = CGFloat(seg.timelineStart) * pxPerSec
                let w = max(8, CGFloat(seg.duration) * pxPerSec)
                MultitrackAudioClipBlock(
                    app: app,
                    state: state,
                    playback: playback,
                    layout: layout,
                    trackLayout: trackLayout,
                    segment: seg,
                    width: w,
                    height: audioRowHeight - 8,
                    pixelsPerSecond: pxPerSec
                )
                .offset(x: x)
            }
        }
        .frame(width: contentWidth, height: audioRowHeight, alignment: .leading)
        .opacity(trackLayout.track.muted ? 0.52 : 1.0)
        .contentShape(Rectangle())
        .dropDestination(for: MultitrackDropItem.self) { items, location in
            state.dropTargetTrackID = nil
            guard !trackLayout.track.locked else {
                app.status = "音訊軌 \(trackLayout.track.name) 已鎖定。"
                return false
            }

            let urls: [URL] = items.compactMap {
                if case .fileURL(let url) = $0 { return url }
                return nil
            }
            if !urls.isEmpty {
                let rawTime = max(0, Double(location.x / pxPerSec))
                let dropTime = snapEnabled
                    ? layout.snap(time: rawTime, playhead: playback.playhead, thresholdSeconds: Double(state.snapThresholdPx / pxPerSec)).snapped
                    : rawTime
                if let sel = app.addURLsToMultitrack(urls, targetTrackID: trackLayout.id, at: dropTime) {
                    state.selectActiveTrack(trackLayout.id, kind: .audio)
                    state.selection = sel
                    state.previewMode = .timeline
                    playback.syncLayout(app.currentMultitrackLayout())
                    return true
                }
                return false
            }

            guard let payload = items.compactMap({ item -> String? in
                if case .payload(let s) = item { return s }
                return nil
            }).first,
                  payload.hasPrefix("md-clip:audio:"),
                  let clipID = UUID(uuidString: String(payload.dropFirst("md-clip:audio:".count))) else {
                return false
            }
            let rawTime = max(0, Double(location.x / pxPerSec))
            let dropTime = snapEnabled
                ? layout.snap(time: rawTime, playhead: playback.playhead, thresholdSeconds: Double(state.snapThresholdPx / pxPerSec), excludingClipID: clipID).snapped
                : rawTime
            app.moveAudioClip(id: clipID, toStart: dropTime, targetTrackID: trackLayout.id)
            state.selectActiveTrack(trackLayout.id, kind: .audio)
            state.selection = .audioClip(trackID: trackLayout.id, clipID: clipID)
            playback.syncLayout(app.currentMultitrackLayout())
            return true
        } isTargeted: { targeted in
            state.dropTargetTrackID = targeted ? trackLayout.id : (state.dropTargetTrackID == trackLayout.id ? nil : state.dropTargetTrackID)
        }
    }

    private func shapeTrackLane(trackLayout: ShapeTrackLayout, contentWidth: CGFloat, pxPerSec: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            laneGridBackground(pxPerSec: pxPerSec)
            ForEach(trackLayout.segments) { seg in
                let isSelected = state.selection == .shapeClip(trackID: trackLayout.id, clipID: seg.id)
                let x = CGFloat(seg.timelineStart) * pxPerSec
                let w = max(24, CGFloat(seg.duration) * pxPerSec)
                let kindObj = ShapeKind.resolved(seg.clip.kind)
                let title = seg.clip.label.isEmpty ? kindObj.displayName : "\(kindObj.displayName) · \(seg.clip.label)"

                HStack(spacing: 4) {
                    Image(systemName: kindObj.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(mtCyanAccent)
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                }
                .padding(.horizontal, 6)
                .frame(width: w, height: textRowHeight - 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 0.12, green: 0.22, blue: 0.28))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? mtCyanAccent : mtCyanAccent.opacity(0.4), lineWidth: isSelected ? 1.6 : 0.8)
                )
                .offset(x: x)
                .onTapGesture {
                    state.selection = .shapeClip(trackID: trackLayout.id, clipID: seg.id)
                    state.selectActiveTrack(trackLayout.id, kind: .shape)
                    state.previewMode = .timeline
                }
            }
        }
        .frame(width: contentWidth, height: textRowHeight, alignment: .leading)
        .background(trackLayout.track.hidden ? .black.opacity(0.35) : .clear)
    }

    private func textTrackLane(trackLayout: TextTrackLayout, contentWidth: CGFloat, pxPerSec: CGFloat) -> some View {
        let isTargeted = state.dropTargetTrackID == trackLayout.id
        return ZStack(alignment: .leading) {
            laneGridBackground(pxPerSec: pxPerSec)
            if isTargeted {
                Rectangle().fill(mtTextAccent.opacity(0.10))
            }
            if trackLayout.segments.isEmpty {
                Text("從左側「文字」頁一鍵套用樣式，或點「+字幕」建立字幕")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.65))
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }

            ForEach(trackLayout.segments) { seg in
                let x = CGFloat(seg.timelineStart) * pxPerSec
                let w = max(8, CGFloat(seg.duration) * pxPerSec)
                MultitrackTextClipBlock(
                    app: app,
                    state: state,
                    playback: playback,
                    layout: layout,
                    trackLayout: trackLayout,
                    segment: seg,
                    width: w,
                    height: textRowHeight - 6,
                    pixelsPerSecond: pxPerSec
                )
                .offset(x: x)
            }
        }
        .frame(width: contentWidth, height: textRowHeight, alignment: .leading)
        .opacity(trackLayout.track.hidden ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, location in
            state.dropTargetTrackID = nil
            guard !trackLayout.track.locked,
                  let payload = items.first,
                  payload.hasPrefix("md-clip:text:"),
                  let clipID = UUID(uuidString: String(payload.dropFirst("md-clip:text:".count))) else {
                return false
            }
            let rawTime = max(0, Double(location.x / pxPerSec))
            let dropTime = snapEnabled
                ? layout.snap(time: rawTime, playhead: playback.playhead, thresholdSeconds: Double(state.snapThresholdPx / pxPerSec), excludingClipID: clipID).snapped
                : rawTime
            app.moveTextClip(id: clipID, toStart: dropTime, targetTrackID: trackLayout.id)
            state.selectActiveTrack(trackLayout.id, kind: .text)
            state.selection = .textClip(trackID: trackLayout.id, clipID: clipID)
            playback.syncLayout(app.currentMultitrackLayout())
            return true
        } isTargeted: { targeted in
            state.dropTargetTrackID = targeted ? trackLayout.id : (state.dropTargetTrackID == trackLayout.id ? nil : state.dropTargetTrackID)
        }
    }
}

// MARK: - Ruler & Playhead

private struct MultitrackRulerView: View {
    let contentWidth: CGFloat
    let pixelsPerSecond: CGFloat
    let totalDuration: Double
    let onScrub: (Double, Bool) -> Void

    static func majorStep(for pxPerSec: CGFloat) -> Double {
        if pxPerSec >= 100 { return 1.0 }
        if pxPerSec >= 48 { return 1.0 }
        if pxPerSec >= 24 { return 2.0 }
        if pxPerSec >= 14 { return 5.0 }
        return 10.0
    }

    static func minorDivisions(for pxPerSec: CGFloat) -> Int {
        if pxPerSec >= 100 { return 5 }
        if pxPerSec >= 48 { return 2 }
        if pxPerSec >= 24 { return 4 }
        return 5
    }

    private func formatTick(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        let mins = rounded / 60
        let secs = rounded % 60
        return mins > 0 ? String(format: "%d:%02d", mins, secs) : "\(secs)s"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.082, green: 0.088, blue: 0.108)
            Canvas { context, size in
                let major = Self.majorStep(for: pixelsPerSecond)
                let minors = Self.minorDivisions(for: pixelsPerSecond)
                let minorStep = major / Double(minors)
                let maxSec = Double(size.width / pixelsPerSecond)

                var idx = 0
                while true {
                    let t = Double(idx) * minorStep
                    if t > maxSec + 0.001 { break }
                    let x = CGFloat(t) * pixelsPerSecond
                    let isMajor = idx % minors == 0
                    let tickH: CGFloat = isMajor ? 8 : 4
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - tickH))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(.white.opacity(isMajor ? 0.34 : 0.15)), lineWidth: 1)

                    if isMajor {
                        let label = Text(formatTick(t))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                        context.draw(label, at: CGPoint(x: x + 3, y: 6.5), anchor: .leading)
                    }
                    idx += 1
                }

                if totalDuration > 0 {
                    let endX = CGFloat(totalDuration) * pixelsPerSecond
                    var endLine = Path()
                    endLine.move(to: CGPoint(x: endX, y: 0))
                    endLine.addLine(to: CGPoint(x: endX, y: size.height))
                    context.stroke(endLine, with: .color(mtCyanAccent.opacity(0.65)), lineWidth: 1.5)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("mtCanvas"))
                .onChanged { value in
                    let rawSec = max(0, Double(value.location.x / pixelsPerSecond))
                    let clamped = totalDuration > 0 ? min(totalDuration, rawSec) : 0
                    onScrub(clamped, false)
                }
                .onEnded { value in
                    let rawSec = max(0, Double(value.location.x / pixelsPerSecond))
                    let clamped = totalDuration > 0 ? min(totalDuration, rawSec) : 0
                    onScrub(clamped, true)
                }
        )
    }
}

private struct MultitrackPlayheadNeedle: View {
    let x: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x - 5.5, y: 0))
                path.addLine(to: CGPoint(x: x + 5.5, y: 0))
                path.addLine(to: CGPoint(x: x + 5.5, y: 7))
                path.addLine(to: CGPoint(x: x, y: 13))
                path.addLine(to: CGPoint(x: x - 5.5, y: 7))
                path.closeSubpath()
            }
            .fill(mtPlayheadRed)

            Rectangle()
                .fill(mtPlayheadRed)
                .frame(width: 1.5, height: max(0, totalHeight - 11))
                .offset(x: x - 0.75, y: 11)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Drag State Helper

@MainActor private final class MultitrackClipGestureState: ObservableObject {
    var originTimelineStart: Double?
    var originSourceStart: Double?
    var originSourceEnd: Double?
    var originDuration: Double?
}

// MARK: - Video Clip Block (with Continuous Filmstrip Thumbnails)

private struct MultitrackVideoClipBlock: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    @ObservedObject private var visualCache = MediaVisualCache.shared
    let layout: MultitrackLayout
    let trackLayout: VideoTrackLayout
    let segment: VideoSegmentLayout
    let width: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat

    @StateObject private var dragState = MultitrackClipGestureState()

    private var isSelected: Bool {
        state.selection == .videoClip(trackID: segment.trackID, clipID: segment.id)
    }

    private var clip: VideoClip { segment.clip }
    private var accentColor: Color { clip.freezeFrame ? mtSnapYellow : (clip.still ? mtStillAccent : mtVideoAccent) }
    private var fillColor: Color { clip.still ? mtStillFill : mtVideoFill }
    private var hasCustomTransform: Bool {
        abs(clip.scale - 1.0) > 0.01 || abs(clip.posX) > 0.01 || abs(clip.posY) > 0.01 || clip.opacity < 0.99
    }

    var body: some View {
        let frames = visualCache.filmstrips[clip.path] ?? []

        ZStack(alignment: .leading) {
            ZStack(alignment: .topLeading) {
                // Continuous filmstrip background
                if !frames.isEmpty && width >= 26 {
                    let tileW: CGFloat = max(28, height * 1.45)
                    let tileCount = max(1, Int(ceil(width / tileW)))
                    HStack(spacing: 0) {
                        ForEach(0..<tileCount, id: \.self) { idx in
                            let frameIdx = min(frames.count - 1, (idx * frames.count) / max(1, tileCount))
                            Image(decorative: frames[frameIdx], scale: 1.0)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(tileCount), height: height)
                                .clipped()
                        }
                    }
                    .opacity(isSelected ? 0.58 : 0.44)
                    .allowsHitTesting(false)

                    LinearGradient(
                        colors: [.black.opacity(0.65), .black.opacity(0.20), .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                } else {
                    (isSelected ? fillColor : fillColor.opacity(0.86))
                }

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(segment.isTrimValid ? accentColor : Color.orange)
                        .frame(height: 2.5)

                    HStack(spacing: 4) {
                        if width >= 54 && !trackLayout.track.locked && layout.videoTracks.count > 1 {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.70))
                                .padding(.vertical, 6)
                                .draggable("md-clip:video:\(segment.id.uuidString)")
                                .help("拖曳此把手可跨軌移至其他影片軌")
                        }
                        if width >= 28 {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 3) {
                                    Text(filename(clip.path))
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
                                        .lineLimit(1)
                                    if clip.freezeFrame && width >= 66 {
                                        clipTinyBadge("定格", color: mtSnapYellow)
                                    }
                                    if abs(clip.speed - 1.0) > 0.02 && !clip.still && !clip.freezeFrame && width >= 78 {
                                        clipTinyBadge(String(format: "%.2gx", clip.speed), color: mtCyanAccent)
                                    }
                                    if clip.reversed && width >= 88 {
                                        clipTinyBadge("倒放", color: .orange)
                                    }
                                    if clip.filterPreset != "none" && width >= 104 {
                                        clipTinyBadge("濾鏡", color: Color(red: 0.78, green: 0.56, blue: 0.98))
                                    }
                                    if clip.chromaKeyEnabled && width >= 110 {
                                        clipTinyBadge("去背", color: mtAudioAccent)
                                    }
                                    if hasCustomTransform && width >= 120 {
                                        clipTinyBadge("PiP", color: accentColor)
                                    }
                                    if clip.muted && !clip.still && width >= 92 {
                                        Image(systemName: "speaker.slash.fill")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if width >= 46 {
                                    Text(String(format: "%.2fs%@", segment.duration, clip.still ? " · 圖" : ""))
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.82))
                                        .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, width >= 36 ? 6 : 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: width, height: height)
            .background(fillColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? mtCyanAccent : .white.opacity(0.16), lineWidth: isSelected ? 1.6 : 0.9)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                state.selection = .videoClip(trackID: segment.trackID, clipID: segment.id)
                state.selectActiveTrack(segment.trackID, kind: .video)
                state.previewMode = .timeline
                app.editSelection = clip.path
            }
            .gesture(moveDragGesture)
            .onAppear {
                visualCache.requestFilmstrip(path: clip.path, count: 8)
            }
            .onChange(of: clip.path) { _, newPath in
                visualCache.requestFilmstrip(path: newPath, count: 8)
            }
            .contextMenu {
                Button("在播放頭分割") { state.splitSelectedAtPlayhead(app: app, playback: playback) }
                    .disabled(app.busy || trackLayout.track.locked)
                Button("插入 2 秒定格") {
                    state.selection = .videoClip(trackID: segment.trackID, clipID: segment.id)
                    state.insertFreezeAtPlayhead(app: app, playback: playback)
                }
                .disabled(app.busy || trackLayout.track.locked)
                Button("跳至片段開頭") {
                    state.selection = .videoClip(trackID: segment.trackID, clipID: segment.id)
                    state.previewMode = .timeline
                    playback.pause()
                    playback.seek(to: segment.timelineStart, exact: true)
                }
                if layout.videoTracks.count > 1 {
                    Menu("移至影片軌") {
                        ForEach(layout.videoTracks) { target in
                            Button(target.track.name) {
                                app.moveVideoClip(id: segment.id, toStart: segment.timelineStart, targetTrackID: target.id)
                                state.selection = .videoClip(trackID: target.id, clipID: segment.id)
                                playback.syncLayout(app.currentMultitrackLayout())
                            }
                            .disabled(target.id == segment.trackID || target.track.locked)
                        }
                    }
                    .disabled(app.busy || trackLayout.track.locked)
                }
                Button("複製片段") {
                    if let dup = app.duplicateSelection(.videoClip(trackID: segment.trackID, clipID: segment.id)) {
                        state.selection = dup
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
                }
                .disabled(app.busy || trackLayout.track.locked)
                Button("重設裁切") { app.resetVideoClipTrim(id: segment.id) }
                    .disabled(app.busy || trackLayout.track.locked || (clip.start.isEmpty && clip.end.isEmpty))
                Divider()
                Button("刪除片段", role: .destructive) {
                    state.selection = .videoClip(trackID: segment.trackID, clipID: segment.id)
                    state.deleteSelected(app: app, playback: playback)
                }
                .disabled(app.busy || trackLayout.track.locked)
            }

            if width >= 22 && !app.busy && !trackLayout.track.locked {
                HStack(spacing: 0) {
                    if !clip.still && !clip.freezeFrame {
                        trimHandle(isLeading: true)
                    }
                    Spacer(minLength: 0)
                    trimHandle(isLeading: false)
                }
                .frame(width: width, height: height)
            }
        }
        .help("\(filename(clip.path)) · \(String(format: "%.2f", segment.duration))s")
    }

    private func clipTinyBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
            .foregroundStyle(canvas)
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .background(color, in: RoundedRectangle(cornerRadius: 2))
    }

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("mtCanvas"))
            .onChanged { value in
                guard !app.busy && !trackLayout.track.locked else { return }
                if dragState.originTimelineStart == nil {
                    dragState.originTimelineStart = segment.timelineStart
                    state.selection = .videoClip(trackID: segment.trackID, clipID: segment.id)
                    state.previewMode = .timeline
                    playback.pause()
                }
                let baseStart = dragState.originTimelineStart ?? segment.timelineStart
                let deltaSec = Double(value.translation.width / pixelsPerSecond)
                var candidate = max(0, baseStart + deltaSec)
                var guide: Double? = nil

                if app.activeMultitrack.snapEnabled {
                    let thresholdSec = Double(state.snapThresholdPx / pixelsPerSecond)
                    let startSnap = layout.snap(time: candidate, playhead: playback.playhead, thresholdSeconds: thresholdSec, excludingClipID: segment.id)
                    let endSnap = layout.snap(time: candidate + segment.duration, playhead: playback.playhead, thresholdSeconds: thresholdSec, excludingClipID: segment.id)
                    if let sg = startSnap.guideTime, let eg = endSnap.guideTime {
                        if abs(sg - candidate) <= abs(eg - (candidate + segment.duration)) {
                            candidate = sg; guide = sg
                        } else {
                            candidate = max(0, eg - segment.duration); guide = eg
                        }
                    } else if let sg = startSnap.guideTime {
                        candidate = sg; guide = sg
                    } else if let eg = endSnap.guideTime {
                        candidate = max(0, eg - segment.duration); guide = eg
                    }
                }
                state.activeSnapGuideTime = guide
                state.dragPreviewHint = "起點 \(TimelineLayout.formatTimecode(candidate))"
                app.moveVideoClip(id: segment.id, toStart: candidate)
            }
            .onEnded { _ in
                dragState.originTimelineStart = nil
                state.activeSnapGuideTime = nil
                state.dragPreviewHint = nil
                playback.syncLayout(app.currentMultitrackLayout())
            }
    }

    private func trimHandle(isLeading: Bool) -> some View {
        let handleW: CGFloat = min(8, max(5, width * 0.2))
        return Rectangle()
            .fill(isSelected ? mtCyanAccent.opacity(0.32) : .white.opacity(0.001))
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? mtCyanAccent : .white.opacity(0.42))
                    .frame(width: 2, height: 18)
            )
            .frame(width: handleW, height: height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("mtCanvas"))
                    .onChanged { value in
                        if dragState.originSourceStart == nil {
                            dragState.originTimelineStart = segment.timelineStart
                            dragState.originSourceStart = segment.sourceStart
                            dragState.originSourceEnd = segment.sourceEnd
                            state.selection = .videoClip(trackID: segment.trackID, clipID: segment.id)
                            state.previewMode = .timeline
                            playback.pause()
                        }
                        let baseTStart = dragState.originTimelineStart ?? segment.timelineStart
                        let baseSrcStart = dragState.originSourceStart ?? segment.sourceStart
                        let baseSrcEnd = dragState.originSourceEnd ?? segment.sourceEnd
                        let deltaSec = Double(value.translation.width / pixelsPerSecond)

                        if clip.still {
                            let newDur = min(300.0, max(TimelineLayout.minClipDuration, baseSrcEnd + deltaSec))
                            app.trimVideoClip(id: segment.id, sourceStart: nil, sourceEnd: newDur)
                            state.dragPreviewHint = String(format: "圖片停留 %.2fs", newDur)
                        } else if clip.freezeFrame {
                            let newDur = min(300.0, max(TimelineLayout.minClipDuration, (baseSrcEnd - baseSrcStart) + deltaSec))
                            app.updateVideoClipProperties(id: segment.id) {
                                $0.end = TimelineLayout.formatTrimSeconds(baseSrcStart + newDur)
                            }
                            state.dragPreviewHint = String(format: "定格時長 %.2fs", newDur)
                        } else if isLeading {
                            let safeSpeed = min(4.0, max(0.25, clip.speed))
                            let srcDelta = deltaSec * safeSpeed
                            let clampedSrcDelta = min(baseSrcEnd - baseSrcStart - TimelineLayout.minClipDuration, max(-baseSrcStart, srcDelta))
                            let nextSrcStart = max(0, baseSrcStart + clampedSrcDelta)
                            let nextTStart = max(0, baseTStart + (nextSrcStart - baseSrcStart) / safeSpeed)
                            app.trimVideoClip(id: segment.id, sourceStart: nextSrcStart, sourceEnd: baseSrcEnd, timelineStart: nextTStart)
                            state.dragPreviewHint = String(format: "入點 %.2fs", nextSrcStart)
                        } else {
                            let safeSpeed = min(4.0, max(0.25, clip.speed))
                            let maxEnd = segment.sourceDuration ?? 3600
                            let nextEnd = min(maxEnd, max(baseSrcStart + TimelineLayout.minClipDuration, baseSrcEnd + deltaSec * safeSpeed))
                            app.trimVideoClip(id: segment.id, sourceStart: baseSrcStart, sourceEnd: nextEnd)
                            state.dragPreviewHint = String(format: "出點 %.2fs", nextEnd)
                        }
                    }
                    .onEnded { _ in
                        dragState.originTimelineStart = nil
                        dragState.originSourceStart = nil
                        dragState.originSourceEnd = nil
                        state.dragPreviewHint = nil
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
            )
    }
}

// MARK: - Audio Clip Block (with Real Waveform Canvas)

private struct MultitrackAudioClipBlock: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    @ObservedObject private var visualCache = MediaVisualCache.shared
    let layout: MultitrackLayout
    let trackLayout: AudioTrackLayout
    let segment: AudioSegmentLayout
    let width: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat

    @StateObject private var dragState = MultitrackClipGestureState()

    private var isSelected: Bool {
        state.selection == .audioClip(trackID: segment.trackID, clipID: segment.id)
    }

    var body: some View {
        let clip = segment.clip
        let bins = visualCache.waveforms[clip.path] ?? []

        ZStack(alignment: .leading) {
            ZStack(alignment: .topLeading) {
                (isSelected ? mtAudioFill : mtAudioFill.opacity(0.84))

                // Real amplitude waveform bar chart via Canvas
                if !bins.isEmpty {
                    Canvas { ctx, size in
                        let srcDur = segment.sourceDuration ?? max(segment.sourceEnd, segment.duration)
                        let startFrac = srcDur > 0 ? min(1, max(0, segment.sourceStart / srcDur)) : 0
                        let endFrac = srcDur > 0 ? min(1, max(startFrac + 0.01, segment.sourceEnd / srcDur)) : 1
                        let startIdx = Int(floor(startFrac * Double(bins.count)))
                        let endIdx = max(startIdx + 1, Int(ceil(endFrac * Double(bins.count))))
                        let sliceCount = max(1, min(bins.count, endIdx) - min(bins.count - 1, startIdx))
                        let barSpacing: CGFloat = 2.0
                        let barCount = max(1, Int(size.width / barSpacing))
                        let midY = size.height * 0.56
                        let maxHalfH = size.height * 0.36

                        for i in 0..<barCount {
                            let frac = Double(i) / Double(max(1, barCount))
                            let idx = min(bins.count - 1, startIdx + Int(frac * Double(sliceCount)))
                            let amp = CGFloat(min(1.0, max(0.06, bins[idx])))
                            let halfH = max(1.5, amp * maxHalfH)
                            let x = CGFloat(i) * barSpacing + 0.5
                            let rect = CGRect(x: x, y: midY - halfH, width: 1.3, height: halfH * 2)
                            ctx.fill(Path(rect), with: .color(mtAudioAccent.opacity(clip.muted ? 0.20 : 0.48)))
                        }
                    }
                    .allowsHitTesting(false)
                }

                // Fade-in / Fade-out slopes
                Canvas { ctx, size in
                    if clip.fadeIn > 0.01 {
                        let fw = min(size.width * 0.5, CGFloat(clip.fadeIn) * pixelsPerSecond)
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: 0))
                        p.addLine(to: CGPoint(x: fw, y: 0))
                        p.addLine(to: CGPoint(x: 0, y: size.height))
                        p.closeSubpath()
                        ctx.fill(p, with: .color(.black.opacity(0.32)))
                    }
                    if clip.fadeOut > 0.01 {
                        let fw = min(size.width * 0.5, CGFloat(clip.fadeOut) * pixelsPerSecond)
                        var p = Path()
                        p.move(to: CGPoint(x: size.width, y: 0))
                        p.addLine(to: CGPoint(x: size.width - fw, y: 0))
                        p.addLine(to: CGPoint(x: size.width, y: size.height))
                        p.closeSubpath()
                        ctx.fill(p, with: .color(.black.opacity(0.32)))
                    }
                }
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(segment.isTrimValid ? mtAudioAccent : Color.orange)
                        .frame(height: 2.5)
                    HStack(spacing: 4) {
                        if width >= 54 && !trackLayout.track.locked && layout.audioTracks.count > 1 {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.vertical, 5)
                                .draggable("md-clip:audio:\(segment.id.uuidString)")
                                .help("拖曳此把手可跨軌移至其他音訊軌")
                        }
                        if width >= 26 {
                            Image(systemName: clip.muted ? "speaker.slash.fill" : "waveform")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(clip.muted ? .orange : mtAudioAccent)
                        }
                        if width >= 54 {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 3) {
                                    Text(filename(clip.path))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.75), radius: 1, x: 0, y: 1)
                                        .lineLimit(1)
                                    if clip.voiceCleanup && width >= 98 {
                                        Text("淨化")
                                            .font(.system(size: 7.5, weight: .bold))
                                            .foregroundStyle(canvas)
                                            .padding(.horizontal, 3)
                                            .background(mtAudioAccent, in: RoundedRectangle(cornerRadius: 2))
                                    }
                                    if clip.audioEffect != "none" && width >= 112 {
                                        Text(AudioEffectKind.resolved(clip.audioEffect).displayName)
                                            .font(.system(size: 7.5, weight: .bold))
                                            .foregroundStyle(canvas)
                                            .padding(.horizontal, 3)
                                            .background(mtSnapYellow, in: RoundedRectangle(cornerRadius: 2))
                                    }
                                }
                                Text(String(format: "%.2fs · %d%%", segment.duration, Int((clip.volume * 100).rounded())))
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.76))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? mtAudioAccent : .white.opacity(0.14), lineWidth: isSelected ? 1.5 : 0.9)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                state.selection = .audioClip(trackID: segment.trackID, clipID: segment.id)
                state.selectActiveTrack(segment.trackID, kind: .audio)
                state.previewMode = .timeline
                app.editSelection = clip.path
            }
            .gesture(moveDragGesture)
            .onAppear {
                visualCache.requestWaveform(path: clip.path, bins: 96)
            }
            .onChange(of: clip.path) { _, newPath in
                visualCache.requestWaveform(path: newPath, bins: 96)
            }
            .contextMenu {
                Button("在播放頭分割") { state.splitSelectedAtPlayhead(app: app, playback: playback) }
                    .disabled(app.busy || trackLayout.track.locked)
                if layout.audioTracks.count > 1 {
                    Menu("移至音訊軌") {
                        ForEach(layout.audioTracks) { target in
                            Button(target.track.name) {
                                app.moveAudioClip(id: segment.id, toStart: segment.timelineStart, targetTrackID: target.id)
                                state.selection = .audioClip(trackID: target.id, clipID: segment.id)
                                playback.syncLayout(app.currentMultitrackLayout())
                            }
                            .disabled(target.id == segment.trackID || target.track.locked)
                        }
                    }
                    .disabled(app.busy || trackLayout.track.locked)
                }
                Button("複製片段") {
                    if let dup = app.duplicateSelection(.audioClip(trackID: segment.trackID, clipID: segment.id)) {
                        state.selection = dup
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
                }
                .disabled(app.busy || trackLayout.track.locked)
                Divider()
                Button("刪除音訊", role: .destructive) {
                    state.selection = .audioClip(trackID: segment.trackID, clipID: segment.id)
                    state.deleteSelected(app: app, playback: playback)
                }
                .disabled(app.busy || trackLayout.track.locked)
            }

            if width >= 22 && !app.busy && !trackLayout.track.locked {
                HStack(spacing: 0) {
                    trimHandle(isLeading: true)
                    Spacer(minLength: 0)
                    trimHandle(isLeading: false)
                }
                .frame(width: width, height: height)
            }
        }
        .help("\(filename(clip.path)) · \(String(format: "%.2f", segment.duration))s")
    }

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("mtCanvas"))
            .onChanged { value in
                guard !app.busy && !trackLayout.track.locked else { return }
                if dragState.originTimelineStart == nil {
                    dragState.originTimelineStart = segment.timelineStart
                    state.selection = .audioClip(trackID: segment.trackID, clipID: segment.id)
                    playback.pause()
                }
                let baseStart = dragState.originTimelineStart ?? segment.timelineStart
                let deltaSec = Double(value.translation.width / pixelsPerSecond)
                var candidate = max(0, baseStart + deltaSec)
                var guide: Double? = nil
                if app.activeMultitrack.snapEnabled {
                    let threshold = Double(state.snapThresholdPx / pixelsPerSecond)
                    let snapRes = layout.snap(time: candidate, playhead: playback.playhead, thresholdSeconds: threshold, excludingClipID: segment.id)
                    candidate = snapRes.snapped
                    guide = snapRes.guideTime
                }
                state.activeSnapGuideTime = guide
                state.dragPreviewHint = "音訊起點 \(TimelineLayout.formatTimecode(candidate))"
                app.moveAudioClip(id: segment.id, toStart: candidate)
            }
            .onEnded { _ in
                dragState.originTimelineStart = nil
                state.activeSnapGuideTime = nil
                state.dragPreviewHint = nil
                playback.syncLayout(app.currentMultitrackLayout())
            }
    }

    private func trimHandle(isLeading: Bool) -> some View {
        let handleW: CGFloat = min(8, max(5, width * 0.2))
        return Rectangle()
            .fill(isSelected ? mtAudioAccent.opacity(0.32) : .white.opacity(0.001))
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? mtAudioAccent : .white.opacity(0.35))
                    .frame(width: 2, height: 15)
            )
            .frame(width: handleW, height: height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("mtCanvas"))
                    .onChanged { value in
                        if dragState.originSourceStart == nil {
                            dragState.originTimelineStart = segment.timelineStart
                            dragState.originSourceStart = segment.sourceStart
                            dragState.originSourceEnd = segment.sourceEnd
                            state.selection = .audioClip(trackID: segment.trackID, clipID: segment.id)
                            playback.pause()
                        }
                        let baseTStart = dragState.originTimelineStart ?? segment.timelineStart
                        let baseSrcStart = dragState.originSourceStart ?? segment.sourceStart
                        let baseSrcEnd = dragState.originSourceEnd ?? segment.sourceEnd
                        let deltaSec = Double(value.translation.width / pixelsPerSecond)
                        if isLeading {
                            let clampedDelta = min(baseSrcEnd - baseSrcStart - TimelineLayout.minClipDuration, max(-baseSrcStart, deltaSec))
                            let nextSrcStart = max(0, baseSrcStart + clampedDelta)
                            let nextTStart = max(0, baseTStart + (nextSrcStart - baseSrcStart))
                            app.trimAudioClip(id: segment.id, sourceStart: nextSrcStart, sourceEnd: baseSrcEnd, timelineStart: nextTStart)
                            state.dragPreviewHint = String(format: "音訊入點 %.2fs", nextSrcStart)
                        } else {
                            let maxEnd = segment.sourceDuration ?? 3600
                            let nextEnd = min(maxEnd, max(baseSrcStart + TimelineLayout.minClipDuration, baseSrcEnd + deltaSec))
                            app.trimAudioClip(id: segment.id, sourceStart: baseSrcStart, sourceEnd: nextEnd)
                            state.dragPreviewHint = String(format: "音訊出點 %.2fs", nextEnd)
                        }
                    }
                    .onEnded { _ in
                        dragState.originTimelineStart = nil
                        dragState.originSourceStart = nil
                        dragState.originSourceEnd = nil
                        state.dragPreviewHint = nil
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
            )
    }
}

// MARK: - Text Clip Block

private struct MultitrackTextClipBlock: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController
    let layout: MultitrackLayout
    let trackLayout: TextTrackLayout
    let segment: TextSegmentLayout
    let width: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat

    @StateObject private var dragState = MultitrackClipGestureState()

    private var isSelected: Bool {
        state.selection == .textClip(trackID: segment.trackID, clipID: segment.id)
    }

    var body: some View {
        let clip = segment.clip
        let singleLine = clip.text.replacingOccurrences(of: "\n", with: " ")
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(mtTextAccent)
                    .frame(height: 2.5)
                HStack(spacing: 4) {
                    if width >= 54 && !trackLayout.track.locked && layout.textTracks.count > 1 {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.vertical, 4)
                            .draggable("md-clip:text:\(segment.id.uuidString)")
                            .help("拖曳此把手可跨軌移至其他文字軌")
                    }
                    if width >= 22 {
                        Text("T")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(mtTextAccent)
                    }
                    if width >= 44 {
                        Text(singleLine.isEmpty ? "（空白字幕）" : singleLine)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if width >= 88 {
                        Text(String(format: "%.1fs", segment.duration))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width, height: height)
            .background(isSelected ? mtTextFill : mtTextFill.opacity(0.84), in: RoundedRectangle(cornerRadius: 4))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? mtTextAccent : .white.opacity(0.14), lineWidth: isSelected ? 1.5 : 0.9)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                state.selection = .textClip(trackID: segment.trackID, clipID: segment.id)
                state.selectActiveTrack(segment.trackID, kind: .text)
                state.previewMode = .timeline
            }
            .gesture(moveDragGesture)
            .contextMenu {
                Button("在播放頭分割") { state.splitSelectedAtPlayhead(app: app, playback: playback) }
                    .disabled(app.busy || trackLayout.track.locked)
                if layout.textTracks.count > 1 {
                    Menu("移至文字軌") {
                        ForEach(layout.textTracks) { target in
                            Button(target.track.name) {
                                app.moveTextClip(id: segment.id, toStart: segment.timelineStart, targetTrackID: target.id)
                                state.selection = .textClip(trackID: target.id, clipID: segment.id)
                                playback.syncLayout(app.currentMultitrackLayout())
                            }
                            .disabled(target.id == segment.trackID || target.track.locked)
                        }
                    }
                    .disabled(app.busy || trackLayout.track.locked)
                }
                Button("複製字幕") {
                    if let dup = app.duplicateSelection(.textClip(trackID: segment.trackID, clipID: segment.id)) {
                        state.selection = dup
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
                }
                .disabled(app.busy || trackLayout.track.locked)
                Divider()
                Button("刪除字幕", role: .destructive) {
                    state.selection = .textClip(trackID: segment.trackID, clipID: segment.id)
                    state.deleteSelected(app: app, playback: playback)
                }
                .disabled(app.busy || trackLayout.track.locked)
            }

            if width >= 22 && !app.busy && !trackLayout.track.locked {
                HStack(spacing: 0) {
                    trimHandle(isLeading: true)
                    Spacer(minLength: 0)
                    trimHandle(isLeading: false)
                }
                .frame(width: width, height: height)
            }
        }
        .help("\(singleLine) · \(String(format: "%.2f", segment.duration))s")
    }

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("mtCanvas"))
            .onChanged { value in
                guard !app.busy && !trackLayout.track.locked else { return }
                if dragState.originTimelineStart == nil {
                    dragState.originTimelineStart = segment.timelineStart
                    state.selection = .textClip(trackID: segment.trackID, clipID: segment.id)
                    playback.pause()
                }
                let baseStart = dragState.originTimelineStart ?? segment.timelineStart
                let deltaSec = Double(value.translation.width / pixelsPerSecond)
                var candidate = max(0, baseStart + deltaSec)
                var guide: Double? = nil
                if app.activeMultitrack.snapEnabled {
                    let threshold = Double(state.snapThresholdPx / pixelsPerSecond)
                    let snapRes = layout.snap(time: candidate, playhead: playback.playhead, thresholdSeconds: threshold, excludingClipID: segment.id)
                    candidate = snapRes.snapped
                    guide = snapRes.guideTime
                }
                state.activeSnapGuideTime = guide
                state.dragPreviewHint = "字幕起點 \(TimelineLayout.formatTimecode(candidate))"
                app.moveTextClip(id: segment.id, toStart: candidate)
            }
            .onEnded { _ in
                dragState.originTimelineStart = nil
                state.activeSnapGuideTime = nil
                state.dragPreviewHint = nil
                playback.syncLayout(app.currentMultitrackLayout())
            }
    }

    private func trimHandle(isLeading: Bool) -> some View {
        let handleW: CGFloat = min(8, max(5, width * 0.2))
        return Rectangle()
            .fill(isSelected ? mtTextAccent.opacity(0.32) : .white.opacity(0.001))
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? mtTextAccent : .white.opacity(0.35))
                    .frame(width: 2, height: 14)
            )
            .frame(width: handleW, height: height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("mtCanvas"))
                    .onChanged { value in
                        if dragState.originDuration == nil {
                            dragState.originTimelineStart = segment.timelineStart
                            dragState.originDuration = segment.duration
                            state.selection = .textClip(trackID: segment.trackID, clipID: segment.id)
                            playback.pause()
                        }
                        let baseStart = dragState.originTimelineStart ?? segment.timelineStart
                        let baseDur = dragState.originDuration ?? segment.duration
                        let deltaSec = Double(value.translation.width / pixelsPerSecond)
                        if isLeading {
                            let maxShift = baseDur - TimelineLayout.minClipDuration
                            let shift = min(maxShift, max(-baseStart, deltaSec))
                            let nextStart = MultitrackLayout.roundTime(max(0, baseStart + shift))
                            let nextDur = MultitrackLayout.roundTime(max(TimelineLayout.minClipDuration, baseDur - shift))
                            app.updateTextClipProperties(id: segment.id) {
                                $0.timelineStart = nextStart
                                $0.duration = nextDur
                            }
                            state.dragPreviewHint = String(format: "字幕時長 %.2fs", nextDur)
                        } else {
                            let nextDur = MultitrackLayout.roundTime(min(300.0, max(TimelineLayout.minClipDuration, baseDur + deltaSec)))
                            app.updateTextClipProperties(id: segment.id) {
                                $0.duration = nextDur
                            }
                            state.dragPreviewHint = String(format: "字幕時長 %.2fs", nextDur)
                        }
                    }
                    .onEnded { _ in
                        dragState.originTimelineStart = nil
                        dragState.originDuration = nil
                        state.dragPreviewHint = nil
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
            )
    }
}

// MARK: - High-Density Tabbed Right Inspector (Concat Style)

struct MultitrackInspectorView: View {
    @ObservedObject var app: Studio
    @ObservedObject var state: MultitrackEditState
    @ObservedObject var playback: MultitrackPlaybackController

    private var layout: MultitrackLayout {
        app.currentMultitrackLayout()
    }

    var body: some View {
        let tabs = state.availableInspectorTabs()
        let activeTab = tabs.contains(state.inspectorTab) ? state.inspectorTab : (tabs.first ?? .output)

        VStack(spacing: 0) {
            // Compact segmented tab header
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    let isSelected = activeTab == tab
                    Button {
                        state.inspectorTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(isSelected ? mtCyanAccent.opacity(0.24) : .clear, in: Capsule())
                            .overlay {
                                if isSelected {
                                    Capsule().strokeBorder(mtCyanAccent.opacity(0.6), lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(mtDarkWell)
            Divider().overlay(.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch activeTab {
                    case .transform:
                        if case .videoClip(let tid, let cid) = state.selection,
                           let seg = layout.videoSegment(trackID: tid, clipID: cid) {
                            videoTransformTab(seg)
                        } else {
                            emptySelectionHint
                        }
                    case .colorKey:
                        if case .videoClip(let tid, let cid) = state.selection,
                           let seg = layout.videoSegment(trackID: tid, clipID: cid) {
                            videoFilterChromaTab(seg)
                        } else {
                            emptySelectionHint
                        }
                    case .audio:
                        if case .videoClip(let tid, let cid) = state.selection,
                           let seg = layout.videoSegment(trackID: tid, clipID: cid) {
                            videoAudioTab(seg)
                        } else if case .audioClip(let tid, let cid) = state.selection,
                                  let seg = layout.audioSegment(trackID: tid, clipID: cid) {
                            audioClipInspectorTab(seg)
                        } else {
                            emptySelectionHint
                        }
                    case .transition:
                        if case .transition(let tid, let afterID, let beforeID) = state.selection,
                           let junction = layout.junction(trackID: tid, afterID: afterID, beforeID: beforeID) {
                            transitionInspectorTab(junction)
                        } else {
                            emptySelectionHint
                        }
                    case .text:
                        if case .textClip(let tid, let cid) = state.selection,
                           let seg = layout.textSegment(trackID: tid, clipID: cid) {
                            textInspectorTab(seg)
                        } else {
                            emptySelectionHint
                        }
                    case .shape:
                        if case .shapeClip(let tid, let cid) = state.selection,
                           let seg = layout.shapeSegment(trackID: tid, clipID: cid) {
                            ShapeInspectorView(seg: seg, app: app, state: state, playback: playback)
                        } else {
                            emptySelectionHint
                        }
                    case .output:
                        outputExportTab
                    }
                }
                .padding(9)
            }
        }
        .background(panel)
    }

    private var emptySelectionHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(layout.isEmpty ? "多軌剪輯就緒" : "點選時間軸片段或接縫")
                .font(.callout.weight(.semibold))
            Text("點選影片、音訊、字幕片段或轉場膠囊，即可檢視與調整高密度參數。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.6), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
    }

    // MARK: Video — 變換 Tab

    private func videoTransformTab(_ seg: VideoSegmentLayout) -> some View {
        let clip = seg.clip
        let locked = layout.videoTracks.first(where: { $0.id == seg.trackID })?.track.locked ?? false
        let playheadInside = playback.playhead > seg.timelineStart + 0.05 && playback.playhead < seg.timelineEnd - 0.05
        let playheadSourceSec = layout.sourceTime(for: seg, at: playback.playhead)

        return VStack(alignment: .leading, spacing: 8) {
            // Compact clip identity bar
            HStack(spacing: 7) {
                MediaThumbnail(path: clip.path, width: 38, height: 26, reloadToken: app.mediaReloadToken)
                VStack(alignment: .leading, spacing: 1) {
                    Text(filename(clip.path))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .help(clip.path)
                    Text(String(format: "%@ · %.2fs", clip.freezeFrame ? "定格" : (clip.still ? "圖片" : "影片"), seg.duration))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Picker("軌道", selection: Binding(
                    get: { seg.trackID },
                    set: { targetID in
                        app.moveVideoClip(id: seg.id, toStart: seg.timelineStart, targetTrackID: targetID)
                        state.selection = .videoClip(trackID: targetID, clipID: seg.id)
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
                )) {
                    ForEach(layout.videoTracks) { vt in
                        Text(vt.track.name).tag(vt.id)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 84)
                .disabled(app.busy || locked)
            }

            // Section 1: Timing & Trim
            inspectorSection("時間與入出點") {
                HStack(spacing: 6) {
                    Text("起點").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    Text(TimelineLayout.formatTimecode(seg.timelineStart)).font(.caption2.monospacedDigit())
                    Spacer()
                    Stepper("起點", value: Binding(
                        get: { seg.timelineStart },
                        set: { app.moveVideoClip(id: seg.id, toStart: max(0, $0)) }
                    ), in: 0...3600, step: 0.1)
                    .labelsHidden()
                    .controlSize(.mini)
                    .disabled(app.busy || locked)
                }

                if clip.still || clip.freezeFrame {
                    HStack(spacing: 6) {
                        Text("停留").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                        Text(String(format: "%.2fs", seg.duration)).font(.caption2.monospacedDigit())
                        Spacer()
                        Stepper("停留", value: Binding(
                            get: { seg.duration },
                            set: { val in
                                if clip.freezeFrame {
                                    app.updateVideoClipProperties(id: seg.id) {
                                        $0.end = TimelineLayout.formatTrimSeconds(seg.sourceStart + max(0.1, val))
                                    }
                                } else {
                                    app.trimVideoClip(id: seg.id, sourceStart: nil, sourceEnd: val)
                                }
                            }
                        ), in: 0.1...300, step: 0.5)
                        .labelsHidden()
                        .controlSize(.mini)
                        .disabled(app.busy || locked)
                    }
                } else {
                    HStack(spacing: 5) {
                        Text("入點").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                        Text(String(format: "%.2fs", seg.sourceStart)).font(.caption2.monospacedDigit())
                        Spacer()
                        Stepper("入點", value: Binding(
                            get: { seg.sourceStart },
                            set: { app.trimVideoClip(id: seg.id, sourceStart: $0, sourceEnd: nil) }
                        ), in: 0...max(0.1, seg.sourceEnd - 0.1), step: 0.1)
                        .labelsHidden()
                        .controlSize(.mini)
                        .disabled(app.busy || locked)
                        Button("播放頭") {
                            app.trimVideoClip(id: seg.id, sourceStart: playheadSourceSec, sourceEnd: nil)
                        }
                        .controlSize(.mini)
                        .disabled(app.busy || locked || !playheadInside || playheadSourceSec >= seg.sourceEnd - 0.1)
                    }
                    HStack(spacing: 5) {
                        Text("出點").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                        Text(String(format: "%.2fs", seg.sourceEnd)).font(.caption2.monospacedDigit())
                        Spacer()
                        Stepper("出點", value: Binding(
                            get: { seg.sourceEnd },
                            set: { app.trimVideoClip(id: seg.id, sourceStart: nil, sourceEnd: $0) }
                        ), in: (seg.sourceStart + 0.1)...max(seg.sourceStart + 0.1, seg.sourceDuration ?? 3600), step: 0.1)
                        .labelsHidden()
                        .controlSize(.mini)
                        .disabled(app.busy || locked)
                        Button("播放頭") {
                            app.trimVideoClip(id: seg.id, sourceStart: nil, sourceEnd: playheadSourceSec)
                        }
                        .controlSize(.mini)
                        .disabled(app.busy || locked || !playheadInside || playheadSourceSec <= seg.sourceStart + 0.1)
                    }
                }
            }

            // Section 2: Speed, Reverse & Freeze Frame
            if !clip.still {
                inspectorSection("速度與特技") {
                    compactSliderRow(
                        title: "速度",
                        valueText: String(format: "%.2fx", clip.speed),
                        value: Binding(
                            get: { clip.speed },
                            set: { val in
                                app.updateVideoClipProperties(id: seg.id) {
                                    $0.speed = (min(4.0, max(0.25, val)) * 100).rounded() / 100
                                }
                            }
                        ),
                        range: 0.25...4.0,
                        disabled: app.busy || locked || clip.freezeFrame
                    )

                    HStack(spacing: 4) {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { spd in
                            let isCur = abs(clip.speed - spd) < 0.03
                            Button(String(format: "%gx", spd)) {
                                app.updateVideoClipProperties(id: seg.id) { $0.speed = spd }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9.5, weight: isCur ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(isCur ? canvas : .white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isCur ? mtCyanAccent : mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
                            .disabled(app.busy || locked || clip.freezeFrame)
                        }
                        Spacer()
                        Toggle("倒放", isOn: Binding(
                            get: { clip.reversed },
                            set: { val in app.updateVideoClipProperties(id: seg.id) { $0.reversed = val } }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption2)
                        .disabled(app.busy || locked || clip.freezeFrame)

                        Button("定格+2s") {
                            state.insertFreezeAtPlayhead(app: app, playback: playback)
                        }
                        .controlSize(.mini)
                        .disabled(app.busy || locked)
                    }
                }
            }

            // Section 2-bis: V4 Keyframes & Curves + Speed Ramp
            KeyframeAndSpeedRampInspectorSection(seg: seg, app: app, playback: playback)

            // Section 3: Transform, Flip, Rotation & Crop
            inspectorSection("畫面變換 / 幾何裁切") {
                HStack(spacing: 4) {
                    Button("滿版") {
                        app.updateVideoClipProperties(id: seg.id) {
                            $0.scale = 1.0; $0.posX = 0; $0.posY = 0; $0.rotation = 0; $0.flipH = false; $0.flipV = false; $0.opacity = 1.0
                        }
                    }.controlSize(.mini).disabled(app.busy || locked)

                    Button("畫中畫右下") {
                        app.updateVideoClipProperties(id: seg.id) {
                            $0.scale = 0.35; $0.posX = 0.28; $0.posY = 0.28
                        }
                    }.controlSize(.mini).disabled(app.busy || locked)

                    Spacer()

                    Button {
                        app.updateVideoClipProperties(id: seg.id) { $0.flipH.toggle() }
                    } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.system(size: 10))
                            .foregroundStyle(clip.flipH ? canvas : .white)
                            .frame(width: 24, height: 19)
                            .background(clip.flipH ? mtCyanAccent : mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy || locked)
                    .help("水平翻轉")

                    Button {
                        app.updateVideoClipProperties(id: seg.id) { $0.flipV.toggle() }
                    } label: {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                            .font(.system(size: 10))
                            .foregroundStyle(clip.flipV ? canvas : .white)
                            .frame(width: 24, height: 19)
                            .background(clip.flipV ? mtCyanAccent : mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy || locked)
                    .help("垂直翻轉")

                    Button {
                        app.updateVideoClipProperties(id: seg.id) {
                            let next = $0.rotation + 90
                            $0.rotation = next > 180 ? next - 360 : next
                        }
                    } label: {
                        Text("90°")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .frame(width: 26, height: 19)
                            .background(mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(app.busy || locked)
                    .help("順時針旋轉 90°")
                }

                compactSliderRow(
                    title: "縮放",
                    valueText: "\(Int((clip.scale * 100).rounded()))%",
                    value: Binding(get: { clip.scale }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.scale = v } }),
                    range: 0.1...2.0,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "位置 X",
                    valueText: "\(Int((clip.posX * 100).rounded()))%",
                    value: Binding(get: { clip.posX }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.posX = v } }),
                    range: -0.8...0.8,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "位置 Y",
                    valueText: "\(Int((clip.posY * 100).rounded()))%",
                    value: Binding(get: { clip.posY }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.posY = v } }),
                    range: -0.8...0.8,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "旋轉",
                    valueText: "\(Int(clip.rotation.rounded()))°",
                    value: Binding(get: { clip.rotation }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.rotation = v.rounded() } }),
                    range: -180...180,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "不透明",
                    valueText: "\(Int((clip.opacity * 100).rounded()))%",
                    value: Binding(get: { clip.opacity }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.opacity = v } }),
                    range: 0.0...1.0,
                    disabled: app.busy || locked
                )

                Divider().overlay(.white.opacity(0.06))
                HStack {
                    Text("四邊裁切").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if clip.cropTop > 0 || clip.cropBottom > 0 || clip.cropLeft > 0 || clip.cropRight > 0 {
                        Button("重設") {
                            app.updateVideoClipProperties(id: seg.id) {
                                $0.cropTop = 0; $0.cropBottom = 0; $0.cropLeft = 0; $0.cropRight = 0
                            }
                        }.controlSize(.mini).disabled(app.busy || locked)
                    }
                }
                compactSliderRow(
                    title: "上裁切",
                    valueText: "\(Int((clip.cropTop * 100).rounded()))%",
                    value: Binding(get: { clip.cropTop }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.cropTop = v } }),
                    range: 0...0.45,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "下裁切",
                    valueText: "\(Int((clip.cropBottom * 100).rounded()))%",
                    value: Binding(get: { clip.cropBottom }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.cropBottom = v } }),
                    range: 0...0.45,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "左裁切",
                    valueText: "\(Int((clip.cropLeft * 100).rounded()))%",
                    value: Binding(get: { clip.cropLeft }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.cropLeft = v } }),
                    range: 0...0.45,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "右裁切",
                    valueText: "\(Int((clip.cropRight * 100).rounded()))%",
                    value: Binding(get: { clip.cropRight }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.cropRight = v } }),
                    range: 0...0.45,
                    disabled: app.busy || locked
                )
            }

            // Section 4: Entry / Exit Animation
            inspectorSection("進出場動畫") {
                HStack(spacing: 6) {
                    Text("進場").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    Picker("進場", selection: Binding(
                        get: { clip.animationIn },
                        set: { v in app.updateVideoClipProperties(id: seg.id) { $0.animationIn = v } }
                    )) {
                        ForEach(ClipAnimationKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .disabled(app.busy || locked)

                    Text("出場").font(.caption2).foregroundStyle(.secondary)
                    Picker("出場", selection: Binding(
                        get: { clip.animationOut },
                        set: { v in app.updateVideoClipProperties(id: seg.id) { $0.animationOut = v } }
                    )) {
                        ForEach(ClipAnimationKind.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .disabled(app.busy || locked)
                }

                compactSliderRow(
                    title: "時長",
                    valueText: String(format: "%.2fs", clip.animationDuration),
                    value: Binding(
                        get: { clip.animationDuration },
                        set: { v in app.updateVideoClipProperties(id: seg.id) { $0.animationDuration = (v * 100).rounded() / 100 } }
                    ),
                    range: 0.1...2.0,
                    disabled: app.busy || locked || (clip.animationIn == "none" && clip.animationOut == "none")
                )
            }

            clipActionButtons(locked: locked)
        }
    }

    // MARK: Video — 濾鏡/去背 Tab

    private func videoFilterChromaTab(_ seg: VideoSegmentLayout) -> some View {
        let clip = seg.clip
        let locked = layout.videoTracks.first(where: { $0.id == seg.trackID })?.track.locked ?? false

        return VStack(alignment: .leading, spacing: 8) {
            inspectorSection("濾鏡風格預設") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(VideoFilterPreset.allCases) { preset in
                        let isSel = clip.filterPreset == preset.rawValue
                        Button {
                            app.updateVideoClipProperties(id: seg.id) {
                                $0.filterPreset = preset.rawValue
                                if preset == .none {
                                    $0.brightness = 0; $0.contrast = 1.0; $0.saturation = 1.0; $0.blur = 0; $0.vignette = false
                                } else if preset == .vignette {
                                    $0.vignette = true
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(preset.swatchColors.first ?? .gray)
                                    .frame(width: 8, height: 8)
                                Text(preset.displayName)
                                    .font(.system(size: 10, weight: isSel ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(isSel ? canvas : .white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(isSel ? mtCyanAccent : mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .disabled(app.busy || locked)
                    }
                }
            }

            inspectorSection("色彩與光學微調") {
                HStack {
                    Spacer()
                    Button("重設調色") {
                        app.updateVideoClipProperties(id: seg.id) {
                            $0.filterPreset = "none"; $0.brightness = 0; $0.contrast = 1.0; $0.saturation = 1.0; $0.blur = 0; $0.vignette = false
                        }
                    }
                    .controlSize(.mini)
                    .disabled(app.busy || locked)
                }

                compactSliderRow(
                    title: "亮度",
                    valueText: String(format: "%+.0f%%", clip.brightness * 100),
                    value: Binding(get: { clip.brightness }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.brightness = v } }),
                    range: -0.5...0.5,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "對比",
                    valueText: "\(Int((clip.contrast * 100).rounded()))%",
                    value: Binding(get: { clip.contrast }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.contrast = v } }),
                    range: 0.5...2.0,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "飽和度",
                    valueText: "\(Int((clip.saturation * 100).rounded()))%",
                    value: Binding(get: { clip.saturation }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.saturation = v } }),
                    range: 0.0...2.0,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "柔焦模糊",
                    valueText: String(format: "%.1fpx", clip.blur),
                    value: Binding(get: { clip.blur }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.blur = v } }),
                    range: 0.0...20.0,
                    disabled: app.busy || locked
                )
                Toggle("暗角暈影（Vignette）", isOn: Binding(
                    get: { clip.vignette },
                    set: { v in app.updateVideoClipProperties(id: seg.id) { $0.vignette = v } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(app.busy || locked)
            }

            inspectorSection("綠幕色度去背（Chroma Key）") {
                Toggle("啟用色度去背", isOn: Binding(
                    get: { clip.chromaKeyEnabled },
                    set: { v in app.updateVideoClipProperties(id: seg.id) { $0.chromaKeyEnabled = v } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .disabled(app.busy || locked)

                if clip.chromaKeyEnabled {
                    HStack(spacing: 6) {
                        Text("去背色").font(.caption2).foregroundStyle(.secondary)
                        Button("綠幕") {
                            app.updateVideoClipProperties(id: seg.id) { $0.chromaKeyColor = "#00FF00" }
                        }
                        .controlSize(.mini)
                        .tint(.green)
                        Button("藍幕") {
                            app.updateVideoClipProperties(id: seg.id) { $0.chromaKeyColor = "#0000FF" }
                        }
                        .controlSize(.mini)
                        .tint(.blue)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { MultitrackColorHex.color(from: clip.chromaKeyColor, fallback: .green) },
                            set: { c in app.updateVideoClipProperties(id: seg.id) { $0.chromaKeyColor = MultitrackColorHex.hexString(from: c) } }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Text(clip.chromaKeyColor)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .disabled(app.busy || locked)

                    compactSliderRow(
                        title: "相似度",
                        valueText: String(format: "%.2f", clip.chromaKeySimilarity),
                        value: Binding(get: { clip.chromaKeySimilarity }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.chromaKeySimilarity = v } }),
                        range: 0.01...0.50,
                        disabled: app.busy || locked
                    )
                    compactSliderRow(
                        title: "柔邊混合",
                        valueText: String(format: "%.2f", clip.chromaKeyBlend),
                        value: Binding(get: { clip.chromaKeyBlend }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.chromaKeyBlend = v } }),
                        range: 0.0...0.50,
                        disabled: app.busy || locked
                    )
                }
            }
        }
    }

    // MARK: Video — 音訊 Tab

    private func videoAudioTab(_ seg: VideoSegmentLayout) -> some View {
        let clip = seg.clip
        let locked = layout.videoTracks.first(where: { $0.id == seg.trackID })?.track.locked ?? false

        return VStack(alignment: .leading, spacing: 8) {
            if clip.still || clip.freezeFrame {
                Text(clip.freezeFrame ? "定格片段不包含音訊軌。" : "靜態圖片不包含音訊軌。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface.opacity(0.6), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
            } else {
                inspectorSection("影片原聲控制") {
                    Toggle("靜音影片原聲", isOn: Binding(
                        get: { clip.muted },
                        set: { v in app.updateVideoClipProperties(id: seg.id) { $0.muted = v } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(app.busy || locked)

                    compactSliderRow(
                        title: "音量",
                        valueText: "\(Int((clip.volume * 100).rounded()))%",
                        value: Binding(get: { clip.volume }, set: { v in app.updateVideoClipProperties(id: seg.id) { $0.volume = v } }),
                        range: 0.0...2.0,
                        disabled: app.busy || locked || clip.muted
                    )
                }

                inspectorSection("人聲處理與音效（匯出套用）") {
                    Toggle("人聲淨化（降噪＋響度平衡）", isOn: Binding(
                        get: { clip.voiceCleanup },
                        set: { v in app.updateVideoClipProperties(id: seg.id) { $0.voiceCleanup = v } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .disabled(app.busy || locked || clip.muted)

                    audioEffectSelector(
                        current: clip.audioEffect,
                        disabled: app.busy || locked || clip.muted
                    ) { newEffect in
                        app.updateVideoClipProperties(id: seg.id) { $0.audioEffect = newEffect }
                    }
                }
            }
        }
    }

    // MARK: Audio Clip Inspector Tab

    private func audioClipInspectorTab(_ seg: AudioSegmentLayout) -> some View {
        let clip = seg.clip
        let locked = layout.audioTracks.first(where: { $0.id == seg.trackID })?.track.locked ?? false

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mtAudioAccent)
                    .frame(width: 30, height: 26)
                    .background(mtAudioFill, in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(filename(clip.path))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(String(format: "音訊片段 · %.2fs", seg.duration))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("軌道", selection: Binding(
                    get: { seg.trackID },
                    set: { targetID in
                        app.moveAudioClip(id: seg.id, toStart: seg.timelineStart, targetTrackID: targetID)
                        state.selection = .audioClip(trackID: targetID, clipID: seg.id)
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
                )) {
                    ForEach(layout.audioTracks) { at in
                        Text(at.track.name).tag(at.id)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 82)
                .disabled(app.busy || locked)
            }

            inspectorSection("時間與剪裁") {
                HStack(spacing: 6) {
                    Text("起點").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    Text(TimelineLayout.formatTimecode(seg.timelineStart)).font(.caption2.monospacedDigit())
                    Spacer()
                    Stepper("起點", value: Binding(get: { seg.timelineStart }, set: { app.moveAudioClip(id: seg.id, toStart: max(0, $0)) }), in: 0...3600, step: 0.1)
                        .labelsHidden().controlSize(.mini).disabled(app.busy || locked)
                }
                HStack(spacing: 6) {
                    Text("入點").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    Text(String(format: "%.2fs", seg.sourceStart)).font(.caption2.monospacedDigit())
                    Spacer()
                    Stepper("入點", value: Binding(get: { seg.sourceStart }, set: { app.trimAudioClip(id: seg.id, sourceStart: $0, sourceEnd: nil) }), in: 0...max(0.1, seg.sourceEnd - 0.1), step: 0.1)
                        .labelsHidden().controlSize(.mini).disabled(app.busy || locked)
                }
                HStack(spacing: 6) {
                    Text("出點").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    Text(String(format: "%.2fs", seg.sourceEnd)).font(.caption2.monospacedDigit())
                    Spacer()
                    Stepper("出點", value: Binding(get: { seg.sourceEnd }, set: { app.trimAudioClip(id: seg.id, sourceStart: nil, sourceEnd: $0) }), in: (seg.sourceStart + 0.1)...max(seg.sourceStart + 0.1, seg.sourceDuration ?? 3600), step: 0.1)
                        .labelsHidden().controlSize(.mini).disabled(app.busy || locked)
                }
            }

            inspectorSection("音量與淡入淡出") {
                Toggle("靜音此音訊", isOn: Binding(
                    get: { clip.muted },
                    set: { val in app.updateAudioClipProperties(id: seg.id) { $0.muted = val } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(app.busy || locked)

                compactSliderRow(
                    title: "音量",
                    valueText: "\(Int((clip.volume * 100).rounded()))%",
                    value: Binding(get: { clip.volume }, set: { val in app.updateAudioClipProperties(id: seg.id) { $0.volume = val } }),
                    range: 0.0...2.0,
                    disabled: app.busy || locked || clip.muted
                )
                compactSliderRow(
                    title: "淡入",
                    valueText: String(format: "%.1fs", clip.fadeIn),
                    value: Binding(get: { clip.fadeIn }, set: { val in app.updateAudioClipProperties(id: seg.id) { $0.fadeIn = min(seg.duration * 0.5, max(0, val)) } }),
                    range: 0.0...min(5.0, max(0.1, seg.duration * 0.5)),
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "淡出",
                    valueText: String(format: "%.1fs", clip.fadeOut),
                    value: Binding(get: { clip.fadeOut }, set: { val in app.updateAudioClipProperties(id: seg.id) { $0.fadeOut = min(seg.duration * 0.5, max(0, val)) } }),
                    range: 0.0...min(5.0, max(0.1, seg.duration * 0.5)),
                    disabled: app.busy || locked
                )
            }

            inspectorSection("人聲淨化與聲音特效") {
                Toggle("人聲淨化（降噪＋響度平衡）", isOn: Binding(
                    get: { clip.voiceCleanup },
                    set: { val in app.updateAudioClipProperties(id: seg.id) { $0.voiceCleanup = val } }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .disabled(app.busy || locked || clip.muted)

                audioEffectSelector(
                    current: clip.audioEffect,
                    disabled: app.busy || locked || clip.muted
                ) { newEffect in
                    app.updateAudioClipProperties(id: seg.id) { $0.audioEffect = newEffect }
                }
            }

            clipActionButtons(locked: locked)
        }
    }

    private func audioEffectSelector(current: String, disabled: Bool, onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("聲音特效").font(.caption2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(AudioEffectKind.allCases) { fx in
                    let isSel = current == fx.rawValue
                    Button {
                        onSelect(fx.rawValue)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: fx.symbolName).font(.system(size: 9.5))
                            Text(fx.displayName).font(.system(size: 10, weight: isSel ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(isSel ? canvas : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(isSel ? mtAudioAccent : mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                }
            }
        }
    }

    // MARK: Text / Subtitle Inspector Tab

    private func textInspectorTab(_ seg: TextSegmentLayout) -> some View {
        let clip = seg.clip
        let locked = layout.textTracks.first(where: { $0.id == seg.trackID })?.track.locked ?? false
        let fontFamilies = ["PingFang TC", "Heiti TC", "Songti TC", "Hiragino Sans", "Helvetica Neue"]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("T")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(canvas)
                    .frame(width: 20, height: 20)
                    .background(mtTextAccent, in: RoundedRectangle(cornerRadius: 4))
                Text("文字與字幕")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("文字軌", selection: Binding(
                    get: { seg.trackID },
                    set: { targetID in
                        app.moveTextClip(id: seg.id, toStart: seg.timelineStart, targetTrackID: targetID)
                        state.selection = .textClip(trackID: targetID, clipID: seg.id)
                        playback.syncLayout(app.currentMultitrackLayout())
                    }
                )) {
                    ForEach(layout.textTracks) { tt in Text(tt.track.name).tag(tt.id) }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 88)
                .disabled(app.busy || locked)
            }

            TextEditor(text: Binding(
                get: { clip.text },
                set: { val in app.updateTextClipProperties(id: seg.id) { $0.text = val } }
            ))
            .font(.callout)
            .scrollContentBackground(.hidden)
            .padding(5)
            .frame(height: 64)
            .background(mtDarkWell, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.10)))
            .disabled(app.busy || locked)

            inspectorSection("時間軸位置") {
                HStack(spacing: 6) {
                    Text("起點").font(.caption2).foregroundStyle(.secondary)
                    Text(TimelineLayout.formatTimecode(seg.timelineStart)).font(.caption2.monospacedDigit())
                    Stepper("起點", value: Binding(get: { seg.timelineStart }, set: { app.moveTextClip(id: seg.id, toStart: max(0, $0)) }), in: 0...3600, step: 0.1)
                        .labelsHidden().controlSize(.mini).disabled(app.busy || locked)
                    Spacer(minLength: 2)
                    Text("時長").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.1fs", seg.duration)).font(.caption2.monospacedDigit())
                    Stepper("時長", value: Binding(get: { seg.duration }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.duration = max(0.1, val) } }), in: 0.1...300, step: 0.2)
                        .labelsHidden().controlSize(.mini).disabled(app.busy || locked)
                }
            }

            inspectorSection("字體與外觀") {
                HStack(spacing: 6) {
                    Text("字體").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Picker("字體", selection: Binding(
                        get: { clip.fontFamily },
                        set: { val in app.updateTextClipProperties(id: seg.id) { $0.fontFamily = val } }
                    )) {
                        ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 132)
                    .disabled(app.busy || locked)
                }

                compactSliderRow(
                    title: "字級",
                    valueText: "\(Int(clip.fontSize.rounded()))pt",
                    value: Binding(get: { clip.fontSize }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.fontSize = val } }),
                    range: 14...140,
                    disabled: app.busy || locked
                )

                HStack(spacing: 12) {
                    ColorPicker("文字色", selection: Binding(
                        get: { MultitrackColorHex.color(from: clip.textColorHex, fallback: .white) },
                        set: { c in app.updateTextClipProperties(id: seg.id) { $0.textColorHex = MultitrackColorHex.hexString(from: c) } }
                    ), supportsOpacity: false)
                    .font(.caption2)
                    .disabled(app.busy || locked)

                    ColorPicker("描邊色", selection: Binding(
                        get: { MultitrackColorHex.color(from: clip.strokeColorHex, fallback: .black) },
                        set: { c in app.updateTextClipProperties(id: seg.id) { $0.strokeColorHex = MultitrackColorHex.hexString(from: c) } }
                    ), supportsOpacity: false)
                    .font(.caption2)
                    .disabled(app.busy || locked)
                }

                compactSliderRow(
                    title: "描邊寬",
                    valueText: String(format: "%.1fpx", clip.strokeWidth),
                    value: Binding(get: { clip.strokeWidth }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.strokeWidth = val } }),
                    range: 0...12,
                    disabled: app.busy || locked
                )

                HStack(spacing: 10) {
                    Toggle("陰影", isOn: Binding(get: { clip.shadowEnabled }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.shadowEnabled = val } }))
                        .toggleStyle(.checkbox).font(.caption2).disabled(app.busy || locked)
                    Toggle("底板", isOn: Binding(get: { clip.backgroundEnabled }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.backgroundEnabled = val } }))
                        .toggleStyle(.checkbox).font(.caption2).disabled(app.busy || locked)
                    if clip.backgroundEnabled {
                        ColorPicker("", selection: Binding(
                            get: { MultitrackColorHex.color(from: clip.backgroundColorHex, fallback: .black) },
                            set: { c in app.updateTextClipProperties(id: seg.id) { $0.backgroundColorHex = MultitrackColorHex.hexString(from: c) } }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        .disabled(app.busy || locked)
                    }
                }

                if clip.backgroundEnabled {
                    compactSliderRow(
                        title: "底板透明",
                        valueText: "\(Int((clip.backgroundOpacity * 100).rounded()))%",
                        value: Binding(get: { clip.backgroundOpacity }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.backgroundOpacity = val } }),
                        range: 0.0...1.0,
                        disabled: app.busy || locked
                    )
                }
            }

            inspectorSection("畫布位置（亦可直接於預覽拖曳）") {
                HStack(spacing: 5) {
                    Button("底部字幕") { app.updateTextClipProperties(id: seg.id) { $0.posX = 0.5; $0.posY = 0.86 } }.controlSize(.mini)
                    Button("置中標題") { app.updateTextClipProperties(id: seg.id) { $0.posX = 0.5; $0.posY = 0.50 } }.controlSize(.mini)
                    Button("左上標註") { app.updateTextClipProperties(id: seg.id) { $0.posX = 0.18; $0.posY = 0.14 } }.controlSize(.mini)
                }
                .disabled(app.busy || locked)

                compactSliderRow(
                    title: "水平 X",
                    valueText: "\(Int((clip.posX * 100).rounded()))%",
                    value: Binding(get: { clip.posX }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.posX = val } }),
                    range: 0.05...0.95,
                    disabled: app.busy || locked
                )
                compactSliderRow(
                    title: "垂直 Y",
                    valueText: "\(Int((clip.posY * 100).rounded()))%",
                    value: Binding(get: { clip.posY }, set: { val in app.updateTextClipProperties(id: seg.id) { $0.posY = val } }),
                    range: 0.05...0.95,
                    disabled: app.busy || locked
                )
            }

            clipActionButtons(locked: locked)
        }
    }

    // MARK: Same-Track Transition Inspector Tab

    private func transitionInspectorTab(_ junction: TrackJunctionLayout) -> some View {
        let trackLayout = layout.videoTracks.first(where: { $0.id == junction.trackID })
        let locked = trackLayout?.track.locked ?? false
        let leading = trackLayout?.segments.first(where: { $0.id == junction.afterID })
        let trailing = trackLayout?.segments.first(where: { $0.id == junction.beforeID })
        let activeKind = junction.transition?.kind ?? "cut"
        let isCut = junction.isCut
        let currentSec = junction.transition?.seconds ?? state.transitionDefaultSeconds

        return VStack(alignment: .leading, spacing: 8) {
            inspectorSection("\(trackLayout?.track.name ?? "V1") 同軌轉場") {
                if let leading, let trailing {
                    Text("\(filename(leading.clip.path)) → \(filename(trailing.clip.path))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    transitionOptionButton(
                        title: "硬切",
                        symbol: "scissors",
                        selected: isCut,
                        disabled: app.busy || locked
                    ) {
                        app.setMultitrackTransition(trackID: junction.trackID, after: junction.afterID, before: junction.beforeID, kind: "cut", seconds: 0)
                        playback.syncLayout(app.currentMultitrackLayout())
                    }

                    ForEach(TimelineTransitionKind.allCases) { kind in
                        transitionOptionButton(
                            title: kind.displayName,
                            symbol: kind.symbolName,
                            selected: !isCut && activeKind == kind.rawValue,
                            disabled: app.busy || locked
                        ) {
                            app.setMultitrackTransition(
                                trackID: junction.trackID,
                                after: junction.afterID,
                                before: junction.beforeID,
                                kind: kind.rawValue,
                                seconds: currentSec
                            )
                            let updated = app.currentMultitrackLayout()
                            playback.syncLayout(updated)
                            if let updatedJ = updated.junction(trackID: junction.trackID, afterID: junction.afterID, beforeID: junction.beforeID) {
                                playback.pause()
                                playback.seek(to: updatedJ.seamTime, exact: true)
                            }
                        }
                    }
                }

                compactSliderRow(
                    title: "轉場秒數",
                    valueText: String(format: "%.2fs", currentSec),
                    value: Binding(
                        get: { currentSec },
                        set: { val in
                            guard !isCut else { return }
                            let clean = (min(3.0, max(0.1, val)) * 100).rounded() / 100
                            state.transitionDefaultSeconds = clean
                            app.setMultitrackTransition(
                                trackID: junction.trackID,
                                after: junction.afterID,
                                before: junction.beforeID,
                                kind: activeKind,
                                seconds: clean
                            )
                            playback.syncLayout(app.currentMultitrackLayout())
                        }
                    ),
                    range: 0.1...3.0,
                    disabled: app.busy || locked || isCut
                )

                if !isCut {
                    if !junction.isValid {
                        Text("轉場秒數超過相鄰片段長度，請縮短轉場秒數（0.1–3.0s）。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text(String(format: "重疊區間：%@ – %@（%.2fs）",
                                    TimelineLayout.formatTimecode(junction.overlapStart),
                                    TimelineLayout.formatTimecode(junction.overlapEnd),
                                    junction.overlapDuration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if junction.trackIndex == 0 {
                    Divider().overlay(.white.opacity(0.06))
                    Button {
                        app.syncLegacyMirrorFromMultitrack()
                        app.startBridgeShot(after: junction.afterID, before: junction.beforeID)
                    } label: {
                        Label("V1 接縫補鏡頭", systemImage: "plus.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(app.busy)
                    .help("擷取前段尾幀與後段首幀，切換至生成頁生成過渡鏡頭")
                }
            }
        }
    }

    private func transitionOptionButton(
        title: String,
        symbol: String,
        selected: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5))
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? canvas : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(selected ? mtCyanAccent : mtDarkWell, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? mtCyanAccent : .white.opacity(0.08), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: Export & Output Settings Tab (720p/1080p/4K, 24/30/60fps, H.264/HEVC/HW, 8/10-bit)

    private var outputExportTab: some View {
        let currentFPS = app.timelineOutput.fps ?? 24
        let currentCodec = app.timelineOutput.codec ?? "h264"
        let currentBitDepth = app.timelineOutput.bitDepth ?? 8

        let resPresets: [(label: String, w: String, h: String, aspect: String)] = [
            ("720p", "1280", "720", "16:9"),
            ("1080p", "1920", "1080", "16:9"),
            ("4K", "3840", "2160", "16:9"),
            ("直式 9:16", "1080", "1920", "9:16"),
            ("方形 1:1", "1080", "1080", "1:1")
        ]

        return VStack(alignment: .leading, spacing: 8) {
            inspectorSection("解析度與比例") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(resPresets, id: \.label) { p in
                        let isCur: Bool = {
                            if let d = app.timelineOutput.dimensions {
                                return d.width == p.w && d.height == p.h
                            }
                            return p.w == "1920" && app.timelineOutput.aspect == "16:9"
                                || (p.aspect == "9:16" && app.timelineOutput.aspect == "9:16")
                                || (p.aspect == "1:1" && app.timelineOutput.aspect == "1:1")
                        }()
                        Button(p.label) {
                            app.timelineOutput.aspect = p.aspect
                            app.timelineOutput.dimensions = OutputDimensions(width: p.w, height: p.h)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: isCur ? .semibold : .regular))
                        .foregroundStyle(isCur ? .white : .white.opacity(0.86))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isCur ? mtCyanAccent : mtDarkWell, in: Capsule())
                        .overlay(Capsule().strokeBorder(isCur ? mtCyanAccent.opacity(0.75) : .white.opacity(0.08), lineWidth: 0.8))
                    }
                }

                HStack(spacing: 5) {
                    Text("自訂像素").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    TextField("寬", text: Binding(
                        get: { app.timelineOutput.dimensions?.width ?? (app.timelineOutput.aspect == "16:9" ? "1920" : "1080") },
                        set: { w in
                            let h = app.timelineOutput.dimensions?.height ?? (app.timelineOutput.aspect == "9:16" ? "1920" : "1080")
                            app.timelineOutput.dimensions = OutputDimensions(width: w, height: h)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .frame(width: 56)
                    .monospacedDigit()
                    Text("×").font(.caption2)
                    TextField("高", text: Binding(
                        get: { app.timelineOutput.dimensions?.height ?? (app.timelineOutput.aspect == "9:16" ? "1920" : "1080") },
                        set: { h in
                            let w = app.timelineOutput.dimensions?.width ?? (app.timelineOutput.aspect == "16:9" ? "1920" : "1080")
                            app.timelineOutput.dimensions = OutputDimensions(width: w, height: h)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .frame(width: 56)
                    .monospacedDigit()
                    Text("px").font(.caption2).foregroundStyle(.secondary)
                }
            }

            inspectorSection("影格率 / 編碼 / 位元深度") {
                HStack(spacing: 6) {
                    Text("影格率").font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    KliporaSegmentedControl(
                        options: [(24, "24 fps"), (30, "30 fps"), (60, "60 fps")],
                        selection: Binding(
                            get: { currentFPS },
                            set: { app.timelineOutput.fps = $0 }
                        )
                    )
                }

                HStack(spacing: 6) {
                    Text("編碼器").font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    KliporaPillMenuPicker(
                        options: TimelineExportCodec.allCases.map { ($0.rawValue, $0.displayName) },
                        selection: Binding(
                            get: { currentCodec },
                            set: { newCodec in
                                app.timelineOutput.codec = newCodec
                                if (newCodec == "h264" || newCodec == "h264_videotoolbox") && (app.timelineOutput.bitDepth ?? 8) == 10 {
                                    app.timelineOutput.bitDepth = 8
                                }
                            }
                        )
                    )
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text("位元深度").font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    KliporaSegmentedControl(
                        options: [(8, "8-bit"), (10, "10-bit HEVC")],
                        selection: Binding(
                            get: { currentBitDepth },
                            set: { depth in
                                app.timelineOutput.bitDepth = depth
                                if depth == 10 && currentCodec != "hevc" && currentCodec != "hevc_videotoolbox" {
                                    app.timelineOutput.codec = "hevc_videotoolbox"
                                }
                            }
                        )
                    )
                }
            }

            inspectorSection("渲染與匯出") {
                HStack {
                    Text("\(layout.videoTracks.count)V / \(layout.audioTracks.count)A / \(layout.textTracks.count)T")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("總長 \(TimelineLayout.formatTimecode(layout.totalDuration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                }

                if layout.hasInvalidTransitions {
                    Text("有轉場超過相鄰片段長度，請修正後再預覽或匯出。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    Button("預覽成片", action: app.previewTimeline)
                        .buttonStyle(KliporaPillButtonStyle(variant: .secondary, compact: true, fullWidth: true))
                        .disabled(app.busy || layout.isEmpty || layout.hasInvalidTransitions)

                    Button { app.export() } label: {
                        Label("匯出 MP4", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(KliporaPillButtonStyle(variant: .primary, compact: true, fullWidth: true))
                    .disabled(app.busy || layout.isEmpty || layout.hasInvalidTransitions)
                }
            }
        }
    }

    // MARK: Compact Helpers

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.72), in: RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: StudioTheme.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
    }

    private func compactSliderRow(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        disabled: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
                .disabled(disabled)
            Text(valueText)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func clipActionButtons(locked: Bool) -> some View {
        HStack(spacing: 5) {
            Button {
                state.splitSelectedAtPlayhead(app: app, playback: playback)
            } label: {
                Label("分割", systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(app.busy || locked)

            Button {
                if let current = state.selection, let dup = app.duplicateSelection(current) {
                    state.selection = dup
                    playback.syncLayout(app.currentMultitrackLayout())
                }
            } label: {
                Label("複製", systemImage: "plus.square.on.square")
            }
            .controlSize(.small)
            .disabled(app.busy || locked)

            Button(role: .destructive) {
                state.deleteSelected(app: app, playback: playback)
            } label: {
                Label("刪除", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(app.busy || locked)
        }
    }
}
