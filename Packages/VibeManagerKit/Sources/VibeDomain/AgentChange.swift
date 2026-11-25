import Foundation

/// One time a session was moved to another agent or another model.
///
/// The configuration it left is kept whole, resume identifier included: that is what lets a
/// failed switch put the session back exactly as it was, lets the transcripts of every agent that
/// worked here still be read, and lets the history say who did what. Nothing about the text handed
/// over is kept but its size — it can be rebuilt, and the store keeps no text sent to an agent.
public struct AgentChange: Identifiable, Hashable, Codable, Sendable {
  /// What the next agent was given to pick the work up.
  public enum Handover: Hashable, Codable, Sendable {
    /// Same agent, another model: its own conversation went on, and no text was sent.
    case resumedConversation
    /// A new conversation, started with a summary of the session.
    case summary(byteCount: Int, isTruncated: Bool, wasEdited: Bool)
    /// A new conversation, instructed to read durable copies of the native conversation logs.
    case conversationHistory(byteCount: Int)
    /// The session had never run: the next agent was given the prompt it was created with.
    case initialPrompt
    /// A new conversation, told nothing.
    case nothing
  }

  public enum Outcome: Hashable, Codable, Sendable {
    case completed
    /// The next agent never ran, and the session was put back on the previous one.
    case failed(reason: String)

    public var isFailure: Bool {
      if case .failed = self { return true }
      return false
    }
  }

  /// Why the session was moved, when the user did not ask for it.
  public enum Cause: Hashable, Codable, Sendable {
    /// The account the session ran on reached its limit, and the session went on with the next
    /// account of the backup chain (#600). `resetsAt` is when the limit lifts, when it is known.
    case accountLimit(resetsAt: Date?)
  }

  public let id: UUID
  public let date: Date
  public let previous: SessionAgentConfiguration
  public let next: SessionAgentConfiguration
  public let handover: Handover
  public internal(set) var outcome: Outcome
  /// `nil` for a switch the user made.
  public let cause: Cause?

  public init(
    id: UUID = UUID(),
    date: Date,
    previous: SessionAgentConfiguration,
    next: SessionAgentConfiguration,
    handover: Handover,
    outcome: Outcome = .completed,
    cause: Cause? = nil
  ) {
    self.id = id
    self.date = date.storageRounded
    self.previous = previous
    self.next = next
    self.handover = handover
    self.outcome = outcome
    switch cause {
    case .accountLimit(let resetsAt?): self.cause = .accountLimit(resetsAt: resetsAt.storageRounded)
    default: self.cause = cause
    }
  }

  /// Whether the agent it left had actually worked: a switch made before the session ever ran
  /// handed over its initial prompt, and the agent it left never started.
  public var leftAgentThatRan: Bool {
    outcome == .completed && handover != .initialPrompt
  }

  /// Whether the provider changed, rather than only the model.
  public var changesProvider: Bool {
    previous.providerID != next.providerID
  }
}

public enum AgentSwitchError: Error, Equatable, Sendable {
  /// Only a session whose agent is stopped can be given another one.
  case notClosed(SessionStatus)
  case noAgent
  /// The same agent and the same model: there is nothing to switch to.
  case nothingToChange
  /// Only the last switch can be undone, and only once.
  case notRevertible
}
