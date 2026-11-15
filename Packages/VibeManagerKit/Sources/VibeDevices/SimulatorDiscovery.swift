import Foundation

/// One shared probe, independent of a caller's lifetime. Slow simctl must not hold up adb.
actor SimulatorDiscovery {
  struct Snapshot: Sendable {
    let devices: [DeviceCatalog.Device]
    let isRefreshing: Bool
  }

  private let load: @Sendable () async -> [DeviceCatalog.Device]?
  private let freshness: Duration
  private var devices: [DeviceCatalog.Device]?
  private var updatedAt: ContinuousClock.Instant?
  private var refresh: Task<Void, Never>?

  init(
    freshness: Duration = .seconds(5),
    load: @escaping @Sendable () async -> [DeviceCatalog.Device]?
  ) {
    self.freshness = freshness
    self.load = load
  }

  func snapshot(coldWait: Duration = .milliseconds(200)) async -> Snapshot {
    let isStale = updatedAt.map { $0.duration(to: .now) >= freshness } ?? true
    if refresh == nil && isStale {
      refresh = Task {
        let result = await load()
        if let result { devices = result }
        updatedAt = .now
        refresh = nil
      }
    }
    // Give a fast first probe a chance, then return; the shared probe keeps running.
    if devices == nil && refresh != nil { try? await Task.sleep(for: coldWait) }
    return Snapshot(devices: devices ?? [], isRefreshing: refresh != nil)
  }

  /// Waits for the current probe without starting another one.
  func settled() async {
    await refresh?.value
  }
}
