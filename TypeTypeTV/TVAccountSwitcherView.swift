import Foundation
import SwiftUI

/// The main-menu Account destination is a household profile switcher.
/// Account creation/sign-in and server settings stay in Settings -> Account.
struct TVAccountSwitcherView: View {
    let api: TypeTypeAPI
    let onAddAccount: () -> Void
    let onAccountChanged: () -> Void
    var focusRequest = 0

    @State private var accounts: [TVSavedAccount] = []
    @FocusState private var focusedAccountID: String?
    @FocusState private var addAccountFocused: Bool
    @State private var identity: TVAccountIdentity?
    @State private var loading = true
    @State private var changing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("profiles.title")
                    .font(.system(size: 48, weight: .bold))
                Text("profiles.subtitle")
                    .font(.title3)
                    .foregroundStyle(TTTheme.muted)

                if loading {
                    ProgressView("login.accountChecking")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                    Button("common.retry") {
                        Task { await refresh() }
                    }
                    .buttonStyle(.bordered)
                }

                if !accounts.isEmpty {
                    Text("profiles.saved")
                        .font(.title2.bold())
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 20
                    ) {
                        ForEach(accounts) { account in
                            Button {
                                Task { await switchTo(account) }
                            } label: {
                                HStack(spacing: 18) {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 36))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(account.label)
                                            .font(.title3.bold())
                                            .lineLimit(2)
                                        if identity?.id == account.id {
                                            Text("profiles.current")
                                                .font(.callout)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if identity?.id == account.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(24)
                                .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                                .background(focusedAccountID == account.id
                                                ? Color.white.opacity(0.13) : TTTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(focusedAccountID == account.id
                                                      ? Color.white : .clear,
                                                      lineWidth: 3)
                                }
                            }
                            .buttonStyle(TVRailButtonStyle())
                            .focusEffectDisabled(true)
                            .focused($focusedAccountID, equals: account.id)
                            .disabled(changing)
                            .onMoveCommand { direction in
                                // A final row containing one or two profiles
                                // must lead down to the Add Account button.
                                if direction == .down,
                                   let index = accounts.firstIndex(where: { $0.id == account.id }),
                                   index >= accounts.count - 2 {
                                    addAccountFocused = true
                                }
                            }
                            .accessibilityLabel(account.label)
                            .accessibilityAddTraits(identity?.id == account.id ? .isSelected : [])
                        }
                    }
                    .focusSection()
                }

                if identity?.isGuest == true {
                    Label("login.guestActive", systemImage: "person.crop.circle")
                        .foregroundStyle(TTTheme.muted)
                } else if identity == nil && !loading {
                    Label("login.notSignedIn", systemImage: "person.crop.circle")
                        .foregroundStyle(TTTheme.muted)
                }

                // Switching between saved accounts is safe here. Logging
                // out or changing to a guest session belongs only in
                // Settings -> Account, never in the quick profile chooser.
                Button {
                    onAddAccount()
                } label: {
                    Label("profiles.add", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(TTTheme.accent)
                .focused($addAccountFocused)
                .onMoveCommand { direction in
                    if direction == .up, let last = accounts.last {
                        focusedAccountID = last.id
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, 60)
            .padding(.top, 46)
            .padding(.bottom, 130)
        }
        .background(TTTheme.ink)
        .task {
            accounts = TypeTypeCredentials.shared.savedAccounts(for: api.origin)
            focusFirstAccount()
            await refresh()
        }
        .task(id: focusRequest) {
            await Task.yield()
            focusFirstAccount()
        }
        .onChange(of: accounts.count) { _, _ in
            if focusedAccountID == nil && !addAccountFocused {
                focusFirstAccount()
            }
        }
    }

    @MainActor
    private func focusFirstAccount() {
        if let first = accounts.first {
            focusedAccountID = first.id
        } else {
            addAccountFocused = true
        }
    }

    @MainActor
    private func refresh() async {
        accounts = TypeTypeCredentials.shared.savedAccounts(for: api.origin)
        guard api.origin.host != "preview.invalid" else {
            loading = false
            return
        }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let actual = try await api.currentAccount()
            identity = actual
            if let actual, !actual.isGuest {
                // Existing single-account installations acquire a saved
                // profile without requiring the user to log in again.
                TypeTypeCredentials.shared.rememberActive(actual, for: api.origin)
            }
            accounts = TypeTypeCredentials.shared.savedAccounts(for: api.origin)
        } catch TypeTypeError.http(401, _) {
            // A rejected bearer does not mean that the Keychain has vanished.
            // Keep saved household profiles and offer a fresh sign-in.
            identity = nil
            errorMessage = TVL10n.value("login.sessionExpired")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func switchTo(_ account: TVSavedAccount) async {
        guard !changing, identity?.id != account.id else { return }
        changing = true
        errorMessage = nil
        defer { changing = false }
        let credentials = TypeTypeCredentials.shared
        let oldToken = credentials.token(for: api.origin)
        let oldLabel = credentials.displayIdentifier(for: api.origin)
        let oldRefresh = credentials.refreshToken(for: api.origin)
        guard credentials.activate(account, for: api.origin) else {
            errorMessage = TVL10n.value("profiles.switchFailed")
            return
        }
        do {
            let verified = try await api.currentAccount()
            guard verified?.id == account.id else {
                throw TypeTypeError.unexpectedResponse
            }
            identity = verified
            TVLocalProgress.shared.clear()
            onAccountChanged()
        } catch {
            restore(token: oldToken, label: oldLabel, refresh: oldRefresh)
            errorMessage = error.localizedDescription
        }
    }

    private func restore(token: String?, label: String?, refresh: String?) {
        let credentials = TypeTypeCredentials.shared
        if let token {
            credentials.save(token, for: api.origin)
            credentials.saveDisplayIdentifier(label, for: api.origin)
        } else {
            credentials.clear(for: api.origin)
        }
        if let refresh {
            credentials.saveRefreshToken(refresh, for: api.origin)
        } else {
            credentials.clearRefreshToken(for: api.origin)
        }
    }
}
