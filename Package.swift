// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TextLayer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "textlayer", targets: ["textlayer"]),
        // Vision text recognition and invisible-text drawing, for apps that build searchable PDFs
        .library(name: "TextRecognition", targets: ["TextRecognition"]),
        .library(name: "PDFTextLayer", targets: ["PDFTextLayer"]),
    ],
    targets: [
        .target(name: "TextRecognition"),
        .target(name: "PDFTextLayer", dependencies: ["TextRecognition"]),
        .executableTarget(name: "textlayer", dependencies: ["PDFTextLayer"]),
        .testTarget(name: "PDFTextLayerTests", dependencies: ["PDFTextLayer", "TextRecognition"]),
    ]
)
