import Foundation
import SwiftUI

/// Account creation is a self-contained modal. The settings page only lists
/// already saved household accounts; passwords and device codes never appear
/// inline among the saved-profile rows.
struct TVAddAccountSheet: View {
    let api: TypeTypeAPI
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    private enum Method: Hashable {
        case choose, password, device
    }
    private enum Control: Hashable {
        case choosePassword, chooseDevice, identifier, password, submit
    }

    @State private var method: Method = .choose
    @FocusState private var focus: Control?
    @State private var identifier = ""
    @State private var password = ""
    @State private var deviceCode: String?
    @State private var deviceLink: URL?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Text("accounts.addTitle")
                    .font(.system(size: 35, weight: .bold))
                Spacer()
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }
            Divider()
            switch method {
            case .choose:
                Text("accounts.addChooseHelp")
                    .font(.title3)
                    .foregroundStyle(TTTheme.muted)
                HStack(spacing: 22) {
                    Button {
                        method = .password
                        message = nil
                    } label: {
                        Label("accounts.methodPassword", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity, minHeight: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .choosePassword)

                    Button {
                        method = .device
                        message = nil
                    } label: {
                        Label("accounts.methodDevice", systemImage: "appletv")
                            .frame(maxWidth: .infinity, minHeight: 84)
                    }
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .chooseDevice)
                }
                .focusSection()

            case .password:
                Text("accounts.passwordHelp")
                    .foregroundStyle(TTTheme.muted)
                TextField("login.identifier", text: $identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .focused($focus, equals: .identifier)
                SecureField("login.password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .password)
                    .onSubmit { Task { await signInWithPassword() } }
                HStack(spacing: 22) {
                    Button {
                        Task { await signInWithPassword() }
                    } label: {
                        if busy { ProgressView() }
                        else { Text("login.passwordButton") }
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .submit)
                    .disabled(busy ||
                        identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        password.isEmpty)
                    Button("accounts.chooseAnotherMethod") {
                        method = .choose
                        message = nil
                        password = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                .focusSection()

            case .device:
                Text("accounts.deviceHelp")
                    .foregroundStyle(TTTheme.muted)
                if let deviceCode, let deviceLink {
                    Text(TVL10n.formatted("login.deviceCode", deviceCode))
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                    Text(deviceLink.absoluteString)
                        .font(.callout)
                        .foregroundStyle(TTTheme.muted)
                } else if busy {
                    ProgressView("login.starting")
                }
                Button("accounts.chooseAnotherMethod") {
                    method = .choose
                    message = nil
                    deviceCode = nil
                    deviceLink = nil
                }
                .buttonStyle(.bordered)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("add-account-status")
            }
        }
        .padding(45)
        .frame(width: 1040, alignment: .leading)
        .frame(minHeight: 435)
        .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 22))
        .onExitCommand {
            if method == .choose { dismiss() }
            else {
                method = .choose
                message = nil
                password = ""
            }
        }
        // Changing the method cancels a previous device-code polling task.
        // Its task is also cancelled when this modal is dismissed.
        .task(id: method) {
            await Task.yield()
            switch method {
            case .choose:
                busy = false
                focus = .choosePassword
            case .password:
                focus = .identifier
            case .device:
                focus = nil
                await signInWithDeviceCode()
            }
        }
        .onDisappear {
            password = ""
            deviceCode = nil
            deviceLink = nil
        }
    }

    @MainActor
    private func signInWithPassword() async {
        guard !busy else { return }
        busy = true
        message = TVL10n.value("login.passwordStarting")
        defer {
            password = ""
            busy = false
        }
        do {
            let token = try await api.passwordLogin(
                identifier: identifier, password: password
            )
            try Task.checkCancellation()
            try await finishLogin(token: token,
                                  fallbackName: identifier.trimmingCharacters(
                                    in: .whitespacesAndNewlines))
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func signInWithDeviceCode() async {
        busy = true
        deviceCode = nil
        deviceLink = nil
        message = TVL10n.value("login.starting")
        defer { busy = false }
        do {
            let service = SabrService(api: api)
            let flow = try await service.deviceLoginStart()
            try Task.checkCancellation()
            deviceCode = flow.userCode
            var link = api.origin.appendingPathComponent("link")
            if var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) {
                parts.queryItems = [URLQueryItem(name: "code", value: flow.userCode)]
                if let resolved = parts.url { link = resolved }
            }
            deviceLink = link
            message = TVL10n.value("login.waiting")
            let interval = UInt64(max(1, flow.interval)) * 1_000_000_000
            for _ in 0..<max(1, flow.expiresIn / max(1, flow.interval)) {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: interval)
                let result = try await service.deviceLoginPoll(flow.deviceCode)
                try Task.checkCancellation()
                if let token = result.accessToken, !token.isEmpty {
                    try await finishLogin(token: token, fallbackName: nil)
                    return
                }
                if result.code == "access_denied" || result.code == "denied" {
                    message = TVL10n.value("login.denied")
                    return
                }
            }
            message = TVL10n.value("login.expired")
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    /// Verify before adding a household member. On failure restore the
    /// previous active token; never disturb the credentials of other profiles.
    @MainActor
    private func finishLogin(token: String, fallbackName: String?) async throws {
        try Task.checkCancellation()
        let credentials = TypeTypeCredentials.shared
        let previousToken = credentials.token(for: api.origin)
        let previousName = credentials.displayIdentifier(for: api.origin)
        credentials.save(token, for: api.origin)
        credentials.saveDisplayIdentifier(fallbackName, for: api.origin)
        do {
            guard credentials.token(for: api.origin) == token,
                  let identity = try await api.currentAccount(),
                  !identity.isGuest else {
                throw TypeTypeError.unexpectedResponse
            }
            try Task.checkCancellation()
            guard credentials.remember(identity, token: token,
                                       displayIdentifier: fallbackName,
                                       for: api.origin) else {
                throw TypeTypeError.unexpectedResponse
            }
            TVLocalProgress.shared.clear()
            onAdded()
            dismiss()
        } catch {
            if let previousToken {
                credentials.save(previousToken, for: api.origin)
                credentials.saveDisplayIdentifier(previousName, for: api.origin)
            } else {
                credentials.clear(for: api.origin)
            }
            throw error
        }
    }
}
