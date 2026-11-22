import Foundation

/// The whole conversation drawn small beside it, which scrolls it too (#567).
///
/// Laid out from the blocks rather than from their views: the list builds only the rows on screen,
/// so a block never shown is given the height its content suggests — lines of text at the width
/// of the column, a tool folded on its title — and the height measured once its row has been
/// built. Each block is placed under the one before, the whole conversation fitting the height of
/// the overview.
///
/// A session can hold tens of thousands of blocks: what a block looks like is read once, whatever
/// the width (`ConversationOverviewShapes`), and a layout only adds heights up.
public struct ConversationOverviewLayout: Equatable, Sendable {
  /// What the estimates are made with: the column and the text as the conversation shows them.
  public struct Metrics: Hashable, Sendable {
    public var columnWidth: Double
    public var textSize: Double
    /// A multiple of the text size, as the theme gives it.
    public var lineHeight: Double
    public var blockSpacing: Double
    public var paragraphSpacing: Double

    public init(
      columnWidth: Double, textSize: Double, lineHeight: Double, blockSpacing: Double,
      paragraphSpacing: Double
    ) {
      self.columnWidth = columnWidth
      self.textSize = textSize
      self.lineHeight = lineHeight
      self.blockSpacing = blockSpacing
      self.paragraphSpacing = paragraphSpacing
    }

    /// The height of a line of text.
    public var linePitch: Double { textSize * lineHeight }

    /// About as many characters as a line of the column holds: half the text size each.
    public var charactersPerLine: Int { max(16, Int(columnWidth / (textSize * 0.5))) }

    /// A bubble leaves room on its leading side.
    public var charactersPerBubbleLine: Int { max(12, charactersPerLine * 4 / 5) }
  }

  /// How a block is drawn.
  public enum Mark: Hashable, Sendable {
    /// What the user wrote: a bubble.
    case prompt
    /// What the agent answered: lines of text.
    case text
    /// Tools, folded on their title: a frame.
    case tool
    /// Tools of which one failed: a frame of the failure's colour.
    case failure
    /// Reasoning folded, a notice: a short line.
    case quiet
  }

  /// What a block looks like, whatever the width it is shown at.
  public struct Shape: Hashable, Sendable {
    public var mark: Mark
    /// The length of each line of its text that is not blank, in characters, top to bottom: the
    /// first `maximumLines` of them.
    public var lineLengths: [Int]
    /// Lines past `maximumLines`, counted one each.
    public var moreLines: Int
    public var paragraphs: Int
    /// For tools: how many rows they take folded.
    public var rows: Int

    public init(
      mark: Mark, lineLengths: [Int] = [], moreLines: Int = 0, paragraphs: Int = 1, rows: Int = 1
    ) {
      self.mark = mark
      self.lineLengths = lineLengths
      self.moreLines = moreLines
      self.paragraphs = paragraphs
      self.rows = rows
    }

    /// How many lines its text makes `width` characters wide.
    public func lineCount(width: Int) -> Int {
      let width = max(width, 1)
      return lineLengths.reduce(moreLines) { $0 + max(($1 + width - 1) / width, 1) }
    }
  }

  /// A block placed in the conversation.
  public struct Item: Hashable, Sendable {
    public var id: String
    public var shape: Shape
    /// Where it starts and how tall it is, in the conversation's points.
    public var top: Double
    public var height: Double
  }

  /// A place in the conversation: a block, and how far into it.
  public struct Position: Hashable, Sendable {
    public var index: Int
    public var offset: Double

    public init(index: Int, offset: Double) {
      self.index = index
      self.offset = offset
    }
  }

  /// The blocks, their shapes, the height each is given until measured, then where each is and
  /// how tall: kept apart, so that new heights only add numbers up again.
  public private(set) var ids: [String] = []
  public private(set) var shapes: [Shape] = []
  private var estimates: [Double] = []
  public private(set) var tops: [Double] = []
  public private(set) var heights: [Double] = []
  /// The conversation's height, in its points.
  public private(set) var height = 0.0
  public private(set) var metrics: Metrics?
  private var indices: [String: Int] = [:]

  /// No line is kept beyond that many in a block: drawn small, a long file reads as a mass.
  public static let maximumLines = 2000

