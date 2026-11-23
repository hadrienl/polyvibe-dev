import Foundation
import Testing
import VibeApplication

@testable import VibeUI

/// A clock that moves only when the runner sleeps, and the taps it saw.
private final class FakeTrackpad: @unchecked Sendable {
  private let lock = NSLock()
  private var time = 0.0
  private var lags: [Double]
  private var tapTimes: [Double] = []
  private var loads = 0
  private var fallbacks = 0
  private var fallbackTapTimes: [Double] = []
  /// Grows when a trackpad is plugged in or unplugged.
  private var devices = 0
  /// Called during the first sleep: what happens while a rhythm plays.
  var duringSleep: (@Sendable () -> Void)?

  init(lags: [Double] = []) {
    self.lags = lags
  }

  var now: Double { lock.withLock { time } }
  var taps: [Double] { lock.withLock { tapTimes } }
  var loadCount: Int { lock.withLock { loads } }
  var fallbackCount: Int { lock.withLock { fallbacks } }
  var fallbackTaps: [Double] { lock.withLock { fallbackTapTimes } }
  var deviceState: Int { lock.withLock { devices } }

  func plugIn() {
    lock.withLock { devices += 1 }
  }

  func advance(_ seconds: Double) {
    lock.withLock { time += seconds }
  }

  func sleep(_ seconds: Double) {
    let hook: (@Sendable () -> Void)? = lock.withLock {
      time += seconds + (lags.isEmpty ? 0 : lags.removeFirst())
      defer { duringSleep = nil }
      return duringSleep
    }
    hook?()
  }

  func tapper(gap: Double, failing: Bool = false, fallback: Bool = false) -> any HapticTapping {
    let devices = lock.withLock {
      loads += 1
      return self.devices
    }
    return Tapper(
      trackpad: self, minimumGap: gap, failing: failing, isFallback: fallback, devices: devices)
  }

  /// AppKit's feedback, counted apart.
  func standIn() -> any HapticTapping {
    lock.withLock { fallbacks += 1 }
    return StandIn(trackpad: self)
  }

  fileprivate func record(fallback: Bool = false) {
    lock.withLock {
      if fallback { fallbackTapTimes.append(time) } else { tapTimes.append(time) }
    }
  }

  private struct Tapper: HapticTapping {
    let trackpad: FakeTrackpad
    let minimumGap: Double
    let failing: Bool
    let isFallback: Bool
    let devices: Int

    func tap() -> Bool {
      guard !failing else { return false }
      trackpad.record()
      return true
    }

    func isOutdated() -> Bool { trackpad.deviceState != devices }
  }

  private struct StandIn: HapticTapping {
    let trackpad: FakeTrackpad
    let minimumGap = 0.4
    let isFallback = true

    func tap() -> Bool {
      trackpad.record(fallback: true)
      return true
    }
  }
}

@Suite("The trackpad playing a rhythm (#555)")
struct TrackpadRhythmPlayerTests {
  private func runner(_ trackpad: FakeTrackpad, gap: Double = 0.09) -> RhythmRunner {
    runner(trackpad) { trackpad.tapper(gap: gap) }
  }

  private func runner(
    _ trackpad: FakeTrackpad, load: @escaping @Sendable () -> any HapticTapping
  ) -> RhythmRunner {
    RhythmRunner(
      load: load, fallback: { trackpad.standIn() }, sleep: { trackpad.sleep($0) },
      now: { trackpad.now })
  }

  private func play(_ taps: [Double], on runner: RhythmRunner) {
    runner.run(AlertSoundRhythm(taps: taps), generation: runner.begin())
  }

  @Test("Each tap falls at its time")
  func onTime() {
    let trackpad = FakeTrackpad()
    play([0, 0.2, 0.5], on: runner(trackpad))
    #expect(trackpad.taps.map { ($0 * 1000).rounded() } == [0, 200, 500])
  }

  @Test("A tap that comes late keeps apart from the next one")
  func late() throws {
    let trackpad = FakeTrackpad(lags: [0.25])
    play([0, 0.1, 0.2], on: runner(trackpad))
    let taps = trackpad.taps
    try #require(taps.count == 3)
    #expect(taps[2] - taps[1] >= 0.1 * RhythmRunner.keptShare - 1e-9)
  }

  @Test("A trackpad that loses close taps plays them further apart")
  func spaced() {
    let trackpad = FakeTrackpad()
    play([0, 0.15, 0.5], on: runner(trackpad, gap: 0.4))
    #expect(trackpad.taps.map { ($0 * 1000).rounded() } == [0, 500])
  }

