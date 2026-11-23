import AppKit
import Testing

@testable import VibeConversationUI

/// No bubble over an open menu (#575), however many of its submenus open and close.
@MainActor
@Suite("Tooltips while a menu is open")
struct TooltipMenuTests {
  @Test("A submenu that closes leaves its menu open: no bubble until the menu closes too")
  func submenuClosingKeepsTheMenuOpen() {
    let presenter = TooltipPresenter.shared
    let menu = NSMenu(), submenu = NSMenu()
    defer {
      presenter.menuEnded(ObjectIdentifier(submenu))
      presenter.menuEnded(ObjectIdentifier(menu))
    }

    presenter.menuBegan(ObjectIdentifier(menu))
    presenter.menuBegan(ObjectIdentifier(submenu))
    presenter.menuEnded(ObjectIdentifier(submenu))
    #expect(presenter.isMenuOpen)

    presenter.menuEnded(ObjectIdentifier(menu))
    #expect(!presenter.isMenuOpen)
  }
}
