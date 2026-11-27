import AppKit
import SwiftUI
import VibeApplication

/// How a key moment shows (#572): its icon, its colour, the name of its kind, what happened. The
/// same in the overview, its filters, its preview and the margin of the messages.
@MainActor
enum MomentPresentation {
  // MARK: Kinds

  /// The icon of a kind, on its filter button. A bookmark has its own shape, drawn rather than a
  /// symbol: `nil`.
  static func symbol(of kind: ConversationMomentKind) -> String? {
    switch kind {
    case .bookmark: nil
    case .message: "bubble.right"
    case .git: "arrow.triangle.branch"
    case .forge: "arrow.triangle.pull"
    case .tests: "checkmark.circle"
    case .question: "questionmark.bubble"
    case .incident: "exclamationmark.triangle"
    }
  }

  static func name(of kind: ConversationMomentKind) -> String {
    switch kind {
    case .bookmark: String(localized: "Bookmarks", bundle: .module)
    case .message: String(localized: "Your messages", bundle: .module)
    case .git: "Git"
    case .forge: String(localized: "Tickets and Pull Requests", bundle: .module)
    case .tests: String(localized: "Tests", bundle: .module)
    case .question: String(localized: "Questions", bundle: .module)
    case .incident: String(localized: "Incidents", bundle: .module)
    }
  }

  /// The accent, the success and the failure come from the theme; the others are the system's.
  nonisolated static func color(of kind: ConversationMomentKind, theme: ConversationTheme)
    -> Color
  {
    switch kind {
    case .bookmark: theme.accent.color
    case .message: Color(nsColor: .systemIndigo)
    case .git: Color(nsColor: .systemOrange)
    case .forge: Color(nsColor: .systemPurple)
    case .tests: theme.success.color
    case .question: Color(nsColor: .systemTeal)
    case .incident: Color(nsColor: .systemYellow)
    }
  }

  // MARK: Moments

  static func symbol(of moment: ConversationMoment) -> String {
    switch moment.detail {
    case .bookmark: "bookmark"
    case .message: "bubble.right"
    case .commit: "smallcircle.filled.circle"
    case .push: "arrow.up.circle"
    case .branch: "arrow.triangle.branch"
    case .worktree: "folder.badge.plus"
    case .created(.issue, _): "smallcircle.circle"
    case .created: "arrow.triangle.pull"
    case .merged: "arrow.triangle.merge"
    case .tests(let outcome): outcome.failed > 0 ? "xmark.circle" : "checkmark.circle"
    case .question: "questionmark.bubble"
    case .plan: "list.bullet.clipboard"
    case .error, .interrupted: "exclamationmark.triangle"
    }
  }

  static func color(of moment: ConversationMoment, theme: ConversationTheme) -> Color {
    moment.isFailure ? theme.failure.color : color(of: moment.kind, theme: theme)
  }

  /// What happened, on one line: for a bookmark or a message, the start of its message.
  static func label(of moment: ConversationMoment, block: ConversationBlock?) -> String {
    switch moment.detail {
    case .bookmark, .message:
      return block.map(ConversationModel.bookmarkExcerpt(of:)) ?? ""
    case .commit(let subject?):
      return String(localized: "Commit “\(subject)”", bundle: .module)
    case .commit(nil):
      return String(localized: "Commit", bundle: .module)
    case .push(let branch?):
      return String(localized: "Pushed to \(branch)", bundle: .module)
    case .push(nil):
      return String(localized: "Pushed", bundle: .module)
    case .branch(let name):
      return String(localized: "Branch \(name) created", bundle: .module)
    case .worktree(let path):
      let name = (path as NSString).lastPathComponent
      return String(localized: "Worktree \(name) created", bundle: .module)
    case .created(.issue, let label?):
      return String(localized: "Issue \(label) created", bundle: .module)
    case .created(.issue, nil):
      return String(localized: "Issue created", bundle: .module)
    case .created(_, let label?):
      return String(localized: "Pull request \(label) opened", bundle: .module)
    case .created(_, nil):
      return String(localized: "Pull request opened", bundle: .module)
    case .merged(let label?):
      return String(localized: "Pull request \(label) merged", bundle: .module)
    case .merged(nil):
      return String(localized: "Pull request merged", bundle: .module)
    case .tests(let outcome) where outcome.failed > 0:
      return String(localized: "\(outcome.failed) of \(outcome.total) failed", bundle: .module)
    case .tests(let outcome):
      return String(localized: "\(outcome.total) passed", bundle: .module)
    case .question(let question, _):
      return oneLine(question) ?? String(localized: "Question", bundle: .module)
    case .plan(let title):
      return oneLine(title) ?? String(localized: "Plan", bundle: .module)
    case .error(let text):
      return oneLine(text) ?? ""
    case .interrupted:
      return String(localized: "Turn interrupted", bundle: .module)
    }
  }

