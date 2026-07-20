//
//  SavedKYCRecordsView.swift
//  OnDevice-KYC-Scanner
//

import SwiftUI
import UIKit

struct SavedKYCRecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SavedKYCRecordsViewModel

    @MainActor
    init(viewModel: SavedKYCRecordsViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? SavedKYCRecordsViewModel())
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.records.isEmpty {
                    ContentUnavailableView(
                        "No Saved KYC Data",
                        systemImage: "tray",
                        description: Text("Saved scans will appear here after review.")
                    )
                } else {
                    ForEach(viewModel.records) { record in
                        NavigationLink {
                            SavedKYCRecordDetailView(record: record)
                        } label: {
                            SavedKYCRecordRow(record: record)
                        }
                    }
                }
            }
            .navigationTitle("Saved Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            viewModel.load()
        }
        .alert("Saved Data Error", isPresented: errorIsPresented) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.errorMessage = nil
                }
            }
        )
    }
}

private struct SavedKYCRecordRow: View {
    let record: SavedKYCRecordSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let imageURL = record.imageURL,
               let uiImage = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.18))
                    .frame(width: 72, height: 48)
                    .overlay {
                        Image(systemName: "doc.text.viewfinder")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.cardholderName ?? "Unknown cardholder")
                    .font(.headline)
                Text(record.documentID ?? "No document ID")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                HStack {
                    Text(record.expiryDate ?? "No expiry")
                }
                HStack {
                    Text(record.engine)
                    Text("\(Int(record.averageConfidence * 100))%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SavedKYCRecordDetailView: View {
    @State private var record: SavedKYCRecordSnapshot
    @State private var editDraft: EditableKYCRecord
    @State private var isEditing = false
    @State private var errorMessage: String?

    private let store: KYCRecordStoring?
    private let isEditable: Bool

    init(
        record: SavedKYCRecordSnapshot,
        store: KYCRecordStoring? = RealmKYCRecordStore(),
        isEditable: Bool = true
    ) {
        _record = State(initialValue: record)
        _editDraft = State(initialValue: EditableKYCRecord(record: record))
        self.store = store
        self.isEditable = isEditable
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                imageSection

                VStack(alignment: .leading, spacing: 14) {
                    SavedKYCDetailRow(title: "Cardholder", value: record.cardholderName)
                    SavedKYCDetailRow(title: "Document ID", value: record.documentID)
                    SavedKYCDetailRow(title: "Expiry Date", value: record.expiryDate)
                    SavedKYCDetailRow(title: "OCR Engine", value: record.engine)
                    SavedKYCDetailRow(title: "Confidence", value: "\(Int(record.averageConfidence * 100))%")
                    SavedKYCDetailRow(title: "Captured", value: record.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    SavedKYCDetailRow(title: "Saved", value: record.savedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(record.cardholderName ?? "Saved KYC")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            if isEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") {
                        editDraft = EditableKYCRecord(record: record)
                        isEditing = true
                    }
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            KYCRecordEditorView(
                title: "Edit Saved Data",
                draft: $editDraft,
                saveTitle: "Update"
            ) {
                updateSavedRecord()
            }
        }
        .alert("Saved Data Error", isPresented: detailErrorIsPresented) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        if let imageURL = record.imageURL,
           let uiImage = UIImage(contentsOfFile: imageURL.path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
        } else {
            ContentUnavailableView(
                "No Saved Image",
                systemImage: "doc.text.viewfinder",
                description: Text("This record was saved without an image snapshot.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    private var detailErrorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private func updateSavedRecord() {
        do {
            guard let store else { return }
            try store.update(recordID: record.id, with: editDraft)
            record = record.updating(with: editDraft)
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension SavedKYCRecordSnapshot {
    func updating(with draft: EditableKYCRecord) -> SavedKYCRecordSnapshot {
        SavedKYCRecordSnapshot(
            id: id,
            documentID: draft.documentID.trimmingCharacters(in: .whitespacesAndNewlines),
            expiryDate: draft.expiryDate.trimmingCharacters(in: .whitespacesAndNewlines),
            cardholderName: draft.cardholderName.trimmingCharacters(in: .whitespacesAndNewlines),
            averageConfidence: averageConfidence,
            capturedAt: capturedAt,
            savedAt: savedAt,
            engine: engine,
            imageURL: imageURL
        )
    }
}

private struct SavedKYCDetailRow: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value?.isEmpty == false ? value! : "Not available")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
