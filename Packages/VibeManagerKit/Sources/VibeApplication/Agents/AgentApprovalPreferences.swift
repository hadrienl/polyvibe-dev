import VibeDomain

/// The approval mode of each native agent and account that offers one, under its identifier.
/// Endpoints keep their own definition.
@MainActor
public protocol AgentApprovalPreferences: AnyObject, Sendable {
  func mode(for provider: AgentProviderID) -> AgentApprovalMode
  func setMode(_ mode: AgentApprovalMode, for provider: AgentProviderID)
}

@MainActor
public final class InMemoryAgentApprovalPreferences: AgentApprovalPreferences {
  private var modes: [AgentProviderID: AgentApprovalMode]

  public init(
    mode: AgentApprovalMode = .manual, provider: AgentProviderID = AgentProviderID("codex")
  ) {
    modes = [provider: mode]
  }

  public func mode(for provider: AgentProviderID) -> AgentApprovalMode {
    modes[provider] ?? .manual
  }

  public func setMode(_ mode: AgentApprovalMode, for provider: AgentProviderID) {
    modes[provider] = mode
  }
}
