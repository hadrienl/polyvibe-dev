import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeApplication

/// A session shown as a conversation (#38): messages, the agent's tools folded under titles that
/// say what they did, what it is doing now, and where to write to it.
///
/// Laid out lazily — a session of thousands of messages builds only what is on screen — and kept
/// at the end while the reader is there: scrolling up stops the following, and a pill brings them
/// back to what arrived meanwhile.
public struct ConversationView: View {
  @Bindable var model: ConversationModel
  let theme: ConversationTheme
  let appearance: ConversationAppearance
  /// Whether this is the session on screen: every conversation shown lately stays mounted.
  let isActive: Bool
  /// Whether the composer takes the keyboard when its session comes on screen (#105).
  let claimsKeyboardOnActivation: Bool
  /// A second view of the session's terminal, shown while a command waits in one of its panels
  /// (#219). `nil` where there is no terminal to show.
  /// It is given what Escape does in it: close the block.
  /// and what to tell of what its screen shows.
  let liveTerminal:
    (
      (
        _ focusRequest: Int, _ onEscape: @escaping () -> Void,
        _ onScreen: @escaping (String) -> Void
      ) -> AnyView
    )?
  /// Space as the microphone (#357), for the window this conversation is in.
  @State private var voiceKeys = VoiceKeyMonitor()
  @State private var window: NSWindow?
  @State private var contentFrame = CGRect.zero
  @State private var viewportHeight = 0.0
  @State private var pager = ConversationPager()
  /// Where a page or the overview leads, in the messages: a mark that SwiftUI scrolls to (#227).
  @State private var pageMark = PageMark()
  /// One selection from one message to the next (#381).
  @State private var selection = ConversationSelection()

  private static let bottomID = "conversation.bottom"
  static let pageTargetID = "conversation.page"
  /// The messages' own coordinates: where each row says it is (#567).
  static let contentSpace = "conversation.content"

  public init(
    model: ConversationModel, theme: ConversationTheme, appearance: ConversationAppearance,
    isActive: Bool = true, claimsKeyboardOnActivation: Bool = true,
    liveTerminal: (
      (
        _ focusRequest: Int, _ onEscape: @escaping () -> Void,
        _ onScreen: @escaping (String) -> Void
      ) -> AnyView
    )? = nil
  ) {
    self.liveTerminal = liveTerminal
    self.model = model
    self.theme = theme
    self.appearance = appearance
    self.isActive = isActive
    self.claimsKeyboardOnActivation = claimsKeyboardOnActivation
  }

  public var body: some View {
    let _ = BodyCounter.tick(.conversationView)
    // The pane's width as it is laid out, read once for all that leaves the overview its margin:
    // the overview, the messages' and the composer's room beside it, its estimates (#567). A
    // width told afterwards, by a change of geometry, once stayed that of the pane before the web
    // view came beside it: the overview took half of the pane, over the text.
    GeometryReader { pane in
      page(paneWidth: pane.size.width)
    }
  }

