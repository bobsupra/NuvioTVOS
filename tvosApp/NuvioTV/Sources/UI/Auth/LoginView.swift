//
//  LoginView.swift
//  NuvioTV
//
//  Full-screen login gate shown before profile selection. Offers QR (TV) login
//  and email/password sign-in, plus "Continue without account". Ported from the
//  Android AuthQrSignInScreen / AuthSignInScreen.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var auth: AuthManager
    let onContinue: () -> Void

    enum Method: String, CaseIterable, Identifiable {
        case qr = "QR Code"
        case email = "Email"
        var id: String { rawValue }
    }

    @State private var method: Method = .qr
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var didTriggerContinue = false

    var body: some View {
        ZStack {
            Color.tvBackground.ignoresSafeArea()

            HStack(alignment: .center, spacing: 64) {
                leftPane
                    .frame(maxWidth: .infinity, alignment: .leading)
                rightPane
                    .frame(width: 760)
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
        }
        .onAppear {
            if auth.isAuthenticated {
                triggerContinue()
                return
            }
            if method == .qr { auth.startQrLogin() }
        }
        .onDisappear { auth.stopQrLogin() }
        .onChange(of: method) { _, newMethod in
            auth.errorMessage = nil
            if newMethod == .qr {
                auth.startQrLogin()
            } else {
                auth.stopQrLogin()
            }
        }
        .onChange(of: auth.authState) { _, state in
            if state.isAuthenticated { triggerContinue(delay: 0.9) }
        }
    }

    private func triggerContinue(delay: Double = 0) {
        guard !didTriggerContinue else { return }
        didTriggerContinue = true
        auth.stopQrLogin()
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { onContinue() }
        } else {
            onContinue()
        }
    }

    // MARK: - Left pane (branding)

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image("BrandWordmark")
                .resizable()
                .scaledToFit()
                .frame(width: 300)

            Text(auth.isAuthenticated ? "You're signed in" : "Sign in to Nuvio")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(.white)

            Text(auth.isAuthenticated
                 ? "Your account is connected on this TV. Your library, addons and progress will sync."
                 : "Scan a QR code with your phone or sign in with your email to sync your library, addons and watch progress.")
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let email = auth.currentEmail, !email.isEmpty {
                Text(email)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Color(red: 0.49, green: 1.0, blue: 0.61))
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Right pane (login card)

    private var rightPane: some View {
        VStack(alignment: .center, spacing: 24) {
            if !auth.isAuthenticated {
                methodToggle
            }

            if auth.isAuthenticated {
                connectedContent
            } else if method == .qr {
                qrContent
            } else {
                emailContent
            }

            if let error = auth.errorMessage, !error.isEmpty {
                statusPill(error, isError: true)
            }

            if !auth.isBackendConfigured {
                statusPill("Backend not configured — add the Nuvio API URL and publishable key in AuthConfig.swift.", isError: false)
            }

            Divider().background(Color.white.opacity(0.1)).padding(.vertical, 4)

            LoginButton(title: "Continue without account", systemImage: "arrow.right") {
                auth.skipLogin()
                triggerContinue()
            }
        }
        .padding(40)
        .loginGlassPanel()
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

    // MARK: QR content

    private var qrContent: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 280, height: 280)

                if let qr = auth.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 248, height: 248)
                } else if auth.isBusy {
                    ProgressView()
                        .scaleEffect(1.3)
                        .tint(.black)
                } else {
                    Text("QR unavailable.\nRefresh to retry.")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.black.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
            }

            if let code = auth.qrCode, !code.isEmpty {
                Text("Code: \(code)")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
            }

            if let expires = auth.qrExpiresAt {
                CountdownText(target: expires)
            }

            if let status = auth.qrStatusMessage, !status.isEmpty, auth.errorMessage == nil {
                Text(status)
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
            }

            LoginButton(title: "Refresh QR", systemImage: "arrow.clockwise", disabled: auth.isBusy) {
                auth.startQrLogin(force: true)
            }
        }
    }

    // MARK: Email content

    private var emailContent: some View {
        VStack(spacing: 16) {
            Text(isSignUp ? "Create your account" : "Sign in with email")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

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
                textContentType: isSignUp ? .newPassword : .password
            )

            LoginButton(
                title: isSignUp ? "Create Account" : "Sign In",
                systemImage: "envelope.fill",
                prominent: true,
                disabled: auth.isBusy || email.isEmpty || password.isEmpty
            ) {
                Task {
                    if isSignUp {
                        await auth.signUp(email: email, password: password)
                    } else {
                        await auth.signIn(email: email, password: password)
                    }
                }
            }

            LoginLinkButton(
                title: isSignUp ? "Already have an account? Sign in" : "New to Nuvio? Create an account"
            ) {
                isSignUp.toggle()
                auth.errorMessage = nil
            }
        }
    }

    // MARK: Connected content

    private var connectedContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(Color(red: 0.49, green: 1.0, blue: 0.61))
            Text(auth.qrStatusMessage ?? "Signed in successfully")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
            ProgressView().tint(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func statusPill(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 19, weight: .medium))
            .foregroundColor(isError ? Color(red: 1.0, green: 0.43, blue: 0.43) : .white.opacity(0.7))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background((isError ? Color.red.opacity(0.18) : Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Components

struct MethodTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(isSelected || focused ? .black : .white)
                .padding(.horizontal, 28)
                .frame(height: 52)
                .loginGlassCapsule(highlighted: isSelected || focused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

struct LoginButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 26)
            .frame(height: 58)
            .frame(maxWidth: .infinity)
            .loginGlassCapsule(highlighted: focused, prominent: prominent)
            .opacity(disabled ? 0.5 : 1)
            .scaleEffect(focused && !disabled ? 1.03 : 1)
        }
        // PosterCardButtonStyle (not .plain): the plain style draws its own
        // white focus platter on tvOS even with focusEffectDisabled().
        .buttonStyle(PosterCardButtonStyle())
        .disabled(disabled)
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private var foreground: Color {
        if focused { return .black }
        return prominent ? .black : .white
    }
}

