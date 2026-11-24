import AppKit
import SwiftUI
import Testing
import VibeDomain
import VibeLocalizationTesting

@testable import VibeApplication
@testable import VibeUI

/// The popover of the status bar's Usage button (#574), at its width: nothing cut (#130).
@MainActor
@Suite("The usage of a session in its popover", .timeLimit(.minutes(1)))
struct SessionUsageLayoutTests {
  /// The popover's width, less its padding.
  nonisolated static let innerWidth = Double(SessionUsagePopover.width) - 28

  static func figures() -> SessionUsage {
    var total = UsageRow(key: .total)
    total.runningTime = 3 * 3600 + 12 * 60
    total.runs.starts = 1
    total.runs.resumes = 12
    total.runs.afterRelaunch = 2
    total.runs.afterSwitch = 1
    total.tokens = TokenCounts(input: 6, cacheRead: 111_000, cacheWrite: 21_500, output: 1_100)
    total.responses = 48
    total.hasReportedTokens = true
    var opus = UsageRow(key: .model(providerID: "claude", model: "claude-opus-5-5"))
    opus.tokens = TokenCounts(input: 4, cacheRead: 98_000, cacheWrite: 20_100, output: 1_000)
    opus.hasReportedTokens = true
    var standard = UsageRow(key: .model(providerID: "claude", model: nil))
    standard.tokens = TokenCounts(input: 2, cacheRead: 13_000, cacheWrite: 1_400, output: 100)
    standard.hasReportedTokens = true
    let opusKey = UsageModelKey(providerID: "claude", model: "claude-opus-5-5")
    // The default model has no name, so no price: said, and left out of the total.
    let cost = UsageCost.Estimate(
      total: Decimal(string: "1234.61")!, priced: [opusKey: Decimal(string: "1234.61")!],
      unpriced: [UsageModelKey(providerID: "claude", model: nil)])
    return SessionUsage(
      total: total, models: [opus, standard], hasTranscript: true, transcriptMissingSince: nil,
      cost: cost)
  }

  /// A coordinator's family (#606): a child with the same figures, and a child of it that read
  /// nothing yet.
  static func family() -> SessionFamilyUsage {
    var total = figures()
    total.total.tokens = TokenCounts(
      input: 12, cacheRead: 222_000, cacheWrite: 43_000, output: 2_200)
    total.cost.total = Decimal(string: "2469.22")!
    return SessionFamilyUsage(
      total: total,
      children: [
        .init(id: SessionID(), name: "Implement the quotas (#599)", depth: 1, figures: figures()),
        .init(id: SessionID(), name: "Review", depth: 2, figures: nil),
      ])
  }

  static func popover(language: String, family: SessionFamilyUsage? = nil) -> some View {
    SessionUsagePopoverContent(
      figures: SessionUsageFigures(
        figures: figures(), isTrackingEnabled: true, runsRecordedSince: nil,
        tokenUnavailability: nil, agentNames: ["claude": "Claude Code"],
        context: ContextWindowUsage(
          usedTokens: 182_000, windowSize: 200_000, measuredAt: Date(),
          lastCompaction: .init(date: Date().addingTimeInterval(-720), tokensBefore: 190_000)),
        contextAgentName: "Claude Code"),
      pricesFetchedAt: Date(timeIntervalSince1970: 1_795_000_000),
      family: family
    )
    .environment(\.locale, Locale(identifier: language))
  }

  /// How wide a line of text is drawn, unwrapped.
  static func width(of text: String, font: Font = .callout) -> CGFloat {
    NSHostingView(rootView: Text(verbatim: text).font(font).monospacedDigit().fixedSize())
      .fittingSize.width
  }

  @Test(
    "Each label, and each part of a value, fits on a line of the popover",
    arguments: ["en", "fr"])
  func partsFit(language: String) {
    _ = NSApplication.shared
    let locale = Locale(identifier: language)
    var runs = UsageRunCounts()
    runs.starts = 88
    runs.resumes = 888
    runs.restarts = 8
    runs.afterRelaunch = 8
    runs.afterSwitch = 88
    let tokens = TokenCounts(
      input: 888_888, cacheRead: 888_888_888, cacheWrite: 888_888_888, output: 888_888)
    let labels = ["Running time", "Runs", "Tokens", "Responses", "Cost"].map {
      Localization.string($0, module: "VibeUI", in: language)
    }
    let parts =
      UsagePresentation.runParts(runs, locale: locale)
      + UsagePresentation.tokenParts(tokens, locale: locale).map { "≈ " + $0 }
    #expect(labels.allSatisfy { !$0.isEmpty })
    for text in labels + parts {
      #expect(Self.width(of: text) <= Self.innerWidth, "\(text)")
    }
  }

