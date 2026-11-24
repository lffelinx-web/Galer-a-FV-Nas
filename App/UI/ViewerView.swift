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
    private let positions: [String: Int]

    init(context: ViewerContext) {
        self.context = context
        _current = State(initialValue: context.start)
        var positions: [String: Int] = [:]
        positions.reserveCapacity(context.items.count)
        for (index, item) in context.items.enumerated() { positions[item.id] = index }
        self.positions = positions
    }

    private var currentItem: GalleryItem? { current.flatMap { positions[$0] }.map { context.items[$0] } }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(dragY / 500, 0.7)).ignoresSafeArea()
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
        }
        .overlay(alignment: .top) {
            if chrome { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .statusBarHidden(!chrome)
        .sheet(item: $albumItem) { AddToAlbumSheet(itemID: $0.id).environmentObject(store) }
        .onChange(of: current) { zoomed = false }
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) * 1.4 else { return }
                dragY = value.translation.height
            }
            .onEnded { value in
                if dragY > 130 || value.predictedEndTranslation.height > 400 && dragY > 40 { dismiss() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 } }
            }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                    .frame(width: 46, height: 46).contentShape(Circle())
                    .liquidCircle()
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Cerrar")
            Spacer(minLength: 0)
            if let item = currentItem {
                VStack(spacing: 1) {
                    Text(Timeline.format(item.date, "d 'de' MMMM 'de' y")).font(.subheadline.weight(.semibold))
                    Text(detail(item)).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 18).frame(height: 46)
                .liquidCapsule()
            }
            Spacer(minLength: 0)
            Button { albumItem = currentItem } label: {
                Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
                    .frame(width: 46, height: 46).contentShape(Circle())
                    .liquidCircle()
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Agregar a álbum")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
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

struct VideoPage: View {
    @EnvironmentObject var store: GalleryStore
    let item: GalleryItem
    let active: Bool
    var toggleChrome: () -> Void
    @State private var player: AVPlayer?
    @State private var progress: Double?
    @State private var failure: String?
    @State private var download: Task<Void, Never>?

    private var playable: Bool { !item.isNAS || MediaFormat.playable.contains(item.fileExtension) }

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                Thumbnail(item: item, pixelSize: 700)
                    .aspectRatio(item.aspect > 0 ? item.aspect : 16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { toggleChrome() }
                overlay
            }
        }
        .onChange(of: active) { _, isActive in
            if isActive { Task { await prepare() } } else { stop() }
        }
        .task { if active { await prepare() } }
        .onDisappear { stop() }
    }

    @ViewBuilder private var overlay: some View {
        if let failure {
            message(failure, symbol: "exclamationmark.triangle")
        } else if !playable {
            message("Los videos \(item.fileExtension.uppercased()) se podrán reproducir en una próxima versión.", symbol: "film")
        } else if let progress {
            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 5)
                    Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%").font(.caption.weight(.bold)).foregroundStyle(.white).monospacedDigit()
                }
                .frame(width: 64, height: 64)
                Text("Descargando del NAS…").font(.subheadline).foregroundStyle(.white)
                Button("Cancelar") { download?.cancel(); download = nil; self.progress = nil }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(24)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else if item.isNAS {
            Button { startDownload() } label: {
                Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(Palette.accent)
                    .frame(width: 84, height: 84).contentShape(Circle())
                    .liquidCircle()
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Reproducir")
        } else {
            ProgressView().tint(.white)
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.title)
            Text(text).font(.subheadline).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(30)
    }

    private func prepare() async {
        guard player == nil else { return }
        switch item.source {
        case .phone(let id):
            guard let playerItem = await PhoneLibrary.shared.playerItem(id) else { failure = "No se pudo abrir el video."; return }
            guard active else { return }
            let player = AVPlayer(playerItem: playerItem)
            self.player = player
            player.play()
        case .nas(let url):
            let file = NASImageLoader.videoFile(url)
            if playable && FileManager.default.fileExists(atPath: file.path) { play(file) }
        }
    }

    private func startDownload() {
        guard let url = item.nasURL, let account = store.account else { failure = "Conecta el NAS para ver este video."; return }
        let file = NASImageLoader.videoFile(url)
        progress = 0
        download = Task {
            do {
                try await NASTransport(account).download(url, to: file) { value in
                    Task { @MainActor in if self.progress != nil { self.progress = value } }
                }
                progress = nil
                if active && !Task.isCancelled { play(file) }
            } catch {
                progress = nil
                if !Task.isCancelled && !(error is CancellationError) { failure = error.localizedDescription }
            }
        }
    }

    private func play(_ file: URL) {
        let player = AVPlayer(url: file)
        self.player = player
        player.play()
    }

    private func stop() {
        player?.pause()
        player = nil
    }
}
