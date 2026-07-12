import Testing
import Foundation
@testable import NotchideKit

@Suite("HookEvent decoding")
struct HookEventTests {

    @Test("Decodes a realistic PreToolUse Bash payload and renders the command")
    func decodePreToolUseBash() throws {
        let json = """
        {
          "session_id": "abc123",
          "transcript_path": "/home/user/.claude/projects/x/transcript.jsonl",
          "cwd": "/home/user/my-project",
          "permission_mode": "default",
          "hook_event_name": "PreToolUse",
          "tool_name": "Bash",
          "tool_input": { "command": "rm -rf build/" }
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))

        #expect(event.sessionId == "abc123")
        #expect(event.cwd == "/home/user/my-project")
        #expect(event.hookEventName == .preToolUse)
        #expect(event.rawHookEventName == "PreToolUse")
        #expect(event.toolName == "Bash")
        #expect(event.transcriptPath == "/home/user/.claude/projects/x/transcript.jsonl")

        // Human-readable command render.
        #expect(event.toolInput?.humanReadableCommand(toolName: "Bash") == "rm -rf build/")
        #expect(event.commandDescription == "rm -rf build/")

        // Unmodelled field is preserved in the catch-all.
        #expect(event.extra["permission_mode"] == .string("default"))
    }

    @Test("Decodes a Notification payload")
    func decodeNotification() throws {
        let json = """
        {
          "session_id": "abc123",
          "hook_event_name": "Notification",
          "notification_type": "permission_prompt",
          "message": "Bash tool needs permission: npm test"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))

        #expect(event.hookEventName == .notification)
        #expect(event.notificationType == "permission_prompt")
        #expect(event.message == "Bash tool needs permission: npm test")
    }

    @Test("Decodes a Stop payload")
    func decodeStop() throws {
        let json = """
        {
          "session_id": "abc123",
          "hook_event_name": "Stop",
          "last_assistant_message": "I've completed the refactoring...",
          "permission_mode": "default"
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))

        #expect(event.hookEventName == .stop)
        #expect(event.lastAssistantMessage == "I've completed the refactoring...")
    }

    @Test("Never throws on unknown event names or extra fields")
    func robustToUnknownFields() throws {
        let json = """
        {
          "session_id": "s1",
          "cwd": "/tmp",
          "hook_event_name": "SomeFutureEvent",
          "brand_new_field": { "nested": [1, 2, 3] },
          "another": true
        }
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))

        #expect(event.hookEventName == nil)           // unknown → nil
        #expect(event.rawHookEventName == "SomeFutureEvent")
        #expect(event.extra["brand_new_field"] != nil)
        #expect(event.extra["another"] == .bool(true))
    }

    @Test("Missing common fields degrade gracefully instead of throwing")
    func robustToMissingFields() throws {
        let event = try JSONDecoder().decode(HookEvent.self, from: Data("{}".utf8))
        #expect(event.sessionId == "")
        #expect(event.cwd == "")
        #expect(event.hookEventName == nil)
    }

    @Test("Round-trips losslessly through Codable (for IPC)")
    func roundTrips() throws {
        let original = HookEvent(
            sessionId: "s9",
            cwd: "/work",
            hookEventName: .preToolUse,
            toolName: "Bash",
            toolInput: .object(["command": .string("ls -la")]),
            extra: ["permission_mode": .string("default")]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HookEvent.self, from: data)

        #expect(decoded.sessionId == "s9")
        #expect(decoded.hookEventName == .preToolUse)
        #expect(decoded.toolName == "Bash")
        #expect(decoded.commandDescription == "ls -la")
        #expect(decoded.extra["permission_mode"] == .string("default"))
    }

    @Test("JSONValue subscripts and scalar rendering")
    func jsonValueAccessors() {
        let value = JSONValue.object([
            "s": .string("hi"),
            "n": .number(42),
            "b": .bool(true),
            "arr": .array([.string("a"), .string("b")]),
        ])
        #expect(value["s"]?.stringValue == "hi")
        #expect(value["n"]?.intValue == 42)
        #expect(value["b"]?.boolValue == true)
        #expect(value["arr"]?[1]?.stringValue == "b")
        #expect(value["missing"] == nil)
    }
}
