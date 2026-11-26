import Foundation

extension RemoteEntry {
  /// Only prompts and answers show a time and open a day, as on the Mac (#632).
  public var messageDate: Date? {
    switch kind {
    case .user, .agent: date
    case .tool, .notice: nil
    }
  }
}

/// The first dated message of each day in the displayed slice, without sorting the conversation.
/// Undated messages, tools and notices do not interrupt the current day (#632).
public struct RemoteConversationDays: Equatable, Sendable {
  public enum Label: Equatable, Sendable {
    case today, yesterday, date
  }

  private var openings: [String: Date] = [:]

  public init(entries: [RemoteEntry] = [], calendar: Calendar = .autoupdatingCurrent) {
    var previous: Date?
    for entry in entries {
      guard let date = entry.messageDate else { continue }
      let day = calendar.startOfDay(for: date)
      guard day != previous else { continue }
      openings[entry.id] = day
      previous = day
    }
  }

  public func day(opening id: String) -> Date? { openings[id] }

  public static func label(for day: Date, now: Date, calendar: Calendar) -> Label {
    if calendar.isDate(day, inSameDayAs: now) { return .today }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(day, inSameDayAs: yesterday)
    {
      return .yesterday
    }
    return .date
  }
}
