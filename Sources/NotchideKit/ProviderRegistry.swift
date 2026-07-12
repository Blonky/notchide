import Foundation

/// Holds the set of compiled providers and fans all of their `events()` into the
/// ONE `SessionStore`.
///
/// It can also scan on-disk provider manifests. Swift has no dynamic code
/// loading, so a manifest cannot spin up a live provider; instead a manifest
/// contributes its `ProviderDescriptor` (id, capabilities, decision capability),
/// which lets the store classify a provider's lanes correctly even before any of
/// its events arrive over the socket.
///
/// Manifest format: `~/Library/Application Support/notchide/providers/<name>/
/// provider.toml`. A tiny hand-rolled TOML subset is parsed (see
/// `ProviderManifest`) to stay Foundation-only with no external dependencies; a
/// sibling `provider.json` is accepted as an alternative.
public actor ProviderRegistry {
    private var providers: [any AgentProvider] = []
    private var manifestDescriptors: [ProviderDescriptor] = []
    private var fanInTasks: [Task<Void, Never>] = []

    public init() {}

    /// Registers a compiled provider.
    public func register(_ provider: any AgentProvider) {
        providers.append(provider)
    }

    /// The descriptors of all registered providers plus any loaded manifests.
    public func descriptors() -> [ProviderDescriptor] {
        providers.map(\.descriptor) + manifestDescriptors
    }

    /// Scans `dir` for `*/provider.toml` (or `*/provider.json`) manifests and
    /// records their descriptors. Missing directory / unreadable / malformed
    /// manifests are skipped silently — discovery must never crash the app.
    public func loadManifests(from dir: URL) async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let toml = entry.appendingPathComponent("provider.toml")
            let json = entry.appendingPathComponent("provider.json")
            if let data = try? Data(contentsOf: toml),
               let descriptor = ProviderManifest.parseTOML(String(decoding: data, as: UTF8.self)) {
                manifestDescriptors.append(descriptor)
            } else if let data = try? Data(contentsOf: json),
                      let descriptor = ProviderManifest.parseJSON(data) {
                manifestDescriptors.append(descriptor)
            }
        }
    }

    /// Registers every known descriptor's decision capability with `store`, then
    /// spawns one task per compiled provider that pumps `events()` into `store`.
    public func fanIn(into store: SessionStore) async {
        for descriptor in descriptors() {
            await store.register(descriptor.id, decisionCapability: descriptor.decisionCapability)
        }
        for provider in providers {
            let stream = provider.events()
            let task = Task {
                for await event in stream {
                    await store.ingest(event)
                }
            }
            fanInTasks.append(task)
        }
    }

    /// Cancels all fan-in tasks.
    public func cancelFanIn() {
        for task in fanInTasks { task.cancel() }
        fanInTasks.removeAll()
    }
}

/// Minimal parser for provider manifests (a tiny TOML subset, or JSON).
///
/// Recognized keys: `id` (string), `displayName` (string), `capabilities`
/// (string array), `decisionCapability` (`"blocking"` | `"notifyOnly"`; when
/// absent it is derived from whether `capabilities` includes `gate`).
enum ProviderManifest {
    /// Parses the minimal TOML subset: `key = "value"` and `key = ["a", "b"]`
    /// lines, ignoring blank lines, `#` comments, and `[section]` headers.
    static func parseTOML(_ text: String) -> ProviderDescriptor? {
        var values: [String: String] = [:]
        var arrays: [String: [String]] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rhs = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if rhs.hasPrefix("[") {
                arrays[key] = parseTOMLArray(rhs)
            } else {
                values[key] = unquote(rhs)
            }
        }
        return descriptor(
            id: values["id"],
            displayName: values["displayName"],
            capabilities: arrays["capabilities"] ?? [],
            decisionCapability: values["decisionCapability"]
        )
    }

    static func parseJSON(_ data: Data) -> ProviderDescriptor? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let capabilities = (object["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? []
        return descriptor(
            id: object["id"] as? String,
            displayName: object["displayName"] as? String,
            capabilities: capabilities,
            decisionCapability: object["decisionCapability"] as? String
        )
    }

    private static func descriptor(
        id: String?,
        displayName: String?,
        capabilities rawCapabilities: [String],
        decisionCapability rawDecision: String?
    ) -> ProviderDescriptor? {
        guard let id, !id.isEmpty else { return nil }
        let capabilities = Set(rawCapabilities.compactMap(Capability.init(rawValue:)))
        let decision: DecisionCapability
        switch rawDecision {
        case "blocking": decision = .blocking
        case "notifyOnly": decision = .notifyOnly
        default: decision = DecisionCapability(capabilities: capabilities)
        }
        return ProviderDescriptor(
            id: ProviderID(id),
            displayName: displayName ?? id,
            capabilities: capabilities,
            decisionCapability: decision
        )
    }

    private static func parseTOMLArray(_ text: String) -> [String] {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]") else { return [] }
        let inner = text[text.index(after: open)..<close]
        return inner.split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String) -> String {
        var s = text
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s.removeFirst(); s.removeLast()
        }
        return s
    }
}
