//
//  InputBarView.swift
//  marmy
//

import SwiftUI

struct InputBarView: View {
    @Binding var text: String
    let isSubmitting: Bool
    let isRecording: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void
    let onMicTap: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Microphone button
            Button(action: onMicTap) {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(isRecording ? .red : .primary)
                    .frame(width: 44, height: 44)
                    .background(isRecording ? Color.red.opacity(0.2) : Color.clear)
                    .clipShape(Circle())
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
            }

            // Text field
            TextField("Type a message...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .lineLimit(1...5)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit {
                    if canSubmit {
                        onSubmit()
                    }
                }

            // Submit button
            Button(action: onSubmit) {
                Group {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                    }
                }
                .frame(width: 36, height: 36)
                .background(canSubmit ? Color.blue : Color.gray)
                .foregroundStyle(.white)
                .clipShape(Circle())
            }
            .disabled(!canSubmit || isSubmitting)
            .animation(.easeInOut(duration: 0.2), value: canSubmit)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview("Empty") {
    VStack {
        Spacer()
        InputBarView(
            text: .constant(""),
            isSubmitting: false,
            isRecording: false,
            canSubmit: false,
            onSubmit: {},
            onMicTap: {}
        )
    }
}

#Preview("With Text") {
    VStack {
        Spacer()
        InputBarView(
            text: .constant("Fix the login bug"),
            isSubmitting: false,
            isRecording: false,
            canSubmit: true,
            onSubmit: {},
            onMicTap: {}
        )
    }
}

#Preview("Submitting") {
    VStack {
        Spacer()
        InputBarView(
            text: .constant(""),
            isSubmitting: true,
            isRecording: false,
            canSubmit: false,
            onSubmit: {},
            onMicTap: {}
        )
    }
}

#Preview("Recording") {
    VStack {
        Spacer()
        InputBarView(
            text: .constant(""),
            isSubmitting: false,
            isRecording: true,
            canSubmit: false,
            onSubmit: {},
            onMicTap: {}
        )
    }
}
