import AppKit
import SwiftUI
import VibeApplication

/// Where the rows of the conversation are, as they are built (#567): what the overview places
/// its frame with, and what the bookmark commands start from.
///
/// The list builds only the rows on screen: each tells its frame in the messages while it is
/// built, and its height is kept once it is gone. SwiftUI's own position is not used for the
/// frame: it estimates the rows never built its own way, and the frame would not fall on the
/// blocks the overview draws.
@MainActor
@Observable
public final class ConversationOverviewTracker {
  /// The block at the top of what is read, below the toolbar, and how far into it.
  public struct Top: Hashable, Sendable {
    public var blockID: String
    public var offset: Double
  }

  /// The height of each row built, by block, kept once it is gone.
  @ObservationIgnored public private(set) var measured: [String: Double] = [:]
  /// The rows built now, in the messages' coordinates.
  @ObservationIgnored private(set) var frames: [String: CGRect] = [:]
  /// Bumped when a height measured changes: the overview lays out again.
  public private(set) var measureRevision = 0
  public private(set) var top: Top?
  /// The height of what is read, between the toolbar and the foot.
  public private(set) var readableHeight = 0.0
  @ObservationIgnored private var readableTop = 0.0

  public init() {}

  func rowLaidOut(_ id: String, frame: CGRect) {
    frames[id] = frame
    if abs((measured[id] ?? -1) - frame.height) > 0.5 {
      measured[id] = frame.height
      measureRevision += 1
    }
    updateTop()
  }

  func rowGone(_ id: String) {
    frames[id] = nil
  }

  /// Where the part read now starts in the messages, and how tall it is.
  func scrolled(readableTop: Double, readableHeight: Double) {
    self.readableTop = readableTop
    if abs(self.readableHeight - readableHeight) > 0.5 { self.readableHeight = readableHeight }
    updateTop()
  }

  /// Where a block built now starts in the messages; `nil` for one that is not.
  func top(of id: String) -> Double? { frames[id].map { Double($0.minY) } }

  private func updateTop() {
    // The last row starting above the top of what is read; the first one built when all start
    // below it.
    var best: (id: String, frame: CGRect)?
    var first: (id: String, frame: CGRect)?
    for (id, frame) in frames {
      if frame.minY <= readableTop + 0.5, best.map({ frame.minY > $0.frame.minY }) ?? true {
        best = (id, frame)
      }
      if first.map({ frame.minY < $0.frame.minY }) ?? true { first = (id, frame) }
    }
    let found = (best ?? first).map {
      Top(blockID: $0.id, offset: max(readableTop - $0.frame.minY, 0))
    }
    if found != top { top = found }
  }
}

/// The whole conversation drawn small, beside it, in place of the scroll bar (#567): a click
/// goes there, a drag scrolls, a bookmark is a line of the accent that brings its message up.
struct ConversationOverview: View {
  let model: ConversationModel
  let theme: ConversationTheme
  let metrics: ConversationOverviewLayout.Metrics
  /// Hands the wheel's scrolls over to the messages.
  let pager: ConversationPager

  @State private var layout = ConversationOverviewLayout()
  @State private var dragGrab: Double?
  @State private var hovered: Hover?

  private struct Hover: Equatable {
    var bookmark: String?
    var y: Double
  }

  /// Left of the drawing, where the bookmarks' tags are.
  static let tagMargin = 12.0

  private struct LayoutKey: Equatable {
    var blocks: [ConversationBlock]
    var measureRevision: Int
    var metrics: ConversationOverviewLayout.Metrics
  }

