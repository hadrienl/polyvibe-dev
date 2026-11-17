import Foundation
import VibeApplication
import VibeDomain

extension AntigravityAgentProvider: AgentConversationReporting {
  public func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession, hint: AgentActivityEvent?
  ) -> [URL] {
    guard let identifier = conversation.resumeIdentifier,
      let file = Self.transcript(identifier: identifier, home: home),
      FileManager.default.fileExists(atPath: file.path)
    else { return [] }
    return [file]
  }

  public func conversationDecoder(for file: URL) -> any ConversationDecoding {
    AntigravityConversationDecoder()
  }

  public var promptFormat: AgentPromptFormat { AgentPromptFormat() }
}

/// 1.5.5's exported transcript is a sequence of numbered steps, not Claude messages. Tool
/// results have no call identifier: show them as information instead of attributing them to an
/// arbitrary parallel call or inventing a success state. Unknown step types are left alone.
public final class AntigravityConversationDecoder: ConversationDecoding {
  public private(set) var entries: [ConversationEntry] = []
  /// The step the last entries belong to, and how many they are: the CLI publishes the snapshots
  /// of a step one after the other, so replacing one is replacing the tail.
  private var tailStep: Int?
  private var tailCount = 0
  private var steps: Set<Int> = []

  public init() {}

  public func consume(_ record: TranscriptRecord) {
    let object = record.object
    guard let step = object["step_index"] as? Int, step >= 0,
      let type = object["type"] as? String
    else { return }
    let prefix = "agy:\(step):"
    // The CLI may publish another snapshot of a step while generating it. The latest one replaces
    // the step's entries where they were: at the end, almost always, in constant time; anywhere
    // else, by a search, for a step published again later.
    let insertion: Int
    if tailStep == step {
      entries.removeLast(tailCount)
      insertion = entries.endIndex
    } else if steps.contains(step) {
      insertion = entries.firstIndex { $0.id.hasPrefix(prefix) } ?? entries.endIndex
      entries.removeAll { $0.id.hasPrefix(prefix) }
    } else {
      insertion = entries.endIndex
    }
    steps.insert(step)
    var additions: [ConversationEntry] = []
    let date = (object["created_at"] as? String).flatMap(TranscriptDates.parse)
    func append(_ suffix: String, _ content: ConversationEntry.Content) {
      additions.append(ConversationEntry(id: prefix + suffix, date: date, content: content))
    }
    let rawText = object["content"] as? String ?? ""
    let text = ToolOutput.bounded(rawText).text
    switch type {
    case "USER_INPUT":
      guard object["source"] as? String == "USER_EXPLICIT" else { break }
      let prompt = Self.request(in: rawText) ?? text
      if !prompt.isEmpty {
        append("user", .userPrompt(ToolOutput.bounded(prompt).text, attachments: []))
      }
    case "PLANNER_RESPONSE":
      if let thinking = object["thinking"] as? String, !thinking.isEmpty {
        append("thinking", .reasoning(ToolOutput.bounded(thinking).text))
      }
      if !text.isEmpty { append("text", .agentText(text)) }
      for (index, call) in ((object["tool_calls"] as? [[String: Any]]) ?? []).prefix(100)
        .enumerated()
      {
        guard let name = call["name"] as? String else { continue }
        let args = call["args"] as? [String: Any] ?? [:]
        let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        let description = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        append(
          "tool:\(index)", .notice(.information(ToolOutput.bounded(name + "\n" + description).text))
        )
      }
    case "GENERIC":
      if !text.isEmpty { append("information", .notice(.information(text))) }
    default: break
    }
    let at = min(insertion, entries.count)
    entries.insert(contentsOf: additions, at: at)
    if at + additions.count == entries.count {
      tailStep = step
      tailCount = additions.count
    } else {
      tailStep = nil
      tailCount = 0
    }
  }

  /// What the user typed, without the time and settings metadata the export adds around it; `nil`
  /// when the text is not wrapped. The last close marker ends it, so a literal `</USER_REQUEST>`
  /// inside the prompt is kept. An empty request — attachments alone — is an empty prompt.
  static func request(in text: String) -> String? {
    let open = "<USER_REQUEST>\n"
    guard text.hasPrefix(open) else { return nil }
    let body = text.dropFirst(open.count)
    if let end = body.range(of: "\n</USER_REQUEST>", options: .backwards) {
      return String(body[..<end.lowerBound])
    }
    return body.hasPrefix("</USER_REQUEST>") ? "" : nil
  }
}
