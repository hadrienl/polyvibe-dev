import Foundation

public struct BrowserTabGroupID: Hashable, Codable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A group of the web view's sidebar (#648): tabs opened from one another, as Dia gathers them.
/// Its tabs follow one another among the session's tabs; it is where its first tab is.
public struct BrowserTabGroup: Identifiable, Hashable, Codable, Sendable {
  public enum Origin: Hashable, Codable, Sendable {
    /// A tab opened a link: the two were its first tabs. Left with one, it goes.
    case opener
    /// A tab the user pinned opened a link: the group gathers that tab's links, the tab staying
    /// pinned. It lives on with one tab while that tab is pinned.
    case pinnedOpener(BrowserTabID)
    /// The ticket's page opened a link: the group gathers the ticket's links. The ticket's tab is
    /// made again at each launch, under another identifier: the group is the ticket's, not a tab's.
    /// It goes once empty.
    case ticket
    /// The user made it: it goes once empty.
    case user
  }

  /// Where the group's name comes from (#666).
  public enum NameSource: String, Codable, Sendable {
    /// None yet: the sidebar shows « Group N ».
    case placeholder
    /// Made on this Mac from its tabs (Apple Intelligence), never copied from one of them.
    case generated
    /// The user's: never replaced.
    case user
  }

  public let id: BrowserTabGroupID
  /// Empty: the sidebar shows « Group N ».
  public var name: String
  public var nameSource: NameSource
  /// The N of « Group N »: given once, when the group is made, from the session's count. 0: not
  /// given yet.
  public var number: Int
  /// How many tabs the group had when a name was last asked for: asked at 2, once more at 4.
  public var titledAtCount: Int?
  public var isCollapsed: Bool
  public var origin: Origin

  public init(
    id: BrowserTabGroupID = BrowserTabGroupID(), name: String = "", nameSource: NameSource? = nil,
    number: Int = 0, isCollapsed: Bool = false, origin: Origin
  ) {
    self.id = id
    self.name = name
    self.nameSource = nameSource ?? (name.isEmpty ? .placeholder : .user)
    self.number = number
    self.isCollapsed = isCollapsed
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, nameSource, number, titledAtCount, isCollapsed, origin
  }

  /// An origin written by a later build reads as the user's: the group is kept until empty. A
  /// group written before #666 keeps its name as the user's, never replaced; its number is given
  /// when it is read back.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(BrowserTabGroupID.self, forKey: .id)
    name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
    nameSource =
      (try? container.decodeIfPresent(NameSource.self, forKey: .nameSource))
      ?? (name.isEmpty ? .placeholder : .user)
    number = (try? container.decodeIfPresent(Int.self, forKey: .number)) ?? 0
    titledAtCount = try? container.decodeIfPresent(Int.self, forKey: .titledAtCount)
    isCollapsed = (try? container.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
    origin = (try? container.decodeIfPresent(Origin.self, forKey: .origin)) ?? .user
  }

  /// What the agent reads in `tabs_list`, in English: the name, else « Group N ».
  public var displayName: String {
    name.isEmpty ? "Group \(number)" : name
  }

  /// Whether a name is due, the group holding `count` tabs: when it is made (2), once more at 4,
  /// never once the user named it.
  public func needsTitle(count: Int) -> Bool {
    guard nameSource != .user else { return false }
    if count >= 4 { return (titledAtCount ?? 0) < 4 }
    return count >= 2 && titledAtCount == nil
  }

  /// The name a model gave, once checked: trimmed, 1 to 32 characters, and none of the tabs'
  /// titles — the sidebar shows those already — its first letter a capital, as a title's.
  /// `nil`: the group keeps the name it has.
  public static func acceptedTitle(_ answer: String?, tabTitles: [String]) -> String? {
    let quotes = CharacterSet(charactersIn: "\"'«»“”‘’")
    guard
      let title = answer?.trimmingCharacters(in: .whitespacesAndNewlines.union(quotes))
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty, title.count <= 32, !title.contains("\n")
    else { return nil }
    let duplicate = tabTitles.contains {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title)
        == .orderedSame
    }
    return duplicate ? nil : title.prefix(1).uppercased() + title.dropFirst()
  }
}
