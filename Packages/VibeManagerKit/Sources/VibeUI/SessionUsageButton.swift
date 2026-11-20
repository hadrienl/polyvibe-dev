import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain

/// The session's usage in its status bar (#574), under the terminal and under the conversation:
/// a ring of the context, its share and the cost — “◔ 55 % · 4,82 $” — and every figure in a
/// popover above it.
///
/// The transcripts are read while the session is the one shown, the way the inspector's section
/// read them while it was on screen. Every session keeps its status bar in the window's stack,
/// hidden: the others read nothing.
struct SessionUsageButton: View {
  let usage: UsageModel
  let session: WorkSession
  /// Whether the session is the one shown.
  let isShown: Bool
  let agentNames: [String: String]

  @State private var isPresented = false
  @Environment(\.locale) private var locale

  var body: some View {
    let summary = SessionUsageSummary(
      figures: usage.sessionUsage[session.id],
      percent: usage.contextWindows[session.id]?.percentUsed)
    Button {
      isPresented.toggle()
    } label: {
      SessionUsageLabel(summary: summary, isReading: usage.isReading)
    }
    .controlSize(.small)
    .fixedSize()
    .popover(isPresented: $isPresented, arrowEdge: .top) {
      SessionUsagePopover(usage: usage, session: session, agentNames: agentNames)
    }
    .instantTooltip(
      Text("Session usage", bundle: .module, comment: "Help of the status bar's Usage button."))
    .accessibilityLabel(
      Text(
        LocalizedStringResource("Usage", bundle: .module, comment: "A session's usage, heading.")))
    .accessibilityValue(Text(verbatim: summary.spoken(locale: locale)))
    .task(id: isShown ? session.id : nil) {
      guard isShown else { return }
      let id = session.id
      usage.startWatching(id)
      // Until the session is left or the bar goes away.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(3_600))
      }
      usage.stopWatching(id)
    }
    .onChange(of: isShown) { _, shown in
      if !shown { isPresented = false }
    }
  }
}

/// What the button says, from the figures alone.
struct SessionUsageSummary: Equatable {
  let figures: SessionUsage?
  /// The share of the context used, when the window is known.
  let percent: Int?

  /// The cost, when a model of the session has a price.
  var cost: Decimal? {
    figures.flatMap { $0.cost.hasPrice ? $0.cost.total : nil }
  }

  /// “context 55%, cost about 4.82 US dollars”: the figures of the label, whole, for VoiceOver.
  func spoken(locale: Locale) -> String {
    var parts: [String] = []
    if let percent {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "context \(percent)%", locale: locale, bundle: .module,
            comment: "The share of the window used.")))
    } else if let figures {
      parts.append(UsagePresentation.duration(figures.total.runningTime))
    }
    if let cost {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "cost about \(UsagePresentation.spokenCost(cost, locale: locale))", locale: locale,
            bundle: .module,
            comment:
              "The status bar's Usage button, for VoiceOver: the session's cost, such as “4.82 US dollars”."
          )))
    }
    return parts.isEmpty ? "—" : parts.joined(separator: ", ")
  }
}

/// “◔ 55 % · 4,82 $”: the ring and share of the context — or the running time, when the window is
/// unknown — then the cost. A dash while nothing was read.
struct SessionUsageLabel: View {
  let summary: SessionUsageSummary
  let isReading: Bool

  @Environment(\.locale) private var locale

  var body: some View {
    HStack(spacing: 4) {
      if isReading {
        ProgressView()
          .controlSize(.mini)
          .frame(width: 13, height: 13)
          .accessibilityLabel(Text("Reading transcripts", bundle: .module))
      } else if let percent = summary.percent {
        ContextRing(percent: percent)
      }
      if let percent = summary.percent {
        Text(verbatim: (Double(percent) / 100).formatted(.percent.locale(locale)))
      } else if let figures = summary.figures {
        Text(verbatim: UsagePresentation.duration(figures.total.runningTime))
      } else {
        Text(verbatim: "—")
      }
      if let cost = summary.cost {
        Text(verbatim: "·").foregroundStyle(.secondary)
        Text(verbatim: UsagePresentation.cost(cost, approximate: false, locale: locale))
      }
    }
    .monospacedDigit()
  }
}

/// How much of its window the conversation fills, as a ring that turns red past
/// `SessionContextWindowLine.almostFullPercent`, like the bar of the popover.
struct ContextRing: View {
  let percent: Int

  var body: some View {
    let share = CGFloat(min(max(percent, 0), 100)) / 100
    ZStack {
      Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.2)
      Circle()
        .trim(from: 0, to: share)
        .stroke(
          percent > SessionContextWindowLine.almostFullPercent ? Color.red : Color.accentColor,
          style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
    }
    .frame(width: 11, height: 11)
    .padding(1)
    .accessibilityHidden(true)
  }
}

/// Every figure of the session's usage, as the inspector's section showed them, then where the
/// prices come from and what stays on the Mac.
struct SessionUsagePopover: View {
  let usage: UsageModel
  let session: WorkSession
  let agentNames: [String: String]

  nonisolated static let width: CGFloat = 320

  var body: some View {
    SessionUsagePopoverContent(
      figures: SessionUsageFigures(
        figures: usage.sessionUsage[session.id],
        isTrackingEnabled: usage.isTrackingEnabled,
        runsRecordedSince: usage.runsRecordedSince.flatMap { $0 > session.createdAt ? $0 : nil },
        tokenUnavailability: usage.tokenUnavailability(for: session),
        agentNames: agentNames,
        context: usage.contextWindows[session.id],
        contextUnavailability: usage.contextUnavailability(for: session),
        contextAgentName: session.agent.flatMap { agentNames[$0.transcriptProviderID] }),
      pricesFetchedAt: usage.pricesFetchedAt)
  }
}

/// The popover's layout, apart from the model it reads: what a test draws.
struct SessionUsagePopoverContent: View {
  let figures: SessionUsageFigures
  let pricesFetchedAt: Date?

  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      figures
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        if let pricesFetchedAt {
          Text(
            String(
              localized: LocalizedStringResource(
                "Public prices from LiteLLM, read on \(pricesFetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))).",
                locale: locale, bundle: .module,
                comment: "Where the prices of the costs come from, and the day they were read.")))
        }
        Text(UsagePresentation.privacyNote)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(width: SessionUsagePopover.width, alignment: .leading)
  }
}
