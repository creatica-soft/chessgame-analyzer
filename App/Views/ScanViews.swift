import SwiftUI
import UIKit
import VisionKit

/// Text read from an image or pasted, and the game the reader made of it.
struct ScanReview: Identifiable {
    let id = UUID()
    let source: String
    let text: String
    let result: GameTextReader.Result

    /// The recognised text, to correct and read again. Only the text: the moves read from it
    /// are what it says, so fixing a misread word here changes the moves.
    var editableText: String { text }
}

/// What was read, with every guess and the place reading stopped, before it is analysed.
struct ScanReviewSheet: View {
    let review: ScanReview
    let onOpen: ([String]) -> Void
    let onEdit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                summary
                if !review.result.corrections.isEmpty {
                    Section {
                        ForEach(review.result.corrections, id: \.ply) { c in
                            HStack {
                                Text(label(ply: c.ply, san: c.san)).font(.body.weight(.semibold))
                                Spacer()
                                Text("read as “\(c.read)”").foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Guesses")
                    } footer: {
                        Text("These words were not legal moves as read; each is the only legal move close to what was printed. Check them against the page.")
                    }
                }
                if !review.result.moves.isEmpty {
                    Section("Moves") {
                        Text(movesText).font(.callout).textSelection(.enabled)
                    }
                }
                Section {
                    DisclosureGroup("Recognised text") {
                        Text(review.text.isEmpty ? "No text was found." : review.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(review.source)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        dismiss()
                        onOpen(review.result.moves)
                    }
                    .disabled(review.result.moves.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Correct the Text", systemImage: "square.and.pencil") {
                        dismiss()
                        onEdit(review.editableText)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        let r = review.result
        Section {
            if r.moves.isEmpty {
                Label("No moves could be read.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label("Read \((r.moves.count + 1) / 2) moves", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                if !r.corrections.isEmpty {
                    Label("\(r.corrections.count) guessed: check them below.", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            if let stopped = r.stoppedAt {
                Label("Stopped: \(stopped)", systemImage: "stop.circle").foregroundStyle(.orange)
            }
        }
    }

    /// The moves, numbered, with the guessed ones marked.
    private var movesText: AttributedString {
        var out = AttributedString()
        let guessed = Set(review.result.corrections.map(\.ply))
        for (i, san) in review.result.moves.enumerated() {
            if i % 2 == 0 { out += AttributedString("\(i / 2 + 1). ") }
            var move = AttributedString(san)
            if guessed.contains(i) {
                move.foregroundColor = .orange
                move.inlinePresentationIntent = .stronglyEmphasized
            }
            out += move + AttributedString(" ")
        }
        return out
    }

    private func label(ply: Int, san: String) -> String {
        "\(ply / 2 + 1)\(ply % 2 == 0 ? "." : "…") \(san)"
    }
}

/// The system document camera: finds the page, straightens it, and returns one image per page.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// UIKit calls the delegate on the main thread.
    @MainActor
    final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.dismiss()
            parent.onScan(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}
