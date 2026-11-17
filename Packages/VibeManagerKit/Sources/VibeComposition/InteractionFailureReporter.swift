import CryptoKit
import Foundation
import VibeApplication
import VibeProcess

/// Durable outbox: a failed interaction remains reportable through offline periods and restarts.
/// The request fingerprint is also searched on GitHub before creation, covering a crash after POST.
actor InteractionFailureReporter {
  private let directory: URL
  private let environment: [String: String]
  private var draining = false
  private var needsDrain = false
  private let run: @Sendable (BoundedProcessRequest) async throws -> BoundedProcessResult

  init(
    directory: URL, environment: [String: String],
    run: @escaping @Sendable (BoundedProcessRequest) async throws -> BoundedProcessResult = {
      try await BoundedProcess.run($0)
    }
  ) {
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

  func enqueue(_ failure: AnswerAgentRequest.Failure) {
    let fingerprint = SHA256.hash(data: Data(failure.requestID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let file = directory.appendingPathComponent(fingerprint + ".json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: file.path) {
        let report = Report(
          title: "Interaction failed: \(failure.outcome.rawValue)",
          body: Self.body(failure, fingerprint: fingerprint))
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
    let body: String
    var issueURL: String?
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
    while !Task.isCancelled {
      needsDrain = false
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)) ?? []
      var pending = false
      for file in files where file.pathExtension == "json" {
        guard var report = try? JSONDecoder().decode(Report.self, from: Data(contentsOf: file)),
          report.issueURL == nil
        else { continue }
        do {
          let fingerprint = file.deletingPathExtension().lastPathComponent
          let found = try await gh([
            "issue", "list", "--repo", "hadrienl/vibe-manager", "--state", "all", "--search",
            "interaction-failure-\(fingerprint) in:body", "--json", "url",
          ])
          guard found.exitCode == 0,
            let existing = try JSONSerialization.jsonObject(with: found.standardOutput)
              as? [[String: Any]]
          else {
            pending = true
            continue
          }
          if let url = existing.first?["url"] as? String {
            report.issueURL = url
          } else {
            let created = try await gh(
              [
                "issue", "create", "--repo", "hadrienl/vibe-manager", "--title", report.title,
                "--label", "bug", "--body-file", "-",
              ], input: report.body)
            guard created.exitCode == 0 else {
              pending = true
              continue
            }
            let url = String(decoding: created.standardOutput, as: UTF8.self).trimmingCharacters(
              in: .whitespacesAndNewlines)
            guard url.hasPrefix("https://github.com/hadrienl/vibe-manager/issues/") else {
              pending = true
              continue
            }
            report.issueURL = url
          }
          try JSONEncoder().encode(report).write(to: file, options: .atomic)
        } catch { pending = true }
      }
      if needsDrain { continue }
      guard pending else { return }
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
    }
  }

  nonisolated static func body(_ failure: AnswerAgentRequest.Failure, fingerprint: String) -> String
  {
    func block(_ text: String) -> String {
      // Keep the layout as text; mask common credential forms before sending it outside the Mac.
      let scrubbed = text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(
        of:
          #"(?i)(bearer\s+|(?:api[_-]?key|access[_-]?token|password|secret)["']?\s*[:=]\s*["']?)[^\s\"\\,}]+"#,
        with: "$1[REDACTED]", options: .regularExpression
      )
      .replacingOccurrences(
        of: #"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b"#,
        with: "[REDACTED]", options: .regularExpression)
      return "<pre>"
        + scrubbed.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
          of: "<", with: "&lt;"
        ).replacingOccurrences(of: ">", with: "&gt;") + "</pre>"
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
      - Actual: the dialog could not be safely answered, changed during input, or stayed open after input (3 second confirmation limit).
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
