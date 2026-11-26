import AppKit
import Observation
import SwiftUI

/// Created only for a hovered or bookmarked message. TextKit remains the source of geometry.
@MainActor @Observable
final class ParagraphBookmarkLayout {
  struct Position: Equatable {
    var unit: Int
    var top: Double
    var height: Double
  }
  var positions: [Position] = []
  @ObservationIgnored weak var row: NSView?
  @ObservationIgnored var views: [WeakView] = []
  @ObservationIgnored var changed: ([Position]) -> Void = { _ in }
  @ObservationIgnored private var scheduled = false
  struct WeakView { weak var value: SegmentTextView? }

  func register(_ view: SegmentTextView) {
    views.removeAll { $0.value == nil }
    if !views.contains(where: { $0.value === view }) { views.append(WeakView(value: view)) }
    refresh()
  }

  func refresh() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      scheduled = false
      measure()
    }
  }

  private func measure() {
    guard let row, row.window != nil else { return }
    let ordered = views.compactMap(\.value).filter { $0.window === row.window }.sorted {
      $0.convert($0.bounds, to: row).minY < $1.convert($1.bounds, to: row).minY
    }
    var found: [Position] = []
    for view in ordered {
      guard let storage = view.textStorage, let manager = view.layoutManager,
        let container = view.textContainer
      else { continue }
      manager.ensureLayout(for: container)
      for range in MarkdownUnits.ranges(in: storage, kind: view.kind) {
        let character = min(range.location, max(0, storage.length - 1))
        let glyph = manager.glyphIndexForCharacter(at: character)
        let rect =
          manager.numberOfGlyphs > 0
          ? (range.location == storage.length && storage.string.hasSuffix("\n")
            ? manager.extraLineFragmentRect
            : manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
          : CGRect(x: 0, y: 0, width: 1, height: view.font?.pointSize ?? 14)
        let point = view.convert(CGPoint(x: 0, y: rect.minY + view.textContainerOrigin.y), to: row)
        found.append(Position(unit: found.count, top: point.y, height: rect.height))
      }
    }
    if found != positions { positions = found }
    changed(found)
  }

  func unit(at y: Double) -> Int {
    positions.last { $0.top <= y }?.unit ?? 0
  }
}

struct BookmarkRowOrigin: NSViewRepresentable {
  let layout: ParagraphBookmarkLayout
  final class Origin: NSView {
    override var isFlipped: Bool { true }
    weak var tracker: ParagraphBookmarkLayout?
    override func layout() {
      super.layout()
      tracker?.refresh()
    }
    override func viewDidMoveToWindow() { tracker?.refresh() }
  }
  func makeNSView(context: Context) -> Origin { Origin() }
  func updateNSView(_ view: Origin, context: Context) {
    view.tracker = layout
    layout.row = view
    layout.refresh()
  }
}

extension EnvironmentValues {
  @Entry var paragraphBookmarkLayout: ParagraphBookmarkLayout?
}
