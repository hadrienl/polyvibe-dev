import Foundation

/// The whole conversation drawn small beside it, which scrolls it too (#567).
///
/// Laid out from the blocks rather than from their views: the list builds only the rows on screen,
/// so a block never shown is given the height its content suggests — lines of text at the width
/// of the column, a tool folded on its title — and the height measured once its row has been
/// built. Each block is placed under the one before, the whole conversation fitting the height of
/// the overview.
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
    var charactersPerLine: Int { max(16, Int(columnWidth / (textSize * 0.5))) }
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

  /// A block drawn small, wherever it is.
  public struct Shape: Hashable, Sendable {
    public var mark: Mark
    /// The length of each line of text, from 0 to 1 of the column, top to bottom.
    public var lines: [Double]
    public var estimatedHeight: Double
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

  public private(set) var items: [Item] = []
  /// The conversation's height, in its points.
  public private(set) var height = 0.0
  public private(set) var metrics: Metrics?
  private var indices: [String: Int] = [:]
  /// What each shape was made from, so that a block that did not change keeps its shape.
  private var signatures: [String: Signature] = [:]

  /// No line is kept beyond that many in a block: drawn small, a long file reads as a mass.
  static let maximumLines = 2000

  public init() {}

  /// Lays the blocks out, taking from `previous` the shapes of those that did not change.
  ///
  /// - Parameter measured: the height of the rows already built, by block.
  public init(
    blocks: [ConversationBlock], measured: [String: Double], metrics: Metrics,
    reusing previous: ConversationOverviewLayout? = nil
  ) {
    self.metrics = metrics
    let reusable = previous?.metrics == metrics ? previous : nil
    items.reserveCapacity(blocks.count)
    var top = 0.0
    for block in blocks {
      let signature = Signature(block)
      let shape: Shape
      if let reusable, let index = reusable.indices[block.id],
        reusable.signatures[block.id] == signature
      {
        shape = reusable.items[index].shape
      } else {
        shape = Self.shape(of: block, metrics: metrics)
      }
      let height = max(measured[block.id] ?? shape.estimatedHeight, 1)
      indices[block.id] = items.count
      signatures[block.id] = signature
      items.append(Item(id: block.id, shape: shape, top: top, height: height))
      top += height + metrics.blockSpacing
    }
    height = max(top - metrics.blockSpacing, 0)
  }

  public func index(of id: String) -> Int? { indices[id] }

  /// Where a place is, from the conversation's top.
  public func y(of position: Position) -> Double {
    guard items.indices.contains(position.index) else { return 0 }
    let item = items[position.index]
    return item.top + min(max(position.offset, 0), item.height)
  }

  /// The block at that height, and how far into it; the space after a block counts as its end.
  public func position(atY y: Double) -> Position? {
    guard !items.isEmpty else { return nil }
    var low = 0
    var high = items.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if items[middle].top <= y { low = middle } else { high = middle - 1 }
    }
    let item = items[low]
    return Position(index: low, offset: min(max(y - item.top, 0), item.height))
  }

  /// How much smaller the overview draws the conversation: all of it in `overviewHeight`, never
  /// larger than a fifth, so that a short conversation is not blown up.
  public func scale(forHeight overviewHeight: Double) -> Double {
    guard height > 0 else { return Self.maximumScale }
    return min(overviewHeight / height, Self.maximumScale)
  }

  public static let maximumScale = 0.2

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
  /// Kept between the text and the overview.
  public static let gap = 12.0

  /// The margin right of the column, less a gap; or, narrower than the minimum, the minimum, the
  /// column then laid out in what remains.
  ///
  /// The column is `contentWidth` at most, between its margins, centred in the pane.
  public static func placement(
    paneWidth: Double, contentWidth: Double, leadingMargin: Double, trailingMargin: Double
  ) -> Placement {
    let box = min(contentWidth + leadingMargin + trailingMargin, paneWidth)
    let free = (paneWidth - box) / 2 + trailingMargin - gap
    guard free < minimumWidth else { return Placement(width: free.rounded(.down), reserved: 0) }
    return Placement(width: minimumWidth, reserved: minimumWidth)
  }

  // MARK: - Shapes

  private struct Signature: Hashable {
    var kind: Int
    var size: Int
    var failed: Bool

    init(_ block: ConversationBlock) {
      failed = block.toolState.map { if case .failed = $0 { true } else { false } } ?? false
      switch block {
      case .entry(let entry):
        switch entry.content {
        case .userPrompt(let text, _): (kind, size) = (0, text.utf8.count)
        case .agentText(let text): (kind, size) = (1, text.utf8.count)
        case .reasoning: (kind, size) = (2, 0)
        case .tool: (kind, size) = (3, 1)
        case .notice: (kind, size) = (4, 0)
        }
      case .toolGroup(_, let calls): (kind, size) = (5, calls.count)
      case .subagentGroup(_, let runs): (kind, size) = (6, runs.count)
      }
    }
  }

  static func shape(of block: ConversationBlock, metrics: Metrics) -> Shape {
    let pitch = metrics.linePitch
    // A tool folded on its title: the line, and the frame's padding.
    let toolHeight = pitch + 20
    let failed = block.toolState.map { if case .failed = $0 { true } else { false } } ?? false
    let tool = Shape(mark: failed ? .failure : .tool, lines: [], estimatedHeight: toolHeight)
    switch block {
    case .toolGroup:
      return tool
    case .subagentGroup(_, let runs):
      var shape = tool
      shape.estimatedHeight = Double(max(runs.count, 1)) * toolHeight
      return shape
    case .entry(let entry):
      switch entry.content {
      case .userPrompt(let text, _):
        // A bubble leaves room on its leading side.
        let wrapped = wrap(text, width: Int(Double(metrics.charactersPerLine) * 0.8))
        let lines = wrapped.lines.map { $0 * 0.8 }
        return Shape(
          mark: .prompt, lines: lines,
          estimatedHeight: Double(max(wrapped.count, 1)) * pitch + 20)
      case .agentText(let text):
        let wrapped = wrap(text, width: metrics.charactersPerLine)
        return Shape(
          mark: .text, lines: wrapped.lines,
          estimatedHeight: Double(max(wrapped.count, 1)) * pitch
            + Double(wrapped.paragraphs - 1) * metrics.paragraphSpacing)
      case .tool:
        return tool
      case .reasoning, .notice:
        return Shape(mark: .quiet, lines: [0.3], estimatedHeight: pitch)
      }
    }
  }

  /// The lines a text makes at `width` characters: their lengths, from 0 to 1, the first
  /// `maximumLines` of them; how many there are; how many paragraphs.
  static func wrap(_ text: String, width: Int) -> (lines: [Double], count: Int, paragraphs: Int) {
    let width = max(width, 1)
    var lines: [Double] = []
    var count = 0
    var paragraphs = 1
    var previousWasBlank = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let length = line.count
      guard length > 0, !line.allSatisfy(\.isWhitespace) else {
        previousWasBlank = true
        continue
      }
      if previousWasBlank, count > 0 { paragraphs += 1 }
      previousWasBlank = false
      let full = length / width
      let rest = length % width
      let made = full + (rest > 0 ? 1 : 0)
      count += made
      guard lines.count < maximumLines else { continue }
      lines.append(contentsOf: repeatElement(1, count: min(full, maximumLines - lines.count)))
      if rest > 0, lines.count < maximumLines { lines.append(Double(rest) / Double(width)) }
    }
    return (lines, count, paragraphs)
  }
}