  private func page(paneWidth: Double) -> some View {
    let overview = overviewPlacement(paneWidth: paneWidth)
    return VStack(spacing: 0) {
      switch model.snapshot.availability {
      case .loading where model.blocks.isEmpty:
        placeholder {
          ProgressView().controlSize(.small)
          Text("Reading the conversation…", bundle: .module)
        }
      case .notYetWritten(let name) where model.blocks.isEmpty && model.echoes.isEmpty:
        placeholder {
          Image(systemName: "bubble.left.and.text.bubble.right")
            .font(.system(size: 28))
          Text("\(name) has not written anything yet.", bundle: .module)
        }
      case .unsupported, .noAgent:
        placeholder {
          Text("This session has no readable conversation.", bundle: .module)
        }
      default:
        conversation(paneWidth: paneWidth, overview: overview)
      }
    }
    // Over the end of the messages, which scroll under it, rather than below them (#359).
    .modifier(
      ComposerBar(theme: theme) {
        // Out of the footer: a session started on a command shows its panel while its
        // conversation, empty, is still read and the composer not shown yet (#219).
        if let panel = model.terminalPanel, let liveTerminal {
          TerminalPanelBlock(
            model: model, panel: panel,
            terminal: liveTerminal(
              model.terminalPanelFocusRequest,
              { model.escapeInTerminalPanel() },
              { model.terminalScreenChanged($0) })
          )
          .frame(maxWidth: layout.contentWidth)
          .padding(.leading, leadingMargin)
          .padding(.trailing, layout.sideMargin + overview.reserved)
          .padding(.bottom, showsComposer ? 8 : 16)
          .frame(maxWidth: .infinity)
        }
        // Outside the switch: the first prompt sent turns the empty conversation into a list, and
        // a composer drawn in each case would be a new one then, the keyboard dropped with the old
        // one (#105).
        if showsComposer { footer(overview: overview) }
      }
    )
    .environment(\.conversationTheme, theme)
    .environment(\.conversationAppearance, appearance)
    .environment(\.conversationIsLive, isActive)
    .environment(\.readAloud, model.readAloud)
    // The models loaded while the conversation is read, the dictation's first (#357): their
    // first load compiles them for this Mac, which takes minutes. One at a time.
    .task {
      model.dictation?.warmUp()
      model.readAloud?.warmUp()
    }
    // Space as the microphone, in the conversation on screen (#357).
    .background(WindowReader { window = $0 })
    .onChange(of: isActive, initial: true) { updateVoiceKeys() }
    .onChange(of: window) { updateVoiceKeys() }
    .onDisappear { voiceKeys.stop() }
    // The audio mode (#357): the answers that arrive are read, in the conversation on screen.
    .onChange(of: model.lastAgentAnswerID, initial: true) { followAnswers() }
    .onChange(of: model.isAgentWorking) { endTurn() }
    .onChange(of: isActive) { followAnswers() }
    .onChange(of: model.snapshot.availability == .loading) { followAnswers() }
    .environment(\.colorScheme, theme.colorScheme)
    // Coming on screen is when the composer takes the keyboard, as the terminal does (#105): only
    // then, never for a message that arrives or a state that changes. Asked of the model rather
    // than of the composer, which is drawn again whenever the conversation changes shape.
    .onAppear { if isActive { claimKeyboardOnActivation() } }
    // Every conversation shown lately stays mounted: only the one on screen is laid out (#250).
    .onChange(of: isActive, initial: true) { _, isActive in model.setShown(isActive) }
    .onDisappear {
      model.setShown(false)
      model.readAloud?.forget(ObjectIdentifier(model))
    }
    .onChange(of: isActive) { _, isActive in
      if isActive {
        claimKeyboardOnActivation()
      } else {
        // Put away before its composer could take it — the conversation still being read — a
        // request is dropped: shown again later, the session must not act on it.
        _ = model.takePendingFocusRequest()
      }
    }
    // Read through the terminal's observable state: the end of the process reaches the model.
    .onChange(of: model.isProcessRunning) { model.processStateChanged() }
    // Hidden too: a permission or a question in a session not on screen is said all the same.
    .onChange(of: model.announcedCallID) { _, id in
      guard id != nil else { return }
      let said =
        model.activity == .awaitingUser(.question)
        ? String(localized: "\(model.agentName) is asking you a question", bundle: .module)
        : String(localized: "\(model.agentName) asks for your permission", bundle: .module)
      AccessibilityNotification.Announcement(said).post()
    }
  }

  /// Everywhere but while a conversation not read yet is loading, or one that cannot be read.
  private var showsComposer: Bool {
    switch model.snapshot.availability {
    case .loading where model.blocks.isEmpty, .unsupported, .noAgent: false
    default: true
    }
  }

  private func claimKeyboardOnActivation() {
    if claimsKeyboardOnActivation { model.requestComposerFocus() }
  }

  /// The theme's layout, at the density the user chose (#118).
  private var layout: ConversationTheme.Layout { theme.layout.at(appearance.density) }

  private var spacing: Double { layout.blockSpacing }

  // MARK: - Overview and bookmarks (#567)

  /// Left of the messages: room for their moments and bookmarks, whatever margin the theme gives
  /// (#572).
  private var leadingMargin: Double { Self.leadingMargin(sideMargin: layout.sideMargin) }

  static func leadingMargin(sideMargin: Double) -> Double {
    max(sideMargin, BookmarkGutter.reach + MomentGutterMark.width)
  }

  private var showsOverview: Bool { appearance.showsOverview && !model.blocks.isEmpty }

  private func overviewPlacement(paneWidth: Double) -> ConversationOverviewLayout.Placement {
    guard showsOverview, paneWidth > 0 else { return .init(width: 0, reserved: 0) }
    return ConversationOverviewLayout.placement(
      paneWidth: paneWidth, contentWidth: layout.contentWidth, leadingMargin: leadingMargin,
      trailingMargin: layout.sideMargin)
  }

