import Foundation
import VibeApplication
import VibeDomain

@MainActor
public final class UserDefaultsAgentApprovalPreferences: AgentApprovalPreferences {
  private let defaults: UserDefaults
  private let namespace: String

  public init(suiteName: String? = nil, namespace: String = "codex") {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    self.namespace = namespace
  }

  public func mode(for provider: AgentProviderID) -> AgentApprovalMode {
    defaults.string(forKey: key(provider)).flatMap(AgentApprovalMode.init(rawValue:)) ?? .manual
  }

  public func setMode(_ mode: AgentApprovalMode, for provider: AgentProviderID) {
    defaults.set(mode.rawValue, forKey: key(provider))
  }

  private func key(_ provider: AgentProviderID) -> String {
    "\(namespace).approvalMode.\(provider.rawValue).v1"
  }
}

public typealias UserDefaultsCodexApprovalPreferences = UserDefaultsAgentApprovalPreferences
