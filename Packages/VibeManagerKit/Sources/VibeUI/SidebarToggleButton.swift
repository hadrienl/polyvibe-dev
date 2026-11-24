import AppKit
import SwiftUI
import VibeConversationUI

/// The sidebar's button, in place of the system's: the same action, sent the same way so that the
/// split view folds the column as it always did, but with the application's tooltip rather than
/// the system's help tag, which came seconds later and looked like no other.
struct SidebarToggleButton: View {
  let isSidebarVisible: Bool

  var body: some View {
    let title =
      isSidebarVisible
      ? Text("Hide Sidebar", bundle: .module, comment: "The toolbar button that folds the sidebar.")
      : Text("Show Sidebar", bundle: .module, comment: "The toolbar button that unfolds the sidebar.")
    Button {
      NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    } label: {
      Label {
        title
      } icon: {
        Image(systemName: "sidebar.left")
      }
    }
    .instantTooltip(title)
  }
}

/// In the sidebar's part of the toolbar, where the system's button stood: against the sidebar's
/// right edge from macOS 26, beside the traffic lights before it.
struct SidebarToggleToolbarItem: ToolbarContent {
  var body: some ToolbarContent {
    if #available(macOS 26, *) {
      // Without it the button follows the traffic lights.
      ToolbarSpacer(.flexible)
    }
    ToolbarItem(placement: .automatic) {
      SidebarToggleButton(isSidebarVisible: true)
    }
  }
}
