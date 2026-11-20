import Foundation
import VibeDomain

/// What a model costs per token, in dollars, at its public price (#574).
///
/// Coded with LiteLLM's own field names: the list kept on the Mac and the copy shipped with the
/// application read the way the public list does.
public struct ModelPrice: Hashable, Codable, Sendable {
  public var input: Decimal
  public var cacheRead: Decimal
  public var cacheWrite: Decimal
  public var output: Decimal

  public init(input: Decimal, cacheRead: Decimal, cacheWrite: Decimal, output: Decimal) {
    self.input = input
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.output = output
  }

  private enum CodingKeys: String, CodingKey {
    case input = "input_cost_per_token"
    case output = "output_cost_per_token"
    case cacheRead = "cache_read_input_token_cost"
    case cacheWrite = "cache_creation_input_token_cost"
  }

  /// A model whose cache has no price of its own pays it as input: no discount is made up.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    input = try container.decode(Decimal.self, forKey: .input)
    output = try container.decode(Decimal.self, forKey: .output)
    cacheRead = try container.decodeIfPresent(Decimal.self, forKey: .cacheRead) ?? input
    cacheWrite = try container.decodeIfPresent(Decimal.self, forKey: .cacheWrite) ?? input
  }
}

/// The public prices of the models, and when they were read.
///
/// `{ "version": 1, "fetchedAt": …, "prices": { "claude-sonnet-4-5": {…} } }`: the list kept on
/// the Mac and the copy shipped with the application.
public struct ModelPriceList: Hashable, Codable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let fetchedAt: Date
  public let prices: [String: ModelPrice]
  /// The latest dated name of each model, by its name without a date: built once, for the
  /// models an agent names without a date.
  private let dated: [String: String]

  public init(fetchedAt: Date, prices: [String: ModelPrice]) {
    self.init(version: Self.currentVersion, fetchedAt: fetchedAt, prices: prices)
  }

  private init(version: Int, fetchedAt: Date, prices: [String: ModelPrice]) {
    self.version = version
    self.fetchedAt = fetchedAt
    self.prices = prices
    var dated: [String: String] = [:]
    for name in prices.keys {
      let undated = Self.withoutDate(name)
      guard undated != name else { continue }
      dated[undated] = max(dated[undated] ?? name, name)
    }
    self.dated = dated
  }

  private enum CodingKeys: String, CodingKey {
    case version, fetchedAt, prices
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decode(Int.self, forKey: .version),
      fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
      prices: try container.decode([String: ModelPrice].self, forKey: .prices))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(fetchedAt, forKey: .fetchedAt)
    try container.encode(prices, forKey: .prices)
  }

  /// The price of a model, as an agent named it. Tried in order: the name itself, the name
  /// without its date (`claude-opus-4-5-20251101` ↔ `claude-opus-4-5`), then either with its
  /// provider's prefix (`anthropic/…`). Nothing else is guessed: a close name is another model.
  /// `nil` for the CLI's default model, whose name nobody knows.
  public func price(for model: String?, providerID: String) -> ModelPrice? {
    guard let model, !model.isEmpty else { return nil }
    var names = [model]
    let undated = Self.withoutDate(model)
    if undated != model { names.append(undated) }
    if let prefix = Self.providerPrefixes[providerID] {
      names += names.map { "\(prefix)/\($0)" }
    }
    for name in names {
      if let price = prices[name] { return price }
    }
    // The other way round: the agent named the model without a date, the list only with one. A
    // dated name is never priced as another date of it.
    guard undated == model else { return nil }
    return dated[undated].flatMap { prices[$0] }
  }

  /// The prefix LiteLLM gives each agent's models. By identifier: the application layer does
  /// not know the agents' modules.
  static let providerPrefixes: [String: String] = [
    "claude-code": "anthropic",
    "codex": "openai",
    "antigravity": "gemini",
  ]

  /// `claude-opus-4-5-20251101` and `gpt-5-2025-08-07` lose their date.
  static func withoutDate(_ model: String) -> String {
    for pattern in [#"-\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#] {
      if let range = model.range(of: pattern, options: .regularExpression) {
        return String(model[..<range.lowerBound])
      }
    }
    return model
  }

  /// The prices of LiteLLM's `model_prices_and_context_window.json`: its chat models that have
  /// a price for input and output. Images, embeddings and the rest are left out, as is an entry
  /// that cannot be read. Throws when there is no such model in it — not the list, or broken.
  public static func parseLiteLLM(_ data: Data, fetchedAt: Date) throws -> ModelPriceList {
    let entries = try JSONDecoder().decode([String: LossyEntry].self, from: data)
    var prices: [String: ModelPrice] = [:]
    for (name, entry) in entries {
      guard let entry = entry.value, entry.mode == "chat" || entry.mode == "responses" else {
        continue
      }
      prices[name] = entry.price
    }
    guard !prices.isEmpty else { throw ModelPriceListError.noPrice }
    return ModelPriceList(fetchedAt: fetchedAt, prices: prices)
  }

  private struct LossyEntry: Decodable {
    let value: (mode: String?, price: ModelPrice)?

    init(from decoder: any Decoder) throws {
      let mode = try? decoder.container(keyedBy: ModeKey.self).decodeIfPresent(
        String.self, forKey: .mode)
      value = (try? ModelPrice(from: decoder)).map { (mode, $0) }
    }

    private enum ModeKey: String, CodingKey {
      case mode
    }
  }
}

