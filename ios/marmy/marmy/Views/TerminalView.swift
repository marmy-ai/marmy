//
//  TerminalView.swift
//  marmy
//

import SwiftUI

struct TerminalView: View {
    let content: String
    let isLoading: Bool

    @State private var fontSize: CGFloat = 14
    @State private var isAtBottom = true
    @State private var showJumpToBottom = false

    private let minFontSize: CGFloat = 10
    private let maxFontSize: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isLoading && content.isEmpty {
                            loadingView
                        } else if content.isEmpty {
                            emptyView
                        } else {
                            terminalContent
                        }

                        // Anchor for scrolling to bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                    .padding()
                }
                .background(Color.terminalBackground)
                .onChange(of: content) { _, _ in
                    if isAtBottom {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } else {
                        showJumpToBottom = true
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showJumpToBottom {
                        jumpToBottomButton {
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                                showJumpToBottom = false
                                isAtBottom = true
                            }
                        }
                    }
                }
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { scale in
                    let newSize = fontSize * scale
                    fontSize = min(max(newSize, minFontSize), maxFontSize)
                }
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = content
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }

            Button {
                fontSize = 14
            } label: {
                Label("Reset Font Size", systemImage: "textformat.size")
            }
        }
    }

    // MARK: - Terminal Content

    private var terminalContent: some View {
        Text(content)
            .font(.terminalFont(size: fontSize))
            .foregroundStyle(Color.terminalText)
            .textSelection(.enabled)
            .lineSpacing(2)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        HStack {
            ProgressView()
                .tint(.terminalText)
            Text("Loading...")
                .font(.terminalFont(size: fontSize))
                .foregroundStyle(Color.terminalText.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(Color.terminalText.opacity(0.5))

            Text("No session content")
                .font(.terminalFont(size: fontSize))
                .foregroundStyle(Color.terminalText.opacity(0.5))

            Text("Send a message to start a Claude Code session")
                .font(.terminalFont(size: fontSize - 2))
                .foregroundStyle(Color.terminalText.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Jump to Bottom Button

    private func jumpToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.blue.opacity(0.8))
                .clipShape(Circle())
                .shadow(radius: 4)
        }
        .padding()
    }
}

#Preview("With Content") {
    TerminalView(
        content: """
        $ claude

        Welcome to Claude Code!

        > What would you like to do?

        I can help you with coding tasks. Just tell me what you need.

        > Fix the bug in login.swift

        I'll analyze the login.swift file and fix the bug...
        """,
        isLoading: false
    )
}

#Preview("Empty") {
    TerminalView(content: "", isLoading: false)
}

#Preview("Loading") {
    TerminalView(content: "", isLoading: true)
}
