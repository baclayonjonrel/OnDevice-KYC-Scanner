//
//  RealmKYCRecordStore.swift
//  OnDevice-KYC-Scanner
//

import Foundation
import RealmSwift
import Security

final class SavedKYCRecord: Object, Identifiable {
    @Persisted(primaryKey: true) var id: String
    @Persisted var documentID: String?
    @Persisted var expiryDate: String?
    @Persisted var cardholderName: String?
    @Persisted var averageConfidence: Float
    @Persisted var capturedAt: Date
    @Persisted var savedAt: Date
    @Persisted var engine: String
    @Persisted var imageFileName: String?
}

struct SavedKYCRecordSnapshot: Identifiable, Equatable, Hashable {
    let id: String
    let documentID: String?
    let expiryDate: String?
    let cardholderName: String?
    let averageConfidence: Float
    let capturedAt: Date
    let savedAt: Date
    let engine: String
    let imageURL: URL?
}

protocol KYCRecordStoring {
    func save(document: KYCDocument, engine: String, imageFileName: String?) throws -> SavedKYCRecordSnapshot
    func update(recordID: String, with draft: EditableKYCRecord) throws
    func fetchAll() throws -> [SavedKYCRecordSnapshot]
}

enum KYCRecordStoreError: LocalizedError {
    case keyGenerationFailed(OSStatus)
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let status):
            return "Unable to generate Realm encryption key. Status: \(status)."
        case .keychainFailure(let status):
            return "Unable to access Realm encryption key. Status: \(status)."
        }
    }
}

final class RealmKYCRecordStore: KYCRecordStoring {
    private let imageStore: ImageSnapshotStoring
    private let keychainService = "com.jonrel.OnDevice-KYC-Scanner.realm"
    private let keychainAccount = "realm-encryption-key"

    convenience init() {
        self.init(imageStore: ImageSnapshotService())
    }

    init(imageStore: ImageSnapshotStoring) {
        self.imageStore = imageStore
    }

    func save(document: KYCDocument, engine: String, imageFileName: String?) throws -> SavedKYCRecordSnapshot {
        let realm = try makeRealm()
        let record = SavedKYCRecord()
        record.id = UUID().uuidString
        record.documentID = document.documentID
        record.expiryDate = document.expiryDate
        record.cardholderName = document.cardholderName
        record.averageConfidence = document.averageConfidence
        record.capturedAt = document.capturedAt
        record.savedAt = Date()
        record.engine = engine
        record.imageFileName = imageFileName

        try realm.write {
            realm.add(record, update: .modified)
        }

        return snapshot(from: record)
    }

    func update(recordID: String, with draft: EditableKYCRecord) throws {
        let realm = try makeRealm()
        guard let record = realm.object(ofType: SavedKYCRecord.self, forPrimaryKey: recordID) else { return }

        try realm.write {
            record.cardholderName = draft.cardholderName.trimmingCharacters(in: .whitespacesAndNewlines)
            record.documentID = draft.documentID.trimmingCharacters(in: .whitespacesAndNewlines)
            record.expiryDate = draft.expiryDate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func fetchAll() throws -> [SavedKYCRecordSnapshot] {
        let realm = try makeRealm()
        return realm.objects(SavedKYCRecord.self)
            .sorted(byKeyPath: "savedAt", ascending: false)
            .map(snapshot)
    }

    private func snapshot(from record: SavedKYCRecord) -> SavedKYCRecordSnapshot {
        SavedKYCRecordSnapshot(
            id: record.id,
            documentID: record.documentID,
            expiryDate: record.expiryDate,
            cardholderName: record.cardholderName,
            averageConfidence: record.averageConfidence,
            capturedAt: record.capturedAt,
            savedAt: record.savedAt,
            engine: record.engine,
            imageURL: record.imageFileName.flatMap { imageStore.imageURL(fileName: $0) }
        )
    }

    private func makeRealm() throws -> Realm {
        var configuration = Realm.Configuration(
            schemaVersion: 1,
            migrationBlock: { _, _ in }
        )
        configuration.encryptionKey = try encryptionKey()
        return try Realm(configuration: configuration)
    }

    private func encryptionKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let key = item as? Data {
            return key
        }

        guard status == errSecItemNotFound else {
            throw KYCRecordStoreError.keychainFailure(status)
        }

        var key = Data(count: 64)
        let generationStatus = key.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, 64, baseAddress)
        }

        guard generationStatus == errSecSuccess else {
            throw KYCRecordStoreError.keyGenerationFailed(generationStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KYCRecordStoreError.keychainFailure(addStatus)
        }

        return key
    }
}
