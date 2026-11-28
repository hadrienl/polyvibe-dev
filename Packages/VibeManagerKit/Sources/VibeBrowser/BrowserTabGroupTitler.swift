import Foundation
import VibeDomain

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// What a group's name is made from (#666): a tab's title, and where it is — host and path, never
/// the query, which may hold what is nobody's business.
public struct BrowserTabGroupTitlePage: Sendable, Equatable {
  public let title: String
  public let host: String
  public let path: String

  public init(title: String, host: String, path: String) {
    self.title = title
    self.host = host
    self.path = path
  }

  @MainActor
  init(tab: BrowserTabModel) {
    self.init(title: tab.title, host: tab.url.host() ?? "", path: tab.url.path())
  }
}

/// Names a group of tabs from its pages, on this Mac (#666). `nil`: no name, the group stays
/// « Group N ». Never a remote service.
public protocol BrowserTabGroupTitler: Sendable {
  func title(for pages: [BrowserTabGroupTitlePage]) async -> String?
}

/// Apple Intelligence's on-device model (`FoundationModels`, macOS 26 and later): the common
/// subject of the tabs, in a few words, in the application's language. On an earlier macOS, with
/// Apple Intelligence off or not ready, or past five seconds: no name.
public struct AppleIntelligenceGroupTitler: BrowserTabGroupTitler {
  /// In English, as the instructions are: « French ».
  let language: String
  let timeout: Duration

  /// `nil` where the model cannot exist: before macOS 26, or built without its SDK. Whether
  /// Apple Intelligence is on is asked at each name, as the user may turn it on meanwhile.
  public static func onThisMac(language: String) -> AppleIntelligenceGroupTitler? {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *) else { return nil }
      return AppleIntelligenceGroupTitler(language: language, timeout: .seconds(5))
    #else
      return nil
    #endif
  }

  /// The application's language, in English, for the instructions: « French ».
  public static func applicationLanguage(bundle: Bundle = .main) -> String {
    let code = bundle.preferredLocalizations.first ?? "en"
    return Locale(identifier: "en").localizedString(forIdentifier: code) ?? "English"
  }

  public func title(for pages: [BrowserTabGroupTitlePage]) async -> String? {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *), !pages.isEmpty else { return nil }
      let language = language
      let timeout = timeout
      // Off the main actor: the model takes its time, the sidebar does not wait for it.
      return await Task.detached(priority: .utility) {
        await OnDeviceGroupTitle.make(pages: pages, language: language, timeout: timeout)
      }.value
    #else
      return nil
    #endif
  }
}

#if canImport(FoundationModels)
  @available(macOS 26, *)
  enum OnDeviceGroupTitle {
    @Generable
    struct Answer {
      @Guide(description: "The subject the tabs share, in one to four words.")
      var title: String
    }

    static func instructions(language: String) -> String {
      """
      You name a group of browser tabs. Give the subject the tabs share, in one to four words, \
      in \(language). Do not copy the title of a tab. No quotes, no punctuation at the end.
      """
    }

    static func prompt(_ pages: [BrowserTabGroupTitlePage]) -> String {
      pages.map { page in
        let title = page.title.isEmpty ? "(untitled)" : page.title
        return "- \(title) — \(page.host)\(page.path)"
      }.joined(separator: "\n")
    }

    static func make(
      pages: [BrowserTabGroupTitlePage], language: String, timeout: Duration
    ) async -> String? {
      guard case .available = SystemLanguageModel.default.availability else { return nil }
      return await withTaskGroup(of: String?.self) { group in
        group.addTask {
          let session = LanguageModelSession(instructions: instructions(language: language))
          let response = try? await session.respond(
            to: prompt(pages), generating: Answer.self)
          return response?.content.title
        }
        group.addTask {
          try? await Task.sleep(for: timeout)
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }
  }
#endif
