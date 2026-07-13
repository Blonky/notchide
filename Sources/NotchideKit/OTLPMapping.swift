import Foundation

/// Pure, dependency-free mapping from OTLP/HTTP JSON export bodies to notchide
/// `AgentEvent`s.
///
/// This is the vendor adapter for agents that emit OpenTelemetry rather than
/// speaking the AAP socket directly — Claude Code (`claude_code.*`) and Codex
/// (`codex.*`) today. It is the ONE place that knows their OTLP record/metric
/// names and attribute vocabulary; downstream (SessionStore, the app) sees only
/// vendor-neutral `AgentEvent`s, merged on `SessionKey`.
///
/// OBSERVE-ONLY by construction: it emits only `.started` / `.progress` /
/// `.errored`. It NEVER produces `.needsDecision` (a `claude_code.tool_decision`
/// is a post-hoc record and maps to `.progress`), and it never emits a trusted
/// `.finished` — OTLP is a lossy side-channel, so "done" is not asserted from it.
///
/// Parsing is deliberately lenient, mirroring the other decoders in this package:
/// malformed or partial JSON yields `[]` and odd/unknown shapes are skipped, so a
/// newer or truncated export degrades gracefully instead of throwing.
public enum OTLPMapping {

    /// Provider identity for Claude Code OTLP records/metrics (`claude_code.*`).
    public static let claudeProviderID = ProviderID("sh.claude")
    /// Provider identity for Codex OTLP records/metrics (`codex.*`).
    public static let codexProviderID = ProviderID("sh.codex")

    // MARK: - Public API

    /// Maps an OTLP `ExportLogsServiceRequest` JSON body into `AgentEvent`s.
    ///
    /// Walks `resourceLogs[].scopeLogs[].logRecords[]`, taking each record's
    /// event name from its `body` (an OTLP `AnyValue`) and joining the resource-
    /// and record-level `attributes[]`. Malformed/partial JSON → `[]`.
    public static func events(fromLogsJSON data: Data) -> [AgentEvent] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        var events: [AgentEvent] = []
        var synthesizedSessions: Set<SessionKey> = []