  /// What the overview estimates the blocks never built with. The column's width by steps: a
  /// window resized does not wrap every message again at each frame.
  private func overviewMetrics(
    paneWidth: Double, overview: ConversationOverviewLayout.Placement
  ) -> ConversationOverviewLayout.Metrics {
    let available =
      paneWidth - leadingMargin - layout.sideMargin - overview.reserved
    let column = min(layout.contentWidth, max(available, 200))
    return ConversationOverviewLayout.Metrics(
      columnWidth: (column / 40).rounded() * 40, textSize: appearance.textSize.pointSize,
      lineHeight: layout.lineHeight, blockSpacing: spacing,
      paragraphSpacing: layout.paragraphSpacing)
  }

  /// Tells the overview where the part read now is.
  private func trackReadablePart() {
    guard let readable = pager.readableRange() else { return }
    model.overview.scrolled(readableTop: readable.top, readableHeight: readable.height)
  }

  private func conversation(paneWidth: Double, overview: ConversationOverviewLayout.Placement)
    -> some View
  {
    // What it reads of the messages scrolled away, with the theme and the size they are shown at.
    let _ = selection.source = .of(model, theme: theme, appearance: appearance)
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: spacing) {
          ForEach(model.blocks) { block in
            BlockRow(block: block, model: model, spacing: spacing)
              .id(block.id)
          }
          ForEach(model.echoes) { echo in
            VStack(alignment: .trailing, spacing: 4) {
              if echo.kind.isShell {
                // Running from the moment it is sent: the transcript completes it.
                ShellRunView(
                  id: echo.id.uuidString, run: ShellRun(command: echo.text), model: model,
                  isEcho: true, dismiss: { model.dismissEcho(echo.id) })
                if echo.state == .unconfirmed { echoStatus(echo) }
              } else {
                UserPromptView(
                  text: echo.text, attachments: echo.messageAttachments, date: echo.sentAt,
                  isEcho: true, agentName: model.agentName,
                  showQuote: { model.showSource(of: $0, replyID: nil) })
                echoStatus(echo)
              }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.bottomID)
        }
        .environment(\.conversationSelection, selection)
        .frame(maxWidth: layout.contentWidth)
        .padding(.leading, leadingMargin)
        .padding(.trailing, layout.sideMargin + overview.reserved)
        .padding(.top, layout.topPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        // Short, the conversation fills the view from the bottom rather than leaving its emptiness
        // to the scroll view's top inset, which macOS 26 covers with the toolbar's edge effect
        // (#228).
        .frame(minHeight: viewportHeight, alignment: .bottom)
        .coordinateSpace(name: Self.contentSpace)
        // Behind the messages rather than over them: SwiftUI looks for what it scrolls to in the
        // order the views come, and would read the identifier of every block before it.
        .background(alignment: .topLeading) {
          PageMarkView(mark: pageMark, model: model, proxy: proxy)
        }
        // Inside the scroll view of the messages: the pager finds it from here (#227).
        .background(ConversationPagerProbe(pager: pager).accessibilityHidden(true))
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .scrollView)
        } action: { frame in
          contentFrame = frame
          model.scrollGeometryChanged(contentFrame: frame, viewportHeight: viewportHeight)
          trackReadablePart()
        }
      }
      .onGeometryChange(for: CGSize.self) {
        $0.size
      } action: { size in
        guard size.height != viewportHeight else { return }
        viewportHeight = size.height
        model.scrollGeometryChanged(contentFrame: contentFrame, viewportHeight: size.height)
        trackReadablePart()
      }
      .defaultScrollAnchor(.bottom)
      // The overview stands for the scroll bar (#567).
      .scrollIndicators(showsOverview ? .hidden : .automatic)
      .modifier(ToolbarVeil())
      .overlay(alignment: .trailing) {
        if showsOverview {
          // Its filters over it (#572): hidden with it, the margin keeps its icons.
          VStack(spacing: 0) {
            OverviewFilterBar(model: model)
            ConversationOverview(
              model: model, theme: theme,
              metrics: overviewMetrics(paneWidth: paneWidth, overview: overview), pager: pager,
              room: paneWidth - overview.width
            )
          }
          .frame(width: overview.width)
          .modifier(OverviewBandFade())
        }
      }
      .onAppear {
        let selection = selection
        model.selectedBlockID = {
          guard selection.isActive, selection.anchor != selection.focus else { return nil }
          return selection.focus?.block
        }
      }
      .onChange(of: model.scrollToBottomRequest) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
        // Once it has gone there, and the rows it reached are measured.
        DispatchQueue.main.async { model.scrolledToBottom() }
      }
      .onChange(of: model.pageRequest) {
        guard let top = pager.readableTop(after: model.pageRequest.page) else { return }
        pageMark.lead(to: top, proxy: proxy)
      }
      .onChange(of: model.revealRequest) {
        guard let id = model.revealedBlockID else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
      }
      .overlay(alignment: .top) {
        if let readAloud = model.readAloud, readAloud.isReading {
          ReadingAloudPill(readAloud: readAloud)
        } else if let readAloud = model.readAloud, readAloud.problem == .readingFailed {
          ReadingFailedNotice(readAloud: readAloud)
        }
      }
      .overlay(alignment: .bottom) {
        if model.returnBlockID != nil {
          ReturnToReplyButton(model: model).padding(.bottom, 10)
        } else if model.scroll.unseenCount > 0 {
          Button {
            model.jumpToBottom()
          } label: {
            Label {
              Text("\(model.scroll.unseenCount) new messages", bundle: .module)
            } icon: {
              Image(systemName: "arrow.down")
            }
            .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5), weight: .semibold))
            .foregroundStyle(theme.text.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(
              ConversationGlass(
                shape: Capsule(), fill: theme.raised.color, border: theme.border.color,
                isInteractive: true, shadowRadius: 6, shadowOpacity: 0.2, shadowY: 2))
          }
          .buttonStyle(.plain)
          .padding(.bottom, 10)
        }
      }
      .accessibilityRotor(Text("Messages", bundle: .module)) {
        ForEach(model.promptBlocks) { block in
          AccessibilityRotorEntry(Text(Self.rotorLabel(block)), id: block.id)
        }
      }
      .accessibilityRotor(Text("Failures", bundle: .module)) {
        ForEach(model.failureBlocks) { block in
          AccessibilityRotorEntry(
            Text(verbatim: ToolBlockView.accessibilityTitle(of: block)), id: block.id)
        }
      }
      // Bookmarks included, as the filters show them (#572).
      .accessibilityRotor(Text("Moments", bundle: .module)) {
        ForEach(model.momentBlocks, id: \.block.id) { item in
          AccessibilityRotorEntry(
            Text(verbatim: MomentPresentation.rotorLabel(of: item.moments, block: item.block)),
            id: item.block.id)
        }
      }
      .accessibilityRotor(Text("Sub-agents", bundle: .module)) {
        ForEach(model.subagentBlocks) { block in
          AccessibilityRotorEntry(
            Text(
              verbatim: block.calls.map(SubagentPresentation.description(of:))
                .joined(separator: ", ")),
            id: block.id)
        }
      }
    }
  }

  private func footer(overview: ConversationOverviewLayout.Placement) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      // Out of the messages that scroll: a sub-agent in the background runs long after its block
      // has gone up (#180).
      if !model.trayItems.isEmpty {
        SubagentTray(model: model)
      }
      if model.isAgentWorking {
        ActivityLine(model: model).modifier(StatusGlass())
      }
      if model.composerState == .stopped, let failure = model.shownLaunchFailure {
        HStack(alignment: .firstTextBaseline) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(failure.message)
              if let suggestion = failure.suggestion {
                Text(suggestion).foregroundStyle(theme.secondaryText.color)
              }
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
          Spacer()
          if failure.canDetectAgain, let detectAgain = model.detectAgentsAgain {
            Button {
              Task { await detectAgain() }
            } label: {
              Text("Detect Again", bundle: .module)
            }
          }
          stoppedActions
        }
        .modifier(StatusGlass())
      } else if model.composerState == .stopped, model.hasStoppedOnError {
        HStack {
          Label {
            Text(
              "The agent stopped on an error. Its terminal says why.", bundle: .module,
              comment: "Under a conversation whose agent ended on its own, not closed by the user.")
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
          .foregroundStyle(theme.secondaryText.color)
          Spacer()
          stoppedActions
        }
        .modifier(StatusGlass())
      } else if model.composerState == .stopped, model.canRestart(), let restart = model.restart {
        HStack {
          Label {
            Text("The session is stopped. Its history stays readable.", bundle: .module)
          } icon: {
            Image(systemName: "stop.circle")
          }
          .font(theme.interfaceFont(size: appearance.textSize.scaled(12.5)))
          .foregroundStyle(theme.secondaryText.color)
          Spacer()
          Button(action: restart) {
            Text("Restart", bundle: .module)
          }
        }
        .modifier(StatusGlass())
      }
      if let update = model.agentUpdate, model.composerState != .stopped {
        AgentUpdateNotice(model: model, update: update).modifier(StatusGlass())
      }
      if let signIn = model.signIn, model.composerState != .stopped {
        SignInNotice(model: model, signIn: signIn).modifier(StatusGlass())
      } else if let request = model.standaloneRequest {
        StandaloneRequestCard(model: model, request: request)
          .modifier(StatusGlass())
      }
      PromptComposer(model: model, isActive: isActive)
    }
    .frame(maxWidth: layout.contentWidth)
    .padding(.leading, leadingMargin)
    .padding(.trailing, layout.sideMargin + overview.reserved)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity)
    .modifier(PlainFooterBackground(theme: theme))
  }

  /// The way to the terminal, which says why, and Restart, for an agent that stopped on an error.
  @ViewBuilder
  private var stoppedActions: some View {
    if let showTerminal = model.showTerminal {
      Button(action: showTerminal) {
        Text("Show the Terminal", bundle: .module)
      }
    }
    if model.canRestart(), let restart = model.restart {
      Button(action: restart) {
        Text("Restart", bundle: .module)
      }
    }
  }

  @ViewBuilder
  private func echoStatus(_ echo: PendingEcho) -> some View {
    switch echo.state {
    case .sending:
      HStack(spacing: 8) {
        Text("Sending…", bundle: .module)
        sendNowButton(echo)
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(11)))
      .foregroundStyle(theme.secondaryText.color)
    case .unconfirmed:
      HStack(spacing: 8) {
        Text("Not confirmed by the agent yet", bundle: .module)
        sendNowButton(echo)
        Button {
          model.showTerminal?()
        } label: {
          Text("Show the Terminal", bundle: .module)
        }
        .buttonStyle(.link)
        Button {
          model.dismissEcho(echo.id)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Dismiss", bundle: .module))
      }
      .font(theme.interfaceFont(size: appearance.textSize.scaled(11)))
      .foregroundStyle(theme.warning.color)
    }
  }

  /// Under the last message queued during a turn: sends them all now, the turn stopped (#341).
  @ViewBuilder
  private func sendNowButton(_ echo: PendingEcho) -> some View {
    if model.canSendNow(echo) {
      Button {
        Task { await model.sendNow() }
      } label: {
        Text("Send Now", bundle: .module)
      }
      .buttonStyle(.link)
    }
  }

  private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 10, content: content)
      .font(theme.interfaceFont(size: appearance.textSize.scaled(13)))
      .foregroundStyle(theme.secondaryText.color)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private static func rotorLabel(_ block: ConversationBlock) -> String {
    guard case .entry(let entry) = block,
      case .userPrompt(let text, let attachments) = entry.content
    else { return block.id }
    if let relayed = RelayedMessage(text, attachments: attachments) {
      return RelayedMessageView.summary(of: relayed)
    }
    // A reply is named by its own words, not by the passage it quotes (#565).
    return String(ReplyQuote.message(of: text).prefix(80))
  }
}

