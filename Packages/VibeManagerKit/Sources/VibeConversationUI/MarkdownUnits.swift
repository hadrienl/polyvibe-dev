import AppKit
import VibeApplication

/// A semantic paragraph, code line or whole table, in the continuous text's coordinates.
struct MarkdownUnit: Equatable {
  var index: Int
  var segment: Int
  var range: NSRange
  var text: String
}

enum MarkdownUnits {
  @MainActor
  static func units(of blocks: [MarkdownBlock]) -> [MarkdownUnit] {
    units(in: MarkdownBlocksView.contents(blocks))
  }

  @MainActor
  static func units(in contents: [SegmentView.Content]) -> [MarkdownUnit] {
    var result: [MarkdownUnit] = []
    for (segment, content) in contents.enumerated() {
      let text = SegmentView.text(of: content, theme: .systemLight, size: 14, spacing: 8)
      for range in ranges(in: text, kind: content.kind) {
        result.append(
          MarkdownUnit(
            index: result.count, segment: segment, range: range,
            text: (text.string as NSString).substring(with: range)))
      }
    }
    return result
  }

  static func ranges(in text: NSAttributedString, kind: SegmentKind) -> [NSRange] {
    let whole = NSRange(location: 0, length: text.length)
    if case .table = kind { return [whole] }
    var ranges: [NSRange] = []
    if case .prose = kind {
      text.enumerateAttribute(.bookmarkParagraph, in: whole) { value, range, _ in
        if value != nil { ranges.append(range) }
      }
      if !ranges.isEmpty { return ranges }
    }
    // Plain prompts keep paragraphs together across explicit line breaks; blank lines separate them.
    if case .prose = kind {
      let string = text.string as NSString
      var start: Int?
      var end = 0
      var cursor = 0
      while cursor < string.length {
        let line = string.lineRange(for: NSRange(location: cursor, length: 0))
        let content = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
          if let first = start { ranges.append(NSRange(location: first, length: end - first)) }
          start = nil
        } else {
          if start == nil { start = cursor }
          end = NSMaxRange(line)
          if string.substring(with: line).hasSuffix("\n") { end -= 1 }
        }
        cursor = NSMaxRange(line)
      }
      if let start { ranges.append(NSRange(location: start, length: end - start)) }
      return ranges.isEmpty ? [whole] : ranges
    }
    // Code uses logical lines, never the visual lines introduced by wrapping.
    let string = text.string as NSString
    var start = 0
    while start < string.length {
      let range = string.lineRange(for: NSRange(location: start, length: 0))
      let end = NSMaxRange(range)
      let length = range.length - (string.substring(with: range).hasSuffix("\n") ? 1 : 0)
      ranges.append(NSRange(location: start, length: length))
      start = end
    }
    if case .code = kind, text.string.hasSuffix("\n") {
      ranges.append(NSRange(location: text.length, length: 0))
    }
    return ranges.isEmpty ? [whole] : ranges
  }
}

extension ConversationBlock {
  @MainActor var bookmarkContents: [SegmentView.Content] {
    guard case .entry(let entry) = self else { return [] }
    if case .userPrompt(let text, let attachments) = entry.content {
      if let relayed = RelayedMessage(text, attachments: attachments) {
        return MarkdownBlocksView.contents(MarkdownCache.shared.blocks(for: relayed.body))
      }
      return [
        .plain(
          ReplyLinks.shown(text, attachments: attachments).message,
          color: ConversationTheme.systemLight.text)
      ]
    }
    return bookmarkMarkdown.map {
      MarkdownBlocksView.contents(MarkdownCache.shared.blocks(for: $0))
    } ?? []
  }

  var bookmarkMarkdown: String? {
    guard case .entry(let entry) = self else { return nil }
    switch entry.content {
    case .userPrompt(let text, _), .agentText(let text): return text
    case .reasoning(let text): return text
    case .tool(let call) where call.kind == .plan: return call.parameter(.plan)
    default: return nil
    }
  }
}
