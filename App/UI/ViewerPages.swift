import SwiftUI
import AVKit
import Photos
import PhotosUI

/// One page of the viewer.
struct ViewerPage: View {
    let item: GalleryItem
    let active: Bool
    let chrome: Bool
    /// The next page: a video there starts loading ahead.
    var upcoming = false
    /// A picture of the item with its real shape, shown at once while the sharp one loads.
    var poster: UIImage?
    /// Room kept free for the bars while they show, so the photo is never under them.
    var insets = EdgeInsets()
    var toggleChrome: () -> Void
    var zoomChanged: (Bool) -> Void

    var body: some View {
        Group {
            switch item.kind {
            case .video: VideoPage(item: item, active: active, chrome: chrome, upcoming: upcoming, poster: poster, insets: insets, toggleChrome: toggleChrome)
            case .livePhoto: LivePhotoPage(item: item, poster: poster, toggleChrome: toggleChrome).padding(insets)
            case .photo: PhotoPage(item: item, poster: poster, toggleChrome: toggleChrome, zoomChanged: zoomChanged).padding(insets)
            }
        }
        // Grows to the whole screen when the bars hide, and back.
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: insets)
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
    var upcoming = false
    var poster: UIImage?
    var insets = EdgeInsets()
    var toggleChrome: () -> Void
    @StateObject private var model = VideoModel()
    @State private var vlcURL: URL?
    @State private var failure: String?
    @State private var scrubbing: Double?

    private var native: Bool { !item.isNAS || MediaFormat.playable.contains(item.fileExtension) }

    var body: some View {
        ZStack {
            Color.clear
            PlayerLayerView(player: model.player).opacity(model.ready ? 1 : 0).padding(insets)
            if let vlcURL {
                VLCInlinePlayer(url: vlcURL, active: active, chrome: chrome, muted: model.muted, toggleChrome: toggleChrome)
            }
            if !model.ready && vlcURL == nil {
                posterView.padding(insets)
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
        // Only the next video loads ahead, so the NAS is not asked for every neighbour.
        .task(id: upcoming) { if upcoming { await prefetch() } }
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
    /// A slim time bar where the strip of thumbnails goes in photos.
    private var controls: some View {
        VStack {
            Spacer()
            VideoBar(playing: model.playing, time: model.time, duration: model.duration, muted: model.muted,
                     toggle: { model.toggle() }, seek: { model.seek(to: $0) }, mute: { model.muted.toggle() })
                .padding(.bottom, ViewerMetrics.videoBarBottom)
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

    /// The video after the one on screen gets its start and end (where the index often is)
    /// fetched ahead, so it begins almost at once.
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


// MARK: Video bar

/// Spacing of the viewer's bottom controls, shared by the pages and the bars.
enum ViewerMetrics {
    static let barHeight: CGFloat = 48
    @MainActor static var safeBottom: CGFloat { safeArea.bottom }
    @MainActor static var safeArea: EdgeInsets {
        let insets = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets ?? .zero
        return EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }
    /// Just above the action bar, where photos show the thumbnail strip.
    @MainActor static var videoBarBottom: CGFloat { safeBottom + 4 + barHeight + 12 }
}

/// Play or pause, the time on both sides of a thin line, and the sound.
struct VideoBar: View {
    let playing: Bool
    let time: Double
    let duration: Double
    let muted: Bool?
    var toggle: () -> Void
    var seek: (Double) -> Void
    var mute: () -> Void
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold)).frame(width: 28, height: 28)
            }
            .accessibilityLabel(playing ? "Pausa" : "Reproducir")
            Text(durationText(scrubbing.map { $0 * duration } ?? time)).font(.caption2.weight(.medium).monospacedDigit())
            ScrubLine(value: scrubbing ?? (duration > 0 ? time / duration : 0)) { value, done in
                scrubbing = done ? nil : value
                if done { seek(value) }
            }
            Text(durationText(duration)).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(Palette.secondary)
            if let muted {
                Button(action: mute) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                }
                .accessibilityLabel(muted ? "Activar sonido" : "Silenciar")
            }
        }
        .foregroundStyle(Palette.ink)
        .buttonStyle(PressStyle())
        .padding(.horizontal, 10).frame(height: 38)
        .liquidCapsule()
        .padding(.horizontal, 22)
    }
}

/// A thin progress line that grows a little while you drag it.
struct ScrubLine: View {
    let value: Double
    var changed: (Double, Bool) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.18))
                Capsule().fill(Palette.accent).frame(width: max(geo.size.width * fraction, dragging ? 8 : 4))
            }
            .frame(height: dragging ? 8 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging { withAnimation(.easeOut(duration: 0.15)) { dragging = true } }
                        changed(min(max(drag.location.x / max(geo.size.width, 1), 0), 1), false)
                    }
                    .onEnded { drag in
                        withAnimation(.easeOut(duration: 0.15)) { dragging = false }
                        changed(min(max(drag.location.x / max(geo.size.width, 1), 0), 1), true)
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Posición del video")
        .accessibilityValue("\(Int(value * 100)) %")
    }
}


