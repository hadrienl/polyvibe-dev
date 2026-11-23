import AppKit
import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain
import VibeTerminalUI

/// The agent of a session, in its status bar (#575): "Claude Code · Opus 5.5", before the effort,
/// which depends on it.
///
/// A native menu of two lines, `AgentMenu`. On top, the agent the session runs and its state,
/// with the history of its switches as its submenu. Below, "Switch To", with the models of each
/// agent as its submenu: one of them opens the Switch Agent sheet set on it. The side its
/// submenus open on, and where they line up, are macOS's.
///
/// The button looks like the effort's menu beside it; its menu is AppKit's, which gives its first
/// line a title in bold and each agent its logo.
struct SessionAgentMenu: View {
  let model: AppModel
  let session: WorkSession
  @Environment(\.statusBarDensity) private var density
  @Environment(\.layoutDirection) private var layoutDirection
  /// The button's own view, which the menu opens above.
  @State private var anchor = MenuAnchor.Holder()

  var body: some View {
    let names = model.agentLabels
    let canSwitch = model.canSwitchAgent(session)
    // The bar's step, or a narrower one when even that does not fit.
    ViewThatFits(in: .horizontal) {
      ForEach(density.andNarrower, id: \.self) { form in
        Button {
          openMenu(names: names, canSwitch: canSwitch)
        } label: {
          HStack(spacing: 8) {
            label(names: names, form: form)
            // A menu's own mark, as the effort's menu draws it.
            Image(systemName: "chevron.down")
              .font(.system(size: 8, weight: .semibold))
              .accessibilityHidden(true)
          }
        }
        .controlSize(.small)
        .fixedSize()
      }
    }
    .background(MenuAnchor(holder: anchor))
    .disabled(!Self.opens(for: session))
    // Outside the disabled menu, so that it is shown on the menu greyed out too.
    .instantTooltip(Text(verbatim: help(names: names, canSwitch: canSwitch)))
    .accessibilityLabel(
      Text("Agent", bundle: .module, comment: "The status bar's menu of the agent, for VoiceOver.")
    )
    .accessibilityValue(
      Text(
        verbatim: session.agent.map { names.label($0, separator: ", ") }
          ?? String(localized: "No agent recorded", bundle: .module))
    )
  }

  // MARK: - The button

  /// The button's label at a step of the bar: "Claude Code · Opus 5.5", the model alone, or the
  /// icon.
  @ViewBuilder
  private func label(names: AgentLabels, form: StatusBarDensity) -> some View {
    if let agent = session.agent {
      switch form {
      case .full:
        Text(verbatim: names.label(agent))
      case .model, .level, .gauge:
        // The agent's name when it runs its default model: there is no model to name.
        Text(verbatim: names.model(of: agent) ?? names.name(of: agent.providerID))
      case .icons:
        // The agent's own logo: at this width, it is what tells Claude Code from Codex.
        Image(systemName: Self.symbol(of: agent, among: model.agentDescriptors))
      }
    } else if form == .icons {
      Image(systemName: AgentMenuContent.unknownAgentSymbol)
    } else {
      Text("No agent recorded", bundle: .module)
    }
  }

  /// The logo of the session's agent, as its provider describes itself — known before any
  /// detection — or a generic one for an agent this build does not know.
  static func symbol(
    of agent: SessionAgentConfiguration, among descriptors: [AgentDescriptor]
  ) -> String {
    descriptors.first { $0.id.rawValue == agent.providerID }?.symbolName
      ?? AgentMenuContent.unknownAgentSymbol
  }

  /// The full value, whatever the label leaves out, or why nothing can be chosen.
  private func help(names: AgentLabels, canSwitch: Bool) -> String {
    guard let agent = session.agent else {
      return String(localized: "This session was stored without an agent.", bundle: .module)
    }
    let label = names.label(agent)
    if canSwitch {
      return String(
        localized: "Agent: \(label)", bundle: .module,
        comment: "Help of the status bar's menu of the agent: its name and model.")
    }
    if session.status == .archived {
      return String(
        localized: "Agent: \(label). An archived session's agent cannot be switched.",
        bundle: .module,
        comment: "Help of the status bar's menu of the agent, for an archived session.")
    }
    return String(
      localized:
        "Agent: \(label). It can be switched once the session is done restarting, closing or being restored.",
      bundle: .module,
      comment:
        "Help of the status bar's menu of the agent, while the session restarts, closes or is restored."
    )
  }

  // MARK: - The menu

