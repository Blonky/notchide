import Testing
import Foundation
@testable import NotchideKit

@Suite("OTLP mapping")
struct OTLPMappingTests {

    private let claude = ProviderID("sh.claude")
    private let codex = ProviderID("sh.codex")

    // A realistic Claude Code OTLP/JSON ExportLogsServiceRequest: an api_request
    // carrying usage + cost + model, a tool_result, a (post-hoc) tool_decision,
    // and an api_error — all for one session. Note the proto3 JSON quirk that
    // 64-bit ints arrive as strings, and workspace.host_paths as an arrayValue.
    private let claudeLogs = """
    {
      "resourceLogs": [
        {
          "resource": { "attributes": [
            {"key": "service.name", "value": {"stringValue": "claude-code"}},
            {"key": "workspace.host_paths", "value": {"arrayValue": {"values": [
              {"stringValue": "/Users/zac/proj"}
            ]}}}
          ]},
          "scopeLogs": [
            {
              "scope": {"name": "com.anthropic.claude_code"},
              "logRecords": [
                {
                  "timeUnixNano": "1700000000000000000",
                  "body": {"stringValue": "claude_code.api_request"},
                  "attributes": [
                    {"key": "session.id", "value": {"stringValue": "sess-1"}},
                    {"key": "model", "value": {"stringValue": "claude-opus-4"}},
                    {"key": "input_tokens", "value": {"intValue": "100"}},
                    {"key": "output_tokens", "value": {"intValue": "50"}},
                    {"key": "cache_read_tokens", "value": {"intValue": "12"}},
                    {"key": "cost_usd", "value": {"doubleValue": 0.0123}}
                  ]
                },
                {
                  "timeUnixNano": "1700000001000000000",
                  "body": {"stringValue": "claude_code.tool_result"},
                  "attributes": [
                    {"key": "session.id", "value": {"stringValue": "sess-1"}},
                    {"key": "tool_name", "value": {"stringValue": "Bash"}},
                    {"key": "success", "value": {"boolValue": true}},
                    {"key": "duration_ms", "value": {"intValue": "42"}}
                  ]
                },
                {
                  "timeUnixNano": "1700000002000000000",
                  "body": {"stringValue": "claude_code.tool_decision"},
                  "attributes": [
                    {"key": "session.id", "value": {"stringValue": "sess-1"}},
                    {"key": "tool_name", "value": {"stringValue": "Edit"}}
                  ]
                },
                {
                  "timeUnixNano": "1700000003000000000",
                  "body": {"stringValue": "claude_code.api_error"},
                  "attributes": [
                    {"key": "session.id", "value": {"stringValue": "sess-1"}},
                    {"key": "status_code", "value": {"intValue": "500"}},
                    {"key": "error", "value": {"stringValue": "boom"}}
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
    """

