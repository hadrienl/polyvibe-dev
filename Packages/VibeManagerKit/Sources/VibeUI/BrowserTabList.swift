import SwiftUI
import VibeBrowser
import VibeDomain

// What the tab sidebar (#648) and the address bar share about a tab: its icon, its name, the badge
// of a page of this Mac.

/// Where a tab comes from: the ticket, an agent, a link of the terminal, or the user.
struct BrowserTabIcon: View {
  let tab: BrowserTabModel

  var body: some View {
    if tab.isLoading {
      ProgressView().controlSize(.mini)
    } else if tab.isPinnedTicket {
      Image(systemName: "ticket")
    } else if tab.openedBy == .agent {
      Image(systemName: "sparkle")
        .foregroundStyle(Color.accentColor)
        .padding(2)
        .background(
          Circle().fill(tab.isAgentActing ? Color.accentColor.opacity(0.25) : .clear))
    } else if tab.openedBy == .terminalLink {
      Image(systemName: "terminal")
    } else {
      Image(systemName: "globe")
    }
  }
}

/// What a tab is called, on screen and to VoiceOver.
enum BrowserTabTitle {
  /// An empty tab is a New Tab, never `about:blank`.
  @MainActor
  static func text(of tab: BrowserTabModel) -> Text {
    tab.isBlank && tab.title.isEmpty
      ? Text("New Tab", bundle: .module) : Text(verbatim: tab.displayTitle)
  }

  @MainActor
  static func accessibilityLabel(of tab: BrowserTabModel, in browser: SessionBrowser) -> Text {
    if tab.isPinnedTicket {
      return Text("Ticket tab, \(browser.ticket?.label ?? tab.displayTitle)", bundle: .module)
    }
    if tab.isAgentActing {
      return Text("\(tab.displayTitle), opened by the agent, the agent is acting", bundle: .module)
    }
    if tab.openedBy == .agent {
      return Text("\(tab.displayTitle), opened by the agent", bundle: .module)
    }
    return text(of: tab)
  }
}

/// A page of this Mac, which the agent may act on without asking.
struct BrowserLocalBadge: View {
  var body: some View {
    Text("LOCAL", bundle: .module, comment: "A badge in the address bar for a page of this Mac.")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .foregroundStyle(.green)
      .background(RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.12)))
      .instantTooltip(
        Text("A page of this Mac: the agent may act on it without asking.", bundle: .module))
  }
}
