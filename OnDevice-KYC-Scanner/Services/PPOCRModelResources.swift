//
//  PPOCRModelResources.swift
//  OnDevice-KYC-Scanner
//

import Foundation

enum PPOCRModelResources {
    nonisolated static let detectorFileName = "ppocr_det_fp16"
    nonisolated static let recognizerFileName = "ppocr_rec_fp16"
    nonisolated static let dictionaryFileName = "ppocrv5_dict"
    nonisolated static let resourceSubdirectory = "Resources/OCRModels"

    nonisolated static func detectorURL(bundle: Bundle = .main) -> URL? {
        resourceURL(
            detectorFileName,
            extension: "tflite",
            bundle: bundle
        )
    }

    nonisolated static func recognizerURL(bundle: Bundle = .main) -> URL? {
        resourceURL(
            recognizerFileName,
            extension: "tflite",
            bundle: bundle
        )
    }

    nonisolated static func dictionaryURL(bundle: Bundle = .main) -> URL? {
        resourceURL(
            dictionaryFileName,
            extension: "txt",
            bundle: bundle
        )
    }

    private nonisolated static func resourceURL(
        _ name: String,
        extension fileExtension: String,
        bundle: Bundle
    ) -> URL? {
        bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: resourceSubdirectory
        ) ?? bundle.url(
            forResource: name,
            withExtension: fileExtension
        )
    }
}