/// Where a page or the overview leads (#227, #567). Its own object, read by its own view: moved at
/// each step of a drag in the overview, it would otherwise have the whole conversation evaluated
/// again, and SwiftUI compare the identifiers of its thousands of blocks, at every frame.
@MainActor
@Observable
final class PageMark {
  private(set) var top = 0.0
  /// Asked for, scrolled to once the mark has been laid out where it leads.
  @ObservationIgnored var isPending = false

  /// Scrolls so that this point of the messages is at the top of what is read.
  func lead(to top: Double, proxy: ScrollViewProxy) {
    // A mark already there is not laid out again.
    guard max(top, 0) != max(self.top, 0) else {
      proxy.scrollTo(ConversationView.pageTargetID, anchor: .top)
      return
    }
    isPending = true
    self.top = top
  }
}

/// The mark itself: laid out there, not drawn there — an offset would leave it where SwiftUI
/// scrolls to. It follows the overview too: read anywhere in the list, each step of a drag would
/// have it all made again.
private struct PageMarkView: View {
  let mark: PageMark
  let model: ConversationModel
  let proxy: ScrollViewProxy

  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .id(ConversationView.pageTargetID)
      .padding(.top, max(mark.top, 0))
      // Scrolled to once laid out there: asked any sooner — on the next turn of the main loop, on
      // a machine that lags —, SwiftUI scrolls to where it was, and the page does not move.
      .onGeometryChange(for: Double.self) {
        $0.size.height
      } action: { _ in
        guard mark.isPending else { return }
        mark.isPending = false
        proxy.scrollTo(ConversationView.pageTargetID, anchor: .top)
      }
      .onChange(of: model.overviewScroll) {
        guard let target = model.overviewScroll else { return }
        if let top = target.top ?? model.overview.top(of: target.blockID) {
          mark.lead(to: top + target.offset, proxy: proxy)
        } else {
          // Far from any row built: brought up first, the next move of the drag lands to the
          // point.
          proxy.scrollTo(target.blockID, anchor: .top)
        }
      }
      .accessibilityHidden(true)
  }
}

