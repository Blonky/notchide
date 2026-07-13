import Foundation
import NotchideKit

/// The persisted set of "Approve-and-remember" commands.
///
/// When the user approves a pending command with *remember*, its normalized
/// exact command string is stored here (a small JSON array under
/// `~/Library/Application Support/notchide/remembered.json`). On a later
/// `wantsDecision` gate, the socket handler consults this set BEFORE surfacing
/// the console: an exact, normalized match resolves `.allow` immediately and
/// silently.
///
/// SCOPE / SAFETY: matching is on the **exact normalized command string** only —
/// never a loose or substring match. Normalization just trims and collapses
/// interior whitespace so `rm  -rf x` and `rm -rf x` compare equal; it does not
/// canonicalize paths, flags, or semantics. This is deliberately conservative:
/// the remembered set can only ever auto-approve a command the user has already
/// approved verbatim.
///
/// An `actor` so it is safe to read from concurrent socket connections and write
/// from the main-actor decision handler.
public actor RememberedStore {
    private var commands: Set<String>
    private let url: URL

    public init(url: URL = NotchidePaths.supportDirectory.appendingPathComponent("remembered.json")) {
        self.url = url
        self.commands = Self.load(from: url)
    }

    /// Trim + collapse interior whitespace. The exact-match key.
    public static func normalize(_ command: String) -> String {
        command
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// Whether `command` was previously remembered (exact normalized match).
    public func contains(_ command: String) -> Bool {
        let key = Self.normalize(command)
        guard !key.isEmpty else { return false }
        return commands.contains(key)
    }

    /// Remembers `command` for future auto-approval and persists the set.
    public func remember(_ command: String) {
        let key = Self.normalize(command)
        guard !key.isEmpty else { return }
        guard commands.insert(key).inserted else { return }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let sorted = commands.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        // The support directory is created (0700) at app launch; best-effort here.
        _ = try? NotchidePaths.ensureSupportDirectory()
        try? data.write(to: url, options: [.atomic])
    }

    private static func load(from url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list.map(normalize).filter { !$0.isEmpty })
    }
}
