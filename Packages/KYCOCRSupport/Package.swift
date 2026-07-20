// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KYCOCRSupport",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "KYCOCRSupport",
            targets: ["KYCOCRSupport"]
        )
    ],
    targets: [
        .target(name: "KYCOCRSupport")
    ]
)
