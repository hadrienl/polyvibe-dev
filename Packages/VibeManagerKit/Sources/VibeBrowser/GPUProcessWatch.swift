import AppKit
import Foundation
import OSLog

/// Where WebKit says it lost its GPU process (#613).
///
/// On macOS 27.0 the GPU process can hang while it reads the new screen properties after the
/// displays change. WebKit then replaces it, but the pages already loaded never reconnect to the
/// new one: they stay on screen, grey, drawing nothing. WebKit tells no delegate about this. Its
/// own log, kept in this process, is the only place that says when it happened.
public protocol GPUProcessExitLog: Sendable {
  /// When WebKit last reported its GPU process gone, hung or crashed, at or after `date`.
  /// `nil` if it has not.
  func lastExit(since date: Date) async -> Date?
}

/// Reads the application's own log.
public struct OSLogGPUProcessExitLog: GPUProcessExitLog {
  public init() {}

  public func lastExit(since date: Date) async -> Date? {
    await Task.detached(priority: .utility) { Self.read(since: date) }.value
  }

  /// The message WebKit's application side writes once per GPU process it loses.
  static let message = "GPUProcessProxy::gpuProcessExited"

  static func read(since date: Date) -> Date? {
    guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
    let predicate = NSPredicate(
      format: "subsystem == %@ AND composedMessage CONTAINS %@", "com.apple.WebKit", message)
    guard let entries = try? store.getEntries(at: store.position(date: date), matching: predicate)
    else { return nil }
    var last: Date?
    for case let entry as OSLogEntryLog in entries
    where entry.date >= date && leavesPagesBlank(entry.composedMessage) {
      last = max(last ?? entry.date, entry.date)
    }
    return last
  }

  /// A GPU process that quit because nothing needed it any more left no page behind it.
  static func leavesPagesBlank(_ message: String) -> Bool {
    guard let range = message.range(of: "reason=") else { return true }
    return message[range.upperBound...].prefix(while: \.isLetter) != "IdleExit"
  }
}

/// Asks the log whether WebKit lost its GPU process, at the moments it may have: in the two minutes
/// after the displays change (WebKit gives up on a hung GPU process about a minute later), when the
/// application comes back to the front, and when a session is shown.
@MainActor
final class GPUProcessWatch {
  /// After the displays change, when to look. WebKit declared the hung process lost 49 and 56
  /// seconds after the change.
  static let afterScreenChange: [Duration] = [
    .seconds(30), .seconds(60), .seconds(90), .seconds(120),
  ]

  private let log: any GPUProcessExitLog
  private let delays: [Duration]
  private let recover: @MainActor (Date) -> Void
  /// Everything logged before this was looked at.
  private var checkedUntil: Date
  private var checking: Task<Void, Never>?
  nonisolated(unsafe) private var screenChecks: Task<Void, Never>?
  nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

  init(
    log: any GPUProcessExitLog, since: Date = Date(),
    afterScreenChange delays: [Duration] = GPUProcessWatch.afterScreenChange,
    recover: @escaping @MainActor (Date) -> Void
  ) {
    self.log = log
    self.delays = delays
    self.recover = recover
    checkedUntil = since
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.screensDidChange() }
      },
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { _ = self?.check() }
      },
    ]
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    screenChecks?.cancel()
  }

  /// Looks at what was logged since the last look. A look already under way is the one waited on.
  @discardableResult
  func check() -> Task<Void, Never> {
    if let checking { return checking }
    let since = checkedUntil
    let now = Date()
    let task = Task { [weak self, log] in
      let exit = await log.lastExit(since: since)
      guard let self else { return }
      // A little before the look started: a line WebKit was still writing then is read next time.
      self.checkedUntil = max(self.checkedUntil, now.addingTimeInterval(-5))
      self.checking = nil
      if let exit { self.recover(exit) }
    }
    checking = task
    return task
  }

  private func screensDidChange() {
    screenChecks?.cancel()
    screenChecks = Task { [weak self, delays] in
      var waited = Duration.zero
      for delay in delays {
        try? await Task.sleep(for: delay - waited)
        waited = delay
        guard !Task.isCancelled, let self else { return }
        await self.check().value
      }
    }
  }
}