  /// What the lines of the section say about their texts, once drawn.
  @MainActor
  final class Probe {
    var widths: [DrawnWidth] = []
  }

  /// The lines of the popover: the context, the cost and a line for each of its two models, the
  /// running time, the runs, the tokens and a line for each model, the responses.
  static let lineCount = 10
  /// With a family: a single line, whose menu holds the children (#606). It measures no width of
  /// its own: the menu's button is as wide as its text.
  static let familyLineCount = 0

  /// Draws the popover in a window never shown, until its lines have said how wide their texts
  /// were drawn: no deadline of its own, the suite's time limit stops one that never does. Writes
  /// it as a PNG in the folder `VIBE_USAGE_SNAPSHOTS` names, when it names one, to be looked at.
  private func draw(language: String, family: SessionFamilyUsage? = nil) async throws
    -> [DrawnWidth]
  {
    _ = NSApplication.shared
    let probe = Probe()
    let lineCount = Self.lineCount + (family == nil ? 0 : Self.familyLineCount)
    let host = NSHostingView(
      rootView: Self.popover(language: language, family: family)
        .environment(\.measuresDrawnWidths, true)
        .onPreferenceChange(DrawnWidths.self) { widths in
          MainActor.assumeIsolated { probe.widths = widths }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    // Every line has a label and a value.
    while probe.widths.count < 2 * lineCount {
      host.layoutSubtreeIfNeeded()
      await Task.yield()
    }

    if let folder = ProcessInfo.processInfo.environment["VIBE_USAGE_SNAPSHOTS"] {
      let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let data = try #require(image.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: folder).appendingPathComponent(
          "usage-\(language)\(family == nil ? "" : "-family").png"))
    }
    return probe.widths
  }

  @Test("No label and no value is cut", arguments: ["en", "fr", "de"])
  func nothingIsCut(language: String) async throws {
    let widths = try await draw(language: language)
    #expect(widths.count == 2 * Self.lineCount)
    for width in widths {
      #expect(width.drawn >= width.minimum - 0.5, "\(width.name)")
    }
  }

  @Test(
    "The line of a coordinator's total is cut nowhere (#606)",
    arguments: ["en", "fr", "de"])
  func familyIsNotCut(language: String) async throws {
    let widths = try await draw(language: language, family: Self.family())
    #expect(widths.count == 2 * (Self.lineCount + Self.familyLineCount))
    for width in widths {
      #expect(width.drawn >= width.minimum - 0.5, "\(width.name)")
    }
  }

  @Test("A child's menu says its cost, each model's, its running time, tokens and responses (#606)")
  func childDetails() {
    let en = Locale(identifier: "en_US")
    let figures = Self.figures()
    #expect(SessionFamilyUsageSection.cost(of: figures, locale: en) == "≈ $1,234.61")
    #expect(SessionFamilyUsageSection.cost(of: nil, locale: en) == "—")
    var unpriced = figures
    unpriced.cost = UsageCost.Estimate(unpriced: [UsageModelKey(providerID: "claude", model: nil)])
    #expect(SessionFamilyUsageSection.cost(of: unpriced, locale: en) == "Unknown price")
    // VoiceOver hears the line's cost whole, not its sign.
    #expect(
      SessionFamilyUsageSection.spokenCost(of: figures, locale: en) == "1,234.61 US dollars")
    #expect(SessionFamilyUsageSection.spokenCost(of: unpriced, locale: en) == "Unknown price")
    let lines = SessionFamilyUsageSection.details(
      of: figures, agentNames: ["claude": "Claude Code"], locale: en)
    #expect(
      lines == [
        "Cost: ≈ $1,234.61",
        "Claude Code · claude-opus-5-5: ≈ $1,234.61",
        "Claude Code · Default: Unknown price",
        "Running time: 3 h 12 min",
        "Tokens: ≈ "
          + UsagePresentation.tokenParts(figures.total.tokens, locale: en).joined(separator: " · "),
        "Responses: 48",
      ])
  }

  @Test("A family's children are named once its figures are computed; a child gone keeps its place")
  func familyNames() {
    let coordinator = SessionID()
    let named = WorkSession(name: "Quotas", coordination: .child(of: coordinator))
    let gone = SessionID()
    let families = UsageModel.families(
      [coordinator: [.init(id: named.id, depth: 1), .init(id: gone, depth: 1)]],
      totals: [coordinator: Self.figures()], figures: [named.id: Self.figures()],
      sessions: [named])
    let family = families[coordinator]
    #expect(family?.children.map(\.name) == ["Quotas", gone.description])
    #expect(family?.children.first?.figures == Self.figures())
    #expect(family?.children.last?.figures == nil)
    #expect(UsageModel.families([:], totals: [:], figures: [:], sessions: [named]).isEmpty)
  }

  @Test("The cost comes with each model's, and a model without a price says so")
  func costLines() async throws {
    let names = try await draw(language: "en").map(\.name)
    #expect(names.contains("value beside “≈ $1,234.61”"))
    #expect(names.filter { $0 == "value beside “≈ $1,234.61”" }.count == 2)
    #expect(names.contains("value beside “Unknown price”"))
  }
}

