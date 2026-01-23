//
//  APIClient.swift
//  marmy
//

import Foundation

@Observable
final class APIClient {
    static let shared = APIClient()

    private var config: ServerConfig = .default
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Configuration

    func configure(with config: ServerConfig) {
        self.config = config
    }

    func getConfig() -> ServerConfig {
        return config
    }

    var isConfigured: Bool {
        config.isConfigured
    }

    // MARK: - Health Check

    func healthCheck() async throws -> Bool {
        let _: EmptyResponse = try await request(
            endpoint: "/api/health",
            method: "GET"
        )
        return true
    }

    // MARK: - Projects

    func getProjects() async throws -> [Project] {
        let response: ProjectsResponse = try await request(
            endpoint: "/api/projects",
            method: "GET"
        )
        return response.projects
    }

    func getProject(name: String) async throws -> Project {
        return try await request(
            endpoint: "/api/projects/\(name)",
            method: "GET"
        )
    }

    // MARK: - Sessions

    func getSessions() async throws -> [Session] {
        let response: SessionsResponse = try await request(
            endpoint: "/api/sessions",
            method: "GET"
        )
        return response.sessions
    }

    func getSession(id: String) async throws -> Session {
        return try await request(
            endpoint: "/api/sessions/\(id)",
            method: "GET"
        )
    }

    func getSessionContent(id: String) async throws -> SessionContent {
        return try await request(
            endpoint: "/api/sessions/\(id)/content",
            method: "GET"
        )
    }

    func submitToSession(id: String, text: String) async throws {
        let body = SubmitRequest(text: text)
        let _: EmptyResponse = try await request(
            endpoint: "/api/sessions/\(id)/submit",
            method: "POST",
            body: body
        )
    }

    func deleteSession(id: String) async throws {
        let _: EmptyResponse = try await request(
            endpoint: "/api/sessions/\(id)",
            method: "DELETE"
        )
    }

    // MARK: - Private Request Handler

    private func request<T: Decodable>(
        endpoint: String,
        method: String,
        body: (any Encodable)? = nil
    ) async throws -> T {
        guard config.isConfigured else {
            throw APIError.notConfigured
        }

        guard let url = URL(string: endpoint, relativeTo: config.baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = try encoder.encode(body)
        }

        #if DEBUG
        logRequest(request)
        #endif

        let (data, response) = try await session.data(for: request)

        #if DEBUG
        logResponse(response, data: data)
        #endif

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            return try decoder.decode(T.self, from: data)
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 500...599:
            throw APIError.serverError(httpResponse.statusCode)
        default:
            throw APIError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }

    // MARK: - Logging

    private func logRequest(_ request: URLRequest) {
        print("📤 \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")")
        if let body = request.httpBody, let str = String(data: body, encoding: .utf8) {
            print("   Body: \(str)")
        }
    }

    private func logResponse(_ response: URLResponse, data: Data) {
        if let http = response as? HTTPURLResponse {
            print("📥 \(http.statusCode) \(http.url?.absoluteString ?? "?")")
        }
        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
            let truncated = str.prefix(500)
            print("   Response: \(truncated)\(str.count > 500 ? "..." : "")")
        }
    }
}

// MARK: - Supporting Types

struct EmptyResponse: Decodable {}

enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case unauthorized
    case notFound
    case serverError(Int)
    case unexpectedStatusCode(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server not configured. Please check settings."
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "Authentication failed. Check your auth token."
        case .notFound:
            return "Resource not found"
        case .serverError(let code):
            return "Server error (\(code))"
        case .unexpectedStatusCode(let code):
            return "Unexpected response (\(code))"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
