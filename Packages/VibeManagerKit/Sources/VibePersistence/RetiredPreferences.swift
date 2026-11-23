import Foundation

/// Preferences whose screens are gone, taken out of the user defaults at launch. A layout written
/// by an older build reads past the right column's keys (#578); these keys stood on their own, and
/// would otherwise stay there for good. Removing a key already gone does nothing: after the first
/// launch, nothing is left to remove.
public enum RetiredPreferences {
  public static let keys = [
    // The editor files changed in the Git pane opened with (#14), gone with the column (#578).
    "inspector.fileOpening.editor.v1",
    // Whether the sessions were summarized (#36), gone with the summaries (#572).
    "journal.summaries.enabled.v1",
  ]

  public static func remove(suiteName: String? = nil) {
    let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    for key in keys { defaults.removeObject(forKey: key) }
  }
}
