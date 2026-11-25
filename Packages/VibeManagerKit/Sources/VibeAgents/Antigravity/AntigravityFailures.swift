import Foundation
import SQLite3
import VibeApplication

/// An error step of an agy conversation, as its database keeps it (#615).
///
/// agy 1.5.15–1.5.17 writes the error that stops a turn — a spent quota, a request that failed —
/// neither to the exported transcript nor to its status line, which stays at `idle`: only to
/// `conversations/<id>.db`, table `steps`, as a step of type 17. The attempts it retried are steps
/// of the same type, without the words meant for the user.
struct AntigravityErrorStep: Hashable, Sendable {
  let index: Int
  let date: Date?
  /// What agy told the user — `Individual quota reached. … Resets in 114h3m13s.` — when the
  /// error stopped the turn; `nil` for an attempt agy retried.
  let message: String?
  /// The error itself: `RESOURCE_EXHAUSTED (code 429): …`, `agent executor error: …`.
  let detail: String?
  let code: Int?
  /// agy writes some steps before they end and finishes them later: 3 is a step done. Every error
  /// step measured was written done, but one that is not may still get its words.
  var isFinished = true

  /// The error ended the turn: agy gave up and told the user.
  var endsTurn: Bool { message != nil }

  var isQuota: Bool {
    code == 429 || detail?.contains("RESOURCE_EXHAUSTED") == true
  }

  /// The words of the failure: agy's own, and the error behind them when they say nothing of it,
  /// as `Agent execution terminated due to error.` does.
  var text: String? {
    guard let message else { return detail }
    guard let detail, !detail.contains(message) else { return message }
    return ToolOutput.bounded(message + "\n" + detail, limit: 600).text
  }

  static let stepType = 17

  /// The step from its `step_payload`, or `nil` when it does not read as one. Only the fields
  /// measured on agy 1.5.15–1.5.17 are read: 5.1 the time, 24.3 the error — 1 its words for the
  /// user, 2 the error, 7 its code. Any other field is skipped.
  init?(index: Int, payload: Data) {
    guard let fields = Protobuf.fields(payload) else { return nil }
    let error = fields.message(24).flatMap { $0.message(3) }
    guard let error else { return nil }
    self.index = index
    let time = fields.message(5).flatMap { $0.message(1) }
    date = time.flatMap { time in
      time.varint(1).map { seconds in
        Date(
          timeIntervalSince1970: TimeInterval(seconds)
            + TimeInterval(time.varint(2) ?? 0) / 1_000_000_000)
      }
    }
    message = error.text(1)
    detail = error.text(2)
    code = error.varint(7).flatMap { $0 <= 1_000_000 ? Int($0) : nil }
  }

  init(index: Int, date: Date?, message: String?, detail: String?, code: Int?) {
    self.index = index
    self.date = date
    self.message = message
    self.detail = detail
    self.code = code
  }

  /// The error steps after `index`, oldest first; `nil` when the database cannot be read. Opened
  /// read-only, and closed at once: agy writes it in WAL mode, which a reader never holds back.
  /// Nothing is written beside it, but the index SQLite recreates beside a log agy left by crashing.
  static func read(database: URL, after index: Int) -> [AntigravityErrorStep]? {
    switch query(database.path, flags: 0, after: index) {
    case .read(let steps): return steps
    case .failed: return nil
    case .noJournal:
      // No connection open, agy's log and its index are gone, and a read-only connection may not
      // create them: nobody writes the file then, which reads as it is.
      guard
        var components = URLComponents(string: "file:"),
        case .read(let steps) = {
          components.path = database.path
          components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
          return query(components.string ?? "", flags: SQLITE_OPEN_URI, after: index)
        }()
      else { return nil }
      return steps
    }
  }

  private enum Outcome {
    case read([AntigravityErrorStep])
    case noJournal
    case failed
  }

  private static func query(_ name: String, flags: Int32, after index: Int) -> Outcome {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(name, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | flags, nil)
        == SQLITE_OK, let handle
    else {
      sqlite3_close(handle)
      return .failed
    }
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 100)
    var statement: OpaquePointer?
    let query =
      "SELECT idx, step_payload, status FROM steps WHERE step_type = ?1 AND idx > ?2 ORDER BY idx LIMIT 512"
    let prepared = sqlite3_prepare_v2(handle, query, -1, &statement, nil)
    guard prepared == SQLITE_OK, let statement else {
      return prepared == SQLITE_CANTOPEN && flags == 0 ? .noJournal : .failed
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(stepType))
    sqlite3_bind_int64(statement, 2, Int64(index))
    var steps: [AntigravityErrorStep] = []
    while true {
      let status = sqlite3_step(statement)
      guard status == SQLITE_ROW else {
        if status == SQLITE_DONE { return .read(steps) }
        return status == SQLITE_CANTOPEN && flags == 0 && steps.isEmpty ? .noJournal : .failed
      }
      let row = Int(sqlite3_column_int64(statement, 0))
      let isFinished = sqlite3_column_int64(statement, 2) == 3
      let count = Int(sqlite3_column_bytes(statement, 1))
      // An error step weighs a few kilobytes; one much larger is not one of these.
      guard count <= 256 * 1024, let bytes = sqlite3_column_blob(statement, 1) else {
        var step = AntigravityErrorStep(index: row, date: nil, message: nil, detail: nil, code: nil)
        step.isFinished = isFinished
        steps.append(step)
        continue
      }
      let payload = Data(bytes: bytes, count: count)
      var step =
        AntigravityErrorStep(index: row, payload: payload)
        ?? AntigravityErrorStep(index: row, date: nil, message: nil, detail: nil, code: nil)
      step.isFinished = isFinished
      steps.append(step)
    }
  }

  /// Where agy keeps the steps of a conversation.
  static func database(conversation identifier: String, home: URL) -> URL? {
    guard let uuid = UUID(uuidString: identifier) else { return nil }
    return home.appendingPathComponent(
      ".gemini/antigravity-cli/conversations/\(uuid.uuidString.lowercased()).db")
  }
}

