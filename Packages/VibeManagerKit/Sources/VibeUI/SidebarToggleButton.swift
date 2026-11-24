import AppKit
import SwiftUI
import VibeConversationUI

/// The sidebar's button, in place of the system's: the same action, sent the same way so that the
/// split view folds the column as it always did, but with the application's tooltip rather than
/// the system's help tag, which came seconds later and looked like no other.
private struct SidebarToggleButton: View {
  let isSidebarVisible: Bool

  var body: some View {
    let title =
      isSidebarVisible
      ? Text("Hide Sidebar", bundle: .module, comment: "The toolbar button that folds the sidebar.")
      : Text(
        "Show Sidebar", bundle: .module, comment: "The toolbar button that unfolds the sidebar.")
    Button {
      NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    } label: {
      Label {
        title
      } icon: {
        Image(systemName: "sidebar.left")
      }
    }
    .toolbarTooltip(title)
  }
}

extension View {
  /// The system's sidebar button replaced by one that wears the application's tooltip, from macOS
  /// 26: where it was checked. Before it the system's stays, with its own help tag.
  @ViewBuilder
  func replacingSystemSidebarToggle(model: AppModel) -> some View {
    if #available(macOS 26, *) {
      toolbar(removing: .sidebarToggle)
        .toolbar { SidebarToggleToolbarItem(model: model) }
    } else {
      self
    }
  }
}

/// In the sidebar's part of the toolbar, where the system's button stood: against the sidebar's
/// right edge. The sidebar folded, the window keeps it beside the traffic lights: no second one is
/// needed to bring the sidebar back.
@available(macOS 26, *)
private struct SidebarToggleToolbarItem: ToolbarContent {
  let model: AppModel

  var body: some ToolbarContent {
    // Without it the button follows the traffic lights.
    ToolbarSpacer(.flexible)
    ToolbarItem(placement: .automatic) {
      SidebarToggleButton(isSidebarVisible: model.layout.columns.isSidebarVisible)
    }
  }
}
