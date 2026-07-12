import SwiftUI

/// Typography tokens. Body text uses the system UI font; anything that renders a
/// command, path, or diff uses a monospaced face (SF Mono / ui-monospace).
public enum Typo {
    public static let title = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 12, weight: .regular)
    public static let caption = Font.system(size: 11, weight: .regular)
    public static let chip = Font.system(size: 11, weight: .medium)

    /// Monospaced command / diff text.
    public static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
    public static let monoBold = Font.system(size: 12, weight: .semibold, design: .monospaced)
}
