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
    /// A pinned tab — the ticket's or one the user pinned — opened a link: the group gathers that
    /// tab's links, the tab staying pinned. It lives on with one tab while that tab is pinned.
    case pinnedOpener(BrowserTabID)
    /// The user made it: it goes once empty.
    case user
  }

  public let id: BrowserTabGroupID
  /// Empty: the sidebar shows a name of its own.
  public var name: String
  public var isCollapsed: Bool
  public var origin: Origin

  public init(
    id: BrowserTabGroupID = BrowserTabGroupID(), name: String, isCollapsed: Bool = false,
    origin: Origin
  ) {
    self.id = id
    self.name = name
    self.isCollapsed = isCollapsed
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, isCollapsed, origin
  }

  /// An origin written by a later build reads as the user's: the group is kept until empty.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(BrowserTabGroupID.self, forKey: .id)
    name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
    isCollapsed = (try? container.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
    origin = (try? container.decodeIfPresent(Origin.self, forKey: .origin)) ?? .user
  }
}
