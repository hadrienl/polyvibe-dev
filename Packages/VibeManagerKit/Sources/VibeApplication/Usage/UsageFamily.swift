import Foundation
import VibeDomain

/// The sessions whose usage a coordinator's total adds to its own (#606): every session it gave
/// work to, and theirs in turn.
///
/// Unlike `CoordinationPolicy.children`, a child that left the board still counts: closed, done or
/// archived, what its agent spent was spent for the coordinator.
public enum UsageFamily {
  /// A session under the coordinator, and how far: 1 for its own child, 2 for a child's child.
  public struct Member: Hashable, Sendable {
    public let id: SessionID
    public let depth: Int

    public init(id: SessionID, depth: Int) {
      self.id = id
      self.depth = depth
    }
  }

  /// Every session under `id`, each one followed by its own, in the order the store keeps them.
  /// Empty for a session without children. A link that loops back is followed once.
  public static func members(of id: SessionID, among sessions: [WorkSession]) -> [Member] {
    members(of: id, children: children(among: sessions))
  }

  /// The members of each of `ids` that has any.
  public static func families(of ids: some Sequence<SessionID>, among sessions: [WorkSession])
    -> [SessionID: [Member]]
  {
    let children = children(among: sessions)
    var families: [SessionID: [Member]] = [:]
    for id in ids {
      let members = members(of: id, children: children)
      if !members.isEmpty { families[id] = members }
    }
    return families
  }

  /// The children of each session that has any, in the store's order.
  private static func children(among sessions: [WorkSession]) -> [SessionID: [SessionID]] {
    var children: [SessionID: [SessionID]] = [:]
    for session in sessions {
      guard let parent = session.coordination?.coordinatorID, parent != session.id else {
        continue
      }
      children[parent, default: []].append(session.id)
    }
    return children
  }

  private static func members(of id: SessionID, children: [SessionID: [SessionID]]) -> [Member] {
    guard children[id] != nil else { return [] }
    var members: [Member] = []
    var seen: Set<SessionID> = [id]
    func visit(_ parent: SessionID, depth: Int) {
      for child in children[parent] ?? [] where seen.insert(child).inserted {
        members.append(Member(id: child, depth: depth))
        visit(child, depth: depth + 1)
      }
    }
    visit(id, depth: 1)
    return members
  }
}
