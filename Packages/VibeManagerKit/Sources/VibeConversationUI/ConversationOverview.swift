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

  /// Where a block starts in the messages: where its row is, if it is built; else as far from
  /// the row built nearest it as the overview lays them apart, within `reach` — rows the list has
  /// not built yet are given heights of its own, which nothing tells, so a block further away is
  /// left to it. A drag upwards, where the block is the one just above what is built, lands there
  /// rather than at the block's start and then back in it at the next move (#567).
  func documentTop(of index: Int, in layout: ConversationOverviewLayout, reach: Double) -> Double? {
    guard layout.ids.indices.contains(index) else { return nil }
    if let frame = frames[layout.ids[index]] { return Double(frame.minY) }
    var nearest: (distance: Double, top: Double)?
    for (id, frame) in frames {
      guard let built = layout.index(of: id) else { continue }
      let distance = layout.tops[index] - layout.tops[built]
      if abs(distance) <= reach, nearest.map({ abs(distance) < abs($0.distance) }) ?? true {
        nearest = (distance, Double(frame.minY) + distance)
      }
    }
    return nearest?.top
  }

  /// Whether a block built now shows in what is read.
  func isRead(_ id: String) -> Bool {
    guard let frame = frames[id] else { return false }
    return frame.maxY > readableTop && frame.minY < readableTop + readableHeight
  }

  /// A unit's first line, rather than any part of its possibly very long message.
  func isRead(_ id: String, offset: Double) -> Bool {
    guard let frame = frames[id] else { return false }
    let y = Double(frame.minY) + offset
    return y >= readableTop - ConversationBookmarks.startTolerance
      && y < readableTop + readableHeight
  }

  /// Forgets the heights measured at another width or text size: estimated again until their
  /// rows are built anew. Those built now are measured as they are.
  func forgetMeasures() {
    measured = frames.mapValues { Double($0.height) }
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
  /// The layout of the blocks it was made from (`ConversationModel.blocksRevision`).
  let blocksRevision: Int

  init(
    _ layout: ConversationOverviewLayout = ConversationOverviewLayout(), blocksRevision: Int = -1
  ) {
    self.layout = layout
    self.blocksRevision = blocksRevision
  }
}

/// The whole conversation drawn small, beside it, in place of the scroll bar (#567): a click
/// goes there, a drag scrolls, a bookmark is a line of the accent that brings its message up. Its
/// key moments are icons in its left margin (#572): the pointer on one tells what happened, a
/// click brings it up.
struct ConversationOverview: View {
  let model: ConversationModel
  let theme: ConversationTheme
  let metrics: ConversationOverviewLayout.Metrics
  /// Hands the wheel's scrolls over to the messages.
  let pager: ConversationPager
  /// The width of the messages left of the overview, which a bookmark's preview lies over.
  let room: Double
  @Environment(\.conversationAppearance) private var appearance

  @State private var box = OverviewLayoutBox()
  @State private var frameDrag = OverviewDrag()
  /// Reset by SwiftUI when the drag is let go, and when it is cancelled, which `onEnded` is not
  /// told of.
  @GestureState private var isPressed = false
  @State private var hovered: Hover?

  private var layout: ConversationOverviewLayout { box.layout }

  /// What the pointer is on: the first moment of an icon, or the rest of the overview. Its icon —
  /// the moments drawn with it, and where — is found again in each layout, not kept: icons move
  /// as rows are measured and as the scale changes, the pointer standing still.
  private struct Hover: Equatable {
    var moment: ConversationMoment?
  }

  /// Left of the drawing, where the moments' icons are.
  static let tagMargin = 18.0
  /// The height of a moment's icon.
  static let iconSize = 11.0

  private struct LayoutKey: Equatable {
    var blocksRevision: Int
    var measureRevision: Int
    var metrics: ConversationOverviewLayout.Metrics
  }

