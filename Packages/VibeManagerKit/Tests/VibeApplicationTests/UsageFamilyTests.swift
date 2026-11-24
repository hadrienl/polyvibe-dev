import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// A coordinator's usage with its children (#606): who counts, and what they add up to.
@Suite("The usage of a coordinator with its children (#606)")
struct UsageFamilyTests {
  private static let day = LocalDay(Date(timeIntervalSince1970: 1_790_000_000), calendar: .current)
  private static let priced = "claude-sonnet-4-5"
  private static let unpriced = "a-model-nobody-prices"

  private static func session(_ name: String, under parent: WorkSession? = nil) -> WorkSession {
    WorkSession(
      name: name, coordination: parent.map { .child(of: $0.id) } ?? .coordinator)
  }

  // MARK: - Who counts

  @Test("A session without children has no family")
  func noChildren() {
    let alone = Self.session("Alone")
    let ordinary = WorkSession(name: "Ordinary")
    let sessions = [alone, ordinary]
    #expect(UsageFamily.members(of: alone.id, among: sessions).isEmpty)
    #expect(UsageFamily.members(of: ordinary.id, among: sessions).isEmpty)
    #expect(UsageFamily.families(of: [alone.id, ordinary.id], among: sessions).isEmpty)
  }

  @Test("Children's children count, each one after its parent, deeper by one")
  func recursive() {
    let coordinator = Self.session("Coordinator")
    let first = Self.session("First", under: coordinator)
    let grandchild = Self.session("Grandchild", under: first)
    let greatGrandchild = Self.session("Great-grandchild", under: grandchild)
    let second = Self.session("Second", under: coordinator)
    let stranger = Self.session("Another's", under: Self.session("Another coordinator"))
    let members = UsageFamily.members(
      of: coordinator.id,
      among: [second, greatGrandchild, coordinator, stranger, first, grandchild]
    )
    // The store's order, each parent before what is under it.
    #expect(
      members == [
        .init(id: second.id, depth: 1), .init(id: first.id, depth: 1),
        .init(id: grandchild.id, depth: 2), .init(id: greatGrandchild.id, depth: 3),
      ])
    // A child's own family starts from it.
    #expect(
      UsageFamily.members(of: first.id, among: [first, grandchild, greatGrandchild]) == [
        .init(id: grandchild.id, depth: 1), .init(id: greatGrandchild.id, depth: 2),
      ])
  }

  @Test("Closed, done and archived children count")
  func childrenThatLeft() throws {
    let coordinator = Self.session("Coordinator")
    let closed = WorkSession(
      name: "Closed", status: .closed, closedAt: Date(), coordination: .child(of: coordinator.id))
    let done = WorkSession(
      name: "Done", status: .closed, taskStatus: .done, coordination: .child(of: coordinator.id))
    var archived = WorkSession(
      name: "Archived", status: .closed, taskStatus: .done,
      coordination: .child(of: coordinator.id))
    try archived.archive(at: Date().addingTimeInterval(60), cause: .user)
    #expect(archived.status == .archived)
    let ids = UsageFamily.members(of: coordinator.id, among: [coordinator, closed, done, archived])
      .map(\.id)
    #expect(ids == [closed.id, done.id, archived.id])
  }

  @Test("A link that loops back is followed once")
  func loop() {
    let a = SessionID()
    let b = SessionID()
    let sessions = [
      WorkSession(id: a, name: "A", coordination: .child(of: b)),
      WorkSession(id: b, name: "B", coordination: .child(of: a)),
    ]
    #expect(UsageFamily.members(of: a, among: sessions) == [.init(id: b, depth: 1)])
  }

  // MARK: - What they add up to

  private static func file(_ session: WorkSession, model: String, tokens: TokenCounts)
    -> TokenUsageFile
  {
    TokenUsageFile(
      sessionID: session.id, providerID: "claude-code",
      tallies: [.init(model: model, day: day, tokens: tokens, responses: 1)])
  }

  private static func service(_ files: [TokenUsageFile]) -> UsageService {
    let ledger = InMemoryUsageLedger()
    let tracking = InMemoryUsageTrackingStore()
    // From text: a `Double` literal is not a whole thousandth once made a `Decimal`.
    let thousandth = Decimal(string: "0.001")!
    let price = ModelPrice(
      input: thousandth, cacheRead: thousandth, cacheWrite: thousandth, output: thousandth * 10)
    return UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking), ledger: ledger,
      tracking: tracking,
      tokenStore: InMemoryTokenUsageStore(
        snapshot: TokenUsageSnapshot(
          files: Dictionary(
            uniqueKeysWithValues: files.enumerated().map { ("\($0.offset)", $0.element) }))),
      reader: nil,
      prices: ModelPriceUpdater(
        fetcher: NoFetch(), store: NoPrices(),
        bundled: ModelPriceList(fetchedAt: Date(), prices: [priced: price])))
  }

  @Test("The total adds the coordinator, its children and theirs; each keeps its own figures")
  func total() async {
    let coordinator = Self.session("Coordinator")
    let child = Self.session("Child", under: coordinator)
    let grandchild = Self.session("Grandchild", under: child)
    let service = Self.service([
      Self.file(coordinator, model: Self.priced, tokens: TokenCounts(input: 1_000)),
      Self.file(child, model: Self.priced, tokens: TokenCounts(input: 2_000)),
      Self.file(grandchild, model: Self.priced, tokens: TokenCounts(output: 300)),
    ])
    let members = UsageFamily.members(of: coordinator.id, among: [coordinator, child, grandchild])
    let overview = await service.overview(
      period: .allTime, grouping: .session, sessions: [coordinator.id] + members.map(\.id),
      families: [coordinator.id: members.map(\.id)])
    let family = overview.families[coordinator.id]
    #expect(family?.total.tokens == TokenCounts(input: 3_000, output: 300))
    #expect(family?.cost.total == Decimal(6))
    #expect(family?.cost.unpriced.isEmpty == true)
    #expect(overview.sessions[coordinator.id]?.cost.total == 1)
    #expect(overview.sessions[child.id]?.cost.total == 2)
    #expect(overview.sessions[grandchild.id]?.cost.total == 3)
  }

  @Test("A child's model without a price is said in the total, never counted as free")
  func unpricedModel() async {
    let coordinator = Self.session("Coordinator")
    let child = Self.session("Child", under: coordinator)
    let service = Self.service([
      Self.file(coordinator, model: Self.priced, tokens: TokenCounts(input: 1_000)),
      Self.file(child, model: Self.unpriced, tokens: TokenCounts(input: 5_000)),
    ])
    let overview = await service.overview(
      period: .allTime, grouping: .session, sessions: [coordinator.id, child.id],
      families: [coordinator.id: [child.id]])
    let family = overview.families[coordinator.id]
    #expect(family?.cost.total == 1)
    #expect(
      family?.cost.unpriced == [UsageModelKey(providerID: "claude-code", model: Self.unpriced)])
    #expect(family?.total.tokens == TokenCounts(input: 6_000))
    #expect(overview.sessions[child.id]?.cost.hasPrice == false)
  }

  @Test("A coordinator without children has no total")
  func noFamily() async {
    let coordinator = Self.session("Coordinator")
    let service = Self.service([
      Self.file(coordinator, model: Self.priced, tokens: TokenCounts(input: 1_000))
    ])
    let overview = await service.overview(
      period: .allTime, grouping: .session, sessions: [coordinator.id],
      families: UsageFamily.families(of: [coordinator.id], among: [coordinator]).mapValues {
        $0.map(\.id)
      })
    #expect(overview.families.isEmpty)
    #expect(overview.sessions[coordinator.id]?.cost.total == 1)
  }

  private struct NoFetch: ModelPriceFetching {
    func fetchPriceList() async throws -> Data { throw CancellationError() }
  }

  private struct NoPrices: ModelPriceStore {
    func load() async -> ModelPriceList? { nil }
    func save(_ list: ModelPriceList) async throws {
      // The list given is the one used.
    }
  }
}
