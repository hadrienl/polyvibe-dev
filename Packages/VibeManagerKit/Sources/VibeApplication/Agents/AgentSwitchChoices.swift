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
    /// Empty when the catalogue has not answered, or lists nothing.
    public let models: [AgentModel]

    public init(descriptor: AgentDescriptor, availability: AgentAvailability, models: [AgentModel])
    {
      self.descriptor = descriptor
      self.availability = availability
      self.models = models
    }

    public var id: AgentProviderID { descriptor.id }
    public var name: String { descriptor.displayName }
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

  /// Reads the registry: its agents, whether each can run, and each one's models.
  public static func read(
    from registry: any AgentProviderResolving, forceRefresh: Bool = false
  ) async -> AgentSwitchChoices {
    let descriptors = await registry.descriptors()
    let availabilities = await registry.availabilities(forceRefresh: forceRefresh)
    var agents: [Agent] = []
    for descriptor in descriptors {
      guard let availability = availabilities[descriptor.id] else { continue }
      let models = await registry.provider(id: descriptor.id)?.models() ?? []
      agents.append(Agent(descriptor: descriptor, availability: availability, models: models))
    }
    return AgentSwitchChoices(agents: agents)
  }

  /// The agents a switch can go to now: the ones that can run.
  public var offered: [Agent] {
    agents.filter(\.availability.isUsable)
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
    var choices = agent.models.map { model in
      Choice(
        target: AgentTarget(providerID: providerID, modelID: model.id),
        modelName: model.displayName,
        isCurrent: current?.providerID == providerID && current?.modelID == model.id)
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
          modelName: current.modelID, isCurrent: true))
    }
    return choices
  }
}