  var body: some View {
    GeometryReader { geometry in
      let scale = layout.scale(forHeight: geometry.size.height)
      ZStack(alignment: .topLeading) {
        OverviewBlocks(layout: layout, scale: scale, colors: .init(theme))
          .equatable()
        OverviewViewport(
          model: model, tracker: model.overview, layout: layout, scale: scale,
          colors: .init(theme),
          isActive: dragGrab != nil || (hovered != nil && hovered?.bookmark == nil))
      }
      .contentShape(Rectangle())
      .gesture(drag(scale: scale))
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          let bookmark = bookmark(atY: point.y, scale: scale)
          let hover = Hover(bookmark: bookmark, y: point.y)
          if hover != hovered { hovered = hover }
        case .ended:
          hovered = nil
        }
      }
      // Left of the overview, level with the line.
      .overlay(alignment: .topLeading) {
        if let hovered, let id = hovered.bookmark {
          BookmarkPreview(model: model, blockID: id, theme: theme)
            .fixedSize()
            .alignmentGuide(.leading) { $0[.trailing] + 8 }
            .alignmentGuide(.top) { $0[VerticalAlignment.center] - hovered.y }
            .allowsHitTesting(false)
        }
      }
    }
    .background(WheelForwarder(pager: pager))
    .overlay(alignment: .leading) {
      Rectangle().fill(theme.border.color.opacity(0.6)).frame(width: 1)
    }
    .onChange(
      of: LayoutKey(
        blocks: model.blocks, measureRevision: model.overview.measureRevision, metrics: metrics),
      initial: true
    ) { _, key in
      layout = ConversationOverviewLayout(
        blocks: key.blocks, measured: model.overview.measured, metrics: key.metrics,
        reusing: layout)
    }
    .accessibilityHidden(true)
  }

  /// The bookmark whose line is within a few points of that height in the overview.
  private func bookmark(atY y: Double, scale: Double) -> String? {
    var nearest: (id: String, distance: Double)?
    for index in model.bookmarkedIndices where layout.items.indices.contains(index) {
      let distance = abs(Self.bookmarkY(layout.items[index], scale: scale) - y)
      if distance <= 5, nearest.map({ distance < $0.distance }) ?? true {
        nearest = (layout.items[index].id, distance)
      }
    }
    return nearest?.id
  }

  static func bookmarkY(_ item: ConversationOverviewLayout.Item, scale: Double) -> Double {
    item.top * scale + 1.5
  }

  private func drag(scale: Double) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if dragGrab == nil {
          if let id = bookmark(atY: value.startLocation.y, scale: scale) {
            // A bookmark clicked: nothing more until the button is released.
            dragGrab = .infinity
            model.revealBookmark(id)
            return
          }
          let thumb = OverviewViewport.thumb(
            tracker: model.overview, layout: layout, scale: scale)
          let y = value.startLocation.y
          // Held where it was taken; anywhere else, the frame centred on the click.
          dragGrab =
            thumb.map { y >= $0.top && y <= $0.top + $0.height ? y - $0.top : $0.height / 2 }
            ?? 0
        }
        guard let grab = dragGrab, grab.isFinite, scale > 0,
          let position = layout.position(atY: (value.location.y - grab) / scale)
        else { return }
        model.scrollOverview(to: layout.items[position.index].id, offset: position.offset)
      }
      .onEnded { _ in dragGrab = nil }
  }
}

/// The overview's colours, taken from the theme once.
struct OverviewColors: Equatable {
  var text: Color
  var bubble: Color
  var tool: Color
  var toolBorder: Color
  var failure: Color
  var accent: Color
  var viewport: Color
  var viewportActive: Color

  init(_ theme: ConversationTheme) {
    text = theme.text.color.opacity(0.4)
    bubble = theme.bubble.color
    tool = theme.raised.color
    toolBorder = theme.border.color
    failure = theme.failure.color
    accent = theme.accent.color
    viewport = theme.text.color.opacity(0.07)
    viewportActive = theme.text.color.opacity(0.13)
  }
}

/// The blocks, drawn again only when the layout changes: never while scrolling.
private struct OverviewBlocks: View, Equatable {
  let layout: ConversationOverviewLayout
  let scale: Double
  let colors: OverviewColors

  var body: some View {
    Canvas { context, size in
      let left = ConversationOverview.tagMargin
      let width = max(size.width - left - 6, 1)
      for item in layout.items {
        let top = item.top * scale
        guard top <= size.height else { break }
        let height = max(item.height * scale, 1)
        switch item.shape.mark {
        case .prompt:
          let longest = item.shape.lines.max() ?? 0.4
          let bubbleWidth = max(width * longest, width * 0.2)
          let rect = CGRect(x: left + width - bubbleWidth, y: top, width: bubbleWidth, height: height)
          context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(colors.bubble))
          drawLines(
            item.shape.lines, in: rect.insetBy(dx: 2, dy: min(2, height / 4)), context: context)
        case .text:
          drawLines(
            item.shape.lines, in: CGRect(x: left, y: top, width: width, height: height),
            context: context)
        case .tool, .failure:
          let rect = CGRect(x: left + 0.5, y: top + 0.5, width: width - 1, height: max(height - 1, 1))
          let path = Path(roundedRect: rect, cornerRadius: 1.5)
          context.fill(path, with: .color(colors.tool))
          context.stroke(
            path, with: .color(item.shape.mark == .failure ? colors.failure : colors.toolBorder),
            lineWidth: 1)
        case .quiet:
          context.fill(
            Path(CGRect(x: left, y: top, width: width * 0.3, height: min(height, 1.5))),
            with: .color(colors.text.opacity(0.5)))
        }
      }
    }
  }

  /// A line every point and a half at most: a long block drawn small reads as a mass anyway.
  private func drawLines(_ lines: [Double], in rect: CGRect, context: GraphicsContext) {
    guard !lines.isEmpty, rect.height > 0 else { return }
    let pitch = rect.height / Double(lines.count)
    let stride = max(Int((1.5 / pitch).rounded(.up)), 1)
    let thickness = max(min(pitch * Double(stride) * 0.55, 2.5), 0.8)
    var path = Path()
    for index in Swift.stride(from: 0, to: lines.count, by: stride) {
      let y = rect.minY + Double(index) * pitch
      path.addRect(CGRect(x: rect.minX, y: y, width: rect.width * lines[index], height: thickness))
    }
    context.fill(path, with: .color(colors.text))
  }
}