/// A block of the conversation and, above the first message of a day, its separator: one element
/// of the list, so that scrolling to the message shows the day it opens (#458).
struct BlockRow: View {
  let block: ConversationBlock
  let model: ConversationModel
  let spacing: Double
  @Environment(\.conversationTheme) private var theme
  @Environment(\.conversationAppearance) private var appearance
  @State private var isHovered = false

  var body: some View {
    Group {
      if let day = model.days.day(opening: block.id) {
        VStack(alignment: .leading, spacing: spacing) {
          DaySeparator(day: day, clock: model.clock)
          bookmarkable
        }
      } else {
        bookmarkable
      }
    }
    // Where it is in the messages, for the overview (#567). Not moved by a scroll.
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(ConversationView.contentSpace))
    } action: { frame in
      model.overview.rowLaidOut(block.id, frame: frame)
    }
    .onDisappear { model.overview.rowGone(block.id) }
  }

  /// The block, its bookmark in the margin left of it, and the light a bookmark brings it up
  /// with (#567). Left of the bookmark, the icon of its moments (#572), in a box of the same
  /// height at the same top: both are centred on its first line.
  private var bookmarkable: some View {
    BlockView(block: block, model: model)
      // A message's own view lights it already (#565): the others, here.
      .modifier(ReplyHighlight(isLit: !isLitByItsView && model.highlightedBlockID == block.id))
      .onHover { isHovered = $0 }
      .overlay(alignment: .topLeading) {
        // Without the overview, neither bookmarks nor moments (#572).
        if appearance.showsOverview { gutter }
      }
  }

  /// The block's moment and bookmark, left of it.
  private var gutter: some View {
    HStack(alignment: .top, spacing: 0) {
      let moments = model.moments(of: block).filter { appearance.shows($0.kind) }
      if moments.isEmpty {
        Color.clear.frame(width: MomentGutterMark.width, height: 1)
      } else {
        MomentGutterMark(moments: moments, block: block, lineHeight: linePitch)
      }
      BookmarkGutter(
        isMarked: model.isBookmarked(block), isRowHovered: isHovered, lineHeight: linePitch
      ) {
        model.toggleBookmark(block)
      }
    }
    .padding(.top, firstLineTop)
    .offset(x: -(BookmarkGutter.reach + MomentGutterMark.width))
  }

  /// Whether its view lights it itself when it is brought up: what the user and the agent wrote.
  private var isLitByItsView: Bool {
    guard case .entry(let entry) = block else { return false }
    switch entry.content {
    case .userPrompt, .agentText: return true
    default: return false
    }
  }

  private var linePitch: Double {
    appearance.textSize.pointSize * theme.layout.at(appearance.density).lineHeight
  }

  /// Where the block's first line starts in it: inside a bubble or a tool's frame, its padding.
  private var firstLineTop: Double {
    let framed = appearance.density == .compact ? 6.0 : 9.0
    switch block {
    case .toolGroup, .subagentGroup:
      return framed
    case .entry(let entry):
      switch entry.content {
      case .userPrompt: return appearance.userMessageStyle == .bubbles ? 10 : 6
      case .tool, .notice(.shell): return framed
      default: return 0
      }
    }
  }
}

