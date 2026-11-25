import Foundation
import VibeApplication
import VibeDomain

/// A session whose account reaches its limit goes on with the next account of the backup chain
/// (#600), by the switch the user would make: the agent stopped, its logs copied for the next one
/// — a summary and the request that failed when there are none —, the separator of the
/// conversation saying why.
///
/// Only the account's limit moves it. The turn ended on the provider's refusal at a limit, and the
/// CLI, asked right after, says a window of the account's quota is spent and does not come back
/// within a quarter of an hour. Nothing that would be lost is stopped: the session must still be
/// running, with nothing at work behind it and nothing typed into its prompt. The chain is an
/// order of priority: a session goes back up it only at its next limit, never while it works.
extension AppModel {
  /// How long a turn that just ended is given for its transcript to say why: the refusal is
  /// written as the turn stops, and read a moment later.
  static let accountLimitSettling: Duration = .seconds(2)

  /// A turn of the session ended: looked into when the session's account is in the chain.
  func accountFallbackActivityChanged(
    _ id: SessionID, from previous: AgentActivityState?, to state: AgentActivityState
  ) {
    guard case .working? = previous?.activity else { return }
    // Antigravity writes its refusal nowhere but the terminal: its request says it (#599).
    let quotaSpent = state.requests.contains { request in
      guard case .inTerminal(let prompt) = request.content else { return false }
      return prompt.reportsQuotaExhausted
    }
    // Any other refusal ends the turn at rest; a permission or a question asked is no refusal.
    guard quotaSpent || state.activity == .idle else { return }
    guard accountFallback.isActive,
      let providerID = sessions.first(where: { $0.id == id })?.agent?.providerID,
      accountFallback.contains(providerID), fallingBackSessionIDs.insert(id).inserted
    else { return }
    let endedAt = clock.now()
    Task { [weak self] in
      await self?.fallBackIfLimited(id, from: providerID, endedAt: endedAt, quotaSpent: quotaSpent)
      self?.fallingBackSessionIDs.remove(id)
    }
  }

  func fallBackIfLimited(
    _ id: SessionID, from providerID: String, endedAt: Date, quotaSpent: Bool
  ) async {
    if !quotaSpent {
      guard await endsOnLimitError(id) else { return }
    }
    guard let limit = await accountLimit(of: providerID, since: endedAt) else { return }
    diagnostics.record(
      .session, .info, "session.accountLimit",
      [
        "session": diagnostics.pseudonym(id),
        "agent": .token(AgentProviderID(providerID).diagnosticToken),
      ])
    await fallBack(id, from: providerID, limit: limit)
  }

  /// Whether the session's conversation ends on the provider's refusal at a limit. A conversation
  /// on screen is given a few moments to show the line, written as the turn stops; one that is
  /// not is read from its transcripts once, whole.
  private func endsOnLimitError(_ id: SessionID) async -> Bool {
    for _ in 0..<3 {
      try? await Task.sleep(for: Self.accountLimitSettling)
      guard let session = sessions.first(where: { $0.id == id }) else { return false }
      // Written to again meanwhile: the turn that failed is behind.
      if activity(for: id)?.activity == .working { return false }
      let isFollowed = conversations.existingModel(for: id) != nil
      if let entries = await conversations.entries(of: session),
        AccountFallbackRules.endsOnLimitError(entries)
      {
        return true
      }
      if !isFollowed { return false }
    }
    return false
  }

  /// The limit the account is at, by what its CLI says after `date`; remembered either way. An
  /// answer from before — its CLI failing now, the last figures kept — says nothing of now.
  func accountLimit(of providerID: String, since date: Date) async -> AccountLimit? {
    guard let entry = await quotaReading(of: providerID, since: date), entry.readAt >= date
    else { return nil }
    let limit = AccountFallbackRules.limit(of: entry.reading.quota, at: clock.now())
    limitedAccounts[providerID] = limit
    return limit
  }

  private func quotaReading(of providerID: String, since date: Date) async
    -> AccountQuotaService.Entry?
  {
    await usage?.quotas.reading(of: providerID, since: date)
  }

