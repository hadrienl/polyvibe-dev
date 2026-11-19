import AppKit
import SwiftUI

/// « Reply » over a message's text (#565): at the end of the paragraph under the pointer, or of
/// the selection once it is made.
final class ReplyAccessoryButton: NSButton {
  /// The passage it replies to.
  var passage = ""
  var reply: ((String) -> Void)?

  /// Around its label, inside its capsule.
  private static let padding = CGSize(width: 14, height: 6)

  convenience init(tint: NSColor) {
    self.init(frame: .zero)
    // A capsule of its own, opaque and lifted: over the words that follow the selection, it is
    // read as the button it is, not lost among them.
    isBordered = false
    wantsLayer = true
    layer?.borderWidth = 1
    layer?.masksToBounds = false
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.22)
    lift.shadowBlurRadius = 4
    lift.shadowOffset = NSSize(width: 0, height: -1)
    shadow = lift
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

  /// Its colours, the conversation's theme's.
  func paint(fill: NSColor, border: NSColor, tint: NSColor) {
    contentTintColor = tint
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = fill.cgColor
      layer?.borderColor = border.cgColor
    }
  }

  override var intrinsicContentSize: NSSize {
    let content = super.intrinsicContentSize
    return NSSize(
      width: ceil(content.width) + Self.padding.width,
      height: ceil(content.height) + Self.padding.height)
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
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
    if let button = replyButton, !button.isHidden,
      button.frame.insetBy(dx: -4, dy: -4).contains(point)
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
    button.paint(fill: replyFill, border: replyBorder, tint: replyTint)
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
    // In the conversation's order, the messages scrolled away included.
    let order = blockOrder(shown)
    let (first, last) = key(anchor, order) <= key(focus, order) ? (anchor, focus) : (focus, anchor)
    func view(at place: SelectionPlace) -> SegmentTextView? {
      shown.first { $0.block == place.block && $0.segment == place.segment }?.view
    }
    // At the selection's end, or at its start when the end has scrolled away.
    let (ending, offset): (SegmentTextView?, Int) =
      view(at: last).map { ($0, last.offset) } ?? (view(at: first), first.offset)
    // The message it starts in is the one replied to.
    let starting = shown.first { $0.block == first.block && $0.view.replyAction != nil }?.view
    guard let ending, let reply = starting?.replyAction ?? ending.replyAction else { return }
    let passage = SelectionText.plain(selectedPieces)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !passage.isEmpty else { return }
    ending.offerSelectionReply(endingAt: offset, passage: passage, reply: reply)
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

// MARK: The passage a reply quotes

extension SegmentTextView {
  /// The passage a reply quotes, lit here when it is in this text (#565), and brought into view
  /// where it starts.
  func light(_ light: PassageLight?, color: NSColor) {
    litColor = color
    guard light?.passage != litRequest else { return }
    litRequest = light?.passage
    let start = applyLight(light?.passage)
    guard let light, let start else { return }
    light.found()
    if start { bringLitPassageIntoView() }
  }

  /// Lights the passage where it is in the text, the light before gone. Returns whether it starts
  /// here, `nil` where it is not.
  @discardableResult
  func applyLight(_ passage: LitPassage?) -> Bool? {
    if let litRange, let layoutManager, NSMaxRange(litRange) <= textLength {
      layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: litRange)
    }
    litRange = nil
    guard let passage, let (range, start) = passage.quote.range(in: string),
      NSMaxRange(range) <= textLength
    else { return nil }
    layoutManager?.addTemporaryAttribute(
      .backgroundColor, value: litColor.withAlphaComponent(0.32), forCharacterRange: range)
    litRange = range
    return start
  }

  /// Once the conversation has scrolled to its message: the passage in the middle of the view,
  /// or its start at the top when it is taller.
  private func bringLitPassageIntoView() {
    let request = litRequest
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollSettleDelay) { [weak self] in
      guard let self, self.litRequest == request, let range = self.litRange,
        let layoutManager = self.layoutManager, let textContainer = self.textContainer,
        let clip = self.enclosingScrollView?.contentView
      else { return }
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var lit = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      lit.origin.x += self.textContainerOrigin.x
      lit.origin.y += self.textContainerOrigin.y
      let visible = self.convert(clip.documentVisibleRect, from: clip.documentView)
      guard !visible.contains(lit) else { return }
      // A margin above and below: centred, or its start under the top.
      let height = visible.height
      let shown =
        lit.height < height - 2 * Self.litMargin
        ? lit.insetBy(dx: 0, dy: -(height - lit.height) / 2 + 1)
        : CGRect(
          x: lit.minX, y: lit.minY - Self.litMargin, width: lit.width,
          height: height - 2)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.allowsImplicitAnimation = true
        self.scrollToVisible(shown)
      }
    }
  }

  /// What the conversation's own scroll to the message takes.
  nonisolated static let scrollSettleDelay = 0.3
  nonisolated static let litMargin: CGFloat = 24
}

/// The passage a reply quotes, lit in the message around (#565), and what to tell when one of its
/// texts shows it.
struct PassageLight: Equatable {
  let passage: LitPassage
  let found: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.passage == rhs.passage }
}

extension EnvironmentValues {
  /// The passage of a reply lit in the message around (#565): `nil` while none is.
  @Entry var litPassage: PassageLight?
}
