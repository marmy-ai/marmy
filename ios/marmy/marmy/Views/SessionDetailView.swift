//
//  SessionDetailView.swift
//  marmy
//

import SwiftUI

struct SessionDetailView: View {
    let project: Project

    @State private var viewModel: SessionViewModel
    @State private var showKillConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(project: Project) {
        self.project = project
        self._viewModel = State(initialValue: SessionViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal content
            TerminalView(
                content: viewModel.sessionContent,
                isLoading: viewModel.isLoading
            )

            Divider()

            // Input bar
            InputBarView(
                text: $viewModel.inputText,
                isSubmitting: viewModel.isSubmitting,
                isRecording: viewModel.isRecording,
                canSubmit: viewModel.canSubmit,
                onSubmit: {
                    Task {
                        await viewModel.submit()
                    }
                },
                onMicTap: {
                    handleMicTap()
                }
            )
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Connection status
                Image(systemName: viewModel.isConnected ? "wifi" : "wifi.slash")
                    .foregroundStyle(viewModel.isConnected ? .green : .secondary)

                // Voice read button
                Button {
                    if viewModel.isSpeaking {
                        viewModel.stopReading()
                    } else {
                        viewModel.readContent()
                    }
                } label: {
                    Image(systemName: viewModel.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                }

                // Refresh button
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                // More options menu
                Menu {
                    if project.hasSession {
                        Button(role: .destructive) {
                            showKillConfirmation = true
                        } label: {
                            Label("Kill Session", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(project.name)
                        .font(.headline)

                    if let branch = project.gitBranch {
                        Text(branch)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .alert("Kill Session?", isPresented: $showKillConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Kill", role: .destructive) {
                Task {
                    try? await viewModel.killSession()
                    dismiss()
                }
            }
        } message: {
            Text("This will terminate the Claude Code session for \(project.name).")
        }
        .task {
            await viewModel.connect()
        }
        .onDisappear {
            viewModel.disconnect()
        }
    }

    private func handleMicTap() {
        if viewModel.isRecording {
            viewModel.stopVoiceInput()
        } else {
            Task {
                let speechAuthorized = await VoiceService.shared.requestSpeechAuthorization()
                let micAuthorized = await VoiceService.shared.requestMicrophoneAuthorization()

                if speechAuthorized && micAuthorized {
                    try? viewModel.startVoiceInput()
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(
            project: Project(
                name: "test-project",
                path: "/path/to/project",
                hasGit: true,
                gitBranch: "main",
                hasSession: true,
                sessionId: "test-project"
            )
        )
    }
}
