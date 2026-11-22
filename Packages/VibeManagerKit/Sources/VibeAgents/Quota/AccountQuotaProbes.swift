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
      // A subscription whose session is spent can leave the structured limits out and say them
      // only in its text; an account on an API key says them nowhere: it has no quota.
      guard let limits = report.rateLimits?.limits, !limits.isEmpty else {
        let windows = claudeTextWindows(output, now: now)
        guard !windows.isEmpty else { return .unavailable(.notReportedByAgent) }
        return .measured(AccountQuota(windows: windows, measuredAt: now))
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

  /// The windows `/usage` writes as text — `Current session: 100% used · resets Nov 22 at
  /// 11:09pm (Europe/Paris)`, `Current week (all models): 41% used · resets …` — when its report
  /// leaves them out. Only these lines are read: the rest of the text, which describes the
  /// sessions, is skipped.
  static func claudeTextWindows(_ output: Data, now: Date) -> [QuotaWindow] {
    var windows: [QuotaWindow] = []
    for line in output.split(separator: 0x0A) where line.contains(0x22) {
      guard let decoded = try? JSONDecoder().decode(ClaudeTextLine.self, from: Data(line)),
        decoded.type == "assistant"
      else { continue }
      for block in decoded.message?.content ?? [] {
        for text in (block.text ?? "").split(separator: "\n") {
          if let window = claudeTextWindow(String(text), now: now) { windows.append(window) }
        }
      }
    }
    return windows
  }

  static func claudeTextWindow(_ line: String, now: Date) -> QuotaWindow? {
    let pattern =
      #"^Current (session|week \((.{1,64})\)): (\d{1,3}(?:\.\d+)?)% used(?: · resets (.{1,80}))?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: line, range: NSRange(line.startIndex..., in: line)),
      let percentRange = Range(match.range(at: 3), in: line),
      let percent = Double(line[percentRange])
    else { return nil }
    let model = Range(match.range(at: 2), in: line).map { String(line[$0]) }
    let resets = Range(match.range(at: 4), in: line).flatMap {
      textDate(String(line[$0]), now: now)
    }
    let used = min(percent, 100) / 100
    switch model {
    case nil:
      return QuotaWindow(id: "session", kind: .session, usedFraction: used, resetsAt: resets)
    case "all models":
      return QuotaWindow(id: "weekly_all", kind: .weekly, usedFraction: used, resetsAt: resets)
    case let name?:
      return QuotaWindow(
        id: "weekly_scoped:" + name, kind: .weeklyModel(name), usedFraction: used,
        resetsAt: resets)
    }
  }

  /// `Nov 22 at 11:09pm (Europe/Paris)`, or `11:09pm (Europe/Paris)` for today: the next such
  /// moment from `now`, in the zone named.
  static func textDate(_ text: String, now: Date) -> Date? {
    var text = text.trimmingCharacters(in: .whitespaces)
    var zone = TimeZone.current
    if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
      let name = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
      if let named = TimeZone(identifier: name) { zone = named }
      text = text[..<open].trimmingCharacters(in: .whitespaces)
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.defaultDate = now
    for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d", "h:mma", "ha"] {
      formatter.dateFormat = format
      guard let parsed = formatter.date(from: text) else { continue }
      let hasDay = format.hasPrefix("MMM")
      var date = parsed
      if hasDay {
        // Without a year: this year's, or next year's once this year's is long past.
        var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
        parts.year = calendar.component(.year, from: now)
        date = calendar.date(from: parts) ?? parsed
        if date < now.addingTimeInterval(-86_400),
          let next = calendar.date(byAdding: .year, value: 1, to: date)
        {
          date = next
        }
      } else {
        let time = calendar.dateComponents([.hour, .minute], from: parsed)
        date =
          calendar.date(
            bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: now) ?? parsed
        if date < now, let next = calendar.date(byAdding: .day, value: 1, to: date) { date = next }
      }
      return date
    }
    return nil
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

/// A line of `claude -p /usage` reduced to its type and the text of its answer: what the limits
/// are said in when the report leaves them out. Only the lines that name a window are read.
struct ClaudeTextLine: Decodable {
  let type: String?
  let message: Message?

  struct Message: Decodable {
    let content: [Block]?
  }

  struct Block: Decodable {
    let text: String?
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
