import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The Games tab: read a game from PGN, text or a picture of a page, and see it annotated.
struct GamesView: View {
    @Bindable var model: GameAnalysisModel
    /// Opens a position in the Position tab.
    let onAnalyzePosition: (String) -> Void

    @State private var editorText: String?
    @State private var showingImporter = false
    @State private var showingScanner = false
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showingSettings = false
    @State private var review: ScanReview?
    @State private var isReading = false
    @State private var errorMessage: String?
    @State private var next: Next?

    private enum Next {
        /// Read text from the editor: as PGN if it is clean, otherwise into the review.
        case read(String)
        /// Open the editor on this text.
        case edit(String)
    }


    var body: some View {
        NavigationStack {
            Group {
                if let game = model.game {
                    GameView(model: model, game: game, onAnalyzePosition: onAnalyzePosition)
                        .id(game.id)   // a new game starts with fresh view state
                } else if !model.games.isEmpty {
                    gameList
                } else {
                    emptyState
                }
            }
            .overlay {
                if isReading {
                    ProgressView("Reading the page…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            // The players go in the page, where they fit; the bar is crowded with buttons.
            .navigationTitle(model.game == nil ? "Games" : "Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // A sheet cannot be presented while another is going away: what one sheet leads to
            // is kept in `next` and shown once it has been dismissed.
            .sheet(isPresented: Binding(get: { editorText != nil }, set: { if !$0 { editorText = nil } }),
                   onDismiss: showNext) {
                PGNEditor(initialText: editorText ?? "") { text in next = .read(text) }
            }
            .sheet(item: $review, onDismiss: showNext) { review in
                ScanReviewSheet(review: review,
                                onOpen: { moves in report(model.openMoves(moves, tags: review.result.tags, title: review.source,
                                                                        stoppedAt: review.result.stoppedAt)) },
                                onEdit: { text in next = .edit(text) })
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showingScanner) {
                DocumentScanner { pages in Task { await read(images: pages, source: "Scanned Page") } }
                    .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { loadPhoto() }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-demoScan") else { return }
                while model.engine.status == .starting { try? await Task.sleep(for: .milliseconds(100)) }
                await read(images: [DemoGame.page()], source: "Scanned Page")
            }
            #endif
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: PGNFile.types) { result in
                importFile(result)
            }
            .alert("Couldn't Open the Game", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Game", systemImage: "list.number")
        } description: {
            Text("Scan a printed game, or paste or open one in PGN. Every move is checked by the engine and marked as an inaccuracy, mistake or blunder, with the better line.")
        } actions: {
            if DocumentScanner.isSupported {
                Button("Scan with Camera", systemImage: "doc.viewfinder") { showingScanner = true }
                    .buttonStyle(.borderedProminent)
            }
            pasteButton
            Button("Choose Photo", systemImage: "photo") { showingPhotoPicker = true }
            Button("Open PGN File", systemImage: "folder") { showingImporter = true }
            Button("Type PGN", systemImage: "square.and.pencil") { editorText = "" }
        }
    }

    private var gameList: some View {
        List(model.games) { game in
            Button {
                report(model.open(game))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(game.title).font(.headline)
                        Spacer()
                        Text(game.result).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !game.subtitle.isEmpty {
                        Text(game.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("\((game.moves.count + 1) / 2) moves").font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if model.game != nil, model.games.count > 1 {
                Button("Games", systemImage: "chevron.left") { model.close() }
            } else {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.game != nil {
                Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.flipped.toggle() }
                if let pgn = model.annotatedPGN(annotator: annotator) {
                    ShareLink(item: pgn, subject: Text(model.game?.pgn.title ?? "Game"),
                              preview: SharePreview("Annotated game")) {
                        Label("Share Annotated PGN", systemImage: "square.and.arrow.up")
                    }
                }
            }
            pasteButton
                .labelStyle(.iconOnly)
            Menu("Import", systemImage: "plus") {
                if DocumentScanner.isSupported {
                    Button("Scan with Camera…", systemImage: "doc.viewfinder") { showingScanner = true }
                }
                Button("Choose Photo…", systemImage: "photo") { showingPhotoPicker = true }
                Button("Open PGN File…", systemImage: "folder") { showingImporter = true }
                Button("Type PGN…", systemImage: "square.and.pencil") { editorText = "" }
                if model.game != nil {
                    Divider()
                    Button("Settings…", systemImage: "gearshape") { showingSettings = true }
                    Button("Close Game", systemImage: "xmark") { model.close() }
                }
            }
        }
    }

    private var annotator: String {
        switch model.limit {
        case .depth(let d): "Creatica AB, depth \(d)"
        case .time(let s): "Creatica AB, \(s) s per position"
        case .infinite: "Creatica AB"
        }
    }

    /// The system Paste button, not a button that reads UIPasteboard: reading the pasteboard in
    /// code makes iOS ask "Allow Paste?" first. It takes text, or a copied picture of a page,
    /// which is read like a scan.
    private var pasteButton: some View {
        PasteButton(supportedContentTypes: ClipboardReader.types) { providers in
            Task { @MainActor in await paste(providers) }
        }
    }

    // MARK: - Reading

    private func paste(_ providers: [NSItemProvider]) async {
        let types = providers.map(\.registeredTypeIdentifiers)
        fputs("paste: \(types)\n", stderr)
        // Text first: when the clipboard has both, the text is what was meant (and is exact).
        if let text = await ClipboardReader.text(from: providers),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ImportLog.save(text: text, images: [], source: "paste \(types)")
            importText(text, source: "Read from Text")
        } else if let image = await ClipboardReader.image(from: providers) {
            await read(images: [image], source: "Read from Picture")
        } else {
            errorMessage = "The clipboard holds neither text nor a picture (it has \(types.flatMap { $0 }.joined(separator: ", ")))."
        }
    }

    private func loadPhoto() {
        guard let item = photoItem else { return }
        photoItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                errorMessage = "The photo could not be loaded."
                return
            }
            await read(images: [image], source: "Read from Photo")
        }
    }

    private func read(images: [UIImage], source: String) async {
        isReading = true
        defer { isReading = false }
        do {
            var pages: [String] = []
            for image in images { pages.append(try await TextRecognizer.text(in: image)) }
            let text = pages.joined(separator: "\n")
            ImportLog.save(text: text, images: images, source: source)
            review = ScanReview(source: source, text: text, result: GameTextReader.read(text))
        } catch {
            errorMessage = "The text could not be recognised: \(error.localizedDescription)"
        }
    }

    private func showNext() {
        guard let pending = next else { return }
        next = nil
        switch pending {
        case .read(let text): importText(text, source: "Read from Text")
        case .edit(let text): editorText = text
        }
    }

    /// Clean PGN opens at once; anything else (a single game that does not replay, or loose
    /// text) goes through the reader and its review.
    private func importText(_ text: String, source: String) {
        // Strict PGN only if every game in it replays to the end: text with misread tags parses as
        // several broken "games", and is better read by the reader.
        let games = PGNParser.parse(text)
        let clean = !games.isEmpty && games.allSatisfy { game in
            guard let loaded = LoadedGame(pgn: game) else { return false }
            return loaded.readError == nil && !loaded.plies.isEmpty
        }
        if clean {
            report(model.importPGN(text))
        } else {
            review = ScanReview(source: source, text: text, result: GameTextReader.read(text))
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            report(model.importPGN(try PGNFile.read(result.get())))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func report(_ error: String?) {
        errorMessage = error
    }
}

/// A plain text editor for pasting, typing or fixing a game.
private struct PGNEditor: View {
    let initialText: String
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .navigationTitle("PGN")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Open") {
                            dismiss()
                            onImport(text)
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { text = initialText }
        }
    }
}
