//
//  ProjectListViewModel.swift
//  marmy
//

import Foundation

@Observable
final class ProjectListViewModel {
    private(set) var projects: [Project] = []
    private(set) var isLoading = false
    private(set) var error: Error?

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    var hasError: Bool {
        error != nil
    }

    var isEmpty: Bool {
        projects.isEmpty && !isLoading
    }

    var isConfigured: Bool {
        apiClient.isConfigured
    }

    @MainActor
    func loadProjects() async {
        guard apiClient.isConfigured else {
            error = APIError.notConfigured
            return
        }

        isLoading = true
        error = nil

        do {
            projects = try await apiClient.getProjects()
        } catch {
            self.error = error
        }

        isLoading = false
    }

    @MainActor
    func refresh() async {
        await loadProjects()
    }

    func projectsWithActiveSessions() -> [Project] {
        projects.filter { $0.hasSession }
    }

    func projectsWithoutSessions() -> [Project] {
        projects.filter { !$0.hasSession }
    }
}
