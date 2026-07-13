import SwiftUI
import NotchideKit

/// The Telemetry pane — the OTLP enrichment plane (observe-only).
///
/// A toggle for the loopback `:4318` receiver, the exact exporter env-vars for
/// Claude Code and Codex, and the honest framing: this lane can only *enrich* a
/// lane the hook already owns (tokens / cost / model). It never gates, never
/// actuates, never opens or closes a lane, and binds loopback only.
struct TelemetryPane: View {
    @ObservedObject var store: SettingsStore
    /// Persisted intent to run the receiver. The receiver itself lives in the
    /// running app; this pane records whether the user wants it on.
    @AppStorage("notchide.otlp.enabled") private var otlpEnabled = false

    private var port: UInt16 { OTLPProvider.defaultPort }
    private var endpoint: String { "http://localhost:\(port)" }

    var body: some View {
        PaneScaffold(
            title: "Telemetry",
            subtitle: "An OpenTelemetry receiver that lets agents enrich their lanes with tokens, cost, and model — for free, if they already speak OTLP."
        ) {
            // Enable toggle + bound-port / fallback status.
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Toggle(isOn: $otlpEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable the OTLP receiver on :\(String(port))")
                            .font(Typo.title)
                        Text("Binds 127.0.0.1 only — never a routable address.")
                            .font(Typo.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack(spacing: Theme.Spacing.sm) {
                    Circle()
                        .fill(otlpEnabled ? Theme.done : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(otlpEnabled
                         ? "Receiver on — binds 127.0.0.1:\(String(port)); on a port clash (EADDRINUSE) it falls back to the next free port rather than failing."
                         : "Receiver off — no port is bound.")
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsCard()

            SettingsCallout(
                .info,
                "Loopback-only, observe-only enrichment. OTLP records merge onto the lane the hook/sidecar already owns, keyed by shared session id. It is structurally notify-only: an OTLP \"done\" must never close a lane the hook still shows blocking, and a gate can never ride OTLP."
            )

            // Claude Code exporter env-vars (the exact, documented set).
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("Claude Code", systemImage: "sparkle")
                    .font(Typo.title)
                Text("Export these before launching Claude Code so it points its OTLP exporter at notchide. session.id equals the PreToolUse hook's session_id, so the enrichment lands on the right lane.")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CodeBlock(text: claudeCodeEnv)
            }

            // Codex exporter env-vars.
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(Typo.title)
                Text("Codex emits OTLP when pointed at an endpoint; its records merge by conversation.id — the Codex equivalent of Claude's session.id. Set its enable flag per your Codex build.")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CodeBlock(text: codexEnv)
            }

            SettingsCallout(
                .caution,
                "Low export intervals matter: the vendor defaults (metrics 60000 ms, logs 5000 ms) are far too laggy for an ambient cockpit, so the values above are deliberately short. notchide forces http/json for the same reason."
            )
        }
    }

    private var claudeCodeEnv: String {
        """
        export CLAUDE_CODE_ENABLE_TELEMETRY=1
        export OTEL_LOGS_EXPORTER=otlp
        export OTEL_METRICS_EXPORTER=otlp
        export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
        export OTEL_EXPORTER_OTLP_ENDPOINT=\(endpoint)
        # Low intervals — well below the 60000/5000 ms vendor defaults.
        export OTEL_METRIC_EXPORT_INTERVAL=10000
        export OTEL_LOGS_EXPORT_INTERVAL=5000
        """
    }

    private var codexEnv: String {
        """
        export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
        export OTEL_EXPORTER_OTLP_ENDPOINT=\(endpoint)
        export OTEL_METRICS_EXPORTER=otlp
        export OTEL_LOGS_EXPORTER=otlp
        """
    }
}
