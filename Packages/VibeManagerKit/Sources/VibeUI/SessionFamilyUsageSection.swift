import SwiftUI
import VibeApplication
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

/// The part of a coordinator's Usage popover that adds its children (#606): the tokens and the
/// cost of all of them with it, then a line per child with its own cost.
struct SessionFamilyUsageSection: View {
  let family: SessionFamilyUsage

  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(
        LocalizedStringResource(
          "With its child sessions", bundle: .module,
          comment:
            "A coordinator's usage popover: the heading of what it and every session it created cost together."
        )
      )
      .font(.headline)
      .padding(.bottom, 2)
      tokens
      UsageCostLine(estimate: family.total.cost)
      ForEach(family.children) { child in
        let cost = childCost(child)
        UsageLine(
          label: Text(verbatim: child.name), value: cost.text, partPerLine: false, font: .caption
        )
        .foregroundStyle(cost.isUnpriced ? Color.usageWarning : Color.secondary)
        .padding(.leading, 12 * CGFloat(child.depth))
      }
      if family.total.cost.hasPrice, !family.total.cost.unpriced.isEmpty {
        Text(UsagePresentation.unpricedModelsLeftOut(locale: locale))
          .font(.caption)
          .foregroundStyle(.secondary)
          .foregroundStyle(Color.usageWarning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var tokens: some View {
    if family.total.total.hasReportedTokens {
      UsageTokensLine(tokens: family.total.total.tokens)
    } else {
      UsageLine(
        label: Text(SessionUsageFigures.tokensTitle), value: "—",
        help: UsagePresentation.tokensExplanation)
    }
  }

  /// A child's own cost; its unknown price, said as the session's; a dash when it reported
  /// nothing.
  private func childCost(_ child: SessionFamilyUsage.Child) -> (text: String, isUnpriced: Bool) {
    guard let figures = child.figures, figures.total.hasReportedTokens else { return ("—", false) }
    if figures.cost.hasPrice {
      return (UsagePresentation.cost(figures.cost.total, locale: locale), false)
    }
    if !figures.cost.unpriced.isEmpty {
      return (UsagePresentation.unknownPrice(locale: locale), true)
    }
    return ("—", false)
  }
}
