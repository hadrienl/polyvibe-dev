import AppKit
import SwiftUI

/// « Reply » over a message's text (#565): at the end of the paragraph under the pointer, or of
/// the selection once it is made.
final class ReplyAccessoryButton: NSButton {
  /// The passage it replies to.
  var passage = ""
  var reply: ((String) -> Void)?

  convenience init(tint: NSColor) {
    self.init(frame: .zero)
    bezelStyle = .inline
    controlSize = .small
    font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    image = NSImage(
      systemSymbolName: "arrowshape.turn.up.left",
      accessibilityDescription: nil)
    imagePosition = .imageLeading
    imageHugsTitle = true
    contentTintColor = tint
    target = self
    action = #selector(clicked)
  }

  @objc private func clicked() {
    reply?(passage)
  }

  /// Its label, or its icon alone where the label does not fit.
  func set(title: String, iconOnly: Bool) {
    self.title = iconOnly ? "" : title
    imagePosition = iconOnly ? .imageOnly : .imageLeading
    toolTip = iconOnly ? title : nil
    setAccessibilityLabel(title)
    setFrameSize(fittingSize)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

extension SegmentTextView {
  /// The gap between the text and the button.
  nonisolated static let replyGap: CGFloat = 6

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let replyTrackingArea { removeTrackingArea(replyTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    replyTrackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    guard offersParagraphReply, replyAction != nil, selectionReplyOffset == nil else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let button = replyButton, !button.isHidden, button.frame.insetBy(dx: -4, dy: -4).contains(point)
    {
      return
    }
    guard let paragraph = paragraph(at: point) else { return hideReplyButton() }
    guard paragraph != repliedParagraph else { return }
    let passage = (string as NSString).substring(with: paragraph)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !passage.isEmpty else { return hideReplyButton() }
    showReplyButton(
      after: NSMaxRange(paragraph), passage: passage,
      title: String(localized: "Reply", bundle: .module))
    repliedParagraph = paragraph
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    if selectionReplyOffset == nil { hideReplyButton() }
  }

  /// The selection ends here: « Reply to Selection » at its end, for `passage`, replied to by
  /// `reply` — the action of the message it starts in.
  func offerSelectionReply(endingAt offset: Int, passage: String, reply: @escaping (String) -> Void)
  {
    showReplyButton(
      after: offset, passage: passage,
      title: String(localized: "Reply to Selection", bundle: .module), action: reply)
    selectionReplyOffset = offset
    repliedParagraph = nil
  }

  func hideReplyButton() {
    replyButton?.isHidden = true
    repliedParagraph = nil
    selectionReplyOffset = nil
  }

  /// The paragraph under `point`, a point of the view: `nil` beside the text.
  func paragraph(at point: NSPoint) -> NSRange? {
    guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else {
      return nil
    }
    let inContainer = NSPoint(
      x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    guard layoutManager.usedRect(for: textContainer).insetBy(dx: 0, dy: -2).contains(inContainer)
    else { return nil }
    let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
    guard glyph < layoutManager.numberOfGlyphs else { return nil }
    let index = layoutManager.characterIndexForGlyph(at: glyph)
    var paragraph = (string as NSString).paragraphRange(
      for: NSRange(location: min(index, textStorage.length - 1), length: 0))
    // Without its line break: the button follows its last word.
    while paragraph.length > 0,
      let last = (string as NSString).substring(
        with: NSRange(location: NSMaxRange(paragraph) - 1, length: 1)
      ).unicodeScalars.first,
      CharacterSet.newlines.contains(last)
    {
      paragraph.length -= 1
    }
    guard paragraph.length > 0 else { return nil }
    // Between two paragraphs, in the space that parts them, the pointer is over neither.
    let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
    var extent = CGRect.null
    layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
      extent = extent.union(used)
    }
    guard !extent.isNull, inContainer.y >= extent.minY - 2, inContainer.y <= extent.maxY + 2
    else { return nil }
    return paragraph
  }

  /// Where the button goes after the character at `offset`: past the end of its line, or, the
  /// line full, its icon alone at the line's end.
  func replyButtonFrame(after offset: Int, size: CGSize, iconSize: CGSize) -> (CGRect, Bool)? {
    guard let layoutManager, let textContainer, offset > 0 else { return nil }
    let glyphs = layoutManager.glyphRange(
      forCharacterRange: NSRange(location: offset - 1, length: 1), actualCharacterRange: nil)
    guard glyphs.length > 0 else { return nil }
    let last = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
    let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
    let origin = textContainerOrigin
    let x = last.maxX + origin.x + Self.replyGap
    func centered(_ height: CGFloat) -> CGFloat {
      line.midY + origin.y - height / 2
    }
    if x + size.width <= bounds.width {
      return (CGRect(x: x, y: centered(size.height), width: size.width, height: size.height), false)
    }
    let iconX = min(x, bounds.width - iconSize.width)
    return (
      CGRect(
        x: max(iconX, 0), y: centered(iconSize.height), width: iconSize.width,
        height: iconSize.height),
      true
    )
  }

  private func showReplyButton(
    after offset: Int, passage: String, title: String, action: ((String) -> Void)? = nil
  ) {
    let button = replyButton ?? ReplyAccessoryButton(tint: replyTint)
    if replyButton == nil {
      replyButton = button
      addSubview(button)
    }
    button.contentTintColor = replyTint
    button.set(title: title, iconOnly: true)
    let iconSize = button.fittingSize
    button.set(title: title, iconOnly: false)
    let size = button.fittingSize
    guard let (frame, iconOnly) = replyButtonFrame(after: offset, size: size, iconSize: iconSize)
    else { return hideReplyButton() }
    button.set(title: title, iconOnly: iconOnly)
    button.frame = frame
    button.passage = passage
    let reply = action ?? replyAction
    button.reply = { [weak self] passage in
      reply?(passage)
      self?.hideReplyButton()
    }
    button.isHidden = false
  }
}

extension ConversationSelection {
  /// The selection made, « Reply to Selection » at its end (#565), for the message it starts in.
  func offerReply() {
    let shown = shown
    for item in shown { item.view.hideReplyButton() }
    guard hasSelection, let anchor, let focus else { return }
    let order = Dictionary(
      shown.enumerated().map { ($0.element.block, $0.offset) },
      uniquingKeysWith: { first, _ in first })
    func rank(_ place: SelectionPlace) -> (Int, Int, Int) {
      (order[place.block] ?? Int.max, place.segment, place.offset)
    }
    let (first, last) = rank(anchor) < rank(focus) ? (anchor, focus) : (focus, anchor)
    let starting = shown.first { $0.block == first.block && $0.view.replyAction != nil }
    guard
      let ending = shown.first(where: { $0.block == last.block && $0.segment == last.segment }),
      let reply = starting?.view.replyAction ?? ending.view.replyAction
    else { return }
    let passage = SelectionText.plain(selectedPieces)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !passage.isEmpty else { return }
    ending.view.offerSelectionReply(endingAt: last.offset, passage: passage, reply: reply)
  }
}

/// Replies to a passage of a message (#565), the same for as long as its message is.
struct PassageReply: Equatable {
  /// The message, and whose it is.
  let id: String
  let action: (String) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
  /// Replies to a passage of the message around (#565): none where it cannot be replied to.
  @Entry var replyToPassage: PassageReply?
}
