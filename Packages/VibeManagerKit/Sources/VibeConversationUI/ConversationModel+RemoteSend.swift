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
    if !files.isEmpty { attach(files, focusing: false) }
    draft = text
    let sent = await send()
    let quoted = sent && reply != nil && replyTarget == nil
    attachments.filter(files.contains).forEach(removeAttachment)
    if !keptFiles.isEmpty { attach(keptFiles, focusing: false) }
    if draft == text || (sent && draft.isEmpty) { draft = kept }
    // A newly chosen Mac passage is not the temporary phone passage.
    if replyTarget == installedReply { cancelReply() }
    restoreReply(keptReply)
    return (sent, quoted)
  }
}
