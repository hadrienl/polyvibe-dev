import AppKit
import Foundation
import WebKit

/// Whether a page still draws (#613).
///
/// On macOS 27.0 WebKit's GPU process can hang while it reads the new screen properties after the
/// displays change. WebKit then replaces it, but the pages already loaded never reconnect to the
/// new one: they stay grey, drawing nothing, and WebKit tells no delegate. Such a page no longer
/// gives a picture of itself either, where one that draws gives it at once.
@MainActor
public protocol PageRenderingProbe: Sendable {
  func draws(_ webView: WKWebView) async -> Bool
}

/// Asks the page for a small picture of itself.
public struct SnapshotRenderingProbe: PageRenderingProbe {
  /// A page that draws answers within milliseconds; one left without its GPU process fails at
  /// once on screen, after about fifteen seconds in the parking window, or never.
  static let timeout: Duration = .seconds(20)

  public init() {}

  public func draws(_ webView: WKWebView) async -> Bool {
    let answer = ProbeAnswer()
    return await withCheckedContinuation { continuation in
      answer.continuation = continuation
      let configuration = WKSnapshotConfiguration()
      configuration.snapshotWidth = 32
      webView.takeSnapshot(with: configuration) { image, _ in
        MainActor.assumeIsolated { answer.finish(image != nil) }
      }
      answer.timeout = Task {
        try? await Task.sleep(for: Self.timeout)
        answer.finish(false)
      }
    }
  }
}

/// The first of the picture and the time limit answers.
@MainActor
private final class ProbeAnswer {
  var continuation: CheckedContinuation<Bool, Never>?
  var timeout: Task<Void, Never>?

  func finish(_ draws: Bool) {
    timeout?.cancel()
    continuation?.resume(returning: draws)
    continuation = nil
  }
}

/// Says when to look whether the pages still draw: in the minutes after the displays change
/// (WebKit gave up on the hung GPU process 49 and 56 seconds after the change, and starts the next
/// one only when a page needs it: a page replaced before would be tied to the hung one, and
/// replaced again), and when the application comes back to the front. A page put on
/// screen is looked at by the workspace itself.
@MainActor
final class PageRenderingWatch {
  static let afterScreenChange: [Duration] = [
    .seconds(60), .seconds(90), .seconds(120), .seconds(180), .seconds(240),
  ]

  private let delays: [Duration]
  private let check: @MainActor () async -> Void
  nonisolated(unsafe) private var screenChecks: Task<Void, Never>?
  nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

  init(afterScreenChange delays: [Duration], check: @escaping @MainActor () async -> Void) {
    self.delays = delays
    self.check = check
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
        MainActor.assumeIsolated {
          guard let self else { return }
          Task { await self.check() }
        }
      },
    ]
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    screenChecks?.cancel()
  }

  private func screensDidChange() {
    screenChecks?.cancel()
    screenChecks = Task { [weak self, delays] in
      var waited = Duration.zero
      for delay in delays {
        try? await Task.sleep(for: delay - waited)
        waited = delay
        guard !Task.isCancelled, let self else { return }
        await self.check()
      }
    }
  }
}
