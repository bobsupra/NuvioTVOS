//
//  FilterChip.swift
//  NuvioTV
//
//  Created by Claude Code
//  Filter chip component for iOS/tvOS
//

import SwiftUI

/// Filter chip component (similar to Android FilterChip)
struct FilterChip: View {
    let text: String
    let selected: Bool
    let onClick: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: onClick) {
            Text(text)
                .font(.subheadline)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundColor(textColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(backgroundColor)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: borderWidth)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        #if os(tvOS)
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        #endif
    }

    // MARK: - Computed Properties

    #if os(tvOS)
    private var backgroundColor: Color {
        if selected {
            return .white.opacity(0.25)
        } else if isFocused {
            return .white.opacity(0.15)
        } else {
            return .gray.opacity(0.2)
        }
    }

    private var textColor: Color {
        if selected || isFocused {
            return .white
        } else {
            return .gray
        }
    }

    private var borderColor: Color {
        if isFocused {
            return AppFocusOutline.color
        } else if selected {
            return .white
        } else {
            return .clear
        }
    }

    private var borderWidth: CGFloat {
        if isFocused {
            return AppFocusOutline.width
        } else if selected {
            return 2
        } else {
            return 0
        }
    }
    #else
    private var backgroundColor: Color {
        selected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2)
    }

    private var textColor: Color {
        selected ? .blue : .primary
    }

    private var borderColor: Color {
        selected ? .blue : .clear
    }

    private var borderWidth: CGFloat {
        selected ? 1.5 : 0
    }
    #endif
}

// MARK: - Preview

#if DEBUG
struct FilterChip_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            FilterChip(text: "Selected", selected: true) { }
            FilterChip(text: "Not Selected", selected: false) { }
        }
        .previewLayout(.sizeThatFits)
        .padding()
        .background(Color.black)
    }
}
#endif
