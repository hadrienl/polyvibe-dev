import AppKit
import Foundation
import OSLog
import Testing
import VibeDomain
import WebKit

@testable import VibeBrowser

/// Pages made before WebKit lost its GPU process stay grey; they are given a new web view (#613).
@Suite("Pages after WebKit loses its GPU process")
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
    return workspace.browser(for: session).tabs.last!
  }

  @Test("A page on screen gets a new web view where the old one was, with the keyboard")
  func pageOnScreenIsReplacedInPlace() throws {
    let workspace = BrowserWorkspace()
    let tab = openTab("a", in: workspace)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: true)
    defer { window.close() }
    window.isReleasedWhenClosed = false
    let holder = try #require(window.contentView)
    let old = workspace.show(tab)
    old.removeFromSuperview()
    holder.addSubview(old)
    window.makeFirstResponder(old)

    workspace.replacePages(madeBefore: Date())

    let fresh = try #require(tab.webView)
    #expect(fresh !== old)
    #expect(old.superview == nil)
    #expect(fresh.superview === holder)
    #expect((window.firstResponder as? NSView)?.isDescendant(of: fresh) == true)
    #expect(fresh.navigationDelegate === tab)
  }

  @Test("A page off screen is let go, and loads again when shown")
  func parkedPageIsLetGo() {
    let workspace = BrowserWorkspace()
    let tab = openTab("a", in: workspace)
    #expect(tab.isLoaded)

    workspace.replacePages(madeBefore: Date())

    #expect(!tab.isLoaded)
    #expect(workspace.show(tab) === tab.webView)
    #expect(tab.isLoaded)
  }

  @Test("A page made after the loss is left alone")
  func laterPageIsKept() throws {
    let workspace = BrowserWorkspace()
    let loss = Date()
    let tab = openTab("a", in: workspace)
    let page = try #require(tab.webView)

    workspace.replacePages(madeBefore: loss.addingTimeInterval(-1))

    #expect(tab.webView === page)
  }

  @Test("The log is looked at when a session is shown, and the pages replaced")
  func sessionShownLooks() async {
    let log = ScriptedExitLog()
    let workspace = BrowserWorkspace()
    workspace.watchGPUProcess(log, afterScreenChange: [])
    let tab = openTab("a", in: workspace)
    log.exit = Date()

    workspace.sessionDidAppear(session)

    await waitUntil("the page let go") { !tab.isLoaded }
  }

  @Test("After the displays change, the log is looked at again until the loss shows")
  func screenChangeLooksAgain() async {
    let log = ScriptedExitLog()
    let workspace = BrowserWorkspace()
    workspace.watchGPUProcess(log, afterScreenChange: [.milliseconds(10), .milliseconds(20)])
    let tab = openTab("a", in: workspace)

    NotificationCenter.default.post(
      name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    await waitUntil("a first look") { log.looks >= 1 }
    #expect(tab.isLoaded)
    log.exit = Date()

    await waitUntil("the page let go") { !tab.isLoaded }
    #expect(log.looks >= 2)
  }

  @Test("Only a GPU process that quit for want of work leaves no page behind")
  func reasons() {
    let message = "GPUProcessProxy::gpuProcessExited: reason="
    #expect(OSLogGPUProcessExitLog.leavesPagesBlank(message + "Unresponsive"))
    #expect(OSLogGPUProcessExitLog.leavesPagesBlank(message + "Crash"))
    #expect(!OSLogGPUProcessExitLog.leavesPagesBlank(message + "IdleExit"))
  }

  @Test("The application's own log says when WebKit lost its GPU process")
  func readsOwnLog() async {
    let start = Date()
    Logger(subsystem: "com.apple.WebKit", category: "Process").log(
      "0x1 - GPUProcessProxy::gpuProcessExited: reason=Unresponsive")
    Logger(subsystem: "com.apple.WebKit", category: "Process").log(
      "0x2 - GPUProcessProxy::gpuProcessExited: reason=IdleExit")
    var found: Date?
    await waitUntil("the line in the log") {
      found = await OSLogGPUProcessExitLog().lastExit(since: start.addingTimeInterval(-1))
      return found != nil
    }
    #expect(found.map { $0 >= start.addingTimeInterval(-1) } == true)
  }
}

/// A log that says what the test tells it to, and counts the looks.
@MainActor
private final class ScriptedExitLog: GPUProcessExitLog {
  var exit: Date?
  var looks = 0

  nonisolated func lastExit(since date: Date) async -> Date? {
    await MainActor.run {
      looks += 1
      return exit.flatMap { $0 >= date ? $0 : nil }
    }
  }
}
