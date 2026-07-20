//
//  ScannerView.swift
//  OnDevice-KYC-Scanner
//

import KYCOCRSupport
import PhotosUI
import SwiftUI

struct ScannerView: View {
    @StateObject private var viewModel: ScannerViewModel
    @Binding private var selectedEnginePreference: OCRProcessingEngine
    @State private var isShowingSettings = false
    @State private var isShowingSavedData = false
    @State private var isShowingSaveReview = false
    @State private var shouldResumeScanningAfterReview = false
    @State private var detailRecord: SavedKYCRecordSnapshot?
    @State private var reviewDraft = EditableKYCRecord()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingInitialImage: UIImage?
    @State private var cropGuide: ScannerCropGuide?

    init(
        viewModel: ScannerViewModel,
        selectedEngine: Binding<OCRProcessingEngine> = .constant(.appleVision),
        initialImage: UIImage? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _selectedEnginePreference = selectedEngine
        _pendingInitialImage = State(initialValue: initialImage)
    }

    var body: some View {
        GeometryReader { proxy in
            let guide = makeScannerCropGuide(in: proxy.size)

            ZStack(alignment: .bottom) {
                CameraPreviewView(session: viewModel.session)
                    .ignoresSafeArea()

                scannerOverlay(guide: guide)

                VStack(spacing: 14) {
                    qualityStrip
                    resultPanel
                }
                .padding()
            }
            .onAppear {
                cropGuide = guide
            }
            .onChange(of: proxy.size) { _, newSize in
                cropGuide = makeScannerCropGuide(in: newSize)
            }
        }
        .navigationTitle("On-Device KYC")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Scanner settings")

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel("Upload static ID image")
                    .disabled(viewModel.isProcessingStaticImage)

                    Button {
                        isShowingSavedData = true
                    } label: {
                        Image(systemName: "tray.full")
                    }
                    .accessibilityLabel("Show saved KYC data")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.isRunning ? viewModel.stop() : viewModel.start()
                } label: {
                    Image(systemName: viewModel.isRunning ? "pause.circle" : "play.circle")
                }
                .accessibilityLabel(viewModel.isRunning ? "Pause scanning" : "Start scanning")
            }
        }
        .onAppear {
            viewModel.prepareInitialEngineIfNeeded()
            viewModel.start()
        }
        .task {
            if let pendingInitialImage {
                self.pendingInitialImage = nil
                await viewModel.processStaticImage(pendingInitialImage)
                detailRecord = viewModel.extractedStaticRecord
            }
        }
        .onDisappear {
            viewModel.stop()
        }
        .alert("Scanner Error", isPresented: errorIsPresented) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                OCRSettingsView(
                selectedEngine: Binding(
                    get: { viewModel.selectedEngine },
                    set: { engine in
                        selectedEnginePreference = engine
                        viewModel.selectEngine(engine)
                    }
                )
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isShowingSettings = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingSaveReview) {
            KYCRecordEditorView(
                title: "Review Before Saving",
                draft: $reviewDraft,
                saveTitle: "Save"
            ) {
                let reviewedDocument = reviewDraft.applying(to: viewModel.document)
                viewModel.saveSecurely(reviewedDocument: reviewedDocument)
                isShowingSaveReview = false
                shouldResumeScanningAfterReview = false
                detailRecord = viewModel.lastSavedRecord
            }
        }
        .onChange(of: isShowingSaveReview) { _, isShowing in
            if !isShowing, shouldResumeScanningAfterReview {
                shouldResumeScanningAfterReview = false
                viewModel.start()
            }
        }
        .navigationDestination(item: $detailRecord) { record in
            SavedKYCRecordDetailView(
                record: record,
                store: record.id.hasPrefix("extracted-") ? nil : RealmKYCRecordStore(),
                isEditable: !record.id.hasPrefix("extracted-")
            )
        }
        .fullScreenCover(isPresented: $isShowingSavedData) {
            SavedKYCRecordsView()
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }

            Task {
                defer {
                    selectedPhoto = nil
                }

                guard
                    let data = try? await item.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                else {
                    viewModel.errorMessage = "Unable to load the selected image."
                    return
                }

                await viewModel.processStaticImage(image)
                detailRecord = viewModel.extractedStaticRecord
            }
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

    private func scannerOverlay(guide: ScannerCropGuide) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [18, 10]))
            .foregroundStyle(viewModel.quality.issues.isEmpty ? .green : .yellow)
            .frame(width: guide.guideRect.width, height: guide.guideRect.height)
            .position(x: guide.guideRect.midX, y: guide.guideRect.midY)
            .shadow(radius: 12)
        .allowsHitTesting(false)
    }

    private func makeScannerCropGuide(in size: CGSize) -> ScannerCropGuide {
        let width = max(1, min(size.width - 48, 360))
        let height = width * 0.62
        let rect = CGRect(
            x: (size.width - width) / 2,
            y: size.height * 0.36 - height / 2,
            width: width,
            height: height
        )

        return ScannerCropGuide(viewportSize: size, guideRect: rect)
    }

    private var qualityStrip: some View {
        HStack(spacing: 10) {
            if viewModel.quality.issues.isEmpty {
                Label("Ready to capture", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                ForEach(viewModel.quality.issues) { issue in
                    Label(issue.title, systemImage: issue.systemImage)
                        .foregroundStyle(.yellow)
                        .help(issue.guidance)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Extracted Details")
                    .font(.headline)
                Spacer()
                Text("\(Int(viewModel.document.completionRatio * 100))%")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(viewModel.document.isComplete ? .green : .secondary)
            }

            KYCFieldRow(title: "Cardholder", value: viewModel.document.cardholderName)
            KYCFieldRow(title: "Document ID", value: viewModel.document.documentID)
            KYCFieldRow(title: "Expiry", value: viewModel.document.expiryDate)

            if viewModel.isPreparingEngine || viewModel.engineStatusMessage != nil {
                HStack(spacing: 8) {
                    if viewModel.isPreparingEngine {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(viewModel.engineStatusMessage ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Label(viewModel.selectedEngine.title, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.isProcessingStaticImage {
                    ProgressView()
                        .controlSize(.small)
                }

                Label(
                    "Confidence \(Int(viewModel.quality.averageConfidence * 100))%",
                    systemImage: "waveform.path.ecg"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    Task {
                        reviewDraft = await viewModel.prepareSnapshotForSaveReview(cropGuide: cropGuide)
                        shouldResumeScanningAfterReview = viewModel.isRunning
                        viewModel.stop()
                        isShowingSaveReview = true
                    }
                } label: {
                    Label(viewModel.isSaved ? "Saved" : "Save", systemImage: "key")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.document.isComplete || viewModel.isSaved)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct KYCFieldRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Text(value?.isEmpty == false ? value! : "Scanning...")
                .font(.body.monospaced())
                .textSelection(.enabled)
                .redacted(reason: value == nil ? .placeholder : [])
        }
    }
}
