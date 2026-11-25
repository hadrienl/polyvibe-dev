import CompanionCore
import Foundation
import Observation
import VibeApplication
import VibeDomain

/// Each phone showing a conversation counts as a viewer of its usage (#631), independently of
/// the Mac and other phones. Only changed figures travel over the direct channel.
@MainActor
public final class CompanionUsageFeed {
  private struct Watch {
    var session: SessionID
    var sent: RemoteSessionUsage?
  }

  private let usage: UsageModel
  private let sessions: () -> [WorkSession]
  private let agentNames: () -> [String: String]
  private let send: @MainActor (String, RemoteSessionUsage) -> Void
  private var watches: [String: Watch] = [:]
  private var generation = 0

  public init(
    usage: UsageModel, sessions: @escaping () -> [WorkSession],
    agentNames: @escaping () -> [String: String],
    send: @escaping @MainActor (String, RemoteSessionUsage) -> Void
  ) {
    self.usage = usage
    self.sessions = sessions
    self.agentNames = agentNames
    self.send = send
  }

  public func follow(_ session: SessionID, for peer: String) {
    stop(peer)
    usage.startWatching(session)
    watches[peer] = Watch(session: session)
    generation += 1
    read(generation)
  }

  public func stop(_ peer: String) {
    guard let watch = watches.removeValue(forKey: peer) else { return }
    usage.stopWatching(watch.session)
    generation += 1
    read(generation)
  }

  private func read(_ generation: Int) {
    guard generation == self.generation, !watches.isEmpty else { return }
    let values = withObservationTracking {
      let sessions = sessions()
      let names = agentNames()
      return watches.mapValues { watch in
        Self.figures(
          of: watch.session, session: sessions.first { $0.id == watch.session },
          usage: usage, agentNames: names)
      }
    } onChange: { [weak self] in
      Task { @MainActor in self?.read(generation) }
    }
    for (peer, figures) in values where watches[peer]?.sent != figures {
      watches[peer]?.sent = figures
      send(peer, figures)
    }
  }

  static func figures(
    of id: SessionID, session: WorkSession?, usage: UsageModel, agentNames: [String: String]
  ) -> RemoteSessionUsage {
    let conversion = usage.conversion
    var result = RemoteSessionUsage(
      sessionID: id.rawValue.uuidString, isTrackingOn: usage.isTrackingEnabled,
      currency: conversion.code)
    guard usage.isTrackingEnabled, let session else { return result }
    let figures = usage.sessionUsage[id]
    if let context = usage.contextWindows[id] {
      result.context = RemoteUsageContext(
        usedTokens: context.usedTokens, windowSize: context.windowSize,
        percentUsed: context.percentUsed, isEstimate: context.isEstimate)
    }
    if let reason = usage.contextUnavailability(for: session) {
      result.contextUnavailable =
        switch reason {
        case .trackingOff: "trackingOff"
        case .notReportedByAgent: "notReportedByAgent"
        case .noResponseYet: "noResponseYet"
        }
    }
    result.runningTime = figures?.total.runningTime
    if let figures, figures.total.hasReportedTokens {
      let tokens = figures.total.tokens
      // Reasoning is already part of output, as in the Mac's token total.
      result.tokens = tokens.input + tokens.cacheRead + tokens.cacheWrite + tokens.output
      result.cost = cost(figures, conversion: conversion)
      result.models = figures.models.compactMap { row in
        guard case .model(let provider, let model) = row.key, !row.tokens.isZero else {
          return nil
        }
        return RemoteModelCost(
          providerName: agentNames[provider] ?? provider, model: model,
          amount: figures.cost.priced[UsageModelKey(providerID: provider, model: model)].map {
            $0 * conversion.perDollar
          })
      }
    }
    if let reason = usage.tokenUnavailability(for: session) {
      result.tokensUnavailable =
        switch reason {
        case .trackingOff: "trackingOff"
        case .notReportedByAgent: "notReportedByAgent"
        case .noTranscript: "noTranscript"
        }
    }
    if let family = usage.family(of: id) {
      result.family = RemoteFamilyUsage(
        cost: cost(family.total, conversion: conversion),
        children: family.children.map { child in
          RemoteFamilyUsage.Child(
            id: child.id.rawValue.uuidString, name: child.name, depth: child.depth,
            cost: child.figures.flatMap { cost($0, conversion: conversion) })
        })
    }
    return result
  }

  private static func cost(_ figures: SessionUsage, conversion: CostConversion) -> RemoteQuotaCost?
  {
    guard figures.total.hasReportedTokens,
      figures.cost.hasPrice || !figures.cost.unpriced.isEmpty
    else { return nil }
    return RemoteQuotaCost(
      amount: figures.cost.total * conversion.perDollar, hasPrice: figures.cost.hasPrice,
      leavesOutUnpriced: !figures.cost.unpriced.isEmpty)
  }
}
