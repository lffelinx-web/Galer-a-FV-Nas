import SwiftUI

/// The app's colors, each with a light and a dark version that follow the iPhone (or the
/// appearance chosen in Configuración).
enum Palette {
    private static func dynamic(_ light: (CGFloat, CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }

    static let background = dynamic((0.93, 0.95, 0.99, 1), (0.05, 0.06, 0.09, 1))
    static let backgroundBottom = dynamic((0.97, 0.98, 1.0, 1), (0.02, 0.03, 0.05, 1))
    static let ink = dynamic((0.08, 0.11, 0.18, 1), (0.93, 0.95, 0.98, 1))
    static let secondary = dynamic((0.36, 0.40, 0.48, 1), (0.62, 0.66, 0.74, 1))
    static let accent = dynamic((0.18, 0.42, 0.91, 1), (0.36, 0.58, 1.0, 1))
    static let accentLight = dynamic((0.36, 0.62, 1.0, 1), (0.48, 0.70, 1.0, 1))
    static let tile = dynamic((0.86, 0.89, 0.95, 1), (0.14, 0.16, 0.21, 1))
    static let online = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warning = Color(red: 0.98, green: 0.62, blue: 0.15)
    static let stroke = dynamic((1, 1, 1, 0.7), (1, 1, 1, 0.12))
    /// Cards on the background: white in light mode, a raised dark gray in dark mode.
    static let card = dynamic((1, 1, 1, 0.8), (0.11, 0.12, 0.16, 0.92))
    static let cardStroke = dynamic((1, 1, 1, 1), (1, 1, 1, 0.07))

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
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.cardStroke, lineWidth: 1))
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
