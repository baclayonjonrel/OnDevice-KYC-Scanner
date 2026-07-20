//
//  TensorFlowLiteOCRService.swift
//  OnDevice-KYC-Scanner
//

@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TensorFlowLite
import UIKit

enum TensorFlowLiteOCRError: LocalizedError {
    case missingModelResource(String)
    case modelWarmupFailed(String)
    case unsupportedTensor(String)
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .missingModelResource(let name):
            return "Missing LiteRT OCR resource: \(name)."
        case .modelWarmupFailed(let reason):
            return "LiteRT OCR model warmup failed: \(reason)"
        case .unsupportedTensor(let reason):
            return "Unsupported LiteRT OCR tensor: \(reason)"
        case .imageConversionFailed:
            return "Unable to prepare camera frame for LiteRT OCR."
        }
    }
}

final class TensorFlowLiteOCRService: OCRServicing {
    private nonisolated let fallbackOCRService = VisionOCRService()
    private nonisolated let inferenceLock = NSLock()
    private nonisolated let ciContext = CIContext(options: [.cacheIntermediates: false])
    private nonisolated(unsafe) var detector: Interpreter?
    private nonisolated(unsafe) var recognizer: Interpreter?
    private nonisolated(unsafe) var dictionary: [String] = []

    nonisolated func prepare() async throws {
        try withInferenceLock {
            try preparePPOCRInterpreters()
        }
    }

    nonisolated func recognizeDocument(in sampleBuffer: CMSampleBuffer) async throws -> OCRScanResult {
        guard let image = makeCGImage(from: sampleBuffer, orientation: .right) else {
            return try await fallbackOCRService.recognizeDocument(in: sampleBuffer)
        }

        let result = try await recognizeDocumentWithFallback(in: image)
        return result.withBrightness(estimateBrightness(from: sampleBuffer))
    }

    nonisolated func recognizeDocument(in image: CGImage) async throws -> OCRScanResult {
        try await recognizeDocumentWithFallback(in: image)
    }

    private nonisolated func recognizeDocumentWithFallback(in image: CGImage) async throws -> OCRScanResult {
        let result: OCRScanResult

        do {
            result = try recognizeDocumentWithTensorFlow(in: image)
        } catch {
            return try await fallbackOCRService.recognizeDocument(in: image)
        }

        guard result.document.hasLiteRTDetectedIdentityData || result.quality.recognizedLineCount > 0 else {
            return try await fallbackOCRService.recognizeDocument(in: image)
        }

        return result
    }

    private nonisolated func recognizeDocumentWithTensorFlow(in image: CGImage) throws -> OCRScanResult {
        try withInferenceLock {
            try preparePPOCRInterpreters()

            guard
                let detector,
                let recognizer
            else {
                throw TensorFlowLiteOCRError.modelWarmupFailed("Interpreters were not initialized.")
            }

            let regions = try detectTextRegions(in: image, using: detector)
            let lines = try regions.compactMap { region -> LiteRTRecognizedTextLine? in
                guard let crop = cropImage(image, to: region.imageRect) else { return nil }
                guard let text = try recognizeText(in: crop, using: recognizer), !text.value.isEmpty else { return nil }

                return LiteRTRecognizedTextLine(
                    text: text.value,
                    confidence: text.confidence,
                    boundingBox: region.normalizedRect
                )
            }

            let document = parseDocument(from: lines)
            let quality = ScanQuality(
                brightness: estimateBrightness(from: image),
                averageConfidence: lines.averageConfidence,
                documentCoverage: lines.documentCoverage,
                recognizedLineCount: lines.count
            )

            return OCRScanResult(document: document, quality: quality)
        }
    }

    private nonisolated func withInferenceLock<T>(_ body: () throws -> T) rethrows -> T {
        inferenceLock.lock()
        defer {
            inferenceLock.unlock()
        }

        return try body()
    }

