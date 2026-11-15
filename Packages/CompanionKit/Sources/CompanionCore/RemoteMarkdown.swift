import Foundation

/// An agent's answer as the phone draws it (#548): its prose, in-line Markdown, and its fenced code
/// blocks apart, each with a Copy button — and a Run button for a command the agent wrote for its
/// shell mode.
public enum RemoteMarkdown {
  public enum Segment: Hashable, Sendable {
    case prose(String)
    case code(language: String?, code: String)
  }

  /// The text in reading order. A block still open — the answer being written — runs to the end.
  public static func segments(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    var prose: [Substring] = []
    var code: [Substring] = []
    var fence: (marker: Character, length: Int, language: String?)?

    func flushProse() {
      let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
      if !joined.isEmpty { segments.append(.prose(joined)) }
      prose = []
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if let open = fence {
        if let close = Self.fence(line), close.marker == open.marker, close.length >= open.length,
          close.info.isEmpty
        {
          segments.append(.code(language: open.language, code: code.joined(separator: "\n")))
          code = []
          fence = nil
        } else {
          code.append(line)
        }
      } else if let open = Self.fence(line), open.marker == "~" || !open.info.contains("`") {
        flushProse()
        let language = open.info.split(separator: " ").first.map(String.init)
        fence = (open.marker, open.length, language)
      } else {
        prose.append(line)
      }
    }
    if let open = fence {
      segments.append(.code(language: open.language, code: code.joined(separator: "\n")))
    }
    flushProse()
    return segments
  }

  /// The prompt a code block sends when run, or nil when it is not a single command opening on
  /// `!` (`! gcloud auth login`): as the Mac's composer reads it, a command for the shell mode.
  public static func shellPrompt(in code: String) -> String? {
    let line = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("!"), !line.contains(where: \.isNewline),
      !line.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return line
  }

  /// A fence opening or closing a block: three backticks or tildes or more, indented by three
  /// spaces at most, then the block's info string.
  private static func fence(_ line: Substring) -> (marker: Character, length: Int, info: String)? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
    let length = rest.prefix { $0 == marker }.count
    guard length >= 3 else { return nil }
    return (marker, length, rest.dropFirst(length).trimmingCharacters(in: .whitespaces))
  }
}
