//
//  TensorFlowLiteOCRService.swift
//  OnDevice-KYC-Scanner
//

@preconcurrency import AVFoundation
import Foundation
import TensorFlowLite

enum TensorFlowLiteOCRError: LocalizedError {
    case missingModelResource(String)
    case modelWarmupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingModelResource(let name):
            return "Missing LiteRT OCR resource: \(name)."
        case .modelWarmupFailed(let reason):
            return "LiteRT OCR model warmup failed: \(reason)"
        }
    }
}

final class TensorFlowLiteOCRService: OCRServicing {
    private nonisolated let fallbackOCRService = VisionOCRService()
    private nonisolated let warmUpLock = NSLock()
    private nonisolated(unsafe) var isWarm = false

    nonisolated func prepare() async throws {
        try warmUpPPOCRInterpreters()
    }

    nonisolated func recognizeDocument(in sampleBuffer: CMSampleBuffer) async throws -> OCRScanResult {
        try warmUpPPOCRInterpreters()

        // The LiteRT runtime is exercised above. Full PP-OCR postprocessing still requires:
        // detection map decoding, non-max suppression, crop rectification, recognition decoding,
        // and dictionary lookup. Until that layer is complete, keep parsing on-device with Vision.
        return try await fallbackOCRService.recognizeDocument(in: sampleBuffer)
    }

    nonisolated func recognizeDocument(in image: CGImage) async throws -> OCRScanResult {
        try warmUpPPOCRInterpreters()
        return try await fallbackOCRService.recognizeDocument(in: image)
    }

    private nonisolated func warmUpPPOCRInterpreters() throws {
        warmUpLock.lock()
        defer {
            warmUpLock.unlock()
        }

        guard !isWarm else { return }

        guard let detectorURL = PPOCRModelResources.detectorURL() else {
            throw TensorFlowLiteOCRError.missingModelResource("ppocr_det_fp16.tflite")
        }

        guard let recognizerURL = PPOCRModelResources.recognizerURL() else {
            throw TensorFlowLiteOCRError.missingModelResource("ppocr_rec_fp16.tflite")
        }

        guard PPOCRModelResources.dictionaryURL() != nil else {
            throw TensorFlowLiteOCRError.missingModelResource("ppocrv5_dict.txt")
        }

        do {
            var options = Interpreter.Options()
            options.threadCount = 2
            options.isXNNPackEnabled = true

            let detector = try Interpreter(modelPath: detectorURL.path, options: options)
            try detector.allocateTensors()
            _ = try detector.input(at: 0)

            let recognizer = try Interpreter(modelPath: recognizerURL.path, options: options)
            try recognizer.allocateTensors()
            _ = try recognizer.input(at: 0)

            isWarm = true
        } catch {
            throw TensorFlowLiteOCRError.modelWarmupFailed(error.localizedDescription)
        }
    }
}
