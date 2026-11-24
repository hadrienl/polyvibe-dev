import SwiftUI
import VibeApplication

/// Above the composer's field: the passage the next message replies to, and ✕ to take it back
/// (#565).
struct ReplyQuoteBar: View {
  let quote: ReplyQuote
  let agentName: String
  let remove: () -> Void
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "arrowshape.turn.up.left")
        .font(.system(size: size * 0.8, weight: .semibold))
        .foregroundStyle(theme.accent.color)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        ReplyTitle(quote: quote, agentName: agentName, replying: true)
          .font(theme.interfaceFont(size: size * 0.75, weight: .semibold))
          .foregroundStyle(theme.accent.color)
        Text(verbatim: ReplyHeader.oneLine(quote.excerpt))
          .font(theme.interfaceFont(size: size * 0.82))
          .foregroundStyle(theme.secondaryText.color)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 0)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: size * 0.7, weight: .semibold))
          .foregroundStyle(theme.secondaryText.color)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Remove the Quote", bundle: .module))
      .instantTooltip(Text("Remove the Quote", bundle: .module))
    }
    .padding(.leading, 10)
    .padding(.trailing, 4)
    .padding(.vertical, 6)
    .background(
      theme.accent.color.opacity(0.08),
      in: RoundedRectangle(cornerRadius: theme.layout.innerRadius))
    .accessibilityElement(children: .contain)
  }
}

/// « Replying to Claude Code · 14:32 » over the composer, « In reply to… » on a reply.
struct ReplyTitle: View {
  let quote: ReplyQuote
  let agentName: String
  /// Over the composer, the reply is still being written.
  var replying = false

  var body: some View {
    let whom: Text =
      switch (quote.author, replying) {
      case (.agent, true): Text("Replying to \(agentName)", bundle: .module)
      case (.user, true): Text("Replying to your message", bundle: .module)
      case (.agent, false): Text("In reply to \(agentName)", bundle: .module)
      case (.user, false): Text("In reply to your message", bundle: .module)
      }
    if let time = quote.time {
      whom + Text(verbatim: " · " + time)
    } else {
      whom
    }
  }
}

/// On top of a reply's bubble: the passage it quotes, which a click brings into view (#565).
struct ReplyHeader: View {
  let quote: ReplyQuote
  let agentName: String
  let foreground: ThemeColor
  let show: () -> Void
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let size = appearance.textSize.pointSize
    Button(action: show) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "arrowshape.turn.up.left")
          .font(.system(size: size * 0.68, weight: .semibold))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          ReplyTitle(quote: quote, agentName: agentName)
            .font(theme.interfaceFont(size: size * 0.74, weight: .semibold))
          Text(verbatim: Self.oneLine(quote.excerpt))
            .font(theme.interfaceFont(size: size * 0.8))
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
        }
      }
      .foregroundStyle(foreground.color.opacity(0.75))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        foreground.color.opacity(0.07),
        in: RoundedRectangle(cornerRadius: max(theme.layout.innerRadius - 2, 4)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .instantTooltip(Text("Show the Quoted Message", bundle: .module))
    .accessibilityHint(Text("Show the Quoted Message", bundle: .module))
  }

  /// A passage on one line: its line breaks as spaces.
  static func oneLine(_ excerpt: String) -> String {
    excerpt.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
}

/// Under a message that has replies: « ↩ 2 replies », which brings the last one into view.
struct RepliesButton: View {
  let replies: [String]
  let show: (String) -> Void
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    if let last = replies.last {
      Button {
        show(last)
      } label: {
        Label {
          Text("\(replies.count) replies", bundle: .module)
        } icon: {
          Image(systemName: "arrowshape.turn.up.left")
        }
        .font(theme.interfaceFont(size: appearance.textSize.scaled(11.5), weight: .semibold))
        .foregroundStyle(theme.accent.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(theme.accent.color.opacity(0.1), in: Capsule())
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .instantTooltip(Text("Show the Reply", bundle: .module))
    }
  }
}

/// « Back to your reply », over the messages while the user reads the passage a reply quotes.
struct ReturnToReplyButton: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    Button {
      model.returnToReply()
    } label: {
      Label {
        Text("Back to Your Reply", bundle: .module)
      } icon: {
        Image(systemName: "arrow.down")
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5), weight: .semibold))
      .foregroundStyle(theme.text.color)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .modifier(
        ConversationGlass(
          shape: Capsule(), fill: theme.raised.color, border: theme.border.color,
          isInteractive: true, shadowRadius: 6, shadowOpacity: 0.2, shadowY: 2))
    }
    .buttonStyle(.plain)
  }
}

/// A block brought into view by a reply, or by the passage it quotes, lit a moment.
struct ReplyHighlight: ViewModifier {
  let isLit: Bool
  @Environment(\.conversationTheme) private var theme

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: theme.layout.innerRadius)
          .fill(theme.warning.color.opacity(isLit ? 0.16 : 0))
          .padding(-6)
          .allowsHitTesting(false)
      }
      .animation(.easeOut(duration: 0.4), value: isLit)
  }
}

/// « Reply », small, under a message of the user's while the pointer is over it.
struct ReplyButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ReplyLabel()
    }
    .buttonStyle(.plain)
    .pointingHand()
  }
}

/// What « Reply » shows: also the room it keeps, empty, where it is not built yet.
struct ReplyLabel: View {
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    Label {
      Text("Reply", bundle: .module)
    } icon: {
      Image(systemName: "arrowshape.turn.up.left")
    }
    .font(theme.interfaceFont(size: appearance.textSize.scaled(11), weight: .medium))
    .foregroundStyle(theme.secondaryText.color)
    .contentShape(Rectangle())
  }
}
