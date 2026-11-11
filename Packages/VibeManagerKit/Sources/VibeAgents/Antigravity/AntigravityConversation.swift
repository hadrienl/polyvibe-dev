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
  public init() {}

  public func consume(_ record: TranscriptRecord) {
    let object = record.object
    guard let step = object["step_index"] as? Int, step >= 0,
      let type = object["type"] as? String
    else { return }
    let prefix = "agy:\(step):"
    // The CLI may publish another snapshot of a step while generating it.
    let insertion = entries.firstIndex { $0.id.hasPrefix(prefix) } ?? entries.endIndex
    entries.removeAll { $0.id.hasPrefix(prefix) }
    var additions: [ConversationEntry] = []
    let date = (object["created_at"] as? String).flatMap(TranscriptDates.parse)
    func append(_ suffix: String, _ content: ConversationEntry.Content) {
      additions.append(ConversationEntry(id: prefix + suffix, date: date, content: content))
    }
    let rawText = object["content"] as? String ?? ""
    let text = ToolOutput.bounded(rawText).text
    switch type {
    case "USER_INPUT":
      guard object["source"] as? String == "USER_EXPLICIT" else { return }
      // The export adds time/settings metadata around the actual request. Do not show those
      // implementation details as if the user had typed them. Use the last close marker so a
      // literal </USER_REQUEST> inside the prompt is preserved.
      let prompt: String
      if rawText.hasPrefix("<USER_REQUEST>\n"),
        let end = rawText.range(of: "\n</USER_REQUEST>", options: .backwards)
      {
        prompt = String(rawText[rawText.index(rawText.startIndex, offsetBy: 15)..<end.lowerBound])
      } else {
        prompt = text
      }
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
    entries.insert(contentsOf: additions, at: min(insertion, entries.count))
  }
}