  public init() {}

  /// Lays the blocks out, with the shapes `shapes` keeps for them.
  ///
  /// - Parameter measured: the height of the rows already built, by block.
  @MainActor
  public init(
    blocks: [ConversationBlock], measured: [String: Double], metrics: Metrics,
    shapes: ConversationOverviewShapes
  ) {
    self.init(
      blocks: blocks, shapes: blocks.map(shapes.shape(of:)), measured: measured, metrics: metrics)
  }

  /// Lays the blocks out with their shapes, read already.
  public init(
    blocks: [ConversationBlock], shapes: [Shape], measured: [String: Double], metrics: Metrics
  ) {
    self.metrics = metrics
    self.shapes = shapes
    ids = blocks.map(\.id)
    estimates = shapes.map { Self.estimatedHeight(of: $0, metrics: metrics) }
    indices.reserveCapacity(ids.count)
    for (index, id) in ids.enumerated() { indices[id] = index }
    place(measured)
  }

  /// The blocks from `start` on laid out again, those before kept with their shapes: what a
  /// conversation that grows changes, at the end.
  @MainActor
  public func replacing(
    from start: Int, blocks: [ConversationBlock], measured: [String: Double],
    shapes cache: ConversationOverviewShapes
  ) -> ConversationOverviewLayout {
    guard let metrics, start >= 0, start <= ids.count, start <= blocks.count else {
      return ConversationOverviewLayout(
        blocks: blocks, measured: measured, metrics: metrics ?? Self.fallbackMetrics,
        shapes: cache)
    }
    var layout = self
    for id in ids[start...] { layout.indices[id] = nil }
    layout.ids.removeSubrange(start...)
    layout.shapes.removeSubrange(start...)
    layout.estimates.removeSubrange(start...)
    for block in blocks[start...] {
      let shape = cache.shape(of: block)
      layout.indices[block.id] = layout.ids.count
      layout.ids.append(block.id)
      layout.shapes.append(shape)
      layout.estimates.append(Self.estimatedHeight(of: shape, metrics: metrics))
    }
    layout.place(measured)
    return layout
  }

  private static let fallbackMetrics = Metrics(
    columnWidth: 700, textSize: 14.5, lineHeight: 1.25, blockSpacing: 18, paragraphSpacing: 10)

  /// The same blocks, with the heights measured since: nothing is read nor estimated again.
  public func remeasured(_ measured: [String: Double]) -> ConversationOverviewLayout {
    var layout = self
    layout.place(measured)
    return layout
  }

  private mutating func place(_ measured: [String: Double]) {
    guard let metrics else { return }
    heights = estimates
    for (id, height) in measured {
      if let index = indices[id] { heights[index] = height }
    }
    tops = []
    tops.reserveCapacity(heights.count)
    var top = 0.0
    for index in heights.indices {
      heights[index] = max(heights[index], 1)
      tops.append(top)
      top += heights[index] + metrics.blockSpacing
    }
    height = max(top - metrics.blockSpacing, 0)
  }

  public var count: Int { ids.count }

  public func item(at index: Int) -> Item {
    Item(id: ids[index], shape: shapes[index], top: tops[index], height: heights[index])
  }

  /// Every block placed: for tests, the drawing reads the arrays.
  public var items: [Item] { ids.indices.map(item(at:)) }

  public func index(of id: String) -> Int? { indices[id] }

  /// Where a place is, from the conversation's top.
  public func y(of position: Position) -> Double {
    guard tops.indices.contains(position.index) else { return 0 }
    return tops[position.index] + min(max(position.offset, 0), heights[position.index])
  }