  /// What the user answered a question, under it in the preview.
  static func answer(of moment: ConversationMoment) -> String? {
    guard case .question(_, let answer?) = moment.detail else { return nil }
    return String(localized: "Answer: \(answer)", bundle: .module)
  }

  /// The kind and the label, as the margin's help and VoiceOver read a moment.
  static func description(of moment: ConversationMoment, block: ConversationBlock?) -> String {
    var text = "\(name(of: moment.kind)) · \(label(of: moment, block: block))"
    if let answer = answer(of: moment) { text += " · \(answer)" }
    return text
  }

  /// A block's moments as the rotor reads them, one after the other.
  static func rotorLabel(of moments: [ConversationMoment], block: ConversationBlock) -> String {
    moments.map { description(of: $0, block: block) }.joined(separator: "; ")
  }

  private static func oneLine(_ text: String?) -> String? {
    guard let text else { return nil }
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !flat.isEmpty else { return nil }
    return flat.count > 140 ? String(flat.prefix(139)) + "…" : flat
  }

  /// When it happened: the day too, for another day's.
  static func time(of date: Date?) -> String? {
    guard let date else { return nil }
    let day: Date.FormatStyle.DateStyle =
      Calendar.current.isDateInToday(date) ? .omitted : .abbreviated
    return date.formatted(date: day, time: .shortened)
  }
}

/// A moment's icon: its symbol in its colour, or a bookmark's shape.
struct MomentIcon: View {
  let symbol: String?
  let color: Color
  /// The height of the symbol, and of a bookmark's shape.
  let size: Double

  var body: some View {
    if let symbol, symbol != "bookmark" {
      Image(systemName: symbol)
        .resizable()
        .scaledToFit()
        .fontWeight(.semibold)
        .foregroundStyle(color)
        .frame(width: size + 2, height: size)
    } else {
      // Narrower than the margin's tag: the overview's margin is narrow.
      BookmarkShape()
        .fill(color)
        .frame(width: size * 1.25, height: size * 0.8)
        .frame(width: size + 2, height: size)
    }
  }
}

/// The moments of a block, in the margin left of its bookmark (#572): the first one's icon, and
/// how many there are when there are several. It does nothing: the pointer on it shows them, in
/// the overview's preview (#608).
struct MomentGutterMark: View {
  /// Those of the kinds shown, bookmarks and messages aside: a bookmark's shape is beside it
  /// already, the message is the block itself.
  let moments: [ConversationMoment]
  let block: ConversationBlock
  let preview: ConversationMarginPreview
  /// The height of the block's first line, which it is centred on, as the bookmark is.
  let lineHeight: Double
  @Environment(\.conversationTheme) private var theme

  /// Its width, left of the bookmark's.
  static let width = 18.0
  /// The height of its symbol: the bookmark's tag's.
  static let symbolSize = BookmarkGutter.tagHeight

  /// What it shows of a block: its moments of the kinds shown, bookmarks aside.
  static func moments(
    of block: ConversationBlock, model: ConversationModel, appearance: ConversationAppearance
  ) -> [ConversationMoment] {
    // A message's own: the message is right beside it.
    model.moments(of: block).filter { $0.kind != .message && appearance.shows($0.kind) }
  }

  var body: some View {
    let first = moments[0]
    let description = moments.map { MomentPresentation.description(of: $0, block: block) }
      .joined(separator: "\n")
    MomentIcon(
      symbol: MomentPresentation.symbol(of: first),
      color: MomentPresentation.color(of: first, theme: theme), size: Self.symbolSize
    )
    .overlay(alignment: .topTrailing) {
      if moments.count > 1 {
        Text(verbatim: "\(moments.count)")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(theme.secondaryText.color)
          .fixedSize()
          .offset(x: 5, y: -5)
      }
    }
    .frame(width: Self.width, height: BookmarkGutter.boxHeight(lineHeight: lineHeight))
    .contentShape(Rectangle())
    // The overview's preview rather than a help tag: the same words, at once (#608).
    .modifier(MarginPreviewSource(preview: preview, blockID: block.id, target: .moments))
    .accessibilityElement()
    .accessibilityLabel(Text(verbatim: description))
  }
}
