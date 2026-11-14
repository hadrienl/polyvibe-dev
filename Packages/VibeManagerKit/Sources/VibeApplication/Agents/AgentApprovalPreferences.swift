import VibeDomain

/// Independent modes for native agents and accounts. Endpoints keep their own definition.
@MainActor
public protocol AgentApprovalPreferences: AnyObject, Sendable {
  func mode(for provider: AgentProviderID) -> AgentApprovalMode
  func setMode(_ mode: AgentApprovalMode, for provider: AgentProviderID)
}

public typealias CodexApprovalPreferences = AgentApprovalPreferences

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

public typealias InMemoryCodexApprovalPreferences = InMemoryAgentApprovalPreferences
