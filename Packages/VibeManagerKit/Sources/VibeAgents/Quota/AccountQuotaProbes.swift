import Foundation
import VibeApplication
import VibeProcess

/// Asks each CLI for its account's quota (#599), the way CodexBar does: with the CLI's own
/// sign-in, the account's folder (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) in its environment, in an
/// empty folder, bounded in time and output. Nothing a CLI answers is kept but the fields the
/// types below declare: shares, windows, dates, a plan and the names of groups and models.
///
/// Measured on codex-cli 0.169.0, claude 2.1.330 and agy 1.5.14, 2026-11-22: none of the three
/// calls a model, spends a turn or writes a conversation.
enum AccountQuotaProbe {
  static let timeout: Duration = .seconds(20)
  static let outputLimit = 1 << 20

  /// An empty folder of its own, for the CLIs to start in: none reads a project's configuration.
  static func workingDirectory() -> String {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerQuota", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.path
  }

  /// A date as the CLIs write it: ISO 8601, with or without a fraction of any length.
  static func date(_ text: String?) -> Date? {
    guard var text else { return nil }
    if let dot = text.firstIndex(of: "."),
      let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." })
    {
      text.removeSubrange(dot..<end)
    } else if let dot = text.firstIndex(of: ".") {
      text.removeSubrange(dot...)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }

  static func says(_ output: Data, signedOut patterns: [String]) -> Bool {
    let text = String(decoding: output.prefix(64 * 1024), as: UTF8.self).lowercased()
    return patterns.contains { text.contains($0) }
  }

  // MARK: - Claude Code

  /// `claude -p /usage`: a local command, answered without the model. Hooks, MCP servers and tools
  /// are off, and nothing is written to the transcripts; its input is empty, or it would read it.
  static let claudeArguments = [
    "-p", "/usage", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
    "--allowed-tools", "", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#,
  ]

  static func claude(_ output: Data, now: Date) -> AccountQuotaReading {
    for line in output.split(separator: 0x0A)
    where line.range(of: Data(#""usage_report""#.utf8)) != nil {
      guard let decoded = try? JSONDecoder().decode(ClaudeQuotaLine.self, from: Data(line)),
        let report = decoded.usageReport
      else { continue }
      // An account on an API key has a usage report without limits: it has no quota.
      guard let limits = report.rateLimits?.limits, !limits.isEmpty else {
        return .unavailable(.notReportedByAgent)
      }
      let windows = limits.compactMap { limit -> QuotaWindow? in
        guard let kind = limit.kind, let percent = limit.percent else { return nil }
        let window: QuotaWindow.Kind
        switch kind {
        case "session": window = .session
        case "weekly_all": window = .weekly
        case "weekly_scoped":
          guard let model = limit.scope?.model?.displayName, !model.isEmpty else { return nil }
          window = .weeklyModel(String(model.prefix(64)))
        default: return nil
        }
        let id = kind + (limit.scope?.model?.displayName.map { ":" + $0 } ?? "")
        return QuotaWindow(
          id: id, kind: window, usedFraction: percent / 100, resetsAt: date(limit.resetsAt))
      }
      guard !windows.isEmpty else { return .unavailable(.unrecognized) }
      return .measured(AccountQuota(windows: windows, measuredAt: now))
    }
    if says(output, signedOut: ["not logged in", "please run /login", "invalid api key"]) {
      return .unavailable(.signedOut)
    }
    return .unavailable(.unrecognized)
  }

  // MARK: - Codex

  static let codexMethod = "account/rateLimits/read"

  static func codex(_ result: Data, now: Date) -> AccountQuotaReading {
    guard let decoded = try? JSONDecoder().decode(CodexQuotaResult.self, from: result),
      let limits = decoded.rateLimits
    else { return .unavailable(.unrecognized) }
    let windows = [("primary", limits.primary), ("secondary", limits.secondary)].compactMap {
      id, window -> QuotaWindow? in
      guard let window, let used = window.usedPercent else { return nil }
      let kind: QuotaWindow.Kind =
        window.windowDurationMins == 10_080 ? .weekly : .minutes(window.windowDurationMins ?? 0)
      return QuotaWindow(
        id: id, kind: kind, usedFraction: used / 100,
        resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) })
    }
    guard !windows.isEmpty else { return .unavailable(.unrecognized) }
    return .measured(
      AccountQuota(
        windows: windows, plan: limits.planType.map { String($0.prefix(32)) }, measuredAt: now))
  }

  static func codexFailure(_ error: any Error) -> AccountQuotaReading {
    if case CodexHookTrustError.serverFailed(let message) = error,
      says(Data(message.utf8), signedOut: ["auth", "login", "logged in", "sign in"])
    {
      return .unavailable(.signedOut)
    }
    return .unavailable(.failed)
  }

  // MARK: - Antigravity

  static let antigravityArguments = ["-p", "/usage", "--output-format", "json"]

