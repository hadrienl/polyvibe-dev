import SwiftUI
import VibeApplication

/// A message Vibe Manager or the session's coordinator sent it, folded under who wrote it — and,
/// for Vibe Manager's news, the sessions it is about. Unfolded, what the agent read, in English as
/// it read it.
struct RelayedMessageView: View {
  let id: String
  let message: RelayedMessage
  /// As the agent read it, for Copy Message.
  let text: String
  let date: Date?
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let _ = model.toggleRevision
    let isExpanded = model.isExpanded(id: id, default: false)
    let size = appearance.textSize.pointSize * 0.86
    VStack(alignment: .leading, spacing: 6) {
      Button {
        model.setExpanded(!isExpanded, for: id)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.system(size: size * 0.75, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Image(systemName: symbol)
          summary
            .lineLimit(1)
            .truncationMode(.tail)
          MessageTime(date: date, tooltipSide: .trailing)
        }
        .font(theme.interfaceFont(size: size))
        .foregroundStyle(theme.secondaryText.color)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(
        isExpanded ? Text("expanded", bundle: .module) : Text("collapsed", bundle: .module)
      )
      .contextMenu {
        Button {
          copy(text)
        } label: {
          Text("Copy Message", bundle: .module)
        }
      }
      if isExpanded {
        HStack(alignment: .top, spacing: 10) {
          Rectangle().fill(theme.border.color).frame(width: 2)
          MarkdownView(text: message.body)
            .opacity(0.85)
        }
        .padding(.leading, 18)
      }
    }
  }

  /// Who wrote it, and the sessions Vibe Manager's news is about.
  private var summary: Text {
    switch message.sender {
    case .application:
      let sender = Text(verbatim: "Vibe Manager").fontWeight(.semibold)
      guard !message.children.isEmpty else { return sender }
      return sender + Text(verbatim: " · " + message.children.joined(separator: ", "))
    case .coordinator(let name):
      return Text("Coordinator “\(name)”", bundle: .module).fontWeight(.semibold)
    }
  }

  /// The same, as VoiceOver's rotor names it.
  static func summary(of message: RelayedMessage) -> String {
    switch message.sender {
    case .application:
      return (["Vibe Manager"] + [message.children.joined(separator: ", ")])
        .filter { !$0.isEmpty }.joined(separator: " · ")
    case .coordinator(let name):
      return String(localized: "Coordinator “\(name)”", bundle: .module)
    }
  }

  private var symbol: String {
    switch message.sender {
    case .application: "bell"
    case .coordinator: "point.3.connected.trianglepath.dotted"
    }
  }
}
