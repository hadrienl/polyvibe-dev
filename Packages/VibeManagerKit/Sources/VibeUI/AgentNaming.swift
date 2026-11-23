import VibeDomain

/// An agent as people read it (#247): the name of its provider — "Claude Code", not
/// "claude-code" — and its identifier only when no detected agent goes by it any more.
enum AgentNaming {
  static func name(of providerID: String, names: [String: String]) -> String {
    names[providerID] ?? providerID
  }
}
