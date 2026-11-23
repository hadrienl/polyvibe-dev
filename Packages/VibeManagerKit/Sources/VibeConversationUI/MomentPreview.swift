import AppKit
import SwiftUI
import VibeApplication

/// The type of the moments' preview, the conversation's own: a bookmark's words as the messages
/// read them — the theme's font, at the conversation's size —, who wrote them as a relayed
/// message's summary does.
struct MomentPreviewStyle {
  let textSize: Double
  let headingFont: Font
  /// A bookmark's message.
  let excerptFont: Font
  /// What happened, for the other moments.
  let eventFont: Font
  /// What the user answered a question.
  let answerFont: Font

  init(theme: ConversationTheme, appearance: ConversationAppearance) {
    textSize = appearance.textSize.pointSize
    headingFont = theme.interfaceFont(size: textSize * 0.86, weight: .semibold)
    excerptFont = theme.messageFont(size: textSize)
    eventFont = theme.interfaceFont(size: textSize)
    answerFont = theme.interfaceFont(size: textSize * 0.86)
  }
}

/// What the preview of moments says, one item for each: a bookmark's message — who wrote it,
/// when, its start —, or what happened and when. The same for an icon of the overview and for one
/// of the margin (#608): both are read here, and drawn by `MomentPreview`. Read only while the
/// pointer is on an icon.
@MainActor
struct MomentPreviewContent: Equatable {
  struct Item: Equatable {
    /// Who wrote a bookmark's message, or a moment's kind; and when.
    var heading: String?
    /// What happened, or the start of a bookmark's message.
    var label: String
    /// A bookmark's message: in the type of the messages rather than the interface's.
    var isExcerpt: Bool
    /// What the user answered a question.
    var answer: String?
  }

  var items: [Item]

  init(moments: [(moment: ConversationMoment, block: ConversationBlock?)], agentName: String) {
    items = moments.map { Self.item(of: $0.moment, block: $0.block, agentName: agentName) }
  }

  /// An icon of the overview: the moments drawn with it, each with its own block.
  init(placed: some Collection<ConversationMoments.Placed>, model: ConversationModel) {
    let blocks = model.blocks
    self.init(
      moments: placed.map {
        ($0.moment, blocks.indices.contains($0.blockIndex) ? blocks[$0.blockIndex] : nil)
      },
      agentName: model.agentName)
  }

  /// An icon of the margin (#608): the block's moments, as its icon draws them, or its bookmark.
  /// `nil` when there is none — a bookmark just taken away.
  init?(
    margin target: ConversationMarginPreview.Target, of block: ConversationBlock,
    model: ConversationModel, appearance: ConversationAppearance
  ) {
    let moments: [ConversationMoment]
    switch target {
    case .moments:
      moments = MomentGutterMark.moments(of: block, model: model, appearance: appearance)
    case .bookmark:
      moments =
        ConversationMoments.bookmark(of: block, at: 0, in: model.bookmarks).map { [$0.moment] }
        ?? []
    }
    guard !moments.isEmpty else { return nil }
    self.init(moments: moments.map { ($0, block) }, agentName: model.agentName)
  }

  private static func item(
    of moment: ConversationMoment, block: ConversationBlock?, agentName: String
  ) -> Item {
    Item(
      heading: heading(of: moment, block: block, agentName: agentName),
      label: MomentPresentation.label(of: moment, block: block),
      isExcerpt: moment.kind == .bookmark,
      answer: MomentPresentation.answer(of: moment))
  }

  /// A bookmark's: who wrote its message — Vibe Manager or a coordinator for one relayed to the
  /// session (#568) —, and when. Another moment's: its kind, and when.
  private static func heading(
    of moment: ConversationMoment, block: ConversationBlock?, agentName: String
  ) -> String? {
    let time = MomentPresentation.time(of: moment.date)
    let who: String
    if moment.kind == .bookmark {
      guard let block, let author = author(of: block, agent: agentName) else {
        return MomentPresentation.name(of: .bookmark)
      }
      who = author
    } else {
      who = MomentPresentation.name(of: moment.kind)
    }
    return time.map { "\(who) · \($0)" } ?? who
  }

