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
  /// Called during the first sleep: what happens while a rhythm plays.
  var duringSleep: (@Sendable () -> Void)?

  init(lags: [Double] = []) {
    self.lags = lags
  }

  var now: Double { lock.withLock { time } }
  var taps: [Double] { lock.withLock { tapTimes } }
  var loadCount: Int { lock.withLock { loads } }

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
    lock.withLock { loads += 1 }
    return Tapper(trackpad: self, minimumGap: gap, failing: failing, isFallback: fallback)
  }

  fileprivate func record() {
    lock.withLock { tapTimes.append(time) }
  }

  private struct Tapper: HapticTapping {
    let trackpad: FakeTrackpad
    let minimumGap: Double
    let failing: Bool
    let isFallback: Bool

    func tap() -> Bool {
      guard !failing else { return false }
      trackpad.record()
      return true
    }
  }
}

@Suite("The trackpad playing a rhythm (#555)")
struct TrackpadRhythmPlayerTests {
  private func runner(_ trackpad: FakeTrackpad, gap: Double = 0.09) -> RhythmRunner {
    RhythmRunner(
      load: { trackpad.tapper(gap: gap) }, sleep: { trackpad.sleep($0) }, now: { trackpad.now })
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
    let runner = RhythmRunner(
      load: { trackpad.tapper(gap: 0.09, failing: loads.next() == 1) },
      sleep: { trackpad.sleep($0) }, now: { trackpad.now })
    play([0, 0.2], on: runner)
    #expect(trackpad.loadCount == 2)
    #expect(trackpad.taps.count == 2)
  }

  @Test("While the fallback plays, the trackpads are looked for again from time to time")
  func fallbackRetried() {
    let trackpad = FakeTrackpad()
    let runner = RhythmRunner(
      load: { trackpad.tapper(gap: 0.4, fallback: true) }, sleep: { trackpad.sleep($0) },
      now: { trackpad.now })
    play([0], on: runner)
    play([0], on: runner)
    #expect(trackpad.loadCount == 1)
    trackpad.advance(RhythmRunner.retryInterval)
    play([0], on: runner)
    #expect(trackpad.loadCount == 2)
  }

  @Test("Not a trackpad that loses close taps: kept for the run")
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
    let runner = RhythmRunner(load: { trackpad.tapper(gap: 0.09) })
    let generation = runner.begin()
    let done = Task.detached {
      runner.run(AlertSoundRhythm(taps: [0, 3_600]), generation: generation)
    }
    while trackpad.taps.isEmpty { await Task.yield() }
    _ = runner.begin()
    await done.value
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
