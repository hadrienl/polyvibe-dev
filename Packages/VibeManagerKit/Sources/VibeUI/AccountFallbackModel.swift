import Foundation
import Observation

/// The backup chain of Settings › Backup Accounts (#600): the accounts a session goes on with
/// when the one it runs on reaches its limit, by order of priority — the first one free. One chain for every session: a session
/// on an account the chain leaves out never moves.
@MainActor
@Observable
public final class AccountFallbackModel {
  /// The providers of the chain, in order: `claude-code`, `codex`, an account of #478.
  public private(set) var chain: [String] {
    didSet { defaults?.set(chain, forKey: Self.chainKey) }
  }

  @ObservationIgnored private let defaults: UserDefaults?

  static let chainKey = "accountFallbackChain"

  public init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    chain = defaults?.stringArray(forKey: Self.chainKey) ?? []
  }

  /// A chain of one account has nowhere to go: nothing moves.
  public var isActive: Bool { chain.count > 1 }

  public func contains(_ providerID: String) -> Bool { chain.contains(providerID) }

  /// Puts an account at the end of the chain, or takes it out.
  public func setIncluded(_ included: Bool, _ providerID: String) {
    if included {
      guard !chain.contains(providerID) else { return }
      chain.append(providerID)
    } else {
      chain.removeAll { $0 == providerID }
    }
  }

  /// Moves an account of the chain one place up (`-1`) or down (`1`) among those `shown`: past
  /// its visible neighbour, whatever account no longer plugged in lies between them.
  public func move(_ providerID: String, by offset: Int, among shown: [String]) {
    let visible = self.shown(among: shown)
    guard let position = visible.firstIndex(of: providerID),
      visible.indices.contains(position + offset),
      let index = chain.firstIndex(of: providerID),
      let neighbour = chain.firstIndex(of: visible[position + offset])
    else { return }
    chain.swapAt(index, neighbour)
  }

  /// The accounts no longer plugged in are left in the chain, out of sight: an agent missing at
  /// one launch — its CLI being updated — keeps its place. Only those shown are offered.
  public func shown(among providerIDs: [String]) -> [String] {
    chain.filter(providerIDs.contains)
  }
}
