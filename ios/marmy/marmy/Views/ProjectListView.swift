//
//  ProjectListView.swift
//  marmy
//

import SwiftUI

struct ProjectListView: View {
    @State private var viewModel = ProjectListViewModel()
    @State private var showSettings = false
    @State private var selectedProject: Project?

    var body: some View {
        NavigationStack {
            Group {
                if !viewModel.isConfigured {
                    notConfiguredView
                } else if viewModel.isLoading && viewModel.projects.isEmpty {
                    loadingView
                } else if viewModel.hasError {
                    errorView
                } else if viewModel.isEmpty {
                    emptyView
                } else {
                    projectList
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(item: $selectedProject) { project in
                SessionDetailView(project: project)
            }
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.loadProjects()
            }
        }
    }

    // MARK: - Project List

    private var projectList: some View {
        List {
            if !viewModel.projectsWithActiveSessions().isEmpty {
                Section("Active Sessions") {
                    ForEach(viewModel.projectsWithActiveSessions()) { project in
                        ProjectRow(project: project)
                            .onTapGesture {
                                selectedProject = project
                            }
                    }
                }
            }

            if !viewModel.projectsWithoutSessions().isEmpty {
                Section("Projects") {
                    ForEach(viewModel.projectsWithoutSessions()) { project in
                        ProjectRow(project: project)
                            .onTapGesture {
                                selectedProject = project
                            }
                    }
                }
            }
        }
    }

    // MARK: - Empty States

    private var notConfiguredView: some View {
        ContentUnavailableView {
            Label("Not Configured", systemImage: "gear.badge.questionmark")
        } description: {
            Text("Configure your server connection to get started.")
        } actions: {
            Button("Open Settings") {
                showSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var loadingView: some View {
        ProgressView("Loading projects...")
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(viewModel.error?.localizedDescription ?? "Unknown error")
        } actions: {
            Button("Retry") {
                Task {
                    await viewModel.loadProjects()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder")
        } description: {
            Text("No projects found in the workspace directory.")
        } actions: {
            Button("Refresh") {
                Task {
                    await viewModel.refresh()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.name)
                        .font(.headline)

                    if !project.hasGit {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    if project.hasGit, let branch = project.gitBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if project.hasSession {
                        Text("Active")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        if project.hasSession {
            return .green
        } else if project.hasGit {
            return .gray
        } else {
            return .yellow
        }
    }
}

#Preview("Not Configured") {
    ProjectListView()
}

#Preview("Project Row") {
    List {
        ProjectRow(project: Project(
            name: "my-website",
            path: "/path/to/project",
            hasGit: true,
            gitBranch: "main",
            hasSession: true,
            sessionId: "my-website"
        ))
        ProjectRow(project: Project(
            name: "api-backend",
            path: "/path/to/api",
            hasGit: true,
            gitBranch: "feature/auth",
            hasSession: false,
            sessionId: nil
        ))
        ProjectRow(project: Project(
            name: "new-project",
            path: "/path/to/new",
            hasGit: false,
            gitBranch: nil,
            hasSession: false,
            sessionId: nil
        ))
    }
}
