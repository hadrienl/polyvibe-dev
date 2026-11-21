import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

@Suite("The model prices kept on the Mac (#574)")
struct FileModelPriceStoreTests {
  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("VibeManagerPrices-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Prices", isDirectory: true)
  }

  @Test("A list saved reads back whole, in a file only its owner reads")
  func roundTrip() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let store = FileModelPriceStore(directory: directory)
    #expect(await store.load() == nil)
    let list = ModelPriceList(
      fetchedAt: Date(timeIntervalSince1970: 1_790_000_000),
      prices: [
        "claude-sonnet-4-5": ModelPrice(
          input: Decimal(string: "0.000003")!, cacheRead: Decimal(string: "0.0000003")!,
          cacheWrite: Decimal(string: "0.00000375")!, output: Decimal(string: "0.000015")!)
      ])
    try await store.save(list)
    #expect(await store.load() == list)
    let file = directory.appendingPathComponent("model-prices.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test("A file of another version, or broken, is not read")
  func unreadable() async throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("model-prices.json")
    try Data(#"{"version": 2, "fetchedAt": "2026-11-20T10:00:00Z", "prices": {}}"#.utf8)
      .write(to: file)
    #expect(await FileModelPriceStore(directory: directory).load() == nil)
    try Data("{".utf8).write(to: file)
    #expect(await FileModelPriceStore(directory: directory).load() == nil)
  }

  @Test("The shipped copy reads, prices written as LiteLLM writes them included (5E-7)")
  func bundledCopy() throws {
    let list = try #require(FileModelPriceStore.bundled())
    #expect(list.prices.count > 50)
    let sonnet = try #require(list.price(for: "claude-sonnet-4-5", providerID: "claude-code"))
    #expect(sonnet.input == Decimal(string: "0.000003"))
    #expect(sonnet.cacheRead == Decimal(string: "0.0000003"))
    #expect(list.price(for: "gpt-5", providerID: "codex") != nil)
  }
}
