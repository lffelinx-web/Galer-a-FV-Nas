import SwiftUI
import AVKit
import Photos
import PhotosUI

/// One page of the viewer.
struct ViewerPage: View {
    let item: GalleryItem
    let active: Bool
    let chrome: Bool
    /// A picture of the item with its real shape, shown at once while the sharp one loads.
    var poster: UIImage?
    var toggleChrome: () -> Void
    var zoomChanged: (Bool) -> Void

    var body: some View {
        switch item.kind {
        case .video: VideoPage(item: item, active: active, chrome: chrome, poster: poster, toggleChrome: toggleChrome)
        case .livePhoto: LivePhotoPage(item: item, poster: poster, toggleChrome: toggleChrome)
        case .photo: PhotoPage(item: item, poster: poster, toggleChrome: toggleChrome, zoomChanged: zoomChanged)
        }
    }
}

// MARK: Photos

struct PhotoPage: View {
    @EnvironmentObject var store: GalleryStore
    @Environment(\.displayScale) private var displayScale
    let item: GalleryItem
    var poster: UIImage?
    var toggleChrome: () -> Void
    var zoomChanged: (Bool) -> Void
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var loadingFull = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let shown = image ?? poster {
                    ZoomableImage(image: shown, toggleChrome: toggleChrome, zoomChanged: zoomChanged)
                } else if failure == nil {
                    ProgressView().tint(.white)
                }
                if let failure, image == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(failure).font(.subheadline).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.85)).padding(30)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: item.id) { await load(longSide: max(geo.size.width, geo.size.height)) }
        }
    }

    private func load(longSide: CGFloat) async {
        switch item.source {
        case .phone(let id):
            let pixels = longSide * displayScale * 1.5
            for await next in PhoneLibrary.shared.images(id, pixels: CGSize(width: pixels, height: pixels), fill: false) {
                // Keep the poster until something at least as sharp arrives.
                if let poster, image == nil, next.size.width * next.scale < poster.size.width * poster.scale { continue }
                image = next
            }
            if image == nil && poster == nil { failure = "No se pudo abrir la foto." }
        case .nas(let url):
            if image == nil, poster == nil { image = NASImageLoader.shared.cached(url) }
            guard let account = store.account else { if image == nil && poster == nil { failure = "Conecta el NAS para ver esta foto." }; return }
            loadingFull = true
            defer { loadingFull = false }
            do {
                let full = try await NASImageLoader.shared.image(item, account: account, maxPixels: min(longSide * displayScale * 2, 4096))
                if !Task.isCancelled { image = full }
            } catch {
                if !Task.isCancelled && image == nil && poster == nil { failure = error.localizedDescription }
            }
        }
    }
}

/// Pinch or double tap to zoom; drag to move around while zoomed.
struct ZoomableImage: View {
    let image: UIImage
    var toggleChrome: () -> Void
    var zoomChanged: (Bool) -> Void
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(max(baseScale * value.magnification, 1), 6) }
                    .onEnded { _ in
                        if scale < 1.05 { reset() } else { baseScale = scale; zoomChanged(true) }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
                    }
                    .onEnded { _ in baseOffset = offset },
                including: scale > 1 ? .all : .none
            )
            .onTapGesture(count: 2) {
                if scale > 1 { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { reset() } }
                else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { scale = 2.5; baseScale = 2.5 }
                    zoomChanged(true)
                }
            }
            .onTapGesture { toggleChrome() }
            .onChange(of: image) { reset() }
    }

    private func reset() {
        scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
        zoomChanged(false)
    }
}

// MARK: Live Photos

struct LivePhotoPage: View {
    @Environment(\.displayScale) private var displayScale
    let item: GalleryItem
    var poster: UIImage?
    var toggleChrome: () -> Void
    @State private var photo: PHLivePhoto?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let photo {
                    LivePhotoView(photo: photo).onTapGesture { toggleChrome() }
                } else if let poster {
                    Image(uiImage: poster).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Label("LIVE", systemImage: "livephoto")
                    .font(.caption2.weight(.bold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10).frame(height: 26)
                    .liquidCapsule()
                    .padding(.leading, 16).padding(.top, geo.safeAreaInsets.top + 64)
                    .allowsHitTesting(false)
            }
            .task(id: item.id) {
                guard let id = item.phoneID else { return }
                let pixels = max(geo.size.width, geo.size.height) * displayScale
                for await next in PhoneLibrary.shared.livePhoto(id, pixels: CGSize(width: pixels, height: pixels)) { photo = next }
            }
        }
    }
}

struct LivePhotoView: UIViewRepresentable {
    let photo: PHLivePhoto
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== photo { view.livePhoto = photo }
    }
}


// MARK: Videos

