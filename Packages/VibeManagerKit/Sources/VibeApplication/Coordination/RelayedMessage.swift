import Foundation

/// A message a session was sent by Vibe Manager or by its coordinator rather than typed by the
/// user, read back from its transcript so that the conversation shows who wrote it.
///
/// Read from the text alone: the mark it opens with is all a transcript keeps of its author.
public struct RelayedMessage: Equatable, Sendable {
  public enum Sender: Equatable, Sendable {
    /// Vibe Manager, telling a coordinator what its children did.
    case application
    /// A coordinator, writing to one of its children; its name.
    case coordinator(String)
  }

  public let sender: Sender
  /// What it says, in Markdown, without its mark. A child is named in bold, without the
  /// identifier the coordinator was given.
  public let body: String
  /// The children it names, in order and once each: what it is about, folded.
  public let children: [String]

  /// `nil` for what the user wrote — the coordination prefaces in front of their words included.
  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard CoordinatorInstructions.userText(of: trimmed) == nil else { return nil }
    if trimmed.hasPrefix(CoordinationPolicy.coordinatorMark) {
      let rest = trimmed.dropFirst(CoordinationPolicy.coordinatorMark.count)
      guard let close = rest.range(of: "”]") else { return nil }
      sender = .coordinator(String(rest[..<close.lowerBound]))
      children = []
      body = rest[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      return
    }
    guard trimmed.hasPrefix(CoordinatorInstructions.applicationMark) else { return nil }
    let rest = trimmed.dropFirst(CoordinatorInstructions.applicationMark.count)
      .trimmingCharacters(in: .whitespaces)
    sender = .application
    var lines = rest.split(separator: "\n", omittingEmptySubsequences: false)
    // « 2 events: », over the news to a coordinator: the list says as much.
    if let first = lines.first, first.wholeMatch(of: /\d+ events?:/) != nil {
      lines.removeFirst()
    }
    body = lines.map { Self.namingChildren(in: String($0)) }.joined(separator: "\n")
    var named: [String] = []
    for match in rest.matches(of: Self.child()) where !named.contains(String(match.1)) {
      named.append(String(match.1))
    }
    children = named
  }

  /// « “name” (identifier) », as Vibe Manager names a child to its coordinator.
  private static func child() -> Regex<(Substring, Substring)> {
    /“(.+?)” \([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\)/
  }

  /// Each « “name” (identifier) » of a line as the name, in bold.
  static func namingChildren(in line: String) -> String {
    line.replacing(child()) { "**" + escaped(String($0.1)) + "**" }
  }

  /// A name as Markdown shows it, whatever punctuation it holds.
  private static func escaped(_ name: String) -> String {
    var result = ""
    for character in name {
      if "\\`*_[]<>#|~!".contains(character) { result.append("\\") }
      result.append(character)
    }
    return result
  }
}
