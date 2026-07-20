//
//  CameraCaptureService.swift
//  OnDevice-KYC-Scanner
//

import AVFoundation
import CoreImage
import Foundation

protocol CameraCaptureServicing: AnyObject {
    var session: AVCaptureSession { get }
    var frames: AsyncStream<CMSampleBuffer> { get }

    func configure() async throws
    nonisolated func currentFrame() async throws -> CMSampleBuffer
    func start()
    func stop()
}

enum CameraCaptureError: LocalizedError {
    case unavailable
    case permissionDenied
    case configurationFailed
    case noCurrentFrame

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "No rear camera is available."
        case .permissionDenied:
            return "Camera permission is required to scan an ID."
        case .configurationFailed:
            return "Unable to configure the camera session."
        case .noCurrentFrame:
            return "No camera frame is ready yet."
        }
    }
}

final class CameraCaptureService: NSObject, CameraCaptureServicing, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "kyc.camera.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "kyc.camera.frames", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var latestFrame: CMSampleBuffer?
    private var isConfigured = false

    lazy var frames: AsyncStream<CMSampleBuffer> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            self?.continuation = continuation
            continuation.onTermination = { _ in }
        }
    }()

    func configure() async throws {
        let authorized = await requestCameraAccessIfNeeded()
        guard authorized else { throw CameraCaptureError.permissionDenied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraCaptureError.configurationFailed)
                    return
                }

                do {
                    try self.configureSessionIfNeeded()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    nonisolated func currentFrame() async throws -> CMSampleBuffer {
        try await withCheckedThrowingContinuation { continuation in
            outputQueue.async { [weak self] in
                guard let self, let latestFrame = self.latestFrame else {
                    continuation.resume(throwing: CameraCaptureError.noCurrentFrame)
                    return
                }

                var copiedFrame: CMSampleBuffer?
                let status = CMSampleBufferCreateCopy(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: latestFrame,
                    sampleBufferOut: &copiedFrame
                )

                guard status == noErr, let copiedFrame else {
                    continuation.resume(throwing: CameraCaptureError.noCurrentFrame)
                    return
                }

                continuation.resume(returning: copiedFrame)
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        var copiedFrame: CMSampleBuffer?
        if CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copiedFrame
        ) == noErr {
            latestFrame = copiedFrame
        }

        continuation?.yield(sampleBuffer)
    }

    private func configureSessionIfNeeded() throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera)
        else {
            throw CameraCaptureError.unavailable
        }

        guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
            throw CameraCaptureError.configurationFailed
        }

        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                connection.videoRotationAngle = 90
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
        isConfigured = true
    }

    private func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