  private static func author(of block: ConversationBlock, agent: String) -> String? {
    guard case .entry(let entry) = block else { return nil }
    switch entry.content {
    case .userPrompt:
      switch ConversationModel.relayedMessage(of: block)?.sender {
      case .application: return "Vibe Manager"
      case .coordinator(let name):
        return String(localized: "Coordinator “\(name)”", bundle: .module)
      case nil: return String(localized: "You", bundle: .module)
      }
    case .agentText: return agent
    default: return nil
    }
  }
}

/// The moments under the pointer, beside the overview or below an icon of the margin, in the
/// conversation's own type.
struct MomentPreview: View {
  let content: MomentPreviewContent
  let theme: ConversationTheme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    let style = MomentPreviewStyle(theme: theme, appearance: appearance)
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(content.items.enumerated()), id: \.offset) { _, item in
        VStack(alignment: .leading, spacing: 3) {
          if let heading = item.heading {
            Text(heading)
              .font(style.headingFont)
              .foregroundStyle(theme.secondaryText.color)
              .lineLimit(1)
          }
          if !item.label.isEmpty {
            Text(item.label)
              .font(item.isExcerpt ? style.excerptFont : style.eventFont)
              .foregroundStyle(theme.text.color)
              .lineLimit(3)
          }
          if let answer = item.answer {
            Text(answer)
              .font(style.answerFont)
              .foregroundStyle(theme.secondaryText.color)
              .lineLimit(2)
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
  }
}

// MARK: - The margin's preview (#608)

/// The icon of the margin the pointer is on, and where it is: what the preview over the messages
/// shows, and next to what. Gone as soon as the icon moves under the pointer — the messages
/// scrolled —, and not shown again until the pointer moves once they have stopped: the rows
/// passing under a still pointer would show and hide it at each frame.
@MainActor
@Observable
public final class ConversationMarginPreview {
  enum Target: Hashable, Sendable {
    /// The icon of the block's moments.
    case moments
    /// Its bookmark, once set.
    case bookmark
  }

  struct Hover: Equatable {
    var blockID: String
    var target: Target
    /// The icon's box, in `ConversationView.viewportSpace`.
    var anchor: CGRect
  }

  private(set) var hover: Hover?
  @ObservationIgnored private var quietUntil: ContinuousClock.Instant?
  @ObservationIgnored var now: () -> ContinuousClock.Instant = { ContinuousClock.now }
  /// How long after the last step of a scroll the pointer shows nothing.
  static let quietAfterScroll = Duration.milliseconds(250)

  public init() {}

  /// The pointer is on an icon, or the icon it is on moved: under a pointer that stayed, the
  /// messages scrolled.
  func pointerOn(blockID: String, target: Target, anchor: CGRect) {
    if let hover, hover.blockID == blockID, hover.target == target, hover.anchor != anchor {
      scrolled()
      return
    }
    if let quietUntil, now() < quietUntil { return }
    let hover = Hover(blockID: blockID, target: target, anchor: anchor)
    if hover != self.hover { self.hover = hover }
  }

  /// The pointer left an icon, or it has nothing to show any more: hidden if it was its preview.
  func pointerLeft(blockID: String, target: Target) {
    guard hover?.blockID == blockID, hover?.target == target else { return }
    hover = nil
  }

  /// The messages moved under the pointer.
  func scrolled() {
    contentMoved()
    if hover != nil { hover = nil }
  }

  /// The messages moved, perhaps not on screen — rows above measured again —: what is shown
  /// stays while its icon does not move, but no row brought under the pointer shows its own.
  func contentMoved() {
    quietUntil = now() + Self.quietAfterScroll
  }

  /// The conversation put away: nothing shown when it comes back, the pointer elsewhere.
  func hide() {
    if hover != nil { hover = nil }
  }
}

/// Tells the margin's preview when the pointer is on the icon it is applied to, and where the
/// icon is. Its place is read only while the pointer is on it: a row built by a scroll adds the
/// hover's tracking and the state it keeps, nothing that runs before the pointer comes.
struct MarginPreviewSource: ViewModifier {
  let preview: ConversationMarginPreview
  let blockID: String
  let target: ConversationMarginPreview.Target
  /// Whether it has something to show: a bookmark not set has none.
  var isEnabled = true
  /// Told when the pointer comes onto the icon and leaves it: the icon's own look, with the same
  /// tracking.
  var hovered: ((Bool) -> Void)?
  @State private var isHovered = false
  @State private var anchor: CGRect?

  func body(content: Content) -> some View {
    content
      .onContinuousHover { phase in
        switch phase {
        case .active:
          if !isHovered {
            isHovered = true
            hovered?(true)
          }
          show(at: anchor)
        case .ended:
          isHovered = false
          hovered?(false)
          anchor = nil
          preview.pointerLeft(blockID: blockID, target: target)
        }
      }
      .background {
        if isHovered {
          Color.clear.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(ConversationView.viewportSpace))
          } action: { frame in
            anchor = frame
            show(at: frame)
          }
        }
      }
      .onChange(of: isEnabled) {
        if isEnabled {
          show(at: anchor)
        } else {
          preview.pointerLeft(blockID: blockID, target: target)
        }
      }
      // Its row gone with the pointer on it.
      .onDisappear {
        if isHovered { preview.pointerLeft(blockID: blockID, target: target) }
      }
  }

  private func show(at anchor: CGRect?) {
    guard isEnabled, let anchor else { return }
    preview.pointerOn(blockID: blockID, target: target, anchor: anchor)
  }
}

