import CompanionCore
import Foundation
import Testing

@Suite("The agent a folder proposes on the phone's new session (#634)")
struct NewSessionAgentProposalTests {
  private let options = RemoteNewSessionOptions(
    folders: ["/work/api", "/work/web"],
    agents: [
      RemoteAgent(id: "claude-code", name: "Claude Code", models: []),
      RemoteAgent(id: "codex", name: "Codex", models: []),
    ],
    folderAgents: ["/work/api": "codex", "/work/web": "claude-code", "/work/old": "gone"])

  @Test("Each folder chosen brings its agent, a browsed one through its listing")
  func followsTheFolder() {
    let proposal = NewSessionAgentProposal()
    let listings = [
      "/work/other": RemoteFolderListing(path: "/work/other", folders: [], agentID: "codex")
    ]
    #expect(proposal.agent(forFolder: "/work/api", options: options) == "codex")
    #expect(proposal.agent(forFolder: "/work/web", options: options) == "claude-code")
    #expect(
      proposal.agent(forFolder: "/work/other", options: options, listings: listings) == "codex")
  }

  @Test("A folder without an agent, or with one the phone was not offered, changes nothing")
  func unknownLeavesTheAgent() {
    let proposal = NewSessionAgentProposal()
    #expect(proposal.agent(forFolder: "/work/new", options: options) == nil)
    #expect(proposal.agent(forFolder: "/work/old", options: options) == nil)
    var older = options
    older.folderAgents = nil
    #expect(proposal.agent(forFolder: "/work/api", options: older) == nil)
  }

  @Test("Once the user picks, and on a form that came back, the folder no longer changes it")
  func userChoiceStops() {
    var proposal = NewSessionAgentProposal()
    proposal.userChose()
    #expect(!proposal.followsTheFolder)
    #expect(proposal.agent(forFolder: "/work/api", options: options) == nil)
    #expect(
      NewSessionAgentProposal(userChose: true).agent(forFolder: "/work/api", options: options)
        == nil)
  }

  @Test(
    "An offer and a listing from an older Mac decode without the agents, and round-trip with them")
  func transport() throws {
    let oldOffer = Data(
      #"{"folders":["/a"],"agents":[],"symbols":[],"colors":[],"templates":[]}"#.utf8)
    #expect(
      try JSONDecoder().decode(RemoteNewSessionOptions.self, from: oldOffer).folderAgents == nil)
    let oldListing = Data(#"{"path":"/a","folders":["b"],"isUnreadable":false}"#.utf8)
    #expect(try JSONDecoder().decode(RemoteFolderListing.self, from: oldListing).agentID == nil)
    let messages: [RemoteMessage] = [
      .newSessionOffer(options),
      .folderListing(RemoteFolderListing(path: "/a", folders: ["b"], agentID: "codex")),
    ]
    for message in messages {
      let data = try JSONEncoder().encode(message)
      #expect(try JSONDecoder().decode(RemoteMessage.self, from: data) == message)
    }
  }
}
