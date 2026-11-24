import SwiftUI

/// Back to the end of the conversation, centred over its bottom while the reader is above (#619).
///
/// An arrow alone while nothing arrived, small over the lines read; the same button grows into
/// « 3 new messages » once something did, rather than a second one appearing elsewhere. Not in a
/// corner: down there on the right it would echo the composer's send arrow, pointing the other way.
///
/// A view of its own so that only it reads the scroll state: the messages are not drawn again each
/// time the reader leaves the end or comes back to it.
struct JumpToBottomButton: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let state = model.scroll.jumpToBottom
    ZStack {
      if state != .hidden {
        button(state)
          .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state)
  }

  private func button(_ state: ConversationScrollState.JumpToBottom) -> some View {
    // The arrow alone is a circle as tall as the pill with words.
    let side = appearance.textSize.scaled(28)
    return Button {
      model.jumpToBottom()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "arrow.down")
        if case .newMessages(let count) = state {
          Text("\(count) new messages", bundle: .module).lineLimit(1).fixedSize()
        }
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5), weight: .semibold))
      .foregroundStyle(theme.text.color)
      .padding(.horizontal, state == .arrow ? 0 : 12)
      .frame(minWidth: side, minHeight: side)
      .modifier(
        ConversationGlass(
          shape: Capsule(), fill: theme.raised.color, border: theme.border.color,
          isInteractive: true, shadowRadius: 6, shadowOpacity: 0.2, shadowY: 2))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    // The words say it once there are some; the arrow alone needs them under the pointer.
    .instantTooltip(state == .arrow ? Self.name(of: state) : nil)
    .accessibilityLabel(Self.name(of: state))
  }

  private static func name(of state: ConversationScrollState.JumpToBottom) -> Text {
    if case .newMessages(let count) = state {
      return Text("\(count) new messages", bundle: .module)
    }
    return Text(
      "Scroll to Bottom", bundle: .module,
      comment: "Over the conversation, once the reader has scrolled up: goes back to its end (#619).")
  }
}
