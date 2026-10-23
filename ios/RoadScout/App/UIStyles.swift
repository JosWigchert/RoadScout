import SwiftUI

/// Neutral map actions with a true circular system surface.
struct MapIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            configuration.label
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
                .opacity(!isEnabled ? 0.35 : (configuration.isPressed ? 0.7 : 1))
        } else {
            configuration.label
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.background, in: Circle())
                .opacity(!isEnabled ? 0.35 : (configuration.isPressed ? 0.7 : 1))
        }
    }
}

struct GlassContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

struct GlassFloatingModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if reduceTransparency {
                content.background(.background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct GlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var prominent: Bool = false
    var cornerRadius: CGFloat = 16
    private var horizontalPadding: CGFloat = 16
    private var verticalPadding: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(background(configuration: configuration))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .opacity(reduceMotion ? 1 : (configuration.isPressed ? 0.9 : 1))
    }

    @ViewBuilder
    private func background(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            if reduceTransparency {
                prominent ? Color.accentColor : Color(.secondarySystemBackground)
            } else {
                (prominent ? Color.accentColor : Color.clear).opacity(prominent ? 0.25 : 0)
            }
        } else {
            (prominent ? Color.accentColor : Color.clear).opacity(prominent ? 0.2 : 0)
        }
    }
}

extension View {
    func glassFloatingControl(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassFloatingModifier(cornerRadius: cornerRadius))
    }

    func glassContainer(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> some View) -> some View {
        GlassContainer(spacing: spacing, content: content)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glassFloating: GlassButtonStyle { GlassButtonStyle() }
    static var glassProminentFloating: GlassButtonStyle { GlassButtonStyle(prominent: true) }
}