    @Test("Claude logs map to kinds, session key, and usage payload")
    func claudeLogsMapping() throws {
        let events = OTLPMapping.events(fromLogsJSON: Data(claudeLogs.utf8))
        #expect(!events.isEmpty)

        // OBSERVE-ONLY: no event is ever a blocking decision.
        #expect(events.allSatisfy { $0.kind != .needsDecision })
        // ...and OTLP never asserts a trusted finish.
        #expect(events.allSatisfy { $0.kind != .finished })

        // A single synthesized start opens the lane (Claude has no native start),
        // and it precedes the first real record.
        let starts = events.filter { $0.kind == .started }
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(start.providerID == claude)
        #expect(start.sessionKey.agentSessionID == "sess-1")
        #expect(start.payload["synthesized"]?.boolValue == true)
        #expect(events.first?.kind == .started)

        // api_request → progress, carrying tokens / cost / model in the payload.
        let apiRequest = try #require(events.first { $0.payload["name"]?.stringValue == "claude_code.api_request" })
        #expect(apiRequest.kind == .progress)
        #expect(apiRequest.sessionKey == SessionKey(provider: claude, agentSessionID: "sess-1", cwd: "/Users/zac/proj"))
        #expect(apiRequest.cwd == "/Users/zac/proj")
        #expect(apiRequest.payload["input_tokens"]?.intValue == 100)
        #expect(apiRequest.payload["output_tokens"]?.intValue == 50)
        #expect(apiRequest.payload["cache_read_tokens"]?.intValue == 12)
        #expect(apiRequest.payload["cost_usd"]?.doubleValue == 0.0123)
        #expect(apiRequest.payload["model"]?.stringValue == "claude-opus-4")

        // tool_result → progress, carrying tool_name / success.
        let toolResult = try #require(events.first { $0.payload["name"]?.stringValue == "claude_code.tool_result" })
        #expect(toolResult.kind == .progress)
        #expect(toolResult.payload["tool_name"]?.stringValue == "Bash")
        #expect(toolResult.payload["success"]?.boolValue == true)

        // A tool_decision record is POST-hoc → progress, NEVER a needsDecision.
        let toolDecision = try #require(events.first { $0.payload["name"]?.stringValue == "claude_code.tool_decision" })
        #expect(toolDecision.kind == .progress)

        // api_error → errored, carrying the status code.
        let apiError = try #require(events.first { $0.payload["name"]?.stringValue == "claude_code.api_error" })
        #expect(apiError.kind == .errored)
        #expect(apiError.payload["status_code"]?.intValue == 500)
    }

