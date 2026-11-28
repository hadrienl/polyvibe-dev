import Foundation
import VibeApplication

/// What a group of the web view's sidebar is called, now that it shows no title (#666): how many
/// tabs it holds and the site they come from.
enum BrowserTabGroupSummary {
  /// The site of the group's first tab that has one: the page it was opened from, as a rule.
  static func site(of urls: [URL]) -> String? {
    for url in urls {
      guard let origin = BrowserOrigin(url: url), !origin.host.isEmpty else { continue }
      return origin.description
    }
    return nil
  }

  /// « 3 tabs », on a collapsed group's line.
  static func count(_ count: Int) -> String {
    String(
      localized: "\(count) tabs", bundle: .module,
      comment: "How many tabs a collapsed group of web tabs holds.")
  }

  /// What VoiceOver calls the group: « Group of 3 tabs, github.com ».
  static func accessibilityLabel(count: Int, site: String?) -> String {
    guard let site else {
      return String(
        localized: "Group of \(count) tabs", bundle: .module,
        comment: "VoiceOver's name of a group of web tabs whose site is unknown.")
    }
    return String(
      localized: "Group of \(count) tabs, \(site)", bundle: .module,
      comment: "VoiceOver's name of a group of web tabs: how many, and the site they come from.")
  }
}