  var body: some View {
    GeometryReader { geometry in
      let scale = layout.scale(forHeight: geometry.size.height)
      ZStack(alignment: .topLeading) {
        OverviewBlocks(
          box: box, scale: scale, colors: .init(theme),
          moments: OverviewMoments(model.shownMoments, revision: model.momentsRevision)
        )
        .equatable()
        OverviewViewport(
          tracker: model.overview, box: box, scale: scale, colors: .init(theme),
          isActive: frameDrag.isDragging || (hovered != nil && hovered?.moment == nil))
      }
      .contentShape(Rectangle())
      .gesture(drag(scale: scale))
      // The click that brings the window forward goes there too, as on a scroll bar: else it
      // only activated the window, and a bookmark took a second click (#596).
      .modifier(TakesActivatingClick())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          let cluster = Self.cluster(
            near: point, moments: model.shownMoments, layout: layout, scale: scale)
          let hover = Hover(
            moment: cluster.map { model.shownMoments[$0.moments.lowerBound].moment })
          if hover != hovered { hovered = hover }
          // A moment is a link: the hand over the whole square of its icon, or its line.
          (cluster == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        case .ended:
          hovered = nil
          NSCursor.arrow.set()
        }
      }
      // Left of the overview, level with the icon, over the messages.
      .overlay {
        if let moment = hovered?.moment,
          let cluster = Self.cluster(
            starting: moment, moments: model.shownMoments, layout: layout, scale: scale)
        {
          BookmarkPreviewPlacement(
            lineY: cluster.y,
            width: ConversationOverviewLayout.previewWidth(
              textSize: MomentPreviewStyle(theme: theme, appearance: appearance).textSize,
              room: room)
          ) {
            MomentPreview(
              content: MomentPreviewContent(
                placed: model.shownMoments[cluster.moments], model: model),
              theme: theme)
          }
          .allowsHitTesting(false)
        }
      }
    }
    .background(WheelForwarder(pager: pager))
    // A moment gone under the pointer — a bookmark taken away — is no longer hovered.
    .onChange(of: model.momentsRevision) {
      guard let moment = hovered?.moment,
        !model.shownMoments.contains(where: { $0.moment == moment })
      else { return }
      hovered = Hover(moment: nil)
    }
    .overlay(alignment: .leading) {
      Rectangle().fill(theme.border.color.opacity(0.6)).frame(width: 1)
    }
    .onChange(
      of: LayoutKey(
        blocksRevision: model.blocksRevision, measureRevision: model.overview.measureRevision,
        metrics: metrics),
      initial: true
    ) { _, key in
      let changedFrom = model.takeBlocksChangedFrom()
      let tracker = model.overview
      let layout: ConversationOverviewLayout
      if key.metrics != self.layout.metrics {
        // Heights measured at another width or text size no longer hold.
        if self.layout.metrics != nil {
          tracker.forgetMeasures()
          model.forgetBookmarkPositions()
        }
        layout = ConversationOverviewLayout(
          blocks: model.blocks, measured: tracker.measured, metrics: key.metrics,
          shapes: tracker.shapes)
      } else if key.blocksRevision != box.blocksRevision {
        // Only what changed, at the end of a conversation that grows.
        layout = self.layout.replacing(
          from: changedFrom ?? 0, blocks: model.blocks, measured: tracker.measured,
          shapes: tracker.shapes)
      } else if frameDrag.holdMeasures() {
        // Held while the frame is dragged: laid out again once the drag ends.
        return
      } else {
        layout = self.layout.remeasured(tracker.measured)
      }
      box = OverviewLayoutBox(layout, blocksRevision: key.blocksRevision)
    }
    .onChange(of: isPressed) { _, pressed in
      if !pressed { endDrag() }
    }
    .onDisappear { endDrag() }
    .accessibilityHidden(true)
  }

  /// The moments drawn as one icon, among `moments`, and where their icon is: the first one's
  /// block, never above the overview's top.
  static func clusters(
    of moments: [ConversationMoments.Placed], layout: ConversationOverviewLayout, scale: Double
  ) -> [(moments: Range<Int>, y: Double)] {
    // In order: those of blocks the layout does not have yet are the last.
    let placed = moments.prefix { $0.blockIndex < layout.count }
    let tops = placed.map { momentTop($0, layout: layout) }
    return ConversationOverviewLayout.clusters(tops, scale: scale).map {
      ($0, iconY(top: tops[$0.lowerBound], scale: scale))
    }
  }

  /// The icon a moment was hovered in, as the overview is laid out now: the moments drawn with
  /// it, and where. `nil` once the moment is gone. Laid out again, it may be drawn with others.
  static func cluster(
    starting moment: ConversationMoment, moments: [ConversationMoments.Placed],
    layout: ConversationOverviewLayout, scale: Double
  ) -> (moments: Range<Int>, y: Double)? {
    clusters(of: moments, layout: layout, scale: scale).first { cluster in
      moments[cluster.moments].contains { $0.moment == moment }
    }
  }

  /// The moments under the pointer: an icon within a few points of it, or the line of a bookmark
  /// across the overview. `touched` is the moment a click brings up: the one the icon shows, or
  /// the bookmark whose line it is.
  static func cluster(
    near point: CGPoint, moments: [ConversationMoments.Placed],
    layout: ConversationOverviewLayout, scale: Double
  ) -> (moments: Range<Int>, y: Double, touched: Int)? {
    var nearest: (moments: Range<Int>, y: Double, touched: Int, distance: Double)?
    for cluster in clusters(of: moments, layout: layout, scale: scale) {
      let iconDistance = abs(cluster.y - point.y)
      // The whole square of the icon, its hollows included, not only its strokes.
      let onIcon = iconSquare(y: cluster.y).contains(point)
      // Each bookmark's line is drawn at its own block, the first of its cluster or not.
      func lineDistance(_ index: Int) -> Double {
        abs(iconY(top: momentTop(moments[index], layout: layout), scale: scale) - point.y)
      }
      let line = cluster.moments
        .filter { moments[$0].moment.kind == .bookmark }
        .map { (index: $0, distance: lineDistance($0)) }
        .min { $0.distance < $1.distance }
      let onLine = line.map { $0.distance <= 5 } ?? false
      let distance = onIcon ? iconDistance : line?.distance ?? iconDistance
      if onIcon || onLine, nearest.map({ distance < $0.distance }) ?? true {
        let icon = ConversationMoments.iconIndex(in: moments, group: cluster.moments)
        let touched = onIcon ? icon : line?.index ?? icon
        nearest = (cluster.moments, cluster.y, touched, distance)
      }
    }
    return nearest.map { ($0.moments, $0.y, $0.touched) }
  }

  /// The block a click at `point` brings up: that of the moment touched. Named by the model's
  /// blocks, which the moments are of: the layout may not have caught up with them yet.
  static func blockID(
    clickedAt point: CGPoint, model: ConversationModel, layout: ConversationOverviewLayout,
    scale: Double
  ) -> String? {
    guard
      let cluster = cluster(
        near: point, moments: model.shownMoments, layout: layout, scale: scale)
    else { return nil }
    let index = model.shownMoments[cluster.touched].blockIndex
    return model.blocks.indices.contains(index) ? model.blocks[index].id : nil
  }

  /// What answers the pointer for an icon centred at `y`: the margin's width, as tall.
  static func iconSquare(y: Double) -> CGRect {
    CGRect(x: 0, y: y - tagMargin / 2, width: tagMargin, height: tagMargin)
  }

  static func momentTop(_ placed: ConversationMoments.Placed, layout: ConversationOverviewLayout)
    -> Double
  {
    layout.tops[placed.blockIndex] + placed.unitOffset + placed.unitFraction
      * layout.heights[placed.blockIndex]
  }

  /// Where a moment's icon is centred, and a bookmark's line: at the top of its block.
  static func iconY(top: Double, scale: Double) -> Double {
    max(top * scale + 1.5, iconSize / 2)
  }

  /// The drag let go or cancelled: the frame unlit, the heights it held laid out.
  private func endDrag() {
    guard frameDrag.end() else { return }
    box = OverviewLayoutBox(
      layout.remeasured(model.overview.measured), blocksRevision: box.blocksRevision)
  }

  private func drag(scale: Double) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($isPressed) { _, pressed, _ in pressed = true }
      .onChanged { value in
        if frameDrag.grab == nil {
          if let blockID = Self.blockID(
            clickedAt: value.startLocation, model: model, layout: layout, scale: scale)
          {
            // A moment clicked: nothing more until the button is released.
            frameDrag.grab = .infinity
            if let touched = Self.cluster(
              near: value.startLocation, moments: model.shownMoments, layout: layout, scale: scale)?
              .touched
            {
              let moment = model.shownMoments[touched].moment
              model.revealMoment(blockID, unit: moment.unit, bookmark: moment.kind == .bookmark)
            }
            return
          }
          let thumb = OverviewViewport.thumb(
            tracker: model.overview, layout: layout, scale: scale)
          let y = value.startLocation.y
          // Held where it was taken; anywhere else, the frame centred on the click.
          frameDrag.grab =
            thumb.map { y >= $0.top && y <= $0.top + $0.height ? y - $0.top : $0.height / 2 }
            ?? 0
        }
        guard let grab = frameDrag.grab, grab.isFinite, scale > 0,
          let position = layout.position(atY: (value.location.y - grab) / scale)
        else { return }
        let tracker = model.overview
        model.scrollOverview(
          to: layout.ids[position.index], offset: position.offset,
          top: tracker.documentTop(
            of: position.index, in: layout, reach: tracker.readableHeight * 2))
      }
      .onEnded { _ in endDrag() }
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
  /// What a moment's count is written in.
  var count: Color
  var moments: [ConversationMomentKind: Color]

  init(_ theme: ConversationTheme) {
    text = theme.text.color.opacity(0.4)
    bubble = theme.bubble.color
    tool = theme.raised.color
    toolBorder = theme.border.color
    failure = theme.failure.color
    accent = theme.accent.color
    viewport = theme.text.color.opacity(0.14)
    viewportActive = theme.text.color.opacity(0.22)
    count = theme.secondaryText.color
    moments = Dictionary(
      uniqueKeysWithValues: ConversationMomentKind.allCases.map {
        ($0, MomentPresentation.color(of: $0, theme: theme))
      })
  }
}

