import SwiftUI

public struct ProfilePinView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var enteredPin = ""
    @FocusState private var focusedControl: ProfilePinControl?

    public init(viewModel: ProfileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Enter PIN")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(.white)

                    Text(instructions)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.64))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < enteredPin.count ? Color.white : Color.white.opacity(0.24))
                            .frame(width: 18, height: 18)
                    }
                }
                .padding(.vertical, 4)

                Group {
                    if viewModel.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Verifying…")
                        }
                        .foregroundColor(.white.opacity(0.72))
                    } else {
                        Text(viewModel.pinError ?? " ")
                            .foregroundColor(.red)
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .frame(height: 24)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(80)), count: 3),
                    spacing: 18
                ) {
                    ForEach(1...9, id: \.self) { number in
                        digitButton(number)
                    }

                    Color.clear
                        .frame(width: 80, height: 80)

                    digitButton(0)
                    deleteButton
                }

                actionButton(title: "Cancel", control: .cancel) {
                    guard !viewModel.isLoading else { return }
                    dismiss()
                }
                .padding(.top, 4)
            }
            .frame(width: 500)
            .padding(44)
            .loginGlassPanel()
            .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .onAppear {
            enteredPin = ""
            viewModel.pinError = nil
            focusedControl = .digit(1)
        }
        .onChange(of: viewModel.pinError) { _, error in
            if error != nil {
                enteredPin = ""
                focusedControl = .digit(1)
            }
        }
    }

    private var instructions: String {
        guard
            let profileID = viewModel.pendingProfileId,
            let profile = viewModel.profiles.first(where: { $0.id == profileID })
        else {
            return "Enter the 4-digit profile PIN."
        }
        return "Enter the 4-digit PIN for \(profile.name)."
    }

    private func digitButton(_ number: Int) -> some View {
        let control = ProfilePinControl.digit(number)
        return Button {
            addPinDigit(String(number))
        } label: {
            Text(String(number))
                .font(.system(size: 38, weight: .medium))
                .foregroundColor(focusedControl == control ? .black : .white)
                .frame(width: 80, height: 80)
                .loginGlassCapsule(highlighted: focusedControl == control)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedControl, equals: control)
        .focusEffectDisabledIfAvailable()
        .disabled(viewModel.isLoading)
        .scaleEffect(focusedControl == control ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: focusedControl)
    }

    private var deleteButton: some View {
        let control = ProfilePinControl.delete
        return Button {
            guard !viewModel.isLoading, !enteredPin.isEmpty else { return }
            enteredPin.removeLast()
            viewModel.pinError = nil
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(focusedControl == control ? .black : .white)
                .frame(width: 80, height: 80)
                .loginGlassCapsule(highlighted: focusedControl == control)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedControl, equals: control)
        .focusEffectDisabledIfAvailable()
        .disabled(viewModel.isLoading)
        .scaleEffect(focusedControl == control ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: focusedControl)
    }

    private func actionButton(
        title: String,
        control: ProfilePinControl,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(focusedControl == control ? .black : .white)
                .padding(.horizontal, 30)
                .frame(height: 56)
                .loginGlassCapsule(highlighted: focusedControl == control)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focusedControl, equals: control)
        .focusEffectDisabledIfAvailable()
        .disabled(viewModel.isLoading)
        .scaleEffect(focusedControl == control ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: focusedControl)
    }

    private func addPinDigit(_ digit: String) {
        guard !viewModel.isLoading, enteredPin.count < 4 else { return }
        enteredPin.append(digit)
        viewModel.pinError = nil
        if enteredPin.count == 4 {
            viewModel.verifyAndSwitch(pin: enteredPin)
        }
    }

    private func dismiss() {
        viewModel.isPinEntryVisible = false
        enteredPin = ""
        viewModel.pinError = nil
    }
}

private enum ProfilePinControl: Hashable {
    case digit(Int)
    case delete
    case cancel
}

struct PinButton: View {
    let number: String
    var isDisabled: Bool = false
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(number)
                .font(.title)
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 80, height: 80)
                .loginGlassCapsule(highlighted: isFocused)
                .opacity(isDisabled ? 0 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(isDisabled)
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