  /// Whether the menu opens: whenever the session has an agent. One that cannot be switched now —
  /// archived, restarting, closing, being restored — still shows its state and its history, with
  /// only Switch To greyed out.
  static func opens(for session: WorkSession) -> Bool {
    session.agent != nil
  }

  /// Opens the menu above the button, as it is now; the agents are read again meanwhile, for the
  /// next time — an agent installed since is offered then.
  private func openMenu(names: AgentLabels, canSwitch: Bool) {
    let content = AgentMenuContent(
      session: session, names: names, choices: model.agentChoices, state: stateSentence,
      canSwitch: canSwitch)
    let id = session.id
    let menu = AgentMenu.make(content) { [model] target in
      model.beginAgentSwitch(id, preselected: target)
    }
    Task { [model] in await model.refreshAgentChoices() }
    guard let view = anchor.view else { return }
    menu.userInterfaceLayoutDirection =
      layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
    menu.popUp(
      positioning: nil,
      at: Self.menuOrigin(
        menu: menu.size, button: view.bounds, isFlipped: view.isFlipped,
        direction: layoutDirection),
      in: view)
  }

  /// Where the menu's top left corner goes, in the button's own coordinates: above the button, a
  /// little apart, lined up on its leading edge — its left one, or its right one in Arabic or
  /// Hebrew, where the bar is mirrored but an AppKit view's coordinates are not.
  static func menuOrigin(
    menu: NSSize, button: NSRect, isFlipped: Bool, direction: LayoutDirection
  ) -> NSPoint {
    let gap: CGFloat = 4
    let top = isFlipped ? button.minY - gap - menu.height : button.maxY + gap + menu.height
    let left = direction == .rightToLeft ? button.maxX - menu.width : button.minX
    return NSPoint(x: left, y: top)
  }

  private var stateSentence: String {
    AgentHistoryPresentation.state(
      of: model.pane(for: session.id)?.status, resolution: model.resolution(forID: session.id))
  }

}

/// What the history of a session's agents says (#575), in words: the menu's lines, and what
/// VoiceOver reads of each. Every agent the session had, newest first: each switch, the failed
/// ones included, then where it started.
@MainActor
struct AgentHistoryPresentation: Equatable {
  struct Entry: Equatable, Identifiable {
    enum ID: Hashable {
      case change(AgentChange.ID)
      case start
    }

    let id: ID
    /// "Codex · gpt-6.1 → Claude Code · Opus 5.5", "→ Opus 5.5 failed", "Started with …".
    let title: String
    /// When, and what was handed over, or why it failed.
    let detail: String
    let failed: Bool
    let spoken: String
  }

  let entries: [Entry]
  /// Whether the session ever switched, or tried to: its start alone is no history.
  let hasChanges: Bool

  init(session: WorkSession, names: AgentLabels) {
    var entries = session.agentHistory.reversed().map { Self.entry($0, names: names) }
    // The agent that first ran: the one the first real switch left, or the current one. A switch
    // made before the session ever ran does not count — the agent it left never started.
    let first = session.agentHistory.first(where: \.leftAgentThatRan)?.previous ?? session.agent
    if let first, let start = session.startedAt {
      let label = names.label(first)
      entries.append(
        Entry(
          id: .start,
          title: String(
            localized: "Started with \(label)", bundle: .module,
            comment: "The agent a session first ran: its name, and its model."),
          detail: Self.shown(start),
          failed: false,
          spoken: String(
            localized: "\(Self.spoken(start)), started with \(label)", bundle: .module,
            comment: "What VoiceOver says of a session's start: a date, then its first agent.")))
    }
    self.entries = entries
    hasChanges = !session.agentHistory.isEmpty
  }

  private static func entry(_ change: AgentChange, names: AgentLabels) -> Entry {
    let from = side(change.previous, of: change, names: names)
    let to = side(change.next, of: change, names: names)
    switch change.outcome {
    case .completed:
      let handover = handover(change.handover)
      return Entry(
        id: .change(change.id),
        title: "\(from) → \(to)",
        detail: "\(shown(change.date)) · \(handover)",
        failed: false,
        spoken: String(
          localized:
            "\(spoken(change.date)), switched from \(from) to \(to), \(handover)",
          bundle: .module,
          comment:
            "What VoiceOver says of an agent switch: a date, the agent left, the agent taken, and what was handed over."
        ))
    case .failed(let reason):
      return Entry(
        id: .change(change.id),
        title: String(
          localized: "→ \(to) failed", bundle: .module,
          comment: "A switch to this agent that failed."),
        detail: reason.isEmpty ? shown(change.date) : "\(shown(change.date)) · \(reason)",
        failed: true,
        spoken: String(
          localized: "\(spoken(change.date)), switch to \(to) failed. \(reason)",
          bundle: .module,
          comment: "What VoiceOver says of a failed agent switch: a date, the agent, and why."))
    }
  }

