import SwiftUI

/// Central Darkroom Charcoal / White palette with Navy-Blue & Coral-Orange accents (Build 39).
/// Main workspace uses true neutral black/dark-gray surfaces and crisp white typography for
/// distraction-free media editing, with blue and vibrant coral-orange reserved as key accents.
enum StudioTheme {
    // Unified Corner Radius Tokens (Option A: Capsule buttons + 14pt cards + 10pt wells/inputs)
    enum Radius {
        static let card: CGFloat = 14
        static let well: CGFloat = 10
        static let control: CGFloat = 10
    }

    // Brand accent tokens
    static let navy = Color(red: 0.078, green: 0.129, blue: 0.239)          // #14213D deep navy accent
    static let cream = Color(red: 0.961, green: 0.961, blue: 0.969)         // #F5F5F7 crisp white text
    static let coral = Color(red: 0.957, green: 0.420, blue: 0.325)         // #F46B53 vibrant coral-orange CTA accent
    static let neutralAccent = Color(red: 0.310, green: 0.545, blue: 1.000) // #4F8BFF crisp blue interactive accent

    // True neutral black-gray pro darkroom surfaces
    static let well = Color(red: 0.047, green: 0.047, blue: 0.055)          // #0C0C0E deepest dark well
    static let canvas = Color(red: 0.067, green: 0.067, blue: 0.075)        // #111113 main dark canvas
    static let panel = Color(red: 0.094, green: 0.094, blue: 0.106)         // #18181B sidebar & top bar
    static let surface = Color(red: 0.133, green: 0.133, blue: 0.149)       // #222226 card surface
    static let elevated = Color(red: 0.169, green: 0.169, blue: 0.188)      // #2B2B30 elevated / focused card

    // Borders & crisp white-on-dark typography hierarchy
    static let border = Color.white.opacity(0.10)
    static let borderStrong = Color.white.opacity(0.20)
    static let textPrimary = Color(red: 0.961, green: 0.961, blue: 0.969)   // #F5F5F7
    static let textSecondary = Color.white.opacity(0.72)
    static let textMuted = Color.white.opacity(0.48)

    // Accent & semantic tones
    static let accent = coral
    static let accentSoft = coral.opacity(0.18)
    static let warmHighlight = Color(red: 0.965, green: 0.690, blue: 0.480)
    static let success = Color(red: 0.260, green: 0.780, blue: 0.540)       // Ready green
    static let warning = Color(red: 0.945, green: 0.720, blue: 0.300)       // Actionable warning amber
    static let danger = Color(red: 0.920, green: 0.360, blue: 0.360)        // Error red only
}

/// Sleek dark-gray header background with subtle navy-blue & coral-orange edge accents.
/// Preserves neutral darkroom contrast without competing with media or stealing layout space.
struct StudioWarmGlowBackground: View {
    var intensity: Double = 1.0
    var base: Color = StudioTheme.panel

    var body: some View {
        ZStack {
            base
            RadialGradient(
                colors: [
                    StudioTheme.navy.opacity(0.32 * intensity),
                    Color.clear
                ],
                center: UnitPoint(x: 0.12, y: 0.0),
                startRadius: 10,
                endRadius: 340
            )
            RadialGradient(
                colors: [
                    StudioTheme.coral.opacity(0.07 * intensity),
                    Color.clear
                ],
                center: UnitPoint(x: 0.86, y: 0.15),
                startRadius: 10,
                endRadius: 300
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Unified Rounded Pill Button & Edits-Style Card Primitives (v1.1.1 / v1.2 UI)

enum KliporaPillVariant {
    case primary       // Vibrant coral CTA
    case accent        // Crisp blue highlight
    case secondary     // Edits-style calm dark gray pill
    case subtle        // Low-contrast translucent pill
    case destructive   // Muted danger pill
}

struct KliporaPillButtonStyle: ButtonStyle {
    var variant: KliporaPillVariant = .secondary
    var compact: Bool = false
    var fullWidth: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = {
            switch variant {
            case .primary: return StudioTheme.cream
            case .accent: return .white
            case .secondary: return StudioTheme.textPrimary
            case .subtle: return StudioTheme.textSecondary
            case .destructive: return StudioTheme.danger
            }
        }()
        let bg: Color = {
            switch variant {
            case .primary: return StudioTheme.coral
            case .accent: return StudioTheme.neutralAccent
            case .secondary: return Color.white.opacity(configuration.isPressed ? 0.16 : 0.10)
            case .subtle: return Color.white.opacity(configuration.isPressed ? 0.11 : 0.06)
            case .destructive: return StudioTheme.danger.opacity(configuration.isPressed ? 0.24 : 0.14)
            }
        }()
        let border: Color = {
            switch variant {
            case .primary, .accent: return Color.white.opacity(0.14)
            case .secondary: return Color.white.opacity(0.11)
            case .subtle: return Color.white.opacity(0.07)
            case .destructive: return StudioTheme.danger.opacity(0.32)
            }
        }()

        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: variant == .primary ? .semibold : .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, compact ? 11 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(bg, in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1.0) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct KliporaGroupedCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.114, green: 0.118, blue: 0.133), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
        )
    }
}

/// Unified Capsule Segmented Control (replaces macOS square-corner .pickerStyle(.segmented))
struct KliporaSegmentedControl<SelectionValue: Hashable>: View {
    let options: [(value: SelectionValue, label: String)]
    @Binding var selection: SelectionValue
    var activeColor: Color = StudioTheme.neutralAccent

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option.value
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .white : StudioTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            isSelected ? activeColor : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }
}

/// Unified Capsule Dropdown Menu Picker (replaces macOS square-corner Menu Picker)
struct KliporaPillMenuPicker<SelectionValue: Hashable>: View {
    let options: [(value: SelectionValue, label: String)]
    @Binding var selection: SelectionValue
    var placeholder: String = ""
    var fullWidth: Bool = false

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? placeholder
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if fullWidth {
                    Spacer(minLength: 4)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5.5)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}
