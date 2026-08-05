import SwiftUI

public struct ProfilePinView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var enteredPin = ""
    @FocusState private var focusedPinKey: String?

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
                        PinButton(
                            number: "\(number)",
                            focus: $focusedPinKey,
                            focusKey: "pin-\(number)"
                        ) {
                            addPinDigit("\(number)")
                        }
                    }

                    PinButton(number: "", isDisabled: true, focus: $focusedPinKey, focusKey: "pin-empty") {}
                    PinButton(number: "0", focus: $focusedPinKey, focusKey: "pin-0") { addPinDigit("0") }

                    PinDeleteButton(action: deleteDigit)
                }
                .focusSection()
                .defaultFocusIfAvailable($focusedPinKey, "pin-1")

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
        .onExitCommand(perform: dismiss)
        .onAppear {
            enteredPin = ""
            viewModel.pinError = nil
            DispatchQueue.main.async { focusedPinKey = "pin-1" }
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
        guard !viewModel.isLoading else { return }
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
    var focus: FocusState<String?>.Binding
    let focusKey: String
    let action: () -> Void

    private var isFocused: Bool { focus.wrappedValue == focusKey }

    var body: some View {
        Button(action: action) {
            Text(number)
                .font(.title)
                .foregroundColor(.white)
                .frame(width: 80, height: 80)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isFocused
                                    ? [.white.opacity(0.32), .white.opacity(0.18)]
                                    : [.white.opacity(0.12), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isFocused ? 0.48 : 0.18), lineWidth: 1)
                )
                .opacity(isDisabled ? 0 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(isDisabled)
        .focused(focus, equals: focusKey)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
