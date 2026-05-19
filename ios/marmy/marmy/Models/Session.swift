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

struct SessionContent {
    let sessionId: String
    let content: String
    let timestamp: Date
    let cursorX: Int
    let cursorY: Int

    init(sessionId: String, content: String, timestamp: Date = .now, cursorX: Int = -1, cursorY: Int = -1) {
        self.sessionId = sessionId
        self.content = content
        self.timestamp = timestamp
        self.cursorX = cursorX
        self.cursorY = cursorY
    }
}

struct SessionsResponse: Codable {
    let sessions: [Session]
}

struct SubmitRequest: Codable {
    let text: String
}
