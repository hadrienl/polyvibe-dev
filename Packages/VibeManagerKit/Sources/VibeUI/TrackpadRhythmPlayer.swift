import AppKit
import IOKit
import VibeApplication
import os

/// Plays the rhythm of the alert sound on the trackpad (#555): the application's trackpad, in the
/// tests a recorder.
@MainActor
public protocol AlertRhythmPlaying: AnyObject {
  /// Readies the trackpad ahead of the first alert: opening it took over a second on a loaded
  /// machine, and the first tap must fall with the sound.
  func prepare()
  /// Plays `rhythm` from now, in place of one still playing.
  func play(_ rhythm: AlertSoundRhythm)
}

/// One tap on the trackpad, away from the main actor.
protocol HapticTapping: Sendable {
  /// The least time between two taps it renders as two.
  var minimumGap: Double { get }
  /// Whether it stands in for the trackpads, which are looked for again from time to time.
  var isFallback: Bool { get }
  /// Whether a trackpad took it.
  func tap() -> Bool
}

extension HapticTapping {
  var isFallback: Bool { false }
}

/// The trackpad of the Mac, and any Magic Trackpad: through MultitouchSupport, whose taps are all
/// felt, or through AppKit's haptic feedback when it cannot be loaded (ADR 0045).
@MainActor
public final class TrackpadRhythmPlayer: AlertRhythmPlaying {
  private let runner: RhythmRunner

  public convenience init() {
    self.init(runner: RhythmRunner(load: TrackpadRhythmPlayer.loadTapper))
  }

  init(runner: RhythmRunner) {
    self.runner = runner
  }

  public func prepare() {
    let runner = runner
    Self.detach { _ = runner.tapper() }
  }

  public func play(_ rhythm: AlertSoundRhythm) {
    let runner = runner
    let generation = runner.begin()
    Self.detach { runner.run(rhythm, generation: generation) }
  }

  /// A thread of its own, which sleeps between two taps: a rhythm lasts as long as its sound, up
  /// to 30 seconds, too long to hold a thread of the shared pool.
  private static func detach(_ work: @escaping @Sendable () -> Void) {
    let thread = Thread(block: work)
    thread.name = "Alert rhythm"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  nonisolated static let log = Logger(subsystem: "eu.hadrien.VibeManager", category: "haptics")

  nonisolated static func loadTapper() -> any HapticTapping {
    if let multitouch = MultitouchTapper.load() {
      log.info(
        "Alert rhythm on \(multitouch.count, privacy: .public) trackpad(s) (MultitouchSupport)")
      return multitouch
    }
    log.info("Alert rhythm through NSHapticFeedbackManager: MultitouchSupport unavailable")
    return FeedbackTapper()
  }
}

/// Plays a rhythm on a tapper, its taps kept apart however late the machine runs: a tap that comes
/// late never falls on the next one, which would be felt as one.
final class RhythmRunner: @unchecked Sendable {
  /// What a late tap keeps, at least, of the time between it and the one before.
  static let keptShare = 0.6
  /// How often the trackpads are looked for again while the fallback plays: a Magic Trackpad
  /// connects after the application has started.
  static let retryInterval: Double = 30

  private let load: @Sendable () -> any HapticTapping
  /// In the tests, a clock that moves; otherwise a wait a newer rhythm cuts short.
  private let sleep: (@Sendable (Double) -> Void)?
  private let now: @Sendable () -> Double
  /// The rhythm playing: a newer one wakes it and stops it before its next tap.
  private let state = NSCondition()
  private var generation = 0
  /// The tapper and when it was loaded — away from `state`, which the main actor takes.
  private let loading = NSLock()
  private var loaded: (tapper: any HapticTapping, at: Double)?

  init(
    load: @escaping @Sendable () -> any HapticTapping,
    sleep: (@Sendable (Double) -> Void)? = nil,
    now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.load = load
    self.sleep = sleep
    self.now = now
  }

  /// The tapper loaded, or loaded now: the fallback is kept only `retryInterval` seconds.
  func tapper() -> any HapticTapping {
    loading.withLock {
      let time = now()
      if let loaded, !loaded.tapper.isFallback || time - loaded.at < Self.retryInterval {
        return loaded.tapper
      }
      // The one before is let go first: a trackpad may open for one owner at a time.
      loaded = nil
      let tapper = load()
      loaded = (tapper, time)
      return tapper
    }
  }

  /// Forgets a tapper that failed: a trackpad unplugged, another plugged in.
  private func forget() {
    loading.withLock { loaded = nil }
  }

  /// Starts a rhythm: the one playing stops.
  func begin() -> Int {
    state.lock()
    defer { state.unlock() }
    generation += 1
    state.broadcast()
    return generation
  }

