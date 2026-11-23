import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeDomain
import VibeTerminalUI

@testable import VibeUI

/// The sessions kept behind the one shown draw no agent, effort or usage in their status bar.
///
/// Every session keeps its terminal in the window's stack, hidden, and a hidden view is still laid
/// out. The bar's three menus each measure every form they may take (#575): drawn in every
/// session's bar, each change in the window measured them all again, and a window of many
/// sessions spent its whole main thread laying them out, at rest.
@MainActor
@Suite("Hidden sessions draw no status bar menus", .serialized, .timeLimit(.minutes(2)))
struct HiddenStatusBarTests {
  private static let provider = WorkspaceProvider()

  @MainActor
  private final class Probe {
    var items: [StatusBarItemFrame] = []
  }

  @MainActor
  private struct Workspace {
    let model: AppModel
    let sessions: [WorkSession]
    let window: NSWindow
    let host: NSView
    let probe: Probe
    let folder: String

    func close() {
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(atPath: folder)
    }

    /// The bar's items drawn now, the hidden sessions' with the shown one's.
    func agentMenus() async -> Int {
      for _ in 0..<20 {
        host.layoutSubtreeIfNeeded()
        await Task.yield()
      }
      return probe.items.filter { $0.name == "agent" }.count
    }
  }

  private struct NeverReached: Error, CustomStringConvertible {
    let description: String
  }

  /// `count` running sessions, the first one shown in its terminal.
  private func workspace(sessions count: Int) async throws -> Workspace {
    _ = NSApplication.shared
    let folder = NSTemporaryDirectory().appending("vibe-hidden-bars-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let sessions = (0..<count).map { index in
      WorkSession(
        name: "Session \(index)", agent: SessionAgentConfiguration(providerID: "stub"),
        status: .closed, createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2), closedAt: Date(timeIntervalSince1970: 1),
        repositories: [RepositoryContext(path: folder)])
    }
    let supervisor = WorkspaceSupervisor()
    let repository = WorkspaceRepository(sessions: sessions)
    let registry = WorkspaceRegistry(providers: [Self.provider])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()))
    let plan = try await Self.provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: folder))
    for session in sessions {
      await launcher.launch(session: session, plan: plan)
    }
    await model.load()
    model.select(sessions[0].id)

    let probe = Probe()
    let host = NSHostingView(
      rootView: RootView(model: model)
        .environment(\.reportsStatusBarItems, true)
        .onPreferenceChange(StatusBarItemFrames.self) { items in
          MainActor.assumeIsolated { probe.items = items }
        })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    let workspace = Workspace(
      model: model, sessions: sessions, window: window, host: host, probe: probe, folder: folder)

    let clock = ContinuousClock()
    let start = clock.now
    while model.paneSessionIDs.count < count || probe.items.isEmpty {
      host.layoutSubtreeIfNeeded()
      guard clock.now - start < .seconds(45) else {
        workspace.close()
        throw NeverReached(
          description: "Never reached: \(count) panes and a bar on screen, "
            + "\(model.paneSessionIDs.count) panes and \(probe.items.count) items")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    return workspace
  }

  @Test("Of eight running sessions, the shown one alone draws its agent's menu")
  func shownSessionAlone() async throws {
    let workspace = try await workspace(sessions: 8)
    defer { workspace.close() }

    let first = await workspace.agentMenus()
    #expect(first == 1, "\(first) agent menus drawn")

    // Another session shown: its bar comes with it, and the first one's goes.
    workspace.model.select(workspace.sessions[5].id)
    let second = await workspace.agentMenus()
    #expect(second == 1, "\(second) agent menus drawn")
  }

  /// How long laying the window out takes with many sessions kept behind the one shown: each step
  /// of a resize lays out every one of them. A figure to compare before and after a change,
  /// printed, never asserted. Opt-in, like the other budgets.
  @Test(
    "Resizing a window of forty running sessions",
    .enabled(if: ProcessInfo.processInfo.environment["VIBE_PERFORMANCE"] != nil))
  func resizingCost() async throws {
    let workspace = try await workspace(sessions: 40)
    defer { workspace.close() }
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for step in 0..<40 {
        workspace.window.setContentSize(NSSize(width: 1400 - step * 10, height: 900))
        workspace.host.layoutSubtreeIfNeeded()
      }
    }
    print("HiddenStatusBarTests: 40 resizes of a window of 40 sessions laid out in \(elapsed)")
  }
}
