//
//  ImageSnapshotService.swift
//  OnDevice-KYC-Scanner
//

@preconcurrency import AVFoundation
import CoreImage
import Foundation
import UIKit
import Vision

enum ImageSnapshotError: LocalizedError {
    case missingPixelBuffer
    case conversionFailed
    case directoryUnavailable

    var errorDescription: String? {
        switch self {
        case .missingPixelBuffer:
            return "Unable to read camera frame pixels."
        case .conversionFailed:
            return "Unable to create an image snapshot."
        case .directoryUnavailable:
            return "Unable to access secure image storage."
        }
    }
}

struct ScannerCropGuide: Equatable {
    let viewportSize: CGSize
    let guideRect: CGRect
}

protocol ImageSnapshotStoring {
    func jpegData(from sampleBuffer: CMSampleBuffer) throws -> Data
    func jpegData(from sampleBuffer: CMSampleBuffer, cropGuide: ScannerCropGuide?) throws -> Data
    func jpegData(from image: UIImage) throws -> Data
    func jpegData(from image: UIImage, cropGuide: ScannerCropGuide?) throws -> Data
    func saveImageData(_ data: Data, preferredName: String) throws -> String
    func imageURL(fileName: String) -> URL?
}

final class ImageSnapshotService: ImageSnapshotStoring {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func jpegData(from sampleBuffer: CMSampleBuffer) throws -> Data {
        try jpegData(from: sampleBuffer, cropGuide: nil)
    }

    func jpegData(from sampleBuffer: CMSampleBuffer, cropGuide: ScannerCropGuide?) throws -> Data {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ImageSnapshotError.missingPixelBuffer
        }

