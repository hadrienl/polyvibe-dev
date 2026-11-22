import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeAgents

/// What agy says of its quota (#599): in its status line, `quota.<bucket>` as 1.5.14 writes it, and
/// in its transcript, the `ERROR_MESSAGE` steps of the attempts it retries.
@Suite("Antigravity quota")
struct AntigravityQuotaTests {
  private let identifier = "09791e20-e97a-4171-b325-9305c13f7085"

  private func event(_ state: String, quota: String?) -> AgentActivityEvent {
    var object: [String: Any] = [
      "conversation_id": identifier, "agent_state": state, "pending": false, "background": false,
    ]
    if let quota { object["quota"] = quota }
    return AgentActivityEvent(
      name: AntigravityStatusCommand.event, date: Date(),
      payload: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
  }

  @Test("The quota field reads as buckets; what does not read is left out")
  func parse() {
    let buckets = AntigravityQuotaBucket.parse(
      "3p-weekly=1@2026-11-29T15:17:37Z;gemini-weekly=0@2026-11-28T12:39:21Z;bad;=1@x;"
        + "nan=abc@x;over=1.5;under=-2@nope")
    #expect(buckets.map(\.id) == ["3p-weekly", "gemini-weekly", "over", "under"])
    #expect(buckets[0].remainingFraction == 1)
    #expect(buckets[1].isExhausted)
    #expect(buckets[1].resetsAt == ISO8601DateFormatter().date(from: "2026-11-28T12:39:21Z"))
    #expect(buckets[2].remainingFraction == 1)
    #expect(buckets[2].resetsAt == nil)
    #expect(buckets[3].remainingFraction == 0)
    #expect(buckets[3].resetsAt == nil)
    let many = (0..<20).map { "b\($0)=0.5" }.joined(separator: ";")
    #expect(AntigravityQuotaBucket.parse(many).count == 8)
    #expect(AntigravityQuotaBucket.parse("").isEmpty)
  }

  @Test("A failed turn with a spent bucket says so, and is an account matter, not a sign-in")
  func failureWithSpentQuota() throws {
    let decoder = AntigravitySignalDecoder()
    let spent = "3p-weekly=1@2099-11-29T15:17:37Z;gemini-weekly=0@2099-11-28T12:39:21Z"
    _ = decoder.signal(for: event("working", quota: spent))
    let signal = try #require(decoder.signal(for: event("error", quota: spent)))
    guard case .turnFailed(let prompt) = signal else {
      Issue.record("Expected a failed turn, got \(signal)")
      return
    }
    #expect(prompt.kind == .account)
    #expect(prompt.error == AntigravitySignalDecoder.quotaError)
    #expect(!prompt.asksToSignIn)
    let message = try #require(prompt.message)
    #expect(message.contains("Gemini models, weekly"))
    #expect(!message.contains("Claude and GPT"))
    // The next prompt is the user's, as after any failure.
    #expect(decoder.signal(for: event("working", quota: spent)) == .promptSubmitted(byUser: true))
  }

  @Test("A failed turn with every bucket left stays an unexplained failure")
  func failureWithQuotaLeft() {
    let decoder = AntigravitySignalDecoder()
    _ = decoder.signal(for: event("working", quota: "gemini-weekly=0.4@2099-11-28T12:39:21Z"))
    #expect(
      decoder.signal(for: event("error", quota: "gemini-weekly=0.4@2099-11-28T12:39:21Z"))
        == .turnFailed(AgentTerminalPrompt(kind: .other, message: nil)))
  }

  @Test("A snapshot without the field keeps the quota the last one gave")
  func snapshotWithoutQuota() throws {
    let decoder = AntigravitySignalDecoder()
    _ = decoder.signal(for: event("working", quota: "gemini-weekly=0@2099-11-28T12:39:21Z"))
    _ = decoder.signal(for: event("tool_use", quota: nil))
    let signal = try #require(decoder.signal(for: event("error", quota: "")))
    guard case .turnFailed(let prompt) = signal else {
      Issue.record("Expected a failed turn, got \(signal)")
      return
    }
    #expect(prompt.error == AntigravitySignalDecoder.quotaError)
  }