public enum ModelPriceListError: Error, Equatable {
  /// The answer holds no price of a chat model.
  case noPrice
  /// The answer is not the list: a status other than 200, or too large.
  case unexpectedResponse
}

/// Which model a cost belongs to: an agent's, as its CLI named it. `nil` for the CLI's default.
public struct UsageModelKey: Hashable, Sendable {
  public var providerID: String
  public var model: String?

  public init(providerID: String, model: String?) {
    self.providerID = providerID
    self.model = model
  }
}

/// What tokens would have cost at the models' public prices: an API equivalent (#574). On a
/// subscription, it is what the work would have cost paid by the token, not what was paid.
///
/// The tokens are already split the way prices are: Codex's input leaves out what it read from
/// the cache, and its reasoning is part of its output, never counted twice. Claude Code's cache
/// writes are paid at the five-minute price, the long-context price is ignored: the `≈` the
/// interface puts before every cost covers both.
public enum UsageCost {
  public struct Estimate: Hashable, Sendable {
    /// What the models with a price cost together.
    public var total: Decimal
    public var priced: [UsageModelKey: Decimal]
    /// The models without a known price, left out of the total rather than counted as free.
    public var unpriced: [UsageModelKey]

    public init(
      total: Decimal = 0, priced: [UsageModelKey: Decimal] = [:], unpriced: [UsageModelKey] = []
    ) {
      self.total = total
      self.priced = priced
      self.unpriced = unpriced
    }

    /// Whether any model of it has a price: without one, there is no cost to say.
    public var hasPrice: Bool { !priced.isEmpty }
  }

  public static func cost(of tokens: TokenCounts, at price: ModelPrice) -> Decimal {
    Decimal(tokens.input) * price.input + Decimal(tokens.cacheRead) * price.cacheRead
      + Decimal(tokens.cacheWrite) * price.cacheWrite + Decimal(tokens.output) * price.output
  }

  /// The cost of each model's tokens, and the total of those that have a price. A model that
  /// reported no token is neither.
  public static func estimate(
    _ rows: [(model: UsageModelKey, tokens: TokenCounts)], prices: ModelPriceList?
  ) -> Estimate {
    var estimate = Estimate()
    for row in rows where !row.tokens.isZero {
      if let price = prices?.price(for: row.model.model, providerID: row.model.providerID) {
        let cost = cost(of: row.tokens, at: price)
        estimate.priced[row.model, default: 0] += cost
        estimate.total += cost
      } else if !estimate.unpriced.contains(row.model) {
        estimate.unpriced.append(row.model)
      }
    }
    return estimate
  }
}
