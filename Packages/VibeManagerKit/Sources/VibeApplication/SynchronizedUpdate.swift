/// Synchronized output, DEC private mode 2026 (#580): a program wraps a frame in `ESC[?2026h` …
/// `ESC[?2026l`, and a terminal that knows the mode, as SwiftTerm does, shows the frame only once
/// the update ends — or once a second has passed since it began, or on a reset (`ESC c`).
public enum SynchronizedUpdate {
  public enum Mark: Equatable, Sendable {
    case begin
    case end
  }

  /// How long a view waits on an update it was told of before showing what it holds: SwiftTerm's.
  public static let wait: Duration = .seconds(1)

  /// Each begin and end in `bytes`, with the index of its `ESC`, in order — the mode set or reset
  /// among other modes too, and a reset of the terminal as an end — and the index of an escape
  /// sequence `bytes` end inside of, which may still be one: nil when they end on none.
  public static func marks(in bytes: ArraySlice<UInt8>) -> (marks: [(Mark, Int)], cutShort: Int?) {
    var marks: [(Mark, Int)] = []
    var index = bytes.startIndex
    while let escape = bytes[index...].firstIndex(of: escapeByte) {
      index = escape + 1
      guard index < bytes.endIndex else { return (marks, escape) }
      if bytes[index] == UInt8(ascii: "c") {
        marks.append((.end, escape))
        continue
      }
      guard bytes[index] == UInt8(ascii: "[") else { continue }
      guard index + 1 < bytes.endIndex else { return (marks, escape) }
      guard bytes[index + 1] == UInt8(ascii: "?") else { continue }
      let parameters = index + 2
      guard
        let final = bytes[parameters...].firstIndex(where: {
          !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) && $0 != UInt8(ascii: ";")
        })
      else { return (marks, escape) }
      let mark: Mark
      switch bytes[final] {
      case UInt8(ascii: "h"): mark = .begin
      case UInt8(ascii: "l"): mark = .end
      default: continue
      }
      if bytes[parameters..<final].split(separator: UInt8(ascii: ";")).contains(where: {
        $0.elementsEqual(mode)
      }) {
        marks.append((mark, escape))
      }
      index = final + 1
    }
    return (marks, nil)
  }

  private static let escapeByte: UInt8 = 0x1B
  private static let mode = Array("2026".utf8)
}
