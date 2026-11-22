import Foundation
import VibeDomain

/// What a line of an agent's transcript says, once read (#36): the same few things whichever CLI
/// wrote it.
public enum TranscriptEvent: Hashable, Sendable {
  /// Something the user asked, the first prompt and the summaries handed over on a restart
  /// included.
  case prompt(String, at: Date?)
  case toolCall(TranscriptToolCall)
  /// What a command that creates a resource printed: the only outputs ever read, since a
  /// `gh issue list` prints eighty tickets the agent did not use.
  case creationOutput(command: String, directory: String?, output: String, at: Date?)
  /// What the agent said.
  case agentText(String, at: Date?)
}

/// One call of a tool, as the journal needs it.
public struct TranscriptToolCall: Hashable, Sendable {
  /// The command line, for a tool that runs one.
  public var command: String?
  /// Where it ran.
  public var directory: String?
  /// The branch checked out there, when the transcript says so (Claude Code does).
  public var branch: String?
  /// Every other string of its input, searched for URLs.
  public var strings: [String]
  public var at: Date?

  public init(
    command: String? = nil, directory: String? = nil, branch: String? = nil,
    strings: [String] = [], at: Date? = nil
  ) {
    self.command = command
    self.directory = directory
    self.branch = branch
    self.strings = strings
    self.at = at
  }
}

/// The transcripts of a session read from where the last reading stopped.
public struct TranscriptReading: Sendable {
  /// Each conversation's events in order.
  public var events: [TranscriptEvent]
  /// Where the reading of each file stopped now.
  public var cursors: [String: TranscriptCursor]

  public init(events: [TranscriptEvent] = [], cursors: [String: TranscriptCursor] = [:]) {
    self.events = events
    self.cursors = cursors
  }
}

/// Reads a session's transcripts incrementally, from cursors the journal keeps.
public protocol SessionJournalReading: Sendable {
  func read(_ session: WorkSession, from cursors: [String: TranscriptCursor]) async
    -> TranscriptReading
  /// The folders whose changes may concern the session's transcripts.
  func transcriptDirectories(for session: WorkSession) async -> [String]
}
