//
//  OCRProcessingEngine.swift
//  KYCOCRSupport
//

public enum OCRProcessingEngine: String, CaseIterable, Identifiable, Sendable {
    case appleVision
    case tensorflowLite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleVision:
            return "Apple Vision"
        case .tensorflowLite:
            return "LiteRT"
        }
    }

    public var detail: String {
        switch self {
        case .appleVision:
            return "Uses VNRecognizeTextRequest fully on device."
        case .tensorflowLite:
            return "Runs the TensorFlow Lite/LiteRT OCR model stack."
        }
    }
}