/// One block of the conversation, or of a sub-agent's activity.
struct BlockView: View {
  let block: ConversationBlock
  let model: ConversationModel
  /// Inside a sub-agent's activity.
  var isNested = false

  /// Its text is part of the conversation's selection, unless it is a sub-agent's (#381).
  private var selectionBlock: String? { isNested ? nil : block.id }

  var body: some View {
    switch block {
    case .toolGroup:
      ToolBlockView(block: block, model: model)
    case .subagentGroup:
      SubagentGroupView(block: block, model: model)
    case .entry(let entry):
      switch entry.content {
      case .userPrompt(let text, let attachments):
        // Vibe Manager's or the coordinator's, not the user's: who wrote it says so.
        if let relayed = RelayedMessage(text, attachments: attachments) {
          RelayedMessageView(
            id: entry.id, message: relayed, text: text, date: entry.date, model: model
          )
          .environment(\.selectionBlock, selectionBlock)
        } else {
          UserPromptView(
            text: text, attachments: attachments, date: entry.date, agentName: model.agentName,
            showQuote: isNested ? nil : { model.showSource(of: $0, replyID: entry.id) },
            reply: replyAction(entry, author: .user),
            replies: model.replyLinks.replies[entry.id] ?? [], showReply: model.showReply
          )
          .environment(\.selectionBlock, selectionBlock)
          .environment(\.replyToPassage, passageReply(entry, author: .user))
          .environment(\.litPassage, litPassage(entry))
          .modifier(ReplyHighlight(isLit: model.highlightedBlockID == entry.id))
        }
      case .agentText(let text):
        AgentTextView(
          text: text, id: entry.id, readAloud: model.readAloud, date: entry.date,
          replies: model.replyLinks.replies[entry.id] ?? [], showReply: model.showReply,
          reply: replyAction(entry, author: .agent)
        )
        .environment(\.selectionBlock, selectionBlock)
        .environment(\.replyToPassage, passageReply(entry, author: .agent))
        .environment(\.litPassage, litPassage(entry))
        .modifier(ReplyHighlight(isLit: model.highlightedBlockID == entry.id))
        // Only the agent's own answers: a command in a sub-agent's mission or a plan was not
        // written for the user to run (#548).
        .environment(\.shellCommandRunner, model)
      case .reasoning(let text):
        ReasoningRow(id: entry.id, text: text, model: model)
          .environment(\.selectionBlock, selectionBlock)
      case .tool(let call) where call.kind == .subagent:
        SubagentBlockView(call: call, model: model, isNested: isNested)
      case .tool:
        ToolBlockView(block: block, model: model)
      case .notice(.shell(let run)):
        ShellRunView(id: entry.id, run: run, model: model)
      case .notice(let notice):
        NoticeRow(notice: notice)
      }
    }
  }

