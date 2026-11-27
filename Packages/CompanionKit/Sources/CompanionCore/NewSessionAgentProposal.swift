import Foundation

/// The agent the phone's New Session sheet puts for the folder chosen (#634): the one the Mac
/// would propose there, until the user picks an agent or a model.
public struct NewSessionAgentProposal: Hashable, Sendable {
  /// Whether choosing a folder still changes the agent.
  public private(set) var followsTheFolder: Bool

  /// A form that came back keeps what was sent, as if the user had picked it.
  public init(userChose: Bool = false) {
    followsTheFolder = !userChose
  }

  /// The agent to put for `folder`; `nil` leaves the one on the sheet. An agent the phone was not
  /// offered is ignored, as is a folder the Mac knows no agent for.
  public func agent(
    forFolder folder: String, options: RemoteNewSessionOptions,
    listings: [String: RemoteFolderListing] = [:]
  ) -> String? {
    guard followsTheFolder,
      let id = options.folderAgents?[folder] ?? listings[folder]?.agentID,
      options.agents.contains(where: { $0.id == id })
    else { return nil }
    return id
  }

  /// The user picked the agent or the model: the folder no longer changes them.
  public mutating func userChose() {
    followsTheFolder = false
  }
}