/// Email/password entry styled like the Search bar and Settings fields: a
/// Liquid Glass capsule with a hidden off-screen UITextField driving editing,
/// because a native focused TextField/SecureField on tvOS always paints its
/// own white pill over custom chrome.
struct LoginGlassField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil

    @FocusState private var focused: Bool
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            ZStack(alignment: .leading) {
                HiddenLoginTextField(
                    text: $text,
                    isEditing: $isEditing,
                    isSecure: isSecure,
                    keyboardType: keyboardType,
                    textContentType: textContentType
                )
                .frame(width: 1, height: 1)
                .offset(x: -4_000)
                .allowsHitTesting(false)

                Text(displayText)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(text.isEmpty ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 58)
            .modifier(GlassCapsule(focused: focused || isEditing))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
    }

    private var displayText: String {
        guard !text.isEmpty else { return placeholder }
        return isSecure ? String(repeating: "•", count: text.count) : text
    }
}

/// Off-screen UITextField that drives editing for LoginGlassField. Mirrors the
/// Settings tab's private helper: never focusable itself, invisible, and only
/// used to summon the keyboard and receive text.
struct HiddenLoginTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil

    func makeUIView(context: Context) -> HiddenLoginUITextField {
        let textField = HiddenLoginUITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.backgroundColor = .clear
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.returnKeyType = .done
        textField.keyboardAppearance = .dark
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.isSecureTextEntry = isSecure
        textField.keyboardType = keyboardType
        textField.textContentType = textContentType
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: HiddenLoginUITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if isEditing && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isEditing && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        private let isEditing: Binding<Bool>

        init(text: Binding<String>, isEditing: Binding<Bool>) {
            self.text = text
            self.isEditing = isEditing
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            isEditing.wrappedValue = false
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isEditing.wrappedValue = false
        }
    }
}

final class HiddenLoginUITextField: UITextField {
    override var canBecomeFocused: Bool { false }
}

/// Small text-link button (e.g. sign-in/sign-up toggle) with the shared glass
/// capsule focus treatment instead of the system's white platter.
struct LoginLinkButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(focused ? .white : .white.opacity(0.7))
                .padding(.horizontal, 24)
                .frame(height: 46)
                .modifier(GlassCapsule(focused: focused))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Live "Expires in mm:ss" countdown.
struct CountdownText: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let remaining = max(0, Int(target.timeIntervalSince(context.date)))
            Text(String(format: "Expires in %02d:%02d", remaining / 60, remaining % 60))
                .font(.system(size: 19))
                .foregroundColor(.white.opacity(0.55))
        }
    }
}

extension View {
    /// Capsule chrome shared by the login/profile buttons and tabs: Liquid
    /// Glass on tvOS 26+, translucent white fill on older versions.
    /// `highlighted` renders the solid-white selected/focused state (pair it
    /// with black text); `prominent` brightens the resting state for the
    /// primary call-to-action.
    @ViewBuilder
    func loginGlassCapsule(highlighted: Bool, prominent: Bool = false) -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(
                highlighted
                    ? Glass.regular.tint(.white.opacity(0.92))
                    : prominent ? Glass.regular.tint(.white.opacity(0.75)) : Glass.regular,
                in: Capsule()
            )
        } else {
            background(
                highlighted
                    ? Color.white
                    : Color.white.opacity(prominent ? 0.92 : 0.12)
            )
            .clipShape(Capsule())
        }
    }

    /// Liquid Glass panel behind the whole login card, with a material
    /// fallback for tvOS < 26 that keeps the previous translucent look.
    @ViewBuilder
    func loginGlassPanel() -> some View {
        if #available(tvOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
    }
}
