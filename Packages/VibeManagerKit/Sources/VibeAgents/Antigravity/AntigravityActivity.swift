import Foundation
import VibeApplication
import VibeDomain

/// Per-process status reporting, passed through `--settings`. No global hook, plugin or setting
/// is installed. The original status command receives the same input and keeps its output.
enum AntigravityStatusCommand {
  static let event = "AntigravityStatus"
  /// Two processes per refresh: `plutil` turns the payload into an XML property list, one
  /// `awk` pass reads the allowed fields from it and the time. The user's own command gets the
  /// payload whole, up to 4 MiB.
  static let script = #"""
    u=$1;
    i=$({ head -c 4194304; cat >/dev/null; });
    r=$(printf '%s' "$i" | /usr/bin/plutil -convert xml1 -o - - 2>/dev/null | /usr/bin/awk '
    { sub(/^[ \t]+/, "") }
    /^<(dict|array)>$/ { if (d == 1) o = k; k = ""; d++; next }
    /^<\/(dict|array)>$/ { d--; next }
    /^<key>.*<\/key>$/ { v = $0; gsub(/<\/?key>/, "", v); if (d == 1) k = v; else n = v; next }
    d == 1 && k != "" { v = $0; if (v == "<true/>") v = "true"; else if (v == "<false/>") v = "false"; else gsub(/<[^>]*>/, "", v); f[k] = v; k = ""; next }
    d > 1 { if (o == "subagents" && n == "status" && $0 == "<string>running</string>") b = "true"; n = "" }
    END { srand(); printf "%s|%s|%s|%s|%s|%d", f["conversation_id"], f["agent_state"], f["tool_confirmation_pending"], f["task_count"], (b == "" ? "false" : b), srand() }');
    set -f; IFS='|'; set -- $r; unset IFS; set +f;
    c=$1; s=$2; p=$3; t=$4; b=$5; now=$6;
    case "$t" in ''|*[!0-9]*) ;; *) [ "$t" -gt 0 ] && b=true;; esac;
    [ "$b" = true ] || b=false;
    case "$c" in [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;; *) c=;; esac;
    case "$s" in idle|working|tool_use|reviewing|authenticating|initializing|error) ;; *) s=unknown;; esac;
    [ "$p" = true ] || p=false;
    case "$now" in ''|*[!0-9]*) now=0;; esac;
    [ -n "$VIBE_AGENT_ACTIVITY_LOG" ] && printf 'AntigravityStatus\t%s\t{"conversation_id":"%s","agent_state":"%s","pending":%s,"background":%s}\n' "$now" "$c" "$s" "$p" "$b" >>"$VIBE_AGENT_ACTIVITY_LOG";
    [ -n "$u" ] && printf '%s' "$i" | /bin/sh -c "$u";
    exit 0
    """#

  static func settings(home: URL) -> String {
    let file = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
    var status: [String: Any] = [:]
    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 1024 * 1024, let data = try? Data(contentsOf: file),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let own = object["statusLine"] as? [String: Any]
    {
      status = own
    }
    let enabled = status["enabled"] as? Bool != false
    let original = enabled ? (status["command"] as? String ?? "") : ""
    if !enabled {
      // The user turned the status line off. The reporter must run all the same, so it stays on,
      // alone and drawing nothing: what the user sees is still no status line.
      status["stack_with_default"] = false
    } else if original.isEmpty {
      status["stack_with_default"] = true
    }
    // The CLI expands a leading tilde before running the user's command. Preserve that here.
    let command =
      original.hasPrefix("~/")
      ? AgentActivityHookCommand.shellQuoted(home.path) + original.dropFirst() : original
    status["command"] =
      ["/bin/sh", "-c", script, "vibe-antigravity", command]
      .map(AgentActivityHookCommand.shellQuoted).joined(separator: " ") + " 2>/dev/null"
    status["type"] = "command"
    // Required for the reporting, whatever the user chose: see above for a disabled line.
    status["enabled"] = true
    let data = try? JSONSerialization.data(
      withJSONObject: ["statusLine": status], options: [.sortedKeys, .withoutEscapingSlashes])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }
}

extension AntigravityAgentProvider: AgentActivityReporting {
  public func reportingActivity(_ plan: AgentLaunchPlan, to log: URL) -> AgentLaunchPlan {
    AntigravitySettings.merging(AntigravityStatusCommand.settings(home: home), into: plan)
      .reportingActivity(options: [], to: log)
  }

  public func activityDecoder() -> any AgentSignalDecoding { AntigravitySignalDecoder() }
}

/// Snapshots are not repeated turn-end events: an idle redraw must never create an unread
/// answer. Keep only the last effective state, including background work, under a lock.
public final class AntigravitySignalDecoder: AgentSignalDecoding, @unchecked Sendable {
  private let lock = NSLock()
  private var previous: String?
  public let approvalAnswerKeys: Set<[UInt8]> = []

  public init() {}

  public func conversationIdentifier(in event: AgentActivityEvent) -> String? {
    guard event.name == AntigravityStatusCommand.event,
      let value = event.string("conversation_id"), let uuid = UUID(uuidString: value)
    else { return nil }
    return uuid.uuidString.lowercased()
  }

  public func signal(for event: AgentActivityEvent) -> AgentSignal? {
    guard event.name == AntigravityStatusCommand.event, let object = event.jsonObject,
      let state = object["agent_state"] as? String
    else { return nil }
    let effective: String
    if object["pending"] as? Bool == true || state == "reviewing" {
      effective = "reviewing"
    } else if object["background"] as? Bool == true {
      effective = "working"
    } else {
      effective = state
    }
    guard
      ["idle", "working", "tool_use", "reviewing", "authenticating", "initializing", "error"]
        .contains(effective)
    else { return nil }
    return lock.withLock {
      guard effective != previous else { return nil }
      let old = previous
      previous = effective
      return Self.signal(from: old, to: effective)
    }
  }

  /// What a change of state means. Only snapshots are seen, never who started a turn: a turn
  /// that starts from rest is the user's — work the agent resumes by itself (background tasks,
  /// subagents) reports as working all along, never as idle in between.
  static func signal(from old: String?, to new: String) -> AgentSignal? {
    let busy: Set<String> = ["working", "tool_use"]
    switch new {
    case "working", "tool_use":
      // Running a tool is the same turn going on.
      if let old, busy.contains(old) { return nil }
      if old == "reviewing" { return .questionResolved }
      // A session adopted, or seen first, mid-turn: nobody typed anything just now.
      guard let old, ["idle", "error"].contains(old) else { return .promptSubmitted(byUser: false) }
      return .promptSubmitted(byUser: true)
    case "reviewing":
      // No invented choices or keys. The user answers the actual dialog in the terminal.
      return .dialogAnnounced(AgentTerminalPrompt(kind: .other, message: nil))
    case "idle":
      // An approval, and the rest of the turn ran between two snapshots: the turn ended.
      if let old, busy.contains(old) || old == "reviewing" { return .turnEnded }
      // A first snapshot at rest settles an adopted process that was working, without an answer
      // to read; after an error, the failure is behind.
      return .interrupted
    case "error": return .turnFailed(AgentTerminalPrompt(kind: .other, message: nil))
    case "authenticating", "initializing": return .channelConfirmed
    default: return nil
    }
  }
}

/// Reuse the already-tested confirmation/retry/adoption machinery: only the location of the
/// transcript differs. The UUID comes exclusively from this process's structured status, never
/// the workspace's last-conversation cache or a UUID echoed by the terminal.
struct AntigravityTranscriptWatcher: ClaudeCodeTranscriptWatching {
  let home: URL

  func awaitTranscript(identifier: String, timeout: Duration) async -> Bool {
    guard let file = AntigravityAgentProvider.transcript(identifier: identifier, home: home)
    else { return false }
    let start = ContinuousClock.now
    let deadline = start.advanced(by: timeout)
    while !Task.isCancelled {
      if FileManager.default.fileExists(atPath: file.path) { return true }
      let now = ContinuousClock.now
      guard now < deadline else { return false }
      let interval: Duration = now - start < .seconds(30) ? .milliseconds(500) : .seconds(5)
      do { try await Task.sleep(for: min(interval, deadline - now)) } catch { return false }
    }
    return false
  }
}

public actor AntigravityLaunchObserver: AgentLaunchObserver {
  private let capture: ClaudeCodeSessionIdentifierCapture
  private var named: String?

  /// `recording`: under the endpoint's identifier, with `agy` as its harness, when an endpoint's
  /// session runs it.
  init(
    sessionID: SessionID, repository: any SessionRepository, home: URL,
    recording: AgentResumeRecording = AgentResumeRecording(
      providerID: AntigravityAgentProvider.id.rawValue)
  ) {
    capture = ClaudeCodeSessionIdentifierCapture(
      sessionID: sessionID,
      record: RecordAgentResumeIdentifier(
        repository: repository, providerID: recording.providerID, launchedAt: Date(),
        harnessID: recording.harnessID),
      transcripts: AntigravityTranscriptWatcher(home: home))
  }

  public nonisolated var readsOutput: Bool { false }
  public func launched(plan: AgentLaunchPlan) async {}
  public func observe(output: String) async -> AgentOutputDemand { .enough }
  public func finished() async { await capture.finish() }
  public func awaitedResumeIdentifier() async -> String? { await capture.awaitedIdentifier }

  public func conversationNamed(_ identifier: String) async {
    guard let uuid = UUID(uuidString: identifier) else { return }
    let value = uuid.uuidString.lowercased()
    guard named != value else { return }
    named = value
    await capture.watch(identifier: value)
  }

  public func adopted(awaitedResumeIdentifier identifier: String) async {
    await conversationNamed(identifier)
  }
}

extension AntigravityAgentProvider: AgentLaunchObserverProviding {
  public func launchObserver(for sessionID: SessionID, repository: any SessionRepository)
    -> any AgentLaunchObserver
  {
    launchObserver(
      for: sessionID, repository: repository,
      recording: AgentResumeRecording(providerID: Self.id.rawValue))
  }

  public func launchObserver(
    for sessionID: SessionID, repository: any SessionRepository, recording: AgentResumeRecording
  ) -> any AgentLaunchObserver {
    AntigravityLaunchObserver(
      sessionID: sessionID, repository: repository, home: home, recording: recording)
  }
}
