import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// The overview's width, whatever width the conversation was shown at before (#567): a width
/// told before the web view came beside the messages once stayed, and the overview took half of
/// the pane, over the text.
@MainActor
@Suite(
  "The overview keeps to the margin of the pane it is in", .serialized, .timeLimit(.minutes(1)))
struct OverviewWidthTests {
  /// What the window holds a conversation with: a width held while the web view slides over it,
  /// or while it is hidden behind another session, as the window's column does.
  @MainActor @Observable final class Slot {
    var held: CGFloat?
    var isActive = true
  }

  private struct Host: View {
    let model: ConversationModel
    let slot: Slot

    var body: some View {
      ConversationView(
        model: model, theme: .systemDark, appearance: ConversationAppearance(),
        isActive: slot.isActive
      )
      .frame(width: slot.held)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .opacity(slot.isActive ? 1 : 0)
    }
  }

  private func host(width: CGFloat) -> (NSWindow, Slot) {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { _ in }
    model.processRunning = { true }
    model.apply(
      ConversationSnapshot(
        entries: (0..<200).map {
          ConversationEntry(
            id: "m\($0)",
            content: .agentText("Message \($0) " + String(repeating: "word ", count: 40)))
        }, availability: .available))
    let slot = Slot()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: Host(model: model, slot: slot))
    return (window, slot)
  }

  /// A bound that only stops a test that would hang: what is waited for is a state.
  private static let patience = Duration.seconds(10)

  /// Laid out until the overview is `width` wide. Says where it stands when the bound cuts it off.
  private func waitUntil(
    _ step: String, _ window: NSWindow, overviewIs width: Double
  ) async throws {
    let deadline = ContinuousClock.now + Self.patience
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      if overviewWidth(in: window) == width { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record(
      "\(step): the overview stayed \(overviewWidth(in: window).map { "\($0)" } ?? "absent"), not \(width)"
    )
    throw CancellationError()
  }

  /// The overview's width, from the view that takes its wheel: its frame is the overview's.
  private func overviewWidth(in window: NSWindow) -> Double? {
    func find(_ view: NSView) -> NSView? {
      if String(describing: type(of: view)).contains("Forwarder") { return view }
      return view.subviews.lazy.compactMap(find).first
    }
    return window.contentView.flatMap(find).map { Double($0.frame.width) }
  }

  /// Where the overview, the composer's field and the messages' texts are, in the window.
  private func frames(in window: NSWindow) -> (
    overview: CGRect?, composer: CGRect?, texts: [CGRect]
  ) {
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    let views = window.contentView.map(all) ?? []
    func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
    let overview = views.first { String(describing: type(of: $0)).contains("Forwarder") }
    let composer = views.first { ($0 as? NSTextView)?.isEditable == true }
    let texts = views.compactMap { $0 as? SegmentTextView }.filter { !$0.bounds.isEmpty }
    return (overview.map(frame), composer.map(frame), texts.map(frame))
  }

  /// The overview's width in a pane that wide, the conversation's theme and margins as they are.
  private func nominal(_ paneWidth: Double) -> Double { placement(paneWidth).width }

  private func placement(_ paneWidth: Double) -> ConversationOverviewLayout.Placement {
    let layout = ConversationTheme.systemDark.layout.at(ConversationAppearance().density)
    return ConversationOverviewLayout.placement(
      paneWidth: paneWidth, contentWidth: layout.contentWidth,
      leadingMargin: max(layout.sideMargin, BookmarkGutter.reach),
      trailingMargin: layout.sideMargin)
  }

  @Test("Wide, then narrowed by the web view held over it and let go, it keeps to the margin")
  func heldThenLetGo() async throws {
    let (window, slot) = host(width: 850)
    defer { window.close() }
    #expect(nominal(850) < nominal(1700))
    try await waitUntil("shown", window, overviewIs: nominal(850))
    slot.held = 1700
    try await waitUntil("held wide", window, overviewIs: nominal(1700))
    slot.held = nil
    try await waitUntil("let go", window, overviewIs: nominal(850))
  }

  @Test(
    "Hidden at the width it was shown at, then shown in a narrower pane, it keeps to the margin")
  func hiddenThenShownNarrower() async throws {
    let (window, slot) = host(width: 850)
    defer { window.close() }
    slot.isActive = false
    slot.held = 1700
    try await waitUntil("hidden wide", window, overviewIs: nominal(1700))
    slot.isActive = true
    slot.held = nil
    try await waitUntil("shown narrower", window, overviewIs: nominal(850))
  }

  @Test("A window narrowed takes the overview down to the margin it leaves")
  func windowNarrowed() async throws {
    let (window, _) = host(width: 1700)
    defer { window.close() }
    try await waitUntil("wide", window, overviewIs: nominal(1700))
    window.setContentSize(NSSize(width: 850, height: 800))
    try await waitUntil("narrowed", window, overviewIs: nominal(850))
  }

  @Test("Held wide then let go in a narrow pane, the messages and the composer leave it its room")
  func narrowPaneLeavesTheOverviewItsRoom() async throws {
    let (window, slot) = host(width: 850)
    defer { window.close() }
    // Narrow enough that the messages give up part of their width to the overview.
    #expect(placement(850).reserved > 0)
    slot.held = 1700
    try await waitUntil("held wide", window, overviewIs: nominal(1700))
    slot.held = nil
    try await waitUntil("let go", window, overviewIs: nominal(850))
    let laidOut = frames(in: window)
    let overview = try #require(laidOut.overview)
    let composer = try #require(laidOut.composer)
    #expect(composer.maxX <= overview.minX)
    #expect(!laidOut.texts.isEmpty)
    for text in laidOut.texts {
      #expect(text.maxX <= overview.minX)
    }
  }
}