  static func antigravity(_ output: Data, now: Date) -> AccountQuotaReading {
    guard let decoded = try? JSONDecoder().decode(AntigravityQuotaAnswer.self, from: output) else {
      if says(output, signedOut: ["not logged in", "sign in", "login", "authenticate"]) {
        return .unavailable(.signedOut)
      }
      return .unavailable(.unrecognized)
    }
    guard let groups = decoded.command?.data?.groups else {
      if says(output, signedOut: ["not logged in", "sign in", "login", "authenticate"]) {
        return .unavailable(.signedOut)
      }
      return .unavailable(.unrecognized)
    }
    var windows: [QuotaWindow] = []
    for group in groups.prefix(8) {
      for bucket in (group.buckets ?? []).prefix(4) {
        guard let id = bucket.id, let remaining = bucket.remainingFraction else { continue }
        let name = (group.name?.isEmpty == false ? group.name : nil) ?? id
        windows.append(
          QuotaWindow(
            id: String(id.prefix(64)), kind: .group(String(name.prefix(64))),
            usedFraction: 1 - remaining, resetsAt: date(bucket.resetTime)))
      }
    }
    guard !windows.isEmpty else { return .unavailable(.unrecognized) }
    return .measured(AccountQuota(windows: windows, measuredAt: now))
  }

  /// Runs a CLI that answers on its output and ends.
  static func run(_ plan: AgentLaunchPlan, arguments: [String]) async -> BoundedProcessResult? {
    try? await BoundedProcess.run(
      BoundedProcessRequest(
        executablePath: plan.executablePath, arguments: arguments, environment: plan.environment,
        workingDirectoryPath: plan.workingDirectoryPath, timeout: timeout,
        outputByteLimit: outputLimit))
  }
}

// MARK: - The agents

extension ClaudeCodeAgentProvider: AgentQuotaReporting {
  public var quotaPageURL: URL? { URL(string: "https://claude.ai/settings/usage") }

  public func readQuota() async -> AccountQuotaReading {
    guard
      let plan = try? await launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: AccountQuotaProbe.workingDirectory()))
    else { return .unavailable(.notInstalled) }
    guard
      let result = await AccountQuotaProbe.run(plan, arguments: AccountQuotaProbe.claudeArguments)
    else { return .unavailable(.failed) }
    let reading = AccountQuotaProbe.claude(result.standardOutput, now: Date())
    if case .unavailable(.unrecognized) = reading, result.didTimeOut {
      return .unavailable(.failed)
    }
    return reading
  }
}

extension CodexAgentProvider: AgentQuotaReporting {
  public var quotaPageURL: URL? { URL(string: "https://chatgpt.com/codex/settings/usage") }

  public func readQuota() async -> AccountQuotaReading {
    guard
      let plan = try? await launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: AccountQuotaProbe.workingDirectory()))
    else { return .unavailable(.notInstalled) }
    do {
      let result = try await appServer.call(
        plan: plan, options: [], method: AccountQuotaProbe.codexMethod, params: Data("{}".utf8))
      return AccountQuotaProbe.codex(result, now: Date())
    } catch {
      return AccountQuotaProbe.codexFailure(error)
    }
  }
}

extension AntigravityAgentProvider: AgentQuotaReporting {
  public var quotaPageURL: URL? { nil }

  public func readQuota() async -> AccountQuotaReading {
    guard
      let plan = try? await launchPlan(
        for: AgentLaunchRequest(workingDirectoryPath: AccountQuotaProbe.workingDirectory()))
    else { return .unavailable(.notInstalled) }
    guard
      let result = await AccountQuotaProbe.run(
        plan, arguments: AccountQuotaProbe.antigravityArguments)
    else { return .unavailable(.failed) }
    if result.didTimeOut { return .unavailable(.failed) }
    return AccountQuotaProbe.antigravity(result.standardOutput, now: Date())
  }
}

// MARK: - What is decoded, and nothing else

/// A line of `claude -p /usage`, reduced to the limits: the text of the answer, the session and
/// the command's arguments are not declared.
struct ClaudeQuotaLine: Decodable {
  let usageReport: Report?

  enum CodingKeys: String, CodingKey {
    case usageReport = "usage_report"
  }

  struct Report: Decodable {
    let rateLimits: RateLimits?
    enum CodingKeys: String, CodingKey {
      case rateLimits = "rate_limits"
    }
  }

  struct RateLimits: Decodable {
    let limits: [Limit]?
  }

  struct Limit: Decodable {
    let kind: String?
    let percent: Double?
    let resetsAt: String?
    let scope: Scope?
    enum CodingKeys: String, CodingKey {
      case kind, percent, scope
      case resetsAt = "resets_at"
    }
  }

  struct Scope: Decodable {
    let model: Model?
  }

  struct Model: Decodable {
    let displayName: String?
    enum CodingKeys: String, CodingKey {
      case displayName = "display_name"
    }
  }
}

/// The result of `account/rateLimits/read`, reduced to its two windows and the plan: the account
/// identifier and the reset credits are not declared.
struct CodexQuotaResult: Decodable {
  let rateLimits: Limits?

  struct Limits: Decodable {
    let primary: Window?
    let secondary: Window?
    let planType: String?
  }

  struct Window: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
  }
}

/// `agy -p /usage --output-format json`, reduced to its groups and buckets: the answer's text and
/// the descriptions are not declared.
struct AntigravityQuotaAnswer: Decodable {
  let command: Command?

  struct Command: Decodable {
    let data: Payload?
  }

  struct Payload: Decodable {
    let groups: [Group]?
  }

  struct Group: Decodable {
    let name: String?
    let buckets: [Bucket]?
  }

  struct Bucket: Decodable {
    let id: String?
    let remainingFraction: Double?
    let resetTime: String?
    enum CodingKeys: String, CodingKey {
      case id
      case remainingFraction = "remaining_fraction"
      case resetTime = "reset_time"
    }
  }
}
