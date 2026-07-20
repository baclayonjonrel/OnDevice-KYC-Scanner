//
//  OnboardingCoordinatorViewModel.swift
//  OnDevice-KYC-Scanner
//

import Combine
import Foundation

@MainActor
final class OnboardingCoordinatorViewModel: ObservableObject {
    @Published private(set) var isUnlocked: Bool

    private let sessionStore: AuthSessionStoring

    init(sessionStore: AuthSessionStoring = UserDefaultsAuthSessionStore()) {
        self.sessionStore = sessionStore
        self.isUnlocked = sessionStore.hasValidSession
    }

    func unlock() {
        sessionStore.saveSession()
        isUnlocked = true
    }

    func lockIfSessionExpired() {
        guard !sessionStore.hasValidSession else { return }
        isUnlocked = false
    }
}

protocol AuthSessionStoring {
    var hasValidSession: Bool { get }
    func saveSession()
}

struct UserDefaultsAuthSessionStore: AuthSessionStoring {
    private let expiryKey = "kyc.auth.session.expiresAt"
    private let sessionDuration: TimeInterval = 15 * 60

    nonisolated init() {}

    var hasValidSession: Bool {
        guard let expiresAt = UserDefaults.standard.object(forKey: expiryKey) as? Date else {
            return false
        }

        if expiresAt > Date() {
            return true
        }

        UserDefaults.standard.removeObject(forKey: expiryKey)
        return false
    }

    func saveSession() {
        UserDefaults.standard.set(Date().addingTimeInterval(sessionDuration), forKey: expiryKey)
    }
}
