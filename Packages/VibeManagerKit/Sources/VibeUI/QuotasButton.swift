import AppKit
import SwiftUI
import VibeApplication
import VibeConversationUI

/// The Quotas button of the window's toolbar (#599), always there: a dial whose needle points at
/// the window nearest its limit, every account together, and whose colour says how near — green,
/// orange from four fifths, red at the limit, grey without a figure. No badge: it would hide the
/// dial. Its popover lists every account plugged in, its windows and its last thirty days at
/// public prices.
struct QuotasToolbarButton: View {
  let usage: UsageModel
  /// Opens an address beside the session, or in the browser when no session is shown.
  let openPage: (URL) -> Void

  @State private var isPresented = false
  @Environment(\.locale) private var locale

  var body: some View {
    let quotas = usage.quotas
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let gauge = quotas.gauge(at: context.date)
      Button {
        isPresented.toggle()
      } label: {
        Label {
          Text("Quotas", bundle: .module, comment: "The toolbar button of every account's quota.")
        } icon: {
          QuotaDial(gauge: gauge, display: quotas.display)
        }
      }
      // Not over its own popover, which opens under it.
      .instantTooltip(
        isPresented
          ? "" : Self.help(quotas: quotas, gauge: gauge, now: context.date, locale: locale)
      )
      .accessibilityValue(
        Text(verbatim: Self.help(quotas: quotas, gauge: gauge, now: context.date, locale: locale)))
    }
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      QuotasPopover(usage: usage, openPage: openPage)
    }
  }

  /// “Quotas, one account blocked: Antigravity, Gemini Models”, “Quotas, 82 % used at most”.
  static func help(quotas: QuotaModel, gauge: QuotaGauge, now: Date, locale: Locale) -> String {
    let blocked = quotas.blocked(at: now)
    if !blocked.isEmpty {
      let names = blocked.map { account, windows in
        ([account.name] + windows.map { QuotaPresentation.name(of: $0, locale: locale) })
          .joined(separator: ", ")
      }.joined(separator: "; ")
      return String(
        localized: LocalizedStringResource(
          "Quotas, limit reached: \(names)", locale: locale, bundle: .module,
          comment: "Help of the Quotas button: the accounts and windows whose limit is reached."))
    }
    guard let used = gauge.usedFraction else {
      return String(
        localized: LocalizedStringResource(
          "Quotas, no figure yet", locale: locale, bundle: .module,
          comment: "Help of the Quotas button before any account answered."))
    }
    let window = QuotaWindow(id: "", kind: .weekly, usedFraction: used, resetsAt: nil)
    let share = QuotaPresentation.share(of: window, display: quotas.display, locale: locale)
    return String(
      localized: LocalizedStringResource(
        "Quotas, nearest limit: \(share)", locale: locale, bundle: .module,
        comment: "Help of the Quotas button: the share of the window nearest its limit."))
  }
}

/// A half dial with its needle: from the left, nothing, to the right, everything — used or left,
/// as chosen — in the colour of the nearest limit.
struct QuotaDial: View {
  let gauge: QuotaGauge
  let display: QuotaModel.Display

  var color: Color {
    switch gauge.level {
    case .normal: .green
    case .near: .orange
    case .reached: .red
    case .unknown: .secondary
    }
  }

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height * 0.78)
      let radius = min(size.width / 2, size.height * 0.78) - 1.5
      var arc = Path()
      arc.addArc(
        center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360),
        clockwise: false)
      context.stroke(arc, with: .color(.primary.opacity(0.55)), lineWidth: 1.6)
      let angle = Angle.degrees(180 + 180 * gauge.needle(display))
      let tip = CGPoint(
        x: center.x + cos(angle.radians) * (radius - 1.5),
        y: center.y + sin(angle.radians) * (radius - 1.5))
      var needle = Path()
      needle.move(to: center)
      needle.addLine(to: tip)
      context.stroke(needle, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      context.fill(
        Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
        with: .color(color))
    }
    .frame(width: 18, height: 14)
    .accessibilityHidden(true)
  }
}

/// Every account plugged in: its name, its plan, its last thirty days at public prices, its
/// windows; the total under them, then the Usage window.
struct QuotasPopover: View {
  let usage: UsageModel
  let openPage: (URL) -> Void

  @Environment(\.locale) private var locale
  @Environment(\.openWindow) private var openWindow
  @State private var watch: UUID?

