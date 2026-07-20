//
//  BiometricLockViewModel.swift
//  OnDevice-KYC-Scanner
//

import Combine
import Foundation
import LocalAuthentication

@MainActor
final class BiometricLockViewModel: ObservableObject {
    @Published private(set) var isAuthenticating = false
    @Published var errorMessage: String?

    let biometryLabel: String
    private let authenticationService: BiometricAuthenticationServicing
    private let onUnlock: () -> Void

    init(authenticationService: BiometricAuthenticationServicing, onUnlock: @escaping () -> Void) {
        self.authenticationService = authenticationService
        self.onUnlock = onUnlock

        switch authenticationService.availableBiometryType() {
        case .faceID:
            biometryLabel = "Face ID"
        case .touchID:
            biometryLabel = "Touch ID"
        case .opticID:
            biometryLabel = "Optic ID"
        default:
            biometryLabel = "device authentication"
        }
    }

    func authenticate() {
        guard !isAuthenticating else { return }

        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                try await authenticationService.authenticate()
                onUnlock()
            } catch {
                errorMessage = error.localizedDescription
            }

            isAuthenticating = false
        }
    }
}
