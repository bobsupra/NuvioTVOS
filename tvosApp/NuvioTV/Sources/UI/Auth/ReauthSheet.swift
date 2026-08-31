//
//  ReauthSheet.swift
//  NuvioTV
//
//  Dedicated in-place re-authentication modal shown when an account session
//  expires (refresh token rejected). Preserves local profiles, addons, and
//  history while allowing the user to scan a QR code or sign in with email
//  to restore sync seamlessly.
//

import SwiftUI

struct ReauthSheet: View {
    @ObservedObject var auth: AuthManager
    var onReauthenticated: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    enum Method: String, CaseIterable, Identifiable {
        case qr = "QR Code"
        case email = "Email"
        var id: String { rawValue }
    }

    @State private var method: Method = .qr
    @State private var email = ""
    @State private var password = ""
    @State private var didTriggerSuccess = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.2))

                    Text(L10n.string("reauth_title", fallback: "Reconnect Nuvio Account"))
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(L10n.string(
                    "reauth_subtitle",
                    fallback: "Your session expired. Scan the QR code or sign in to resume syncing your library, addons, and watch progress."
                ))
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Auth content
            if !auth.isAuthenticated || auth.sessionNeedsReauthentication {
                methodToggle
            }

            if !auth.sessionNeedsReauthentication && auth.isAuthenticated {
                successContent
            } else if method == .qr {
                qrContent
            } else {
                emailContent
            }

            if let error = auth.errorMessage, !error.isEmpty {
                statusPill(error, isError: true)
            }

            Divider()
                .background(Color.white.opacity(0.12))
                .padding(.vertical, 2)

            LoginButton(
                title: L10n.string("action_cancel", fallback: "Cancel"),
                systemImage: "xmark"
            ) {
                dismiss()
            }
        }
        .frame(width: 780)
        .padding(.horizontal, 64)
        .padding(.vertical, 48)
        .loginGlassPanel()
        .onAppear {
            if method == .qr {
                auth.startQrLogin(force: true)
            }
        }
        .onDisappear {
            auth.stopQrLogin()
        }
        .onExitCommand {
            dismiss()
        }
        .onChange(of: method) { _, newMethod in
            auth.errorMessage = nil
            if newMethod == .qr {
                auth.startQrLogin()
            } else {
                auth.stopQrLogin()
            }
        }
        .onChange(of: auth.sessionNeedsReauthentication) { _, needsReauth in
            if !needsReauth && auth.isAuthenticated {
                handleSuccess()
            }
        }
        .onChange(of: auth.authState) { _, state in
            if state.isAuthenticated && !auth.sessionNeedsReauthentication {
                handleSuccess()
            }
        }
    }

    private func handleSuccess() {
        guard !didTriggerSuccess else { return }
        didTriggerSuccess = true
        auth.stopQrLogin()
        onReauthenticated?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }

    private var methodToggle: some View {
        HStack(spacing: 12) {
            ForEach(Method.allCases) { m in
                MethodTab(title: m.rawValue, isSelected: method == m) {
                    if method != m { method = m }
                }
            }
        }
    }

    private var qrContent: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 250, height: 250)

                if let qr = auth.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                } else if auth.isBusy {
                    ProgressView()
                        .scaleEffect(1.3)
                        .tint(.black)
                } else {
                    Text("QR unavailable.\nRefresh to retry.")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.black.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
            }

            if let code = auth.qrCode, !code.isEmpty {
                Text("Code: \(code)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }

            if let expires = auth.qrExpiresAt {
                CountdownText(target: expires)
            }

            if let status = auth.qrStatusMessage, !status.isEmpty, auth.errorMessage == nil {
                Text(status)
                    .font(.system(size: 19))
                    .foregroundColor(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
            }

            LoginButton(title: "Refresh QR", systemImage: "arrow.clockwise", disabled: auth.isBusy) {
                auth.startQrLogin(force: true)
            }
        }
    }

    private var emailContent: some View {
        VStack(spacing: 16) {
            LoginGlassField(
                placeholder: "Email",
                text: $email,
                keyboardType: .emailAddress,
                textContentType: .emailAddress
            )

            LoginGlassField(
                placeholder: "Password",
                text: $password,
                isSecure: true,
                textContentType: .password
            )

            LoginButton(
                title: L10n.string("tvos_account_sign_in", fallback: "Sign In"),
                systemImage: "envelope.fill",
                prominent: true,
                disabled: auth.isBusy || email.isEmpty || password.isEmpty
            ) {
                Task {
                    await auth.signIn(email: email, password: password)
                }
            }
        }
    }

    private var successContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(Color(red: 0.49, green: 1.0, blue: 0.61))
            Text(L10n.string("reauth_success", fallback: "Reconnected successfully! Resuming sync…"))
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
            ProgressView().tint(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func statusPill(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(isError ? Color(red: 1.0, green: 0.43, blue: 0.43) : .white.opacity(0.7))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(isError ? Color.red.opacity(0.18) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
