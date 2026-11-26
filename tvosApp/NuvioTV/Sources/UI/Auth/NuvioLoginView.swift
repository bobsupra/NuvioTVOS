//
//  NuvioLoginView.swift
//  NuvioTV
//
//  The login gate shown instead of LoginView while Nuvio Branding is on.
//  Laid out like the
//  Android TV AuthQrSignInScreen: the wordmark and tagline over a purple
//  gradient on the left, and a pane on the right with the QR code, the short
//  code, and Refresh QR / Continue without account. Server options and email
//  sign-in sit in the menu at the top left.
//

import SwiftUI

struct NuvioLoginView: View {
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
    @State private var showingServerOptions = false
    @State private var backendInput = ""
    @State private var trustServer = false
    @FocusState private var focusedAction: PaneAction?

    private enum PaneAction: Hashable { case refresh, continueOn, back }

    // Android `AuthQrSignInScreen` colours. Android TV lays out at 2x density, so
    // its dp sizes are doubled here.
    private static let textPrimary = Color(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xF8 / 255)
    private static let textSecondary = Color(red: 0x96 / 255, green: 0x9C / 255, blue: 0xA3 / 255)
    private static let accountGreen = Color(red: 0x7C / 255, green: 1, blue: 0x9B / 255)

    var body: some View {
        ZStack(alignment: .topLeading) {
            AuthGradientBackground()

            HStack(spacing: 0) {
                brandPanel
                    .padding(.horizontal, 112)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                loginPane
                    .padding(.horizontal, 96)
                    .frame(width: 920)
                    .frame(maxHeight: .infinity)
                    .background(Color.white.opacity(0.022))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.07)).frame(width: 2)
                    }
            }

            if !auth.isAuthenticated {
                optionsMenu
                    .padding(.leading, 56)
                    .padding(.top, 56)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focusedAction, defaultAction)
        .onAppear {
            if auth.isAuthenticated {
                triggerContinue()
                return
            }
            selectSupportedMethod(startQR: true)
            // The focus engine starts at the top left, on the menu; Android
            // starts on the pane's first button. While the QR loads, Refresh
            // is disabled, and focus moves there once the QR has loaded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !auth.isBusy { focusedAction = defaultAction }
            }
        }
        .onDisappear { auth.stopQrLogin() }
        .onChange(of: method) { _, newMethod in
            auth.errorMessage = nil
            if newMethod == .qr && auth.serverCapabilities.tvLogin {
                auth.startQrLogin()
            } else {
                auth.stopQrLogin()
            }
        }
        .onChange(of: auth.authState) { _, state in
            if state.isAuthenticated { triggerContinue(delay: 0.9) }
        }
        .onChange(of: auth.isBusy) { _, isBusy in
            // The QR has loaded: Refresh QR takes focus, unless a pane button has it.
            if !isBusy, focusedAction == nil, method == .qr, !auth.isAuthenticated, !showingServerOptions {
                focusedAction = .refresh
            }
        }
        .onChange(of: auth.serverCapabilities) { _, _ in
            selectSupportedMethod(startQR: true)
        }
    }

    private func selectSupportedMethod(startQR: Bool) {
        if method == .qr && auth.serverCapabilities.tvLogin {
            if startQR { auth.startQrLogin() }
        } else if auth.serverCapabilities.tvLogin {
            method = .qr
        } else if auth.serverCapabilities.emailPasswordAuth {
            method = .email
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

    // MARK: - Brand panel

    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("NuvioWordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 120)
                .accessibilityLabel("Nuvio")

            AuthTagline(text: L10n.string("auth_qr_tagline", fallback: "Watch your library, anywhere"))
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.top, 64)

            if auth.isAuthenticated || method == .email {
                Text(auth.isAuthenticated
                     ? L10n.string("auth_qr_connected", fallback: "Your account is connected on this TV.")
                     : L10n.string("auth_email_hint", fallback: "Sign in directly with the account on your self-hosted server."))
                    .font(.system(size: 34))
                    .lineSpacing(18)
                    .foregroundColor(Self.textSecondary)
                    .frame(maxWidth: 800, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 36)
            }

            if auth.isAuthenticated, let email = auth.currentEmail, !email.isEmpty {
                Text(email)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(Self.accountGreen)
                    .padding(.top, 48)
            }
        }
    }

    // MARK: - Login pane

    private var loginPane: some View {
        VStack(spacing: 0) {
            Text(paneInstruction)
                .font(.system(size: 30))
                .lineSpacing(12)
                .foregroundColor(Self.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if auth.isAuthenticated {
                    statusPill(
                        L10n.string("auth_qr_finishing", fallback: "Finishing sign in…"),
                        isError: false
                    )
                } else if showingServerOptions {
                    serverOptionsForm
                } else if method == .email {
                    VStack(spacing: 20) {
                        emailForm
                        if !auth.isBackendConfigured {
                            statusPill(L10n.string("auth_no_account_server", fallback: "No account server is configured."), isError: false)
                        }
                    }
                } else {
                    qrBlock
                }
            }
            .padding(.vertical, 56)

            if !showingServerOptions {
                paneButtons
            }
        }
    }

    /// As on Android, Refresh QR takes first focus once the QR is there. While
    /// signed out, focus never starts on Continue without account: the launch
    /// splash covers the screen for the first second, and a press meant for
    /// it would skip sign-in for good.
    private var defaultAction: PaneAction {
        if showingServerOptions { return .back }
        return auth.isAuthenticated ? .continueOn : .refresh
    }

    private var paneInstruction: String {
        if auth.isAuthenticated {
            return L10n.string("auth_qr_synced_data", fallback: "Your synced data")
        }
        if showingServerOptions {
            return L10n.string("auth_use_self_hosted_server", fallback: "Use a Self-Hosted Server")
        }
        if method == .email {
            return L10n.string("auth_email_instruction", fallback: "Enter your email and password to continue.")
        }
        return L10n.string(
            "auth_qr_scan_instruction",
            fallback: "Scan the QR code or enter the short code in your browser."
        )
    }

    private var paneButtons: some View {
        HStack(spacing: 24) {
            if !auth.isAuthenticated && method == .qr {
                AuthPaneButton(
                    title: auth.isBusy
                        ? L10n.string("auth_qr_please_wait", fallback: "Please wait…")
                        : L10n.string("auth_refresh_qr", fallback: "Refresh QR"),
                    disabled: auth.isBusy
                ) {
                    auth.startQrLogin(force: true)
                }
                .focused($focusedAction, equals: .refresh)
            }
            AuthPaneButton(
                title: auth.isAuthenticated
                    ? L10n.string("auth_qr_continue", fallback: "Continue")
                    : L10n.string("auth_continue_without_account", fallback: "Continue without account")
            ) {
                if !auth.isAuthenticated { auth.skipLogin() }
                triggerContinue()
            }
            .focused($focusedAction, equals: .continueOn)
        }
    }

    // MARK: QR

    private var qrBlock: some View {
        VStack(spacing: 0) {
            ZStack {
                if let qr = auth.qrImage {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.09), lineWidth: 2)
                        )
                    Text(auth.isBusy
                         ? L10n.string("auth_qr_generating", fallback: "Generating QR…")
                         : L10n.string("auth_qr_unavailable", fallback: "QR unavailable. Refresh to retry."))
                        .font(.system(size: 26))
                        .foregroundColor(Self.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
            .frame(width: 412, height: 412)

            manualCode

            termsLine
                .padding(.top, 24)

            if let error = auth.errorMessage, !error.isEmpty {
                statusPill(error, isError: true)
                    .padding(.top, 28)
            } else if let status = auth.qrStatusMessage, !status.isEmpty {
                Text(status)
                    .font(.system(size: 24))
                    .foregroundColor(Self.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
            }

            if !auth.isBackendConfigured {
                statusPill(L10n.string("auth_no_account_server", fallback: "No account server is configured."), isError: false)
                    .padding(.top, 20)
            }
        }
    }

    /// "Or go to nuvio.tv/link and enter", the code, and its countdown, from the
    /// values `LoginView` shows. A legacy server's long code has no link, since
    /// it isn't meant to be typed, and is shown smaller, as on Android.
    @ViewBuilder
    private var manualCode: some View {
        if let code = auth.qrDisplayCode {
            let link = auth.qrManualEntryLink
            VStack(spacing: 0) {
                if let link {
                    Text(L10n.format(
                        "auth_qr_manual_instruction",
                        fallback: "Or go to %@ and enter",
                        Self.displayURI(link)
                    ))
                        .font(.system(size: 26))
                        .foregroundColor(Self.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Text(code)
                    .font(.system(size: link != nil ? 48 : 28, weight: .semibold))
                    .tracking(link != nil ? 6 : 0)
                    .foregroundColor(Self.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, link != nil ? 20 : 0)
                if let expires = auth.qrExpiresAt {
                    AuthExpiresText(target: expires)
                        .padding(.top, 12)
                }
            }
            .padding(.top, 36)
        } else if auth.isBusy {
            VStack(spacing: 20) {
                skeletonBar(width: 476, height: 24)
                skeletonBar(width: 232, height: 44)
                skeletonBar(width: 168, height: 16)
            }
            .padding(.top, 36)
        }
    }

    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: width, height: height)
    }

    private var termsLine: some View {
        (Text(L10n.string("auth_qr_terms_prefix", fallback: "By signing up / logging in, I agree to the"))
            .foregroundColor(Self.textSecondary)
         + Text(" ")
         + Text(L10n.string("auth_qr_terms_link", fallback: "Terms"))
            .foregroundColor(Self.textPrimary)
            .fontWeight(.semibold))
            .font(.system(size: 26))
            .multilineTextAlignment(.center)
    }

    static func displayURI(_ uri: String) -> String {
        var value = uri
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // MARK: Email

    private var emailForm: some View {
        VStack(spacing: 24) {
            LoginGlassField(
                placeholder: L10n.string("auth_email_placeholder", fallback: "Email address"),
                text: $email,
                keyboardType: .emailAddress,
                textContentType: .emailAddress
            )
            LoginGlassField(
                placeholder: L10n.string("account_password", fallback: "Password"),
                text: $password,
                isSecure: true,
                textContentType: isSignUp ? .newPassword : .password
            )
            LoginButton(
                title: auth.isBusy
                    ? L10n.string("auth_email_signing_in", fallback: "Signing in…")
                    : isSignUp
                        ? L10n.string("action_create_account", fallback: "Create Account")
                        : L10n.string("auth_email_sign_in", fallback: "Sign In"),
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
                title: isSignUp
                    ? L10n.string("auth_already_have_account", fallback: "Already have an account? Sign in")
                    : L10n.string("auth_new_to_nuvio", fallback: "New to Nuvio? Create an account")
            ) {
                isSignUp.toggle()
                auth.errorMessage = nil
            }
            termsLine
            if let error = auth.errorMessage, !error.isEmpty {
                statusPill(error, isError: true)
            }
        }
    }

    // MARK: Server options

    private var serverOptionsForm: some View {
        VStack(spacing: 20) {
            LoginGlassField(
                placeholder: L10n.string("auth_backend_url", fallback: "Backend URL"),
                text: $backendInput,
                keyboardType: .URL
            )
            .onChange(of: backendInput) { _, _ in
                auth.clearDiscoveredServer()
                trustServer = false
            }
            LoginButton(
                title: auth.isDiscoveringServer
                    ? L10n.string("auth_checking_server", fallback: "Checking Server…")
                    : L10n.string("auth_check_server", fallback: "Check Server"),
                systemImage: "checkmark.shield",
                disabled: auth.isDiscoveringServer || backendInput.isEmpty
            ) {
                trustServer = false
                auth.clearDiscoveredServer()
                Task { await auth.discoverCustomServer(input: backendInput) }
            }
            if let discovered = auth.discoveredServer {
                Text(L10n.format("auth_found_server", fallback: "Found %@", discovered.configuration.backendURL))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(Self.textPrimary)
                let methods = [
                    discovered.configuration.capabilities.emailPasswordAuth
                        ? L10n.string("auth_method_email", fallback: "Email")
                        : nil,
                    discovered.configuration.capabilities.tvLogin
                        ? L10n.string("auth_method_qr", fallback: "QR")
                        : nil
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                Text(L10n.format("auth_sign_in_methods", fallback: "Sign-in: %@", methods))
                    .font(.system(size: 22))
                    .foregroundColor(Self.textSecondary)
                ForEach(discovered.securityWarnings, id: \.self) { warning in
                    Text(warning)
                        .font(.system(size: 20))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
                Toggle(L10n.string("auth_trust_server", fallback: "I trust this server"), isOn: $trustServer)
                    .foregroundColor(.white)
                LoginButton(
                    title: L10n.string("action_connect", fallback: "Connect"),
                    systemImage: "link",
                    prominent: true,
                    disabled: auth.isDiscoveringServer || !trustServer
                ) {
                    let configuration = discovered.configuration
                    let selectedMethod: Method = configuration.capabilities.tvLogin ? .qr : .email
                    let shouldStartQR = selectedMethod == .qr && method == .qr
                    guard auth.activateCustomConfiguration(configuration) else { return }
                    showingServerOptions = false
                    trustServer = false
                    method = selectedMethod
                    if shouldStartQR { auth.startQrLogin() }
                }
            }
            if let error = auth.errorMessage, !error.isEmpty {
                statusPill(error, isError: true)
            }
            AuthPaneButton(title: L10n.string("auth_qr_back", fallback: "Back")) {
                showingServerOptions = false
                auth.errorMessage = nil
            }
            .focused($focusedAction, equals: .back)
        }
    }

    // MARK: Options menu

    /// The top-left menu, like Android's server options: another server, the
    /// official one, and on tvOS also email sign-in.
    private var optionsMenu: some View {
        Menu {
            Button {
                backendInput = AuthConfig.apiBaseURL == AuthConfig.officialAPIBaseURL ? "" : AuthConfig.apiBaseURL
                showingServerOptions = true
            } label: {
                Label(
                    AuthConfig.isCustom
                        ? L10n.string("server_options_change_custom", fallback: "Connect to another server")
                        : L10n.string("server_options_connect_custom", fallback: "Connect to custom server"),
                    systemImage: "server.rack"
                )
            }
            if AuthConfig.isCustom {
                Button {
                    let shouldStartQR = method == .qr
                    auth.useOfficialServer()
                    method = .qr
                    showingServerOptions = false
                    if shouldStartQR { auth.startQrLogin() }
                } label: {
                    Label(
                        L10n.string("server_options_use_official", fallback: "Use official server"),
                        systemImage: "arrow.uturn.backward"
                    )
                }
            }
            if auth.serverCapabilities.tvLogin && auth.serverCapabilities.emailPasswordAuth {
                Button {
                    showingServerOptions = false
                    method = method == .qr ? .email : .qr
                } label: {
                    Label(
                        method == .qr
                            ? L10n.string("auth_sign_in_email_title", fallback: "Sign in with email")
                            : L10n.string("auth_qr_title", fallback: "Sign In With QR"),
                        systemImage: method == .qr ? "envelope" : "qrcode"
                    )
                }
            }
        } label: {
            AuthMenuDots()
                .accessibilityLabel(L10n.string("server_options_content_description", fallback: "Server options"))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
    }

    private func statusPill(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 24))
            .foregroundColor(isError ? Color(red: 1.0, green: 0.43, blue: 0.43) : Self.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .background(
                isError ? Color(red: 0.78, green: 0.16, blue: 0.16).opacity(0.2) : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

/// Android's `authGradientBackground`: a 122 degree gradient from deep purple at
/// the top left to black, over black.
private struct AuthGradientBackground: View {
    private static let stops: [Gradient.Stop] = [
        .init(color: Color(red: 0x21 / 255, green: 0x11 / 255, blue: 0x3B / 255), location: 0),
        .init(color: Color(red: 0x21 / 255, green: 0x11 / 255, blue: 0x3B / 255), location: 0.14),
        .init(color: Color(red: 0x1A / 255, green: 0x0E / 255, blue: 0x2F / 255), location: 0.26),
        .init(color: Color(red: 0x13 / 255, green: 0x0A / 255, blue: 0x23 / 255), location: 0.36),
        .init(color: Color(red: 0x0A / 255, green: 0x06 / 255, blue: 0x0F / 255), location: 0.48),
        .init(color: Color(red: 0x05 / 255, green: 0x04 / 255, blue: 0x08 / 255), location: 0.60),
        .init(color: .black, location: 0.70),
        .init(color: .black, location: 1)
    ]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Same geometry as Compose's angled linear gradient: the line runs
            // through the centre at 122 degrees and just reaches both corners.
            let angle = 122.0 * Double.pi / 180
            let dx = sin(angle)
            let dy = -cos(angle)
            let half = (abs(size.width * dx) + abs(size.height * dy)) / 2
            let start = UnitPoint(
                x: 0.5 - dx * half / max(size.width, 1),
                y: 0.5 - dy * half / max(size.height, 1)
            )
            let end = UnitPoint(
                x: 0.5 + dx * half / max(size.width, 1),
                y: 0.5 + dy * half / max(size.height, 1)
            )
            LinearGradient(stops: Self.stops, startPoint: start, endPoint: end)
                .background(Color.black)
        }
    }
}

/// A button in the login pane: Android's translucent rounded button with a
/// hairline border, white with black text when focused.
private struct AuthPaneButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AuthPaneButtonLabel(title: title, disabled: disabled)
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(disabled)
        .focusEffectDisabledIfAvailable()
    }
}

private struct AuthPaneButtonLabel: View {
    let title: String
    let disabled: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        Text(title)
            .font(.system(size: 28, weight: .medium))
            .foregroundColor(focused ? .black : Color(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xF8 / 255))
            .padding(.horizontal, 36)
            .frame(height: 76)
            .background(
                focused ? Color.white : Color.white.opacity(disabled ? 0.022 : 0.05),
                in: RoundedRectangle(cornerRadius: 32, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(focused ? 0 : 0.09), lineWidth: 2)
            )
            .scaleEffect(focused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// The tagline, wrapped the way Android wraps it. SwiftUI's Text won't leave one
/// word alone on the last line, so it would break "Watch your / library,
/// anywhere"; a UILabel with no line-break strategy breaks after "library,".
private struct AuthTagline: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = []
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        paragraph.lineBreakStrategy = []
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 72, weight: .semibold),
            .foregroundColor: UIColor(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xF8 / 255, alpha: 1),
            .paragraphStyle: paragraph
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? 880
        let fitted = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}

/// Android's vertical three dots, inside a white circle when focused.
private struct AuthMenuDots: View {
    @Environment(\.isFocused) private var focused

    var body: some View {
        Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .font(.system(size: 30, weight: .bold))
            .foregroundColor(focused ? .black : Color(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xF8 / 255))
            .frame(width: 72, height: 72)
            .background(Circle().fill(focused ? Color.white : Color.clear))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// "Expires in mm:ss", ticking once a second.
private struct AuthExpiresText: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let remaining = max(0, Int(target.timeIntervalSince(context.date)))
            Text(L10n.format(
                "auth_expires_in",
                fallback: "Expires in %02d:%02d",
                remaining / 60,
                remaining % 60
            ))
                .font(.system(size: 24))
                .foregroundColor(Color(red: 0x96 / 255, green: 0x9C / 255, blue: 0xA3 / 255))
        }
    }
}
