import Foundation
import VibeDomain

/// The agents and models a session can be switched to (#575), read from the registry: the list
/// the Switch Agent sheet offers, and the one the status bar's menu offers, in the same order.
///
/// Read when it is needed, and kept by no one: an agent installed or signed in since is there the
/// next time.
public struct AgentSwitchChoices: Equatable, Sendable {
  /// One registered agent, its availability, and the models its catalogue lists.
  public struct Agent: Equatable, Sendable, Identifiable {
    public let descriptor: AgentDescriptor
    public let availability: AgentAvailability
    /// Empty when the catalogue has not answered, or lists nothing — and for an agent that cannot
    /// run, whose catalogue is not read.
    public let models: [AgentModel]
    /// What the agent's configuration makes of its aliases, keyed in lowercase.
    public let aliases: [String: AgentModelAlias]

    public init(
      descriptor: AgentDescriptor, availability: AgentAvailability, models: [AgentModel],
      aliases: [String: AgentModelAlias] = [:]
    ) {
      self.descriptor = descriptor
      self.availability = availability
      self.models = models
      self.aliases = aliases
    }

    public var id: AgentProviderID { descriptor.id }
    public var name: String { descriptor.displayName }

    /// What its catalogue and its configuration make of a model's identifier, or of an alias.
    public var catalogue: AgentCatalogue {
      AgentCatalogue(models: models, aliases: aliases)
    }

    /// The model `id` names, an alias resolved: see `AgentCatalogue.model(named:)`.
    public func model(named id: String?) -> AgentModel? {
      catalogue.model(named: id)
    }
  }

  /// One entry of the menu: an agent and a model, `modelID == nil` for the agent's own default.
  public struct Choice: Equatable, Sendable, Identifiable {
    public let target: AgentTarget
    /// The model's name as its catalogue gives it, or its identifier. `nil` for the default model.
    public let modelName: String?
    /// The agent and model the session runs now.
    public let isCurrent: Bool

    public init(target: AgentTarget, modelName: String?, isCurrent: Bool) {
      self.target = target
      self.modelName = modelName
      self.isCurrent = isCurrent
    }

    public var id: AgentTarget { target }
  }

  /// Every registered agent with an availability, in registration order, the ones that cannot run
  /// included: the sheet lists them all, and says why one cannot run.
  public let agents: [Agent]

  public init(agents: [Agent]) {
    self.agents = agents
  }

  /// Reads the registry: its agents, whether each can run, and the models of each one that can.
  /// The catalogues are read side by side: one that is slow to answer — a CLI asked for its
  /// models — holds the list back no longer than itself.
  ///
  /// `availabilities`, when the caller has just detected the agents, are used rather than asked
  /// for again.
  public static func read(
    from registry: any AgentProviderResolving,
    availabilities known: [AgentProviderID: AgentAvailability]? = nil, forceRefresh: Bool = false
  ) async -> AgentSwitchChoices {
    let descriptors = await registry.descriptors()
    let availabilities: [AgentProviderID: AgentAvailability]
    if let known {
      availabilities = known
    } else {
      availabilities = await registry.availabilities(forceRefresh: forceRefresh)
    }
    let usable = descriptors.filter { availabilities[$0.id]?.isUsable == true }.map(\.id)
    typealias Catalogue = (models: [AgentModel], aliases: [String: AgentModelAlias])
    let catalogues = await withTaskGroup(of: (AgentProviderID, Catalogue).self) { group in
      for id in usable {
        group.addTask {
          let provider = await registry.provider(id: id)
          return (id, (await provider?.models() ?? [], await provider?.modelAliases() ?? [:]))
        }
      }
      var catalogues: [AgentProviderID: Catalogue] = [:]
      for await (id, catalogue) in group { catalogues[id] = catalogue }
      return catalogues
    }
    let agents = descriptors.compactMap { descriptor in
      availabilities[descriptor.id].map {
        Agent(
          descriptor: descriptor, availability: $0,
          models: catalogues[descriptor.id]?.models ?? [],
          aliases: catalogues[descriptor.id]?.aliases ?? [:])
      }
    }
    return AgentSwitchChoices(agents: agents)
  }