  /// The block at that height, and how far into it; the space after a block counts as its end.
  public func position(atY y: Double) -> Position? {
    guard !tops.isEmpty else { return nil }
    var low = 0
    var high = tops.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if tops[middle] <= y { low = middle } else { high = middle - 1 }
    }
    return Position(index: low, offset: min(max(y - tops[low], 0), heights[low]))
  }

  /// How much smaller the overview draws the conversation: all of it in `overviewHeight`, never
  /// larger than a fifth, so that a short conversation is not blown up.
  public func scale(forHeight overviewHeight: Double) -> Double {
    guard height > 0 else { return Self.maximumScale }
    return min(overviewHeight / height, Self.maximumScale)
  }

  public static let maximumScale = 0.2

  /// The height a block never built is given.
  public static func estimatedHeight(of shape: Shape, metrics: Metrics) -> Double {
    let pitch = metrics.linePitch
    // A tool folded on its title: the line, and the frame's padding.
    let toolHeight = pitch + 20
    switch shape.mark {
    case .tool, .failure:
      return Double(max(shape.rows, 1)) * toolHeight
    case .prompt:
      return Double(max(shape.lineCount(width: metrics.charactersPerBubbleLine), 1)) * pitch + 20
    case .text:
      return Double(max(shape.lineCount(width: metrics.charactersPerLine), 1)) * pitch
        + Double(max(shape.paragraphs - 1, 0)) * metrics.paragraphSpacing
    case .quiet:
      return pitch
    }
  }

  // MARK: - Width

  /// The overview's width, and what the messages give up for it.
  public struct Placement: Equatable, Sendable {
    public var width: Double
    /// Taken from the right of the messages: none while the margin holds the overview.
    public var reserved: Double

    public init(width: Double, reserved: Double) {
      self.width = width
      self.reserved = reserved
    }
  }

  public static let minimumWidth = 56.0
  /// No wider, however wide the margin (#596): held against the pane's right edge, as a scroll bar
  /// is, the rest of the margin left empty.
  public static let maximumWidth = 160.0
  /// Kept between the text and the overview.
  public static let gap = 12.0

  /// The margin right of the column, less a gap, up to `maximumWidth`; or, narrower than the
  /// minimum, the minimum, the
  /// messages giving up what it lacks — no more, so that the text moves as the window narrows,
  /// never in a jump.
  ///
  /// The column is `contentWidth` at most, between its margins, centred in what the messages
  /// have: the pane, less what they give up.
  public static func placement(
    paneWidth: Double, contentWidth: Double, leadingMargin: Double, trailingMargin: Double
  ) -> Placement {
    let column = contentWidth + leadingMargin + trailingMargin
    let free = (paneWidth - min(column, paneWidth)) / 2 + trailingMargin - gap
    guard free < minimumWidth else {
      return Placement(width: min(free, maximumWidth).rounded(.down), reserved: 0)
    }
    // Centred, the column moves by half of what is given up while it keeps its width; once it
    // fills the pane, only its right margin stands between it and the overview.
    let centred = 2 * (minimumWidth - free)
    let reserved =
      column + centred <= paneWidth ? centred : max(minimumWidth + gap - trailingMargin, 0)
    return Placement(width: minimumWidth, reserved: reserved)
  }

  // MARK: - Moments (#572)

  /// Moments drawn closer than that in the overview share one icon.
  public static let clusterGap = 13.0

  /// The moments grouped as the overview draws them: each group from a moment to those less than
  /// `minimumGap` points below it once drawn small, in order. Only the first one's icon is drawn.
  ///
  /// - Parameter tops: where each moment's block starts in the conversation, in order.
  public static func clusters(
    _ tops: [Double], scale: Double, minimumGap: Double = clusterGap
  ) -> [Range<Int>] {
    var clusters: [Range<Int>] = []
    var start = 0
    for index in tops.indices.dropFirst()
    where (tops[index] - tops[start]) * scale >= minimumGap {
      clusters.append(start..<index)
      start = index
    }
    if !tops.isEmpty { clusters.append(start..<tops.count) }
    return clusters
  }

  // MARK: - Bookmark preview

  /// Kept between a bookmark's preview and the overview.
  public static let previewGap = 8.0
  /// Kept between a bookmark's preview and the ends of the overview.
  public static let previewMargin = 4.0

  /// Where the start of a bookmarked message shows while the pointer is on its line, in the
  /// overview's points: left of the overview, centred on the line — moved down or up just enough
  /// to stay level with the overview, so that a bookmark near an end neither slips it under the
  /// toolbar nor lays it over the composer. Taller than the overview, it starts at its top.
  public static func previewOrigin(
    lineY: Double, previewWidth: Double, previewHeight: Double, overviewHeight: Double
  ) -> (x: Double, y: Double) {
    let centred = lineY - previewHeight / 2
    let lowest = overviewHeight - previewMargin - previewHeight
    return (-previewWidth - previewGap, max(min(centred, lowest), previewMargin))
  }

  /// How wide a bookmark's preview may be: wider as the text is larger, never wider than the
  /// room left of the overview — narrower then, never past the pane's edge.
  public static func previewWidth(textSize: Double, room: Double) -> Double {
    min(max(260, textSize * 20), max(room - previewGap - previewMargin, 0))
  }

  // MARK: - Shapes

  static func shape(of block: ConversationBlock) -> Shape {
    let failed = block.toolState.map { if case .failed = $0 { true } else { false } } ?? false
    let tool = Shape(mark: failed ? .failure : .tool)
    switch block {
    case .toolGroup:
      return tool
    case .subagentGroup(_, let runs):
      var shape = tool
      shape.rows = max(runs.count, 1)
      return shape
    case .entry(let entry):
      switch entry.content {
      case .userPrompt(let text, _):
        return lines(of: text, mark: .prompt)
      case .agentText(let text):
        return lines(of: text, mark: .text)
      case .tool:
        return tool
      case .reasoning, .notice:
        return Shape(mark: .quiet)
      }
    }
  }

  /// The lines of a text that are not blank, their length in characters, and its paragraphs: one
  /// pass over its bytes, the text made contiguous once — a text read from a transcript comes
  /// from Foundation, where walking its characters one by one costs far more.
  static func lines(of text: String, mark: Mark) -> Shape {
    var shape = Shape(mark: mark)
    var contiguous = text
    contiguous.makeContiguousUTF8()
    var length = 0
    var isBlank = true
    var previousWasBlank = false
    var hasContent = false
    func endLine() {
      if isBlank {
        previousWasBlank = true
      } else {
        if previousWasBlank, hasContent { shape.paragraphs += 1 }
        previousWasBlank = false
        hasContent = true
        if shape.lineLengths.count < maximumLines {
          shape.lineLengths.append(length)
        } else {
          shape.moreLines += 1
        }
      }
      length = 0
      isBlank = true
    }
    _ = contiguous.utf8.withContiguousStorageIfAvailable { bytes in
      for byte in bytes {
        if byte == 0x0A {
          endLine()
        } else if byte & 0xC0 != 0x80 {
          // The first byte of a character: its continuation bytes are not counted.
          length += 1
          if byte != 0x20, byte != 0x09, byte != 0x0D { isBlank = false }
        }
      }
    }
    endLine()
    return shape
  }
}