    private nonisolated func preparePPOCRInterpreters() throws {
        guard detector == nil || recognizer == nil || dictionary.isEmpty else { return }

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
            options.isXNNPackEnabled = false

            let detector = try Interpreter(modelPath: detectorURL.path, options: options)
            try detector.allocateTensors()
            _ = try detector.input(at: 0)

            let recognizer = try Interpreter(modelPath: recognizerURL.path, options: options)
            try recognizer.allocateTensors()
            _ = try recognizer.input(at: 0)

            self.detector = detector
            self.recognizer = recognizer
            self.dictionary = try loadDictionary()
        } catch {
            throw TensorFlowLiteOCRError.modelWarmupFailed(error.localizedDescription)
        }
    }

    private nonisolated func detectTextRegions(
        in image: CGImage,
        using interpreter: Interpreter
    ) throws -> [DetectedTextRegion] {
        try interpreter.allocateTensors()
        let input = try interpreter.input(at: 0)
        let layout = try ImageTensorLayout(input.shape.dimensions)
        let inputData = try makeImageTensorData(
            from: image,
            width: layout.width,
            height: layout.height,
            channelOrder: layout.channelOrder
        )

        try interpreter.copy(inputData, toInputAt: 0)
        try interpreter.invoke()

        let output = try interpreter.output(at: 0)
        let scores = try output.floatArray()
        let dimensions = output.shape.dimensions
        guard let map = DetectionMap(dimensions: dimensions, values: scores) else {
            throw TensorFlowLiteOCRError.unsupportedTensor("Detector output shape \(dimensions)")
        }

        return map.connectedRegions(
            imageWidth: image.width,
            imageHeight: image.height
        )
    }

    private nonisolated func recognizeText(
        in image: CGImage,
        using interpreter: Interpreter
    ) throws -> (value: String, confidence: Float)? {
        try interpreter.allocateTensors()
        let input = try interpreter.input(at: 0)
        let layout = try ImageTensorLayout(input.shape.dimensions)
        let inputData = try makeImageTensorData(
            from: image,
            width: layout.width,
            height: layout.height,
            channelOrder: layout.channelOrder
        )

        try interpreter.copy(inputData, toInputAt: 0)
        try interpreter.invoke()

        let output = try interpreter.output(at: 0)
        return try decodeRecognizerOutput(output)
    }

    private nonisolated func decodeRecognizerOutput(_ output: Tensor) throws -> (value: String, confidence: Float)? {
        let values = try output.floatArray()
        let dimensions = output.shape.dimensions
        guard dimensions.count >= 2 else {
            throw TensorFlowLiteOCRError.unsupportedTensor("Recognizer output shape \(dimensions)")
        }

        let timeSteps: Int
        let classCount: Int
        let baseOffset: Int

        if dimensions.count == 3 {
            timeSteps = dimensions[1]
            classCount = dimensions[2]
            baseOffset = 0
        } else if dimensions.count == 2 {
            timeSteps = dimensions[0]
            classCount = dimensions[1]
            baseOffset = 0
        } else {
            timeSteps = dimensions[dimensions.count - 2]
            classCount = dimensions[dimensions.count - 1]
            baseOffset = 0
        }

        guard timeSteps > 0, classCount > 1, values.count >= timeSteps * classCount else {
            return nil
        }

        var previousIndex = 0
        var characters: [String] = []
        var confidences: [Float] = []

        for step in 0..<timeSteps {
            let offset = baseOffset + step * classCount
            var bestIndex = 0
            var bestValue = values[offset]

            for index in 1..<classCount {
                let value = values[offset + index]
                if value > bestValue {
                    bestIndex = index
                    bestValue = value
                }
            }

            let dictionaryIndex = bestIndex - 1
            if bestIndex != 0, bestIndex != previousIndex, dictionary.indices.contains(dictionaryIndex) {
                characters.append(dictionary[dictionaryIndex])
                confidences.append(bestValue)
            }

            previousIndex = bestIndex
        }

        let text = characters.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let confidence = confidences.isEmpty ? Float(0) : confidences.reduce(0, +) / Float(confidences.count)
        return (text, confidence)
    }

    private nonisolated func makeImageTensorData(
        from image: CGImage,
        width: Int,
        height: Int,
        channelOrder: ImageTensorLayout.ChannelOrder
    ) throws -> Data {
        guard let resized = resizeImage(image, width: width, height: height) else {
            throw TensorFlowLiteOCRError.imageConversionFailed
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TensorFlowLiteOCRError.imageConversionFailed
        }

        context.draw(resized, in: CGRect(x: 0, y: 0, width: width, height: height))

        var floats = [Float]()
        floats.reserveCapacity(width * height * 3)

        switch channelOrder {
        case .nhwc:
            for index in stride(from: 0, to: pixels.count, by: 4) {
                appendNormalizedRGB(from: pixels, at: index, to: &floats)
            }
        case .nchw:
            for channel in 0..<3 {
                for pixelIndex in stride(from: 0, to: pixels.count, by: 4) {
                    floats.append(normalizedChannelValue(pixels[pixelIndex + channel]))
                }
            }
        }

        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private nonisolated func appendNormalizedRGB(
        from pixels: [UInt8],
        at index: Int,
        to floats: inout [Float]
    ) {
        floats.append(normalizedChannelValue(pixels[index]))
        floats.append(normalizedChannelValue(pixels[index + 1]))
        floats.append(normalizedChannelValue(pixels[index + 2]))
    }

    private nonisolated func normalizedChannelValue(_ value: UInt8) -> Float {
        (Float(value) / 255.0 - 0.5) / 0.5
    }

    private nonisolated func resizeImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let sourceImage = CIImage(cgImage: image)
        let transform = CGAffineTransform(
            scaleX: CGFloat(width) / sourceImage.extent.width,
            y: CGFloat(height) / sourceImage.extent.height
        )
        let outputImage = sourceImage.transformed(by: transform)
        return ciContext.createCGImage(
            outputImage,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    private nonisolated func cropImage(_ image: CGImage, to rect: CGRect) -> CGImage? {
        image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }

    private nonisolated func makeCGImage(
        from sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        return ciContext.createCGImage(image, from: image.extent)
    }

    private nonisolated func loadDictionary() throws -> [String] {
        guard let url = PPOCRModelResources.dictionaryURL() else {
            throw TensorFlowLiteOCRError.missingModelResource("ppocrv5_dict.txt")
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private nonisolated func parseDocument(from lines: [LiteRTRecognizedTextLine]) -> KYCDocument {
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
        return estimateBrightness(from: CIImage(cvPixelBuffer: pixelBuffer))
    }

    private nonisolated func estimateBrightness(from image: CGImage) -> Double {
        estimateBrightness(from: CIImage(cgImage: image))
    }

    private nonisolated func estimateBrightness(from image: CIImage) -> Double {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent

        guard let outputImage = filter.outputImage else { return 0 }

        var bitmap = [UInt8](repeating: 0, count: 4)
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

private struct ImageTensorLayout {
    enum ChannelOrder {
        case nhwc
        case nchw
    }

    var width: Int
    var height: Int
    var channelOrder: ChannelOrder

    nonisolated init(_ dimensions: [Int]) throws {
        guard dimensions.count == 4 else {
            throw TensorFlowLiteOCRError.unsupportedTensor("Image input shape \(dimensions)")
        }

        if dimensions[3] == 3 {
            height = dimensions[1]
            width = dimensions[2]
            channelOrder = .nhwc
        } else if dimensions[1] == 3 {
            height = dimensions[2]
            width = dimensions[3]
            channelOrder = .nchw
        } else {
            throw TensorFlowLiteOCRError.unsupportedTensor("Image input shape \(dimensions)")
        }
    }
}

private struct DetectionMap {
    var width: Int
    var height: Int
    var values: [Float]

    nonisolated init?(dimensions: [Int], values: [Float]) {
        guard dimensions.count >= 2 else { return nil }

        if dimensions.count == 4 {
            if dimensions[3] == 1 {
                height = dimensions[1]
                width = dimensions[2]
            } else if dimensions[1] == 1 {
                height = dimensions[2]
                width = dimensions[3]
            } else {
                return nil
            }
        } else if dimensions.count == 3 {
            height = dimensions[1]
            width = dimensions[2]
        } else {
            height = dimensions[0]
            width = dimensions[1]
        }

        guard width > 0, height > 0, values.count >= width * height else { return nil }
        self.values = values
    }

    nonisolated func connectedRegions(imageWidth: Int, imageHeight: Int) -> [DetectedTextRegion] {
        let threshold: Float = 0.30
        let minimumArea = Swift.max(6, width * height / 2500)
        var visited = [Bool](repeating: false, count: width * height)
        var regions: [DetectedTextRegion] = []

        for index in values.indices where index < width * height {
            guard values[index] >= threshold, !visited[index] else { continue }

            var stack = [index]
            visited[index] = true
            var minX = width
            var maxX = 0
            var minY = height
            var maxY = 0
            var area = 0

            while let current = stack.popLast() {
                let x = current % width
                let y = current / width
                area += 1
                minX = Swift.min(minX, x)
                maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y)
                maxY = Swift.max(maxY, y)

                for neighbor in neighbors(x: x, y: y) {
                    guard !visited[neighbor], values[neighbor] >= threshold else { continue }
                    visited[neighbor] = true
                    stack.append(neighbor)
                }
            }

            guard area >= minimumArea else { continue }

            let padding: CGFloat = 0.015
            let normalizedX = CGFloat(minX) / CGFloat(width)
            let normalizedY = CGFloat(minY) / CGFloat(height)
            let normalizedWidth = CGFloat(maxX - minX + 1) / CGFloat(width)
            let normalizedHeight = CGFloat(maxY - minY + 1) / CGFloat(height)
            let normalizedRect = CGRect(
                x: normalizedX - padding,
                y: normalizedY - padding,
                width: normalizedWidth + padding * 2,
                height: normalizedHeight + padding * 2
            ).standardized.clampedToUnit

            let imageRect = CGRect(
                x: normalizedRect.minX * CGFloat(imageWidth),
                y: normalizedRect.minY * CGFloat(imageHeight),
                width: normalizedRect.width * CGFloat(imageWidth),
                height: normalizedRect.height * CGFloat(imageHeight)
            )

            regions.append(DetectedTextRegion(
                imageRect: imageRect,
                normalizedRect: normalizedRect
            ))
        }

        return regions
            .sorted { lhs, rhs in
                if abs(lhs.normalizedRect.minY - rhs.normalizedRect.minY) > 0.04 {
                    return lhs.normalizedRect.minY < rhs.normalizedRect.minY
                }
                return lhs.normalizedRect.minX < rhs.normalizedRect.minX
            }
            .prefix(32)
            .map { $0 }
    }

    private nonisolated func neighbors(x: Int, y: Int) -> [Int] {
        var result: [Int] = []
        for nextY in Swift.max(0, y - 1)...Swift.min(height - 1, y + 1) {
            for nextX in Swift.max(0, x - 1)...Swift.min(width - 1, x + 1) {
                guard nextX != x || nextY != y else { continue }
                result.append(nextY * width + nextX)
            }
        }
        return result
    }
}

private struct DetectedTextRegion {
    var imageRect: CGRect
    var normalizedRect: CGRect
}

private struct LiteRTRecognizedTextLine {
    var text: String
    var confidence: Float
    var boundingBox: CGRect
}

private extension Tensor {
    nonisolated func floatArray() throws -> [Float] {
        switch dataType {
        case .float32:
            return data.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        case .uInt8:
            guard let quantizationParameters else {
                return data.map { Float($0) }
            }
            return data.map {
                (Float(Int($0) - quantizationParameters.zeroPoint)) * quantizationParameters.scale
            }
        default:
            throw TensorFlowLiteOCRError.unsupportedTensor("\(name) uses \(dataType)")
        }
    }
}

private extension CGRect {
    nonisolated var clampedToUnit: CGRect {
        let minX = Swift.max(0, self.minX)
        let minY = Swift.max(0, self.minY)
        let maxX = Swift.min(1, self.maxX)
        let maxY = Swift.min(1, self.maxY)
        return CGRect(x: minX, y: minY, width: Swift.max(0, maxX - minX), height: Swift.max(0, maxY - minY))
    }
}

private extension OCRScanResult {
    nonisolated func withBrightness(_ brightness: Double) -> OCRScanResult {
        OCRScanResult(
            document: document,
            quality: ScanQuality(
                brightness: brightness,
                averageConfidence: quality.averageConfidence,
                documentCoverage: quality.documentCoverage,
                recognizedLineCount: quality.recognizedLineCount
            )
        )
    }
}

private extension KYCDocument {
    nonisolated var hasLiteRTDetectedIdentityData: Bool {
        [documentID, expiryDate, cardholderName].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private extension Array where Element == LiteRTRecognizedTextLine {
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
