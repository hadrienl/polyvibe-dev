import Foundation

/// A code block an agent wrote for the user to run in its shell mode, `! gcloud auth login`
/// (#548): one line opening on `!`. Its Run button sends it as typed in the composer.
public enum ShellCommandBlock {
  /// The prompt the block sends, or nil when it is not a single command opening on `!`.
  public static func prompt(in code: String) -> String? {
    let line = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("!"), !line.contains(where: \.isNewline),
      !line.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return line
  }
}
