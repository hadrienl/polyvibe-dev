import AppKit
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The quota of every account plugged in (#599): Claude Code, Codex, Antigravity and the extra
/// accounts of #478, each asked through its own CLI.
///
/// Asked when the Quotas popover or a session's Usage popover opens, then every minute while one
/// stays open; in the background every ten minutes while the application is in front, for the
/// accounts used in the last day. An account is never asked twice in thirty seconds, and nothing
/// is asked while usage tracking is off. What is read is never written to disk.
@MainActor
@Observable
public final class QuotaModel {
  /// Whether shares are shown as what was used or what is left: one choice for every agent.
  public enum Display: String, CaseIterable, Sendable {
    case used
    case remaining
  }

  public struct Account: Identifiable, Hashable, Sendable {
    /// The provider's identifier: `claude-code`, `codex`, `antigravity`, `account.<uuid>`.
    public let id: String
    public let name: String
    public let symbolName: String
    /// Where the provider's usage page is, when it has one.
    public let usageURL: URL?

    public init(id: String, name: String, symbolName: String, usageURL: URL? = nil) {
      self.id = id
      self.name = name
      self.symbolName = symbolName
      self.usageURL = usageURL
    }
  }

  public var display: Display {
    didSet { defaults?.set(display.rawValue, forKey: Self.displayKey) }
  }
  public private(set) var accounts: [Account] = []
  public private(set) var entries: [String: AccountQuotaService.Entry] = [:]
  public private(set) var asking: Set<String> = []

  static let displayKey = "quotaDisplay"

  @ObservationIgnored private let service: AccountQuotaService
  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private var reporters: [String: any AgentQuotaReporting] = [:]
  @ObservationIgnored var isTrackingEnabled: () -> Bool = { true }
  @ObservationIgnored var recentlyUsed: () -> Set<String> = { [] }
  /// What each popover open watches: its accounts, or every one for `nil`.
  @ObservationIgnored private var watches: [UUID: [String]?] = [:]
  /// Moved on when tracking is turned off: a reading asked before is not kept.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var watchTask: Task<Void, Never>?
  @ObservationIgnored private var backgroundTask: Task<Void, Never>?
  @ObservationIgnored private let watchInterval: Duration
  @ObservationIgnored private let backgroundInterval: Duration

  public init(
    service: AccountQuotaService = AccountQuotaService(), defaults: UserDefaults? = nil,
    watchInterval: Duration = .seconds(60), backgroundInterval: Duration = .seconds(600)
  ) {
    self.service = service
    self.defaults = defaults
    self.watchInterval = watchInterval
    self.backgroundInterval = backgroundInterval
    display = defaults?.string(forKey: Self.displayKey).flatMap(Display.init(rawValue:)) ?? .used
  }

  /// The accounts that can tell their quota, in the order of the agents: set again whenever the
  /// list of agents changes.
  public func connect(accounts: [(Account, any AgentQuotaReporting)]) {
    self.accounts = accounts.map(\.0)
    reporters = Dictionary(
      accounts.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
    entries = entries.filter { reporters[$0.key] != nil }
  }

  /// The account's last reading, if it was ever asked.
  public func entry(for providerID: String) -> AccountQuotaService.Entry? {
    entries[providerID]
  }

  public func isAccount(_ providerID: String) -> Bool { reporters[providerID] != nil }

  /// Asks the accounts — all of them by default — unless they were in the last thirty seconds.
  public func refresh(_ providerIDs: [String]? = nil) async {
    guard isTrackingEnabled() else { return }
    let ids = providerIDs ?? accounts.map(\.id)
    let generation = generation
    await withTaskGroup(of: (String, AccountQuotaService.Entry).self) { group in
      for id in ids {
        guard let reporter = reporters[id], !asking.contains(id) else { continue }
        asking.insert(id)
        group.addTask { [service] in (id, await service.refresh(id, with: reporter)) }
      }
      for await (id, entry) in group {
        // Tracking turned off meanwhile: what comes back is not kept.
        guard generation == self.generation, isTrackingEnabled() else { continue }
        entries[id] = entry
        asking.remove(id)
      }
    }
  }

  /// The account's quota read after `date` (#600): asked now unless it already was since. `nil`
  /// while tracking is off, and for an account that cannot tell its quota.
  public func reading(of providerID: String, since date: Date) async -> AccountQuotaService.Entry? {
    guard isTrackingEnabled(), let reporter = reporters[providerID] else { return nil }
    let generation = generation
    var entry = await service.refresh(providerID, with: reporter, freshSince: date)
    // A reading already under way when asked was started before: the next one is not.
    if entry.readAt < date {
      entry = await service.refresh(providerID, with: reporter, freshSince: date)
    }
    guard generation == self.generation, isTrackingEnabled() else { return nil }
    entries[providerID] = entry
    return entry
  }

  // MARK: - When

  /// A popover that shows quotas opened: its accounts — every one for `nil` — asked now, then
  /// every minute until it closes. The watch returned is the one to stop: each popover stops its
  /// own, whatever changed meanwhile.
  @discardableResult
  public func startWatching(_ providerIDs: [String]? = nil) -> UUID {
    let watch = UUID()
    watches[watch] = .some(providerIDs)
    Task { await refresh(providerIDs) }
    if watchTask == nil {
      let interval = watchInterval
      watchTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
          guard !Task.isCancelled, let self else { return }
          await self.refresh(self.watched)
        }
      }
    }
    return watch
  }

  public func stopWatching(_ watch: UUID) {
    watches[watch] = nil
    guard watches.isEmpty else { return }
    watchTask?.cancel()
    watchTask = nil
  }

  /// The accounts the popovers open show: every one as soon as one shows them all.
  var watched: [String]? {
    var ids: Set<String> = []
    for scope in watches.values {
      guard let scope else { return nil }
      ids.formUnion(scope)
    }
    return accounts.map(\.id).filter(ids.contains)
  }

  /// The gauge of the header follows the accounts used in the last day, every ten minutes while
  /// the application is in front.
  public func startBackground() {
    guard backgroundTask == nil else { return }
    let interval = backgroundInterval
    backgroundTask = Task { [weak self] in
      // Once the agents have been found, not during the launch.
      try? await Task.sleep(for: .seconds(5))
      while !Task.isCancelled {
        guard let self else { return }
        if NSApplication.shared.isActive {
          let recent = self.recentlyUsed()
          let ids = self.accounts.map(\.id).filter { recent.contains($0) }
          if !ids.isEmpty { await self.refresh(ids) }
        }
        try? await Task.sleep(for: interval)
      }
    }
  }

  public func stopBackground() {
    backgroundTask?.cancel()
    backgroundTask = nil
  }

  /// Tracking turned off: nothing more is shown or asked.
  func trackingChanged(_ enabled: Bool) async {
    if !enabled {
      generation += 1
      entries = [:]
      asking = []
      await service.clear()
    }
  }

  // MARK: - The gauge

  /// The window nearest its limit among every account's, and how near.
  public func gauge(at now: Date = Date()) -> QuotaGauge {
    guard isTrackingEnabled() else { return QuotaGauge(level: .unknown, usedFraction: nil) }
    let windows = accounts.compactMap { entries[$0.id]?.reading.quota?.mostUsed(at: now) }
    guard let most = windows.map(\.usedFraction).max() else {
      return QuotaGauge(level: .unknown, usedFraction: nil)
    }
    return QuotaGauge(level: QuotaGauge.level(for: most), usedFraction: most)
  }

  /// The accounts with a window spent, with the names of those windows.
  public func blocked(at now: Date = Date()) -> [(Account, [QuotaWindow])] {
    accounts.compactMap { account in
      let spent = (entries[account.id]?.reading.quota?.windows ?? []).filter {
        $0.isExhausted && !$0.hasReset(at: now)
      }
      return spent.isEmpty ? nil : (account, spent)
    }
  }
}

/// The needle and colour of the header's dial: green under four fifths used, orange up to the
/// limit, red at it, grey without any figure. These colours belong to the dial alone: elsewhere
/// orange still means an agent is waiting (ADR 0024).
public struct QuotaGauge: Hashable, Sendable {
  public enum Level: Hashable, Sendable {
    case normal
    case near
    case reached
    case unknown
  }

  public static let nearThreshold = 0.8

  public let level: Level
  /// The share used of the window nearest its limit.
  public let usedFraction: Double?

  public static func level(for usedFraction: Double) -> Level {
    if usedFraction >= 1 { return .reached }
    if usedFraction >= nearThreshold { return .near }
    return .normal
  }

  /// Where the needle points, from 0 on the left to 1 on the right, in the display chosen.
  public func needle(_ display: QuotaModel.Display) -> Double {
    guard let usedFraction else { return 0 }
    return display == .used ? usedFraction : 1 - usedFraction
  }
}
