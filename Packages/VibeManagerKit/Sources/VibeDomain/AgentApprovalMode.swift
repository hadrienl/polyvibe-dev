/// The user's permission-review choice, mapped to each CLI's native policy.
public enum AgentApprovalMode: String, Codable, Hashable, Sendable, CaseIterable {
  case manual
  case autoReview
}

/// Compatibility for endpoint persistence and callers introduced with #543.
public typealias CodexApprovalMode = AgentApprovalMode
