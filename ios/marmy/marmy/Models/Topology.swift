//
//  Topology.swift
//  marmy
//

import Foundation

struct TmuxPane: Codable {
    let id: String
    let windowId: String
    let sessionId: String
    let index: Int
    let width: Int
    let height: Int
    let active: Bool
    let currentCommand: String
    let currentPath: String
    let pid: Int

    enum CodingKeys: String, CodingKey {
        case id, index, width, height, active, pid
        case windowId = "window_id"
        case sessionId = "session_id"
        case currentCommand = "current_command"
        case currentPath = "current_path"
    }
}

struct TmuxWindow: Codable {
    let id: String
    let sessionId: String
    let index: Int
    let name: String
    let panes: [String]
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case id, index, name, panes, active
        case sessionId = "session_id"
    }
}

struct TmuxSession: Codable {
    let id: String
    let name: String
    let windows: [String]
    let attached: Bool
    let unread: Bool
}

struct Topology: Codable {
    let sessions: [TmuxSession]
    let windows: [TmuxWindow]
    let panes: [TmuxPane]
}