    @Test("a Claude token.usage metric carries tokens into the payload")
    func claudeTokenMetric() throws {
        let metrics = """
        {
          "resourceMetrics": [
            {
              "resource": {"attributes": [
                {"key":"service.name","value":{"stringValue":"claude-code"}}
              ]},
              "scopeMetrics": [
                {
                  "metrics": [
                    {
                      "name": "claude_code.token.usage",
                      "sum": {"dataPoints": [
                        {
                          "timeUnixNano": "1700000000000000000",
                          "asInt": "1234",
                          "attributes": [
                            {"key":"session.id","value":{"stringValue":"sess-2"}},
                            {"key":"type","value":{"stringValue":"input"}},
                            {"key":"model","value":{"stringValue":"claude-opus-4"}}
                          ]
                        }
                      ]}
                    },
                    {
                      "name": "claude_code.cost.usage",
                      "sum": {"dataPoints": [
                        {
                          "asDouble": 0.25,
                          "attributes": [
                            {"key":"session.id","value":{"stringValue":"sess-2"}}
                          ]
                        }
                      ]}
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
        let events = OTLPMapping.events(fromMetricsJSON: Data(metrics.utf8))
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.kind != .needsDecision })

        let tokenUsage = try #require(events.first { $0.payload["name"]?.stringValue == "claude_code.token.usage" })
        #expect(tokenUsage.kind == .progress)
        #expect(tokenUsage.sessionKey == SessionKey(provider: claude, agentSessionID: "sess-2", cwd: ""))
        #expect(tokenUsage.payload["input_tokens"]?.intValue == 1234)
        #expect(tokenUsage.payload["value"]?.doubleValue == 1234)

        let cost = try #require(events.first { $0.payload["name"]?.stringValue == "claude_code.cost.usage" })
        #expect(cost.kind == .progress)
        #expect(cost.payload["cost_usd"]?.doubleValue == 0.25)

        // Exactly one synthesized start for the (single) new session.
        #expect(events.filter { $0.kind == .started }.count == 1)
    }

    @Test("Codex logs map starts, progress, and errors on conversation.id")
    func codexLogsMapping() throws {
        let codexLogs = """
        {
          "resourceLogs": [{
            "scopeLogs": [{
              "logRecords": [
                {"body":{"stringValue":"codex.conversation_starts"},"attributes":[
                  {"key":"conversation.id","value":{"stringValue":"conv-9"}},
                  {"key":"workspace.host_paths","value":{"arrayValue":{"values":[{"stringValue":"/tmp/cx"}]}}}
                ]},
                {"body":{"stringValue":"codex.api_request"},"attributes":[
                  {"key":"conversation.id","value":{"stringValue":"conv-9"}},
                  {"key":"model","value":{"stringValue":"gpt-5"}},
                  {"key":"input_token_count","value":{"intValue":"200"}},
                  {"key":"http.response.status_code","value":{"intValue":"200"}}
                ]},
                {"body":{"stringValue":"codex.api_request"},"attributes":[
                  {"key":"conversation.id","value":{"stringValue":"conv-9"}},
                  {"key":"http.response.status_code","value":{"intValue":"500"}}
                ]},
                {"body":{"stringValue":"codex.tool_result"},"attributes":[
                  {"key":"conversation.id","value":{"stringValue":"conv-9"}},
                  {"key":"error.message","value":{"stringValue":"rate limited"}}
                ]}
              ]
            }]
          }]
        }
        """
        let events = OTLPMapping.events(fromLogsJSON: Data(codexLogs.utf8))
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.kind != .needsDecision })

        // Codex has a NATIVE start, so no start is synthesized: the only .started
        // is the conversation_starts record itself.
        let starts = events.filter { $0.kind == .started }
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(start.payload["name"]?.stringValue == "codex.conversation_starts")
        #expect(start.providerID == codex)
        #expect(start.sessionKey == SessionKey(provider: codex, agentSessionID: "conv-9", cwd: "/tmp/cx"))
        #expect(start.payload["synthesized"] == nil)

        let ok = try #require(events.first {
            $0.payload["name"]?.stringValue == "codex.api_request"
                && $0.payload["http.response.status_code"]?.intValue == 200
        })
        #expect(ok.kind == .progress)
        #expect(ok.payload["input_token_count"]?.intValue == 200)

        let httpError = try #require(events.first {
            $0.payload["name"]?.stringValue == "codex.api_request"
                && $0.payload["http.response.status_code"]?.intValue == 500
        })
        #expect(httpError.kind == .errored)

        let toolError = try #require(events.first { $0.payload["name"]?.stringValue == "codex.tool_result" })
        #expect(toolError.kind == .errored)
    }

    @Test("no OTLP event is ever a needsDecision")
    func neverNeedsDecision() {
        let logs = OTLPMapping.events(fromLogsJSON: Data(claudeLogs.utf8))
        #expect(logs.allSatisfy { $0.kind != .needsDecision })
        #expect(!logs.isEmpty)
    }

    @Test("malformed or partial JSON maps to an empty array")
    func lenientOnGarbage() {
        #expect(OTLPMapping.events(fromLogsJSON: Data("garbage".utf8)).isEmpty)
        #expect(OTLPMapping.events(fromLogsJSON: Data()).isEmpty)
        #expect(OTLPMapping.events(fromLogsJSON: Data("{".utf8)).isEmpty)
        #expect(OTLPMapping.events(fromMetricsJSON: Data("not json".utf8)).isEmpty)
        #expect(OTLPMapping.events(fromMetricsJSON: Data()).isEmpty)
        // Well-formed but empty / unrelated payloads yield nothing, not a crash.
        #expect(OTLPMapping.events(fromLogsJSON: Data(#"{"resourceLogs":[]}"#.utf8)).isEmpty)
        #expect(OTLPMapping.events(fromMetricsJSON: Data(#"{"resourceMetrics":[]}"#.utf8)).isEmpty)
    }

    @Test("records from unknown providers are skipped")
    func unknownProviderSkipped() {
        let logs = """
        {"resourceLogs":[{"scopeLogs":[{"logRecords":[
          {"body":{"stringValue":"gemini.request"},"attributes":[
            {"key":"session.id","value":{"stringValue":"g-1"}}
          ]}
        ]}]}]}
        """
        #expect(OTLPMapping.events(fromLogsJSON: Data(logs.utf8)).isEmpty)
    }
}
