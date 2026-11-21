import Testing

@testable import VibeConversationUI

/// A drag of the overview's frame, and the heights measured while it lasts (#567).
@Suite("Dragging the overview's frame")
struct OverviewDragTests {
  @Test("Out of a drag, heights measured lay the overview out at once")
  func notDragging() {
    var drag = OverviewDrag()
    let held = drag.holdMeasures()
    let laidOut = drag.end()
    #expect(!held)
    #expect(!laidOut)
  }

  @Test("During a drag they wait, and its end lays them out, once")
  func heldUntilTheEnd() {
    var drag = OverviewDrag()
    drag.grab = 12
    let first = drag.holdMeasures()
    let second = drag.holdMeasures()
    #expect(first && second)
    let letGo = drag.end()
    #expect(letGo)
    #expect(!drag.isDragging)
    // Let go and cancelled both end it: told twice, it lays nothing out twice.
    let cancelled = drag.end()
    #expect(!cancelled)
    let after = drag.holdMeasures()
    #expect(!after)
  }

  @Test("A drag ended with nothing measured lays nothing out")
  func nothingHeld() {
    var drag = OverviewDrag()
    drag.grab = .infinity
    let laidOut = drag.end()
    #expect(!laidOut)
    #expect(!drag.isDragging)
  }
}
