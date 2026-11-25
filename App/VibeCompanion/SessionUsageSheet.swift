import CompanionCore
import SwiftUI

/// The phone puts the Mac's raw figures into its own language; it never reads a transcript.
enum SessionUsageWords {
  static func cost(_ cost: RemoteQuotaCost?, currency: String, locale: Locale) -> String {
    guard let cost else { return "—" }
    guard cost.hasPrice else { return String(localized: "Unknown price") }
    return RemoteQuotaFormat.cost(cost.amount, currency: currency, locale: locale)
  }

  static func summary(_ usage: RemoteSessionUsage, locale: Locale, family: Bool = true) -> String {
    var parts = [RemoteUsageFormat.contextOrTime(usage, locale: locale)]
    if let cost = usage.cost {
      parts.append(self.cost(cost, currency: usage.currency, locale: locale))
    }
    if family, let total = usage.family?.cost {
      let amount = cost(total, currency: usage.currency, locale: locale)
      parts.append(String(localized: "total \(amount)"))
    }
    return parts.joined(separator: " · ")
  }

  static func unavailable(_ reason: String?) -> String {
    switch reason {
    case "trackingOff": String(localized: "Usage tracking is off")
    case "notReportedByAgent": String(localized: "Not reported by this agent")
    case "noTranscript": String(localized: "No transcript found")
    case "noResponseYet": String(localized: "No answer read yet")
    default: "—"
    }
  }
}

/// The context's share, with the same red threshold as the Mac; orange is for a waiting agent.
struct SessionUsageRing: View {
  @MainActor
  static func image(percent: Int?) -> Image {
    let renderer = ImageRenderer(content: SessionUsageRing(percent: percent))
    renderer.scale = 3
    guard let image = renderer.uiImage else { return Image(systemName: "circle") }
    return Image(uiImage: image).renderingMode(.original)
  }

  let percent: Int?

  var body: some View {
    ZStack {
      Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
      if let percent {
        Circle().trim(from: 0, to: min(1, max(0, Double(percent) / 100)))
          .stroke(percent > 80 ? Color.red : Color.accentColor, lineWidth: 2)
          .rotationEffect(.degrees(-90))
      }
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
  }
}

/// The native subtitle flattens attachments. This keeps the ring visible, drops the family total
/// first and the cost next; at the narrowest width the agent's state yields to the context share.
struct SessionUsageHeader: View {
  let title: String
  let state: String
  let usage: RemoteSessionUsage
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: 2) {
      Text(verbatim: title).font(.headline).lineLimit(1)
      ViewThatFits(in: .horizontal) {
        line(SessionUsageWords.summary(usage, locale: locale)).fixedSize()
        line(SessionUsageWords.summary(usage, locale: locale, family: false)).fixedSize()
        line(RemoteUsageFormat.contextOrTime(usage, locale: locale))
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: title + ", " + state))
    .accessibilityValue(
      Text(
        verbatim: String(localized: "Usage") + ": "
          + SessionUsageWords.summary(usage, locale: locale)))
  }

  private func line(_ figures: String) -> some View {
    HStack(spacing: 3) {
      Text(verbatim: state).lineLimit(1).truncationMode(.tail)
      Text(verbatim: "·")
      SessionUsageRing(percent: usage.context?.percentUsed).scaleEffect(0.65).frame(
        width: 11, height: 11)
      Text(verbatim: figures).fixedSize()
    }
  }
}

struct SessionUsageSheet: View {
  let sessionID: String
  @Environment(RemoteChannel.self) private var channel
  @Environment(\.locale) private var locale
  @Environment(\.dismiss) private var dismiss

  private var usage: RemoteSessionUsage? {
    guard let usage = channel.sessionUsage, usage.sessionID == sessionID else { return nil }
    return usage
  }

  var body: some View {
    NavigationStack {
      List {
        if let usage, usage.isTrackingOn {
          context(usage)
          costs(usage)
          Section {
            LabeledContent(
              "Running time", value: usage.runningTime.map(RemoteUsageFormat.duration) ?? "—")
            LabeledContent(
              "Tokens",
              value: usage.tokens.map { $0.formatted(.number.locale(locale)) }
                ?? SessionUsageWords.unavailable(usage.tokensUnavailable))
          }
          if let family = usage.family {
            Section {
              LabeledContent(
                "With its child sessions",
                value: SessionUsageWords.cost(family.cost, currency: usage.currency, locale: locale)
              )
              .fontWeight(.semibold)
              ForEach(family.children) { child in
                LabeledContent {
                  Text(
                    verbatim: SessionUsageWords.cost(
                      child.cost, currency: usage.currency, locale: locale)
                  )
                  .foregroundStyle(child.cost?.hasPrice == false ? Color.red : Color.secondary)
                } label: {
                  Text(verbatim: child.name)
                    .padding(.leading, CGFloat(max(0, child.depth - 1)) * 12)
                }
                .accessibilityElement(children: .combine)
              }
              if family.cost?.leavesOutUnpriced == true { unpriced }
            }
          }
          Section {
            Text("Costs (≈) are an API equivalent: the tokens at the models' public prices.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else if usage?.isTrackingOn == false {
          Text("Usage tracking is off")
        } else {
          Text("Connection lost")
        }
      }
      .monospacedDigit()
      .navigationTitle("Usage")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func context(_ usage: RemoteSessionUsage) -> some View {
    Section {
      if let context = usage.context {
        LabeledContent("Context") {
          let used = RemoteUsageFormat.tokens(context.usedTokens, locale: locale)
          let size = context.windowSize.map { RemoteUsageFormat.tokens($0, locale: locale) }
          Text(verbatim: (context.isEstimate ? "≈ " : "") + used + (size.map { " / " + $0 } ?? ""))
        }
        if let percent = context.percentUsed {
          HStack {
            ProgressView(value: Double(min(100, max(0, percent))), total: 100)
              .tint(percent > 80 ? .red : .accentColor)
              .accessibilityHidden(true)
            Text(verbatim: RemoteUsageFormat.contextOrTime(usage, locale: locale))
          }
          .accessibilityElement(children: .combine)
        } else {
          Text("Window size unknown for this model").font(.caption).foregroundStyle(.secondary)
        }
      } else {
        LabeledContent("Context", value: SessionUsageWords.unavailable(usage.contextUnavailable))
      }
    }
  }

  private func costs(_ usage: RemoteSessionUsage) -> some View {
    Section {
      LabeledContent(
        "Cost", value: SessionUsageWords.cost(usage.cost, currency: usage.currency, locale: locale)
      )
      .fontWeight(.semibold)
      ForEach(usage.models.indices, id: \.self) { index in
        let model = usage.models[index]
        LabeledContent {
          Text(
            verbatim: model.amount.map {
              RemoteQuotaFormat.cost($0, currency: usage.currency, locale: locale)
            } ?? String(localized: "Unknown price")
          )
          .foregroundStyle(model.amount == nil ? Color.red : Color.secondary)
        } label: {
          VStack(alignment: .leading) {
            Text(verbatim: model.providerName)
            Text(verbatim: model.model ?? String(localized: "Default model of the agent"))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
      if usage.cost?.leavesOutUnpriced == true { unpriced }
    }
  }

  private var unpriced: some View {
    Text("Models without a known price are left out of the total.")
      .font(.caption).foregroundStyle(.red)
  }
}
