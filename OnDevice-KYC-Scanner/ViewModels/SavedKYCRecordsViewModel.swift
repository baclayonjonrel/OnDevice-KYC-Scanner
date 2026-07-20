//
//  SavedKYCRecordsViewModel.swift
//  OnDevice-KYC-Scanner
//

import Combine
import Foundation

@MainActor
final class SavedKYCRecordsViewModel: ObservableObject {
    @Published private(set) var records: [SavedKYCRecordSnapshot] = []
    @Published var errorMessage: String?

    private let store: KYCRecordStoring

    convenience init() {
        self.init(store: RealmKYCRecordStore())
    }

    init(store: KYCRecordStoring) {
        self.store = store
    }

    func load() {
        do {
            records = try store.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
