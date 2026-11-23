import AppKit
import Foundation
import Testing
import VibeDomain
import WebKit

@testable import VibeBrowser

/// Pages left without WebKit's GPU process stay grey; they are given a new web view (#613).
@Suite("Pages that no longer draw")
@MainActor
struct GPUProcessRecoveryTests {
  private let session = SessionID()

  init() {
    _ = NSApplication.shared
  }

  private func openTab(_ page: String, in workspace: BrowserWorkspace) -> BrowserTabModel {
    workspace.open(
      URL(string: "data:text/html,<p>\(page)</p>")!, in: session, openedBy: .user,
      activate: false)
  }

  /// A window the page is shown in, out of the user's sight.
  private func screenWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    return window
  }

  private func putOnScreen(_ tab: BrowserTabModel, _ workspace: BrowserWorkspace, in window: NSWindow)
    -> WKWebView
  {
    let webView = workspace.show(tab)
    webView.removeFromSuperview()
    window.contentView?.addSubview(webView)
    return webView
  }

  @Test("A page on screen gets a new web view where the old one was, with the keyboard")
  func pageOnScreenIsReplacedInPlace() throws {
    let workspace = BrowserWorkspace()
    let tab = openTab("a", in: workspace)
    let window = screenWindow()
    defer { window.close() }
    let old = putOnScreen(tab, workspace, in: window)
    window.makeFirstResponder(old)

    tab.replaceWebView()

    let fresh = try #require(tab.webView)
    #expect(fresh !== old)
    #expect(old.superview == nil)
    #expect(fresh.superview === window.contentView)
    #expect((window.firstResponder as? NSView)?.isDescendant(of: fresh) == true)
    #expect(fresh.navigationDelegate === tab)
  }

  @Test("A page off screen is let go, and loads again when shown")
  func parkedPageIsLetGo() {
    let workspace = BrowserWorkspace()
    let tab = openTab("a", in: workspace)
    #expect(tab.isLoaded)

    tab.replaceWebView()

    #expect(!tab.isLoaded)
    #expect(workspace.show(tab) === tab.webView)
    #expect(tab.isLoaded)
  }

  @Test("A page on screen that does not draw has every page that does not draw replaced")
  func blankPageOnScreenReplacesTheBlankOnes() async throws {
    let probe = ScriptedProbe()
    let workspace = BrowserWorkspace()
    workspace.watchPageRendering(probe: probe, afterScreenChange: [])
    let shown = openTab("shown", in: workspace)
    let parkedBlank = openTab("parked-blank", in: workspace)
    let parkedFine = openTab("parked-fine", in: workspace)
    let window = screenWindow()
    defer { window.close() }
    let old = putOnScreen(shown, workspace, in: window)
    await workspace.checkRendering().value
    #expect(probe.asked.contains(ObjectIdentifier(old)))
    #expect(shown.webView === old)

    probe.blank = [shown.webView, parkedBlank.webView].compactMap { $0.map(ObjectIdentifier.init) }
    let kept = try #require(parkedFine.webView)
    await workspace.checkRendering().value

    #expect(shown.webView !== old)
    #expect(shown.webView?.superview === window.contentView)
    #expect(!parkedBlank.isLoaded)
    #expect(parkedFine.webView === kept)
  }

  @Test("Pages off screen are not looked at while the pages on screen draw")
  func onlyOnScreenFirst() async {
    let probe = ScriptedProbe()
    let workspace = BrowserWorkspace()
    workspace.watchPageRendering(probe: probe, afterScreenChange: [])
    let parked = openTab("parked", in: workspace)
    probe.blank = [parked.webView].compactMap { $0.map(ObjectIdentifier.init) }

    await workspace.checkRendering().value

    #expect(probe.asked.isEmpty)
    #expect(parked.isLoaded)
  }

  @Test("After the displays change, the pages are looked at again and again")
  func screenChangeLooksAgain() async {
    let probe = ScriptedProbe()
    let workspace = BrowserWorkspace()
    workspace.watchPageRendering(probe: probe, afterScreenChange: [.milliseconds(10), .seconds(1)])
    let tab = openTab("a", in: workspace)
    let window = screenWindow()
    defer { window.close() }
    let old = putOnScreen(tab, workspace, in: window)
    await waitUntil("the page looked at when shown") { probe.looks >= 1 }
    let looks = probe.looks

    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    await waitUntil("a first look after the change") { probe.looks > looks }
    #expect(tab.webView === old)
    probe.blank = [ObjectIdentifier(old)]

    await waitUntil("the page replaced at the next look") { tab.webView !== old }
  }

  @Test("A page that gives a picture of itself draws")
  func snapshotProbe() async {
    let workspace = BrowserWorkspace()
    let tab = openTab("a", in: workspace)
    let window = screenWindow()
    defer { window.close() }
    let webView = putOnScreen(tab, workspace, in: window)
    await tab.waitUntilSettled()

    #expect(await SnapshotRenderingProbe().draws(webView))
  }
}

/// A probe that says the pages it is told about do not draw, and counts what it is asked.
@MainActor
private final class ScriptedProbe: PageRenderingProbe {
  var blank: [ObjectIdentifier] = []
  var asked: Set<ObjectIdentifier> = []
  var looks = 0

  func draws(_ webView: WKWebView) async -> Bool {
    looks += 1
    asked.insert(ObjectIdentifier(webView))
    return !blank.contains(ObjectIdentifier(webView))
  }
}
