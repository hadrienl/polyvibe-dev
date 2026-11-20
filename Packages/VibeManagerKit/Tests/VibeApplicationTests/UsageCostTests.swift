import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Dollars per million tokens, the way prices are published.
private func perMillion(_ value: Decimal) -> Decimal { value / 1_000_000 }

private let sonnet = ModelPrice(
  input: perMillion(3), cacheRead: perMillion(Decimal(string: "0.3")!),
  cacheWrite: perMillion(Decimal(string: "3.75")!), output: perMillion(15))
private let gpt = ModelPrice(
  input: perMillion(Decimal(string: "1.25")!), cacheRead: perMillion(Decimal(string: "0.125")!),
  cacheWrite: perMillion(Decimal(string: "1.25")!), output: perMillion(10))

private let list = ModelPriceList(
  fetchedAt: Date(timeIntervalSince1970: 0),
  prices: [
    "claude-sonnet-4-5": sonnet,
    "claude-sonnet-4-5-20250929": sonnet,
    "openai/gpt-5.1-codex": gpt,
    "claude-haiku-4-5-20251001": sonnet,
  ])

@Suite("The cost of tokens at public prices (#574)")
struct UsageCostTests {
  @Test("A Claude model pays its input, cache read, cache write and output, each at its price")
  func claudeWithCache() {
    let tokens = TokenCounts(
      input: 1_000_000, cacheRead: 10_000_000, cacheWrite: 200_000, output: 100_000)
    // 3 + 10 × 0.3 + 0.2 × 3.75 + 0.1 × 15
    #expect(UsageCost.cost(of: tokens, at: sonnet) == Decimal(string: "8.25"))
  }

  @Test("Codex's reasoning is part of its output, never counted twice")
  func codexReasoning() {
    let tokens = TokenCounts(input: 1_000_000, cacheRead: 0, output: 200_000, reasoning: 150_000)
    // 1.25 + 0.2 × 10: the 150 k of reasoning are inside the 200 k of output.
    #expect(UsageCost.cost(of: tokens, at: gpt) == Decimal(string: "3.25"))
  }

  @Test("A model without a price is said, and left out of the total rather than counted as free")
  func unpricedModel() {
    let known = UsageModelKey(providerID: "claude-code", model: "claude-sonnet-4-5")
    let unknown = UsageModelKey(providerID: "claude-code", model: "mistral-maison")
    let estimate = UsageCost.estimate(
      [
        (known, TokenCounts(input: 1_000_000)),
        (unknown, TokenCounts(input: 5_000_000)),
      ], prices: list)
    #expect(estimate.total == 3)
    #expect(estimate.priced == [known: 3])
    #expect(estimate.unpriced == [unknown])
    #expect(estimate.hasPrice)
  }

  @Test("The CLI's default model has no name, and so no price")
  func defaultModel() {
    let key = UsageModelKey(providerID: "claude-code", model: nil)
    let estimate = UsageCost.estimate([(key, TokenCounts(input: 1_000))], prices: list)
    #expect(estimate.unpriced == [key])
    #expect(!estimate.hasPrice)
    #expect(estimate.total == 0)
  }

  @Test("Without any list, every model is without a price; a model with no token is neither")
  func noList() {
    let used = UsageModelKey(providerID: "codex", model: "gpt-5.1-codex")
    let idle = UsageModelKey(providerID: "codex", model: "gpt-5")
    let estimate = UsageCost.estimate([(used, TokenCounts(output: 10)), (idle, .zero)], prices: nil)
    #expect(estimate.unpriced == [used])
    #expect(estimate.priced.isEmpty)
  }

  @Test("The aggregator adds the cost of each bucket to its row, and says what had no price")
  func aggregatorCost() {
    let session = SessionID()
    let day = LocalDay(year: 2026, month: 11, day: 20)
    let buckets = [
      TokenUsageBucket(
        sessionID: session, providerID: "claude-code", model: "claude-sonnet-4-5", day: day,
        tokens: TokenCounts(input: 1_000_000), responses: 1),
      TokenUsageBucket(
        sessionID: session, providerID: "claude-code", model: "claude-sonnet-4-5",
        day: LocalDay(year: 2026, month: 11, day: 19),
        tokens: TokenCounts(output: 100_000), responses: 1),
      TokenUsageBucket(
        sessionID: session, providerID: "claude-code", model: "mistral-maison", day: day,
        tokens: TokenCounts(input: 1), responses: 1),
    ]
    let report = UsageAggregator.report(
      runs: [], tokens: buckets, period: nil, grouping: .session, now: Date(),
      calendar: Calendar(identifier: .gregorian),
      cost: { bucket in
        list.price(for: bucket.model, providerID: bucket.providerID).map {
          UsageCost.cost(of: bucket.tokens, at: $0)
        }
      })
    #expect(report.rows.count == 1)
    #expect(report.total.cost == Decimal(string: "4.5"))
    #expect(report.total.hasPricedTokens)
    #expect(report.total.hasUnpricedTokens)
  }
}

