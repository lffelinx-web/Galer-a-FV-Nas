import SwiftUI

#if canImport(MobileVLCKit)
import MobileVLCKit

/// Drives VLC for formats AVPlayer can't open (MKV, AVI…).
///
/// libvlc calls that touch the input (tracks, seeking, stopping) can wait for the network
/// while VLC is buffering, so they run on `queue`; the main thread only reads cached values.
@MainActor
final class VLCController: ObservableObject {
    struct Track: Identifiable, Hashable { var id: Int32; var name: String }

    let player = VLCMediaPlayer()
    @Published private(set) var time: Double = 0
    @Published private(set) var length: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var loading = true
    @Published private(set) var ended = false
    @Published private(set) var failed = false
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var audioTrack: Int32 = -1
    @Published private(set) var subtitleTrack: Int32 = -1
    private let queue = DispatchQueue(label: "lfaz.galeria.vlc", qos: .userInitiated)
    private var timer: Timer?
    private var lastState: VLCMediaPlayerState?
    private var tracksLoaded = false
    private var loadingTracks = false

    func load(_ url: URL, start: Double) {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        // Plays in a loop, like the other videos of the gallery.
        media.addOption(":input-repeat=65535")
        if start > 0 { media.addOption(":start-time=\(Int(start))") }
        player.media = media
        let player = player
        queue.async { player.play() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func refresh() {
        time = Double(player.time.intValue) / 1000
        let total = Double(player.media?.length.intValue ?? 0) / 1000
        if total > 0 { length = total }
        let state = player.state
        playing = state == .playing || (state == .buffering && player.isPlaying)
        switch state {
        case .opening, .buffering: loading = !playing
        case .ended: ended = true; loading = false
        case .error: failed = true; loading = false
        default: loading = false
        }
        // Track lists change when streams appear; read them off the main thread.
        if !tracksLoaded || (state != lastState && (state == .playing || state == .esAdded)) { loadTracks() }
        lastState = state
    }

    func loadTracks() {
        guard !loadingTracks else { return }
        loadingTracks = true
        let player = player
        queue.async { [weak self] in
            let audio = Self.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
            let subtitles = Self.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
            let currentAudio = player.currentAudioTrackIndex, currentSubtitle = player.currentVideoSubTitleIndex
            Task { @MainActor in
                guard let self else { return }
                self.audioTracks = audio; self.subtitleTracks = subtitles
                self.audioTrack = currentAudio; self.subtitleTrack = currentSubtitle
                self.tracksLoaded = !audio.isEmpty
                self.loadingTracks = false
            }
        }
    }

    nonisolated private static func tracks(names: [Any]?, indexes: [Any]?) -> [Track] {
        let names = (names ?? []).map { "\($0)" }
        let indexes = (indexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        return zip(indexes, names).map { Track(id: $0, name: $1) }
    }

    private func control(_ action: @escaping (VLCMediaPlayer) -> Void) {
        let player = player
        queue.async { action(player) }
    }

    func togglePlay() {
        let wasPlaying = playing
        playing.toggle()
        control { wasPlaying ? $0.pause() : $0.play() }
    }
    func jump(_ seconds: Int32) {
        time = max(0, min(length, time + Double(seconds)))
        control { seconds > 0 ? $0.jumpForward(seconds) : $0.jumpBackward(-seconds) }
    }
    func seek(to fraction: Double) {
        let value = Float(min(max(fraction, 0), 1))
        time = Double(value) * length; loading = true
        control { $0.position = value }
    }
    func selectAudio(_ id: Int32) { audioTrack = id; control { $0.currentAudioTrackIndex = id } }
    func selectSubtitle(_ id: Int32) { subtitleTrack = id; control { $0.currentVideoSubTitleIndex = id } }

    /// Stopping waits for VLC's network thread; never block the screen while it closes.
    func stop() {
        timer?.invalidate(); timer = nil
        control { $0.stop() }
    }
}

struct VLCVideoView: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black
        // VLC adds its own rendering subview, which would swallow taps meant for the controls.
        view.isUserInteractionEnabled = false
        player.drawable = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// A video VLC plays inside the viewer (MKV, AVI, WebM…): it starts by itself, loops and
/// follows the viewer's controls and sound setting.
struct VLCInlinePlayer: View {
    let url: URL
    let active: Bool
    let chrome: Bool
    let muted: Bool
    var toggleChrome: () -> Void
    @StateObject private var controller = VLCController()
    @State private var scrubbing: Double?

    var body: some View {
        ZStack {
            Color.black
            VLCVideoView(player: controller.player).allowsHitTesting(false)
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleChrome() }
            if controller.loading { ProgressView().tint(.white) }
            if controller.failed {
                Label("No se pudo reproducir este video.", systemImage: "exclamationmark.triangle").foregroundStyle(.white)
            }
            if chrome { controls.transition(.opacity) }
        }
        .onAppear {
            controller.load(url, start: 0)
            applyVolume()
        }
        .onChange(of: active) { _, isActive in
            if isActive != controller.playing { controller.togglePlay() }
        }
        .onChange(of: muted) { applyVolume() }
        .onDisappear { controller.stop() }
    }

    private func applyVolume() { controller.player.audio?.volume = muted ? 0 : 100 }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.playing ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold)).frame(width: 34, height: 34)
                }
                .accessibilityLabel(controller.playing ? "Pausa" : "Reproducir")
                Text(durationText(scrubbing.map { $0 * controller.length } ?? controller.time)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { scrubbing ?? (controller.length > 0 ? controller.time / controller.length : 0) },
                                      set: { scrubbing = $0 }),
                       onEditingChanged: { editing in
                           if !editing, let value = scrubbing { controller.seek(to: value); scrubbing = nil }
                       })
                    .tint(Palette.accent)
                Text(durationText(controller.length)).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            }
            .foregroundStyle(Palette.ink)
            .buttonStyle(PressStyle())
            .padding(.horizontal, 12).frame(height: 48)
            .liquidCapsule()
            .padding(.horizontal, 14)
            .padding(.bottom, 168)
        }
    }
}

#else

/// Without VLCKit (a build without the framework), other formats cannot play.
struct VLCInlinePlayer: View {
    let url: URL
    let active: Bool
    let chrome: Bool
    let muted: Bool
    var toggleChrome: () -> Void
    var body: some View {
        Label("Este formato necesita el reproductor VLC.", systemImage: "film").foregroundStyle(.white)
    }
}

#endif
