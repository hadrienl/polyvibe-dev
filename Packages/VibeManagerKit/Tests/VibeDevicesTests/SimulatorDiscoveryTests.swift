import Foundation
import Testing

@testable import VibeDevices

@Suite("Simulator discovery without holding up phones")
struct SimulatorDiscoveryTests {
  @Test("A slow probe returns a pending snapshot, shares its work, then publishes simulators")
  func slowProbe() async {
    let probe = Probe()
    let cache = SimulatorDiscovery { await probe.load() }
    let first = await cache.snapshot(coldWait: .zero)
    #expect(first.devices.isEmpty && first.isRefreshing)
    await probe.waitUntilStarted()
    let second = await cache.snapshot(coldWait: .zero)
    #expect(second.isRefreshing)
    #expect(await probe.calls == 1)
    let simulator = DeviceCatalog.Device(id: "SIM", name: "iPhone")
    await probe.complete([simulator])
    await cache.settled()
    let loaded = await cache.snapshot(coldWait: .zero)
    #expect(loaded.devices == [simulator] && !loaded.isRefreshing)
    #expect(await probe.calls == 1)
  }

  @Test("A failed refresh keeps known simulators; a successful empty result removes them")
  func refreshResults() async {
    let probe = Probe()
    let cache = SimulatorDiscovery(freshness: .zero) { await probe.load() }
    _ = await cache.snapshot(coldWait: .zero)
    await probe.waitUntilStarted()
    let simulator = DeviceCatalog.Device(id: "SIM", name: "iPhone")
    await probe.complete([simulator])
    await cache.settled()
    let refreshing = await cache.snapshot(coldWait: .zero)
    #expect(refreshing.devices == [simulator] && refreshing.isRefreshing)
    await probe.waitUntilStarted(count: 2)
    await probe.complete(nil)
    await cache.settled()
    let retained = await cache.snapshot(coldWait: .zero)
    #expect(retained.devices == [simulator])
    await probe.waitUntilStarted(count: 3)
    await probe.complete([])
    await cache.settled()
    // Even while the next refresh starts, the stopped simulator is already gone.
    let empty = await cache.snapshot(coldWait: .zero)
    #expect(empty.devices.isEmpty)
    await probe.waitUntilStarted(count: 4)
    await probe.complete([])
    await cache.settled()
  }

  @Test("Cancelling a listing does not cancel shared simulator discovery")
  func cancelledCaller() async {
    let probe = Probe()
    let cache = SimulatorDiscovery { await probe.load() }
    let caller = Task { await cache.snapshot(coldWait: .seconds(60)) }
    await probe.waitUntilStarted()
    caller.cancel()
    let pending = await caller.value
    #expect(pending.isRefreshing)
    let simulator = DeviceCatalog.Device(id: "SIM", name: "iPhone")
    await probe.complete([simulator])
    await cache.settled()
    let loaded = await cache.snapshot(coldWait: .zero)
    #expect(loaded.devices == [simulator] && !loaded.isRefreshing)
  }

  private actor Probe {
    private(set) var calls = 0
    private var result: CheckedContinuation<[DeviceCatalog.Device]?, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func load() async -> [DeviceCatalog.Device]? {
      calls += 1
      started?.resume()
      started = nil
      return await withCheckedContinuation { result = $0 }
    }

    func waitUntilStarted(count: Int = 1) async {
      if calls < count { await withCheckedContinuation { started = $0 } }
    }

    func complete(_ devices: [DeviceCatalog.Device]?) {
      result?.resume(returning: devices)
      result = nil
    }
  }
}
