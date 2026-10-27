import CoreGraphics
import Foundation
import Vision

/// A line of recognized text. Points are normalized to the image (0...1) with the origin at the
/// bottom-left, the same way up as a PDF page. The text reads from the left edge (bottomLeft to
/// topLeft) towards the right edge, and its glyphs stand on the bottom edge: a line of vertical
/// Japanese has its "bottom" edge on the left of the column and reads downwards.
public struct RecognizedLine: Sendable {
    public var text: String
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomLeft: CGPoint
    public var bottomRight: CGPoint

    public init(text: String, topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        self.text = text
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// An upright line filling box
    public init(text: String, box: CGRect) {
        self.init(
            text: text,
            topLeft: CGPoint(x: box.minX, y: box.maxY),
            topRight: CGPoint(x: box.maxX, y: box.maxY),
            bottomLeft: CGPoint(x: box.minX, y: box.minY),
            bottomRight: CGPoint(x: box.maxX, y: box.minY)
        )
    }

    /// The axis-aligned rectangle around the line
    public var box: CGRect {
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
        let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// Reads text from images with Vision, tuned for Japanese and English documents.
public enum TextRecognizer {
    /// Whether recognizeLines returns lines in reading order (the document reader, macOS 26 and
    /// later, which also reads vertical Japanese) or only top to bottom across the page
    public static var linesAreInReadingOrder: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Blocks the calling thread. Safe to call from several threads at once.
    public static func recognizeLines(in image: CGImage) throws -> [RecognizedLine] {
        if #available(macOS 26, *) {
            return try readDocument(image)
        }
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
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
    }

    @available(macOS 26, *)
    private static func readDocument(_ image: CGImage) throws -> [RecognizedLine] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                var request = RecognizeDocumentsRequest()
                request.textRecognitionOptions.recognitionLanguages = [
                    Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US"),
                ]
                request.textRecognitionOptions.useLanguageCorrection = true
                let observations = try await request.perform(on: image)
                box.result = .success(observations.flatMap { observation in
                    observation.document.text.lines.compactMap { line -> RecognizedLine? in
                        guard let text = line.topCandidates(1).first?.string,
                              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                        return RecognizedLine(
                            text: text,
                            topLeft: CGPoint(x: line.topLeft.x, y: line.topLeft.y),
                            topRight: CGPoint(x: line.topRight.x, y: line.topRight.y),
                            bottomLeft: CGPoint(x: line.bottomLeft.x, y: line.bottomLeft.y),
                            bottomRight: CGPoint(x: line.bottomRight.x, y: line.bottomRight.y)
                        )
                    }
                })
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result<[RecognizedLine], Error>?
    }
}
