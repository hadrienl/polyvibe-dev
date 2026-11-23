import CryptoKit
import Foundation
import VibeApplication
import VibeDomain

/// Reads the token usage Claude Code, Codex and Antigravity write in their own transcripts.
///
/// What a line says is never read: a line is only decoded when its bytes hold one of the keys
/// below, and it is decoded into types that declare nothing but counters, identifiers, a model and
/// a date. In JSON a quote inside a string value is always escaped, so `"usage":` in the bytes can
/// only be a key — a prompt that mentions it does not match.
///
/// Claude Code writes `message.usage` on each answer, and repeats it on every line of an answer
/// that has several blocks: they are counted once, by `message.id` and `requestId`. Codex writes a
/// `token_usage_record` per response, named by `response_id`, and names the model in the
/// `turn_context` that opens a turn; a rollout written before those records has only the
/// per-turn `token_count` events, counted by their `last_token_usage` instead.
///
/// agy writes `input_tokens`, `cache_read_tokens` and `output_tokens` on each `PLANNER_RESPONSE`,
/// with its `model`, counted once by `step_index`; a `CHECKPOINT`, the call that compacts the
/// conversation, carries the same counters without a model, and counts for the last one named.
///
/// Codex counts cached input inside its input, Claude Code and agy beside it: all are reported
/// here as Claude Code does, input without the cache.
public struct AgentUsageReader: TokenUsageReading {
  let locator: AgentTranscriptLocator
  private let calendar: Calendar
  let now: @Sendable () -> Date

  public init(
    locator: AgentTranscriptLocator = AgentTranscriptLocator(),
    calendar: Calendar = .current,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.locator = locator
    self.calendar = calendar
    self.now = now
  }

