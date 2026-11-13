import Foundation
import UIKit
import UniformTypeIdentifiers

/// Reads what the system Paste button hands over. Apps put text on the clipboard in different
/// forms: plain UTF-8 or UTF-16, RTF, HTML, or only an attributed string (Live Text, Notes).
/// So it goes by the types actually registered, not by `canLoadObject(ofClass: String.self)`,
/// which misses some of them.
@MainActor
enum ClipboardReader {
    static let types: [UTType] = [.text, .image]

    static func text(from providers: [NSItemProvider]) async -> String? {
        for provider in providers {
            for id in provider.registeredTypeIdentifiers {
                let type = UTType(id)
                guard type?.conforms(to: .text) == true || id == Self.attributedString,
                      let data = await data(id, from: provider),
                      let text = decode(data, typeIdentifier: id) else { continue }
                return text
            }
        }
        // Last resort: the bridged loader.
        for provider in providers where provider.canLoadObject(ofClass: String.self) {
            if let text = await withCheckedContinuation({ (c: CheckedContinuation<String?, Never>) in
                _ = provider.loadObject(ofClass: String.self) { text, _ in c.resume(returning: text) }
            }) { return text }
        }
        return nil
    }

    static func image(from providers: [NSItemProvider]) async -> UIImage? {
        for provider in providers {
            for id in provider.registeredTypeIdentifiers where UTType(id)?.conforms(to: .image) == true {
                if let data = await data(id, from: provider), let image = UIImage(data: data) { return image }
            }
        }
        return nil
    }

    private static func data(_ id: String, from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { c in
            _ = provider.loadDataRepresentation(forTypeIdentifier: id) { data, _ in c.resume(returning: data) }
        }
    }

    /// UIKit's own type for an attributed string copied in an app: a keyed archive.
    static let attributedString = "com.apple.uikit.attributedstring"

    static func decode(_ data: Data, typeIdentifier id: String) -> String? {
        if id == attributedString {
            return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data))?.string
        }
        guard let type = UTType(id) else { return nil }
        if type.conforms(to: .rtf) || type.conforms(to: .flatRTFD) || type.conforms(to: .html) {
            let documentType: NSAttributedString.DocumentType? =
                type.conforms(to: .html) ? .html : type.conforms(to: .flatRTFD) ? .rtfd : type.conforms(to: .rtf) ? .rtf : nil
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let documentType { options[.documentType] = documentType }
            if type.conforms(to: .html) { options[.characterEncoding] = String.Encoding.utf8.rawValue }
            if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                return attributed.string
            }
            return nil
        }
        if type.conforms(to: .utf16PlainText) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }
}

/// The last few imports, kept in the app's Documents folder (Files app: On My iPhone ›
/// Chess Analyzer › Imports), so a page that read badly can be looked at afterwards.
enum ImportLog {
    static var folder: URL {
        URL.documentsDirectory.appending(path: "Imports", directoryHint: .isDirectory)
    }

    static func save(text: String, images: [UIImage], source: String) {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateSeparator(.dash))
        let dir = folder.appending(path: stamp, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "\(source)\n\n\(text)".write(to: dir.appending(path: "text.txt"), atomically: true, encoding: .utf8)
            for (i, image) in images.enumerated() {
                try image.jpegData(compressionQuality: 0.85)?.write(to: dir.appending(path: "page\(i + 1).jpg"))
            }
            prune()
        } catch {
            fputs("import log: \(error)\n", stderr)
        }
    }

    /// Keeps the ten most recent.
    private static func prune() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for old in dirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(10) {
            try? fm.removeItem(at: old)
        }
    }
}
