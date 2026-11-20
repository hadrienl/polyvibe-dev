/// A drag of the overview's frame (#567): where the frame was taken, and whether heights measured
/// meanwhile wait for the drag to end before the overview is laid out again — the drawing would
/// move under the pointer, and the frame with it.
///
/// Ended by the button let go, and by the gesture cancelled — another session brought up from the
/// keyboard while it is held —, which SwiftUI tells only by resetting the gesture's state: missed,
/// the heights stayed held, and the frame lit, until the next drag.
struct OverviewDrag: Equatable {
  /// Where the frame was taken, from its top; infinite once a moment was clicked. `nil` out of a
  /// drag.
  var grab: Double?
  /// Heights measured during the drag, not laid out yet.
  private(set) var holdsMeasures = false

  var isDragging: Bool { grab != nil }

  /// Heights were measured: whether they wait for the end of a drag.
  mutating func holdMeasures() -> Bool {
    guard isDragging else { return false }
    holdsMeasures = true
    return true
  }

  /// The drag ended, let go or cancelled. Whether heights held meanwhile are to be laid out now.
  mutating func end() -> Bool {
    grab = nil
    defer { holdsMeasures = false }
    return holdsMeasures
  }
}
