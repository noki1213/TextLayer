import CoreGraphics
import Foundation
import Vision

/// A line of recognized text. `box` is normalized to the image (0...1) with its origin at the
/// bottom-left, the same way up as a PDF page.
public struct RecognizedLine: Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Reads text from images with Vision, tuned for Japanese and English documents.
public enum TextRecognizer {
    public static let languages = ["ja-JP", "en-US"]

    /// Blocks the calling thread. Safe to call from several threads at once.
    public static func recognizeLines(in image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        configure(request)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return RecognizedLine(text: text, box: observation.boundingBox)
        }
    }

    public static func configure(_ request: VNRecognizeTextRequest) {
        request.recognitionLanguages = languages
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
    }
}