/// What each block of a conversation looks like drawn small, read once (#567): kept as long as the
/// conversation, so that neither a new layout, nor a width, nor a view made again reads the
/// thousands of texts of a long session anew.
@MainActor
public final class ConversationOverviewShapes {
  private struct Signature: Hashable {
    var kind: Int
    var size: Int
    var failed: Bool

    init(_ block: ConversationBlock) {
      failed = block.toolState.map { if case .failed = $0 { true } else { false } } ?? false
      // UTF-16 counts: a text from Foundation knows its own without reading it.
      switch block {
      case .entry(let entry):
        switch entry.content {
        case .userPrompt(let text, _): (kind, size) = (0, text.utf16.count)
        case .agentText(let text): (kind, size) = (1, text.utf16.count)
        case .reasoning: (kind, size) = (2, 0)
        case .tool: (kind, size) = (3, 1)
        case .notice: (kind, size) = (4, 0)
        }
      case .toolGroup(_, let calls): (kind, size) = (5, calls.count)
      case .subagentGroup(_, let runs): (kind, size) = (6, runs.count)
      }
    }
  }

  private var shapes: [String: (signature: Signature, shape: ConversationOverviewLayout.Shape)] =
    [:]
  /// How many shapes were read: a test holds it to the blocks that changed.
  public private(set) var readCount = 0

  public init() {}

  public func shape(of block: ConversationBlock) -> ConversationOverviewLayout.Shape {
    let signature = Signature(block)
    if let known = shapes[block.id], known.signature == signature { return known.shape }
    let shape = ConversationOverviewLayout.shape(of: block)
    shapes[block.id] = (signature, shape)
    readCount += 1
    return shape
  }
}
