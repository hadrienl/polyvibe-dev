/// Describes a coding agent and how to launch it, without ever creating a process.
///
/// Building a process belongs to the terminal runtime: a provider only produces values, which
/// keeps every provider testable without a real CLI, a real account or a real shell.
public protocol AgentProvider: Sendable {
  var descriptor: AgentDescriptor { get }
  func availability(forceRefresh: Bool) async -> AgentAvailability
  func models() async -> [AgentModel]
  /// What the aliases the CLI accepts — `opus` — stand for, as the agent is configured, keyed in
  /// lowercase (#575). An alias left out stands for the newest model its catalogue lists of the
  /// family, `AgentModel.shortName`: the CLI's own default.
  func modelAliases() async -> [String: AgentModelAlias]
  func launchPlan(for request: AgentLaunchRequest) async throws -> AgentLaunchPlan
}

extension AgentProvider {
  public func availability() async -> AgentAvailability {
    await availability(forceRefresh: false)
  }

  /// No configuration of its own: every alias is the catalogue's.
  public func modelAliases() async -> [String: AgentModelAlias] { [:] }
}

/// What a model alias stands for when the agent's configuration says it (#575).
public enum AgentModelAlias: Hashable, Sendable {
  /// Configured to name this model, listed by the catalogue or not.
  case model(String)
  /// What it names cannot be read from here — a cloud provider's own identifiers, for one. The
  /// alias is shown as it is rather than a model guessed.
  case unknown
}

/// Extension point for #5 and #6: reading the resume identifier an agent prints while running.
public protocol AgentResumeIdentifierExtractor: Sendable {
  func resumeIdentifier(in chunk: String) -> String?
}

/// Read only access to the provider registry, so use cases never depend on `VibeAgents`.
public protocol AgentProviderResolving: Sendable {
  func descriptors() async -> [AgentDescriptor]
  func provider(id: AgentProviderID) async -> (any AgentProvider)?
  func availabilities(forceRefresh: Bool) async -> [AgentProviderID: AgentAvailability]
}

extension AgentProviderResolving {
  public func availabilities() async -> [AgentProviderID: AgentAvailability] {
    await availabilities(forceRefresh: false)
  }
}
