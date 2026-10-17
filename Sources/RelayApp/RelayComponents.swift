import AppKit
import SwiftUI

struct RelayWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            RelayVibrancy()
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.65))
        }
    }
}

private struct RelayVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct RelayPageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 9) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.6)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
    }
}

struct RelayHeroSymbol: View {
    let symbol: String
    var tint: Color = .primary
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 36, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 82, height: 82)
            .modifier(RelayGlassPlate())
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.07), radius: 16, x: 0, y: 8)
            .accessibilityHidden(true)
    }
}

private struct RelayGlassPlate: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 23))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 23))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 23))
                .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
    }
}

struct RelayDevicePair: View {
    let toDrive: Bool
    var size: CGFloat = 35
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 19) {
            device(toDrive ? "desktopcomputer" : "externaldrive")
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
            device(toDrive ? "externaldrive" : "desktopcomputer")
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func device(_ symbol: String) -> some View {
        let glyph = Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .frame(width: size * 1.3)
        if contrast == .increased {
            glyph.foregroundStyle(.primary)
        } else {
            glyph.foregroundStyle(LinearGradient(stops: [
                .init(color: .primary.opacity(0.65), location: 0),
                .init(color: .primary.opacity(0.95), location: 0.4),
                .init(color: .primary.opacity(0.68), location: 0.65),
                .init(color: .primary.opacity(0.88), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .shadow(color: .white.opacity(colorScheme == .dark ? 0.1 : 0.65), radius: 0.4, y: -0.5)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.14), radius: 0.7, y: 1)
        }
    }
}

struct RelayDirectionSurface: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(LinearGradient(colors: [
                        .white.opacity(colorScheme == .dark ? 0.24 : 0.8),
                        .white.opacity(0.02),
                        .black.opacity(colorScheme == .dark ? 0.2 : 0.06)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                    .padding(0.7)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(contrast == .increased ? 0.4 : 0.1),
                                  lineWidth: selected ? 1.2 : 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : (selected ? 0.07 : 0.04)),
                    radius: selected ? 18 : 12, y: selected ? 8 : 5)
    }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

struct RelayPrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Text(title).frame(minWidth: 98)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}

struct RelayChoiceStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: configuration.isPressed)
    }
}