        let cameraImage = CIImage(cvPixelBuffer: pixelBuffer)
        let orientation: CGImagePropertyOrientation = cameraImage.extent.width > cameraImage.extent.height ? .right : .up
        let ciImage = cameraImage.oriented(orientation)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw ImageSnapshotError.conversionFailed
        }

        let image = UIImage(cgImage: cgImage)
        return try jpegData(from: image, cropGuide: cropGuide)
    }

    func jpegData(from image: UIImage) throws -> Data {
        try jpegData(from: image, cropGuide: nil)
    }

    func jpegData(from image: UIImage, cropGuide: ScannerCropGuide?) throws -> Data {
        let croppedImage = cropToScannerGuide(normalizedForCropping(image), cropGuide: cropGuide)
        guard let data = croppedImage.jpegData(compressionQuality: 0.82) else {
            throw ImageSnapshotError.conversionFailed
        }

        return data
    }

    func saveImageData(_ data: Data, preferredName: String) throws -> String {
        let directory = try imageDirectory()
        let fileName = "\(preferredName).jpg"
        let url = directory.appendingPathComponent(fileName, conformingTo: .jpeg)
        try data.write(to: url, options: [.atomic, .completeFileProtection])

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)

        return fileName
    }

    func imageURL(fileName: String) -> URL? {
        guard let directory = try? imageDirectory() else { return nil }
        return directory.appendingPathComponent(fileName, conformingTo: .jpeg)
    }

    private func imageDirectory() throws -> URL {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ImageSnapshotError.directoryUnavailable
        }

        let directory = supportDirectory.appendingPathComponent("KYCImages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        return directory
    }

    private func cropToScannerGuide(_ image: UIImage, cropGuide: ScannerCropGuide?) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        if let guidedCrop = cropToVisibleGuide(image, cgImage: cgImage, cropGuide: cropGuide) {
            return guidedCrop
        }

        if let textCrop = cropToDetectedTextRegion(image, cgImage: cgImage) {
            return textCrop
        }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let targetAspect: CGFloat = 1.0 / 0.62
        let imageAspect = pixelWidth / pixelHeight

        let cropSize: CGSize
        if imageAspect > targetAspect {
            cropSize = CGSize(width: pixelHeight * targetAspect, height: pixelHeight)
        } else {
            cropSize = CGSize(width: pixelWidth, height: pixelWidth / targetAspect)
        }

        let isPortrait = pixelHeight > pixelWidth
        let centerY = isPortrait ? pixelHeight * 0.42 : pixelHeight * 0.5
        let origin = CGPoint(
            x: max(0, (pixelWidth - cropSize.width) / 2),
            y: min(max(0, centerY - cropSize.height / 2), pixelHeight - cropSize.height)
        )

        let cropRect = CGRect(origin: origin, size: cropSize).integral
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }

        return UIImage(
            cgImage: croppedCGImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }

    private func cropToVisibleGuide(
        _ image: UIImage,
        cgImage: CGImage,
        cropGuide: ScannerCropGuide?
    ) -> UIImage? {
        guard
            let cropGuide,
            cropGuide.viewportSize.width > 0,
            cropGuide.viewportSize.height > 0,
            cropGuide.guideRect.width > 0,
            cropGuide.guideRect.height > 0
        else {
            return nil
        }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = max(
            cropGuide.viewportSize.width / imageSize.width,
            cropGuide.viewportSize.height / imageSize.height
        )
        guard scale.isFinite, scale > 0 else { return nil }

        let scaledSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let croppedByPreview = CGPoint(
            x: max(0, (scaledSize.width - cropGuide.viewportSize.width) / 2),
            y: max(0, (scaledSize.height - cropGuide.viewportSize.height) / 2)
        )

        let paddedGuideRect = cropGuide.guideRect.insetBy(
            dx: -cropGuide.guideRect.width * 0.08,
            dy: -cropGuide.guideRect.height * 0.12
        )
        let rectInPixels = CGRect(
            x: (paddedGuideRect.minX + croppedByPreview.x) / scale,
            y: (paddedGuideRect.minY + croppedByPreview.y) / scale,
            width: paddedGuideRect.width / scale,
            height: paddedGuideRect.height / scale
        )
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let cropRect = rectInPixels.intersection(imageBounds).integral

        guard
            cropRect.width > 1,
            cropRect.height > 1,
            let croppedCGImage = cgImage.cropping(to: cropRect)
        else {
            return nil
        }

        return UIImage(
            cgImage: croppedCGImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }

    private func cropToDetectedTextRegion(_ image: UIImage, cgImage: CGImage) -> UIImage? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.018

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])

        let observations = (request.results ?? []).filter { observation in
            guard let candidate = observation.topCandidates(1).first else { return false }
            return candidate.confidence >= 0.35
        }
        guard observations.count >= 3 else { return nil }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let textBounds = observations
            .map { pixelRect(fromVisionBoundingBox: $0.boundingBox, imageSize: imageSize) }
            .reduce(CGRect.null) { partialResult, rect in
                partialResult.union(rect)
            }

        guard !textBounds.isNull, textBounds.width > 1, textBounds.height > 1 else { return nil }

        let paddedRect = expandedIDRect(around: textBounds, imageSize: imageSize)
        guard let croppedCGImage = cgImage.cropping(to: paddedRect.integral) else { return nil }

        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: .up)
    }

    private func pixelRect(fromVisionBoundingBox boundingBox: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: boundingBox.minX * imageSize.width,
            y: (1 - boundingBox.maxY) * imageSize.height,
            width: boundingBox.width * imageSize.width,
            height: boundingBox.height * imageSize.height
        )
    }

    private func expandedIDRect(around textBounds: CGRect, imageSize: CGSize) -> CGRect {
        let targetAspect: CGFloat = 1.0 / 0.62
        let padded = textBounds.insetBy(dx: -textBounds.width * 0.35, dy: -textBounds.height * 0.75)
        let width = max(padded.width, padded.height * targetAspect)
        let height = max(padded.height, width / targetAspect)
        let centered = CGRect(
            x: padded.midX - width / 2,
            y: padded.midY - height / 2,
            width: width,
            height: height
        )
        let imageBounds = CGRect(origin: .zero, size: imageSize)

        return centered.intersection(imageBounds)
    }

    private func normalizedForCropping(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
