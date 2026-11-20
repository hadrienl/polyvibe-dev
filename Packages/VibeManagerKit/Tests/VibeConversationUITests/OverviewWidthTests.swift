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
@Suite("The overview keeps to the margin of the pane it is in", .serialized)
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

  private func settle(_ window: NSWindow) async {
    for _ in 0..<30 {
      window.layoutIfNeeded()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// The overview's width, from the view that takes its wheel: its frame is the overview's.
  private func overviewWidth(in window: NSWindow) -> Double? {
    func find(_ view: NSView) -> NSView? {
      if String(describing: type(of: view)).contains("Forwarder") { return view }
      return view.subviews.lazy.compactMap(find).first
    }
    return window.contentView.flatMap(find).map { Double($0.frame.width) }
  }

  /// The overview's width in a pane that wide, the conversation's theme and margins as they are.
  private func nominal(_ paneWidth: Double) -> Double {
    let layout = ConversationTheme.systemDark.layout.at(ConversationAppearance().density)
    return ConversationOverviewLayout.placement(
      paneWidth: paneWidth, contentWidth: layout.contentWidth,
      leadingMargin: max(layout.sideMargin, BookmarkGutter.reach),
      trailingMargin: layout.sideMargin
    ).width
  }

  @Test("Wide, then narrowed by the web view held over it and let go, it keeps to the margin")
  func heldThenLetGo() async throws {
    let (window, slot) = host(width: 850)
    defer { window.close() }
    await settle(window)
    slot.held = 1700
    await settle(window)
    #expect(try #require(overviewWidth(in: window)) == nominal(1700))
    slot.held = nil
    await settle(window)
    #expect(try #require(overviewWidth(in: window)) == nominal(850))
    #expect(nominal(850) < nominal(1700))
  }

  @Test(
    "Hidden at the width it was shown at, then shown in a narrower pane, it keeps to the margin")
  func hiddenThenShownNarrower() async throws {
    let (window, slot) = host(width: 850)
    defer { window.close() }
    slot.isActive = false
    slot.held = 1700
    await settle(window)
    slot.isActive = true
    slot.held = nil
    await settle(window)
    #expect(try #require(overviewWidth(in: window)) == nominal(850))
  }

  @Test("A window narrowed takes the overview down to the margin it leaves")
  func windowNarrowed() async throws {
    let (window, _) = host(width: 1700)
    defer { window.close() }
    await settle(window)
    #expect(try #require(overviewWidth(in: window)) == nominal(1700))
    window.setContentSize(NSSize(width: 850, height: 800))
    await settle(window)
    #expect(try #require(overviewWidth(in: window)) == nominal(850))
  }
}
