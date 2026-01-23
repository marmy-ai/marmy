//
//  SettingsView.swift
//  marmy
//

import AVFoundation
import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                voiceSection
                appInfoSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        viewModel.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.isValid)
                }
            }
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
        Section {
            TextField("Host (e.g., 100.x.x.x)", text: $viewModel.host)
                .textContentType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled()

            TextField("Port", text: $viewModel.port)
                .keyboardType(.numberPad)

            SecureField("Auth Token", text: $viewModel.authToken)
                .textContentType(.password)
                .autocapitalization(.none)
                .autocorrectionDisabled()

            Button {
                Task {
                    await viewModel.testConnection()
                }
            } label: {
                HStack {
                    Text("Test Connection")

                    Spacer()

                    if viewModel.isTestingConnection {
                        ProgressView()
                    } else if let result = viewModel.connectionTestResult {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.isSuccess ? .green : .red)
                    }
                }
            }
            .disabled(!viewModel.isValid || viewModel.isTestingConnection)

            if let result = viewModel.connectionTestResult, !result.isSuccess {
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Server Configuration")
        } footer: {
            Text("Enter your Tailscale IP address and the API server port (default: 3000).")
        }
    }

    // MARK: - Voice Section

    private var voiceSection: some View {
        Section {
            Toggle("Text-to-Speech", isOn: $viewModel.ttsEnabled)

            if viewModel.ttsEnabled {
                // Voice selection
                Picker("Voice", selection: $viewModel.selectedVoiceId) {
                    Text("Default").tag(nil as String?)

                    ForEach(viewModel.availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))")
                            .tag(voice.identifier as String?)
                    }
                }

                // Speech rate
                VStack(alignment: .leading) {
                    Text("Speech Rate: \(String(format: "%.1f", viewModel.speechRate))")
                        .font(.subheadline)

                    Slider(value: $viewModel.speechRate, in: 0.1...1.0, step: 0.1)
                }

                // Preview button
                Button {
                    viewModel.previewVoice()
                } label: {
                    Label("Preview Voice", systemImage: "speaker.wave.2")
                }

                // Auto-read toggle
                Toggle("Auto-read new content", isOn: $viewModel.autoReadEnabled)
            }

            // STT Language
            Picker("Speech Input Language", selection: $viewModel.sttLanguage) {
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("English (AU)").tag("en-AU")
            }
        } header: {
            Text("Voice Settings")
        } footer: {
            Text("Configure text-to-speech for reading terminal output and speech-to-text for voice input.")
        }
    }

    // MARK: - App Info Section

    private var appInfoSection: some View {
        Section {
            LabeledContent("Version", value: viewModel.appVersion)
            LabeledContent("Build", value: viewModel.buildNumber)
        } header: {
            Text("About")
        }
    }
}

#Preview {
    SettingsView()
}