  @Test("A newer rhythm stops the one playing")
  func replaced() {
    let trackpad = FakeTrackpad()
    let runner = runner(trackpad)
    trackpad.duringSleep = { _ = runner.begin() }
    play([0, 0.2, 0.4], on: runner)
    #expect(trackpad.taps == [0])
  }

  @Test("A trackpad that fails is looked for again, once")
  func reloaded() {
    let trackpad = FakeTrackpad()
    let loads = LoadCounter()
    let runner = runner(trackpad) { trackpad.tapper(gap: 0.09, failing: loads.next() == 1) }
    play([0, 0.2], on: runner)
    #expect(trackpad.loadCount == 2)
    #expect(trackpad.taps.count == 2)
    #expect(trackpad.fallbackCount == 0)
  }

  @Test("Trackpads that refuse their taps leave them to the fallback, spaced for it")
  func degraded() {
    let trackpad = FakeTrackpad()
    let runner = runner(trackpad) { trackpad.tapper(gap: 0.09, failing: true) }
    play([0, 0.2, 0.6], on: runner)
    #expect(trackpad.loadCount == 2)
    #expect(trackpad.fallbackCount == 1)
    #expect(trackpad.fallbackTaps.map { ($0 * 1000).rounded() } == [0, 600])
    // Kept until the trackpads are looked for again.
    play([0], on: runner)
    #expect(trackpad.loadCount == 2)
    // Still refused: the fallback again.
    trackpad.advance(RhythmRunner.retryInterval)
    play([0], on: runner)
    #expect(trackpad.loadCount == 4)
    #expect(trackpad.fallbackCount == 2)
  }

  @Test("A trackpad plugged in is opened at the next rhythm")
  func pluggedIn() {
    let trackpad = FakeTrackpad()
    let runner = runner(trackpad)
    play([0], on: runner)
    play([0], on: runner)
    #expect(trackpad.loadCount == 1)
    trackpad.plugIn()
    play([0], on: runner)
    #expect(trackpad.loadCount == 2)
    play([0], on: runner)
    #expect(trackpad.loadCount == 2)
  }

  @Test("The rhythm keeps time with its sound however long the trackpads take to open")
  func slowLoad() throws {
    let trackpad = FakeTrackpad()
    let runner = runner(trackpad) {
      trackpad.advance(1)
      return trackpad.tapper(gap: 0.09)
    }
    play([0, 0.2, 4], on: runner)
    let taps = trackpad.taps
    try #require(taps.count == 3)
    #expect(abs(taps[2] - 4) < 1e-9)
  }

  @Test("While the fallback plays, the trackpads are looked for again from time to time")
  func fallbackRetried() {
    let trackpad = FakeTrackpad()
    let runner = runner(trackpad) { trackpad.tapper(gap: 0.4, fallback: true) }
    play([0], on: runner)
    play([0], on: runner)
    #expect(trackpad.loadCount == 1)
    trackpad.advance(RhythmRunner.retryInterval)
    play([0], on: runner)
    #expect(trackpad.loadCount == 2)
  }

  @Test("Not a trackpad that loses close taps: kept while the trackpads stay the same")
  func trackpadKept() {
    let trackpad = FakeTrackpad()
    let runner = runner(trackpad)
    play([0], on: runner)
    trackpad.advance(RhythmRunner.retryInterval * 2)
    play([0], on: runner)
    #expect(trackpad.loadCount == 1)
  }

  @Test("Wakes on a newer rhythm instead of sleeping to its next tap", .timeLimit(.minutes(1)))
  func wakes() async {
    let trackpad = FakeTrackpad()
    let runner = RhythmRunner(
      load: { trackpad.tapper(gap: 0.09) }, fallback: { trackpad.standIn() })
    let generation = runner.begin()
    // On a thread of its own, as the player runs it: blocked in a task, it would hold one of the
    // few threads every test shares — on a runner with three cores, enough to freeze them all.
    let finished = DispatchSemaphore(value: 0)
    Thread {
      runner.run(AlertSoundRhythm(taps: [0, 3_600]), generation: generation)
      finished.signal()
    }.start()
    while trackpad.taps.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
    _ = runner.begin()
    await withCheckedContinuation { continuation in
      Thread {
        finished.wait()
        continuation.resume()
      }.start()
    }
    #expect(trackpad.taps.count == 1)
  }

  @Test("A notification is felt when macOS plays its sound: sounds on, not in front")
  func notificationFelt() {
    #expect(SystemRequestNotifier.feels(soundsOn: true, inFront: false))
    #expect(!SystemRequestNotifier.feels(soundsOn: false, inFront: false))
    #expect(!SystemRequestNotifier.feels(soundsOn: true, inFront: true))
  }
}

private final class LoadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func next() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}
