import SwiftUI

/// The notchide design system.
///
/// The notch panel is *always* a dark "screenshot" surface regardless of the
/// system appearance — these tokens are fixed, not semantic/appearance-driven.
/// Values come straight from the approved visual spec.
public enum Theme {

    // MARK: Surfaces

    /// Panel gradient top (`#1d1f27`).
    public static let panelTop = Color(hex: 0x1D1F27)
    /// Panel gradient bottom (`#141419`).
    public static let panelBottom = Color(hex: 0x141419)

    /// The vertical panel background gradient shared by all surfaces.
    public static let panelGradient = LinearGradient(
        colors: [panelTop, panelBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// A slightly raised inner surface (chips, command block, tail).
    public static let raisedSurface = Color(hex: 0x20222B)
    public static let sunkenSurface = Color(hex: 0x121217)

    // MARK: Hairlines (rgba white 0.055–0.10)

    public static let hairlineSoft = Color.white.opacity(0.055)
    public static let hairline = Color.white.opacity(0.075)
    public static let hairlineStrong = Color.white.opacity(0.10)

    // MARK: Text

    public static let textPrimary = Color(hex: 0xEAEAF1)
    public static let textSecondary = Color(hex: 0xA6A7B2)
    public static let textTertiary = Color(hex: 0x6F707B)

    // MARK: Glyph / lane states

    /// flowing — calm teal.
    public static let flowing = Color(hex: 0x34D6AC)
    /// needs-you — amber (pulsing ring).
    public static let needsYou = Color(hex: 0xF5B13A)
    /// done — green.
    public static let done = Color(hex: 0x54CF95)
    /// error — red.
    public static let error = Color(hex: 0xF2807A)

    // MARK: Primary action (teal → violet)

    public static let primaryGradientStart = Color(hex: 0x37D9C1)
    public static let primaryGradientEnd = Color(hex: 0x7B78FF)
    public static let primaryGradient = LinearGradient(
        colors: [primaryGradientStart, primaryGradientEnd],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: Diff

    public static let diffAddText = Color(hex: 0x54CF95)
    public static let diffAddBackground = Color(hex: 0x54CF95).opacity(0.10)
    public static let diffRemoveText = Color(hex: 0xF2807A)
    public static let diffRemoveBackground = Color(hex: 0xF2807A).opacity(0.10)
    public static let diffGutter = Color.white.opacity(0.03)

    // MARK: Syntax highlighting (built-in Swift keyword highlighter)

    public static let synKeyword = Color(hex: 0xC792EA)  // violet
    public static let synType = Color(hex: 0x82AAFF)     // blue
    public static let synString = Color(hex: 0xC3E88D)   // soft green
    public static let synNumber = Color(hex: 0xF78C6C)   // orange
    public static let synComment = Color(hex: 0x6F707B)  // tertiary grey
    public static let synPlain = textPrimary

    // MARK: Geometry

    public enum Radius {
        public static let panel: CGFloat = 16
        public static let card: CGFloat = 12
        public static let control: CGFloat = 11
        public static let chip: CGFloat = 7
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 22
    }
}

extension Color {
    /// Builds a color from a 24-bit `0xRRGGBB` literal.
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