  private func isCurrent(_ generation: Int) -> Bool {
    state.lock()
    defer { state.unlock() }
    return self.generation == generation
  }

  /// Waits `seconds`, or less when a newer rhythm starts.
  private func pause(_ seconds: Double, generation: Int) {
    if let sleep {
      sleep(seconds)
      return
    }
    let deadline = Date(timeIntervalSinceNow: seconds)
    state.lock()
    defer { state.unlock() }
    while self.generation == generation, state.wait(until: deadline) {
      // Woken: by a newer rhythm, which the condition reads, or for nothing.
    }
  }

  func run(_ rhythm: AlertSoundRhythm, generation: Int) {
    var tapper: (any HapticTapping)? = tapper()
    var reloaded = false
    let taps = rhythm.spaced(by: tapper?.minimumGap ?? 0).taps
    let start = now()
    var previous: (planned: Double, at: Double)?
    for planned in taps {
      guard isCurrent(generation) else { return }
      let current = now()
      var wait = start + planned - current
      if let previous {
        wait = max(wait, (planned - previous.planned) * Self.keptShare - (current - previous.at))
      }
      if wait > 0 { pause(wait, generation: generation) }
      guard isCurrent(generation) else { return }
      if tapper?.tap() == false, !reloaded {
        reloaded = true
        // Let go before the trackpads are opened again.
        tapper = nil
        forget()
        tapper = self.tapper()
        _ = tapper?.tap()
      }
      previous = (planned, now())
    }
  }
}

/// AppKit's haptic feedback: public, but it loses taps closer than about 400 ms, and now and then
/// a whole rhythm (#555). The fallback.
struct FeedbackTapper: HapticTapping {
  let minimumGap = 0.4
  let isFallback = true

  func tap() -> Bool {
    Task { @MainActor in
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
    return true
  }
}

/// The actuators of MultitouchSupport, a private framework of macOS: every tap felt, even closer
/// than 100 ms, the application in front or not (#555). Loaded by name; a symbol missing — a later
/// macOS — and the fallback plays instead.
final class MultitouchTapper: HapticTapping, @unchecked Sendable {
  private typealias Create = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
  private typealias Open = @convention(c) (CFTypeRef) -> Int32
  private typealias Close = @convention(c) (CFTypeRef) -> Int32
  private typealias Actuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

  static let path =
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
  /// The actuation felt clearly, and the same on every trackpad tried (#555).
  static let actuation: Int32 = 6

  let minimumGap = AlertSoundRhythm.mergeInterval
  private let actuate: Actuate
  private let close: Close?
  private let actuators: [CFTypeRef]
  /// Two rhythms overlap for an instant when one replaces the other.
  private let lock = NSLock()

  var count: Int { actuators.count }

  private init(actuate: Actuate, close: Close?, actuators: [CFTypeRef]) {
    self.actuate = actuate
    self.close = close
    self.actuators = actuators
  }

  deinit {
    for actuator in actuators { _ = close?(actuator) }
  }

  /// The actuators of every trackpad that has one, opened; `nil` when there is none, or the
  /// framework is not what it was.
  static func load() -> MultitouchTapper? {
    guard let handle = dlopen(path, RTLD_NOW),
      let createSymbol = dlsym(handle, "MTActuatorCreateFromDeviceID"),
      let openSymbol = dlsym(handle, "MTActuatorOpen"),
      let actuateSymbol = dlsym(handle, "MTActuatorActuate")
    else { return nil }
    let create = unsafeBitCast(createSymbol, to: Create.self)
    let open = unsafeBitCast(openSymbol, to: Open.self)
    let close = dlsym(handle, "MTActuatorClose").map { unsafeBitCast($0, to: Close.self) }
    let actuators = deviceIDs().compactMap { id -> CFTypeRef? in
      guard let actuator = create(id)?.takeRetainedValue() else { return nil }
      return open(actuator) == 0 ? actuator : nil
    }
    guard !actuators.isEmpty else { return nil }
    return MultitouchTapper(
      actuate: unsafeBitCast(actuateSymbol, to: Actuate.self), close: close, actuators: actuators)
  }

  /// The multitouch devices that say they can actuate, by their identifier: a Magic Mouse is a
  /// multitouch device too.
  static func deviceIDs() -> [UInt64] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var ids: [UInt64] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      let actuates = property("ActuationSupported", of: service) as? Bool ?? false
      if actuates, let id = property("Multitouch ID", of: service) as? NSNumber {
        ids.append(id.uint64Value)
      }
    }
    return ids
  }

  private static func property(_ key: String, of service: io_object_t) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
  }

  func tap() -> Bool {
    lock.withLock {
      actuators.reduce(false) { felt, actuator in
        actuate(actuator, Self.actuation, 0, 0, 0) == 0 || felt
      }
    }
  }
}
