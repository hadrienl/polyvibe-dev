import CompanionCore
import SwiftUI

/// The time is a sibling of the content: links, files and Run buttons keep their own VoiceOver
/// targets. Its spoken label includes the whole date, without adding it to copied message text.
struct ConversationMessageTime: View {
  let date: Date?
  let calendar: Calendar
  @Environment(\.locale) private var locale
  @Environment(\.conversationPalette) private var palette

  var body: some View {
    if let date {
      Text(date, format: style(date: .omitted, time: .shortened))
        .font(.caption2)
        .foregroundStyle(palette.secondaryText)
        .accessibilityLabel(Text(date.formatted(style(date: .complete, time: .standard))))
    }
  }

  private func style(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle)
    -> Date.FormatStyle
  {
    var style = Date.FormatStyle(date: date, time: time).locale(locale)
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    return style
  }
}

struct ConversationDaySeparator: View {
  let day: Date
  let now: Date
  let calendar: Calendar
  @Environment(\.locale) private var locale
  @Environment(\.conversationPalette) private var palette

  var body: some View {
    HStack(spacing: 10) {
      line
      label.font(.caption2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
      line
    }
    .foregroundStyle(palette.secondaryText)
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private var line: some View {
    Rectangle().fill(palette.secondaryText.opacity(0.2)).frame(height: 1)
      .accessibilityHidden(true)
  }

  private var label: Text {
    switch RemoteConversationDays.label(for: day, now: now, calendar: calendar) {
    case .today: return Text("Today")
    case .yesterday: return Text("Yesterday")
    case .date:
      var style = Date.FormatStyle(date: .complete, time: .omitted).locale(locale)
      style.calendar = calendar
      style.timeZone = calendar.timeZone
      return Text(day.formatted(style))
    }
  }
}
