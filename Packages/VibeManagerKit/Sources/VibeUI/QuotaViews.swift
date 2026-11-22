import SwiftUI
import VibeApplication

/// The words of the quotas (#599), apart from the views: what a test reads.
enum QuotaPresentation {
  /// “5 hours”, “Week”, “Week · Fable”, “Gemini Models”.
  static func name(of window: QuotaWindow, locale: Locale) -> String {
    switch window.kind {
    case .session:
      return String(
        localized: LocalizedStringResource(
          "Session", locale: locale, bundle: .module,
          comment: "A quota window: Claude Code's current five-hour session."))
    case .minutes(let minutes) where minutes > 0 && minutes % 60 == 0:
      let hours = minutes / 60
      return String(
        localized: LocalizedStringResource(
          "\(hours) hours", locale: locale, bundle: .module,
          comment: "A quota window of so many hours, such as Codex's five hours."))
    case .minutes(let minutes):
      return String(
        localized: LocalizedStringResource(
          "\(minutes) minutes", locale: locale, bundle: .module,
          comment: "A quota window of so many minutes."))
    case .weekly:
      return String(
        localized: LocalizedStringResource(
          "Week", locale: locale, bundle: .module,
          comment: "A quota window: the week, every model."))
    case .weeklyModel(let model):
      return String(
        localized: LocalizedStringResource(
          "Week · \(model)", locale: locale, bundle: .module,
          comment: "A quota window: the week of one model, named after the dot."))
    case .group(let name):
      return name
    }
  }

  /// The share shown, in the display chosen: “82 % used”, “18 % left”.
  static func share(of window: QuotaWindow, display: QuotaModel.Display, locale: Locale)
    -> String
  {
    let value = display == .used ? window.usedFraction : 1 - window.usedFraction
    let percent = value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    switch display {
    case .used:
      return String(
        localized: LocalizedStringResource(
          "\(percent) used", locale: locale, bundle: .module,
          comment: "The share of a quota window used, such as “82 % used”."))
    case .remaining:
      return String(
        localized: LocalizedStringResource(
          "\(percent) left", locale: locale, bundle: .module,
          comment: "The share of a quota window left, such as “18 % left”."))
    }
  }

  /// “resets 14:26”, the same day; “resets Fri 09:00” further; “reset since” once past.
  static func reset(of window: QuotaWindow, now: Date, locale: Locale) -> String? {
    guard let resetsAt = window.resetsAt else { return nil }
    if resetsAt <= now {
      return String(
        localized: LocalizedStringResource(
          "reset since", locale: locale, bundle: .module,
          comment: "A quota window that came back since it was read: its share no longer holds."))
    }
    let style: Date.FormatStyle =
      resetsAt.timeIntervalSince(now) < 20 * 3_600
      ? Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
      : Date.FormatStyle().weekday(.abbreviated).hour().minute().locale(locale)
    let date = resetsAt.formatted(style)
    return String(
      localized: LocalizedStringResource(
        "resets \(date)", locale: locale, bundle: .module,
        comment: "When a quota window comes back, such as “resets 14:26” or “resets Fri 09:00”."))
  }