  var body: some View {
    let quotas = usage.quotas
    VStack(alignment: .leading, spacing: 10) {
      Text("Quotas", bundle: .module).font(.headline)
      if !usage.isTrackingEnabled {
        Text(verbatim: QuotaPresentation.unavailable(.trackingOff, locale: locale))
          .foregroundStyle(.secondary)
      } else if quotas.accounts.isEmpty {
        Text("No account can tell its quota.", bundle: .module)
          .foregroundStyle(.secondary)
      } else {
        TimelineView(.periodic(from: .now, by: 30)) { context in
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(quotas.accounts) { account in
                accountRow(account, now: context.date)
                if account.id != quotas.accounts.last?.id { Divider() }
              }
            }
          }
          // As tall as the screen allows, so that every account shows without scrolling when it can.
          .frame(maxHeight: Self.listMaxHeight)
          .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        total
      }
      HStack {
        Button {
          openWindow(id: "usage")
        } label: {
          Text("Open Usage Window", bundle: .module)
        }
        Spacer()
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: 380, alignment: .leading)
    .onAppear {
      watch = quotas.startWatching()
      // The costs of thirty days need every session's transcripts, as the Usage window reads.
      usage.startWatching()
    }
    .onDisappear {
      if let watch { quotas.stopWatching(watch) }
      watch = nil
      usage.stopWatching()
    }
  }

  private func accountRow(_ account: QuotaModel.Account, now: Date) -> some View {
    let quotas = usage.quotas
    let entry = quotas.entry(for: account.id)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: account.symbolName).foregroundStyle(.secondary)
        Text(verbatim: account.name).font(.body.weight(.semibold))
        if let plan = entry?.reading.quota?.plan {
          Text(verbatim: plan.capitalized).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 6)
        if let cost = cost(of: account.id) {
          Text(verbatim: cost)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(
              usage.accountCosts[account.id]?.hasPrice == true ? .primary : .secondary
            )
            .instantTooltip(Self.costHelp(locale: locale))
        }
      }
      AccountQuotaSection(
        account: account.name, entry: entry, isAsking: quotas.asking.contains(account.id),
        display: quotas.display, now: now)
      if let url = account.usageURL {
        Button {
          openPage(url)
        } label: {
          Text("See usage online", bundle: .module)
        }
        .buttonStyle(.link)
        .font(.caption)
      }
    }
  }

  /// “≈ 127 € · 30 d”; without a session in Polyvibe over thirty days, or only models without
  /// a price, says so rather than a zero.
  private func cost(of providerID: String) -> String? {
    guard let estimate = usage.accountCosts[providerID] else {
      return String(
        localized: LocalizedStringResource(
          "No session in 30 days", locale: locale, bundle: .module,
          comment:
            "An account without any session run in Polyvibe over the last thirty days: no cost to say."
        ))
    }
    guard estimate.hasPrice else { return UsagePresentation.unknownPrice(locale: locale) }
    let amount = UsagePresentation.cost(estimate.total, locale: locale)
    return String(
      localized: LocalizedStringResource(
        "\(amount) · 30 d", locale: locale, bundle: .module,
        comment:
          "An account's API-equivalent cost over the last thirty days, such as “≈ 127 € · 30 d”."
      ))
  }

  private var total: some View {
    let estimates = usage.quotas.accounts.compactMap { usage.accountCosts[$0.id] }
    let priced = estimates.filter(\.hasPrice)
    let sum = priced.reduce(Decimal(0)) { $0 + $1.total }
    let leavesOut = estimates.contains { !$0.unpriced.isEmpty }
    return VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("API equivalent · last 30 days", bundle: .module)
        Spacer()
        Text(verbatim: priced.isEmpty ? "—" : UsagePresentation.cost(sum, locale: locale))
          .monospacedDigit()
      }
      .font(.callout.weight(.semibold))
      Group {
        Text(Self.costHelp(locale: locale))
        if leavesOut { Text(verbatim: UsagePresentation.unpricedModelsLeftOut(locale: locale)) }
        if let note = UsagePresentation.conversionNote(CostConversion.current, locale: locale) {
          Text(verbatim: note)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The screen's visible height, less room for the toolbar, the header, the total and the button.
  static var listMaxHeight: CGFloat {
    let screen = NSScreen.main?.visibleFrame.height ?? 800
    return max(360, screen - 260)
  }

  static func costHelp(locale: Locale) -> String {
    String(
      localized: LocalizedStringResource(
        "What the tokens of the sessions run in Polyvibe over the last thirty days would cost at public API prices.",
        locale: locale, bundle: .module,
        comment: "Explains the thirty-day cost of the Quotas popover (#599)."))
  }
}
