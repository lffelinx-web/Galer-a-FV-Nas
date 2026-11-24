import SwiftUI
import AVKit
import Photos
import PhotosUI

/// Full-screen viewer: swipe sideways between photos, pinch or double tap to zoom, swipe
/// down to close.
struct ViewerView: View {
    let context: ViewerContext
    @EnvironmentObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: String?
    @State private var chrome = true
    @State private var zoomed = false
    @State private var dragY: CGFloat = 0
    @State private var albumItem: GalleryItem?
    /// 0: the photo sits on its tile; 1: it fills the screen. Animated when opening and closing.
    @State private var progress: CGFloat
    @State private var settled: Bool
    private let positions: [String: Int]

    private var hasSource: Bool { context.sourceFrame != nil && context.sourceImage != nil }

    init(context: ViewerContext) {
        self.context = context
        _current = State(initialValue: context.start)
        let zooms = context.sourceFrame != nil && context.sourceImage != nil
        _progress = State(initialValue: zooms ? 0 : 1)
        _settled = State(initialValue: !zooms)
        var positions: [String: Int] = [:]
        positions.reserveCapacity(context.items.count)
        for (index, item) in context.items.enumerated() { positions[item.id] = index }
        self.positions = positions
    }

    private var currentItem: GalleryItem? { current.flatMap { positions[$0] }.map { context.items[$0] } }

    var body: some View {
        ZStack {
            Color.black.opacity((1 - min(dragY / 500, 0.7)) * progress).ignoresSafeArea()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(context.items) { item in
                        ViewerPage(item: item, active: item.id == current,
                                   toggleChrome: { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } },
                                   zoomChanged: { zoomed = $0 })
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .scrollDisabled(zoomed)
            .ignoresSafeArea()
            .offset(y: dragY)
            .scaleEffect(1 - min(dragY / 2500, 0.15))
            .simultaneousGesture(closeGesture, including: zoomed ? .none : .all)
            .opacity(settled ? 1 : 0)
            if !settled { zoomLayer }
        }
        .overlay(alignment: .top) {
            if chrome && settled { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .presentationBackground(.clear)
        .onAppear {
            guard !settled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { progress = 1 } completion: { settled = true }
        }
        .statusBarHidden(!chrome)
        .sheet(item: $albumItem) { AddToAlbumSheet(itemID: $0.id).environmentObject(store) }
        .onChange(of: current) { zoomed = false }
    }

    /// The tile's picture moving between its place in the wall and the full screen.
    private var zoomLayer: some View {
        GeometryReader { geo in
            if let image = context.sourceImage, let source = context.sourceFrame {
                let target = fitted(aspect: aspect(of: image), in: CGRect(origin: .zero, size: geo.size))
                let frame = CGRect(x: source.minX + (target.minX - source.minX) * progress,
                                   y: source.minY + (target.minY - source.minY) * progress + dragY,
                                   width: source.width + (target.width - source.width) * progress,
                                   height: source.height + (target.height - source.height) * progress)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8 * (1 - progress), style: .continuous))
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func aspect(of image: UIImage) -> CGFloat {
        if let item = context.items.first(where: { $0.id == context.start }), item.aspect != 1, item.aspect > 0 { return CGFloat(item.aspect) }
        return image.size.height > 0 ? image.size.width / image.size.height : 1
    }

    private func fitted(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect > 0, bounds.height > 0 else { return bounds }
        if aspect > bounds.width / bounds.height {
            let height = bounds.width / aspect
            return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }
        let width = bounds.height * aspect
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
    }

    /// Back to the tile when the photo shown is the one that was tapped; otherwise a plain close.
    private func close() {
        guard hasSource, current == context.start, !zoomed else { dismiss(); return }
        settled = false
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { progress = 0; dragY = 0 } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) * 1.4 else { return }
                dragY = value.translation.height
            }
            .onEnded { value in
                if dragY > 130 || value.predictedEndTranslation.height > 400 && dragY > 40 { close() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 } }
            }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                    .frame(width: 46, height: 46).contentShape(Circle())
                    .liquidCircle()
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Cerrar")
            if let item = currentItem {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Timeline.format(item.date, "d 'de' MMMM 'de' y")).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(detail(item)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 14).frame(height: 46)
                .liquidCapsule()
                .layoutPriority(-1)
                Spacer(minLength: 0)
                actions(item)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    /// Favorito, Agregar a álbum and Ocultar, in one glass capsule.
    private func actions(_ item: GalleryItem) -> some View {
        let favorite = store.isFavorite(item)
        let hidden = store.isHidden(item)
        return HStack(spacing: 0) {
            Button { store.toggleFavorite(item) } label: {
                Image(systemName: favorite ? "heart.fill" : "heart").foregroundStyle(favorite ? Color.red : Palette.ink)
                    .frame(width: 42, height: 46).contentShape(Rectangle())
            }
            .accessibilityLabel(favorite ? "Quitar de favoritos" : "Agregar a favoritos")
            .sensoryFeedback(.impact(weight: .light), trigger: favorite)
            Button { albumItem = item } label: {
                Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(Palette.ink)
                    .frame(width: 42, height: 46).contentShape(Rectangle())
            }
            .accessibilityLabel("Agregar a álbum")
            Button { store.setHidden(item, !hidden) } label: {
                Image(systemName: hidden ? "eye" : "eye.slash").foregroundStyle(Palette.ink)
                    .frame(width: 42, height: 46).contentShape(Rectangle())
            }
            .accessibilityLabel(hidden ? "Mostrar en Fototeca" : "Ocultar")
        }
        .font(.system(size: 17, weight: .semibold))
        .buttonStyle(PressStyle())
        .padding(.horizontal, 4)
        .liquidCapsule()
    }

    private func detail(_ item: GalleryItem) -> String {
        let time = Timeline.format(item.date, "HH:mm")
        if item.isNAS {
            let place = item.folder.map { $0.isEmpty ? store.nasLabel : $0 } ?? store.nasLabel
            return "\(time) · NAS · \(place)"
        }
        return "\(time) · iPhone"
    }
}

extension View {
    @ViewBuilder func liquidCircle() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.regularMaterial, in: Circle()).overlay(Circle().stroke(Palette.stroke, lineWidth: 0.75))
        }
    }
}

