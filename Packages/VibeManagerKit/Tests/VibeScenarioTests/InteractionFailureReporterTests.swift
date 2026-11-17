import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeComposition

private actor ReportingCLI {
  var calls: [BoundedProcessRequest] = []
  let existing: Bool
  init(existing: Bool = false) { self.existing = existing }
  func run(_ request: BoundedProcessRequest) -> BoundedProcessResult {
    calls.append(request)
    let output =
      request.arguments.contains("list")
      ? (existing ? "[{\"url\":\"https://github.com/hadrienl/vibe-manager/issues/123\"}]" : "[]")
      : "https://github.com/hadrienl/vibe-manager/issues/123\n"
    return BoundedProcessResult(termination: .exited(0), standardOutput: Data(output.utf8))
  }
}

struct InteractionFailureReporterTests {
  private func failure() -> AnswerAgentRequest.Failure {
    .init(
      requestID: "request-a", outcome: .notOnScreen,
      request: "question with previews", answer: "option 1",
      before: "❯ 1. Relais\n  2. singleTask", after: "same dialog",
      keys: [[49], [13]], writtenKeys: [])
  }

  @Test("Reports preserve terminal text, input and recovery, while masking credentials")
  func reportContent() {
    let failure = AnswerAgentRequest.Failure(
      requestID: "a", outcome: .interrupted, request: #"{"api_key": "private-value"}"#,
      answer: "Bearer private-bearer", before: "ghp_privategithubtoken", after: "❯ 1. Relais",
      keys: [Array("private pasted value".utf8)], writtenKeys: [[49]])
    let body = InteractionFailureReporter.body(failure, fingerprint: "fingerprint")
    for secret in [
      "private-value", "private-bearer", "ghp_privategithubtoken", "private pasted value",
    ] {
      #expect(!body.contains(secret))
    }
    #expect(body.contains("❯ 1. Relais"))
    #expect(body.contains("[49]"))
    #expect(body.contains("terminal view"))
    #expect(body.contains("interaction-failure-fingerprint"))
  }

  @Test("A failure is persisted, posted once and remains deduplicated after restart")
  func durableReport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI()
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], run: { await cli.run($0) })
    await reporter.enqueue(failure())
    var posted = false
    for _ in 0..<200 {
      if let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil),
        let file = files.first, let text = try? String(contentsOf: file, encoding: .utf8),
        text.contains("issueURL")
      {
        posted = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(posted)
    #expect(await cli.calls.count == 2)
    let restarted = InteractionFailureReporter(
      directory: directory, environment: [:], run: { await cli.run($0) })
    await restarted.enqueue(failure())
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.count == 2)
    let calls = await cli.calls
    #expect(calls[1].arguments.contains("--body-file"))
    #expect(calls[1].standardInput?.data.isEmpty == false)
  }

  @Test("An outbox entry left before a crash finds its existing GitHub ticket")
  func existingTicket() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI(existing: true)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], run: { await cli.run($0) })
    await reporter.enqueue(failure())
    for _ in 0..<200 {
      if await cli.calls.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.count == 1)
    #expect(await cli.calls.first?.arguments.contains("list") == true)
  }
}
