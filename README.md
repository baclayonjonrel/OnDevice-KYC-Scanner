# OnDevice KYC Scanner

A native SwiftUI proof-of-concept for an AI neobank onboarding and insurance ID scanning flow. The app demonstrates biometric/passcode access control, live camera capture, on-device OCR, optional TensorFlow Lite / LiteRT model warmup, Realm persistence, protected image snapshots, and privacy-first handling of KYC data.

## What This App Demonstrates

- SwiftUI onboarding UI with a separate login screen and authenticated dashboard.
- Face ID, Touch ID, or device passcode unlock using `LocalAuthentication`.
- Short-lived login session persistence with automatic expiry.
- Live ID scanning with `AVCaptureSession` and `AVCaptureVideoPreviewLayer`.
- On-device OCR using Apple's Vision framework and `VNRecognizeTextRequest`.
- Optional TensorFlow Lite / LiteRT OCR engine path using bundled `.tflite` PP-OCR assets.
- Static image upload from Photos for repeatable demo and interview testing.
- Real-time scan quality feedback for low light, blur/low OCR confidence, and poor positioning.
- Editable review before saving OCR results.
- Saved KYC records and saved ID images with local Realm-backed persistence.
- MVVM-oriented SwiftUI architecture with async/await services.

## Current User Flow

1. User opens the app on a dedicated login screen.
2. User taps **Login** and authenticates with Face ID, Touch ID, or device passcode.
3. A short-lived authenticated session is saved locally and expires after 15 minutes.
4. After unlock, the app shows a 2x2 dashboard:
   - Capture
   - Upload
   - Saved
   - Settings
5. Capture opens the live camera scanner.
6. The yellow guide helps users place the ID card in frame.
7. OCR runs locally and extracts:
   - Cardholder name
   - Document ID
   - Expiry date
8. Save captures the current frame, crops around the yellow guide with extra padding, pauses the camera, and opens an editable review sheet.
9. After review, the app saves the record and image, then opens the saved-record detail screen.
10. Upload validates the selected image with on-device Vision OCR. If no ID data is detected, the app shows an error instead of opening a blank result.
11. Saved records can be opened full screen and edited.

## Privacy And Security

This project is designed around a local-first KYC demo:

- Raw camera frames are processed on device.
- OCR parsing uses Apple Vision locally.
- TensorFlow Lite / LiteRT models are bundled and warmed up locally.
- The app does not upload unencrypted raw images to external servers.
- Authentication uses `LocalAuthentication` with device-owner policy, allowing biometrics or passcode.
- Login persistence stores only a session expiry timestamp, not PII.
- Reviewed KYC data is saved into Realm.
- The Realm encryption key is generated with `SecRandomCopyBytes` and stored in Keychain using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Saved ID image snapshots are written under Application Support with complete file protection and excluded from backup.

## Architecture

The app uses a lightweight MVVM and service-oriented structure:

```text
OnDevice-KYC-Scanner/
  Domain/
    KYCDocument.swift
  Services/
    BiometricAuthenticationService.swift
    CameraCaptureService.swift
    ImageSnapshotService.swift
    KeychainPIIStore.swift
    PPOCRModelResources.swift
    RealmKYCRecordStore.swift
    TensorFlowLiteOCRService.swift
    VisionOCRService.swift
  ViewModels/
    BiometricLockViewModel.swift
    OnboardingCoordinatorViewModel.swift
    SavedKYCRecordsViewModel.swift
    ScannerViewModel.swift
  Views/
    BiometricLockView.swift
    CameraPreviewView.swift
    KYCRecordEditorView.swift
    LandingView.swift
    LoginView.swift
    OCRSettingsView.swift
    SavedKYCRecordsView.swift
    ScannerView.swift
  Resources/
    OCRModels/
      ppocr_det_fp16.tflite
      ppocr_rec_fp16.tflite
      ppocrv5_dict.txt

Packages/
  KYCOCRSupport/
    Sources/KYCOCRSupport/
      OCRProcessingEngine.swift
```

## OCR And ML

### Apple Vision

`VisionOCRService` uses `VNRecognizeTextRequest` for local text recognition. It parses recognized lines into KYC fields using local heuristics and regex rules. This is the primary reliable OCR path in the current app.

### TensorFlow Lite / LiteRT

`TensorFlowLiteOCRService` demonstrates a custom ML runtime path. It loads and warms up bundled PP-OCR detector and recognizer `.tflite` models through the `TensorFlowLite` Swift module.

Current status:

- Model assets are bundled locally.
- TensorFlow Lite interpreters are initialized on device.
- XNNPACK is enabled.
- Apple Vision remains the fallback parser until full PP-OCR post-processing is implemented.

