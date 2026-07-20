//
//  OCRSettingsView.swift
//  OnDevice-KYC-Scanner
//

import KYCOCRSupport
import SwiftUI

struct OCRSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedEngine: OCRProcessingEngine

    var body: some View {
        Form {
            Section("OCR Engine") {
                Picker("OCR Engine", selection: $selectedEngine) {
                    ForEach(OCRProcessingEngine.allCases) { engine in
                        VStack(alignment: .leading) {
                            Text(engine.title)
                            Text(engine.detail)
                        }
                        .tag(engine)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Privacy") {
                Label("Camera frames are processed on device only.", systemImage: "lock.shield")
                Label("Reviewed KYC records are saved in encrypted Realm.", systemImage: "externaldrive.badge.checkmark")
                Label("Realm encryption material is protected by Keychain.", systemImage: "key")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
