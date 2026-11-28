import Foundation
import Testing

@testable import VibeUI

@Suite("A group of web tabs without a title says how many and where from (#666)")
struct BrowserTabGroupSummaryTests {
  @Test("The site is the first tab's that has one: a new tab or a file does not name it")
  func site() {
    let urls = [
      URL(string: "about:blank")!,
      URL(fileURLWithPath: "/tmp/page.html"),
      URL(string: "https://github.com/hadrienl/polyvibe-dev/pull/664")!,
      URL(string: "https://docs.github.com/actions")!,
    ]
    #expect(BrowserTabGroupSummary.site(of: urls) == "github.com")
    #expect(BrowserTabGroupSummary.site(of: [URL(string: "http://localhost:4321/")!]) != nil)
    #expect(BrowserTabGroupSummary.site(of: [URL(string: "about:blank")!]) == nil)
    #expect(BrowserTabGroupSummary.site(of: []) == nil)
  }

  @Test("VoiceOver hears how many tabs, and the site when there is one")
  func accessibilityLabel() {
    #expect(
      BrowserTabGroupSummary.accessibilityLabel(count: 3, site: "github.com")
        == "Group of 3 tabs, github.com")
    #expect(BrowserTabGroupSummary.accessibilityLabel(count: 1, site: nil) == "Group of 1 tab")
  }

  @Test("A collapsed group counts its tabs")
  func count() {
    #expect(BrowserTabGroupSummary.count(2) == "2 tabs")
    #expect(BrowserTabGroupSummary.count(1) == "1 tab")
  }
}