Remaining work for full TensorFlow/LiteRT OCR:

- Decode detector output maps.
- Run text-box post-processing and non-max suppression.
- Crop and rectify detected text regions.
- Run recognition on each crop.
- Decode recognizer output with `ppocrv5_dict.txt`.
- Feed decoded lines into the existing KYC parser.

## Image Capture And Cropping

Live capture uses the yellow scanner guide as the source of truth for saved images:

- The latest camera frame is captured exactly when the user taps Save.
- The camera frame is normalized to portrait before cropping.
- The visible yellow guide is mapped back into image pixels using the same aspect-fill math as the camera preview.
- The crop includes extra padding outside the guide to avoid cutting off important ID edges.
- Static uploaded images can fall back to an on-device Vision text-region crop when no live guide is available.

## Dependencies

### Swift Package Manager

- RealmSwift: https://github.com/realm/realm-swift
- Local package: `Packages/KYCOCRSupport`

### TensorFlow Lite / LiteRT Runtime

The project currently imports the `TensorFlowLite` Swift module for the optional LiteRT demo path.

In this checkout, the official TensorFlow Lite Swift runtime is still configured through CocoaPods:

- TensorFlow Lite Swift source: https://github.com/tensorflow/tensorflow/tree/master/tensorflow/lite/swift
- CocoaPods package: `TensorFlowLiteSwift`

The app is intentionally SPM-first for Realm and local shared code. The remaining CocoaPods target exists only to provide the TensorFlow Lite Swift runtime currently wired in the project.

## Model Assets

Bundled OCR model files live in:

```text
OnDevice-KYC-Scanner/Resources/OCRModels/
```

Expected files:

- `ppocr_det_fp16.tflite`
- `ppocr_rec_fp16.tflite`
- `ppocrv5_dict.txt`

The model set is PP-OCR-style detection plus recognition. A detector-only model such as EAST can locate text boxes, but it does not recognize text content by itself, so it is less useful for complete KYC field extraction.

## Requirements

- Xcode 16 or newer
- iOS 17.0 or newer
- Physical iPhone recommended for camera and biometric testing
- CocoaPods only if using the currently wired `TensorFlowLiteSwift` Pod

## Setup

1. Clone the repository.
2. Resolve Swift Package Manager dependencies in Xcode.
3. If TensorFlow Lite is still wired through CocoaPods in your checkout, install Pods:

```bash
pod install
```

4. Open the workspace:

```bash
open OnDevice-KYC-Scanner.xcworkspace
```

5. Select the `OnDevice-KYC-Scanner` scheme.
6. Run on a physical iOS device for the best camera and biometric experience.

## Build From Terminal

```bash
xcodebuild \
  -workspace OnDevice-KYC-Scanner.xcworkspace \
  -scheme OnDevice-KYC-Scanner \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Important Implementation Notes

- `ContentView` switches between `LoginView` and `LandingView` based on auth session state.
- `LoginView` triggers `LocalAuthentication` and shows a single login action.
- `OnboardingCoordinatorViewModel` stores a short-lived login expiry timestamp.
- `LandingView` presents the authenticated 2x2 action dashboard.
- `ScannerViewModel` owns scan state, OCR engine selection, static image processing, save review, and persistence orchestration.
- `VisionOCRService` performs local OCR and KYC field extraction.
- `TensorFlowLiteOCRService` verifies bundled LiteRT model loading and interpreter setup.
- `ImageSnapshotService` normalizes, crops, pads, and stores protected JPEG snapshots.
- `RealmKYCRecordStore` persists reviewed KYC records.
- `SavedKYCRecordsView` displays saved records, details, images, and edit actions.

## Interview Talking Points

- The app demonstrates a privacy-first KYC flow: camera frames and OCR stay on device.
- The biometric gate protects sensitive saved KYC data and uses the system passcode fallback.
- The short auth session shows practical fintech session handling without storing credentials.
- AVFoundation powers the real-time camera scanner, while Vision powers on-device OCR.
- The crop pipeline maps SwiftUI preview geometry back to camera pixels and preserves ID edges with padding.
- The OCR engine abstraction lets the app switch between Apple Vision and a TensorFlow/LiteRT path.
- Realm demonstrates local persistence for structured KYC data and saved image references.
- The editable review step handles OCR mistakes before saving PII.

## Current Limitations

- Full PP-OCR TensorFlow post-processing is not implemented yet.
- TensorFlow Lite mode warms model interpreters and falls back to Vision for final parsing.
- OCR field extraction uses heuristic parsing and should be expanded for specific ID templates.
- This is a technical demo, not a production KYC compliance system.