        for resourceLog in root["resourceLogs"]?.arrayValue ?? [] {
            let resourceAttrs = attributes(from: resourceLog["resource"]?["attributes"])
            for scopeLog in resourceLog["scopeLogs"]?.arrayValue ?? [] {
                for record in scopeLog["logRecords"]?.arrayValue ?? [] {
                    var attrs = resourceAttrs
                    for (key, value) in attributes(from: record["attributes"]) { attrs[key] = value }

                    let name = anyValue(record["body"])?.stringValue
                        ?? attrs["event.name"]?.stringValue
                        ?? attrs["name"]?.stringValue
                        ?? ""
                    guard let family = family(for: name) else { continue }

                    let event = buildEvent(
                        family: family,
                        name: name,
                        attrs: attrs,
                        at: timestamp(fromNano: record["timeUnixNano"]))
                    appendWithSynthesis(event, into: &events, synthesized: &synthesizedSessions)
                }
            }
        }
        return events
    }

    /// Maps an OTLP `ExportMetricsServiceRequest` JSON body into `AgentEvent`s.
    ///
    /// Walks `resourceMetrics[].scopeMetrics[].metrics[].(sum|gauge).dataPoints[]`,
    /// taking the event name from `metric.name` and carrying each data point's
    /// numeric value into the payload (semantically, e.g. `input_tokens` for a
    /// `claude_code.token.usage` point of `type` `"input"`). Malformed JSON → `[]`.
    public static func events(fromMetricsJSON data: Data) -> [AgentEvent] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        var events: [AgentEvent] = []
        var synthesizedSessions: Set<SessionKey> = []

        for resourceMetric in root["resourceMetrics"]?.arrayValue ?? [] {
            let resourceAttrs = attributes(from: resourceMetric["resource"]?["attributes"])
            for scopeMetric in resourceMetric["scopeMetrics"]?.arrayValue ?? [] {
                for metric in scopeMetric["metrics"]?.arrayValue ?? [] {
                    let name = metric["name"]?.stringValue ?? ""
                    guard let family = family(for: name) else { continue }

                    let dataPoints = (metric["sum"]?["dataPoints"]?.arrayValue ?? [])
                        + (metric["gauge"]?["dataPoints"]?.arrayValue ?? [])
                    for point in dataPoints {
                        var attrs = resourceAttrs
                        for (key, value) in attributes(from: point["attributes"]) { attrs[key] = value }

                        let value = metricValue(from: point)
                        for (key, extra) in metricValueAttributes(
                            name: name, value: value, type: attrs["type"]?.stringValue) {
                            attrs[key] = extra
                        }

                        let event = buildEvent(
                            family: family,
                            name: name,
                            attrs: attrs,
                            at: timestamp(fromNano: point["timeUnixNano"]))
                        appendWithSynthesis(event, into: &events, synthesized: &synthesizedSessions)
                    }
                }
            }
        }
        return events
    }

    // MARK: - Provider families

    private enum Family {
        case claude
        case codex
    }

    private static func family(for name: String) -> Family? {
        if name.hasPrefix("claude_code.") { return .claude }
        if name.hasPrefix("codex.") { return .codex }
        return nil
    }

    /// Claude record/metric names that denote a failure (→ `.errored`). Note that
    /// `claude_code.tool_decision` is deliberately absent: it is a post-hoc record,
    /// not a blocking gate, so it maps to `.progress`, never `.needsDecision`.
    private static let claudeErrorNames: Set<String> = [
        "claude_code.api_error",
        "claude_code.api_refusal",
        "claude_code.internal_error",
        "claude_code.api_retries_exhausted",
    ]

    // MARK: - Event construction

    private static func buildEvent(
        family: Family,
        name: String,
        attrs: [String: JSONValue],
        at: Date
    ) -> AgentEvent {
        switch family {
        case .claude:
            let sessionID = attrs["session.id"]?.stringValue ?? ""
            let cwd = hostPathFirst(attrs)
            let kind: AgentEventKind = claudeErrorNames.contains(name) ? .errored : .progress
            let title = attrs["tool_name"]?.stringValue ?? attrs["model"]?.stringValue ?? name
            return event(
                provider: claudeProviderID, sessionID: sessionID, cwd: cwd,
                kind: kind, title: title, name: name, attrs: attrs, at: at)

        case .codex:
            let sessionID = attrs["conversation.id"]?.stringValue ?? ""
            let cwd = hostPathFirst(attrs)
            let kind = codexKind(name: name, attrs: attrs)
            let title = attrs["model"]?.stringValue ?? name
            return event(
                provider: codexProviderID, sessionID: sessionID, cwd: cwd,
                kind: kind, title: title, name: name, attrs: attrs, at: at)
        }
    }

    /// Codex classification: `codex.conversation_starts` is a native start; any
    /// record carrying an `error.message` or a non-2xx `http.response.status_code`
    /// is an error; everything else is progress.
    private static func codexKind(name: String, attrs: [String: JSONValue]) -> AgentEventKind {
        if name == "codex.conversation_starts" { return .started }
        if let message = attrs["error.message"]?.stringValue, !message.isEmpty { return .errored }
        if let status = attrs["http.response.status_code"]?.intValue, !(200..<300).contains(status) {
            return .errored
        }
        return .progress
    }

    private static func event(
        provider: ProviderID,
        sessionID: String,
        cwd: String,
        kind: AgentEventKind,
        title: String,
        name: String,
        attrs: [String: JSONValue],
        at: Date
    ) -> AgentEvent {
        let sessionKey = SessionKey(provider: provider, agentSessionID: sessionID, cwd: cwd)
        var payload = attrs
        payload["name"] = .string(name)
        return AgentEvent(
            providerID: provider,
            sessionKey: sessionKey,
            kind: kind,
            cwd: cwd.isEmpty ? nil : cwd,
            title: title,
            payload: .object(payload),
            at: at)
    }

    /// Appends `event`, first synthesizing a `.started` the FIRST time a Claude
    /// session id is seen in this batch. Claude Code has no native session-start
    /// record over OTLP, so a synthetic start opens the lane; Codex emits its own
    /// `codex.conversation_starts` and is never synthesized here.
    private static func appendWithSynthesis(
        _ event: AgentEvent,
        into events: inout [AgentEvent],
        synthesized: inout Set<SessionKey>
    ) {
        if event.providerID == claudeProviderID,
           event.kind != .started,
           !event.sessionKey.agentSessionID.isEmpty,
           !synthesized.contains(event.sessionKey) {
            synthesized.insert(event.sessionKey)
            events.append(synthesizedStart(for: event))
        }
        events.append(event)
    }

    private static func synthesizedStart(for event: AgentEvent) -> AgentEvent {
        AgentEvent(
            providerID: event.providerID,
            sessionKey: event.sessionKey,
            kind: .started,
            cwd: event.sessionKey.cwd.isEmpty ? nil : event.sessionKey.cwd,
            title: "session started",
            payload: .object([
                "synthesized": .bool(true),
                "session.id": .string(event.sessionKey.agentSessionID),
            ]),
            at: event.at)
    }

    // MARK: - OTLP value helpers

    /// Flattens an OTLP `attributes` array — `[{key, value:{stringValue|intValue|
    /// doubleValue|boolValue|arrayValue|kvlistValue}}]` — into `[key: scalar]`,
    /// unwrapping each `AnyValue` to a plain `JSONValue`.
    private static func attributes(from value: JSONValue?) -> [String: JSONValue] {
        guard let array = value?.arrayValue else { return [:] }
        var out: [String: JSONValue] = [:]
        for item in array {
            guard let key = item["key"]?.stringValue else { continue }
            if let unwrapped = anyValue(item["value"]) { out[key] = unwrapped }
        }
        return out
    }

    /// Unwraps a single OTLP `AnyValue` object to a plain `JSONValue`.
    ///
    /// Per the proto3 JSON mapping, 64-bit ints (`intValue`) arrive as JSON
    /// *strings*; they are parsed back to numbers here so `input_tokens` etc. read
    /// as numbers downstream. A bare (already-unwrapped) scalar passes through.
    private static func anyValue(_ value: JSONValue?) -> JSONValue? {
        guard let object = value?.objectValue else { return value }
        if let string = object["stringValue"] { return string }
        if let int = object["intValue"] {
            if case .number = int { return int }
            if let string = int.stringValue, let number = Double(string) { return .number(number) }
            return int
        }
        if let double = object["doubleValue"] { return double }
        if let bool = object["boolValue"] { return bool }
        if let values = object["arrayValue"]?["values"]?.arrayValue {
            return .array(values.compactMap { anyValue($0) })
        }
        if let entries = object["kvlistValue"]?["values"]?.arrayValue {
            var nested: [String: JSONValue] = [:]
            for entry in entries {
                if let key = entry["key"]?.stringValue, let unwrapped = anyValue(entry["value"]) {
                    nested[key] = unwrapped
                }
            }
            return .object(nested)
        }
        return nil
    }

    /// The first element of a `workspace.host_paths` attribute, else `""`.
    private static func hostPathFirst(_ attrs: [String: JSONValue]) -> String {
        guard let value = attrs["workspace.host_paths"] else { return "" }
        if case .array(let elements) = value { return elements.first?.stringValue ?? "" }
        if case .string(let single) = value { return single }
        return ""
    }

    /// The numeric value of a metric data point (`asInt` string/number, or
    /// `asDouble`), or `nil` when absent.
    private static func metricValue(from point: JSONValue) -> Double? {
        if let double = point["asDouble"]?.doubleValue { return double }
        if let int = point["asInt"] {
            if let number = int.doubleValue { return number }
            if let string = int.stringValue, let number = Double(string) { return number }
        }
        return nil
    }

    /// Semantic payload keys derived from a metric point's value, so the UI can
    /// render usage regardless of which OTLP metric carried it.
    private static func metricValueAttributes(
        name: String,
        value: Double?,
        type: String?
    ) -> [String: JSONValue] {
        guard let value else { return [:] }
        var out: [String: JSONValue] = ["value": .number(value)]
        switch name {
        case "claude_code.token.usage":
            switch type {
            case "input": out["input_tokens"] = .number(value)
            case "output": out["output_tokens"] = .number(value)
            case "cacheRead": out["cache_read_tokens"] = .number(value)
            case "cacheCreation": out["cache_creation_tokens"] = .number(value)
            default: out["tokens"] = .number(value)
            }
        case "claude_code.cost.usage":
            out["cost_usd"] = .number(value)
        default:
            break
        }
        return out
    }

    /// Converts an OTLP `timeUnixNano` (string or number of nanoseconds) into a
    /// `Date`, falling back to "now" when absent or unparsable.
    private static func timestamp(fromNano value: JSONValue?) -> Date {
        let nanos: Double?
        if let number = value?.doubleValue {
            nanos = number
        } else if let string = value?.stringValue, let number = Double(string) {
            nanos = number
        } else {
            nanos = nil
        }
        guard let nanos, nanos > 0 else { return Date() }
        return Date(timeIntervalSince1970: nanos / 1_000_000_000)
    }
}
