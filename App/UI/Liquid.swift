import SwiftUI

/// Liquid Glass on iOS 26; a bright translucent material on earlier versions.
extension View {
    @ViewBuilder func liquidCapsule(interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Palette.stroke, lineWidth: 0.75))
                .shadow(color: Palette.accent.opacity(0.10), radius: 14, y: 6)
        }
    }

    /// One piece of a `GlassGroup`; pieces that share an id melt into each other when the
    /// layout changes, like the system tab bar.
    @ViewBuilder func glassPiece<S: Shape>(_ shape: S, id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape).glassEffectID(id, in: namespace)
        } else {
            background {
                shape.fill(.regularMaterial)
                    .overlay(shape.stroke(Palette.stroke, lineWidth: 0.75))
                    .shadow(color: Palette.accent.opacity(0.12), radius: 16, y: 6)
                    .matchedGeometryEffect(id: id, in: namespace)
            }
        }
    }

    /// The blue lens behind the selected item that slides between items.
    func selectionLens(_ active: Bool, in namespace: Namespace.ID) -> some View {
        background {
            if active {
                Capsule().fill(Palette.selection)
                    .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 0.75))
                    .shadow(color: Palette.accent.opacity(0.35), radius: 8, y: 3)
                    .matchedGeometryEffect(id: "lens", in: namespace)
            }
        }
    }
}

/// Lets nearby glass pieces blend and morph on iOS 26; a plain group before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing) { content() } } else { content() }
    }
}

/// A round glass button, such as the Inicio and Configuración buttons of the compact bar.
struct GlassCircleButton: View {
    var systemImage: String
    var label: String
    var id: String
    var namespace: Namespace.ID
    var size: CGFloat = 58
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassPiece(Circle(), id: id, in: namespace)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

/// A light squeeze when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