struct ViewerPage: View {
    let item: GalleryItem
    let active: Bool
    var toggleChrome: () -> Void
    var zoomChanged: (Bool) -> Void

    var body: some View {
        switch item.kind {
        case .video: VideoPage(item: item, active: active, toggleChrome: toggleChrome)
        case .livePhoto: LivePhotoPage(item: item, toggleChrome: toggleChrome)
        case .photo: PhotoPage(item: item, toggleChrome: toggleChrome, zoomChanged: zoomChanged)
        }
    }
}

// MARK: Photos

struct PhotoPage: View {
    @EnvironmentObject var store: GalleryStore
    @Environment(\.displayScale) private var displayScale
    let item: GalleryItem
    var toggleChrome: () -> Void
    var zoomChanged: (Bool) -> Void
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var loadingFull = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    ZoomableImage(image: image, toggleChrome: toggleChrome, zoomChanged: zoomChanged)
                } else if failure == nil {
                    ProgressView().tint(.white)
                }
                if let failure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(failure).font(.subheadline).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.85)).padding(30)
                }
                if loadingFull && image != nil {
                    ProgressView().tint(.white).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.bottom, 30)
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
            for await next in PhoneLibrary.shared.images(id, pixels: CGSize(width: pixels, height: pixels), fill: false) { image = next }
            if image == nil { failure = "No se pudo abrir la foto." }
        case .nas(let url):
            if image == nil { image = NASImageLoader.shared.cached(url) }
            guard let account = store.account else { failure = "Conecta el NAS para ver esta foto."; return }
            loadingFull = true
            defer { loadingFull = false }
            do {
                let full = try await NASImageLoader.shared.image(item, account: account, maxPixels: min(longSide * displayScale * 2, 4096))
                if !Task.isCancelled { image = full }
            } catch {
                if !Task.isCancelled && image == nil { failure = error.localizedDescription }
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
    var toggleChrome: () -> Void
    @State private var photo: PHLivePhoto?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let photo {
                    LivePhotoView(photo: photo).onTapGesture { toggleChrome() }
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

/// A video: iPhone videos through PhotoKit; NAS videos streamed from the NAS while they
/// play (MOV and MP4 in the system player, MKV, AVI and the rest in VLC).
struct VideoPage: View {
    @EnvironmentObject var store: GalleryStore
    let item: GalleryItem
    let active: Bool
    var toggleChrome: () -> Void
    @State private var player: AVPlayer?
    @State private var vlcURL: URL?
    @State private var failure: String?
    @State private var started = false

    /// Formats the system player opens; the rest go to VLC.
    private var native: Bool { !item.isNAS || MediaFormat.playable.contains(item.fileExtension) }

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else if let vlcURL {
                VLCInlinePlayer(url: vlcURL, active: active)
            } else {
                Thumbnail(item: item, pixelSize: 700)
                    .aspectRatio(item.aspect > 0 ? item.aspect : 16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { toggleChrome() }
                overlay
            }
        }
        .onChange(of: active) { _, isActive in
            if isActive { if player != nil { player?.play() } else if !item.isNAS { Task { await prepare() } } } else { pause() }
        }
        .task { if active && !item.isNAS { await prepare() } }
        .onDisappear { stop() }
    }

    @ViewBuilder private var overlay: some View {
        if let failure {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(failure).font(.subheadline).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(30)
        } else if item.isNAS {
            Button { Task { await startNAS() } } label: {
                Group {
                    if started { ProgressView().tint(Palette.accent) }
                    else { Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(Palette.accent) }
                }
                .frame(width: 84, height: 84).contentShape(Circle())
                .liquidCircle()
            }
            .buttonStyle(PressStyle())
            .disabled(started)
            .accessibilityLabel("Reproducir")
        } else {
            ProgressView().tint(.white)
        }
    }

    private func prepare() async {
        guard player == nil, case .phone(let id) = item.source else { return }
        guard let playerItem = await PhoneLibrary.shared.playerItem(id) else { failure = "No se pudo abrir el video."; return }
        guard active else { return }
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        player.play()
    }

    /// Starts at once: the local stream server fetches the parts from the NAS as they play.
    private func startNAS() async {
        guard let url = item.nasURL, let account = store.account else { failure = "Conecta el NAS para ver este video."; return }
        started = true
        defer { started = false }
        let file = StreamFile(url: url, bytes: item.bytes)
        if let local = BlockCache.downloaded(file) { play(local); return }
        do {
            let stream = try await StreamServer.shared.url(for: file, account: account)
            if native { play(stream) } else { vlcURL = stream }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func play(_ url: URL) {
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    private func pause() { player?.pause() }

    private func stop() {
        player?.pause()
        player = nil
        vlcURL = nil
    }
}
