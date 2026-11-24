import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain

/// A coordinator's usage together with every session under it (#606): its own children, closed,
/// done or archived ones included, and theirs in turn.
struct SessionFamilyUsage: Equatable {
  struct Child: Identifiable, Equatable {
    let id: SessionID
    let name: String
    /// 1 for the coordinator's own child, 2 for a child's child.
    let depth: Int
    /// `nil` while nothing was read for it.
    let figures: SessionUsage?
  }

  /// The coordinator's figures and those of every session under it, added up.
  let total: SessionUsage
  /// Each session under it, followed by its own.
  let children: [Child]
}

/// The line of a coordinator's Usage popover that adds its children (#606): what it and all of
/// them cost together, opening a menu with each child and its own cost, each one opening the
/// child's own figures.
struct SessionFamilyUsageSection: View {
  let family: SessionFamilyUsage
  let agentNames: [String: String]

  @Environment(\.locale) private var locale

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(Self.title)
        .fixedSize()
      Spacer(minLength: 0)
      Menu {
        ForEach(family.children) { child in
          let title = "\(child.name) · \(Self.cost(of: child.figures, locale: locale))"
          if let figures = child.figures, figures.total.hasReportedTokens {
            Menu(title) {
              // By place: two lines may read the same (two agents of one name, one model).
              let lines = Self.details(of: figures, agentNames: agentNames, locale: locale)
              ForEach(lines.indices, id: \.self) { index in
                Text(verbatim: lines[index])
              }
            }
          } else {
            Text(verbatim: title)
          }
        }
        if family.total.cost.hasPrice, !family.total.cost.unpriced.isEmpty {
          Divider()
          Text(UsagePresentation.unpricedModelsLeftOut(locale: locale))
        }
      } label: {
        Text(verbatim: Self.cost(of: family.total, locale: locale))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .font(.callout)
    .instantTooltip(UsagePresentation.costExplanation)
    // One element, as every line of the popover: the line's name, then its whole value.
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(Self.title))
    .accessibilityValue(Text(verbatim: Self.spokenCost(of: family.total, locale: locale)))
  }

  private static var title: LocalizedStringResource {
    LocalizedStringResource(
      "With its child sessions", bundle: .module,
      comment:
        "A coordinator's usage popover: the line of what it and every session it created cost together; it opens the list of the children."
    )
  }

  /// The family's cost as VoiceOver says it: “1,377.10 euros”; the line's own text otherwise.
  static func spokenCost(of figures: SessionUsage, locale: Locale) -> String {
    guard figures.total.hasReportedTokens, figures.cost.hasPrice else {
      return cost(of: figures, locale: locale)
    }
    return UsagePresentation.spokenCost(figures.cost.total, locale: locale)
  }

  /// What a session cost: “≈ 37,23 €”, its unknown price when no model of it has one, a dash
  /// when it reported nothing.
  static func cost(of figures: SessionUsage?, locale: Locale) -> String {
    guard let figures, figures.total.hasReportedTokens else { return "—" }
    if figures.cost.hasPrice { return UsagePresentation.cost(figures.cost.total, locale: locale) }
    if !figures.cost.unpriced.isEmpty { return UsagePresentation.unknownPrice(locale: locale) }
    return "—"
  }

  /// A child's own figures, a line each, as its popover says them: the cost and each model's,
  /// the running time, the tokens, the responses.
  static func details(of figures: SessionUsage, agentNames: [String: String], locale: Locale)
    -> [String]
  {
    func line(_ label: String, _ value: String) -> String {
      String(
        localized: LocalizedStringResource(
          "\(label): \(value)", locale: locale, bundle: .module,
          comment:
            "A figure of a child session in the menu of its coordinator's usage: its name, then its value, such as “Cost: ≈ €37.23”."
        ))
    }
    func named(_ label: LocalizedStringResource, _ value: String) -> String {
      var label = label
      label.locale = locale
      return line(String(localized: label), value)
    }
    var lines = [named(SessionUsageFigures.costTitle, cost(of: figures, locale: locale))]
    for row in figures.models {
      guard case .model(let providerID, let model) = row.key, !row.tokens.isZero else { continue }
      let price = figures.cost.priced[UsageModelKey(providerID: providerID, model: model)]
      let name =
        model
        ?? String(
          localized: LocalizedStringResource(
            "Default", locale: locale, bundle: .module,
            comment: "The model an agent uses when none is chosen."))
      lines.append(
        line(
          "\(agentNames[providerID] ?? providerID) · \(name)",
          price.map { UsagePresentation.cost($0, locale: locale) }
            ?? UsagePresentation.unknownPrice(locale: locale)))
    }
    lines.append(
      named(
        LocalizedStringResource(
          "Running time", bundle: .module, comment: "A session's usage: how long its agent ran."),
        UsagePresentation.duration(figures.total.runningTime)))
    lines.append(
      named(
        SessionUsageFigures.tokensTitle,
        "≈ "
          + UsagePresentation.tokenParts(figures.total.tokens, locale: locale)
          .joined(separator: " · ")))
    lines.append(
      named(
        LocalizedStringResource(
          "Responses", bundle: .module,
          comment: "A session's usage: how many answers the agent wrote."),
        "\(figures.total.responses)"))
    return lines
  }
}
