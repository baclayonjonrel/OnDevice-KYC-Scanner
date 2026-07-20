//
//  LandingView.swift
//  OnDevice-KYC-Scanner
//

import KYCOCRSupport
import PhotosUI
import SwiftUI
import UIKit

struct LandingView: View {
    @State private var selectedEngine: OCRProcessingEngine = .appleVision
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var uploadedImage: UIImage?
    @State private var isShowingUploadedScanner = false
    @State private var isValidatingUpload = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                LazyVGrid(columns: columns, spacing: 14) {
                    NavigationLink {
                        makeScannerView()
                    } label: {
                        LandingTile(
                            title: "Capture",
                            systemImage: "viewfinder",
                            tint: .blue
                        )
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        LandingTile(
                            title: "Upload",
                            systemImage: isValidatingUpload ? "hourglass" : "photo.badge.plus",
                            tint: .green,
                            isLoading: isValidatingUpload
                        )
                    }
                    .disabled(isValidatingUpload)

                    NavigationLink {
                        SavedKYCRecordsView()
                    } label: {
                        LandingTile(
                            title: "Saved",
                            systemImage: "tray.full",
                            tint: .indigo
                        )
                    }

                    NavigationLink {
                        OCRSettingsView(selectedEngine: $selectedEngine)
                    } label: {
                        LandingTile(
                            title: "Settings",
                            systemImage: "slider.horizontal.3",
                            tint: .orange
                        )
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("KYC Onboarding")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingUploadedScanner) {
            if let uploadedImage {
                makeScannerView(initialImage: uploadedImage)
            }
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
                    errorMessage = "Unable to load the selected image."
                    return
                }

                await validateAndOpenUploadedImage(image)
            }
        }
        .alert("Upload Error", isPresented: uploadErrorIsPresented) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(.black, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("Secure ID Workspace")
                    .font(.title2.weight(.bold))

                Text(selectedEngine.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var uploadErrorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private func makeScannerView(initialImage: UIImage? = nil) -> ScannerView {
        ScannerView(
            viewModel: ScannerViewModel(
                cameraService: CameraCaptureService(),
                appleOCRService: VisionOCRService(),
                tensorflowOCRService: TensorFlowLiteOCRService(),
                recordStore: RealmKYCRecordStore(),
                imageStore: ImageSnapshotService(),
                initialEngine: selectedEngine
            ),
            selectedEngine: $selectedEngine,
            initialImage: initialImage
        )
    }

    private func validateAndOpenUploadedImage(_ image: UIImage) async {
        guard let cgImage = image.cgImage else {
            errorMessage = "Unable to read the selected image."
            return
        }

        isValidatingUpload = true
        defer {
            isValidatingUpload = false
        }

        do {
            let result = try await VisionOCRService().recognizeDocument(in: cgImage)
            guard result.document.hasDetectedIdentityData else {
                errorMessage = "No document or ID details were detected in the selected image."
                return
            }

            uploadedImage = image
            isShowingUploadedScanner = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LandingTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.14))

                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 58, height: 58)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
