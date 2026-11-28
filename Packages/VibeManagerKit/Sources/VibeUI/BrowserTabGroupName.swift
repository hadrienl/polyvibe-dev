import Foundation
import VibeDomain

/// What the sidebar calls a group (#666): the name the user gave or Apple Intelligence made,
/// else « Group N », N given when the group was made.
enum BrowserTabGroupName {
  static func shown(_ group: BrowserTabGroup) -> String {
    guard group.name.isEmpty else { return group.name }
    return String(
      localized: "Group \(group.number)", bundle: .module,
      comment: "A group of web tabs not named yet: its number in the session.")
  }

  /// « 3 tabs », to VoiceOver.
  static func count(_ count: Int) -> String {
    String(
      localized: "\(count) tabs", bundle: .module,
      comment: "How many tabs a group of web tabs holds.")
  }
}