// MARK: Native photo page

/// The largest rectangle with this shape that fits in `bounds`, centered. The viewer's zoom
/// and the photo page both use it, so the photo lands exactly where it stays.
func fittedRect(aspect: CGFloat, in bounds: CGRect) -> CGRect {
    guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    if aspect > bounds.width / bounds.height {
        let height = bounds.width / aspect
        return CGRect(x: bounds.minX, y: bounds.minY + (bounds.height - height) / 2, width: bounds.width, height: height)
    }
    let width = bounds.height * aspect
    return CGRect(x: bounds.minX + (bounds.width - width) / 2, y: bounds.minY, width: width, height: bounds.height)
}

/// A photo in a native zooming scroll view. Its place is computed from the photo's shape
/// and the room left by the bars, before it is ever shown, and a sharper image of the same
/// photo keeps the same place: nothing moves once it is open.
final class PhotoCell: UICollectionViewCell, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var itemID: String?
    private var insets = UIEdgeInsets.zero
    private var aspect: CGFloat = 1
    private var load: Task<Void, Never>?
    private var onTap: () -> Void = {}
    private var onZoom: (Bool) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        scroll.addSubview(imageView)
        contentView.addSubview(scroll)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    func configure(item: GalleryItem, poster: UIImage?, insets: UIEdgeInsets, onTap: @escaping () -> Void, onZoom: @escaping (Bool) -> Void) {
        self.onTap = onTap
        self.onZoom = onZoom
        accessibilityLabel = (item.isNAS ? "Foto del NAS, " : "Foto del iPhone, ") + Timeline.format(item.date, "d 'de' MMMM 'de' y")
        if itemID != item.id {
            itemID = item.id
            load?.cancel()
            scroll.setZoomScale(1, animated: false)
            show(poster, aspectFallback: CGFloat(item.aspect))
            load = Task { [weak self] in await self?.loadSharp(item, hasPoster: poster != nil) }
        }
        guard insets != self.insets else { return }
        self.insets = insets
        // The bars hide or show: the photo grows to the screen or makes room, smoothly.
        if window != nil && scroll.zoomScale <= 1.01 {
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                self.placeImage()
            }
        } else {
            setNeedsLayout()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        load?.cancel()
        load = nil
        itemID = nil
        imageView.image = nil
        scroll.setZoomScale(1, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = contentView.bounds
        if scroll.zoomScale <= 1.01 { placeImage() }
    }

    /// The photo's frame inside the room left by the bars.
    private func placeImage() {
        scroll.contentSize = scroll.bounds.size
        imageView.frame = fittedRect(aspect: aspect, in: scroll.bounds.inset(by: insets))
    }

    private func show(_ image: UIImage?, aspectFallback: CGFloat? = nil) {
        imageView.image = image
        if let image, image.size.height > 0 { aspect = image.size.width / image.size.height }
        else if let aspectFallback, aspectFallback > 0 { aspect = aspectFallback }
        if scroll.zoomScale <= 1.01 { placeImage() }
    }

    @MainActor
    private func loadSharp(_ item: GalleryItem, hasPoster: Bool) async {
        let longSide = max(bounds.width, bounds.height, 1) * traitCollection.displayScale
        switch item.source {
        case .phone(let id):
            for await next in PhoneLibrary.shared.images(id, pixels: CGSize(width: longSide * 1.5, height: longSide * 1.5), fill: false) {
                guard !Task.isCancelled, itemID == item.id else { return }
                // A blurry first image only when there is nothing on screen yet.
                if hasPoster, let current = imageView.image, next.size.width * next.scale < current.size.width * current.scale { continue }
                show(next)
            }
        case .nas(let url):
            if imageView.image == nil, let cached = NASImageLoader.shared.cached(url) { show(cached) }
            guard let account = ActiveAccount.current,
                  let full = try? await NASImageLoader.shared.image(item, account: account, maxPixels: min(longSide * 2, 4096)),
                  !Task.isCancelled, itemID == item.id else { return }
            show(full)
        }
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keeps the photo centered while it is smaller than the screen.
        let size = scrollView.bounds.size, content = imageView.frame.size
        let x = max((size.width - content.width) / 2, 0), y = max((size.height - content.height) / 2, 0)
        imageView.frame.origin = CGPoint(x: x, y: y)
        scrollView.contentSize = CGSize(width: max(content.width, size.width), height: max(content.height, size.height))
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= 1.01 { placeImage() }
        onZoom(scale > 1.01)
    }

    @objc private func tapped() { onTap() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
