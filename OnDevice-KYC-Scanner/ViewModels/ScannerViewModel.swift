//
//  ScannerViewModel.swift
//  OnDevice-KYC-Scanner
//

import AVFoundation
import Combine
import Foundation
import KYCOCRSupport
import UIKit

@MainActor
final class ScannerViewModel: ObservableObject {
    @Published private(set) var document = KYCDocument(
        averageConfidence: 0,
        capturedAt: Date()
    )
    @Published private(set) var quality = ScanQuality(
        brightness: 0,
        averageConfidence: 0,
        documentCoverage: 0,
        recognizedLineCount: 0
    )
    @Published private(set) var isRunning = false
    @Published private(set) var isSaved = false
    @Published private(set) var isProcessingStaticImage = false
    @Published private(set) var isPreparingEngine = false
    @Published private(set) var engineStatusMessage: String?
    @Published private(set) var lastSavedRecord: SavedKYCRecordSnapshot?
    @Published private(set) var extractedStaticRecord: SavedKYCRecordSnapshot?
    @Published var selectedEngine: OCRProcessingEngine = .appleVision
    @Published var errorMessage: String?

    var session: AVCaptureSession {
        cameraService.session
    }

    private let cameraService: CameraCaptureServicing
    private let appleOCRService: OCRServicing
    private let tensorflowOCRService: OCRServicing
    private let recordStore: KYCRecordStoring
    private let imageStore: ImageSnapshotStoring
    private var processingTask: Task<Void, Never>?
    private var enginePreparationTask: Task<Void, Never>?
    private var lastProcessedAt = Date.distantPast
    private var latestImageData: Data?
    private var shouldCaptureLiveSnapshotOnSave = true

    init(
        cameraService: CameraCaptureServicing,
        appleOCRService: OCRServicing,
        tensorflowOCRService: OCRServicing,
        recordStore: KYCRecordStoring,
        imageStore: ImageSnapshotStoring,
        initialEngine: OCRProcessingEngine = .appleVision
    ) {
        self.cameraService = cameraService
        self.appleOCRService = appleOCRService
        self.tensorflowOCRService = tensorflowOCRService
        self.recordStore = recordStore
        self.imageStore = imageStore
        self.selectedEngine = initialEngine
    }

    func prepareInitialEngineIfNeeded() {
        if selectedEngine == .tensorflowLite, !isPreparingEngine, engineStatusMessage == nil {
            prepareTensorFlowLiteEngine()
        }
    }

    func selectEngine(_ engine: OCRProcessingEngine) {
        enginePreparationTask?.cancel()
        selectedEngine = engine
        isSaved = false

        if engine == .tensorflowLite {
            prepareTensorFlowLiteEngine()
        } else {
            isPreparingEngine = false
            engineStatusMessage = nil
        }
    }

    func start() {
        guard processingTask == nil else { return }

        errorMessage = nil
        isSaved = false

        processingTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await cameraService.configure()
                cameraService.start()
                isRunning = true

                for await frame in cameraService.frames {
                    try Task.checkCancellation()
                    await processFrameIfNeeded(frame)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                isRunning = false
            }
        }
    }

    func stop() {
        processingTask?.cancel()
        processingTask = nil
        cameraService.stop()
        isRunning = false
    }

    private func prepareTensorFlowLiteEngine() {
        isPreparingEngine = true
        engineStatusMessage = "Preparing LiteRT models..."

        enginePreparationTask = Task { [weak self] in
            guard let self else { return }

            do {
                if let preparableService = tensorflowOCRService as? TensorFlowLiteOCRService {
                    try await preparableService.prepare()
                }

                guard !Task.isCancelled else { return }
                isPreparingEngine = false
                engineStatusMessage = "LiteRT models ready"
            } catch {
                guard !Task.isCancelled else { return }
                isPreparingEngine = false
                engineStatusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func saveSecurely(reviewedDocument: KYCDocument) {
        do {
            let imageFileName = try latestImageData.map {
                try imageStore.saveImageData($0, preferredName: UUID().uuidString)
            }
            let savedRecord = try recordStore.save(
                document: reviewedDocument,
                engine: selectedEngine.title,
                imageFileName: imageFileName
            )
            document = reviewedDocument
            lastSavedRecord = savedRecord
            isSaved = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareSnapshotForSaveReview(cropGuide: ScannerCropGuide?) async -> EditableKYCRecord {
        if isRunning, shouldCaptureLiveSnapshotOnSave {
            do {
                let frame = try await cameraService.currentFrame()
                latestImageData = try imageStore.jpegData(from: frame, cropGuide: cropGuide)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        return EditableKYCRecord(document: document)
    }

    func processStaticImage(_ image: UIImage) async {
        guard !isProcessingStaticImage else { return }
        guard let cgImage = image.cgImage else {
            errorMessage = "Unable to read the selected image."
            return
        }

        latestImageData = try? imageStore.jpegData(from: image)
        shouldCaptureLiveSnapshotOnSave = false
        isProcessingStaticImage = true
        isSaved = false
        extractedStaticRecord = nil

        defer {
            isProcessingStaticImage = false
        }

        do {
            let result = try await activeOCRService.recognizeDocument(in: cgImage)
            document = merge(current: document, incoming: result.document)
            quality = result.quality

            guard result.document.hasDetectedIdentityData else {
                errorMessage = "No document or ID details were detected in the selected image."
                return
            }

            let previewImageFileName = try? latestImageData.map {
                try imageStore.saveImageData($0, preferredName: "extracted-\(UUID().uuidString)")
            }

            extractedStaticRecord = SavedKYCRecordSnapshot(
                id: "extracted-\(UUID().uuidString)",
                documentID: document.documentID,
                expiryDate: document.expiryDate,
                cardholderName: document.cardholderName,
                averageConfidence: document.averageConfidence,
                capturedAt: document.capturedAt,
                savedAt: Date(),
                engine: selectedEngine.title,
                imageURL: previewImageFileName.flatMap { imageStore.imageURL(fileName: $0) }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func processFrameIfNeeded(_ frame: CMSampleBuffer) async {
        let now = Date()
        guard now.timeIntervalSince(lastProcessedAt) > 0.8 else { return }
        lastProcessedAt = now

        do {
            let result = try await activeOCRService.recognizeDocument(in: frame)
            document = merge(current: document, incoming: result.document)
            quality = result.quality
            isSaved = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var activeOCRService: OCRServicing {
        switch selectedEngine {
        case .appleVision:
            return appleOCRService
        case .tensorflowLite:
            return tensorflowOCRService
        }
    }

    private func merge(current: KYCDocument, incoming: KYCDocument) -> KYCDocument {
        KYCDocument(
            documentID: incoming.documentID ?? current.documentID,
            expiryDate: incoming.expiryDate ?? current.expiryDate,
            cardholderName: incoming.cardholderName ?? current.cardholderName,
            averageConfidence: max(current.averageConfidence, incoming.averageConfidence),
            capturedAt: incoming.capturedAt
        )
    }
}
