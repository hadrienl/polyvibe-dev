import CompanionCore
import SwiftUI

/// The words of the quotas (#630): the Mac's own, from the figures it sends. The figures
/// themselves are written by `RemoteQuotaFormat`.
enum QuotaWords {
  /// “5 hours”, “Week”, “Week · Opus”, “Gemini Models”.
  static func name(of window: RemoteQuotaWindow) -> String {
    switch RemoteQuotaFormat.name(of: window.kind) {
    case .session:
      String(
        localized: "Session", comment: "A quota window: Claude Code's current five-hour session.")
    case .hours(let hours):
      String(
        localized: "\(hours) hours",
        comment: "A quota window of so many hours, such as Codex's five hours.")
    case .minutes(let minutes):
      String(localized: "\(minutes) minutes", comment: "A quota window of so many minutes.")
    case .unknownLength:
      String(
        localized: "Usage limit",
        comment: "A quota window whose length the agent's CLI did not give.")
    case .weekly:
      String(localized: "Week", comment: "A quota window: the week, every model.")
    case .weeklyModel(let model):
      String(
        localized: "Week · \(model)",
        comment: "A quota window: the week of one model, named after the dot.")
    case .group(let name):
      name
    }
  }

  /// “82 % used”, “18 % left”.
  static func share(of window: RemoteQuotaWindow, showsRemaining: Bool) -> String {
    let percent = RemoteQuotaFormat.percent(
      of: window, showsRemaining: showsRemaining, locale: .current)
    return showsRemaining
      ? String(
        localized: "\(percent) left",
        comment: "The share of a quota window left, such as “18 % left”.")
      : String(
        localized: "\(percent) used",
        comment: "The share of a quota window used, such as “82 % used”.")
  }

  /// “resets 14:26”, “resets Fri 09:00”; “reset since” once past.
  static func reset(of window: RemoteQuotaWindow, now: Date) -> String? {
    guard window.resetsAt != nil else { return nil }
    guard let date = RemoteQuotaFormat.resetMoment(of: window, now: now, locale: .current) else {
      return String(
        localized: "reset since",
        comment: "A quota window that came back since it was read: its share no longer holds.")
    }
    return String(
      localized: "resets \(date)",
      comment: "When a quota window comes back, such as “resets 14:26” or “resets Fri 09:00”.")
  }

