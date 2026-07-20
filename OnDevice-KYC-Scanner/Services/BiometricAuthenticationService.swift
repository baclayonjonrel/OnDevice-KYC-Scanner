//
//  BiometricAuthenticationService.swift
//  OnDevice-KYC-Scanner
//

import Foundation
import LocalAuthentication

protocol BiometricAuthenticationServicing {
    func authenticate() async throws
    func availableBiometryType() -> LABiometryType
}

enum BiometricAuthenticationError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        }
    }
}

final class LocalBiometricAuthenticationService: BiometricAuthenticationServicing {
    func authenticate() async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw BiometricAuthenticationError.unavailable(
                error?.localizedDescription ?? "Biometric authentication is not available on this device."
            )
        }

        try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock your private onboarding session."
        )
    }

    func availableBiometryType() -> LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }
}
