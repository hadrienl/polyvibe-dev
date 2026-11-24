import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

private func makeDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeManagerUsage-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("Usage", isDirectory: true)
}

private func permissions(of url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func append(_ bytes: Data, to url: URL) throws {
  let handle = try FileHandle(forWritingTo: url)
  try handle.seekToEnd()
  try handle.write(contentsOf: bytes)
  try handle.close()
}

@Suite("Usage files")
struct FileUsageStoresTests {
  private let start = Date(timeIntervalSinceReferenceDate: 800_000_000.123).storageRounded

  private func run(at date: Date) -> UsageRun {
    UsageRun(
      sessionID: SessionID(), providerID: "claude-code", modelID: "opus", kind: .resume,
      afterRelaunch: true, startedAt: date)
  }

  @Test("The journal reads back what was appended, in order")
  func journalRoundTrip() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    let subject = run(at: start)

    try await ledger.append(.start(subject))
    try await ledger.append(.suspend(at: start.addingTimeInterval(10)))
    try await ledger.append(.resume(at: start.addingTimeInterval(20)))
    try await ledger.append(
      .end(runID: subject.id, at: start.addingTimeInterval(60), exit: .exited))

    let events = try await ledger.events()
    #expect(events.count == 4)
    #expect(events.first == .start(subject))
    let folded = UsageLedgerFold.runs(from: events)
    #expect(folded.first?.runningTime(in: nil, now: start) == 50)
  }

  @Test("A last line cut short is ignored")
  func truncatedLine() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    try await ledger.append(.start(run(at: start)))
    let url = await ledger.journalURL(for: start)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"type":"end","at":"20"#.utf8))
    try handle.close()

    #expect(try await ledger.events().count == 1)
  }

  @Test("A line appended after one a crash cut short is kept")
  func appendAfterCutLine() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    let subject = run(at: start)
    try await ledger.append(.start(subject))
    try append(Data(#"{"type":"end","at":"20"#.utf8), to: await ledger.journalURL(for: start))

    try await ledger.append(.suspend(at: start.addingTimeInterval(10)))

    #expect(
      try await ledger.events() == [.start(subject), .suspend(at: start.addingTimeInterval(10))])
  }

  @Test("A line cut short is read once it is complete")
  func lineCompletedLater() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    let subject = run(at: start)
    try await ledger.append(.start(subject))
    var line = try UsageStorage.encoder().encode(
      LedgerLine(.end(runID: subject.id, at: start.addingTimeInterval(60), exit: .exited)))
    line.append(UInt8(ascii: "\n"))
    let url = await ledger.journalURL(for: start)

    try append(line.prefix(20), to: url)
    #expect(try await ledger.events().count == 1)

    try append(line.dropFirst(20), to: url)
    let events = try await ledger.events()
    #expect(events.count == 2)
    #expect(events.last == .end(runID: subject.id, at: start.addingTimeInterval(60), exit: .exited))
  }

  @Test("A read decodes only the lines appended since the last one")
  func readsOnlyAppendedLines() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    let subject = run(at: start)
    try await ledger.append(.start(subject))
    #expect(try await ledger.events() == [.start(subject)])

    // The line already read is overwritten in place, same file and same size: a read that went
    // back to the start would lose it.
    let url = await ledger.journalURL(for: start)
    let size = try Data(contentsOf: url).count
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(repeating: UInt8(ascii: " "), count: size - 1))
    try handle.close()
    try await ledger.append(.suspend(at: start.addingTimeInterval(10)))

    #expect(
      try await ledger.events() == [.start(subject), .suspend(at: start.addingTimeInterval(10))])
  }

  @Test("A journal that shrank, or was cleared, is read again from the start")
  func startsOverAfterShrinkOrClear() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    let first = run(at: start)
    let second = run(at: start.addingTimeInterval(5))
    try await ledger.append(.start(first))
    try await ledger.append(.start(second))
    #expect(try await ledger.events().count == 2)

    let url = await ledger.journalURL(for: start)
    let lines = try Data(contentsOf: url).split(separator: UInt8(ascii: "\n"))
    var kept = Data(lines[1])
    kept.append(UInt8(ascii: "\n"))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: kept)
    try handle.close()
    #expect(try await ledger.events() == [.start(second)])

    try await ledger.clear()
    try await ledger.append(.start(first))
    #expect(try await ledger.events() == [.start(first)])
  }

  @Test("A line written before #602 reads back the date it held")
  func earlierLineReadsTheSame() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    let text = "2026-11-03T09:15:42.123Z"
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expected = try #require(formatter.date(from: text)).storageRounded
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"at":"\#(text)","type":"suspend"}"#.utf8 + [UInt8(ascii: "\n")])
      .write(to: directory.appendingPathComponent("runs-2026-11.jsonl"))

    #expect(try await ledger.events() == [.suspend(at: expected)])
  }

  @Test("Files are owner-only, in an owner-only folder")
  func permissionsAreOwnerOnly() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let ledger = FileUsageLedger(directory: directory)
    try await ledger.append(.start(run(at: start)))
    try await ledger.writeHeartbeat(UsageHeartbeat(at: start, runIDs: []))
    try await FileTokenUsageStore(directory: directory).save(.empty)
    try await FileUsageTrackingStore(directory: directory).save([])

    #expect(try permissions(of: directory) == 0o700)
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
      #expect(try permissions(of: directory.appendingPathComponent(name)) == 0o600)
    }
  }

  @Test("Clearing removes the journal and the heartbeat, and nothing next to them")
  func clearing() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let neighbour = directory.deletingLastPathComponent().appendingPathComponent("sessions.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: neighbour)
    let ledger = FileUsageLedger(directory: directory)
    try await ledger.append(.start(run(at: start)))
    try await ledger.writeHeartbeat(UsageHeartbeat(at: start, runIDs: []))

    try await ledger.clear()

    #expect(try await ledger.events().isEmpty)
    #expect(await ledger.heartbeat() == nil)
    #expect(FileManager.default.fileExists(atPath: neighbour.path))
  }

  @Test("Without a file, tracking is on and always was")
  func trackingDefault() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let store = FileUsageTrackingStore(directory: directory)
    #expect(await store.intervals() == [UsageTrackingInterval(from: .distantPast)])

    let intervals = [UsageTrackingInterval(from: start, to: start.addingTimeInterval(60))]
    try await store.save(intervals)
    #expect(await store.intervals() == intervals)
  }

  @Test("Token totals survive a round trip")
  func tokensRoundTrip() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let store = FileTokenUsageStore(directory: directory)
    var file = TokenUsageFile(sessionID: SessionID(), providerID: "codex", inode: 42, offset: 128)
    file.add(
      TokenCounts(input: 3, cacheRead: 2, output: 1), model: "gpt",
      day: LocalDay(year: 2026, month: 9, day: 24), fallback: false)
    let snapshot = TokenUsageSnapshot(files: ["/tmp/rollout.jsonl": file])

    try await store.save(snapshot)
    #expect(await store.load() == snapshot)

    try await store.clear()
    #expect(await store.load() == .empty)
  }
}
