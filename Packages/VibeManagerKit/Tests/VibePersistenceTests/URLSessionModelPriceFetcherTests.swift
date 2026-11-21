import Foundation
import Testing
import VibeApplication

@testable import VibePersistence

/// Answers in place of the network, by the URL's path: one answer per test, tests side by side.
private final class PriceServer: URLProtocol, @unchecked Sendable {
  enum Answer {
    case status(Int, Data)
    /// Never answers: the request waits for its timeout.
    case silence
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var answers: [String: Answer] = [:]
  nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]

  static func answer(_ answer: Answer) -> URL {
    let path = "/\(UUID().uuidString)"
    lock.withLock { answers[path] = answer }
    return URL(string: "https://prices.invalid\(path)")!
  }

  static func request(to url: URL) -> URLRequest? {
    lock.withLock { requests[url.path] }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let answer = Self.lock.withLock {
      Self.requests[url.path] = request
      return Self.answers[url.path]
    }
    guard case .status(let code, let body) = answer else { return }
    let response = HTTPURLResponse(
      url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    // Nothing is under way to stop: an answer is given whole, or never.
  }
}

@Suite("Fetching the public list of prices (#574)", .timeLimit(.minutes(1)))
struct URLSessionModelPriceFetcherTests {
  private func fetcher(
    _ url: URL, maximumSize: Int = 1_024, requestTimeout: TimeInterval = 15
  ) -> URLSessionModelPriceFetcher {
    URLSessionModelPriceFetcher(
      url: url, maximumSize: maximumSize, requestTimeout: requestTimeout,
      protocolClasses: [PriceServer.self])
  }

  @Test("The list comes back as sent, asked for with nothing of the user")
  func fetched() async throws {
    let body = Data(#"{"claude-sonnet-4-5": {}}"#.utf8)
    let url = PriceServer.answer(.status(200, body))
    #expect(try await fetcher(url).fetchPriceList() == body)
    let request = try #require(PriceServer.request(to: url))
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "VibeManager")
    #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
  }

  @Test("An answer other than 200 is refused")
  func notOK() async {
    let url = PriceServer.answer(.status(429, Data("rate limited".utf8)))
    await #expect(throws: ModelPriceListError.unexpectedResponse) {
      try await fetcher(url).fetchPriceList()
    }
  }

  @Test("An answer past the size limit is given up")
  func tooLarge() async {
    let url = PriceServer.answer(.status(200, Data(repeating: 0x20, count: 200_000)))
    await #expect(throws: ModelPriceListError.unexpectedResponse) {
      try await fetcher(url, maximumSize: 100_000).fetchPriceList()
    }
  }

  @Test("A server that never answers is given up at the timeout")
  func silent() async {
    let url = PriceServer.answer(.silence)
    await #expect(throws: (any Error).self) {
      try await fetcher(url, requestTimeout: 0.5).fetchPriceList()
    }
  }
}
