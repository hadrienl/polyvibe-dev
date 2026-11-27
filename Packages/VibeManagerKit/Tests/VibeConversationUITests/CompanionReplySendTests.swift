import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@Suite("The phone's quotation leaves the Mac's composer alone (#633)")
@MainActor
struct CompanionReplySendTests {
  private func model(running: Bool = true) -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { _ in }
    model.processRunning = { running }
    model.promptFormat = AgentPromptFormat(queueKey: [0x09], submitDelay: .zero)
    model.apply(ConversationSnapshot(availability: .available))
    model.draft = "Mac draft"
    model.reply(to: "Mac passage", author: .user, date: nil, blockID: "mac")
    return model
  }

  private var target: ReplyTarget {
    ReplyTarget(
      quote: ReplyQuote(excerpt: "Phone passage", author: .agent, date: nil), blockID: "phone")
  }

  @Test("The exact Mac formatter composes the phone's quote; its own draft and quote return")
  func send() async {
    let model = model()
    let kept = model.replyTarget
    let result = await model.sendFromCompanion("Continue", files: [], reply: target)
    #expect(result.sent && result.quoted)
    #expect(model.echoes.last?.text == ReplyQuote.compose(target.quote, message: "Continue"))
    #expect(model.draft == "Mac draft")
    #expect(model.replyTarget == kept)
  }

  @Test("A rejected send restores both Mac draft and quote")
  func rejected() async {
    let model = model(running: false)
    let kept = model.replyTarget
    let result = await model.sendFromCompanion("Continue", files: [], reply: target)
    #expect(!result.sent && !result.quoted)
    #expect(model.draft == "Mac draft")
    #expect(model.replyTarget == kept)
  }

  @Test("A CLI command is not quoted, and the phone is told to retain its target")
  func command() async {
    let model = model()
    let kept = model.replyTarget
    let result = await model.sendFromCompanion("/compact", files: [], reply: target)
    #expect(result.sent && !result.quoted)
    #expect(model.echoes.last?.text == "/compact")
    #expect(model.draft == "Mac draft")
    #expect(model.replyTarget == kept)
  }

  @Test("An ordinary phone message never takes the quote left on the Mac")
  func ordinary() async {
    let model = model()
    let kept = model.replyTarget
    let result = await model.sendFromCompanion("Hello", files: [], reply: nil)
    #expect(result.sent && !result.quoted)
    #expect(model.echoes.last?.text == "Hello")
    #expect(model.replyTarget == kept)
  }
  @Test("Phone files join its quotation without taking the Mac's attachments")
  func attachments() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = folder.appendingPathComponent("mac.txt")
    let phone = folder.appendingPathComponent("phone.txt")
    try Data("Mac".utf8).write(to: mac)
    try Data("Phone".utf8).write(to: phone)
    let model = model()
    model.attach([mac], focusing: false)
    let result = await model.sendFromCompanion("Read this", files: [phone], reply: target)
    #expect(result.sent && result.quoted)
    #expect(model.attachments == [mac])
    #expect(model.echoes.last?.text.contains("Phone passage") == true)
    #expect(model.echoes.last?.text.contains("mac.txt") == false)
    #expect(model.draft == "Mac draft")
  }

  @Test("Phone files are sent even when the Mac's own draft is a shell command")
  func filesBesideShellDraft() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let phone = folder.appendingPathComponent("phone.txt")
    try Data("Phone".utf8).write(to: phone)
    let model = model()
    model.promptFormat = AgentPromptFormat(
      queueKey: [0x09], submitDelay: .zero,
      shellEntry: ShellEntry(switchDelay: .zero, chunkDelay: .zero))
    model.draft = "!ls"
    let result = await model.sendFromCompanion("Read this", files: [phone], reply: nil)
    #expect(result.sent)
    #expect(model.echoes.last?.attachments == [phone])
    #expect(model.draft == "!ls")
    #expect(model.attachments.isEmpty)
  }
}
