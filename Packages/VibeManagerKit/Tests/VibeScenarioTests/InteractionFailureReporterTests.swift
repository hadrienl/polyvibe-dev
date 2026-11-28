import Foundation
import Testing
import VibeApplication
import VibeProcess

@testable import VibeComposition

private actor ReportingCLI {
  var calls: [BoundedProcessRequest] = []
  let existing: Bool
  var failuresLeft: Int
  let created: String
  /// `gh` missing or signed out: every call fails.
  let isMissing: Bool
  /// The calls made before GitHub can be reached.
  var offlineCallsLeft: Int
  init(
    existing: Bool = false, failuresLeft: Int = 0,
    created: String = "https://github.com/hadrienl/polyvibe-dev/issues/123",
    isMissing: Bool = false, offlineCalls: Int = 0
  ) {
    self.existing = existing
    self.failuresLeft = failuresLeft
    self.created = created
    self.isMissing = isMissing
    self.offlineCallsLeft = offlineCalls
  }
  /// How many calls were `gh issue <action>`.
  func count(_ action: String) -> Int {
    calls.count { $0.arguments.starts(with: ["gh", "issue", action]) }
  }
  /// Whether `limit` issues were opened, and one more report looked for after them.
  func lookedPast(_ limit: Int) -> Bool {
    count("create") >= limit && count("list") > limit
  }
  func run(_ request: BoundedProcessRequest) -> BoundedProcessResult {
    calls.append(request)
    if isMissing { return BoundedProcessResult(termination: .exited(127)) }
    if offlineCallsLeft > 0 {
      offlineCallsLeft -= 1
      return BoundedProcessResult(
        termination: .exited(1),
        standardError: Data(
          "error connecting to api.github.com\ncheck your internet connection".utf8))
    }
    if request.arguments.contains("create"), failuresLeft > 0 {
      failuresLeft -= 1
      return BoundedProcessResult(termination: .exited(1))
    }
    let output =
      request.arguments.contains("list")
      ? (existing ? "[{\"url\":\"https://github.com/hadrienl/polyvibe-dev/issues/123\"}]" : "[]")
      : created + "\n"
    return BoundedProcessResult(termination: .exited(0), standardOutput: Data(output.utf8))
  }
}

/// A clock the test moves on.
private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  var now: Date { lock.withLock { date } }
  func advance(by interval: TimeInterval) { lock.withLock { date += interval } }
}

struct InteractionFailureReporterTests {
  private func failure() -> AnswerAgentRequest.Failure {
    .init(
      requestID: "request-a", outcome: .notOnScreen,
      request: "question with previews", answer: "option 1",
      before: "❯ 1. Relais\n  2. singleTask", after: "same dialog",
      keys: [[49], [13]], writtenKeys: [])
  }

  @Test("Common environment and authorization credentials are masked in every report field")
  func credentialFormats() {
    let credentials = """
      AWS_SECRET_ACCESS_KEY=review-only-fake-value
      export AWS_ACCESS_KEY_ID=AKIAREVIEWONLYFAKE000
      AWS_SESSION_TOKEN='fake session token with spaces'
      Authorization: Basic cmV2aWV3OmZha2U=
      {"Authorization": "Bearer fake-bearer-value"}
      curl --password 'fake cli password' --api-key=fake-cli-key
      {"password": "fake password with spaces", "api_key": "fake-json-key"}
      """
    let failure = AnswerAgentRequest.Failure(
      requestID: "credentials", outcome: .interrupted, request: credentials,
      answer: credentials, before: credentials, after: credentials, keys: [], writtenKeys: [])
    let body = InteractionFailureReporter.body(failure, fingerprint: "credentials")
    for secret in [
      "review-only-fake-value", "AKIAREVIEWONLYFAKE000", "fake session token with spaces",
      "cmV2aWV3OmZha2U=", "fake-bearer-value", "fake cli password", "fake-cli-key",
      "fake password with spaces", "fake-json-key",
    ] {
      #expect(!body.contains(secret))
    }
    #expect(body.contains("AWS_SECRET_ACCESS_KEY="))
    #expect(body.contains("Authorization: Basic [REDACTED]"))
  }

