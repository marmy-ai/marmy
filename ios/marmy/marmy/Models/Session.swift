//
//  Session.swift
//  marmy
//

import Foundation

struct Session: Identifiable, Codable {
    let id: String
    let projectName: String
    let projectPath: String
    let created: Date
    let attached: Bool
    let lastActivity: Date
}

struct SessionContent: Codable {
    let sessionId: String
    let content: String
    let timestamp: Date
}

struct SessionsResponse: Codable {
    let sessions: [Session]
}

struct SubmitRequest: Codable {
    let text: String
}