  public func refresh(
    _ sessions: [WorkSession],
    from snapshot: TokenUsageSnapshot,
    isTracked: @escaping @Sendable (Date) -> Bool
  ) async -> TokenUsageSnapshot {
    var next = snapshot
    let now = now()
    for session in sessions {
      var seen = Set<String>()
      for conversation in session.conversations {
        guard
          let identifier = conversation.resumeIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines), !identifier.isEmpty
        else { continue }
        let files: [URL]
        let format: TranscriptFormat
        switch conversation.transcriptProviderID {
        case ClaudeCodeAgentProvider.id.rawValue:
          files = locator.claudeTranscripts(
            for: identifier, providerID: conversation.providerID)
          format = .claude
        case CodexAgentProvider.id.rawValue:
          files = locator.codexRollouts(
            for: identifier, providerID: conversation.providerID, since: session.createdAt,
            until: now)
          format = .codex
        case AntigravityAgentProvider.id.rawValue:
          files = locator.antigravityTranscripts(for: identifier)
          format = .antigravity
        default:
          continue
        }
        for url in files {
          let key = Self.key(for: url)
          seen.insert(key)
          let entry =
            next.files[key]
            ?? TokenUsageFile(sessionID: session.id, providerID: conversation.providerID)
          next.files[key] = read(
            url, into: entry, format: format, now: now, isTracked: isTracked)
        }
      }
      // A transcript no longer found — the CLI deleted it — keeps what it reported.
      for (key, file) in next.files
      where file.sessionID == session.id && !seen.contains(key) && !file.isMissing {
        next.files[key]?.isMissing = true
      }
    }
    return next
  }

  /// A digest of the path: a Claude Code project folder is named after the repository it ran
  /// in, and the totals have no use for that name.
  static func key(for url: URL) -> String {
    SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - One file

  func read(
    _ url: URL, into entry: TokenUsageFile, format: TranscriptFormat, now: Date,
    isTracked: (Date) -> Bool
  ) -> TokenUsageFile {
    var file = entry
    file.isMissing = false
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return file
    }
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    // A file that shrank, or another file under the same name, is read again from the start.
    if size < file.offset || (file.inode != nil && inode != nil && file.inode != inode) {
      file = TokenUsageFile(sessionID: entry.sessionID, providerID: entry.providerID)
    }
    file.inode = inode
    guard size > file.offset else { return file }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return file }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: file.offset)
    } catch {
      return file
    }
    let data = (try? handle.readToEnd()) ?? Data()
    // Only whole lines: the CLI may be in the middle of writing the last one.
    guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return file }
    let complete = data[data.startIndex...lastNewline]
    file.offset += UInt64(complete.count)
    file.lastReadAt = now
    // One parser for the whole file: a first reading goes through tens of megabytes.
    let timestamps = TimestampParser()
    for line in complete.split(separator: UInt8(ascii: "\n")) {
      switch format {
      case .claude:
        Self.readClaude(
          line: Data(line), into: &file, calendar: calendar, now: now, timestamps: timestamps,
          isTracked: isTracked)
      case .codex:
        Self.readCodex(
          line: Data(line), into: &file, calendar: calendar, now: now, timestamps: timestamps,
          isTracked: isTracked)
      case .antigravity:
        Self.readAntigravity(
          line: Data(line), into: &file, calendar: calendar, now: now, timestamps: timestamps,
          isTracked: isTracked)
      }
    }
    return file
  }

  // MARK: - Claude Code

  static let claudeMarker = Data(#""usage":"#.utf8)

  static func readClaude(
    line: Data, into file: inout TokenUsageFile, calendar: Calendar, now: Date,
    timestamps: TimestampParser, isTracked: (Date) -> Bool
  ) {
    guard line.range(of: claudeMarker) != nil,
      let decoded = try? JSONDecoder().decode(ClaudeUsageLine.self, from: line),
      decoded.type == "assistant", let message = decoded.message, let usage = message.usage
    else { return }
    let model = message.model ?? "unknown"
    // What the CLI writes itself — an error shown in the conversation — has no model behind it.
    guard model != "<synthetic>" else { return }
    let date = decoded.timestamp.flatMap(timestamps.date) ?? now
    guard isTracked(date) else { return }
    if message.id != nil || decoded.requestId != nil {
      let key = "\(message.id ?? "")|\(decoded.requestId ?? "")"
      guard file.isFirstSighting(of: key) else { return }
    }
    let tokens = TokenCounts(
      input: usage.input ?? 0, cacheRead: usage.cacheRead ?? 0,
      cacheWrite: usage.cacheWrite ?? 0, output: usage.output ?? 0)
    file.add(tokens, model: model, day: LocalDay(date, calendar: calendar), fallback: false)
  }

  // MARK: - Codex

  static let codexMarkers = [
    Data(#""token_usage_record""#.utf8), Data(#""turn_context""#.utf8),
    Data(#""token_count""#.utf8),
  ]

  static func readCodex(
    line: Data, into file: inout TokenUsageFile, calendar: Calendar, now: Date,
    timestamps: TimestampParser, isTracked: (Date) -> Bool
  ) {
    guard codexMarkers.contains(where: { line.range(of: $0) != nil }),
      let decoded = try? JSONDecoder().decode(CodexUsageLine.self, from: line)
    else { return }
    let date = decoded.timestamp.flatMap(timestamps.date) ?? now
    switch decoded.type {
    case "turn_context":
      if let model = decoded.payload?.model, !model.isEmpty { file.currentModel = model }
    case "token_usage_record":
      guard let usage = decoded.payload?.usage, isTracked(date) else { return }
      if let id = decoded.payload?.responseID {
        guard file.isFirstSighting(of: id) else { return }
      }
      file.add(
        usage.counts, model: file.currentModel ?? "unknown",
        day: LocalDay(date, calendar: calendar), fallback: false)
    case "event_msg":
      guard decoded.payload?.type == "token_count",
        let usage = decoded.payload?.info?.lastTokenUsage
      else { return }
      // An older Codex repeats the event, total and all, when only its rate limits changed.
      if let total = decoded.payload?.info?.totalTokenUsage?.counts {
        guard total != file.lastFallbackTotal else { return }
        file.lastFallbackTotal = total
      }
      guard isTracked(date) else { return }
      file.add(
        usage.counts, model: file.currentModel ?? "unknown",
        day: LocalDay(date, calendar: calendar), fallback: true)
    default:
      return
    }
  }

  // MARK: - Antigravity

  static let antigravityMarker = Data(#""input_tokens":"#.utf8)

  static func readAntigravity(
    line: Data, into file: inout TokenUsageFile, calendar: Calendar, now: Date,
    timestamps: TimestampParser, isTracked: (Date) -> Bool
  ) {
    guard line.range(of: antigravityMarker) != nil,
      let decoded = try? JSONDecoder().decode(AntigravityUsageLine.self, from: line),
      decoded.type == "PLANNER_RESPONSE" || decoded.type == "CHECKPOINT"
    else { return }
    if let model = decoded.model, !model.isEmpty { file.currentModel = model }
    let date = decoded.createdAt.flatMap(timestamps.date) ?? now
    guard isTracked(date) else { return }
    if let step = decoded.stepIndex {
      guard file.isFirstSighting(of: "step:\(step)") else { return }
    }
    let tokens = TokenCounts(
      input: decoded.input ?? 0, cacheRead: decoded.cacheRead ?? 0, cacheWrite: 0,
      output: decoded.output ?? 0)
    file.add(
      tokens, model: file.currentModel ?? "unknown", day: LocalDay(date, calendar: calendar),
      fallback: false)
  }
}

/// The transcript a file is, by the CLI that wrote it.
enum TranscriptFormat: Sendable {
  case claude, codex, antigravity
}

/// The dates of a transcript, with and without fractional seconds.
final class TimestampParser {
  private let fractional: ISO8601DateFormatter
  private let whole: ISO8601DateFormatter

  init() {
    fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
  }

  func date(_ value: String) -> Date? {
    fractional.date(from: value) ?? whole.date(from: value)
  }
}

// MARK: - What is decoded, and nothing else

/// A Claude Code transcript line, reduced to what usage needs. No content field is declared, so
/// none can be decoded, kept or logged.
struct ClaudeUsageLine: Decodable {
  let type: String?
  let timestamp: String?
  let requestId: String?
  let message: Message?

  struct Message: Decodable {
    let id: String?
    let model: String?
    let usage: Usage?
  }

  struct Usage: Decodable {
    let input: Int?
    let cacheWrite: Int?
    let cacheRead: Int?
    let output: Int?

    enum CodingKeys: String, CodingKey {
      case input = "input_tokens"
      case cacheWrite = "cache_creation_input_tokens"
      case cacheRead = "cache_read_input_tokens"
      case output = "output_tokens"
    }
  }
}

/// A Codex rollout line, reduced the same way.
struct CodexUsageLine: Decodable {
  let type: String?
  let timestamp: String?
  let payload: Payload?

  struct Payload: Decodable {
    let type: String?
    let model: String?
    let responseID: String?
    let usage: Usage?
    let info: Info?

    enum CodingKeys: String, CodingKey {
      case type, model, usage, info
      case responseID = "response_id"
    }
  }

  struct Info: Decodable {
    let lastTokenUsage: Usage?
    let totalTokenUsage: Usage?
    /// The size of the window, found beside the tokens from Codex 0.131 to 0.164 at least (#407).
    let modelContextWindow: Int?

    enum CodingKeys: String, CodingKey {
      case lastTokenUsage = "last_token_usage"
      case totalTokenUsage = "total_token_usage"
      case modelContextWindow = "model_context_window"
    }
  }

  struct Usage: Decodable {
    let input: Int?
    let cachedInput: Int?
    let cacheWrite: Int?
    let output: Int?
    let reasoning: Int?
    let total: Int?

    enum CodingKeys: String, CodingKey {
      case input = "input_tokens"
      case cachedInput = "cached_input_tokens"
      case cacheWrite = "cache_write_input_tokens"
      case output = "output_tokens"
      case reasoning = "reasoning_output_tokens"
      case total = "total_tokens"
    }

    var counts: TokenCounts {
      let cached = cachedInput ?? 0
      return TokenCounts(
        input: max((input ?? 0) - cached, 0), cacheRead: cached, cacheWrite: cacheWrite ?? 0,
        output: output ?? 0, reasoning: reasoning ?? 0)
    }
  }
}

/// An agy transcript step, reduced to what usage and context need: its content, its thinking and
/// its tool calls are not declared, so none can be decoded, kept or logged.
struct AntigravityUsageLine: Decodable {
  let type: String?
  let stepIndex: Int?
  let createdAt: String?
  let model: String?
  let input: Int?
  let cacheRead: Int?
  let output: Int?

  enum CodingKeys: String, CodingKey {
    case type, model
    case stepIndex = "step_index"
    case createdAt = "created_at"
    case input = "input_tokens"
    case cacheRead = "cache_read_tokens"
    case output = "output_tokens"
  }
}
