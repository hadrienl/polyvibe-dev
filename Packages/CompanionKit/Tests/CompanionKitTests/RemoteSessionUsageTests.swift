import CompanionCore
import Foundation
import Testing

@Suite("A session's usage on the phone (#631)")
struct RemoteSessionUsageTests {
  @Test("Converted costs, unknown prices and every child survive the wire")
  func roundTrip() throws {
    let cost = RemoteQuotaCost(
      amount: Decimal(string: "4.82")!, hasPrice: true, leavesOutUnpriced: true)
    let usage = RemoteSessionUsage(
      sessionID: "parent", currency: "EUR",
      context: RemoteUsageContext(usedTokens: 144_000, windowSize: 200_000, percentUsed: 72),
      runningTime: 3_660, tokens: 980_000, cost: cost,
      models: [
        RemoteModelCost(providerName: "Claude Code", model: "opus", amount: 4.82),
        RemoteModelCost(providerName: "Codex", model: "future", amount: nil),
      ],
      family: RemoteFamilyUsage(
        cost: cost, children: [.init(id: "child", name: "Tests", depth: 1, cost: cost)]))
    let messages: [RemoteMessage] = [.sessionUsage(usage), .show(sessionID: nil)]
    var decoder = RemoteFrame.Decoder()
    #expect(try decoder.append(messages.map(RemoteFrame.encode).reduce(Data(), +)) == messages)
    #expect(usage.hasFigures)
  }

  @Test("An older decoder skips the new case and keeps reading the following frames")
  func oldDecoder() throws {
    // The framed JSON of an unknown case has the same shape a v4 decoder sees for sessionUsage.
    let body = Data(#"{"futureSessionUsage":{"_0":{"sessionID":"parent"}}}"#.utf8)
    let count = UInt32(body.count)
    let header = Data([
      UInt8(count >> 24), UInt8((count >> 16) & 255),
      UInt8((count >> 8) & 255), UInt8(count & 255),
    ])
    var decoder = RemoteFrame.Decoder()
    #expect(
      try decoder.append(header + body + RemoteFrame.encode(.show(sessionID: nil)))
        == [.show(sessionID: nil)])
  }

  @Test("An unknown context window falls back to time, and tracking off hides previous figures")
  func fallback() {
    var usage = RemoteSessionUsage(
      sessionID: "s", currency: "USD",
      context: RemoteUsageContext(usedTokens: 10_000, windowSize: nil, percentUsed: nil),
      runningTime: 3_661)
    #expect(
      RemoteUsageFormat.contextOrTime(usage, locale: Locale(identifier: "fr_FR"))
        == RemoteUsageFormat.duration(3_661))
    usage.context?.percentUsed = 55
    #expect(RemoteUsageFormat.contextOrTime(usage, locale: Locale(identifier: "en_US")) == "55%")
    usage.isTrackingOn = false
    #expect(!usage.hasFigures)
    #expect(!RemoteSessionUsage(sessionID: "s", currency: "USD").hasFigures)
  }
}
