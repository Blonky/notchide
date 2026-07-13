import SwiftUI
import AppKit
import NotchideKit

/// What the add sheet is currently adding. The sheet opens on one of these but
/// lets the user switch between them.
enum AddKind: Hashable, CaseIterable {
    case folder
    case githubRepo
    case provider
    case tool

    var title: String {
        switch self {
        case .folder: return "Folder"
        case .githubRepo: return "GitHub repo"
        case .provider: return "Provider"
        case .tool: return "Tool"
        }
    }
}

/// A unified "add" sheet: a folder workspace, a cloned GitHub workspace, an agent
/// provider manifest, or a tool connector. Each form drives the real model type
/// and dismisses on success.
struct AddSheet: View {
    @ObservedObject var store: SettingsStore
    @State private var kind: AddKind
    @Environment(\.dismiss) private var dismiss

    init(store: SettingsStore, kind: AddKind) {
        self.store = store
        _kind = State(initialValue: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Add")
                .font(.system(size: 15, weight: .semibold))

            Picker("", selection: $kind) {
                ForEach(AddKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Divider()

            switch kind {
            case .folder:
                AddFolderForm(store: store, onDone: { dismiss() })
            case .githubRepo:
                AddGitHubForm(store: store, onDone: { dismiss() })
            case .provider:
                AddProviderForm(store: store, onDone: { dismiss() })
            case .tool:
                AddToolForm(store: store, onDone: { dismiss() })
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460)
    }
}

// MARK: - Folder

private struct AddFolderForm: View {
    @ObservedObject var store: SettingsStore
    let onDone: () -> Void

    @State private var folder: URL?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Open a folder already on disk. notchide only reads it — it never created it.")
                .font(Typo.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Choose folder…") { chooseFolder() }
                if let folder {
                    Text(folder.path)
                        .font(Typo.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            LabeledContent("Name") {
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            FormFooter(
                confirmTitle: "Add workspace",
                confirmEnabled: folder != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty,
                onCancel: onDone,
                onConfirm: add
            )
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func add() {
        guard let folder else { return }
        let workspace = Workspace(
            name: name.trimmingCharacters(in: .whitespaces),
            root: folder,
            source: .folder
        )
        Task {
            await store.addWorkspace(workspace)
            onDone()
        }
    }
}

// MARK: - GitHub repo

private struct AddGitHubForm: View {
    @ObservedObject var store: SettingsStore
    let onDone: () -> Void

    @State private var remote = ""
    @State private var branch = ""
    @State private var parent: URL?
    @State private var isCloning = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Clone a repo into a folder you choose. Only https:// or ssh remotes are accepted; the clone runs git with a hardened, no-prompt environment and a 60s timeout.")
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Remote") {
                TextField("https://github.com/owner/repo.git", text: $remote)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCloning)
            }
            LabeledContent("Branch") {
                TextField("default branch", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCloning)
            }
            HStack {
                Button("Choose destination…") { chooseParent() }
                    .disabled(isCloning)
                if let parent {
                    Text(parent.path)
                        .font(Typo.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if isCloning {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Cloning \(WorkspaceGitHelpers.repoName(from: remote))…")
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorText {
                SettingsCallout(.danger, errorText)
            }

            FormFooter(
                confirmTitle: "Clone & add",
                confirmEnabled: !isCloning && !remote.trimmingCharacters(in: .whitespaces).isEmpty && parent != nil,
                onCancel: onDone,
                onConfirm: clone
            )
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parent = url
    }

    private func clone() {
        guard let parent else { return }
        let remoteValue = remote.trimmingCharacters(in: .whitespaces)
        let branchValue = branch.trimmingCharacters(in: .whitespaces)
        let branchArg: String? = branchValue.isEmpty ? nil : branchValue
        let name = WorkspaceGitHelpers.repoName(from: remoteValue)
        let destination = parent.appendingPathComponent(name, isDirectory: true)

        errorText = nil
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorText = "A folder named “\(name)” already exists here. Choose another destination."
            return
        }

        isCloning = true
        Task {
            do {
                try await Task.detached {
                    try WorkspaceGit.clone(remote: remoteValue, into: destination, branch: branchArg)
                }.value
                let workspace = Workspace(
                    name: name,
                    root: destination,
                    source: .git(remote: remoteValue, branch: branchArg)
                )
                await store.addWorkspace(workspace)
                isCloning = false
                onDone()
            } catch {
                isCloning = false
                errorText = WorkspaceGitHelpers.friendly(error)
            }
        }
    }
}

// MARK: - Provider

private struct AddProviderForm: View {
    @ObservedObject var store: SettingsStore
    let onDone: () -> Void

    @State private var id = ""
    @State private var displayName = ""
    @State private var capabilities: Set<Capability> = [.observe]
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Records a provider manifest so notchide can classify its lanes before the first event arrives. The live provider still connects over the AAP socket.")
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Provider id") {
                TextField("sh.example", text: $id)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Display name") {
                TextField("Example Agent", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Capabilities")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                ForEach(Capability.allCases, id: \.self) { capability in
                    Toggle(isOn: Binding(
                        get: { capabilities.contains(capability) },
                        set: { on in
                            if on { capabilities.insert(capability) } else { capabilities.remove(capability) }
                        }
                    )) {
                        Text(capability.displayLabel)
                            .font(Typo.body)
                    }
                    .toggleStyle(.checkbox)
                }
                Text(capabilities.contains(.gate)
                     ? "Advertises gate → this provider can block for a decision."
                     : "No gate → notify-only. It can color a lane but never seize you.")
                    .font(Typo.caption)
                    .foregroundStyle(.tertiary)
            }

            if let errorText {
                SettingsCallout(.danger, errorText)
            }

            FormFooter(
                confirmTitle: "Add provider",
                confirmEnabled: !displayName.trimmingCharacters(in: .whitespaces).isEmpty,
                onCancel: onDone,
                onConfirm: add
            )
        }
    }

    private func add() {
        do {
            try store.addProviderManifest(
                id: id.trimmingCharacters(in: .whitespaces),
                displayName: displayName.trimmingCharacters(in: .whitespaces),
                capabilities: capabilities
            )
            Task {
                await store.refreshProviders()
                onDone()
            }
        } catch {
            errorText = "Couldn't write the manifest: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tool

private struct AddToolForm: View {
    @ObservedObject var store: SettingsStore
    let onDone: () -> Void

    @State private var name = ""
    @State private var kind: ToolKind = .mcp
    @State private var id = ""

    private var effectiveID: String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let base = name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
        return base.isEmpty ? "" : "\(kind.rawValue).\(base)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Register a connector agents can reach. Disable it later to keep it configured but hidden.")
                .font(Typo.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Kind") {
                Picker("", selection: $kind) {
                    ForEach(ToolKind.allCases, id: \.self) { kind in
                        Label(kind.displayLabel, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .labelsHidden()
            }
            LabeledContent("Name") {
                TextField("My connector", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Id") {
                TextField(effectiveID.isEmpty ? "auto from name" : effectiveID, text: $id)
                    .textFieldStyle(.roundedBorder)
            }

            FormFooter(
                confirmTitle: "Add tool",
                confirmEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && !effectiveID.isEmpty,
                onCancel: onDone,
                onConfirm: add
            )
        }
    }

    private func add() {
        let connector = ToolConnector(
            id: effectiveID,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            enabled: true
        )
        Task {
            await store.registerTool(connector)
            onDone()
        }
    }
}

// MARK: - Shared footer

private struct FormFooter: View {
    let confirmTitle: String
    let confirmEnabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!confirmEnabled)
        }
    }
}

// MARK: - Git helpers

enum WorkspaceGitHelpers {
    /// The bare repo name from a clone remote (last path component, minus `.git`).
    static func repoName(from remote: String) -> String {
        var last = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = last.lastIndex(of: "/") {
            last = String(last[last.index(after: slash)...])
        } else if let colon = last.lastIndex(of: ":") {
            last = String(last[last.index(after: colon)...])
        }
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        last = last.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return last.isEmpty ? "repo" : last
    }

    /// A human-readable message for a clone failure.
    static func friendly(_ error: Error) -> String {
        guard let gitError = error as? WorkspaceGitError else {
            return error.localizedDescription
        }
        switch gitError {
        case let .invalidRemote(remote):
            return "That doesn't look like a clone URL: “\(remote)”. Use an https:// or ssh remote (git@host:path)."
        case let .launchFailed(message):
            return "Couldn't launch git: \(message)"
        case let .timedOut(after):
            return "git timed out after \(Int(after))s. Check the remote URL and your network."
        case let .gitFailed(status, message):
            return message.isEmpty ? "git exited with status \(status)." : message
        }
    }
}
