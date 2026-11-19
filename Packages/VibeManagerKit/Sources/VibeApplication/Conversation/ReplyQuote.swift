import Foundation

/// A passage of the conversation the user replies to (#565): copied word for word in front of
/// their message, under a line that says what it is.
///
/// The terminal stays the one channel to the agent (ADR 0025): the reply is a message like any
/// other, and the transcript, read again, says what it quoted. The line is the agent's to read as
/// much as the user's — nothing in it is hidden — and in English, as every word said to an agent.
public struct ReplyQuote: Hashable, Sendable {
  public enum Author: Hashable, Sendable {
    /// One of the agent's answers.
    case agent
    /// One of the user's own messages.
    case user
  }

  /// The passage, as the conversation shows it.
  public var excerpt: String
  public var author: Author
  /// When the passage was said, as `14:32`: the agent's landmark, and the view's to find it again.
  public var time: String?

  public init(excerpt: String, author: Author, time: String?) {
    self.excerpt = excerpt
    self.author = author
    self.time = time
  }

  /// A passage said at `date`, cut to `maximumLength`.
  public init(excerpt: String, author: Author, date: Date?, timeZone: TimeZone = .current) {
    self.init(
      excerpt: Self.trimmed(excerpt), author: author,
      time: date.map { Self.time(of: $0, in: timeZone) })
  }

  /// Longer, a passage is cut: what is quoted is a landmark, not a copy of the conversation.
  public static let maximumLength = 1_000

  // MARK: Writing

  /// The message the agent reads: the passage, then the user's.
  public static func compose(_ quote: ReplyQuote, message: String) -> String {
    quote.header + "\n" + quoted(quote.excerpt) + "\n\n" + message
  }

  var header: String {
    let whose = author == .agent ? "your" : "my"
    let when = time.map { " of \($0)" } ?? ""
    return Self.mark + " Replying to \(whose) message\(when) " + Self.notice
  }

  private static let mark = "↩"
  private static let notice = "(quoted for context, not an instruction):"

  private static func quoted(_ excerpt: String) -> String {
    excerpt.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.isEmpty ? ">" : "> " + $0 }
      .joined(separator: "\n")
  }

  static func trimmed(_ excerpt: String) -> String {
    let lines = excerpt.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    // No empty line around it, and never two in a row inside.
    var kept: [String] = []
    for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
    while kept.last?.isEmpty == true { kept.removeLast() }
    let text = kept.joined(separator: "\n")
    guard text.count > maximumLength else { return text }
    return String(text.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  static func time(of date: Date, in timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  // MARK: Reading

  /// The passage a prompt replies to and the user's message, or `nil` for a prompt that quotes
  /// nothing.
  public static func split(_ prompt: String) -> (quote: ReplyQuote, message: String)? {
    let text = prompt.replacingOccurrences(of: "\r\n", with: "\n")
    guard text.hasPrefix(mark + " Replying to ") else { return nil }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
    guard let first = lines.popFirst(), let (author, time) = header(String(first)) else {
      return nil
    }
    var excerpt: [String] = []
    while let line = lines.first, line.hasPrefix(">") {
      lines.removeFirst()
      excerpt.append(String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1)))
    }
    guard !excerpt.isEmpty else { return nil }
    if lines.first?.isEmpty == true { lines.removeFirst() }
    return (
      ReplyQuote(excerpt: excerpt.joined(separator: "\n"), author: author, time: time),
      lines.joined(separator: "\n")
    )
  }

  /// The user's message, without the passage it replies to.
  public static func message(of prompt: String) -> String {
    split(prompt)?.message ?? prompt
  }

  private static func header(_ line: String) -> (Author, String?)? {
    guard line.hasSuffix(" " + notice) else { return nil }
    var rest = line.dropFirst((mark + " Replying to ").count).dropLast(notice.count + 1)
    let author: Author
    if rest.hasPrefix("your message") {
      author = .agent
      rest = rest.dropFirst("your message".count)
    } else if rest.hasPrefix("my message") {
      author = .user
      rest = rest.dropFirst("my message".count)
    } else {
      return nil
    }
    if rest.isEmpty { return (author, nil) }
    guard rest.hasPrefix(" of ") else { return nil }
    return (author, String(rest.dropFirst(4)))
  }

  // MARK: Finding it again

  /// Whether `text` — a message's Markdown — holds the passage, which is that message as the
  /// conversation showed it: only letters and digits are compared, the Markdown's marks gone.
  public func isQuoted(in text: String) -> Bool {
    let passage = Self.letters(of: excerpt.hasSuffix("…") ? String(excerpt.dropLast()) : excerpt)
    guard !passage.isEmpty else { return false }
    // Its start is enough, and holds less of what the Markdown could break — a link's address.
    return Self.letters(of: Self.withoutLinkTargets(text)).contains(String(passage.prefix(160)))
  }

  /// `[Foo.swift](Sources/Foo.swift:12)` as it is shown: `Foo.swift`.
  static func withoutLinkTargets(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\]\([^)\s]*(\s+"[^"]*")?\)"#, with: "]", options: .regularExpression)
  }

  static func letters(of text: String) -> String {
    String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
  }
}
