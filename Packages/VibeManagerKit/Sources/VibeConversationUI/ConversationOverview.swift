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
  /// Bumped when heights measured changed, at most every `measureDelay`: the overview lays out
  /// again then, rather than for each row a scroll builds.
  public private(set) var measureRevision = 0
  @ObservationIgnored private var measurePending = false
  static let measureDelay = Duration.milliseconds(150)
  /// What each block looks like drawn small, read once for the conversation.
  @ObservationIgnored public let shapes = ConversationOverviewShapes()
  public private(set) var top: Top?
  /// The height of what is read, between the toolbar and the foot.
  public private(set) var readableHeight = 0.0
  @ObservationIgnored private var readableTop = 0.0

  public init() {}

  func rowLaidOut(_ id: String, frame: CGRect) {
    frames[id] = frame
    if abs((measured[id] ?? -1) - frame.height) > 0.5 {
      measured[id] = frame.height
      scheduleMeasureRevision()
    }
    updateTop()
  }

  private func scheduleMeasureRevision() {
    guard !measurePending else { return }
    measurePending = true
    Task { [weak self] in
      try? await Task.sleep(for: Self.measureDelay)
      guard let self else { return }
      self.measurePending = false
      self.measureRevision += 1
    }
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

/// A layout, compared by identity: a new one is a new box. Thousands of blocks are never compared
/// to tell whether the drawing changed.
final class OverviewLayoutBox {
  let layout: ConversationOverviewLayout
  /// The blocks it was laid out from: the same ones measured anew only add heights up again.
  let blocks: [ConversationBlock]

  init(_ layout: ConversationOverviewLayout = ConversationOverviewLayout(), blocks: [ConversationBlock] = []) {
    self.layout = layout
    self.blocks = blocks
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

  @State private var box = OverviewLayoutBox()
  @State private var dragGrab: Double?
  @State private var hovered: Hover?
  @State private var previewSize = CGSize(width: 260, height: 44)

  private var layout: ConversationOverviewLayout { box.layout }

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
        OverviewBlocks(box: box, scale: scale, colors: .init(theme))
          .equatable()
        OverviewViewport(
          model: model, tracker: model.overview, box: box, scale: scale,
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
      // Left of the overview, level with the line, over the messages.
      .overlay(alignment: .topLeading) {
        if let hovered, let id = hovered.bookmark {
          BookmarkPreview(model: model, blockID: id, theme: theme)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
            .offset(x: -previewSize.width - 8, y: hovered.y - previewSize.height / 2)
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
      let measured = model.overview.measured
      if key.metrics == layout.metrics, key.blocks == box.blocks {
        box = OverviewLayoutBox(layout.remeasured(measured), blocks: key.blocks)
      } else {
        box = OverviewLayoutBox(
          ConversationOverviewLayout(
            blocks: key.blocks, measured: measured, metrics: key.metrics,
            shapes: model.overview.shapes),
          blocks: key.blocks)
      }
    }
    .accessibilityHidden(true)
  }

  /// The bookmark whose line is within a few points of that height in the overview.
  private func bookmark(atY y: Double, scale: Double) -> String? {
    var nearest: (id: String, distance: Double)?
    for index in model.bookmarkedIndices where index < layout.count {
      let distance = abs(Self.bookmarkY(top: layout.tops[index], scale: scale) - y)
      if distance <= 5, nearest.map({ distance < $0.distance }) ?? true {
        nearest = (layout.ids[index], distance)
      }
    }
    return nearest?.id
  }

  static func bookmarkY(top: Double, scale: Double) -> Double {
    top * scale + 1.5
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
        model.scrollOverview(to: layout.ids[position.index], offset: position.offset)
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
///
/// Thousands of blocks share a few points: one shape of each kind is drawn per half point, and
/// each kind is filled at once.
private struct OverviewBlocks: View, Equatable {
  let box: OverviewLayoutBox
  let scale: Double
  let colors: OverviewColors

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.box === rhs.box && lhs.scale == rhs.scale && lhs.colors == rhs.colors
  }

  private static func kind(_ mark: ConversationOverviewLayout.Mark) -> Int {
    switch mark {
    case .prompt: 0
    case .text: 1
    case .tool: 2
    case .failure: 3
    case .quiet: 4
    }
  }

  var body: some View {
    Canvas { context, size in
      let layout = box.layout
      guard let metrics = layout.metrics else { return }
      let left = ConversationOverview.tagMargin
      let width = max(size.width - left - 6, 1)
      var text = Path()
      var bubbles = Path()
      var tools = Path()
      var failures = Path()
      var quiet = Path()
      var lastRow = [Int](repeating: .min, count: 5)
      for index in 0..<layout.count {
        let shape = layout.shapes[index]
        let top = layout.tops[index] * scale
        guard top <= size.height else { break }
        let height = max(layout.heights[index] * scale, 1)
        let kind = Self.kind(shape.mark)
        let row = Int(top * 2)
        // Under a point, a block of the same kind already drawn there stands for it.
        guard height >= 2 || row != lastRow[kind] else { continue }
        lastRow[kind] = row
        switch shape.mark {
        case .prompt:
          let longest = shape.lineLengths.max() ?? 0
          let fraction = min(Double(longest) / Double(metrics.charactersPerBubbleLine), 1)
          let bubbleWidth = max(width * 0.8 * fraction, width * 0.2)
          let rect = CGRect(
            x: left + width - bubbleWidth, y: top, width: bubbleWidth, height: height)
          bubbles.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
          if height >= 4 {
            addLines(
              shape, width: metrics.charactersPerBubbleLine,
              in: rect.insetBy(dx: 2, dy: min(2, height / 4)), to: &text)
          }
        case .text:
          addLines(
            shape, width: metrics.charactersPerLine,
            in: CGRect(x: left, y: top, width: width, height: height), to: &text)
        case .tool, .failure:
          let rect = CGRect(x: left, y: top, width: width, height: height)
          if height >= 6 {
            let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5)
            context.fill(path, with: .color(colors.tool))
            context.stroke(
              path, with: .color(shape.mark == .failure ? colors.failure : colors.toolBorder),
              lineWidth: 1)
          } else if shape.mark == .failure {
            failures.addRect(rect)
          } else {
            tools.addRect(rect)
          }
        case .quiet:
          quiet.addRect(CGRect(x: left, y: top, width: width * 0.3, height: min(height, 1.5)))
        }
      }
      context.fill(bubbles, with: .color(colors.bubble))
      context.fill(tools, with: .color(colors.toolBorder))
      context.fill(text, with: .color(colors.text))
      context.fill(quiet, with: .color(colors.text.opacity(0.5)))
      context.fill(failures, with: .color(colors.failure))
    }
  }

  /// The lines of a text at `width` characters, one every point and a half at most: a long block
  /// drawn small reads as a mass anyway.
  private func addLines(
    _ shape: ConversationOverviewLayout.Shape, width: Int, in rect: CGRect, to path: inout Path
  ) {
    let total = shape.lineCount(width: width)
    guard total > 0, rect.height > 0 else { return }
    let pitch = rect.height / Double(total)
    let stride = max(Int((1.5 / pitch).rounded(.up)), 1)
    let thickness = max(min(pitch * Double(stride) * 0.55, 2.5), 0.8)
    var visual = 0
    for length in shape.lineLengths {
      let count = max((length + width - 1) / width, 1)
      // The first of its lines drawn, then every `stride` lines.
      var line = (stride - visual % stride) % stride
      while line < count {
        let isLast = line == count - 1
        let fraction = isLast ? Double(length - (count - 1) * width) / Double(width) : 1
        path.addRect(
          CGRect(
            x: rect.minX, y: rect.minY + Double(visual + line) * pitch,
            width: rect.width * max(min(fraction, 1), 0.05), height: thickness))
        line += stride
      }
      visual += count
    }
  }
}

/// What is read now, framed, and the bookmarks: drawn again as the messages scroll.
private struct OverviewViewport: View {
  let model: ConversationModel
  let tracker: ConversationOverviewTracker
  let box: OverviewLayoutBox
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
    let layout = box.layout
    let thumb = Self.thumb(tracker: tracker, layout: layout, scale: scale)
    let marked = model.bookmarkedIndices
    Canvas { context, size in
      if let thumb {
        context.fill(
          Path(CGRect(x: 0, y: thumb.top, width: size.width, height: thumb.height)),
          with: .color(isActive ? colors.viewportActive : colors.viewport))
      }
      let left = ConversationOverview.tagMargin
      for index in marked where index < layout.count {
        let y = ConversationOverview.bookmarkY(top: layout.tops[index], scale: scale)
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