/// The protocol buffer wire format, as far as reading strings and numbers out of a message goes.
enum Protobuf {
  enum Value {
    case varint(UInt64)
    case bytes(Data)
    case fixed
  }

  struct Fields {
    let values: [(number: UInt64, value: Value)]

    func varint(_ number: UInt64) -> UInt64? {
      for field in values where field.number == number {
        if case .varint(let value) = field.value { return value }
      }
      return nil
    }

    func bytes(_ number: UInt64) -> Data? {
      for field in values where field.number == number {
        if case .bytes(let value) = field.value { return value }
      }
      return nil
    }

    func message(_ number: UInt64) -> Fields? {
      bytes(number).flatMap(Protobuf.fields)
    }

    /// A string field, trimmed; `nil` when absent, empty or not UTF-8.
    func text(_ number: UInt64) -> String? {
      guard let data = bytes(number), let text = String(data: data, encoding: .utf8) else {
        return nil
      }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : ToolOutput.bounded(trimmed, limit: 2000).text
    }
  }

  /// The fields of one message, or `nil` when the bytes are not one.
  static func fields(_ data: Data) -> Fields? {
    let bytes = [UInt8](data)
    var values: [(number: UInt64, value: Value)] = []
    var offset = 0
    while offset < bytes.count {
      guard let key = varint(bytes, &offset) else { return nil }
      let number = key >> 3
      guard number > 0 else { return nil }
      switch key & 7 {
      case 0:
        guard let value = varint(bytes, &offset) else { return nil }
        values.append((number, .varint(value)))
      case 1, 5:
        let size = key & 7 == 1 ? 8 : 4
        guard bytes.count - offset >= size else { return nil }
        offset += size
        values.append((number, .fixed))
      case 2:
        guard let length = varint(bytes, &offset), length <= UInt64(bytes.count - offset) else {
          return nil
        }
        let end = offset + Int(length)
        values.append((number, .bytes(Data(bytes[offset..<end]))))
        offset = end
      default:
        return nil
      }
    }
    return Fields(values: values)
  }

  private static func varint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while offset < bytes.count, shift < 64 {
      let byte = bytes[offset]
      offset += 1
      result |= UInt64(byte & 0x7F) << shift
      if byte < 0x80 { return result }
      shift += 7
    }
    return nil
  }
}

/// Wakes whenever agy writes to one conversation's database — its write-ahead log, the database
/// itself, or the folder while either is missing — and asks what that means. Never on a clock
/// but for the long safety net.
struct AntigravityDatabaseWatch: Sendable {
  let database: URL
  var safetyNet: Duration = FileWatching.safetyNet
  /// How long a wake waits for the writes that come with it: a turn writes in bursts.
  var settle: Duration = .milliseconds(300)

  func signals(_ check: @escaping @Sendable () -> AgentSignal?) -> AsyncStream<AgentSignal> {
    let watch = self
    return AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        await watch.follow { if let signal = check() { continuation.yield(signal) } }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func follow(_ look: () -> Void) async {
    let wake = WakeSignal()
    let journal = database.path + "-wal"
    let folder = database.deletingLastPathComponent().path
    var databaseWatcher: FileWatcher?
    var journalWatcher: FileWatcher?
    var folderWatcher: FileWatcher?
    while !Task.isCancelled {
      // Armed again when a file appears, disappears or is replaced: SQLite removes its log when
      // the last connection closes, and creates it again at the next.
      if Self.inode(of: database.path) != databaseWatcher?.inode {
        databaseWatcher = FileWatcher(path: database.path, wake: wake)
      }
      if Self.inode(of: journal) != journalWatcher?.inode {
        journalWatcher = FileWatcher(path: journal, wake: wake)
      }
      if databaseWatcher == nil || journalWatcher == nil {
        if folderWatcher == nil { folderWatcher = FileWatcher(path: folder, wake: wake) }
      } else {
        folderWatcher = nil
      }
      look()
      await wake.wait(timeout: safetyNet)
      try? await Task.sleep(for: settle)
    }
  }

  private static func inode(of path: String) -> UInt64? {
    var status = stat()
    return stat(path, &status) == 0 ? UInt64(status.st_ino) : nil
  }
}
