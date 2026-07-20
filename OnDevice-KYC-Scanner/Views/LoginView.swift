//
//  LoginView.swift
//  OnDevice-KYC-Scanner
//

import LocalAuthentication
import SwiftUI

struct LoginView: View {
    let onUnlock: () -> Void

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    private let authenticationService = LocalBiometricAuthenticationService()

    var body: some View {
        ZStack {
            VStack(spacing: 34) {
                Spacer(minLength: 36)

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                            .frame(width: 70, height: 70)

                        Image(systemName: biometryIcon)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text("Nice to see you!")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                        .frame(height: 100)

                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 10) {
                        if isAuthenticating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "lock.shield")
                        }

                        Text(isAuthenticating ? "Unlocking..." : "Login")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 100)
                    .frame(height: 48)
                    .background(Color(.systemGray), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isAuthenticating)
                .padding(.horizontal, 26)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 30)
                }

                Spacer(minLength: 80)
            }
        }
        .navigationBarHidden(true)
    }

    private var biometryIcon: String {
        switch authenticationService.availableBiometryType() {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        default:
            return "person"
        }
    }

    private func authenticate() {
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
