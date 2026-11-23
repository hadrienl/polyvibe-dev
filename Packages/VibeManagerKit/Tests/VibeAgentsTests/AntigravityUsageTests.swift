import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// What agy 1.5.14 writes of its tokens (#599): `input_tokens`, `cache_read_tokens` and
/// `output_tokens` on each `PLANNER_RESPONSE`, beside its `model`, and on the `CHECKPOINT` that
/// compacts the conversation, without one.
@Suite("Antigravity usage and context")
struct AntigravityUsageTests {
  private let identifier = "09791e20-e97a-4171-b325-9305c13f7085"

  private func home() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerAgyUsage-\(UUID().uuidString)", isDirectory: true)
  }

  private func reader(_ root: URL) -> AgentUsageReader {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return AgentUsageReader(
      locator: AgentTranscriptLocator(
        claudeProjects: root.appendingPathComponent("projects"),
        codexSessions: root.appendingPathComponent("sessions"), antigravityHome: root),
      calendar: calendar, now: { Date(timeIntervalSince1970: 1_795_000_000) })
  }

  private func session() -> WorkSession {
    WorkSession(
      name: "Antigravity",
      agent: SessionAgentConfiguration(providerID: "antigravity", resumeIdentifier: identifier))
  }

  private func response(
    _ step: Int, input: Int, cacheRead: Int, output: Int, model: String = "gemini-3.8-flash-high"
  ) -> String {
    """
    {"step_index":\(step),"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE",\
    "created_at":"2026-11-22T11:55:47Z","content":"secret \\"input_tokens\\": 999",\
    "model":"\(model)","input_tokens":\(input),"cache_read_tokens":\(cacheRead),\
    "output_tokens":\(output)}
    """
  }

  private func checkpoint(_ step: Int, input: Int, cacheRead: Int, output: Int) -> String {
    """
    {"step_index":\(step),"source":"SYSTEM","type":"CHECKPOINT","status":"DONE",\
    "created_at":"2026-11-22T12:27:50Z","input_tokens":\(input),"cache_read_tokens":\(cacheRead),\
    "output_tokens":\(output),"truncated_fields":["content"]}
    """
  }

  private func write(_ lines: [String], in root: URL) throws {
    let url = try #require(AntigravityAgentProvider.transcript(identifier: identifier, home: root))
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
  }

  @Test("Each response counts once, by its step; a checkpoint counts for the last model named")
  func usage() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(
      [
        #"{"step_index":0,"type":"USER_INPUT","content":"\"input_tokens\": 5"}"#,
        response(1, input: 9_654, cacheRead: 0, output: 682),
        response(1, input: 9_654, cacheRead: 0, output: 682),
        response(6, input: 2_294, cacheRead: 9_650, output: 244),
        checkpoint(7, input: 7_253, cacheRead: 256_035, output: 2_614),
        response(9, input: 10, cacheRead: 0, output: 1, model: "claude-sonnet-5-5"),
      ], in: root)

    let snapshot = await reader(root).refresh([session()], from: .empty, isTracked: { _ in true })

    let gemini = try #require(snapshot.buckets.first { $0.model == "gemini-3.8-flash-high" })
    #expect(gemini.tokens.input == 9_654 + 2_294 + 7_253)
    #expect(gemini.tokens.cacheRead == 9_650 + 256_035)
    #expect(gemini.tokens.cacheWrite == 0)
    #expect(gemini.tokens.output == 682 + 244 + 2_614)
    #expect(gemini.responses == 3)
    #expect(snapshot.buckets.first { $0.model == "claude-sonnet-5-5" }?.responses == 1)
    #expect(snapshot.files.values.allSatisfy { $0.providerID == "antigravity" })
  }

  @Test("A conversation agy has not written yet reads as nothing")
  func noTranscript() async {
    let root = home()
    let snapshot = await reader(root).refresh([session()], from: .empty, isTracked: { _ in true })
    #expect(snapshot.buckets.isEmpty)
  }

  @Test("The context is the last response's input with its cache; a checkpoint is a compaction")
  func context() async throws {
    let root = home()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(
      [
        response(331, input: 2_847, cacheRead: 252_643, output: 102),
        checkpoint(336, input: 7_253, cacheRead: 256_035, output: 2_614),
        response(337, input: 12_309, cacheRead: 0, output: 352),
      ], in: root)
    let session = session()

    let file = await reader(root).readContext(of: session.agent!, session: session, from: nil)

    let usage = try #require(file?.usage)
    #expect(usage.usedTokens == 12_309)
    #expect(usage.windowSize == nil)
    #expect(usage.model == "gemini-3.8-flash-high")
    #expect(usage.lastCompaction?.tokensBefore == 263_288)
  }

  @Test("Antigravity is an agent whose usage is read")
  func reportsUsage() {
    #expect(AntigravityAgentProvider.descriptor.capabilities.reportsUsage)
  }
}