  /// Replies to a passage of `entry` (#565): none inside a sub-agent's activity.
  private func replyAction(_ entry: ConversationEntry, author: ReplyQuote.Author)
    -> ((String) -> Void)?
  {
    guard !isNested else { return nil }
    return { model.reply(to: $0, author: author, date: entry.date, blockID: entry.id) }
  }

  /// The passage a reply quotes, while it is lit in `entry`.
  private func litPassage(_ entry: ConversationEntry) -> PassageLight? {
    guard !isNested, let lit = model.litPassage, lit.blockID == entry.id else { return nil }
    return PassageLight(passage: lit) { [model] in model.passageShown(lit) }
  }

  private func passageReply(_ entry: ConversationEntry, author: ReplyQuote.Author) -> PassageReply?
  {
    replyAction(entry, author: author).map { PassageReply(id: entry.id, action: $0) }
  }
}

/// The terminal panel and the footer, laid over the end of the messages on macOS 26: they scroll
/// under the composer's glass instead of stopping short above it (#359). Before, below them.
///
/// The theme's picture, when it has one, stays where it is while the messages scroll (#118), and
/// as the bar grows: laid over the whole view, never over the messages' part of it, which shrinks
/// for a long draft or the agent's activity, and the picture filling it would be cropped anew.
/// Behind the messages only, the plain background covers it under the bar, behind the messages
/// that scroll there.
private struct ComposerBar<Bar: View>: ViewModifier {
  let theme: ConversationTheme
  @ViewBuilder let bar: Bar
  @State private var barHeight = 0.0

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        // An inset, not a bar: under a bar, macOS 26 blurs its whole height as soon as it grows
        // for the agent's activity, cut sharp at the top — the very break the glass removes.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) { bar }
            .onGeometryChange(for: Double.self) {
              $0.size.height
            } action: {
              barHeight = $0
            }
        }
        .background {
          ThemeBackdropView(theme: theme)
            .overlay(alignment: .bottom) {
              if theme.backdrop.area == .messages {
                theme.background.color.frame(height: barHeight)
              }
            }
            .ignoresSafeArea()
        }
    } else {
      VStack(spacing: 0) {
        content
        bar
      }
      .background { ThemeBackdropView(theme: theme).ignoresSafeArea() }
    }
  }
}

/// Before macOS 26, a picture behind the messages only leaves the footer the plain background.
private struct PlainFooterBackground: ViewModifier {
  let theme: ConversationTheme

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
    } else {
      content.background(theme.backdrop.area == .messages ? theme.background.color : .clear)
    }
  }
}

