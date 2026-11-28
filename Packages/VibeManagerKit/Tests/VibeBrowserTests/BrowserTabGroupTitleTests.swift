import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeBrowser

/// A titler that answers what it is told, and remembers what it was asked: the real model never
/// runs in tests (#666).
private final class FakeTitler: BrowserTabGroupTitler, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [String?]
  private var asked: [[BrowserTabGroupTitlePage]] = []

  init(_ answers: [String?]) {
    self.answers = answers
  }

  var requests: [[BrowserTabGroupTitlePage]] {
    lock.withLock { asked }
  }

  func title(for pages: [BrowserTabGroupTitlePage]) async -> String? {
    lock.withLock {
      asked.append(pages)
      return answers.isEmpty ? nil : answers.removeFirst()
    }
  }
}

/// Groups named from their tabs on this Mac, else « Group N » (#666).
@Suite("Names of web tab groups")
@MainActor
struct BrowserTabGroupTitleTests {
  private let session = SessionID()

  private func page(_ name: String) -> URL {
    URL(string: "https://example.com/\(name)?token=secret")!
  }

  private func workspace(_ titler: FakeTitler) -> BrowserWorkspace {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    workspace.groupTitler = titler
    return workspace
  }

  @Test("A name is asked when the group is made, once more at four tabs, and never again")
  func askedAtTwoAndFour() async throws {
    let titler = FakeTitler(["Release notes", "Polyvibe release"])
    let workspace = workspace(titler)
    let opener = workspace.open(page("a"), in: session, openedBy: .user)
    workspace.open(page("b"), in: session, openedBy: .user, activate: false, from: opener.id)
    let browser = workspace.browser(for: session)
    await browser.titlesSettled()
    let group = try #require(browser.group(of: opener.id))
    #expect(titler.requests.count == 1)
    #expect(browser.groups.first?.name == "Release notes")
    #expect(browser.groups.first?.nameSource == .generated)

    workspace.open(page("c"), in: session, openedBy: .user, activate: false, from: opener.id)
    await browser.titlesSettled()
    #expect(titler.requests.count == 1)
    workspace.open(page("d"), in: session, openedBy: .user, activate: false, from: opener.id)
    await browser.titlesSettled()
    #expect(titler.requests.count == 2)
    #expect(titler.requests.last?.count == 4)
    #expect(browser.group(of: opener.id)?.name == "Polyvibe release")
    for name in ["e", "f"] {
      workspace.open(page(name), in: session, openedBy: .user, activate: false, from: opener.id)
    }
    await browser.titlesSettled()
    #expect(titler.requests.count == 2)
    #expect(browser.group(of: opener.id)?.id == group.id)
  }

  @Test("The model reads the hosts and paths of the tabs, never their query")
  func noQuery() async throws {
    let titler = FakeTitler([nil])
    let workspace = workspace(titler)
    let opener = workspace.open(page("a"), in: session, openedBy: .user)
    workspace.open(page("b"), in: session, openedBy: .user, activate: false, from: opener.id)
    await workspace.browser(for: session).titlesSettled()
    let pages = try #require(titler.requests.first)
    #expect(pages.map(\.host) == ["example.com", "example.com"])
    #expect(pages.map(\.path) == ["/a", "/b"])
    #expect(!pages.contains { $0.title.contains("secret") || $0.path.contains("secret") })
  }

  @Test("A name the user gave is never replaced, even once the group has four tabs")
  func userNameStays() async throws {
    let titler = FakeTitler(["Made up", "Made up again"])
    let workspace = workspace(titler)
    let opener = workspace.open(page("a"), in: session, openedBy: .user)
    workspace.open(page("b"), in: session, openedBy: .user, activate: false, from: opener.id)
    let browser = workspace.browser(for: session)
    await browser.titlesSettled()
    let group = try #require(browser.group(of: opener.id))
    browser.renameGroup(group.id, to: "Mine")
    for name in ["c", "d"] {
      workspace.open(page(name), in: session, openedBy: .user, activate: false, from: opener.id)
    }
    await browser.titlesSettled()
    #expect(titler.requests.count == 1)
    #expect(browser.group(of: opener.id)?.name == "Mine")
    #expect(browser.group(of: opener.id)?.nameSource == .user)
  }

  @Test("An answer that repeats a tab's title, is empty or too long leaves « Group N »")
  func rejectedAnswers() async throws {
    for answer in ["  example.com  ", "", String(repeating: "x", count: 33)] {
      let titler = FakeTitler([answer])
      let workspace = workspace(titler)
      let opener = workspace.open(page("a"), in: session, openedBy: .user)
      workspace.open(page("b"), in: session, openedBy: .user, activate: false, from: opener.id)
      let browser = workspace.browser(for: session)
      await browser.titlesSettled()
      let group = try #require(browser.group(of: opener.id))
      #expect(group.name.isEmpty)
      #expect(group.nameSource == .placeholder)
      #expect(group.displayName == "Group 1")
    }
  }

  @Test("A group keeps its number whatever closes around it, and after a relaunch")
  func stableNumbers() async throws {
    let store = InMemoryBrowserStateStore()
    _ = NSApplication.shared
    let first = BrowserWorkspace(stateStore: store)
    let browser = await first.restoredBrowser(for: session)
    let a = first.open(page("a"), in: session, openedBy: .user)
    first.open(page("a2"), in: session, openedBy: .user, activate: false, from: a.id)
    let b = first.open(page("b"), in: session, openedBy: .user, activate: false)
    first.open(page("b2"), in: session, openedBy: .user, activate: false, from: b.id)
    #expect(browser.group(of: a.id)?.number == 1)
    #expect(browser.group(of: b.id)?.number == 2)
    first.closeGroup(try #require(browser.group(of: a.id)).id, in: session)
    #expect(browser.group(of: b.id)?.number == 2)
    let c = first.open(page("c"), in: session, openedBy: .user, activate: false)
    first.open(page("c2"), in: session, openedBy: .user, activate: false, from: c.id)
    #expect(browser.group(of: c.id)?.number == 3)
    await store.save(browser.persisted, for: session)

    let second = BrowserWorkspace(stateStore: store)
    let restored = await second.restoredBrowser(for: session)
    #expect(restored.groups.map(\.number) == browser.groups.map(\.number))
    let d = second.open(page("d"), in: session, openedBy: .user, activate: false)
    second.open(page("d2"), in: session, openedBy: .user, activate: false, from: d.id)
    #expect(restored.group(of: d.id)?.number == 4)
  }
}