  /// Moves the session to the account of the chain highest in priority, `providerID` aside, that
  /// can run, is signed in and is not at its limit: one above it that has its quota back is taken
  /// before those below. None left, the session stays as it stopped, the refusal in its
  /// conversation.
  func fallBack(_ id: SessionID, from providerID: String, limit: AccountLimit) async {
    guard let agents, let planAgentSwitch else { return }
    for candidate in AccountFallbackRules.candidates(
      besides: providerID, in: accountFallback.chain)
    {
      if limitedAccounts[candidate]?.holds(at: clock.now()) == true { continue }
      guard let provider = await agents.provider(id: AgentProviderID(candidate)),
        await provider.availability(forceRefresh: false).isUsable
      else { continue }
      if usage?.quotas.isAccount(candidate) == true {
        // What it said in the last half minute will do: it is not the account that just failed.
        let entry = await quotaReading(of: candidate, since: .distantPast)
        // Signed out, the session would wait on its sign-in rather than go on.
        if case .unavailable(let reason)? = entry?.reading,
          [.signedOut, .notInstalled].contains(reason)
        {
          continue
        }
        let now = clock.now()
        let spent = AccountFallbackRules.limit(of: entry?.reading.quota, at: now)
        limitedAccounts[candidate] = spent
        if spent != nil { continue }
      }
      guard let session = sessions.first(where: { $0.id == id }),
        await isStillStoppedOnLimit(session, providerID: providerID)
      else { return }
      let names = Dictionary(
        agentDescriptors.map { ($0.id.rawValue, $0.displayName) },
        uniquingKeysWith: { first, _ in first })
      let history = await planAgentSwitch.conversationHistory(for: session).isUsable
      let target = AgentTarget(providerID: candidate)
      await performAgentSwitch(
        id: id,
        to: target,
        previous: names[providerID] ?? providerID,
        summary: history ? nil : await handoverSummary(of: session, to: target, names: names),
        wasEdited: false,
        includesConversationHistory: history,
        skippingResume: true,
        expecting: nil,
        names: names,
        cause: .accountLimit(resetsAt: limit.resetsAt))
      return
    }
  }

  /// The session may have moved while its limit was looked into: the user switched, closed or
  /// archived it, wrote to it again, or left work running behind it.
  private func isStillStoppedOnLimit(_ session: WorkSession, providerID: String) async -> Bool {
    let id = session.id
    guard let launcher, session.agent?.providerID == providerID, session.status == .active,
      launcher.isRunning(id), canSwitchAgent(session),
      activity(for: id)?.activity != .working,
      launcher.pane(for: id)?.wasStoppedOnPurpose != true
    else { return false }
    if await runsBackgroundWork(id) { return false }
    guard let screen = await launcher.screen(of: id) else { return true }
    if AgentUpdateRestartReadiness.runsInBackground(screen: screen) { return false }
    // Text the user started typing would be lost with the agent.
    if let input = PromptInputRecognition.input(screen: screen),
      PromptInputRecognition.holdsText(input)
    {
      return false
    }
    return true
  }

  /// The summary of the session, and the request its agent could not finish: without its logs,
  /// the next account is told what to go on with. Shortened to fit what an agent is started with.
  private func handoverSummary(
    of session: WorkSession, to target: AgentTarget, names: [String: String]
  ) async -> String? {
    guard let planAgentSwitch else { return nil }
    let summary = planAgentSwitch.summary(
      for: briefInput(for: session, names: names), to: target
    ).text
    let entries = await conversations.entries(of: session) ?? []
    guard let index = entries.lastIndex(where: \.isUserPrompt),
      case .userPrompt(let request, _) = entries[index].content
    else { return summary }
    let introduction = """


      The previous agent's account reached its usage limit before it finished the user's latest \
      request. Go on with it from the current state of the files:

      """
    let room = AgentPromptLimits.argumentByteLimit - summary.utf8.count - introduction.utf8.count
    guard room > 0 else { return summary }
    var kept = request
    while kept.utf8.count > room { kept = String(kept.dropLast(max(1, (kept.utf8.count - room) / 4))) }
    return summary + introduction + kept
  }
}
