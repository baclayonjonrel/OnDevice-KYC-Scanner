//
//  VisionOCRService.swift
//  OnDevice-KYC-Scanner
//

@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

protocol OCRServicing {
    nonisolated func recognizeDocument(in sampleBuffer: CMSampleBuffer) async throws -> OCRScanResult
    nonisolated func recognizeDocument(in image: CGImage) async throws -> OCRScanResult
}

final class VisionOCRService: OCRServicing {
    nonisolated func recognizeDocument(in sampleBuffer: CMSampleBuffer) async throws -> OCRScanResult {
        let request = makeTextRequest()
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .right,
            options: [:]
        )

        return try performRecognition(
            request: request,
            handler: handler,
            brightness: estimateBrightness(from: sampleBuffer)
        )
    }

    nonisolated func recognizeDocument(in image: CGImage) async throws -> OCRScanResult {
        let request = makeTextRequest()
        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: .up,
            options: [:]
        )

        return try performRecognition(
            request: request,
            handler: handler,
            brightness: estimateBrightness(from: image)
        )
    }

    private nonisolated func makeTextRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.018
        request.recognitionLanguages = ["en-US"]
        return request
    }

    private nonisolated func performRecognition(
        request: VNRecognizeTextRequest,
        handler: VNImageRequestHandler,
        brightness: Double
    ) throws -> OCRScanResult {
        try handler.perform([request])

        let observations = request.results ?? []
        let candidates = observations.compactMap { observation -> RecognizedTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }

        let document = parseDocument(from: candidates)
        let quality = ScanQuality(
            brightness: brightness,
            averageConfidence: candidates.averageConfidence,
            documentCoverage: candidates.documentCoverage,
            recognizedLineCount: candidates.count
        )

        return OCRScanResult(document: document, quality: quality)
    }

    private nonisolated func parseDocument(from lines: [RecognizedTextLine]) -> KYCDocument {
        let text = lines.map(\.text).joined(separator: "\n")
        let normalizedLines = lines
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return KYCDocument(
            documentID: extractDocumentID(from: text),
            expiryDate: extractExpiryDate(from: text),
            cardholderName: extractName(from: normalizedLines),
            averageConfidence: lines.averageConfidence,
            capturedAt: Date()
        )
    }

    private nonisolated func extractDocumentID(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:document|doc|id|license|policy|member)\s*(?:no\.?|number|#|:)?\s*([A-Z0-9-]{6,})"#,
            #"\b[A-Z]{1,3}[0-9][A-Z0-9-]{5,}\b"#,
            #"\b[0-9]{3,4}[-\s]?[0-9]{3,4}[-\s]?[0-9]{3,4}\b"#
        ]

        return firstMatch(in: text, patterns: patterns)
    }

    private nonisolated func extractExpiryDate(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:exp|expiry|expires|valid until)\s*[:\-]?\s*([0-3]?\d[\/\-.][0-1]?\d[\/\-.](?:20)?\d{2})"#,
            #"(?i)(?:exp|expiry|expires|valid until)\s*[:\-]?\s*([0-1]?\d[\/\-.](?:20)?\d{2})"#,
            #"\b(20\d{2}[\/\-.][0-1]?\d[\/\-.][0-3]?\d)\b"#
        ]

        return firstMatch(in: text, patterns: patterns)
    }

    private nonisolated func extractName(from lines: [String]) -> String? {
        let rejectedKeywords = [
            "IDENTIFICATION", "INSURANCE", "LICENSE", "EXP", "VALID", "DOCUMENT", "MEMBER", "POLICY", "DATE"
        ]

        for index in lines.indices {
            let line = lines[index]

            guard line.localizedCaseInsensitiveContains("name") else { continue }

            let cleaned = line
                .replacingOccurrences(of: #"(?i)(cardholder|member|full)?\s*name\s*[:\-]?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isLikelyPersonName(cleaned), !isNameHeader(cleaned) {
                return cleaned
            }

            if let nextName = nearestFollowingName(after: index, in: lines) {
                return nextName
            }
        }

        return lines.first { line in
            let upper = line.uppercased()
            let hasKeyword = rejectedKeywords.contains { upper.contains($0) }
            return !hasKeyword && isLikelyPersonName(line) && !isNameHeader(line)
        }
    }

    private nonisolated func nearestFollowingName(after index: Int, in lines: [String]) -> String? {
        let searchRange = lines.index(after: index)..<Swift.min(lines.endIndex, index + 4)

        return lines[searchRange].first { candidate in
            isLikelyPersonName(candidate) && !isNameHeader(candidate)
        }
    }

    private nonisolated func isLikelyPersonName(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ")

        guard words.count >= 2 && words.count <= 6 else { return false }
        guard trimmed.range(of: #"\d"#, options: .regularExpression) == nil else { return false }
        guard trimmed.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil else { return false }

        return true
    }

    private nonisolated func isNameHeader(_ line: String) -> Bool {
        let normalized = line.uppercased()
            .replacingOccurrences(of: #"[^A-Z ]"#, with: "", options: .regularExpression)
            .split(separator: " ")

        guard !normalized.isEmpty else { return false }

        let labelWords: Set<Substring> = ["FIRST", "GIVEN", "MIDDLE", "LAST", "SURNAME", "NAME", "NAMES"]
        return normalized.allSatisfy { labelWords.contains($0) }
    }

    private nonisolated func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            let captureIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let swiftRange = Range(match.range(at: captureIndex), in: text) else { continue }
            return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private nonisolated func estimateBrightness(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return 0 }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent

        guard
            let outputImage = filter.outputImage
        else {
            return 0
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return (0.2126 * Double(bitmap[0]) + 0.7152 * Double(bitmap[1]) + 0.0722 * Double(bitmap[2])) / 255.0
    }

    private nonisolated func estimateBrightness(from image: CGImage) -> Double {
        let ciImage = CIImage(cgImage: image)
        return estimateBrightness(from: ciImage)
    }

    private nonisolated func estimateBrightness(from image: CIImage) -> Double {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent

        guard let outputImage = filter.outputImage else {
            return 0
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        ciContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return (0.2126 * Double(bitmap[0]) + 0.7152 * Double(bitmap[1]) + 0.0722 * Double(bitmap[2])) / 255.0
    }
}

private struct RecognizedTextLine {
    var text: String
    var confidence: Float
    var boundingBox: CGRect
}

private extension Array where Element == RecognizedTextLine {
    nonisolated var averageConfidence: Float {
        guard !isEmpty else { return 0 }
        return reduce(Float(0)) { $0 + $1.confidence } / Float(count)
    }

    nonisolated var documentCoverage: Double {
        guard !isEmpty else { return 0 }

        let union = map(\.boundingBox).reduce(CGRect.null) { partialResult, rect in
            partialResult.union(rect)
        }

        return Swift.max(0, Swift.min(1, union.width * union.height))
    }
}
