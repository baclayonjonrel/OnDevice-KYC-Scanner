//
//  BiometricLockView.swift
//  OnDevice-KYC-Scanner
//

import SwiftUI

struct BiometricLockView: View {
    @StateObject private var viewModel: BiometricLockViewModel

    init(viewModel: BiometricLockViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 64, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)

            VStack(spacing: 10) {
                Text("Secure Onboarding")
                    .font(.largeTitle.bold())

                Text("Authenticate before accessing private KYC capture and extracted identity data.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                viewModel.authenticate()
            } label: {
                Label(
                    viewModel.isAuthenticating ? "Authenticating" : "Unlock with \(viewModel.biometryLabel)",
                    systemImage: "faceid"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isAuthenticating)
            .padding(.horizontal, 24)

            Spacer()

            Text("Raw camera frames stay on device. Parsed PII can be stored using Keychain protection after review.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .navigationBarBackButtonHidden()
        .onAppear {
            viewModel.authenticate()
        }
    }
}
