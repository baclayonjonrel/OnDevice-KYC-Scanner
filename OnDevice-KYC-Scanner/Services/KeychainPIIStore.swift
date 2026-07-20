//
//  KeychainPIIStore.swift
//  OnDevice-KYC-Scanner
//

import Foundation
import Security

protocol SecurePIIStoring {
    func save(_ document: KYCDocument) throws
    func loadLatestDocument() throws -> KYCDocument?
    func deleteLatestDocument() throws
}

enum SecurePIIStoreError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Unable to encode KYC data."
        case .decodingFailed:
            return "Unable to decode stored KYC data."
        case .keychainFailure(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

final class KeychainPIIStore: SecurePIIStoring {
    private let service = "com.jonrel.OnDevice-KYC-Scanner.kyc"
    private let account = "latest-document"

    func save(_ document: KYCDocument) throws {
        guard let data = try? JSONEncoder().encode(document) else {
            throw SecurePIIStoreError.encodingFailed
        }

        try deleteLatestDocument(ignoringMissingItem: true)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecurePIIStoreError.keychainFailure(status)
        }
    }

    func loadLatestDocument() throws -> KYCDocument? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw SecurePIIStoreError.keychainFailure(status)
        }

        guard
            let data = item as? Data,
            let document = try? JSONDecoder().decode(KYCDocument.self, from: data)
        else {
            throw SecurePIIStoreError.decodingFailed
        }

        return document
    }

    func deleteLatestDocument() throws {
        try deleteLatestDocument(ignoringMissingItem: true)
    }

    private func deleteLatestDocument(ignoringMissingItem: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || (ignoringMissingItem && status == errSecItemNotFound) else {
            throw SecurePIIStoreError.keychainFailure(status)
        }
    }
}
