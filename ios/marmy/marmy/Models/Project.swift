//
//  Project.swift
//  marmy
//

import Foundation

struct Project: Identifiable, Codable, Hashable {
    let name: String
    let path: String
    let hasGit: Bool
    let gitBranch: String?
    let hasSession: Bool
    let sessionId: String?

    var id: String { name }
}

struct ProjectsResponse: Codable {
    let projects: [Project]
}
