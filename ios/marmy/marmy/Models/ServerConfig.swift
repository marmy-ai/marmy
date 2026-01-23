//
//  ServerConfig.swift
//  marmy
//

import Foundation

struct ServerConfig: Codable {
    var host: String        // e.g., "100.x.x.x"
    var port: Int           // e.g., 3000
    var authToken: String

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    var webSocketURL: URL {
        URL(string: "ws://\(host):\(port)")!
    }

    static var `default`: ServerConfig {
        ServerConfig(host: "", port: 3000, authToken: "")
    }

    var isConfigured: Bool {
        !host.isEmpty && !authToken.isEmpty
    }
}
