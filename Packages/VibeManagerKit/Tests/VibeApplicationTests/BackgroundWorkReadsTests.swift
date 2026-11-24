import Foundation
import Testing

@testable import VibeApplication

/// Lines `{"started": "<task>", "at": <seconds since 1970>}` and `{"ended": "<task>"}`.
private final class TaskDecoder: ConversationDecoding {
  private var running: [String: Date] = [:]
  var entries: [ConversationEntry] { [] }
  var backgroundWork: [Date] { Array(running.values) }

  func consume(_ record: TranscriptRecord) {
    if let task = record.object["started"] as? String, let at = record.object["at"] as? Double {
      running[task] = Date(timeIntervalSince1970: at)
    } else if let task = record.object["ended"] as? String {
      running[task] = nil
    }
  }
}

/// How many decoders were made: one per read of the transcript.
private final class ReadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int { lock.withLock { value } }

  func decoder() -> any ConversationDecoding {
    lock.withLock { value += 1 }
    return TaskDecoder()
  }
}

@Suite("The background work of a transcript")
struct BackgroundWorkReadsTests {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("BackgroundWorkReads-\(UUID().uuidString)", isDirectory: true)

  private func transcript(_ lines: String...) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("transcript.jsonl")
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: file)
    return file
  }

  private func append(_ line: String, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + "\n").utf8))
    try handle.close()
  }

  @Test("A transcript that did not change is not read again")
  func unchangedTranscriptIsNotRead() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try transcript(#"{"started": "shell", "at": 1000}"#)
    let reads = BackgroundWorkReads()
    let counter = ReadCounter()

    for _ in 0..<5 {
      let started = await reads.backgroundWork(in: file, decoder: { counter.decoder() })
      #expect(started == [Date(timeIntervalSince1970: 1000)])
    }
    #expect(counter.count == 1)
  }

  @Test("A line that ends the work is read, and nothing runs any more")
  func appendedEndIsRead() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try transcript(#"{"started": "shell", "at": 1000}"#)
    let reads = BackgroundWorkReads()
    let counter = ReadCounter()
    #expect(await reads.backgroundWork(in: file, decoder: { counter.decoder() })?.count == 1)

    try append(#"{"ended": "shell"}"#, to: file)

    #expect(await reads.backgroundWork(in: file, decoder: { counter.decoder() }) == [])
    #expect(counter.count == 2)
  }

  @Test("A transcript replaced under the same name is read again")
  func replacedTranscriptIsRead() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try transcript(#"{"started": "shell", "at": 1000}"#)
    let reads = BackgroundWorkReads()
    let counter = ReadCounter()
    _ = await reads.backgroundWork(in: file, decoder: { counter.decoder() })

    // As long as the first, so that only the file itself tells them apart.
    let replacement = directory.appendingPathComponent("replacement.jsonl")
    try Data((#"{"started": "agent", "at": 2000}"# + "\n").utf8).write(to: replacement)
    _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)

    let started = await reads.backgroundWork(in: file, decoder: { counter.decoder() })
    #expect(started == [Date(timeIntervalSince1970: 2000)])
    #expect(counter.count == 2)
  }

  @Test("A transcript that cannot be read tells nothing")
  func missingTranscript() async {
    let reads = BackgroundWorkReads()
    let counter = ReadCounter()
    let missing = directory.appendingPathComponent("missing.jsonl")
    #expect(await reads.backgroundWork(in: missing, decoder: { counter.decoder() }) == nil)
  }
}