  /// The agents a switch can go to now: the ones that can run.
  public var offered: [Agent] {
    agents.filter(\.availability.isUsable)
  }

  /// Each agent's models by identifier, to their names: how a model the session ran is named.
  /// An alias — `opus` — is named after the model it stands for, when that can be known.
  public var modelNames: [String: [String: String]] {
    Dictionary(
      agents.map { agent in
        (agent.id.rawValue, agent.catalogue.names)
      }, uniquingKeysWith: { a, _ in a })
  }

  public func agent(_ providerID: String) -> Agent? {
    agents.first { $0.id.rawValue == providerID }
  }

  /// The models offered for `agent`, the one the session runs checked. An agent whose catalogue
  /// has not answered is offered alone, with its default model. The session's own model is
  /// offered even when the catalogue no longer lists it, as the sheet does.
  public func choices(
    for agent: Agent, current: SessionAgentConfiguration?
  ) -> [Choice] {
    let providerID = agent.id.rawValue
    // The model the session runs, an alias resolved: `opus` checks the newest Opus.
    let running =
      current?.providerID == providerID ? agent.model(named: current?.modelID)?.id : nil
    var choices = agent.models.map { model in
      Choice(
        target: AgentTarget(providerID: providerID, modelID: model.id),
        modelName: model.displayName,
        isCurrent: running == model.id)
    }
    if choices.isEmpty {
      choices.append(
        Choice(
          target: AgentTarget(providerID: providerID), modelName: nil,
          isCurrent: current?.providerID == providerID && current?.modelID == nil))
    }
    if let current, current.providerID == providerID, !choices.contains(where: \.isCurrent) {
      choices.append(
        Choice(
          target: AgentTarget(providerID: providerID, modelID: current.modelID),
          modelName: agent.model(named: current.modelID)?.displayName ?? current.modelID,
          isCurrent: true))
    }
    return choices
  }
}

/// An agent's models and what its configuration makes of its aliases (#575): how a model a
/// session runs — an identifier, or an alias such as `opus` — is named, wherever it is named.
public struct AgentCatalogue: Equatable, Sendable {
  public let models: [AgentModel]
  /// Keyed in lowercase.
  public let aliases: [String: AgentModelAlias]

  public init(models: [AgentModel], aliases: [String: AgentModelAlias] = [:]) {
    self.models = models
    self.aliases = aliases
  }

  /// The model `id` names: itself; for an alias, the model the agent's configuration gives it —
  /// listed by the catalogue or not — or else the newest of its family, `opus` being Claude
  /// Code's newest Opus. `nil` when what an alias names cannot be known: no model is invented.
  public func model(named id: String?) -> AgentModel? {
    guard let id else { return nil }
    if let model = models.first(where: { $0.id == id }) { return model }
    switch aliases[id.lowercased()] {
    case .model(let configured):
      return models.first { $0.id == configured }
        ?? AgentModel(id: configured, displayName: configured)
    case .unknown:
      return nil
    case nil:
      // The catalogue lists the newest first.
      return models.first { $0.shortName?.lowercased() == id.lowercased() }
    }
  }

  /// Each model's name by its identifier, and each alias's by the model it stands for; an alias
  /// whose model cannot be known is left out, to be shown as it is. A real identifier is never
  /// renamed by an alias.
  public var names: [String: String] {
    let aliases = Set(models.compactMap { $0.shortName?.lowercased() }).union(self.aliases.keys)
    let aliasNames = Dictionary(
      aliases.compactMap { alias in model(named: alias).map { (alias, $0.displayName) } },
      uniquingKeysWith: { first, _ in first })
    return aliasNames.merging(
      models.map { ($0.id, $0.displayName) }, uniquingKeysWith: { _, identifier in identifier })
  }
}