/// The moments shown, compared by their revision: hundreds of them are never compared to tell
/// whether the drawing changed.
struct OverviewMoments: Equatable {
  let placed: [ConversationMoments.Placed]
  let revision: Int

  init(_ placed: [ConversationMoments.Placed], revision: Int) {
    self.placed = placed
    self.revision = revision
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision }
}

/// The blocks and their moments, drawn again only when the layout, the moments or the filters
/// change: never while scrolling.
///
/// Thousands of blocks share a few points: one shape of each kind is drawn per half point, and
/// each kind is filled at once.
private struct OverviewBlocks: View, Equatable {
  let box: OverviewLayoutBox
  let scale: Double
  let colors: OverviewColors
  let moments: OverviewMoments

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.box === rhs.box && lhs.scale == rhs.scale && lhs.colors == rhs.colors
      && lhs.moments == rhs.moments
  }

  /// The icons the moments are drawn with, one of each symbol and colour.
  private var symbols: [(tag: String, symbol: String, color: Color)] {
    var seen: Set<String> = []
    var symbols: [(tag: String, symbol: String, color: Color)] = []
    for placed in moments.placed {
      let tag = Self.tag(of: placed.moment)
      guard seen.insert(tag).inserted else { continue }
      let color =
        placed.moment.isFailure ? colors.failure : colors.moments[placed.moment.kind] ?? .gray
      symbols.append((tag, MomentPresentation.symbol(of: placed.moment), color))
    }
    return symbols
  }

  private static func tag(of moment: ConversationMoment) -> String {
    "\(moment.kind.rawValue)|\(MomentPresentation.symbol(of: moment))"
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
      defer { drawMoments(in: &context, size: size) }
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
    } symbols: {
      ForEach(symbols, id: \.tag) { icon in
        MomentIcon(symbol: icon.symbol, color: icon.color, size: ConversationOverview.iconSize)
          .tag(icon.tag)
      }
    }
  }

  /// The moments in the margin left of the drawing, those close together as the first one's icon
  /// and their count; a bookmark's line across the drawing too.
  private func drawMoments(in context: inout GraphicsContext, size: CGSize) {
    let layout = box.layout
    let left = ConversationOverview.tagMargin
    for placed in moments.placed
    where placed.moment.kind == .bookmark && placed.blockIndex < layout.count {
      let y = ConversationOverview.iconY(
        top: ConversationOverview.momentTop(placed, layout: layout), scale: scale)
      context.fill(
        Path(CGRect(x: left - 2, y: y - 0.75, width: size.width - left - 2, height: 1.5)),
        with: .color(colors.accent.opacity(0.6)))
    }
    let clusters = ConversationOverview.clusters(of: moments.placed, layout: layout, scale: scale)
    for cluster in clusters where cluster.y <= size.height + ConversationOverview.iconSize {
      let shown = moments.placed[
        ConversationMoments.iconIndex(in: moments.placed, group: cluster.moments)
      ].moment
      guard let icon = context.resolveSymbol(id: Self.tag(of: shown)) else { continue }
      context.draw(icon, at: CGPoint(x: left / 2, y: cluster.y))
      guard cluster.moments.count > 1 else { continue }
      context.draw(
        Text(verbatim: "\(cluster.moments.count)")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(colors.count),
        at: CGPoint(x: left - 1, y: cluster.y - 5), anchor: .center)
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

/// What is read now, framed: drawn again as the messages scroll.
private struct OverviewViewport: View {
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
    Canvas { context, size in
      if let thumb {
        context.fill(
          Path(CGRect(x: 0, y: thumb.top, width: size.width, height: thumb.height)),
          with: .color(isActive ? colors.viewportActive : colors.viewport))
      }
    }
  }
}

/// Lays a bookmark's preview where `ConversationOverviewLayout.previewOrigin` puts it, from the
/// size it takes at `width` at most (#567). The overlay's alignment guides were not followed —
/// the preview stayed in the overview's top corner, cut by the pane —, and an offset from a size
/// measured afterwards lagged a frame behind.
private struct BookmarkPreviewPlacement: Layout {
  let lineY: Double
  let width: Double

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      let origin = ConversationOverviewLayout.previewOrigin(
        lineY: lineY, previewWidth: size.width, previewHeight: size.height,
        overviewHeight: bounds.height)
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: ProposedViewSize(size))
    }
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

