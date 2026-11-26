import CompanionCore
import SwiftUI
import UIKit

/// Native selection keeps its Copy and link actions; Reply adds only the selected characters.
struct ReplySelectableText: UIViewRepresentable {
  let text: AttributedString
  let color: UIColor
  var design: Font.Design = .default
  var code = false
  let reply: ((String) -> Void)?
  @Environment(\.openURL) private var openURL

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = true
    view.delegate = context.coordinator
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.reply = reply
    context.coordinator.openURL = { openURL($0) }
    let attributed = NSMutableAttributedString(attributedString: NSAttributedString(text))
    let base = UIFont.preferredFont(forTextStyle: code ? .footnote : .body)
    let fontDesign: UIFontDescriptor.SystemDesign =
      code || design == .monospaced
      ? .monospaced
      : design == .serif ? .serif : design == .rounded ? .rounded : .default
    let descriptor = base.fontDescriptor.withDesign(fontDesign) ?? base.fontDescriptor
    var offset = 0
    for run in text.runs {
      let length = String(text[run.range].characters).utf16.count
      let range = NSRange(location: offset, length: length)
      offset += length
      var traits = descriptor.symbolicTraits
      if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
        traits.insert(.traitBold)
      }
      if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
      let mono = run.inlinePresentationIntent?.contains(.code) == true
      let selected = mono ? (descriptor.withDesign(.monospaced) ?? descriptor) : descriptor
      let styled = selected.withSymbolicTraits(traits) ?? selected
      attributed.addAttributes(
        [.font: UIFont(descriptor: styled, size: base.pointSize), .foregroundColor: color],
        range: range)
    }
    if view.attributedText != attributed { view.attributedText = attributed }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    if code {
      let font = UIFont.monospacedSystemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
      let width =
        String(text.characters).components(separatedBy: "\n").map {
          ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 1
      return uiView.sizeThatFits(CGSize(width: ceil(width) + 1, height: .greatestFiniteMagnitude))
    }
    guard let width = proposal.width else { return nil }
    return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UITextViewDelegate {
    var reply: ((String) -> Void)?
    var openURL: ((URL) -> Void)?

    func textView(
      _ textView: UITextView, primaryActionFor textItem: UITextItem,
      defaultAction: UIAction
    ) -> UIAction? {
      guard case .link(let url) = textItem.content else { return defaultAction }
      return UIAction { [weak self] _ in self?.openURL?(url) }
    }

    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      guard let reply, range.length > 0,
        let selected = Range(range, in: textView.text)
      else { return UIMenu(children: suggestedActions) }
      let excerpt = String(textView.text[selected])
      let action = UIAction(
        title: String(localized: "Reply"), image: UIImage(systemName: "arrowshape.turn.up.left")
      ) { _ in
        reply(excerpt)
      }
      return UIMenu(children: suggestedActions + [action])
    }
  }
}

struct ConversationReplyQuote: View {
  let reply: RemoteReply
  let agentName: String
  var action: (() -> Void)?
  var composing = false
  @Environment(\.conversationPalette) private var palette
  @Environment(\.locale) private var locale

  var body: some View {
    Group {
      if let action {
        Button(action: action) { content }.buttonStyle(.plain)
      } else {
        content
      }
    }
  }

  private var content: some View {
    HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 3)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          if composing {
            Text("Reply to \(reply.author == .agent ? agentName : String(localized: "You"))")
          } else {
            Text(verbatim: reply.author == .agent ? agentName : String(localized: "You"))
          }
          if let date = reply.date {
            Text(date, format: .dateTime.hour().minute().locale(locale))
          } else if let time = reply.time {
            Text(verbatim: time)
          }
        }.font(.caption.weight(.medium))
        Text(verbatim: reply.excerpt).font(.subheadline).lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(palette.secondaryText)
    .fixedSize(horizontal: false, vertical: true)
  }
}