  /// “just now”, “8 min ago”.
  static func age(of date: Date, now: Date) -> String {
    if now.timeIntervalSince(date) < 60 {
      return String(localized: "just now", comment: "Quota figures read less than a minute ago.")
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }

  static func unavailable(_ reason: RemoteQuotaUnavailability) -> String {
    switch reason {
    case .notReportedByAgent:
      String(
        localized: "This account has no quota to tell",
        comment: "An account without a quota: one on an API key, for instance.")
    case .notInstalled:
      String(
        localized: "Its command-line tool cannot run",
        comment: "An account's quota cannot be read: its CLI is missing or cannot run.")
    case .signedOut:
      String(
        localized: "Signed out: sign in to read its quota",
        comment: "An account's quota cannot be read: its CLI is signed out.")
    case .unrecognized:
      String(
        localized: "Its answer is not in a format this version reads",
        comment: "An account's quota cannot be read: its CLI answered in an unknown format.")
    case .failed:
      String(
        localized: "Its command-line tool did not answer",
        comment: "An account's quota cannot be read: its CLI failed or took too long.")
    case .trackingOff:
      trackingOff
    }
  }

  static var trackingOff: String {
    String(
      localized: "Usage tracking is off",
      comment: "Quotas are not read: usage tracking is off in Settings.")
  }

  /// “≈ 127 € · 30 d”; without a session over thirty days, or only models without a price, says so
  /// rather than a zero.
  static func cost(_ cost: RemoteQuotaCost?, currency: String) -> String {
    guard let cost else {
      return String(
        localized: "No session in 30 days",
        comment:
          "An account without any session run in Polyvibe over the last thirty days: no cost to say."
      )
    }
    guard cost.hasPrice else {
      return String(
        localized: "Unknown price",
        comment: "A model whose public price per token is not known: its cost is not counted.")
    }
    let amount = RemoteQuotaFormat.cost(cost.amount, currency: currency, locale: .current)
    return String(
      localized: "\(amount) · 30 d",
      comment:
        "An account's API-equivalent cost over the last thirty days, such as “≈ 127 € · 30 d”."
    )
  }

  /// “Quotas, limit reached: Antigravity, Gemini Models”, “Quotas, nearest limit: 82 % used”.
  static func help(_ quotas: RemoteQuotas?, now: Date) -> String {
    let blocked = quotas?.blocked(at: now) ?? []
    if !blocked.isEmpty {
      let names = blocked.map { account, windows in
        ([account.name] + windows.map(name(of:))).joined(separator: ", ")
      }.joined(separator: "; ")
      return String(
        localized: "Quotas, limit reached: \(names)",
        comment: "Help of the Quotas button: the accounts and windows whose limit is reached.")
    }
    guard let quotas, let used = quotas.gauge(at: now).usedFraction else {
      return String(
        localized: "Quotas, no figure yet",
        comment: "Help of the Quotas button before any account answered.")
    }
    let window = RemoteQuotaWindow(id: "", kind: .weekly, usedFraction: used, resetsAt: nil)
    let share = share(of: window, showsRemaining: quotas.showsRemaining)
    return String(
      localized: "Quotas, nearest limit: \(share)",
      comment: "Help of the Quotas button: the share of the window nearest its limit.")
  }

  /// “Codex, 5 hours, 82 % used, resets 14:26”: a window whole, for VoiceOver.
  static func spoken(
    _ window: RemoteQuotaWindow, account: String, showsRemaining: Bool, now: Date
  ) -> String {
    let parts =
      [account, name(of: window)]
      + (window.hasReset(at: now) ? [] : [share(of: window, showsRemaining: showsRemaining)])
      + [reset(of: window, now: now)].compactMap { $0 }
    return parts.joined(separator: ", ")
  }

  static func color(for usedFraction: Double) -> Color {
    color(of: RemoteQuotaGauge.level(for: usedFraction))
  }

  /// The dial's colours, its alone: elsewhere orange still means an agent is waiting.
  static func color(of level: RemoteQuotaGauge.Level) -> Color {
    switch level {
    case .normal: .green
    case .near: .orange
    case .reached: .red
    case .unknown: .secondary
    }
  }
}

/// The Quotas button of the list's top bar: a half dial whose needle points at the window
/// nearest its limit, every account together, in the colour of how near — as the Mac's header.
struct QuotasButton: View {
  let quotas: RemoteQuotas?
  let action: () -> Void

  var body: some View {
    // The button itself in the toolbar, its clock inside: a toolbar shows a label's title in place
    // of a drawn icon, and gives a view that isn't a button a capsule of its own.
    Button(action: action) {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        QuotaDial(
          gauge: quotas?.gauge(at: context.date) ?? .unknown,
          showsRemaining: quotas?.showsRemaining ?? false)
      }
    }
    // “Quotas, nearest limit: 82 % used”: the button's name and state at once, said once.
    .accessibilityLabel(Text(verbatim: QuotaWords.help(quotas, now: .now)))
  }
}

/// A half dial with its needle: from the left, nothing, to the right, everything — used or left,
/// as chosen on the Mac.
struct QuotaDial: View {
  let gauge: RemoteQuotaGauge
  let showsRemaining: Bool

  var body: some View {
    let color = QuotaWords.color(of: gauge.level)
    let needle = gauge.needle(showsRemaining: showsRemaining)
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height * 0.78)
      let radius = min(size.width / 2, size.height * 0.78) - 1.5
      var arc = Path()
      arc.addArc(
        center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360),
        clockwise: false)
      context.stroke(arc, with: .color(.primary.opacity(0.55)), lineWidth: 1.8)
      let angle = Angle.degrees(180 + 180 * needle)
      let tip = CGPoint(
        x: center.x + cos(angle.radians) * (radius - 1.5),
        y: center.y + sin(angle.radians) * (radius - 1.5))
      var hand = Path()
      hand.move(to: center)
      hand.addLine(to: tip)
      context.stroke(hand, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
      context.fill(
        Path(ellipseIn: CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4)),
        with: .color(color))
    }
    .frame(width: 24, height: 18)
    .accessibilityHidden(true)
  }
}