  @Test("A pending report from an earlier version is sanitized and retried after upload failure")
  func pendingReportRetry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("pending.json")
    let pending = [
      "title": "Legacy failure", "body": "<pre>AWS_SECRET_ACCESS_KEY=legacy-fake-secret</pre>",
    ]
    try JSONSerialization.data(withJSONObject: pending).write(to: file)
    let cli = ReportingCLI(failuresLeft: 1)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], retryDelay: .milliseconds(10),
      isEnabled: { true }, run: { await cli.run($0) })
    await reporter.start()
    var posted = false
    for _ in 0..<200 {
      let saved = try String(contentsOf: file, encoding: .utf8)
      if saved.contains("issueURL") {
        posted = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(posted)
    let saved = try String(contentsOf: file, encoding: .utf8)
    #expect(!saved.contains("legacy-fake-secret"))
    let uploads = await cli.calls.filter { $0.arguments.contains("create") }
    #expect(uploads.count == 2)
    for upload in uploads {
      let body = String(decoding: upload.standardInput?.data ?? Data(), as: UTF8.self)
      #expect(!body.contains("legacy-fake-secret"))
      #expect(body.contains("AWS_SECRET_ACCESS_KEY=[REDACTED]</pre>"))
    }
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

  @Test("The user's names are masked wherever they show as a word (#558)")
  func userNames() {
    let screen = "alice@alice-mbp ~/clients % git log\nAuthor: Alice Martin\nmalice ~alice"
    let scrubbed = InteractionFailureReporter.redact(screen, userNames: ["alice", "Alice Martin"])
    #expect(
      scrubbed
        == "[REDACTED]@[REDACTED]-mbp ~/clients % git log\nAuthor: [REDACTED]\nmalice ~[REDACTED]")
  }

  @Test("The Mac's names are masked too: alice@Alices-MacBook-Pro (#558)")
  func machineNames() {
    let names = InteractionFailureReporter.machineNames(
      computerName: "Alice’s MacBook Pro", localHostName: "Alices-MacBook-Pro",
      hostName: "Alices-MacBook-Pro.local")
    #expect(names == ["Alice’s MacBook Pro", "Alices-MacBook-Pro"])
    #expect(
      InteractionFailureReporter.machineNames(
        computerName: nil, localHostName: nil, hostName: "localhost"
      ).isEmpty)
    let screen = "alice@Alices-MacBook-Pro ~ % scutil --get ComputerName\nAlice’s MacBook Pro"
    let scrubbed = InteractionFailureReporter.redact(screen, userNames: ["alice"] + names)
    #expect(scrubbed == "[REDACTED]@[REDACTED] ~ % scutil --get ComputerName\n[REDACTED]")
  }

  @Test("Whose home a path is, tokens of common services and keys are masked too")
  func personalPathsAndTokens() {
    let text = """
      cwd: /Users/alice/clients/acme
      GITHUB_TOKEN=gh-fake-value NPM_TOKEN: 'npm-fake-value' max_tokens=4096
      postgres://app:db-fake-password@localhost/app
      glpat-fakefakefake xoxb-123-fake AIzaFakeFakeFakeFakeFakeFakeFakeFake1
      eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.fakesignature
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAA
      -----END OPENSSH PRIVATE KEY-----
      """
    let failure = AnswerAgentRequest.Failure(
      requestID: "home", outcome: .interrupted, request: text, answer: "option 1",
      before: text, after: text, keys: [], writtenKeys: [])
    let body = InteractionFailureReporter.body(failure, fingerprint: "home")
    for secret in [
      "alice", "gh-fake-value", "npm-fake-value", "db-fake-password", "glpat-fakefakefake",
      "xoxb-123-fake", "AIzaFake", "eyJhbGciOiJIUzI1NiJ9", "b3BlbnNzaC1rZXktdjEAAAAA",
    ] {
      #expect(!body.contains(secret), "\(secret)")
    }
    #expect(body.contains("/Users/[REDACTED]/clients/acme"))
    // A count of tokens is no token.
    #expect(body.contains("max_tokens=4096"))
  }

  @Test("A report too long for GitHub is cut to fit, its fingerprint kept")
  func fitsInAnIssue() {
    let screen = String(repeating: "<é> ", count: 40_000)
    let failure = AnswerAgentRequest.Failure(
      requestID: "long", outcome: .interrupted, request: screen, answer: screen,
      before: screen, after: screen, keys: [], writtenKeys: [])
    let body = InteractionFailureReporter.body(failure, fingerprint: "long")
    #expect(body.utf16.count < 65_536)
    #expect(body.contains("… (cut)"))
    #expect(body.hasSuffix("interaction-failure-long"))
    let legacy = String(repeating: "x", count: 100_000) + "\n\ninteraction-failure-legacy"
    let fitted = InteractionFailureReporter.fitted(legacy)
    #expect(fitted.utf16.count < 65_536)
    #expect(fitted.hasSuffix("interaction-failure-legacy"))
  }

  @Test("Composed outside the application, nothing is ever reported to GitHub")
  func notFromTests() {
    #expect(
      AppEnvironment.interactionFailureReporter(
        logs: FileManager.default.temporaryDirectory, environment: [:], isEnabled: { true })
        == nil)
  }

  @Test("A failure is persisted, posted once and remains deduplicated after restart")
  func durableReport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI()
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], isEnabled: { true }, run: { await cli.run($0) })
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
      directory: directory, environment: [:], isEnabled: { true }, run: { await cli.run($0) })
    await restarted.enqueue(failure())
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.count == 2)
    let calls = await cli.calls
    #expect(calls[1].arguments.contains("--body-file"))
    #expect(calls[1].standardInput?.data.isEmpty == false)
  }

  @Test(
    "An issue is created in the renamed repository, and its URL kept under either name",
    arguments: [
      ("https://github.com/hadrienl/polyvibe-dev/issues/7", true),
      ("https://github.com/hadrienl/vibe-manager/issues/7", true),
      ("https://github.com/someone/else/issues/7", false),
    ])
  func renamedRepository(created: String, kept: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI(created: created)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], retryDelay: .seconds(60), isEnabled: { true },
      run: { await cli.run($0) })
    await reporter.enqueue(failure())
    for _ in 0..<200 {
      if await cli.calls.count == 2 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))
    let calls = await cli.calls
    #expect(calls.count == 2)
    for call in calls {
      let repository = call.arguments.firstIndex(of: "--repo").map { call.arguments[$0 + 1] }
      #expect(repository == "hadrienl/polyvibe-dev")
    }
    let file = try #require(
      FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first)
    #expect(try String(contentsOf: file, encoding: .utf8).contains("issueURL") == kept)
  }

  @Test("An outbox entry left before a crash finds its existing GitHub ticket")
  func existingTicket() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI(existing: true)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], isEnabled: { true }, run: { await cli.run($0) })
    await reporter.enqueue(failure())
    for _ in 0..<200 {
      if await cli.calls.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.count == 1)
    #expect(await cli.calls.first?.arguments.contains("list") == true)
  }

  private func outbox() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func reports(in directory: URL) -> [[String: Any]] {
    let files =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []
    return files.compactMap {
      (try? JSONSerialization.jsonObject(with: Data(contentsOf: $0))) as? [String: Any]
    }
  }

  @Test("Turned off, a failure is neither kept nor sent, and what waits stays (#558)")
  func offByDefault() async throws {
    let directory = try outbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pending = ["title": "Earlier failure", "body": "<pre>screen</pre>"]
    try JSONSerialization.data(withJSONObject: pending).write(
      to: directory.appendingPathComponent("pending.json"))
    let cli = ReportingCLI()
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], isEnabled: { false }, run: { await cli.run($0) })
    await reporter.enqueue(failure())
    await reporter.start()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.isEmpty)
    #expect(reports(in: directory).count == 1)
    #expect(reports(in: directory).first?["issueURL"] == nil)
  }

  @Test("A text the user typed is reported by its length only (#558)")
  func typedTextOmitted() {
    let answer = AgentAnswer.answers([.option(2), .text("my private reply, with a name")])
    #expect(!answer.reported.contains("private"))
    #expect(answer.reported.contains("29 characters omitted"))
    #expect(answer.reported.contains("option(2)"))
    #expect(AgentAnswer.allowOnce.reported.hasSuffix("allowOnce"))
    #expect(
      answer.withoutTypedText("> my private reply, with a name\n  Enter to submit")
        == "> <typed text omitted>\n  Enter to submit")
    // One letter typed leaves the screen readable.
    let screen = "Do you want to proceed?\n> a\n  Enter to submit"
    #expect(AgentAnswer.answers([.text("a")]).withoutTypedText(screen) == screen)
  }

  @Test("Offline, an attempt is not counted, and the report goes out once online (#558)")
  func offline() async throws {
    let directory = try outbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI(offlineCalls: InteractionFailureReporter.maximumAttempts + 1)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], retryDelay: .milliseconds(1),
      isEnabled: { true }, run: { await cli.run($0) })
    await reporter.enqueue(failure())
    for _ in 0..<1_000 {
      if reports(in: directory).first?["issueURL"] != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let report = try #require(reports(in: directory).first)
    #expect(report["issueURL"] as? String == "https://github.com/hadrienl/polyvibe-dev/issues/123")
    #expect(report["abandoned"] == nil)
    #expect(report["attempts"] == nil)
  }

  @Test("Without gh, a report is given up after a few attempts, the delay doubling (#558)")
  func givesUp() async throws {
    let directory = try outbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI(isMissing: true)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], retryDelay: .milliseconds(1),
      isEnabled: { true }, run: { await cli.run($0) })
    await reporter.enqueue(failure())
    for _ in 0..<1_000 {
      if reports(in: directory).first?["abandoned"] as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reports(in: directory).first?["abandoned"] as? Bool == true)
    #expect(await cli.calls.count == InteractionFailureReporter.maximumAttempts)
    // Given up, it is not tried again at the next launch.
    await reporter.start()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await cli.calls.count == InteractionFailureReporter.maximumAttempts)
  }

  @Test("A report queued days ago is given up without running gh (#558)")
  func tooOld() async throws {
    let directory = try outbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI()
    let later = Date().addingTimeInterval(InteractionFailureReporter.maximumAge + 60)
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], isEnabled: { true }, now: { later },
      run: { await cli.run($0) })
    let pending: [String: Any] = [
      "title": "Old failure", "body": "<pre>screen</pre>",
      "queuedAt": Date().timeIntervalSinceReferenceDate,
    ]
    try JSONSerialization.data(withJSONObject: pending).write(
      to: directory.appendingPathComponent("old.json"))
    await reporter.start()
    for _ in 0..<200 {
      if reports(in: directory).first?["abandoned"] as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reports(in: directory).first?["abandoned"] as? Bool == true)
    #expect(await cli.calls.isEmpty)
  }

  @Test(
    "Few issues are opened a day, the others go out the next day (#558)", .timeLimit(.minutes(2)))
  func dailyLimit() async throws {
    let directory = try outbox()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ReportingCLI()
    let clock = TestClock()
    let reporter = InteractionFailureReporter(
      directory: directory, environment: [:], retryDelay: .milliseconds(5), isEnabled: { true },
      now: { clock.now }, run: { await cli.run($0) })
    for index in 0..<(InteractionFailureReporter.dailyIssueLimit + 2) {
      await reporter.enqueue(
        .init(
          requestID: "request-\(index)", outcome: .notOnScreen, request: "question",
          answer: "option 1", before: "screen", after: "screen", keys: [], writtenKeys: []))
    }
    // A state waited for, never a deadline: a runner that stalls only makes it longer. The
    // reports within the limit are opened, then the next one is looked for and kept waiting.
    let limit = InteractionFailureReporter.dailyIssueLimit
    while await !cli.lookedPast(limit) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let all = reports(in: directory)
    #expect(all.count == InteractionFailureReporter.dailyIssueLimit + 2)
    #expect(all.count { $0["issueURL"] != nil } == InteractionFailureReporter.dailyIssueLimit)
    #expect(
      await cli.calls.count { $0.arguments.contains("create") }
        == InteractionFailureReporter.dailyIssueLimit)
    #expect(all.allSatisfy { $0["attempts"] == nil })
    // A day later, with the application still open, the others go out.
    clock.advance(by: 25 * 3600)
    while reports(in: directory).count(where: { $0["issueURL"] != nil }) < all.count {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await cli.count("create") == all.count)
  }
}