@Suite("Finding a model's price (#574)")
struct ModelPriceListTests {
  @Test("The model's own name first")
  func exact() {
    #expect(list.price(for: "claude-sonnet-4-5", providerID: "claude-code") == sonnet)
  }

  @Test("A dated name finds the undated one, and the other way round")
  func dateSuffix() {
    #expect(list.price(for: "claude-sonnet-4-5-20991231", providerID: "claude-code") == sonnet)
    #expect(list.price(for: "claude-haiku-4-5", providerID: "claude-code") == sonnet)
    // A dated name the list does not have is not priced as another date of the model.
    #expect(list.price(for: "claude-haiku-4-5-20240101", providerID: "claude-code") == nil)
    #expect(ModelPriceList.withoutDate("gpt-5-2025-08-07") == "gpt-5")
    #expect(ModelPriceList.withoutDate("claude-opus-4-5-20251101") == "claude-opus-4-5")
  }

  @Test("The provider's prefix, for a list that only knows the model under it")
  func providerPrefix() {
    #expect(list.price(for: "gpt-5.1-codex", providerID: "codex") == gpt)
    #expect(list.price(for: "gpt-5.1-codex", providerID: "claude-code") == nil)
  }

  @Test("A close name is another model: nothing is guessed")
  func closeName() {
    #expect(list.price(for: "claude-sonnet-4-6", providerID: "claude-code") == nil)
    #expect(list.price(for: "claude-sonnet-4", providerID: "claude-code") == nil)
    #expect(list.price(for: "gpt-5.1-codex-max", providerID: "codex") == nil)
    #expect(list.price(for: "", providerID: "codex") == nil)
  }
}

@Suite("Reading LiteLLM's list of prices (#574)")
struct LiteLLMPriceListTests {
  /// Entries as LiteLLM writes them, the sample of its own format included.
  private let excerpt = Data(
    #"""
    {
      "sample_spec": {
        "input_cost_per_token": 0.0, "output_cost_per_token": 0.0,
        "litellm_provider": "one of https://docs.litellm.ai/docs/providers",
        "mode": "one of: chat, embedding, completion, image_generation"
      },
      "claude-sonnet-4-5-20250929": {
        "cache_creation_input_token_cost": 3.75e-06, "cache_read_input_token_cost": 3e-07,
        "input_cost_per_token": 3e-06, "litellm_provider": "anthropic",
        "max_input_tokens": 200000, "mode": "chat", "output_cost_per_token": 1.5e-05,
        "supports_vision": true
      },
      "gpt-5.1-codex": {
        "cache_read_input_token_cost": 1.25E-7, "input_cost_per_token": 1.25e-06,
        "litellm_provider": "openai", "mode": "responses", "output_cost_per_token": 1e-05
      },
      "text-embedding-3-small": {
        "input_cost_per_token": 2e-08, "litellm_provider": "openai", "mode": "embedding",
        "output_cost_per_token": 0.0
      },
      "dall-e-3": { "litellm_provider": "openai", "mode": "image_generation" },
      "half-written": { "mode": "chat", "input_cost_per_token": "free" }
    }
    """#.utf8)

  @Test("A real excerpt: the chat models with their four prices, nothing else")
  func excerptOfTheList() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let parsed = try ModelPriceList.parseLiteLLM(excerpt, fetchedAt: date)
    #expect(Set(parsed.prices.keys) == ["claude-sonnet-4-5-20250929", "gpt-5.1-codex"])
    #expect(parsed.prices["claude-sonnet-4-5-20250929"] == sonnet)
    #expect(parsed.fetchedAt == date)
  }

  @Test("A cache without a price of its own is paid as input")
  func missingCacheField() throws {
    let parsed = try ModelPriceList.parseLiteLLM(excerpt, fetchedAt: Date())
    let codex = try #require(parsed.prices["gpt-5.1-codex"])
    #expect(codex.cacheRead == perMillion(Decimal(string: "0.125")!))
    #expect(codex.cacheWrite == codex.input)
  }

  @Test("Broken JSON, or a list without any chat model, is refused")
  func refused() {
    #expect(throws: (any Error).self) {
      try ModelPriceList.parseLiteLLM(Data("{\"claude\": ".utf8), fetchedAt: Date())
    }
    #expect(throws: ModelPriceListError.noPrice) {
      try ModelPriceList.parseLiteLLM(Data("{\"a\": {\"mode\": \"embedding\"}}".utf8), fetchedAt: Date())
    }
    #expect(throws: (any Error).self) {
      try ModelPriceList.parseLiteLLM(Data("<html>rate limited</html>".utf8), fetchedAt: Date())
    }
  }
}
