import CompanionCore
import Foundation
import Observation
import VibeApplication

/// The quotas the paired phones watch (#630), read from the same models as the Quotas popover.
///
/// A phone showing its list follows the dial: the accounts used in the last day are asked now,
/// then every ten minutes, even with another application in front. A phone showing its Quotas
/// sheet watches as the popover does: every account at once and every minute, and the costs of the
/// last thirty days. Each phone gets the quotas at once, then at each change, until it stops or
/// goes; an account is still never asked twice in thirty seconds, however many phones watch.
@MainActor
public final class CompanionQuotaFeed {
  private struct Watch {
    var follow: UUID?
    var popover: UUID?
    var sent: RemoteQuotas?
  }

  private let usage: UsageModel
  private let send: @MainActor (String, RemoteQuotas) -> Void
  private var watches: [String: Watch] = [:]
  private var observing = false

  public init(usage: UsageModel, send: @escaping @MainActor (String, RemoteQuotas) -> Void) {
    self.usage = usage
    self.send = send
  }

  /// What `peer` shows now; `nil` once it shows no quota.
  public func watch(_ kind: RemoteQuotaWatch?, for peer: String) {
    stop(peer)
    guard let kind else { return }
    var watch = Watch()
    switch kind {
    case .gauge:
      watch.follow = usage.quotas.startFollowing()
    case .sheet:
      watch.popover = usage.quotas.startWatching()
      usage.startWatching()
    }
    let quotas = Self.quotas(of: usage)
    watch.sent = quotas
    watches[peer] = watch
    send(peer, quotas)
    observe()
  }

  /// `peer` went, or stopped watching.
  public func stop(_ peer: String) {
    guard let watch = watches.removeValue(forKey: peer) else { return }
    if let follow = watch.follow { usage.quotas.stopFollowing(follow) }
    if let popover = watch.popover {
      usage.quotas.stopWatching(popover)
      usage.stopWatching()
    }
  }

  private func observe() {
    guard !observing else { return }
    observing = true
    read()
  }

  private func read() {
    // No phone left: nothing to compute until one watches again.
    guard !watches.isEmpty else {
      observing = false
      return
    }
    let quotas = withObservationTracking {
      Self.quotas(of: usage)
    } onChange: { [weak self] in
      Task { @MainActor in self?.read() }
    }
    for (peer, watch) in watches where watch.sent != quotas {
      watches[peer]?.sent = quotas
      send(peer, quotas)
    }
  }

  /// Every account and its quota, as the Quotas popover shows them; costs in the currency chosen.
  static func quotas(of usage: UsageModel) -> RemoteQuotas {
    let quotas = usage.quotas
    let conversion = usage.conversion
    let showsRemaining = quotas.display == .remaining
    guard usage.isTrackingEnabled else {
      return RemoteQuotas(
        isTrackingOn: false, showsRemaining: showsRemaining, currency: conversion.code,
        accounts: [])
    }
    let accounts = quotas.accounts.map { account in
      var remote = RemoteQuotaAccount(
        id: account.id, name: account.name, usageURL: account.usageURL,
        isAsking: quotas.asking.contains(account.id))
      switch quotas.entry(for: account.id)?.reading {
      case .measured(let quota):
        remote.plan = quota.plan
        remote.measuredAt = quota.measuredAt
        remote.windows = quota.windows.map(Self.window)
      case .unavailable(let reason):
        remote.unavailable = Self.unavailability(reason)
      case nil:
        break
      }
      remote.cost = usage.accountCosts[account.id].map {
        RemoteQuotaCost(
          amount: $0.total * conversion.perDollar, hasPrice: $0.hasPrice,
          leavesOutUnpriced: !$0.unpriced.isEmpty)
      }
      return remote
    }
    return RemoteQuotas(
      isTrackingOn: true, showsRemaining: showsRemaining, currency: conversion.code,
      accounts: accounts)
  }

  private static func window(_ window: QuotaWindow) -> RemoteQuotaWindow {
    let kind: RemoteQuotaWindow.Kind =
      switch window.kind {
      case .session: .session
      case .minutes(let minutes): .minutes(minutes)
      case .weekly: .weekly
      case .weeklyModel(let model): .weeklyModel(model)
      case .group(let name): .group(name)
      }
    return RemoteQuotaWindow(
      id: window.id, kind: kind, usedFraction: window.usedFraction, resetsAt: window.resetsAt)
  }

  private static func unavailability(_ reason: QuotaUnavailability) -> RemoteQuotaUnavailability {
    switch reason {
    case .notReportedByAgent: .notReportedByAgent
    case .notInstalled: .notInstalled
    case .signedOut: .signedOut
    case .unrecognized: .unrecognized
    case .failed: .failed
    case .trackingOff: .trackingOff
    }
  }
}
