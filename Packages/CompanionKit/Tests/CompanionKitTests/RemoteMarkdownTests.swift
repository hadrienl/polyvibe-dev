import CompanionCore
import Testing

@Test("Prose and fenced code blocks come apart, in reading order")
func markdownSegments() {
  let text = "Log in first:\n\n```bash\n! gcloud auth login\n```\n\nThen try again."
  #expect(
    RemoteMarkdown.segments(text) == [
      .prose("Log in first:"),
      .code(language: "bash", code: "! gcloud auth login"),
      .prose("Then try again."),
    ])
}

@Test("A block being written runs to the end; tildes and longer fences close their own")
func markdownOpenAndNestedFences() {
  #expect(
    RemoteMarkdown.segments("Run:\n```\nswift test") == [
      .prose("Run:"), .code(language: nil, code: "swift test"),
    ])
  #expect(
    RemoteMarkdown.segments("````md\n```\ninner\n```\n````") == [
      .code(language: "md", code: "```\ninner\n```")
    ])
  #expect(RemoteMarkdown.segments("~~~\na\n~~~") == [.code(language: nil, code: "a")])
}

@Test("Text without a block is one stretch of prose; inline code stays in it")
func markdownProseOnly() {
  #expect(RemoteMarkdown.segments("Use `! ls` here.") == [.prose("Use `! ls` here.")])
  #expect(RemoteMarkdown.segments("") == [])
}

@Test("Only one line opening on ! is a command to run")
func markdownShellPrompt() {
  #expect(RemoteMarkdown.shellPrompt(in: "! gcloud auth login\n") == "! gcloud auth login")
  #expect(RemoteMarkdown.shellPrompt(in: "!ls") == "!ls")
  #expect(RemoteMarkdown.shellPrompt(in: "gcloud auth login") == nil)
  #expect(RemoteMarkdown.shellPrompt(in: "! a\n! b") == nil)
  #expect(RemoteMarkdown.shellPrompt(in: "!  ") == nil)
}
