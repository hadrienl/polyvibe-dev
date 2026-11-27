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
  @Environment(\.conversationPalette) private var palette
  @Environment(\.dynamicTypeSize) private var typeSize

  /// What the text is built from: the same again leaves the view alone, and its selection with it.
  struct Input: Equatable {
    var text: AttributedString
    var color: UIColor
    var accent: UIColor
    var design: Font.Design
    var code: Bool
    var typeSize: DynamicTypeSize
  }

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.delegate = context.coordinator
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  private func baseFont(_ typeSize: DynamicTypeSize) -> UIFont {
    UIFont.preferredFont(
      forTextStyle: code ? .footnote : .body,
      compatibleWith: UITraitCollection(
        preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.reply = reply
    // Opens outside: a tapped link uses the same SwiftUI OpenURLAction as the previous Text.
    context.coordinator.openURL = { openURL($0) }
    let input = Input(
      text: text, color: color, accent: UIColor(palette.accent), design: design, code: code,
      typeSize: typeSize)
    // Set again only when it changed: setting the text clears the selection and its menu.
    guard input != context.coordinator.input else { return }
    context.coordinator.input = input
    // Links in the conversation's accent, as the SwiftUI text drew them.
    view.tintColor = input.accent
    view.linkTextAttributes = [.foregroundColor: input.accent]
    view.attributedText = attributed(input)
  }

  private func attributed(_ input: Input) -> NSAttributedString {
    let attributed = NSMutableAttributedString(attributedString: NSAttributedString(input.text))
    let base = baseFont(input.typeSize)
    let fontDesign: UIFontDescriptor.SystemDesign =
      input.code || input.design == .monospaced
      ? .monospaced
      : input.design == .serif ? .serif : input.design == .rounded ? .rounded : .default
    let descriptor = base.fontDescriptor.withDesign(fontDesign) ?? base.fontDescriptor
    var offset = 0
    for run in input.text.runs {
      let length = String(input.text[run.range].characters).utf16.count
      let range = NSRange(location: offset, length: length)
      offset += length
      let intent = run.inlinePresentationIntent ?? []
      var traits = descriptor.symbolicTraits
      if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
      if intent.contains(.emphasized) { traits.insert(.traitItalic) }
      let selected =
        intent.contains(.code) ? (descriptor.withDesign(.monospaced) ?? descriptor) : descriptor
      let styled = selected.withSymbolicTraits(traits) ?? selected
      var attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont(descriptor: styled, size: base.pointSize), .foregroundColor: input.color,
      ]
      if intent.contains(.strikethrough) {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      attributed.addAttributes(attributes, range: range)
    }
    return attributed
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    if code {
      let font = UIFont.monospacedSystemFont(ofSize: baseFont(typeSize).pointSize, weight: .regular)
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
    var input: Input?
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
