import SwiftUI
import VibeDomain

/// Shared by native agents and endpoints that offer their CLI's automatic permission review.
struct AgentApprovalModePicker: View {
  @Binding var selection: AgentApprovalMode

  var body: some View {
    Picker(selection: $selection) {
      Text("Manual", bundle: .module).tag(AgentApprovalMode.manual)
      Text("Automatic", bundle: .module).tag(AgentApprovalMode.autoReview)
    } label: {
      Text("Approval mode", bundle: .module)
    }
    Text(
      "Auto reviews permission requests for you while keeping the sandbox. Changes apply to new or restarted sessions.",
      bundle: .module
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}
