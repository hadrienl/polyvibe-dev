import Foundation

extension ConversationModel {
  /// A phone's message uses the same submission rules, without borrowing the Mac's draft.
  /// The caller serializes remote sends to this conversation.
  public func sendFromCompanion(_ text: String, files: [URL], reply: ReplyTarget?) async
    -> (sent: Bool, quoted: Bool)
  {
    let kept = draft
    let keptFiles = attachments
    keptFiles.forEach(removeAttachment)
    let keptReply = setReplyAside()
    restoreReply(reply)
    let installedReply = replyTarget
    // The phone's text first: files join it, never a Mac draft in shell mode that it replaces.
    draft = text
    if !files.isEmpty { attach(files, focusing: false) }
    let composed = draft
    let sent = await send()
    let quoted = sent && reply != nil && replyTarget == nil
    attachments.filter(files.contains).forEach(removeAttachment)
    if draft == composed || (sent && draft.isEmpty) { draft = kept }
    // Rejoined to the Mac's own draft, once it is back.
    if !keptFiles.isEmpty { attach(keptFiles, focusing: false) }
    // A newly chosen Mac passage is not the temporary phone passage.
    if replyTarget == installedReply { cancelReply() }
    restoreReply(keptReply)
    return (sent, quoted)
  }
}