/// Every account of the Mac, as its Quotas popover lists them: its plan, its last thirty days at
/// public prices, its windows, how old the figures are and the provider's page; the total under.
struct QuotasSheet: View {
  @Environment(RemoteChannel.self) private var channel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 30)) { context in
        List {
          content(now: context.date)
        }
        .listStyle(.insetGrouped)
      }
      .navigationTitle(Text("Quotas", comment: "The button of every account's quota."))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .close) { dismiss() }
        }
      }
    }
  }

  @ViewBuilder
  private func content(now: Date) -> some View {
    if let quotas = channel.quotas {
      if !quotas.isTrackingOn {
        Text(verbatim: QuotaWords.trackingOff).foregroundStyle(.secondary)
      } else if quotas.accounts.isEmpty {
        Text("No account can tell its quota.").foregroundStyle(.secondary)
      } else {
        ForEach(quotas.accounts) { account in
          Section {
            AccountQuotaRows(
              account: account, currency: quotas.currency,
              showsRemaining: quotas.showsRemaining, now: now)
          }
        }
        Section {
          LabeledContent {
            Text(
              verbatim: quotas.totalCost.map {
                RemoteQuotaFormat.cost($0, currency: quotas.currency, locale: .current)
              } ?? "—"
            )
            .monospacedDigit()
          } label: {
            Text("API equivalent · last 30 days")
          }
          .font(.subheadline.weight(.semibold))
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              "What the tokens of the sessions run in Polyvibe over the last thirty days would cost at public API prices.",
              comment: "Explains the thirty-day cost of the Quotas popover (#599).")
            if quotas.leavesOutUnpriced {
              Text(
                "Models without a known price are left out of the total.",
                comment: "Under a cost, when a model has no known price.")
            }
          }
        }
      }
    } else {
      // The Mac has not answered yet, or the channel is down: it comes back once connected.
      HStack(spacing: 8) {
        ProgressView()
        Text("Asking…").foregroundStyle(.secondary)
      }
    }
  }
}

/// An account: its name, plan and cost, then its windows or why it has none, then how old the
/// figures are and its provider's page.
private struct AccountQuotaRows: View {
  let account: RemoteQuotaAccount
  let currency: String
  let showsRemaining: Bool
  let now: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: account.name).font(.body.weight(.semibold))
      if let plan = account.plan {
        Text(verbatim: plan.capitalized).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(verbatim: QuotaWords.cost(account.cost, currency: currency))
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    if !account.windows.isEmpty {
      ForEach(account.windows) { window in
        QuotaWindowRow(
          window: window, account: account.name, showsRemaining: showsRemaining, now: now)
      }
    } else if let reason = account.unavailable {
      Text(verbatim: QuotaWords.unavailable(reason))
        .font(.subheadline)
        .foregroundStyle(.secondary)
    } else if account.isAsking {
      HStack(spacing: 8) {
        ProgressView()
        Text("Asking…").foregroundStyle(.secondary)
      }
    }
    if account.measuredAt != nil || account.usageURL != nil {
      HStack {
        if let measuredAt = account.measuredAt {
          Text(verbatim: QuotaWords.age(of: measuredAt, now: now))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let url = account.usageURL {
          Link(destination: url) {
            Text("See usage online")
          }
        }
      }
      .font(.footnote)
    }
  }
}

/// One window: its name, its share, a bar and when it comes back.
private struct QuotaWindowRow: View {
  let window: RemoteQuotaWindow
  let account: String
  let showsRemaining: Bool
  let now: Date

  var body: some View {
    let hasReset = window.hasReset(at: now)
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: QuotaWords.name(of: window)).lineLimit(1)
        Spacer(minLength: 8)
        if !hasReset {
          Text(verbatim: QuotaWords.share(of: window, showsRemaining: showsRemaining))
            .monospacedDigit()
            .foregroundStyle(window.isExhausted ? Color.red : Color.secondary)
            .fontWeight(window.isExhausted ? .semibold : .regular)
        }
      }
      .font(.subheadline)
      if !hasReset {
        QuotaBar(usedFraction: window.usedFraction, showsRemaining: showsRemaining)
      }
      if let reset = QuotaWords.reset(of: window, now: now) {
        Text(verbatim: reset)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(
        verbatim: QuotaWords.spoken(
          window, account: account, showsRemaining: showsRemaining, now: now)))
  }
}

/// The share of a window as a bar, coloured by what was used whatever is shown.
private struct QuotaBar: View {
  let usedFraction: Double
  let showsRemaining: Bool

  var body: some View {
    let shown = showsRemaining ? 1 - usedFraction : usedFraction
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.12))
        Capsule()
          .fill(QuotaWords.color(for: usedFraction))
          .frame(width: max(0, min(1, shown)) * proxy.size.width)
      }
    }
    .frame(height: 5)
    .accessibilityHidden(true)
  }
}
