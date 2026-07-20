//
//  KYCDocument.swift
//  OnDevice-KYC-Scanner
//

import Foundation

struct KYCDocument: Codable, Equatable {
    var documentID: String?
    var expiryDate: String?
    var cardholderName: String?
    var averageConfidence: Float
    var capturedAt: Date

    var completionRatio: Double {
        let populatedFields = [documentID, expiryDate, cardholderName]
            .filter { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

        return Double(populatedFields.count) / 3.0
    }

    var isComplete: Bool {
        completionRatio == 1.0 && averageConfidence >= 0.55
    }

    var hasDetectedIdentityData: Bool {
        [documentID, expiryDate, cardholderName].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct EditableKYCRecord: Equatable {
    var cardholderName: String
    var documentID: String
    var expiryDate: String

    init(
        cardholderName: String = "",
        documentID: String = "",
        expiryDate: String = ""
    ) {
        self.cardholderName = cardholderName
        self.documentID = documentID
        self.expiryDate = expiryDate
    }

    init(document: KYCDocument) {
        self.init(
            cardholderName: document.cardholderName ?? "",
            documentID: document.documentID ?? "",
            expiryDate: document.expiryDate ?? ""
        )
    }

    init(record: SavedKYCRecordSnapshot) {
        self.init(
            cardholderName: record.cardholderName ?? "",
            documentID: record.documentID ?? "",
            expiryDate: record.expiryDate ?? ""
        )
    }

    var hasRequiredFields: Bool {
        !normalized(cardholderName).isEmpty &&
        !normalized(documentID).isEmpty &&
        !normalized(expiryDate).isEmpty
    }

    func applying(to document: KYCDocument) -> KYCDocument {
        KYCDocument(
            documentID: normalizedOptional(documentID),
            expiryDate: normalizedOptional(expiryDate),
            cardholderName: normalizedOptional(cardholderName),
            averageConfidence: document.averageConfidence,
            capturedAt: document.capturedAt
        )
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = normalized(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ScanQuality: Equatable {
    var brightness: Double
    var averageConfidence: Float
    var documentCoverage: Double
    var recognizedLineCount: Int

    var issues: [ScanQualityIssue] {
        var result: [ScanQualityIssue] = []

        if brightness < 0.18 {
            result.append(.lowLight)
        }

        if averageConfidence > 0 && averageConfidence < 0.52 {
            result.append(.blur)
        }

        if documentCoverage < 0.32 || recognizedLineCount < 3 {
            result.append(.poorPositioning)
        }

        return result
    }
}

enum ScanQualityIssue: String, Identifiable {
    case lowLight
    case blur
    case poorPositioning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowLight:
            return "Low light"
        case .blur:
            return "Image blur"
        case .poorPositioning:
            return "Poor positioning"
        }
    }

    var guidance: String {
        switch self {
        case .lowLight:
            return "Move near a brighter light source."
        case .blur:
            return "Hold steady and keep the card in focus."
        case .poorPositioning:
            return "Center the full ID inside the frame."
        }
    }

    var systemImage: String {
        switch self {
        case .lowLight:
            return "sun.min"
        case .blur:
            return "camera.metering.unknown"
        case .poorPositioning:
            return "viewfinder"
        }
    }
}

struct OCRScanResult: Equatable {
    var document: KYCDocument
    var quality: ScanQuality
}
