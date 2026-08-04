import SwiftUI

public struct ProfilePinView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var enteredPin = ""

    public init(viewModel: ProfileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Enter PIN")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)

                Text(instructions)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.64))
                    .multilineTextAlignment(.center)

                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < enteredPin.count ? Color.white : Color.white.opacity(0.24))
                            .frame(width: 18, height: 18)
                    }
                }
                .padding(.vertical, 4)

                Text(viewModel.isLoading ? "Verifying…" : (viewModel.pinError ?? " "))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(viewModel.isLoading ? .white.opacity(0.72) : .red)
                    .frame(height: 24)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(80)), count: 3),
                    spacing: 18
                ) {
                    ForEach(1...9, id: \.self) { number in
                        PinButton(number: "\(number)") {
                            addPinDigit("\(number)")
                        }
                    }

                    PinButton(number: "", isDisabled: true) {}
                    PinButton(number: "0") { addPinDigit("0") }

                    PinDeleteButton(action: deleteDigit)
                }

                PinSheetActionButton(title: "Cancel") {
                    guard !viewModel.isLoading else { return }
                    dismiss()
                }
                .padding(.top, 4)
            }
            .frame(width: 520)
            .padding(48)
            .loginGlassPanel()
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 32, y: 18)
        }
        .transition(.opacity)
        .onAppear {
            enteredPin = ""
            viewModel.pinError = nil
        }
        .onChange(of: viewModel.pinError) { _, error in
            if error != nil {
                enteredPin = ""
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

    private func deleteDigit() {
        guard !viewModel.isLoading, !enteredPin.isEmpty else { return }
        enteredPin.removeLast()
        viewModel.pinError = nil
    }
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
