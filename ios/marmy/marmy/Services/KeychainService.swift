//
//  KeychainService.swift
//  marmy
//

import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.marmy.app"
    private let authTokenKey = "authToken"

    private init() {}

    // MARK: - Auth Token

    func saveAuthToken(_ token: String) throws {
        try save(key: authTokenKey, value: token)
    }

    func getAuthToken() -> String? {
        return get(key: authTokenKey)
    }

    func deleteAuthToken() throws {
        try delete(key: authTokenKey)
    }

    // MARK: - Generic Keychain Operations

    private func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Delete existing item first
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: Error {
    case invalidData
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
}