/// Which paragraph the pointer entered from the margin, even after its bookmark is removed.
struct BookmarkGutterHover: Equatable {
  var unit = 0
  private var hoveredTag: Int?

  var isHovered: Bool { hoveredTag != nil }

  mutating func moved(_ hovered: Bool, on unit: Int) {
    if hovered {
      self.unit = unit
      hoveredTag = unit
    } else if hoveredTag == unit {
      hoveredTag = nil
    }
  }

  func canReleaseLayout(bodyHovered: Bool, isMarked: Bool) -> Bool {
    !bodyHovered && !isHovered && !isMarked
  }
}

/// The tag views kept in the margin. A whole-block tag must survive the gap between the
/// body's hover ending and the tag's own hover beginning; it has no paragraph tracker.
struct BookmarkGutterUnits<Content: View>: View {
  let marked: [Int]
  let hoveredUnit: Int
  let showsHoveredUnit: Bool
  let keepsWholeBlockTag: Bool
  @ViewBuilder var content: (Int) -> Content

  var body: some View {
    let units = Set(marked + ((keepsWholeBlockTag || showsHoveredUnit) ? [hoveredUnit] : []))
    ForEach(units.sorted(), id: \.self, content: content)
  }
}

/// The bookmark of a message, in the margin left of it: pale while the pointer is on the message,
/// plain once set. A click sets it, another takes it away. The pointer on one set shows the
/// overview's preview of it (#608); on one not set, what a click does.
struct BookmarkGutter: View {
  let blockID: String
  let preview: ConversationMarginPreview
  let isMarked: Bool
  let isRowHovered: Bool
  /// The height of the message's first line, which it is centred on.
  let lineHeight: Double
  let toggle: () -> Void
  var unit: Int = 0
  var excerpt = ""
  var hovered: (Bool) -> Void = { _ in }
  @Environment(\.conversationTheme) private var theme
  @State private var isHovered = false