/// What scrolls under the toolbar is blurred the whole height of it.
///
/// The soft edge effect of macOS 26 blurs the top of the toolbar only and fades out towards its
/// foot: a message level with the title or the pickers stayed legible under them. The hard one
/// blurs it all, under a veil of the window's background. Before macOS 26 there is no edge effect.
private struct ToolbarVeil: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.scrollEdgeEffectStyle(.hard, for: .top)
    } else {
      content
    }
  }
}

extension ConversationSelection.Source {
  /// The conversation's blocks, and the text of its prompts, answers and unfolded reasoning as
  /// their views show it: a copy takes it from here once they have scrolled away (#381).
  @MainActor
  static func of(
    _ model: ConversationModel, theme: ConversationTheme, appearance: ConversationAppearance
  ) -> Self {
    let size = appearance.textSize.pointSize
    let spacing = theme.layout.at(appearance.density).paragraphSpacing
    func pieces(_ contents: [SegmentView.Content]) -> [SelectionText.Piece] {
      contents.map {
        SelectionText.Piece(
          kind: $0.kind,
          text: SegmentView.text(of: $0, theme: theme, size: size, spacing: spacing))
      }
    }
    return Self(
      blocks: { model.blocks.map(\.id) },
      pieces: { id in
        guard case .entry(let entry) = model.blocks.first(where: { $0.id == id }) else {
          return []
        }
        switch entry.content {
        case .userPrompt(let text, let attachments):
          if let relayed = RelayedMessage(text, attachments: attachments) {
            // Folded, nothing of it is shown.
            guard model.isExpanded(id: entry.id, default: false) else { return [] }
            return pieces(
              MarkdownBlocksView.contents(MarkdownCache.shared.blocks(for: relayed.body)))
          }
          let shown = ReplyLinks.shown(text, attachments: attachments).message
          guard !shown.isEmpty else { return [] }
          let color = appearance.userMessageStyle == .bubbles ? theme.bubbleText : theme.text
          return pieces([.plain(shown, color: color)])
        case .agentText(let text):
          return pieces(MarkdownBlocksView.contents(MarkdownCache.shared.blocks(for: text)))
        case .reasoning(let text?) where model.isExpanded(id: entry.id, default: false):
          return pieces(MarkdownBlocksView.contents(MarkdownCache.shared.blocks(for: text)))
        default:
          return []
        }
      },
      reply: { id in
        guard case .entry(let entry) = model.blocks.first(where: { $0.id == id }) else {
          return nil
        }
        let author: ReplyQuote.Author
        switch entry.content {
        // Vibe Manager's and a coordinator's words are not the user's to quote as theirs.
        case .userPrompt(let text, let attachments):
          guard RelayedMessage(text, attachments: attachments) == nil else { return nil }
          author = .user
        case .agentText: author = .agent
        default: return nil
        }
        return { model.reply(to: $0, author: author, date: entry.date, blockID: entry.id) }
      })
  }
}

extension ConversationView {
  /// Tells the reading aloud the answers this conversation has now, and whether it is on screen.
  fileprivate func followAnswers() {
    // Not before the conversation is read: its history would be taken for answers just arrived.
    guard model.snapshot.availability != .loading else { return }
    model.readAloud?.follow(
      model.agentAnswers, in: ObjectIdentifier(model), isOnScreen: isActive)
  }

  /// The agent's turn over: a discussion ended on a sentence has had its whole answer.
  fileprivate func endTurn() {
    guard !model.isAgentWorking else { return }
    model.readAloud?.turnEnded(in: ObjectIdentifier(model))
  }
}

extension ConversationView {
  /// Installs Space as the microphone while this conversation is on screen, and takes it away
  /// when it is not.
  fileprivate func updateVoiceKeys() {
    guard isActive, let dictation = model.dictation, window != nil else {
      voiceKeys.stop()
      return
    }
    let model = model
    voiceKeys.start(
      in: window,
      VoiceKeyMonitor.Actions(
        press: {
          guard model.acceptsInput || dictation.phase == .discussing else { return false }
          model.readAloud?.stop()
          dictation.pressBegan(model.dictationRequest())
          return true
        },
        release: { dictation.pressEnded(model.dictationRequest()) },
        escape: {
          guard dictation.concerns(ObjectIdentifier(model)),
            dictation.phase == .discussing || dictation.phase == .recording
          else { return false }
          dictation.cancel()
          return true
        }))
  }
}
