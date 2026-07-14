import SwiftUI

public struct ProfilePinView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var enteredPin = ""
    
    public init(viewModel: ProfileViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ZStack {
            Color.black.opacity(0.9).edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                Text("Enter PIN")
                    .font(.title)
                    .foregroundColor(.white)
                
                HStack(spacing: 20) {
                    ForEach(0..<4) { index in
                        Circle()
                            .fill(index < enteredPin.count ? Color.white : Color.gray)
                            .frame(width: 20, height: 20)
                    }
                }
                
                if let error = viewModel.pinError {
                    Text(error)
                        .foregroundColor(.red)
                }
                
                // Numeric Keypad
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(80)), count: 3), spacing: 20) {
                    ForEach(1...9, id: \.self) { number in
                        PinButton(number: "\(number)") {
                            addPinDigit("\(number)")
                        }
                    }
                    
                    PinButton(number: "", isDisabled: true) {}
                    
                    PinButton(number: "0") {
                        addPinDigit("0")
                    }
                    
                    Button(action: {
                        if !enteredPin.isEmpty {
                            enteredPin.removeLast()
                            viewModel.pinError = nil
                        }
                    }) {
                        Image(systemName: "delete.left")
                            .font(.title)
                            .foregroundColor(.white)
                            .frame(width: 80, height: 80)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                
                Button("Cancel") {
                    viewModel.isPinEntryVisible = false
                    enteredPin = ""
                    viewModel.pinError = nil
                }
                .foregroundColor(.white)
                .padding(.top)
            }
        }
    }
    
    private func addPinDigit(_ digit: String) {
        if enteredPin.count < 4 {
            enteredPin.append(digit)
            viewModel.pinError = nil
            if enteredPin.count == 4 {
                viewModel.verifyAndSwitch(pin: enteredPin)
                // Clear pin if failure (VM handles error state)
                if viewModel.pinError != nil {
                     enteredPin = ""
                }
            }
        }
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
