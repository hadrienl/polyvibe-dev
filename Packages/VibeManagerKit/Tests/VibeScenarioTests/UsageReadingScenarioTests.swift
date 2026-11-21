import Foundation
import Testing
import VibeAgents
import VibeApplication
import VibeDomain
import VibePersistence

@testable import VibeUI

/// A session's usage read end to end (#574), from its transcript to the figures of its button:
/// the real stores, reader and prices — the copy shipped with the application.
@Suite("Reading a session's usage, from its transcript to its cost (#574)")
@MainActor
struct UsageReadingScenarioTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  @Test("Tokens, cost and context of a Claude Code conversation")
  func identifierOnlyInTheStore() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("UsageReading-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identifier = UUID().uuidString.lowercased()
    let projects = root.appendingPathComponent("projects")
    let transcript = projects.appendingPathComponent("-Users-me-repo/\(identifier).jsonl")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      """
      {"type":"assistant","timestamp":"2026-11-20T09:00:00.000Z","requestId":"req_1","message":{"id":"msg_1",\
      "model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,\
      "cache_creation_input_tokens":7,"cache_read_input_tokens":100,"output_tokens":5}}}

      """.utf8
    ).write(to: transcript)

    let usageDirectory = root.appendingPathComponent("Usage")
    let ledger = FileUsageLedger(directory: usageDirectory)
    let tracking = FileUsageTrackingStore(directory: usageDirectory)
    let reader = AgentUsageReader(
      locator: AgentTranscriptLocator(
        claudeProjects: projects, codexSessions: root.appendingPathComponent("sessions")),
      calendar: calendar)
    let service = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking), ledger: ledger,
      tracking: tracking, tokenStore: FileTokenUsageStore(directory: usageDirectory),
      reader: reader, contextReader: reader,
      prices: ModelPriceUpdater(
        fetcher: NoFetch(),
        store: FileModelPriceStore(directory: root.appendingPathComponent("Prices")),
        bundled: FileModelPriceStore.bundled()))
    let model = UsageModel(service: service, refreshInterval: .seconds(3_600))

    let launched = Date(timeIntervalSince1970: 1_800_000_000)
    let listed = WorkSession(
      name: "Claude",
      agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: identifier),
      status: .active, createdAt: launched, updatedAt: launched, startedAt: launched)
    model.connect(sessions: { [listed] })
    await model.settleLaunch(running: [listed.id], sessions: [listed], readOnly: false)

    model.startWatching(listed.id)
    defer { model.stopWatching(listed.id) }
    await model.refresh()

    let usage = try #require(model.sessionUsage[listed.id])
    #expect(usage.hasTranscript)
    #expect(usage.total.tokens == TokenCounts(input: 10, cacheRead: 100, cacheWrite: 7, output: 5))
    #expect(model.contextWindows[listed.id]?.usedTokens == 117)
    #expect(model.tokenUnavailability(for: listed) == nil)
    #expect(model.contextUnavailability(for: listed) == nil)
    // Priced from the copy shipped with the application, before any list is fetched.
    #expect(usage.cost.hasPrice)
    #expect(usage.cost.unpriced.isEmpty)
  }
}

private struct NoFetch: ModelPriceFetching {
  func fetchPriceList() async throws -> Data { throw CancellationError() }
}
