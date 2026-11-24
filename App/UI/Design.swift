import SwiftUI

enum Palette {
    static let background = Color(red: 0.93, green: 0.95, blue: 0.99)
    static let backgroundBottom = Color(red: 0.97, green: 0.98, blue: 1.0)
    static let ink = Color(red: 0.08, green: 0.11, blue: 0.18)
    static let secondary = Color(red: 0.36, green: 0.40, blue: 0.48)
    static let accent = Color(red: 0.18, green: 0.42, blue: 0.91)
    static let accentLight = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let tile = Color(red: 0.86, green: 0.89, blue: 0.95)
    static let online = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warning = Color(red: 0.98, green: 0.62, blue: 0.15)
    static let stroke = Color.white.opacity(0.7)

    static var selection: LinearGradient {
        LinearGradient(colors: [accentLight, accent], startPoint: .top, endPoint: .bottom)
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Palette.background, Palette.backgroundBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}

/// The two slanted strokes of the LF’AZ logo.
struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        HStack(spacing: size * 0.08) {
            ForEach(0..<2, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient(colors: index == 0 ? [Color(red: 0.55, green: 0.80, blue: 1), Palette.accentLight] : [Palette.accentLight, Palette.accent],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.26, height: size * 0.95)
                    .rotationEffect(.degrees(28))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// «LF’AZ Galería» as in the sketch.
struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            HStack(spacing: 0) {
                Text("LF’AZ").fontWeight(.bold)
                Text(" Galería").fontWeight(.regular)
            }
            .font(.system(size: 22))
            .foregroundStyle(Palette.ink)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LF’AZ Galería")
    }
}

/// «● NAS conectado • DS120j».
/// «● NAS conectado • DS120j», or just «● DS120j ⌄» where space is short (it opens details).
struct StatusPill: View {
    @EnvironmentObject var store: GalleryStore
    var short = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(store.nasState.color).frame(width: 8, height: 8)
                .overlay(Circle().stroke(store.nasState.color.opacity(0.35), lineWidth: 3))
            Text(short ? (store.account == nil ? "Sin NAS" : store.nasLabel) : store.statusText)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.85)).lineLimit(1)
            if short { Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.secondary) }
        }
        .fixedSize()
        .padding(.horizontal, 12).frame(height: 32)
        .liquidCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.statusText)
    }
}

/// The NAS icon: a server on a blue tile.
struct NASBadge: View {
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: "server.rack")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.selection, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: Palette.accent.opacity(0.25), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white, lineWidth: 1))
            .shadow(color: Palette.accent.opacity(0.06), radius: 12, y: 4)
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var action: (title: String, run: () -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(Palette.accent)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
            Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run)
                    .font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 22).frame(height: 44)
                    .background(Palette.selection, in: Capsule())
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
