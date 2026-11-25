import SwiftUI
import VibeApplication

/// Settings › Backup Accounts (#600): the chain a session goes on along when its account reaches
/// its limit. Every account that can tell its quota is listed; those in the chain first, in its
/// order, which the arrows change.
struct BackupAccountsSettingsView: View {
  @Bindable var fallback: AccountFallbackModel
  /// The accounts that can tell their quota, in the order of the agents.
  let accounts: [QuotaModel.Account]
  let isTrackingEnabled: Bool

  var body: some View {
    let chained = fallback.shown(among: accounts.map(\.id)).compactMap { id in
      accounts.first { $0.id == id }
    }
    let others = accounts.filter { !fallback.contains($0.id) }
    Form {
      Section {
        if accounts.isEmpty {
          Text("No account can tell its quota yet.", bundle: .module)
            .foregroundStyle(.secondary)
        }
        ForEach(Array(chained.enumerated()), id: \.element.id) { index, account in
          row(account, position: index + 1, isFirst: index == 0, isLast: index == chained.count - 1)
        }
        ForEach(others) { account in
          row(account, position: nil, isFirst: false, isLast: false)
        }
      } header: {
        Text(
          "Order of Priority", bundle: .module,
          comment: "A section of Settings › Backup Accounts: the accounts, the first preferred.")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            """
            The chain is an order of priority. When the account of a session reaches its limit — \
            its quota spent, or a rate limit that lifts in more than a quarter of an hour — the \
            session goes on with the first account of the chain that is not at its limit, handed a \
            copy of its conversation: one higher up that has its quota back comes first. A passing \
            error changes nothing, and a session on an account left out of the chain stops at its \
            limit.
            """,
            bundle: .module
          )
          if !isTrackingEnabled {
            Text(
              "Usage tracking is off: turn on Track agent usage in Privacy for limits to be read and sessions to move on.",
              bundle: .module,
              comment: "Under the backup chain while usage tracking is off (#600)."
            )
            .foregroundStyle(.orange)
          }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
  }

  private func row(
    _ account: QuotaModel.Account, position: Int?, isFirst: Bool, isLast: Bool
  ) -> some View {
    let shown = accounts.map(\.id)
    // The arrows beside the switch, not in its label: VoiceOver reaches each of them.
    return HStack(spacing: 8) {
      Text(verbatim: position.map { "\($0)." } ?? "")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minWidth: 18, alignment: .trailing)
        .accessibilityHidden(true)
      Image(systemName: account.symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(verbatim: account.name)
      Spacer()
      if position != nil {
        Button {
          fallback.move(account.id, by: -1, among: shown)
        } label: {
          Image(systemName: "chevron.up")
        }
        .disabled(isFirst)
        .accessibilityLabel(
          Text("Move \(account.name) up", bundle: .module, comment: "VoiceOver: an account."))
        Button {
          fallback.move(account.id, by: 1, among: shown)
        } label: {
          Image(systemName: "chevron.down")
        }
        .disabled(isLast)
        .accessibilityLabel(
          Text("Move \(account.name) down", bundle: .module, comment: "VoiceOver: an account."))
      }
      Toggle(
        isOn: Binding(
          get: { fallback.contains(account.id) },
          set: { fallback.setIncluded($0, account.id) })
      ) {
        Text(verbatim: account.name)
      }
      .labelsHidden()
      .toggleStyle(.switch)
      .accessibilityIdentifier("settings-backup-\(account.id)")
    }
    .buttonStyle(.borderless)
  }
}