/// Plays one video in a loop, and tells when the first frame is on screen.
@MainActor
final class VideoModel: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var playing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    /// Remembered between videos.
    @Published var muted = UserDefaults.standard.bool(forKey: "videoMuted") {
        didSet { player.isMuted = muted; UserDefaults.standard.set(muted, forKey: "videoMuted") }
    }
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?

    var started: Bool { looper != nil }

    func start(_ item: AVPlayerItem) {
        guard looper == nil else { player.play(); return }
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = muted
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.playing = status == .playing
                // The first frame is ready: the poster gives way to the video.
                if status == .playing && !self.ready { withAnimation(.easeOut(duration: 0.25)) { self.ready = true } }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                if let length = self.player.currentItem?.duration.seconds, length.isFinite, length > 0 { self.duration = length }
            }
        }
        player.play()
    }

    func toggle() { playing ? player.pause() : player.play() }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        statusObserver?.invalidate(); statusObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        looper?.disableLooping(); looper = nil
        player.removeAllItems()
        ready = false; playing = false
    }
}

/// The video picture, without the system controls.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// A video starts by itself when it comes on screen and plays in a loop. Until the first
/// frame is ready its picture stays on screen, so there is never a black pause. NAS videos
/// stream from the NAS (MOV and MP4 in the system player; MKV, AVI and the rest in VLC).
struct VideoPage: View {
    @EnvironmentObject var store: GalleryStore
    let item: GalleryItem
    let active: Bool
    let chrome: Bool
    var poster: UIImage?
    var toggleChrome: () -> Void
    @StateObject private var model = VideoModel()
    @State private var vlcURL: URL?
    @State private var failure: String?
    @State private var scrubbing: Double?

    private var native: Bool { !item.isNAS || MediaFormat.playable.contains(item.fileExtension) }

    var body: some View {
        ZStack {
            Color.clear
            PlayerLayerView(player: model.player).opacity(model.ready ? 1 : 0)
            if let vlcURL {
                VLCInlinePlayer(url: vlcURL, active: active, chrome: chrome, muted: model.muted, toggleChrome: toggleChrome)
            }
            if !model.ready && vlcURL == nil {
                posterView
                if failure == nil && active { ProgressView().tint(.white).scaleEffect(1.2) }
            }
            if vlcURL == nil { Color.clear.contentShape(Rectangle()).onTapGesture { toggleChrome() } }
            if let failure {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(failure).font(.subheadline).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(30)
            }
            if chrome && model.ready && vlcURL == nil { controls.transition(.opacity) }
        }
        .task(id: active) {
            if active { await start() } else { model.player.pause() }
        }
        .task { await prefetch() }
        .onDisappear { model.stop(); vlcURL = nil }
    }

    @ViewBuilder private var posterView: some View {
        if let poster {
            Image(uiImage: poster).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Thumbnail(item: item, pixelSize: 700)
                .aspectRatio(item.aspect > 0 ? item.aspect : 16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Play or pause, time, position and sound, just above the viewer's bar.
    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button { model.toggle() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold)).frame(width: 34, height: 34)
                }
                .accessibilityLabel(model.playing ? "Pausa" : "Reproducir")
                Text(durationText(scrubbing.map { $0 * model.duration } ?? model.time)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { scrubbing ?? (model.duration > 0 ? model.time / model.duration : 0) }, set: { scrubbing = $0 }),
                       onEditingChanged: { editing in
                           if !editing, let value = scrubbing { model.seek(to: value); scrubbing = nil }
                       })
                    .tint(Palette.accent)
                Text(durationText(model.duration)).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
                Button { model.muted.toggle() } label: {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
                }
                .accessibilityLabel(model.muted ? "Activar sonido" : "Silenciar")
            }
            .foregroundStyle(Palette.ink)
            .buttonStyle(PressStyle())
            .padding(.horizontal, 12).frame(height: 48)
            .liquidCapsule()
            .padding(.horizontal, 14)
            .padding(.bottom, 168)
        }
    }

    private func start() async {
        if model.started || vlcURL != nil { model.player.play(); return }
        switch item.source {
        case .phone(let id):
            guard let playerItem = await PhoneLibrary.shared.playerItem(id) else { failure = "No se pudo abrir el video."; return }
            guard active else { return }
            model.start(playerItem)
        case .nas(let url):
            guard let account = store.account else { failure = "Conecta el NAS para ver este video."; return }
            let file = StreamFile(url: url, bytes: item.bytes)
            if let local = BlockCache.downloaded(file) { model.start(AVPlayerItem(url: local)); return }
            do {
                let stream = try await StreamServer.shared.url(for: file, account: account)
                guard active else { return }
                if native { model.start(AVPlayerItem(url: stream)) } else { vlcURL = stream }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// As soon as a NAS video is near, its start and end (where the index often is) are
    /// fetched, so it begins almost at once.
    private func prefetch() async {
        guard let url = item.nasURL, let account = store.account else { return }
        let file = StreamFile(url: url, bytes: item.bytes)
        guard BlockCache.downloaded(file) == nil else { return }
        await Task.detached(priority: .utility) {
            guard let total = try? await BlockCache.shared.length(file, account: account) else { return }
            let size = Int64(BlockCache.blockSize)
            let last = max(0, (total - 1) / size)
            for index in Set([0, min(1, last), last]) { _ = try? await BlockCache.shared.block(index, of: file, account: account) }
        }.value
    }
}