/// What is read now, framed, and the bookmarks: drawn again as the messages scroll.
private struct OverviewViewport: View {
  let model: ConversationModel
  let tracker: ConversationOverviewTracker
  let layout: ConversationOverviewLayout
  let scale: Double
  let colors: OverviewColors
  let isActive: Bool

  static func thumb(
    tracker: ConversationOverviewTracker, layout: ConversationOverviewLayout, scale: Double
  ) -> (top: Double, height: Double)? {
    guard let top = tracker.top, let index = layout.index(of: top.blockID) else { return nil }
    let y = layout.y(of: .init(index: index, offset: top.offset))
    return (y * scale, max(tracker.readableHeight * scale, 4))
  }

  var body: some View {
    let thumb = Self.thumb(tracker: tracker, layout: layout, scale: scale)
    let marked = model.bookmarkedIndices
    Canvas { context, size in
      if let thumb {
        context.fill(
          Path(CGRect(x: 0, y: thumb.top, width: size.width, height: thumb.height)),
          with: .color(isActive ? colors.viewportActive : colors.viewport))
      }
      let left = ConversationOverview.tagMargin
      for index in marked where layout.items.indices.contains(index) {
        let y = ConversationOverview.bookmarkY(layout.items[index], scale: scale)
        context.fill(
          Path(CGRect(x: left - 2, y: y - 0.75, width: size.width - left - 2, height: 1.5)),
          with: .color(colors.accent.opacity(0.6)))
        context.fill(BookmarkShape().path(in: CGRect(x: 2, y: y - 4, width: 9, height: 8)),
          with: .color(colors.accent))
      }
    }
  }
}

/// The start of a bookmarked message, beside the overview, while the pointer is on its line.
private struct BookmarkPreview: View {
  let model: ConversationModel
  let blockID: String
  let theme: ConversationTheme

  var body: some View {
    let block = model.blocks.first { $0.id == blockID }
    VStack(alignment: .leading, spacing: 2) {
      if let block, let heading = Self.heading(of: block, agent: model.agentName) {
        Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      }
      Text(block.map(ConversationModel.bookmarkLabel(of:)) ?? "")
        .font(.callout)
        .lineLimit(3)
        .frame(maxWidth: 260, alignment: .leading)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
  }

  private static func heading(of block: ConversationBlock, agent: String) -> String? {
    guard case .entry(let entry) = block else { return nil }
    let who: String
    switch entry.content {
    case .userPrompt: who = String(localized: "You", bundle: .module)
    case .agentText: who = agent
    default: return nil
    }
    guard let date = entry.date else { return who }
    return "\(who) · \(date.formatted(date: .omitted, time: .shortened))"
  }
}

/// A point of an IDE's breakpoint: what marks a message, in the margin and in the overview.
struct BookmarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    let tip = rect.height / 2
    let radius = min(rect.height * 0.2, 2)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - tip, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX - tip, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - radius),
      control: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY))
    path.closeSubpath()
    return path
  }
}

/// The bookmark of a message, in the margin left of it: pale while the pointer is on the message,
/// plain once set. A click sets it, another takes it away.
struct BookmarkGutter: View {
  let isMarked: Bool
  let isRowHovered: Bool
  /// The height of the message's first line, which it is centred on.
  let lineHeight: Double
  let toggle: () -> Void
  @Environment(\.conversationTheme) private var theme
  @State private var isHovered = false

  /// How far left of the message it reaches.
  static let reach = 30.0

  var body: some View {
    Button(action: toggle) {
      BookmarkShape()
        .fill(theme.accent.color.opacity(isMarked ? 1 : 0.35))
        .frame(width: 18, height: 11)
        .frame(width: Self.reach - 4, height: max(lineHeight, 14))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isMarked || isHovered ? 1 : isRowHovered ? 0.6 : 0)
    .onHover { isHovered = $0 }
    .help(
      isMarked
        ? Text("Remove the Bookmark", bundle: .module)
        : Text("Add a Bookmark", bundle: .module))
    .accessibilityLabel(
      isMarked
        ? Text("Remove the Bookmark", bundle: .module)
        : Text("Add a Bookmark", bundle: .module))
  }
}

/// The light a bookmark brings its message up with, fading out (#567).
struct BookmarkFlash: ViewModifier {
  let isLit: Bool
  @Environment(\.conversationTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(cornerRadius: 8)
        .fill(theme.accent.color.opacity(0.14))
        .padding(.horizontal, -10)
        .padding(.vertical, -6)
        .opacity(isLit ? 1 : 0)
        .animation(isLit || reduceMotion ? nil : .easeOut(duration: 1.2), value: isLit)
    }
  }
}

/// The wheel over the overview scrolls the messages.
private struct WheelForwarder: NSViewRepresentable {
  let pager: ConversationPager

  func makeNSView(context: Context) -> Forwarder {
    let view = Forwarder()
    view.pager = pager
    return view
  }

  func updateNSView(_ view: Forwarder, context: Context) {
    view.pager = pager
  }

  final class Forwarder: NSView {
    weak var pager: ConversationPager?

    override func scrollWheel(with event: NSEvent) {
      if let scrollView = pager?.scrollView {
        scrollView.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }
    }
  }
}
