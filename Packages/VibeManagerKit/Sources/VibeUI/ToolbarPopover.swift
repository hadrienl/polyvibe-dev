import AppKit
import SwiftUI

/// A popover under a toolbar button, the same for every button that opens one: the simulators,
/// the session's notes.
///
/// AppKit's, owned here rather than by a SwiftUI presentation binding, so that its owner can close
/// it in one synchronous step — at once when another window replaces it, with the usual animation
/// otherwise — and so that a click on its own button closes it rather than closing and opening it
/// again.
@MainActor
final class ToolbarPopover: NSObject, NSPopoverDelegate {
  /// The popover on screen, if any.
  private(set) var popover: NSPopover?
  /// The button's view, under which the popover opens. `nil` while the button is folded into the
  /// toolbar's overflow menu.
  weak var anchor: NSView?
  /// Closed by AppKit — a click elsewhere, Escape — rather than by `close`.
  var didClose: () -> Void = {}
  /// Opens the popover under the place given in a view. Tests keep it off the screen.
  var present: (NSPopover, NSView, NSRect) -> Void = { popover, view, place in
    popover.show(relativeTo: place, of: view, preferredEdge: .minY)
  }
  /// The workspace window's content, for a popover whose button is in no window. Tests give
  /// their own.
  var fallbackView: () -> NSView? = { NSApp.mainWindow?.contentView }
  /// Whether the button acts on a mouse up in its own window: the end of a click, perhaps the one
  /// that closed the popover. A press from the keyboard or VoiceOver, or an item of the toolbar's
  /// overflow menu, is never that click. Tests say so.
  var actsOnMouseUp: (() -> Bool)?
  /// The window's accessibility identifier, for the UI tests.
  var identifier: String?

  /// Popovers closing with their animation, kept alive until AppKit has put them away.
  private var fading: [NSPopover] = []
  /// When a click closed the popover, wherever it landed, by the events' clock; until the next
  /// click begins.
  private var closedByClickAt: TimeInterval?
  /// Every mouse down while a click that closed the popover is remembered.
  private nonisolated(unsafe) var clickMonitor: Any?

  deinit {
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
  }

  var isShown: Bool { popover != nil }

  /// Opens `content` under the button, or at the top trailing corner of the workspace window when
  /// the button is in no window — rather than a popover asked for and never shown. Returns whether
  /// it opened.
  @discardableResult
  func show(_ content: some View) -> Bool {
    close(animated: false)
    finishFading()
    guard let (view, place) = place() else { return false }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    let host = NSHostingController(rootView: content)
    host.sizingOptions = .preferredContentSize
    popover.contentViewController = host
    self.popover = popover
    present(popover, view, place)
    if let identifier {
      popover.contentViewController?.view.window?.setAccessibilityIdentifier(identifier)
    }
    return true
  }

  /// Puts the popover away. Without animation when another window takes its place: no fading copy
  /// beside its replacement. Its content goes with it — hidden but alive, an editor would still
  /// answer focus requests.
  func close(animated: Bool = true) {
    guard let popover else { return }
    finishFading()
    self.popover = nil
    if animated && popover.isShown {
      fading.append(popover)
      popover.close()
      return
    }
    finish(popover)
  }

  /// Gone at once, with its content.
  private func finish(_ popover: NSPopover) {
    popover.animates = false
    popover.delegate = nil
    popover.close()
    popover.contentViewController = nil
    // A button inside the popover closing it: the objects outlive the click.
    DispatchQueue.main.async { withExtendedLifetime(popover) {} }
  }

  /// The popovers still fading go at once: their editors must not answer the next one's focus
  /// requests.
  private func finishFading() {
    let fading = self.fading
    self.fading = []
    fading.forEach(finish)
  }

  /// The button's press: whether it ends the click that just closed the popover — the press then
  /// does nothing, the popover is already away.
  func pressEndsClosingClick() -> Bool {
    guard let closed = closedByClickAt else { return false }
    forgetClick()
    let mouseUp = actsOnMouseUp?() ?? isMouseUpInButtonWindow()
    return mouseUp && ProcessInfo.processInfo.systemUptime - closed < 1.5
  }

  private func isMouseUpInButtonWindow() -> Bool {
    guard let event = NSApp.currentEvent, event.type == .leftMouseUp,
      let window = anchor?.window
    else { return false }
    return event.window === window
  }

  private func place() -> (NSView, NSRect)? {
    if let anchor, anchor.window != nil { return (anchor, anchor.bounds) }
    guard let content = fallbackView() else { return nil }
    let bounds = content.bounds
    let place = NSRect(
      x: bounds.maxX - 48, y: content.isFlipped ? bounds.minY : bounds.maxY - 1, width: 28,
      height: 1)
    return (content, place)
  }

  // MARK: The click that closed the popover

  /// The transient popover closes on a click's mouse down, and the button acts on its mouse up.
  /// Where the click landed is not asked: the button's clickable area is wider than any view
  /// under it, and only the button acts on that mouse up.
  func closedByClick(at timestamp: TimeInterval) {
    closedByClickAt = timestamp
    guard clickMonitor == nil else { return }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      let timestamp = event.timestamp
      MainActor.assumeIsolated { self?.clickBegan(at: timestamp) }
      return event
    }
  }

  /// Another click began: the one that closed the popover is over, and the button acts again.
  func clickBegan(at timestamp: TimeInterval) {
    guard let closed = closedByClickAt, timestamp > closed else { return }
    forgetClick()
  }

  private func forgetClick() {
    closedByClickAt = nil
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
  }

  // MARK: NSPopoverDelegate

  /// Closed by AppKit, not by `close`, which lets go of the popover first. Its owner hears it at
  /// once rather than after the fade: in between, the popover is no longer shown.
  func popoverWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSPopover, closing === popover else { return }
    if let event = NSApp.currentEvent, event.type == .leftMouseDown {
      closedByClick(at: event.timestamp)
    }
    popover = nil
    fading.append(closing)
    didClose()
  }

  func popoverDidClose(_ notification: Notification) {
    guard let closed = notification.object as? NSPopover else { return }
    closed.delegate = nil
    closed.contentViewController = nil
    fading.removeAll { $0 === closed }
    // Closed without its will-close notice: its owner still hears of it.
    guard closed === popover else { return }
    popover = nil
    didClose()
  }
}

/// A stable native view behind a toolbar button, under which its popover opens. Handed to its
/// owner each time it enters a window; `left` when it leaves it — the button gone from the
/// toolbar, or folded into its overflow menu.
struct ToolbarPopoverAnchor: NSViewRepresentable {
  let entered: (NSView) -> Void
  var left: () -> Void = {}

  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView()
    view.entered = entered
    view.left = left
    return view
  }

  func updateNSView(_ view: AnchorView, context: Context) {
    view.entered = entered
    view.left = left
  }

  final class AnchorView: NSView {
    var entered: ((NSView) -> Void)?
    var left: (() -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else {
        left?()
        return
      }
      Task { @MainActor [weak self] in
        guard let self, self.window != nil else { return }
        self.entered?(self)
      }
    }
  }
}
