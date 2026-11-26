import CompanionCore
import Foundation
import Testing

@Suite("The days and times of the phone's conversation (#632)")
struct RemoteConversationDaysTests {
  private var paris: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
    paris.date(
      from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  private func message(_ id: String, _ date: Date?, agent: Bool = false) -> RemoteEntry {
    RemoteEntry(id: id, kind: agent ? .agent(id) : .user(id, attachments: []), date: date)
  }

  @Test("The first message opens its day; the next same-day message does not")
  func days() {
    let entries = [
      message("a", date(24, 23, 55)), message("b", date(24, 23, 59), agent: true),
      message("c", date(25, 0, 1)), message("d", date(25, 9), agent: true),
      message("e", date(26, 9)),
    ]
    let days = RemoteConversationDays(entries: entries, calendar: paris)
    #expect(
      entries.compactMap { days.day(opening: $0.id) } == [
        paris.startOfDay(for: date(24, 0)), paris.startOfDay(for: date(25, 0)),
        paris.startOfDay(for: date(26, 0)),
      ])
    #expect(days.day(opening: "b") == nil)
    #expect(days.day(opening: "d") == nil)
  }

  @Test("Unknown dates neither invent an hour nor split a known day")
  func missingDates() {
    let entries = [
      message("old", nil), message("a", date(25, 9)),
      message("unknown", nil, agent: true), message("b", date(25, 10)),
    ]
    let days = RemoteConversationDays(entries: entries, calendar: paris)
    #expect(entries[0].messageDate == nil)
    #expect(days.day(opening: "old") == nil)
    #expect(days.day(opening: "unknown") == nil)
    #expect(days.day(opening: "b") == nil)
    #expect(days.day(opening: "a") != nil)
  }

  @Test("Tools and notices after midnight wait for the next real message to open the day")
  func tools() {
    let tool = RemoteEntry(
      id: "tool",
      kind: .tool(
        symbol: "terminal", title: "Test", detail: nil, running: false, failed: false),
      date: date(26, 0, 1))
    let notice = RemoteEntry(id: "notice", kind: .notice(.interrupted), date: date(26, 0, 2))
    let entries = [
      message("a", date(25, 23, 59)), tool, notice,
      message("b", date(26, 0, 3), agent: true),
    ]
    let days = RemoteConversationDays(entries: entries, calendar: paris)
    #expect(tool.messageDate == nil)
    #expect(notice.messageDate == nil)
    #expect(days.day(opening: "tool") == nil)
    #expect(days.day(opening: "notice") == nil)
    #expect(days.day(opening: "b") == paris.startOfDay(for: date(26, 0)))
  }

  @Test("Changing the phone's time zone recuts the same entries at local midnight")
  func timeZone() {
    let entries = [message("a", date(25, 23)), message("b", date(26, 1), agent: true)]
    var newYork = paris
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    #expect(RemoteConversationDays(entries: entries, calendar: paris).day(opening: "b") != nil)
    #expect(RemoteConversationDays(entries: entries, calendar: newYork).day(opening: "b") == nil)
  }

  @Test("Midnight changes Today into Yesterday; a twenty-three-hour day is still yesterday")
  func labels() {
    let day = date(26, 0)
    #expect(
      RemoteConversationDays.label(for: day, now: date(26, 23, 59), calendar: paris) == .today)
    #expect(RemoteConversationDays.label(for: day, now: date(27, 0), calendar: paris) == .yesterday)
    #expect(RemoteConversationDays.label(for: day, now: date(28, 0), calendar: paris) == .date)
    #expect(
      RemoteConversationDays.label(
        for: date(29, 0, month: 3), now: date(30, 0, 10, month: 3), calendar: paris) == .yesterday)
  }

  @Test("A truncated slice opens its first day and keeps out-of-order messages in place")
  func displayedSlice() {
    let entries = [
      message("a", date(25, 9)), message("b", date(25, 10), agent: true),
      message("c", date(24, 23)), message("d", date(25, 11), agent: true),
    ]
    let days = RemoteConversationDays(entries: Array(entries.dropFirst()), calendar: paris)
    #expect(days.day(opening: "b") != nil)
    #expect(days.day(opening: "c") != nil)
    #expect(days.day(opening: "d") != nil)
  }
}
