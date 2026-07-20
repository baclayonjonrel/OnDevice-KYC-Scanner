//
//  KYCRecordEditorView.swift
//  OnDevice-KYC-Scanner
//

import SwiftUI

struct KYCRecordEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var draft: EditableKYCRecord
    let saveTitle: String
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Review Extracted Data") {
                    TextField("Cardholder name", text: $draft.cardholderName)
                        .textInputAutocapitalization(.words)
                        .textContentType(.name)

                    TextField("Document ID", text: $draft.documentID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()

                    TextField("Expiry date", text: $draft.expiryDate)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Privacy") {
                    Label("Only reviewed values are written to encrypted Realm.", systemImage: "lock.shield")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveTitle) {
                        onSave()
                    }
                    .disabled(!draft.hasRequiredFields)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
