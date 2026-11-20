import SwiftUI
import VibeApplication

/// Over the overview, a button for each kind of moment, which shows or hides them (#572): in the
/// overview and in the margin of the messages, in every session. On, a button takes its kind's
/// colour; off, it is grey.
struct OverviewFilterBar: View {
  let model: ConversationModel
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance

  static let buttonSize = 18.0
  static let spacing = 1.0

  var body: some View {
    let counts = Dictionary(grouping: model.moments, by: \.moment.kind).mapValues(\.count)
    FilterFlow(spacing: Self.spacing) {
      ForEach(ConversationMomentKind.allCases, id: \.self) { kind in
        button(kind, count: counts[kind] ?? 0)
      }
    }
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .bottom) {
      Rectangle().fill(theme.border.color.opacity(0.6)).frame(height: 1)
    }
    .overlay(alignment: .leading) {
      Rectangle().fill(theme.border.color.opacity(0.6)).frame(width: 1)
    }
  }

  private func button(_ kind: ConversationMomentKind, count: Int) -> some View {
    let isShown = appearance.shows(kind)
    let name = MomentPresentation.name(of: kind)
    let state =
      isShown
      ? String(localized: "\(count) moments", bundle: .module)
      : String(localized: "Hidden", bundle: .module)
    return Button {
      model.setMomentKindShown?(kind, !isShown)
    } label: {
      MomentIcon(
        symbol: MomentPresentation.symbol(of: kind),
        color: isShown
          ? MomentPresentation.color(of: kind, theme: theme)
          : theme.secondaryText.color.opacity(0.55),
        size: 11
      )
      .frame(width: Self.buttonSize, height: Self.buttonSize)
      .background(
        isShown ? theme.text.color.opacity(0.07) : .clear,
        in: RoundedRectangle(cornerRadius: 4)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(Text(verbatim: "\(name) · \(state)"))
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(Text(verbatim: state))
    .accessibilityAddTraits(isShown ? .isSelected : [])
    .accessibilityIdentifier("moment-filter-\(kind.rawValue)")
  }
}

/// Buttons in rows, as many to a row as the width holds, the rows centred: two rows of three at
/// the overview's narrowest.
private struct FilterFlow: Layout {
  let spacing: Double

  private func columns(_ width: CGFloat?, item: Double, count: Int) -> Int {
    guard let width, width.isFinite else { return count }
    return max(1, min(count, Int((width + spacing) / (item + spacing))))
  }

  private func item(_ subviews: Subviews) -> CGSize {
    subviews.first?.sizeThatFits(.unspecified) ?? .zero
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let size = item(subviews)
    let columns = columns(proposal.width, item: size.width, count: subviews.count)
    let rows = (subviews.count + columns - 1) / max(columns, 1)
    return CGSize(
      width: proposal.width ?? Double(columns) * (size.width + spacing) - spacing,
      height: Double(rows) * (size.height + spacing) - spacing)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let size = item(subviews)
    let columns = columns(bounds.width, item: size.width, count: subviews.count)
    for (index, subview) in subviews.enumerated() {
      let row = index / columns
      let inRow = min(columns, subviews.count - row * columns)
      let rowWidth = Double(inRow) * (size.width + spacing) - spacing
      let x =
        bounds.minX + (bounds.width - rowWidth) / 2
        + Double(index % columns) * (size.width + spacing)
      let y = bounds.minY + Double(row) * (size.height + spacing)
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
    }
  }
}
