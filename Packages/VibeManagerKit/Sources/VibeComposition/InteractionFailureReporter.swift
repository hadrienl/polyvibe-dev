import CryptoKit
import Foundation
import SystemConfiguration
import VibeApplication
import VibeProcess

/// Durable outbox: a failed interaction remains reportable through offline periods and restarts.
/// The request fingerprint is also searched on GitHub before creation, covering a crash after POST.
///
/// An issue is public and opened under the user's own GitHub account: nothing is written or sent
/// unless they turned the reports on (`isEnabled`). Retries back off and give up, and few issues
/// are opened a day, so that a CLI whose dialogs changed cannot flood the repository.
actor InteractionFailureReporter {
  /// Where the issues are created.
  static let repository = "hadrienl/polyvibe-dev"

  /// What the URL of an issue created opens with: under the repository's name, or its former one
  /// (`gh` may answer with either while GitHub redirects the renamed repository, ADR 0046).
  static let issuePrefixes = [
    "https://github.com/\(repository)/issues/", "https://github.com/hadrienl/vibe-manager/issues/",
  ]

  private let directory: URL
  private let environment: [String: String]
  private let retryDelay: Duration
  private let isEnabled: @Sendable () async -> Bool
  private var draining = false
  private var needsDrain = false
  private let run: @Sendable (BoundedProcessRequest) async throws -> BoundedProcessResult
  private let now: @Sendable () -> Date

  /// A report not sent after this many failed attempts, or this long after it was queued, is
  /// given up: `gh` missing or signed out would otherwise be run for the life of the application.
  /// An attempt that could not reach GitHub is not counted: offline, a report waits its age out.
  static let maximumAttempts = 10
  static let maximumAge: TimeInterval = 3 * 24 * 3600
  /// The longest wait between two attempts, the delay doubling from `retryDelay`.
  static let maximumRetryDelay: Duration = .seconds(3600)
  /// The issues opened in a day at most; the others are tried again later, and go out as the
  /// oldest issue of the day turns 24 hours old.
  static let dailyIssueLimit = 3

  init(
    directory: URL, environment: [String: String], retryDelay: Duration = .seconds(60),
    isEnabled: @escaping @Sendable () async -> Bool,
    now: @escaping @Sendable () -> Date = { Date() },
    run: @escaping @Sendable (BoundedProcessRequest) async throws -> BoundedProcessResult = {
      try await BoundedProcess.run($0)
    }
  ) {
    self.retryDelay = retryDelay
    self.isEnabled = isEnabled
    self.now = now
    self.run = run
    self.directory = directory
    var environment = environment
    environment["PATH"] = [
      environment["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ].joined(separator: ":")
    environment["GH_PROMPT_DISABLED"] = "1"
    environment["GH_HOST"] = "github.com"
    self.environment = environment
  }

  func enqueue(_ failure: AnswerAgentRequest.Failure) async {
    // Turned off, the failure is not even kept: the terminal fallback is all that happens.
    guard await isEnabled() else { return }
    let fingerprint = SHA256.hash(data: Data(failure.requestID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let file = directory.appendingPathComponent(fingerprint + ".json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: file.path) {
        let report = Report(
          title: "Interaction failed: \(failure.outcome.rawValue)",
          body: Self.body(failure, fingerprint: fingerprint), queuedAt: now())
        try JSONEncoder().encode(report).write(to: file, options: .atomic)
      }
      needsDrain = true
      start()
    } catch {
      // The terminal fallback does not depend on disk or GitHub being available.
    }
  }

  func start() {
    guard !draining else { return }
    draining = true
    Task { await drain() }
  }

  private struct Report: Codable {
    let title: String
    var body: String
    var issueURL: String?
    /// Absent from the reports of 1.2.0-rc: their file's date stands for it.
    var queuedAt: Date?
    var attempts: Int?
    var issueCreatedAt: Date?
    var abandoned: Bool?
  }

  private func gh(_ arguments: [String], input: String? = nil) async throws -> BoundedProcessResult
  {
    try await run(
      BoundedProcessRequest(
        executablePath: "/usr/bin/env", arguments: ["gh"] + arguments,
        environment: environment, timeout: .seconds(30), outputByteLimit: 32_768,
        standardInput: input.map { BoundedProcessInput(data: Data($0.utf8)) }))
  }

  private func drain() async {
    defer { draining = false }
    var delay = retryDelay
    while !Task.isCancelled {
      needsDrain = false
      guard await isEnabled() else { return }
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
      var pending = false
      for file in files where file.pathExtension == "json" {
        guard var report = try? JSONDecoder().decode(Report.self, from: Data(contentsOf: file)),
          report.issueURL == nil, report.abandoned != true
        else { continue }
        // Turned off meanwhile: what waits stays where it is.
        guard await isEnabled() else { return }
        let queuedAt =
          report.queuedAt ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate)
          ?? now()
        if now().timeIntervalSince(queuedAt) > Self.maximumAge {
          report.abandoned = true
          try? JSONEncoder().encode(report).write(to: file, options: .atomic)
          continue
        }
        do {
          // Re-sanitize pending reports written by older app versions before any upload, and
          // fit them in what GitHub takes: one refused for its length would be sent again and
          // again.
          report.body = Self.fitted(Self.redact(report.body))
          report.queuedAt = queuedAt
          try JSONEncoder().encode(report).write(to: file, options: .atomic)
          let fingerprint = file.deletingPathExtension().lastPathComponent
          let found = try await gh([
            "issue", "list", "--repo", Self.repository, "--state", "all", "--search",
            "interaction-failure-\(fingerprint) in:body", "--json", "url",
          ])
          guard found.exitCode == 0,
            let existing = try JSONSerialization.jsonObject(with: found.standardOutput)
              as? [[String: Any]]
          else {
            pending = failed(&report, file, counted: !Self.isOffline(found)) || pending
            continue
          }
          if let url = existing.first?["url"] as? String {
            report.issueURL = url
          } else {
            // Enough for today: tried again later, which is not a failed attempt.
            guard createdToday(in: files) < Self.dailyIssueLimit else {
              pending = true
              break
            }
            let created = try await gh(
              [
                "issue", "create", "--repo", Self.repository, "--title", report.title,
                "--label", "bug", "--body-file", "-",
              ], input: report.body)
            guard created.exitCode == 0 else {
              pending = failed(&report, file, counted: !Self.isOffline(created)) || pending
              continue
            }
            let url = String(decoding: created.standardOutput, as: UTF8.self).trimmingCharacters(
              in: .whitespacesAndNewlines)
            guard Self.issuePrefixes.contains(where: url.hasPrefix) else {
              pending = failed(&report, file) || pending
              continue
            }
            report.issueURL = url
            report.issueCreatedAt = now()
          }
          try JSONEncoder().encode(report).write(to: file, options: .atomic)
        } catch { pending = failed(&report, file) || pending }
      }
      if needsDrain { continue }
      guard pending else { return }
      do { try await Task.sleep(for: delay) } catch { return }
      delay = min(delay * 2, Self.maximumRetryDelay)
    }
  }

  /// Counts a failed attempt, unless `counted` is false; whether the report is still to be tried.
  private func failed(_ report: inout Report, _ file: URL, counted: Bool = true) -> Bool {
    guard counted else { return true }
    let attempts = (report.attempts ?? 0) + 1
    report.attempts = attempts
    if attempts >= Self.maximumAttempts { report.abandoned = true }
    try? JSONEncoder().encode(report).write(to: file, options: .atomic)
    return report.abandoned != true
  }

  /// `gh` could not reach GitHub: the Mac is offline, the report is not at fault.
  nonisolated static func isOffline(_ result: BoundedProcessResult) -> Bool {
    let message = String(decoding: result.standardError, as: UTF8.self)
    return message.contains("error connecting to")
  }

  /// The issues this outbox opened in the last 24 hours.
  private func createdToday(in files: [URL]) -> Int {
    files.count { file in
      guard
        let report = try? JSONDecoder().decode(Report.self, from: Data(contentsOf: file)),
        let created = report.issueCreatedAt
      else { return false }
      return now().timeIntervalSince(created) < 24 * 3600
    }
  }

  /// The names of the user on this Mac, short and full: what a prompt, `~alice` or a commit's
  /// author shows of them. And the Mac's own, which a prompt shows as `alice@Alices-MacBook-Pro`.
  static let userNames =
    [NSUserName(), NSFullUserName()]
    + machineNames(
      computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?,
      localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
      hostName: ProcessInfo.processInfo.hostName)

  /// The Mac's name as the user gave it (`Alice's MacBook Pro`, `scutil --get ComputerName`), and
  /// its host names without `.local` (`Alices-MacBook-Pro`). Read from the dynamic store, which
  /// answers at once, where `Host.current()` may wait on the network.
  static func machineNames(computerName: String?, localHostName: String?, hostName: String)
    -> [String]
  {
    let short = hostName.hasSuffix(".local") ? String(hostName.dropLast(6)) : hostName
    var names: [String] = []
    for name in [computerName, localHostName, short].compactMap({ $0 })
    where !name.isEmpty && name != "localhost" && !names.contains(name) {
      names.append(name)
    }
    return names
  }

  /// Shared by new reports and the durable outbox, so upgrades also protect queued text.
  nonisolated static func redact(_ text: String, userNames: [String] = userNames) -> String {
    var scrubbed = text.replacingOccurrences(of: "\\\"", with: "\"")
    let patterns = [
      #"(?i)(\bbearer\s+)[^\s"'\\,}<>]+"#,
      #"(?i)((?:proxy-)?authorization["']?\s*:\s*["']?(?:basic|bearer)\s+)[^\s"'\\,}<>]+"#,
      #"(?i)(\b(?:AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|SECURITY_TOKEN)|(?:[A-Z0-9]+_)*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|AUTH[_-]?TOKEN|TOKEN|PASSWORD|SECRET|CLIENT[_-]?SECRET))["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s"'\\,}<>]+)"#,
      // The password of an address: `postgres://user:password@host`.
      #"(://[^/\s:@"'<>]+:)[^/\s@"'<>]+(?=@)"#,
      // Whose home it is: `/Users/<name>`, in a working directory, a path, the prompt.
      #"(/Users/)[^/\s"'\\<>:]+"#,
      #"(?i)(--(?:password|api-key|token|secret|client-secret)[\s=]+)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s"'\\,}<>]+)"#,
    ]
    for pattern in patterns {
      scrubbed = scrubbed.replacingOccurrences(
        of: pattern, with: "$1[REDACTED]", options: .regularExpression)
    }
    // Whose Mac it is, wherever the name shows as a word: `alice@alice-mbp ~ %`.
    for name in userNames.sorted(by: { $0.count > $1.count }) where name.count >= 2 {
      scrubbed = scrubbed.replacingOccurrences(
        of: #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name)
          + #"(?![\p{L}\p{N}])"#,
        with: "[REDACTED]", options: .regularExpression)
    }
    return scrubbed.replacingOccurrences(
      of:
        #"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|(?:AKIA|ASIA)[A-Z0-9]{16}|glpat-[A-Za-z0-9_-]+|xox[abposr]-[A-Za-z0-9-]+|AIza[A-Za-z0-9_-]{30,}|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+)\b|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#,
      with: "[REDACTED]", options: .regularExpression)
  }

  /// What GitHub takes in an issue's body is 65,536 characters; a block is cut well before, so
  /// that the six of a report always fit.
  static let blockLimit = 9_000
  static let bodyLimit = 60_000

  /// The start of `text`, at most `limit` UTF-16 units — what GitHub counts — whole characters.
  nonisolated static func capped(_ text: String, _ limit: Int) -> String {
    guard text.utf16.count > limit else { return text }
    var count = 0
    var end = text.startIndex
    for index in text.indices {
      let width = text[index].utf16.count
      guard count + width <= limit else { break }
      count += width
      end = text.index(after: index)
    }
    return String(text[..<end])
  }

  /// A body GitHub takes, its last lines — the fingerprint looked for — kept.
  nonisolated static func fitted(_ body: String) -> String {
    guard body.utf16.count > bodyLimit else { return body }
    return capped(body, bodyLimit - 400) + "\n…\n" + String(body.suffix(200))
  }

  nonisolated static func body(_ failure: AnswerAgentRequest.Failure, fingerprint: String) -> String
  {
    func block(_ text: String) -> String {
      let scrubbed = redact(text)
      let escaped = scrubbed.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
        of: "<", with: "&lt;"
      ).replacingOccurrences(of: ">", with: "&gt;")
      let shown = capped(escaped, blockLimit)
      return "<pre>" + shown + (shown.count < escaped.count ? "\n… (cut)" : "") + "</pre>"
    }
    func keyGroups(_ groups: [[UInt8]]) -> String {
      groups.map { group in
        let isDigit = group.count == 1 && (49...57).contains(group[0])
        let isControl = [[13], [27], [27, 91, 65], [27, 91, 66], [27, 91, 67], [27, 91, 68]]
          .contains(group)
        return isDigit || isControl ? String(describing: group) : "<text input omitted>"
      }.joined(separator: "\n")
    }
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    return """
      Automatic interaction failure report. No screenshot is required; the terminal layout is included below.

      - Time: \(Date().ISO8601Format())
      - App: \(version) (\(build)); OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
      - Outcome: \(failure.outcome.rawValue)
      - Request: \(failure.requestID)
      - Expected: selecting the answer in the interaction card completes this request in its own terminal.
      - Actual: the dialog could not be safely answered, changed during input, or stayed open after input (\(AnswerAgentRequest.confirmationLimit.components.seconds) seconds after its redraw, \(AnswerAgentRequest.unreadKeyLimit.components.seconds) while the agent drew nothing).
      - Recovery: automatically open this session in terminal view. No automatic input retry.

      Reproduction: present the request below in the agent CLI, with the terminal layout shown in “Before”, then submit the recorded answer from the conversation card or request palette.

      Request payload:
      \(block(failure.request))
      Selected answer:
      \(block(failure.answer))
      Planned key groups (decimal UTF-8 bytes):
      \(block(keyGroups(failure.keys)))
      Successfully written key groups:
      \(block(keyGroups(failure.writtenKeys)))
      Before:
      \(block(failure.before))
      After:
      \(block(failure.after))

      interaction-failure-\(fingerprint)
      """
  }
}
