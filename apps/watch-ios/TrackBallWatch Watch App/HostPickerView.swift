import SwiftUI

/// Picker list for switching between saved desktop hosts.
struct HostPickerView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if hostStore.hosts.isEmpty {
                Text("No desktops paired")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hostStore.hosts) { host in
                    Button {
                        sessionManager.connectDirectWiFi(to: host)
                        sessionManager.playHaptic(.click)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(.body)
                                Text(host.host)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if host.id == hostStore.activeId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Desktops")
    }
}
