import Foundation
import SQLite3
import Testing
import VibeApplication

@testable import VibeAgents

/// The error that stops an Antigravity turn, read from the conversation's database (#615): agy
/// 1.5.15–1.5.17 writes it nowhere else — its status line stays at `idle`, its transcript holds
/// only the prompt.
@Suite("Antigravity failed turns")
struct AntigravityFailureTests {
  private let identifier = "c6fbb17f-8731-49b4-b694-eb6bdc3d3235"
  static let quotaText =
    "Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 114h3m13s."

  // MARK: - Steps

  @Test("The step that stops a turn reads with agy's words, its error and its code")
  func quotaStep() throws {
    let date = Date(timeIntervalSince1970: 1_795_458_967.274)
    let step = try #require(
      AntigravityErrorStep(
        index: 1,
        payload: Self.payload(
          date: date, message: Self.quotaText,
          detail: "RESOURCE_EXHAUSTED (code 429): " + Self.quotaText, code: 429)))
    #expect(step.endsTurn)
    #expect(step.isQuota)
    #expect(step.text == Self.quotaText)
    #expect(abs((step.date?.timeIntervalSince1970 ?? 0) - date.timeIntervalSince1970) < 0.001)
  }

  @Test("A failure whose words say nothing of it shows the error behind them")
  func requestStep() throws {
    let detail = "agent executor error: generating and executing: request failed: Forbidden"
    let step = try #require(
      AntigravityErrorStep(
        index: 1,
        payload: Self.payload(
          date: Date(), message: "Agent execution terminated due to error.", detail: detail,
          code: 2)))
    #expect(step.endsTurn)
    #expect(!step.isQuota)
    #expect(step.text == "Agent execution terminated due to error.\n" + detail)
  }

  @Test("An attempt agy retried does not stop the turn, and bytes that are no message do not read")
  func retriedStep() throws {
    let step = try #require(
      AntigravityErrorStep(
        index: 4,
        payload: Self.payload(
          date: Date(), message: nil,
          detail: "API error (attempt 1): UNAVAILABLE (code 503): No capacity available",
          code: nil)))
    #expect(!step.endsTurn)
    #expect(AntigravityErrorStep(index: 1, payload: Data([0x0A, 0x05, 0x01])) == nil)
    #expect(AntigravityErrorStep(index: 1, payload: Data([0xFF, 0xFF])) == nil)
    #expect(AntigravityErrorStep(index: 1, payload: Self.message([(1, .varint(17))])) == nil)
  }

  @Test("The database gives its error steps after the one asked, and nothing it cannot read")
  func readDatabase() throws {
    let file = try Self.database()
    try Self.insert(file, index: 0, type: 14, payload: Data([0x08, 0x0E]))
    try Self.insert(file, index: 1, type: 17, payload: Self.retry())
    try Self.insert(file, index: 2, type: 17, payload: Self.failure(at: Date()))
    let all = try #require(AntigravityErrorStep.read(database: file, after: -1))
    #expect(all.map(\.index) == [1, 2])
    #expect(all.map(\.endsTurn) == [false, true])
    #expect(AntigravityErrorStep.read(database: file, after: 2)?.isEmpty == true)
    // Closed by agy, its log and index gone: still read, and nothing written beside it.
    let folder = file.deletingLastPathComponent()
    for suffix in ["-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: file.path + suffix)
    }
    let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(before == ["conversation.db"])
    #expect(AntigravityErrorStep.read(database: file, after: 1)?.map(\.index) == [2])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    let missing = file.deletingLastPathComponent().appendingPathComponent("missing.db")
    #expect(AntigravityErrorStep.read(database: missing, after: -1) == nil)
  }

  // MARK: - Decoder

  @Test("A turn that failed at once is told once, as agy said it")
  func failedTurn() throws {
    let file = try Self.database()
    let decoder = Self.decoder(file)
    try Self.insert(file, index: 0, type: 14, payload: Data([0x08, 0x0E]))
    try Self.insert(file, index: 1, type: 17, payload: Self.failure(at: Date().addingTimeInterval(1)))
    let signal = decoder.failure(in: file, conversation: identifier)
    #expect(signal == .turnFailed(AgentTerminalPrompt(kind: .other, message: Self.networkText)))
    #expect(decoder.failure(in: file, conversation: identifier) == nil)
    // The next prompt fails the same way: a failure of its own.
    try Self.insert(file, index: 3, type: 17, payload: Self.failure(at: Date().addingTimeInterval(2)))
    #expect(decoder.failure(in: file, conversation: identifier) != nil)
  }

  @Test("The errors of a conversation resumed belong to its past; a retried attempt is no failure")
  func pastErrors() throws {
    let file = try Self.database()
    try Self.insert(
      file, index: 1, type: 17, payload: Self.failure(at: Date().addingTimeInterval(-3600)))
    let decoder = Self.decoder(file)
    #expect(decoder.failure(in: file, conversation: identifier) == nil)
    try Self.insert(file, index: 2, type: 17, payload: Self.retry())
    #expect(decoder.failure(in: file, conversation: identifier) == nil)
    try Self.insert(file, index: 3, type: 17, payload: Self.failure(at: Date().addingTimeInterval(1)))
    #expect(decoder.failure(in: file, conversation: identifier) != nil)
  }

  @Test("A spent quota is named in the user's words; every bucket spent, it is the account's")
  func quotaFailure() throws {
    let resets = "2099-11-28T12:39:21Z"
    for (quota, isAccount) in [
      ("gemini-weekly=0@\(resets);3p-weekly=0@\(resets)", true),
      ("gemini-weekly=0@\(resets);3p-weekly=1@\(resets)", false),
    ] {
      let file = try Self.database()
      let decoder = Self.decoder(file)
      _ = decoder.signal(for: event("idle", quota: quota))
      try Self.insert(
        file, index: 1, type: 17,
        payload: Self.payload(
          date: Date().addingTimeInterval(1), message: Self.quotaText,
          detail: "RESOURCE_EXHAUSTED (code 429): " + Self.quotaText, code: 429))
      guard case .turnFailed(let prompt) = decoder.failure(in: file, conversation: identifier)
      else {
        Issue.record("No failure for \(quota)")
        continue
      }
      #expect(prompt.kind == (isAccount ? .account : .other))
      #expect(prompt.reportsQuotaExhausted == isAccount)
      let expected = AntigravityQuotaBucket.failure(
        AntigravityQuotaBucket.parse(quota), now: Date())
      #expect(prompt.message == expected)
      #expect(prompt.message?.contains("Gemini") == true)
    }
  }

  @Test("A spent quota the status line did not show is told in agy's words, not as the account's")
  func quotaWithoutBuckets() throws {
    let file = try Self.database()
    let decoder = Self.decoder(file)
    try Self.insert(
      file, index: 1, type: 17,
      payload: Self.payload(
        date: Date().addingTimeInterval(1), message: Self.quotaText,
        detail: "RESOURCE_EXHAUSTED (code 429): " + Self.quotaText, code: 429))
    #expect(
      decoder.failure(in: file, conversation: identifier)
        == .turnFailed(AgentTerminalPrompt(kind: .other, message: Self.quotaText)))
  }

  @Test("An error snapshot tells the failure its step says, and the step is not told again")
  func errorSnapshotReadsStep() throws {
    let file = try Self.database()
    let decoder = Self.decoder(file)
    _ = decoder.signal(for: event("working"))
    try Self.insert(file, index: 1, type: 17, payload: Self.failure(at: Date().addingTimeInterval(1)))
    #expect(
      decoder.signal(for: event("error"))
        == .turnFailed(AgentTerminalPrompt(kind: .other, message: Self.networkText)))
    #expect(decoder.failure(in: file, conversation: identifier) == nil)
    // At rest after it: the failure stays until the user writes again.
    #expect(decoder.signal(for: event("idle")) == nil)
    #expect(decoder.signal(for: event("working")) == .promptSubmitted(byUser: true))
  }

  @Test("One failure said twice — snapshot and step, in either order — is told once")
  func sameFailureOnce() throws {
    // The snapshot first, its step written after.
    let file = try Self.database()
    let decoder = Self.decoder(file)
    _ = decoder.signal(for: event("working"))
    #expect(decoder.signal(for: event("error")) != nil)
    try Self.insert(file, index: 1, type: 17, payload: Self.failure(at: Date().addingTimeInterval(1)))
    #expect(decoder.failure(in: file, conversation: identifier) == nil)

    // The step first, then the snapshot.
    let other = try Self.database()
    let second = Self.decoder(other)
    _ = second.signal(for: event("working"))
    try Self.insert(other, index: 1, type: 17, payload: Self.failure(at: Date().addingTimeInterval(1)))
    #expect(second.failure(in: other, conversation: identifier) != nil)
    #expect(second.signal(for: event("error")) == nil)
  }

  @Test(
    "The database of the conversation named is watched: a failure written later is told",
    .timeLimit(.minutes(1)))
  func watch() async throws {
    let file = try Self.database()
    let decoder = Self.decoder(file)
    let stream = try #require(decoder.additionalSignals(after: event("idle")))
    // The same conversation named again opens nothing more.
    #expect(decoder.additionalSignals(after: event("idle")) == nil)
    try Self.insert(file, index: 0, type: 14, payload: Data([0x08, 0x0E]))
    try Self.insert(file, index: 1, type: 17, payload: Self.failure(at: Date().addingTimeInterval(1)))
    var iterator = stream.makeAsyncIterator()
    #expect(
      await iterator.next()
        == .turnFailed(AgentTerminalPrompt(kind: .other, message: Self.networkText)))
    try Self.insert(file, index: 2, type: 14, payload: Data([0x08, 0x0E]))
    try Self.insert(file, index: 3, type: 17, payload: Self.failure(at: Date().addingTimeInterval(2)))
    #expect(await iterator.next() != nil)
  }

  // MARK: - Fixtures

  static let networkDetail =
    "agent executor error: generating and executing: request failed: Forbidden"
  static let networkText = "Agent execution terminated due to error.\n" + networkDetail

  private func event(_ state: String, quota: String? = nil) -> AgentActivityEvent {
    var object: [String: Any] = [
      "conversation_id": identifier, "agent_state": state, "pending": false, "background": false,
    ]
    if let quota { object["quota"] = quota }
    return AgentActivityEvent(
      name: AntigravityStatusCommand.event, date: Date(),
      payload: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
  }

  private static func decoder(_ file: URL) -> AntigravitySignalDecoder {
    AntigravitySignalDecoder(database: { _ in file })
  }

  static func failure(at date: Date) -> Data {
    payload(
      date: date, message: "Agent execution terminated due to error.", detail: networkDetail,
      code: 2)
  }

  static func retry() -> Data {
    payload(
      date: Date(), message: nil,
      detail: "API error (attempt 1): UNAVAILABLE (code 503): No capacity available", code: nil)
  }

  enum Field {
    case varint(UInt64)
    case bytes(Data)
  }

  /// A step as agy 1.5.17 writes one: its type in 1, its time in 5.1, its error in 24.3.
  static func payload(date: Date, message: String?, detail: String?, code: UInt64?) -> Data {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    let time = Self.message([
      (1, .varint(UInt64(seconds))),
      (2, .varint(UInt64((date.timeIntervalSince1970 - seconds) * 1_000_000_000))),
    ])
    var error: [(UInt64, Field)] = []
    if let message { error.append((1, .bytes(Data(message.utf8)))) }
    if let detail { error.append((2, .bytes(Data(detail.utf8)))) }
    error.append((6, .bytes(Data("7393e712-1".utf8))))
    if let code { error.append((7, .varint(code))) }
    return Self.message([
      (1, .varint(17)),
      (4, .varint(3)),
      (5, .bytes(Self.message([(1, .bytes(time)), (3, .varint(5))]))),
      (24, .bytes(Self.message([(3, .bytes(Self.message(error))), (5, .varint(1))]))),
    ])
  }

  static func message(_ fields: [(UInt64, Field)]) -> Data {
    var data = Data()
    func varint(_ value: UInt64) {
      var value = value
      while value >= 0x80 {
        data.append(UInt8(value & 0x7F) | 0x80)
        value >>= 7
      }
      data.append(UInt8(value))
    }
    for (number, field) in fields {
      switch field {
      case .varint(let value):
        varint(number << 3)
        varint(value)
      case .bytes(let bytes):
        varint(number << 3 | 2)
        varint(UInt64(bytes.count))
        data.append(bytes)
      }
    }
    return data
  }

  /// A database shaped like agy's, in WAL mode as agy keeps it, in a folder of its own.
  static func database() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agy-failures-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("conversation.db")
    try execute(
      file,
      "PRAGMA journal_mode=WAL; CREATE TABLE `steps` (`idx` integer,`step_type` integer NOT NULL "
        + "DEFAULT 0,`status` integer NOT NULL DEFAULT 0,`step_payload` blob, PRIMARY KEY (`idx`));")
    return file
  }

  static func insert(_ file: URL, index: Int, type: Int, payload: Data) throws {
    try execute(file, "") { handle in
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(
          handle, "INSERT INTO steps (idx, step_type, status, step_payload) VALUES (?, ?, 3, ?)",
          -1, &statement, nil) == SQLITE_OK
      else { throw SQLiteFailure() }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, Int64(index))
      sqlite3_bind_int64(statement, 2, Int64(type))
      _ = payload.withUnsafeBytes { bytes in
        sqlite3_bind_blob(
          statement, 3, bytes.baseAddress, Int32(bytes.count),
          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
      guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFailure() }
    }
  }

  struct SQLiteFailure: Error {}

  private static func execute(
    _ file: URL, _ sql: String, _ body: (OpaquePointer) throws -> Void = { _ in }
  ) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else {
      throw SQLiteFailure()
    }
    defer { sqlite3_close(handle) }
    if !sql.isEmpty {
      guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFailure() }
    }
    try body(handle)
  }
}
