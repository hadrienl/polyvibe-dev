import Foundation
import VibeDomain

/// A resource of a session named in words (#36): what Open Quickly reads and says of it.
enum ResourceNaming {
  static func isMergeRequest(_ resource: SessionResource) -> Bool {
    resource.key.hasPrefix("gitlab:") && resource.kind == .pullRequest
  }

  /// The involvement in words, agreeing with the resource in languages where it must.
  static func involvement(_ resource: SessionResource) -> String {
    switch (resource.kind, resource.involvement) {
    case (.issue, .created):
      return String(
        localized: "involvement.issue.created", defaultValue: "created", bundle: .module)
    case (.issue, .changed):
      return String(
        localized: "involvement.issue.changed", defaultValue: "changed", bundle: .module)
    case (.issue, .viewed):
      return String(localized: "involvement.issue.viewed", defaultValue: "viewed", bundle: .module)
    case (.pullRequest, .created):
      return String(
        localized: "involvement.request.created", defaultValue: "created", bundle: .module)
    case (.pullRequest, .changed):
      return String(
        localized: "involvement.request.changed", defaultValue: "changed", bundle: .module)
    case (.pullRequest, .viewed):
      return String(
        localized: "involvement.request.viewed", defaultValue: "viewed", bundle: .module)
    case (.branch, .created):
      return String(
        localized: "involvement.branch.created", defaultValue: "created", bundle: .module)
    case (.branch, .changed):
      return String(
        localized: "involvement.branch.changed", defaultValue: "changed", bundle: .module)
    case (.branch, .viewed):
      return String(
        localized: "involvement.branch.viewed", defaultValue: "checked out", bundle: .module)
    case (.worktree, .created):
      return String(
        localized: "involvement.worktree.created", defaultValue: "created", bundle: .module)
    case (.worktree, .changed):
      return String(
        localized: "involvement.worktree.changed", defaultValue: "worked in", bundle: .module)
    case (.worktree, .viewed):
      return String(
        localized: "involvement.worktree.viewed", defaultValue: "visited", bundle: .module)
    }
  }

  /// What VoiceOver reads: "Pull request #62, hadrienl/vibe-manager, created".
  static func spokenLabel(_ resource: SessionResource) -> String {
    [spokenName(resource), resource.context, involvement(resource)].compactMap { $0 }.joined(
      separator: ", ")
  }

  /// A resource named with its kind: "Pull request #62", "Branch feat/36-journal".
  static func spokenName(_ resource: SessionResource) -> String {
    let label = resource.label
    switch resource.kind {
    case .issue:
      return String(
        localized: "Issue \(label)", bundle: .module, comment: "A ticket's short name: #36.")
    case .pullRequest where isMergeRequest(resource):
      return String(
        localized: "Merge request \(label)", bundle: .module, comment: "A request's short name.")
    case .pullRequest:
      return String(
        localized: "Pull request \(label)", bundle: .module, comment: "A request's short name.")
    case .branch:
      return String(
        localized: "Branch \(label)", bundle: .module, comment: "A branch's name.")
    case .worktree:
      return String(
        localized: "Worktree \(label)", bundle: .module, comment: "A worktree's folder name.")
    }
  }

}