/// What the status bar's Usage button says (#574).
@MainActor
@Suite("The Usage button of the status bar")
struct SessionUsageButtonTests {
  private let en = Locale(identifier: "en_US")

  @Test("VoiceOver hears the context and the cost, whole")
  func spokenValue() {
    let summary = SessionUsageSummary(figures: SessionUsageLayoutTests.figures(), percent: 55)
    #expect(summary.cost == Decimal(string: "1234.61"))
    // The default model has no price: said after the cost, never in the label (#574).
    #expect(
      summary.spoken(locale: en)
        == "context 55%, cost about 1,234.61 US dollars. Models without a known price are left out of the total."
    )
    var priced = SessionUsageLayoutTests.figures()
    priced.cost.unpriced = []
    #expect(
      SessionUsageSummary(figures: priced, percent: 55).spoken(locale: en)
        == "context 55%, cost about 1,234.61 US dollars")
  }

  @Test("Without any price, the button says no cost; without a window, the running time")
  func noPrice() {
    var figures = SessionUsageLayoutTests.figures()
    figures.cost = UsageCost.Estimate(
      unpriced: [UsageModelKey(providerID: "claude", model: nil)])
    let summary = SessionUsageSummary(figures: figures, percent: nil)
    #expect(summary.cost == nil)
    #expect(summary.spoken(locale: en) == "3 h 12 min")
    #expect(SessionUsageSummary(figures: nil, percent: nil).spoken(locale: en) == "—")
  }

  @Test("The tooltip always gives the whole value, whichever form the label takes")
  func help() {
    let figures = SessionUsageLayoutTests.figures()
    let leftOut = "\nModels without a known price are left out of the total."
    #expect(
      SessionUsageSummary(figures: figures, percent: 55).help(locale: en)
        == "Context 55% · ≈ $1,234.61 (API equivalent)" + leftOut)
    #expect(
      SessionUsageSummary(figures: figures, percent: nil).help(locale: en)
        == "Running time 3 h 12 min · ≈ $1,234.61 (API equivalent)" + leftOut)
    var priced = figures
    priced.cost.unpriced = []
    #expect(
      SessionUsageSummary(figures: priced, percent: 55).help(locale: en)
        == "Context 55% · ≈ $1,234.61 (API equivalent)")
    var unpriced = figures
    unpriced.cost = UsageCost.Estimate()
    #expect(
      SessionUsageSummary(figures: unpriced, percent: 55).help(locale: en) == "Context 55% used")
    #expect(SessionUsageSummary(figures: nil, percent: nil).help(locale: en) == "Session usage")
  }

  @Test("Three forms, each narrower than the one before; only those the figures allow")
  func forms() {
    _ = NSApplication.shared
    let label = SessionUsageLabel(
      summary: SessionUsageSummary(figures: SessionUsageLayoutTests.figures(), percent: 55),
      isReading: false)
    #expect(label.forms == [.full, .withoutCost, .ringAlone])
    let widths = label.forms.map { form in
      NSHostingView(rootView: label.form(form).environment(\.locale, en)).fittingSize.width
    }
    #expect(widths == widths.sorted(by: >))
    #expect(Set(widths).count == 3)

    var unpriced = SessionUsageLayoutTests.figures()
    unpriced.cost = UsageCost.Estimate()
    #expect(
      SessionUsageLabel(
        summary: SessionUsageSummary(figures: unpriced, percent: nil), isReading: false
      ).forms == [.withoutCost])
  }

  @Test(
    "A coordinator with children says its total after its own cost, in every form it fits (#606)")
  func familyTotal() {
    _ = NSApplication.shared
    var own = SessionUsageLayoutTests.figures()
    own.cost.unpriced = []
    var family = SessionUsageLayoutTests.family().total
    family.cost.unpriced = []
    let summary = SessionUsageSummary(figures: own, percent: 55, family: family)
    #expect(summary.familyCost == Decimal(string: "2469.22"))
    #expect(
      summary.spoken(locale: en)
        == "context 55%, cost about 1,234.61 US dollars, total with child sessions about 2,469.22 US dollars"
    )
    #expect(
      summary.help(locale: en)
        == "Context 55% · ≈ $1,234.61 (API equivalent)\nWith child sessions: ≈ $2,469.22")
    let label = SessionUsageLabel(summary: summary, isReading: false)
    #expect(label.forms == [.withTotal, .full, .withoutCost, .ringAlone])
    #expect(label.forms(at: .full) == [.withTotal, .full, .withoutCost, .ringAlone])
    #expect(label.forms(at: .level) == [.withoutCost, .ringAlone])
    let widths = label.forms.map { form in
      NSHostingView(rootView: label.form(form).environment(\.locale, en)).fittingSize.width
    }
    #expect(widths == widths.sorted(by: >))
    #expect(Set(widths).count == 4)
  }

  @Test("A child's model without a price is said with the total; no family, nothing changes")
  func familyUnpricedAndNone() {
    var own = SessionUsageLayoutTests.figures()
    own.cost.unpriced = []
    let family = SessionUsageLayoutTests.family().total
    let leftOut = "Models without a known price are left out of the total."
    #expect(
      SessionUsageSummary(figures: own, percent: 55, family: family).help(locale: en)
        == "Context 55% · ≈ $1,234.61 (API equivalent)\nWith child sessions: ≈ $2,469.22\n"
        + leftOut)
    let alone = SessionUsageSummary(figures: own, percent: 55)
    #expect(alone.familyCost == nil)
    #expect(alone.spoken(locale: en) == "context 55%, cost about 1,234.61 US dollars")
    #expect(
      SessionUsageLabel(summary: alone, isReading: false).forms == [
        .full, .withoutCost, .ringAlone,
      ])
  }

  @Test("Dollars in the language's own way, to the cent, and never a zero for a little")
  func costFormat() {
    let fr = Locale(identifier: "fr_FR")
    func plain(_ text: String) -> String {
      text.replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    #expect(UsagePresentation.cost(Decimal(string: "4.82")!, locale: en) == "≈ $4.82")
    #expect(plain(UsagePresentation.cost(Decimal(string: "4.82")!, locale: fr)) == "≈ 4,82 $")
    #expect(
      plain(UsagePresentation.cost(Decimal(string: "4.82")!, approximate: false, locale: fr))
        == "4,82 $")
    #expect(UsagePresentation.cost(Decimal(string: "4.826")!, locale: en) == "≈ $4.83")
    #expect(UsagePresentation.cost(Decimal(string: "0.0042")!, locale: en) == "< $0.01")
    #expect(plain(UsagePresentation.cost(Decimal(string: "0.0042")!, locale: fr)) == "< 0,01 $")
    #expect(UsagePresentation.cost(0, locale: en) == "≈ $0.00")
    // Half a cent, and just under a cent, are not rounded to a zero or up to a cent (#574).
    #expect(UsagePresentation.cost(Decimal(string: "0.005")!, locale: en) == "< $0.01")
    #expect(UsagePresentation.cost(Decimal(string: "0.0099")!, locale: en) == "< $0.01")
    #expect(UsagePresentation.cost(Decimal(string: "0.01")!, locale: en) == "≈ $0.01")
  }

  /// How wide the Usage label is drawn in a status bar of `width`, in French, with a state text
  /// beside it.
  private func labelWidth(inBarOf width: CGFloat) async throws -> CGFloat {
    final class Drawn { var width: CGFloat = 0 }
    let drawn = Drawn()
    let label = SessionUsageLabel(
      summary: SessionUsageSummary(figures: SessionUsageLayoutTests.figures(), percent: 67),
      isReading: false)
    // The status bar as `TerminalStatusBar` lays it out.
    let bar = HStack(spacing: 8) {
      Image(systemName: "play.circle")
      Text(verbatim: "Processus en cours").font(.callout)
      Spacer()
      StatusAccessoryStack {
        Menu {
          Button("Par défaut") {}
        } label: {
          Text(verbatim: "Effort : par défaut")
        }
        .controlSize(.small)
        .fixedSize()
        Button {
        } label: {
          label.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { drawn.width = $0 }
        }
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        Button {
        } label: {
          Image(systemName: "terminal")
        }
        .controlSize(.small)
      }
      Button("Fermer la session…") {}.controlSize(.small)
    }
    .padding(.horizontal, 12)
    .environment(\.locale, Locale(identifier: "fr_FR"))
    let host = NSHostingView(rootView: bar)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 40)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    return drawn.width
  }

  @Test("In the status bar, the label keeps its cost while the state text has room to give")
  func roomInTheBar() async throws {
    _ = NSApplication.shared
    let whole = try await labelWidth(inBarOf: 1_200)
    // Shared evenly with the state text and the spacer, it lost its cost at 600 pt (#574).
    #expect(try await labelWidth(inBarOf: 600) == whole)
    // Where the bar runs out of room, it narrows rather than overlaps.
    #expect(try await labelWidth(inBarOf: 300) < whole)
  }
}