  /// How far left of the message it reaches.
  static let reach = 30.0
  /// The height of its tag, which a moment's icon beside it takes too (#572).
  static let tagHeight = 11.0

  /// The box it is centred in: the message's first line, never less than a click needs.
  static func boxHeight(lineHeight: Double) -> Double { max(lineHeight, 14) }

  // A shape that takes the click rather than a button: built for every message, hidden until
  // the pointer comes, a button cost as much as the rest of a short message to build, which a
  // drag in the overview of a long conversation does for several messages at every frame (#567).
  // VoiceOver still finds a button, named as it was, that it can press.
  var body: some View {
    let label =
      isMarked
      ? Text("Remove the Bookmark", bundle: .module) : Text("Add a Bookmark", bundle: .module)
    BookmarkShape()
      .fill(theme.accent.color.opacity(isMarked ? 1 : 0.35))
      .frame(width: 18, height: Self.tagHeight)
      .frame(width: Self.reach - 4, height: Self.boxHeight(lineHeight: lineHeight))
      .contentShape(Rectangle())
      .onTapGesture(perform: toggle)
      .pointingHand()
      .opacity(isMarked || isHovered ? 1 : isRowHovered ? 0.6 : 0)
      // Set, its preview tells it; a tooltip would come over it. Shown on the pointer the
      // preview's tracking follows: no second one for every message.
      .instantTooltip(isMarked ? nil : label, isHovered: isHovered)
      // One tracking of the pointer, for its look and its preview.
      .modifier(
        MarginPreviewSource(
          preview: preview, blockID: blockID,
          target: unit == 0 ? .bookmark : .paragraphBookmark(unit), isEnabled: isMarked,
          hovered: {
            isHovered = $0
            hovered($0)
          })
      )
      .accessibilityElement()
      .accessibilityLabel(label)
      .accessibilityValue(Text(verbatim: excerpt))
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { toggle() }
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

/// A view whose gestures take the click that activates its window too (macOS 15 on).
struct TakesActivatingClick: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.allowsWindowActivationEvents(true)
    } else {
      content
    }
  }
}

/// The overview dimmed at rest, plain under the pointer (#596): only the opacity of its container
/// changes — nothing is laid out nor drawn again, the rows and the moments neither. Not flattened
/// into a group: a bookmark's preview, over the messages, would blur that group, not them.
struct OverviewBandFade: ViewModifier {
  static let restingOpacity = 0.55
  static let fadeDuration = 0.18
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  /// Increase Contrast: never dimmed, its faint accents would fade out of sight.
  static func opacity(isHovered: Bool, contrast: ColorSchemeContrast) -> Double {
    isHovered || contrast == .increased ? 1 : restingOpacity
  }

  func body(content: Content) -> some View {
    content
      // Scoped to the opacity: a bookmark's preview, or the viewport's highlight, changing on the
      // same hover, comes and goes at once, not in this fade. Reduce Motion: at once.
      .animation(reduceMotion ? nil : .easeInOut(duration: Self.fadeDuration)) {
        $0.opacity(Self.opacity(isHovered: isHovered, contrast: contrast))
      }
      .onHover { isHovered = $0 }
  }
}