  /// “just now”, “8 min ago”: how old the figures are.
  static func age(of date: Date, now: Date, locale: Locale) -> String {
    if now.timeIntervalSince(date) < 60 {
      return String(
        localized: LocalizedStringResource(
          "just now", locale: locale, bundle: .module,
          comment: "Quota figures read less than a minute ago."))
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }

  /// Why an account has no figure.
  static func unavailable(_ reason: QuotaUnavailability, locale: Locale) -> String {
    switch reason {
    case .notReportedByAgent:
      return String(
        localized: LocalizedStringResource(
          "This account has no quota to tell", locale: locale, bundle: .module,
          comment: "An account without a quota: one on an API key, for instance."))
    case .notInstalled:
      return String(
        localized: LocalizedStringResource(
          "Its command-line tool cannot run", locale: locale, bundle: .module,
          comment: "An account's quota cannot be read: its CLI is missing or cannot run."))
    case .signedOut:
      return String(
        localized: LocalizedStringResource(
          "Signed out: sign in to read its quota", locale: locale, bundle: .module,
          comment: "An account's quota cannot be read: its CLI is signed out."))
    case .unrecognized:
      return String(
        localized: LocalizedStringResource(
          "Its answer is not in a format this version reads", locale: locale, bundle: .module,
          comment: "An account's quota cannot be read: its CLI answered in an unknown format."))
    case .failed:
      return String(
        localized: LocalizedStringResource(
          "Its command-line tool did not answer", locale: locale, bundle: .module,
          comment: "An account's quota cannot be read: its CLI failed or took too long."))
    case .trackingOff:
      return String(
        localized: LocalizedStringResource(
          "Usage tracking is off", locale: locale, bundle: .module,
          comment: "Quotas are not read: usage tracking is off in Settings."))
    }
  }

  /// “Codex, 5 hours, 82 % used, resets 14:26”: a window whole, for VoiceOver.
  static func spoken(
    _ window: QuotaWindow, account: String, display: QuotaModel.Display, now: Date,
    locale: Locale
  ) -> String {
    let reset = reset(of: window, now: now, locale: locale)
    let parts =
      [account, name(of: window, locale: locale)]
      + (window.hasReset(at: now) ? [] : [share(of: window, display: display, locale: locale)])
      + [reset].compactMap { $0 }
    return parts.joined(separator: ", ")
  }

  static func color(for usedFraction: Double) -> Color {
    switch QuotaGauge.level(for: usedFraction) {
    case .normal: .green
    case .near: .orange
    case .reached: .red
    case .unknown: .secondary
    }
  }
}

/// One window of a quota: its name, a bar, its share and when it comes back.
struct QuotaWindowRow: View {
  let window: QuotaWindow
  let account: String
  let display: QuotaModel.Display
  let now: Date

  @Environment(\.locale) private var locale

  var body: some View {
    let hasReset = window.hasReset(at: now)
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: QuotaPresentation.name(of: window, locale: locale))
          .lineLimit(1)
        Spacer(minLength: 8)
        if !hasReset {
          Text(verbatim: QuotaPresentation.share(of: window, display: display, locale: locale))
            .monospacedDigit()
            .foregroundStyle(window.isExhausted ? Color.red : Color.primary)
        }
      }
      if !hasReset {
        QuotaBar(usedFraction: window.usedFraction, display: display)
      }
      if let reset = QuotaPresentation.reset(of: window, now: now, locale: locale) {
        Text(verbatim: reset)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(
        verbatim: QuotaPresentation.spoken(
          window, account: account, display: display, now: now, locale: locale)))
  }
}

/// The share of a window as a bar, coloured by what was used whatever the display.
struct QuotaBar: View {
  let usedFraction: Double
  let display: QuotaModel.Display

  var body: some View {
    let shown = display == .used ? usedFraction : 1 - usedFraction
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.12))
        Capsule()
          .fill(QuotaPresentation.color(for: usedFraction))
          .frame(width: max(0, min(1, shown)) * proxy.size.width)
      }
    }
    .frame(height: 5)
    .accessibilityHidden(true)
  }
}

/// An account's quota: its windows, or why it has none, and how old the figures are.
struct AccountQuotaSection: View {
  let account: String
  let entry: AccountQuotaService.Entry?
  let isAsking: Bool
  let display: QuotaModel.Display
  let now: Date

  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch entry?.reading {
      case .measured(let quota):
        ForEach(quota.windows, id: \.id) { window in
          QuotaWindowRow(window: window, account: account, display: display, now: now)
        }
        Text(verbatim: QuotaPresentation.age(of: quota.measuredAt, now: now, locale: locale))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      case .unavailable(let reason):
        Text(verbatim: QuotaPresentation.unavailable(reason, locale: locale))
          .font(.callout)
          .foregroundStyle(.secondary)
      case nil:
        if isAsking {
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Asking…", bundle: .module)
              .foregroundStyle(.secondary)
          }
        } else {
          Text(verbatim: "—").foregroundStyle(.secondary)
        }
      }
    }
  }
}
