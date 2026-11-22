import SwiftUI

/// Central Darkroom Charcoal / White palette with Navy-Blue & Coral-Orange accents (Build 39).
/// Main workspace uses true neutral black/dark-gray surfaces and crisp white typography for
/// distraction-free media editing, with blue and vibrant coral-orange reserved as key accents.
enum StudioTheme {
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
