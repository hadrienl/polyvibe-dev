import Foundation
import VibeDomain

/// Whether a session's agent ended its turn with work still running in the background — a command
/// or a sub-agent it will hear from (#393). The user is not needed yet: the agent goes on by
/// itself once that work ends, and is said when it ends a turn with nothing left running.
///
/// Its transcript is read to its end, away from the main actor. Work started before the agent's
/// process — a process resumed since — never ends, and does not count; neither does anything the
/// transcript cannot tell, or a transcript that cannot be read: then the user is told.
///
/// A session waiting to restart onto an updated CLI asks every half minute, for days at times,
/// of transcripts of tens of megabytes (#601). What was found is kept with the file as it was
/// then: a transcript that has not changed since is not read again.
public struct BackgroundWorkProbe: Sendable {
  private let agents: any AgentProviderResolving
  private let hint: @Sendable (SessionID) async -> AgentActivityEvent?
  private let reads: BackgroundWorkReads

  public init(
    agents: any AgentProviderResolving,
    hint: @escaping @Sendable (SessionID) async -> AgentActivityEvent?
  ) {
    self.agents = agents
    self.hint = hint
    reads = BackgroundWorkReads()
  }

  /// - Parameter processStart: when the agent's process started.
  public func isWaiting(_ session: WorkSession, processStart: Date) async -> Bool {
    guard let conversation = session.conversationAgents.last,
      let reporter = await agents.provider(id: AgentProviderID(conversation.providerID))
        as? any AgentConversationReporting
    else { return false }
    let files = reporter.conversationFiles(
      for: conversation, in: session, hint: await hint(session.id))
    guard let file = files.last,
      let started = await reads.backgroundWork(
        in: file, decoder: { reporter.conversationDecoder(for: file) })
    else { return false }
    return started.contains { !SubagentRun.predates($0, process: processStart) }
  }
}

/// When the background work of each transcript still running started, with the file as it was
/// when it was read.
actor BackgroundWorkReads {
  private var reads: [URL: (version: TranscriptVersion, started: [Date])] = [:]

  /// Nil when the transcript cannot be read.
  func backgroundWork(
    in file: URL, decoder: @escaping @Sendable () -> any ConversationDecoding
  ) async -> [Date]? {
    // Taken before the read: a line written meanwhile changes the version, and is read next time.
    guard let version = TranscriptVersion(of: file) else {
      reads[file] = nil
      return nil
    }
    if let read = reads[file], read.version == version { return read.started }
    let started = await Task.detached(priority: .utility) { () -> [Date]? in
      guard let data = try? Data(contentsOf: file) else { return nil }
      let decoder = decoder()
      for line in data.split(separator: UInt8(ascii: "\n")) {
        decoder.consume(Data(line))
      }
      return decoder.backgroundWork
    }.value
    reads[file] = started.map { (version, $0) }
    return started
  }
}

/// A file as its attributes show it: another file under the same name, or the same written to
/// since, is another version. A link is followed, as reading it does.
struct TranscriptVersion: Equatable {
  let inode: UInt64
  let size: UInt64
  let modified: Date

  init?(of file: URL) {
    guard
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: file.resolvingSymlinksInPath().path),
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
      let size = (attributes[.size] as? NSNumber)?.uint64Value,
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    self.inode = inode
    self.size = size
    self.modified = modified
  }
}
