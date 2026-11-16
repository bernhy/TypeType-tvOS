import SwiftUI

/// Other servers' local credentials. A remote server can be offline or its
/// access JWT can be expired without its saved refresh session being invalid.
/// All checks and removals are explicit, never part of screen initialization.
struct TVInactiveServerAccountsView: View {
    let currentOrigin: URL

    @State private var servers: [TVInactiveServer] = []
    @State private var checking = Set<String>()
    @State private var results: [String: TVInactiveLoginCheck] = [:]
    @State private var pendingRemoval: TVInactiveServer?
    @State private var confirmRemoval = false
    @State private var message: String?
    @State private var listFailed = false

    var body: some View {
        TVSettingsCard("accounts.inactiveTitle",
                       summary: "accounts.inactiveHelp") {
            if listFailed {
                Label("accounts.inactiveReadFailure", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("common.retry") { reload() }
                    .buttonStyle(.bordered)
            } else if servers.isEmpty {
                Label("accounts.inactiveEmpty", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(TTTheme.muted)
                    .padding(.vertical, 8)
            } else {
                ForEach(servers) { server in
                    VStack(alignment: .leading, spacing: 15) {
                        Label(server.origin.absoluteString, systemImage: "server.rack")
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .foregroundStyle(.white)

                        ForEach(server.logins) { login in
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(login.label)
                                        .font(.callout)
                                        .lineLimit(2)
                                    if checking.contains(login.id) {
                                        Text("accounts.inactiveChecking")
                                            .font(.caption)
                                            .foregroundStyle(TTTheme.muted)
                                    } else if let result = results[login.id] {
                                        Text(TVL10n.value(result.titleKey))
                                            .font(.caption)
                                            .foregroundStyle(
                                                result == .valid || result == .renewed
                                                    ? Color.green : Color.orange
                                            )
                                    } else {
                                        Text("accounts.inactiveUnchecked")
                                            .font(.caption)
                                            .foregroundStyle(TTTheme.muted)
                                    }
                                }
                                Spacer(minLength: 12)
                                Button {
                                    Task { await check(login) }
                                } label: {
                                    Label("accounts.inactiveCheck",
                                          systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .disabled(checking.contains(login.id))
                                .accessibilityIdentifier("accounts-inactive-check-" + login.id)
                            }
                        }

                        Button(role: .destructive) {
                            pendingRemoval = server
                            confirmRemoval = true
                        } label: {
                            Label("accounts.inactiveDelete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(server.logins.contains { checking.contains($0.id) })
                        .accessibilityIdentifier("accounts-inactive-delete-" + server.id)
                    }
                    .padding(.vertical, 12)

                    if server.id != servers.last?.id { Divider() }
                }
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(TTTheme.muted)
            }
        }
        .task { reload() }
        .confirmationDialog(
            TVL10n.value("accounts.inactiveDeleteTitle"),
            isPresented: $confirmRemoval
        ) {
            Button("accounts.inactiveDelete", role: .destructive) {
                deletePending()
            }
            Button("common.cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(TVL10n.formatted(
                "accounts.inactiveDeleteHelp",
                pendingRemoval?.origin.absoluteString ?? ""
            ))
        }
    }

    @MainActor
    private func reload() {
        do {
            servers = try TVStoredAccountCleanup.inactiveServers(excluding: currentOrigin)
            listFailed = false
        } catch {
            listFailed = true
        }
    }

    @MainActor
    private func check(_ login: TVInactiveLogin) async {
        guard !checking.contains(login.id),
              servers.contains(where: { $0.origin == login.origin }) else { return }
        checking.insert(login.id)
        let result = await TVInactiveAccountChecker.check(
            login, currentOrigin: currentOrigin
        )
        checking.remove(login.id)
        guard servers.contains(where: { $0.origin == login.origin }) else { return }
        results[login.id] = result
    }

    @MainActor
    private func deletePending() {
        guard let server = pendingRemoval else { return }
        pendingRemoval = nil
        guard !server.logins.contains(where: { checking.contains($0.id) }) else { return }
        let removed = TVStoredAccountCleanup.delete(
            server.origin, excluding: currentOrigin
        )
        message = TVL10n.value(
            removed ? "accounts.inactiveDeleted" : "accounts.inactiveDeleteFailed"
        )
        for login in server.logins { results.removeValue(forKey: login.id) }
        reload()
    }
}
