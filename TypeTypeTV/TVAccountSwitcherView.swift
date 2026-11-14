import Foundation
import SwiftUI

/// The main-menu Account destination is a household profile switcher.
/// Account creation/sign-in and server settings stay in Settings -> Account.
struct TVAccountSwitcherView: View {
    let api: TypeTypeAPI
    let onAddAccount: () -> Void
    let onAccountChanged: () -> Void

    @State private var accounts: [TVSavedAccount] = []
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
                                .background(TTTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled(true)
                            .disabled(changing || identity?.id == account.id)
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

                HStack(spacing: 22) {
                    Button {
                        onAddAccount()
                    } label: {
                        Label("profiles.add", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
                    Button {
                        Task { await useGuest() }
                    } label: {
                        Label("profiles.guest", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(changing || loading || identity?.isGuest == true)
                }
                .focusSection()
            }
            .padding(.horizontal, 60)
            .padding(.top, 46)
            .padding(.bottom, 130)
        }
        .background(TTTheme.ink)
        .task { await refresh() }
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
            restore(token: oldToken, label: oldLabel)
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func useGuest() async {
        guard !changing, identity?.isGuest != true else { return }
        changing = true
        errorMessage = nil
        defer { changing = false }
        let credentials = TypeTypeCredentials.shared
        let oldToken = credentials.token(for: api.origin)
        let oldLabel = credentials.displayIdentifier(for: api.origin)
        credentials.clear(for: api.origin)
        do {
            try await SabrService(api: api).guestLogin()
            let verified = try await api.currentAccount()
            guard verified?.isGuest == true else {
                throw TypeTypeError.unexpectedResponse
            }
            identity = verified
            TVLocalProgress.shared.clear()
            onAccountChanged()
        } catch {
            restore(token: oldToken, label: oldLabel)
            errorMessage = error.localizedDescription
        }
    }

    private func restore(token: String?, label: String?) {
        if let token {
            TypeTypeCredentials.shared.save(token, for: api.origin)
            TypeTypeCredentials.shared.saveDisplayIdentifier(label, for: api.origin)
        } else {
            TypeTypeCredentials.shared.clear(for: api.origin)
        }
    }
}