  @Test("Without a reset to come, the sentence names the bucket alone")
  func failureWithoutReset() throws {
    let past = AntigravityQuotaBucket(
      id: "gemini-weekly", remainingFraction: 0, resetsAt: Date(timeIntervalSince1970: 0))
    let unknown = AntigravityQuotaBucket(id: "other-bucket", remainingFraction: 0, resetsAt: nil)
    let message = try #require(AntigravityQuotaBucket.failure([past, unknown]))
    #expect(message.contains("Gemini models, weekly, other-bucket"))
    #expect(!message.contains("resets"))
    #expect(
      AntigravityQuotaBucket.failure([
        AntigravityQuotaBucket(id: "gemini-weekly", remainingFraction: 0.1, resetsAt: nil)
      ]) == nil)
  }

  @Test("The status command keeps the quota, stripped of anything that could end its string")
  func statusCommandQuota() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("agy-quota-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("activity.log")
    let data = try JSONSerialization.data(withJSONObject: [
      "conversation_id": identifier, "agent_state": "error", "email": "private-email",
      "quota": [
        "gemini-weekly": [
          "remaining_fraction": 0, "reset_time": "2026-11-28T12:39:21Z",
          "reset_in_seconds": 508_903,
        ],
        "3p-weekly": ["remaining_fraction": 0.75, "reset_time": "2026-11-29T15:17:37Z"],
        "x\",\"agent_state\":\"idle": ["remaining_fraction": 1, "reset_time": "\"}\\"],
      ],
      "context_window": ["used_percentage": 12, "remaining_fraction": 0.5],
    ])
    let result = try await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: "/bin/sh",
        arguments: ["-c", AntigravityStatusCommand.script, "test", ""],
        environment: ["PATH": "/usr/bin:/bin", "VIBE_AGENT_ACTIVITY_LOG": log.path],
        timeout: .seconds(5), standardInput: BoundedProcessInput(data: data)))
    #expect(result.exitCode == 0)
    let written = try String(contentsOf: log, encoding: .utf8)
    #expect(!written.contains("private"))
    let payload = try #require(written.split(separator: "\t").last)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    #expect(object["agent_state"] as? String == "error")
    let quota = try #require(object["quota"] as? String)
    let buckets = AntigravityQuotaBucket.parse(quota)
    #expect(buckets.map(\.id).contains("gemini-weekly"))
    #expect(buckets.first { $0.id == "gemini-weekly" }?.isExhausted == true)
    #expect(buckets.first { $0.id == "3p-weekly" }?.remainingFraction == 0.75)
    #expect(!quota.contains("\""))
    #expect(!quota.contains("\\"))
    #expect(object.count == 5)
  }

  private func line(_ decoder: AntigravityConversationDecoder, _ object: [String: Any]) {
    decoder.consume((try? JSONSerialization.data(withJSONObject: object)) ?? Data())
  }

  @Test("An API error is shown while nothing follows it, and leaves once the retry answers")
  func transcriptErrors() {
    let decoder = AntigravityConversationDecoder()
    line(decoder, ["step_index": 0, "type": "PLANNER_RESPONSE", "content": "first"])
    line(
      decoder,
      [
        "step_index": 1, "type": "ERROR_MESSAGE", "status": "DONE",
        "error": "API error (attempt 1): UNAVAILABLE (code 503): No capacity available",
      ])
    #expect(
      decoder.entries.map(\.content) == [
        .agentText("first"),
        .notice(.error("API error (attempt 1): UNAVAILABLE (code 503): No capacity available")),
      ])
    line(
      decoder,
      [
        "step_index": 2, "type": "ERROR_MESSAGE", "status": "DONE",
        "error": "API error (attempt 2): RESOURCE_EXHAUSTED (code 429): Resets in 0s.",
      ])
    #expect(
      decoder.entries.map(\.content) == [
        .agentText("first"),
        .notice(.error("API error (attempt 2): RESOURCE_EXHAUSTED (code 429): Resets in 0s.")),
      ])
    line(decoder, ["step_index": 3, "type": "PLANNER_RESPONSE", "content": "second"])
    #expect(decoder.entries.map(\.content) == [.agentText("first"), .agentText("second")])
    // An error with no text, or not a string, is no step to show.
    line(decoder, ["step_index": 4, "type": "ERROR_MESSAGE", "error": "  "])
    line(decoder, ["step_index": 5, "type": "ERROR_MESSAGE", "error": ["code": 429]])
    #expect(decoder.entries.count == 2)
  }
}