/// The preview of the margin's icon the pointer is on, over the messages (#608). Drawn above the
/// list rather than in the icon's row, which the rows below it would cover, and in a view of its
/// own: the pointer coming and going redraws it alone, never the messages.
struct MarginPreviewOverlay: View {
  let model: ConversationModel
  let theme: ConversationTheme
  @Environment(\.conversationAppearance) private var appearance

  var body: some View {
    if let hover = model.marginPreview.hover,
      let block = model.blocks.first(where: { $0.id == hover.blockID }),
      let content = MomentPreviewContent(
        margin: hover.target, of: block, model: model, appearance: appearance)
    {
      GeometryReader { geometry in
        let origin = geometry.frame(in: .named(ConversationView.viewportSpace)).origin
        let anchor = hover.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
        MarginPreviewPlacement(
          anchor: anchor,
          // Below the toolbar the messages scroll under, above the composer.
          insets: (geometry.safeAreaInsets.top, geometry.safeAreaInsets.bottom),
          width: ConversationOverviewLayout.previewWidth(
            textSize: MomentPreviewStyle(theme: theme, appearance: appearance).textSize,
            room: geometry.size.width - anchor.minX)
        ) {
          MomentPreview(content: content, theme: theme)
        }
      }
      .allowsHitTesting(false)
      // VoiceOver reads the icon's own label: the preview is what the eye gets of it.
      .accessibilityHidden(true)
    }
  }
}

/// Lays the margin's preview where `ConversationOverviewLayout.marginPreviewOrigin` puts it, from
/// the size it takes at `width` at most.
private struct MarginPreviewPlacement: Layout {
  let anchor: CGRect
  let insets: (top: Double, bottom: Double)
  let width: Double

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      let origin = ConversationOverviewLayout.marginPreviewOrigin(
        iconMinX: anchor.minX, iconMinY: anchor.minY, iconMaxY: anchor.maxY,
        previewWidth: size.width, previewHeight: size.height, paneWidth: bounds.width,
        paneTop: insets.top, paneBottom: bounds.height - insets.bottom)
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: ProposedViewSize(size))
    }
  }
}
