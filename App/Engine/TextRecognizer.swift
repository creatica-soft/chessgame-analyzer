import CoreGraphics
import ImageIO
import UIKit
import Vision

/// Text recognition on the phone (Vision), tuned for chess notation.
enum TextRecognizer {
    /// The text in `image`, a line per recognised line, in reading order.
    static func text(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) {
            try recognize(cgImage, orientation: orientation)
        }.value
    }

    private struct Line {
        var text: String
        /// Normalised, origin at the bottom left, as Vision reports it.
        var box: CGRect
    }

    private static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction "fixes" notation into words: Nf3 into Nfs, Bxe5 into Boxes.
        request.usesLanguageCorrection = false
        // English letters only: left to detect the language, it returns Cyrillic б for a 6.
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return Line(text: text, box: observation.boundingBox)
        }
        return readingOrder(lines).map(\.text).joined(separator: "\n")
    }

    /// Top to bottom, left to right, and a two-column page one column at a time: books print
    /// games in columns, and reading straight across would interleave them.
    private static func readingOrder(_ lines: [Line]) -> [Line] {
        func topDown(_ group: [Line]) -> [Line] {
            group.sorted { a, b in
                // The same printed line: Vision may split it in two.
                if abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) / 2 { return a.box.minX < b.box.minX }
                return a.box.midY > b.box.midY
            }
        }
        // A vertical gutter: an x in the middle of the page that no line crosses, with text on
        // both sides of it.
        let gutter = stride(from: 0.3, through: 0.7, by: 0.01).first { x in
            !lines.contains { $0.box.minX < x && $0.box.maxX > x }
                && lines.filter { $0.box.maxX <= x }.count >= 3
                && lines.filter { $0.box.minX >= x }.count >= 3
        }
        guard let gutter else { return topDown(lines) }
        return topDown(lines.filter { $0.box.maxX <= gutter }) + topDown(lines.filter { $0.box.minX >= gutter })
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