  /// One side of a switch. Between two models of the same agent, a side without a model of its
  /// own is the agent's default model, said so: "Claude Code · Opus 5.5 → Claude Code" would not
  /// say that a model was changed at all.
  private static func side(
    _ agent: SessionAgentConfiguration, of change: AgentChange, names: AgentLabels
  ) -> String {
    guard !change.changesProvider, agent.modelID == nil else { return names.label(agent) }
    let defaultModel = String(localized: "Default model of the agent", bundle: .module)
    return "\(names.name(of: agent.providerID)) · \(defaultModel)"
  }

  /// The state of the session's agent: its process's own when it has one — running, starting,
  /// stopped, failed — and otherwise whether it can be resumed. A running agent is never said to
  /// be ready to resume: the status bar has no other word that it runs.
  static func state(
    of status: TerminalPaneModel.Status?, resolution: SessionAgentResolution?
  ) -> String {
    status?.label ?? state(of: resolution)
  }

  /// Whether the agent can be resumed, or why not.
  static func state(of resolution: SessionAgentResolution?) -> String {
    switch resolution {
    case .ready:
      return String(localized: "Ready to resume.", bundle: .module)
    case .unavailable(let diagnostic):
      return diagnostic.summary
    case .unknownProvider(let providerID):
      return String(
        localized: "The provider \(providerID) is not installed in this build.", bundle: .module,
        comment: "An agent's identifier: claude-code, codex.")
    case .unassigned:
      return String(localized: "This session was stored without an agent.", bundle: .module)
    case .none:
      return String(localized: "Detection has not answered yet.", bundle: .module)
    }
  }

  static func handover(_ handover: AgentChange.Handover) -> String {
    switch handover {
    case .resumedConversation:
      return String(
        localized: "same conversation", bundle: .module,
        comment: "What an agent switch handed over: the conversation was resumed.")
    case .conversationHistory:
      return String(localized: "conversation history", bundle: .module)
    case .summary(let bytes, _, let wasEdited):
      let size = AgentSwitchSheet.size(bytes)
      return wasEdited
        ? String(
          localized: "edited summary, \(size)", bundle: .module,
          comment: "What an agent switch handed over: a size, “1.2 KiB”.")
        : String(
          localized: "summary, \(size)", bundle: .module,
          comment: "What an agent switch handed over: a size, “1.2 KiB”.")
    case .initialPrompt:
      return String(
        localized: "initial prompt", bundle: .module,
        comment: "What an agent switch handed over.")
    case .nothing:
      return String(
        localized: "nothing handed over", bundle: .module,
        comment: "What an agent switch handed over.")
    }
  }

  private static func shown(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func spoken(_ date: Date) -> String {
    date.formatted(date: .long, time: .shortened)
  }
}

/// How a session's agent and its model are named, wherever they are (#575): the agent's name,
/// and the model's as its catalogue gives it — "Claude Code · Opus 5.5" — or its identifier when
/// the catalogue does not list it. The one source of that label: `AppModel.agentLabels`.
struct AgentLabels: Equatable {
  let names: [String: String]
  /// Provider, then model identifier, to the model's name.
  var models: [String: [String: String]] = [:]

  func name(of providerID: String) -> String {
    AgentNaming.name(of: providerID, names: names)
  }

  /// `nil` for the agent's default model. An alias — `opus` — is named after the model it stands
  /// for, whatever its case.
  func model(of agent: SessionAgentConfiguration) -> String? {
    agent.modelID.map { id in
      let names = models[agent.providerID]
      return names?[id] ?? names?[id.lowercased()] ?? id
    }
  }

  func label(_ agent: SessionAgentConfiguration, separator: String = " · ") -> String {
    let name = name(of: agent.providerID)
    return model(of: agent).map { "\(name)\(separator)\($0)" } ?? name
  }
}

/// The view the agent's menu opens from: SwiftUI gives a button no view of its own.
struct MenuAnchor: NSViewRepresentable {
  @MainActor
  final class Holder {
    weak var view: NSView?
  }

  let holder: Holder

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    holder.view = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    holder.view = view
  }
}
