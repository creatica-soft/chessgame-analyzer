import PhotosUI
import SwiftUI

/// The Position tab: set up a position and let the engine analyse it.
struct PositionView: View {
    @Bindable var model: AnalysisModel
    @State private var showingPosition = false
    @State private var showingSettings = false
    @State private var showingScanner = false
    @State private var showingCamera = false
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isReadingDiagram = false
    @State private var diagramError: String?
    /// The diagram's picture shown in place of the board, to compare.
    @State private var showingPicture = false
    /// The board's corners being set by hand.
    @State private var corners: CornerJob?
    /// What the camera or the photo picker is reading: a diagram or a real board.
    @State private var photoKind = DiagramReader.Reading.Kind.diagram
    @State private var showingLive = false
    /// A movie read in place of the camera by the live reading (debug).
    @State private var liveMovie: URL?

    private struct CornerJob: Identifiable {
        let id = UUID()
        let photo: CGImage
        let quad: DiagramReader.Quad
        let kind: DiagramReader.Reading.Kind
        var note: String? = nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let reading = model.diagram {
                        DiagramCheckBar(model: model, reading: reading, showingPicture: $showingPicture) {
                            if let photo = reading.photo { corners = CornerJob(photo: photo, quad: reading.quad, kind: reading.kind) }
                        }
                    }
                    EvalBar(whiteShare: model.whiteScore?.whiteShare)
                    if showingPicture, let reading = model.diagram {
                        DiagramPicture(reading: reading, boardFlipped: model.flipped)
                            .contentShape(Rectangle())
                            .onTapGesture { showingPicture = false }
                    } else {
                        BoardView(
                            position: model.position,
                            flipped: model.flipped,
                            selected: model.selectedSquare,
                            bestMove: model.bestMove.flatMap(BoardView.squares(ofUCI:)),
                            marked: model.doubtful,
                            onTap: model.tap
                        )
                    }
                    sideToMovePicker
                    PiecePalette(selected: model.tool, onSelect: model.selectTool)
                    AnalysisPanel(model: model)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .onChange(of: model.diagram == nil) { if model.diagram == nil { showingPicture = false } }
            .navigationTitle("Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showingPosition) { PositionSheet(model: model) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showingScanner) {
                DocumentScanner { pages in
                    if let page = pages.first { Task { await read(page, .diagram) } }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $corners) { job in
                CornerEditor(photo: job.photo, quad: job.quad, note: job.note) { quad in
                    Task { await readCorners(job.photo, quad, job.kind) }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { photo in Task { await read(photo, photoKind) } }
                    .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showingLive) {
                LiveBoardView(movie: liveMovie) { reading, image in
                    ImportLog.save(text: "", images: [image], source: "board-live")
                    showingPicture = false
                    model.loadDiagram(reading)
                }
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { loadPhoto() }
            .overlay {
                if isReadingDiagram {
                    ProgressView(photoKind == .board ? "Reading the board…" : "Reading the diagram…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(photoKind == .board ? "Couldn't Read the Board" : "Couldn't Read the Diagram", isPresented: Binding(
                get: { diagramError != nil }, set: { if !$0 { diagramError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(diagramError ?? "")
            }
            #if DEBUG
            .task {
                // -demoDiagram: reads a rendered diagram onto the board for checking.
                // -demoDiagramFile PATH / -demoBoardFile PATH: reads that picture instead, as a
                // diagram or as a photo of a real board.
                let args = ProcessInfo.processInfo.arguments
                // A path not starting with / is in the app's Documents (as Imports/<stamp>/page1.jpg).
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
                // -demoLiveFile PATH: the live reading, from that movie in place of the camera.
                if let i = args.firstIndex(of: "-demoLiveFile"), i + 1 < args.count {
                    let path = args[i + 1].hasPrefix("/") ? args[i + 1] : documents + "/" + args[i + 1]
                    liveMovie = URL(fileURLWithPath: path)
                    showingLive = true
                    return
                }
                for (flag, kind) in [("-demoDiagramFile", DiagramReader.Reading.Kind.diagram), ("-demoBoardFile", .board)] {
                    guard let i = args.firstIndex(of: flag), i + 1 < args.count,
                          let image = UIImage(contentsOfFile: args[i + 1].hasPrefix("/") ? args[i + 1] : documents + "/" + args[i + 1])
                    else { continue }
                    photoKind = kind
                    await read(image, kind)
                    showingPicture = args.contains("-demoPicture")
                    if args.contains("-demoCorners"), let r = model.diagram, let photo = r.photo {
                        corners = CornerJob(photo: photo, quad: r.quad, kind: r.kind)
                    }
                    return
                }
                guard args.contains("-demoDiagram") else { return }
                await read(DemoGame.diagram(), .diagram)
            }
            #endif
        }
    }

    private func loadPhoto() {
        guard let item = photoItem else { return }
        photoItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                diagramError = "The photo could not be loaded."
                return
            }
            await read(image, photoKind)
        }
    }

    /// Reads a diagram, or a photo of a real board, onto the board for checking.
    private func read(_ image: UIImage, _ kind: DiagramReader.Reading.Kind) async {
        isReadingDiagram = true
        defer { isReadingDiagram = false }
        ImportLog.save(text: "", images: [image], source: kind == .board ? "board" : "diagram")
        do {
            let reading = kind == .board ? try await BoardReader.read(image) : try await DiagramReader.read(image)
            showingPicture = false
            model.loadDiagram(reading)
        } catch DiagramReader.ReadError.noBoard {
            // Not found: the corners can still be set by hand.
            guard let photo = DiagramReader.upright(image) else { return }
            corners = CornerJob(photo: photo, quad: DiagramReader.defaultCorners(in: photo), kind: kind,
                                note: kind == .board
                                    ? "No board was found. Drag the corners onto the corners of the playing area (a8, h8, h1, a1 from White's side), so the grid lines fall between the squares."
                                    : "No board was found. Drag the corners onto the board's corners, so the grid lines fall between the squares.")
        } catch {
            diagramError = error.localizedDescription
        }
    }

    private func readCorners(_ photo: CGImage, _ quad: DiagramReader.Quad, _ kind: DiagramReader.Reading.Kind) async {
        isReadingDiagram = true
        defer { isReadingDiagram = false }
        do {
            let reading = kind == .board ? try await BoardReader.read(photo, corners: quad)
                                         : try await DiagramReader.read(photo, corners: quad)
            showingPicture = false
            model.loadDiagram(reading)
        } catch {
            diagramError = error.localizedDescription
        }
    }

    private var sideToMovePicker: some View {
        Picker("Side to move", selection: Binding(
            get: { model.position.sideToMove },
            set: { model.setSideToMove($0) }
        )) {
            Text("White to move").tag(PieceColor.white)
            Text("Black to move").tag(PieceColor.black)
        }
        .pickerStyle(.segmented)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.canUndo)
            Button("Flip Board", systemImage: "arrow.up.arrow.down") { model.flipped.toggle() }
            engineButton
            Menu("Position", systemImage: "ellipsis.circle") {
                Section("Read a Real Board") {
                    if CameraPicker.isAvailable {
                        Button("Live Camera…", systemImage: "camera.viewfinder") { liveMovie = nil; showingLive = true }
                        Button("Take Photo…", systemImage: "camera") { photoKind = .board; showingCamera = true }
                    }
                    Button("Choose Photo…", systemImage: "photo") { photoKind = .board; showingPhotoPicker = true }
                }
                Section("Read a Diagram") {
                    if CameraPicker.isAvailable {
                        Button("Take Photo…", systemImage: "camera") { photoKind = .diagram; showingCamera = true }
                    }
                    if DocumentScanner.isSupported {
                        // The scanner lets the corners be dragged onto the board; its automatic
                        // shutter (on by default, switched off in its own controls) can catch a
                        // skewed frame.
                        Button("Scan and Crop…", systemImage: "camera.viewfinder") { photoKind = .diagram; showingScanner = true }
                    }
                    Button("Choose Photo…", systemImage: "photo") { photoKind = .diagram; showingPhotoPicker = true }
                }
                Button("Starting Position", systemImage: "arrow.counterclockwise") { model.load(.start) }
                Button("Clear Board", systemImage: "trash") { model.load(.empty) }
                Button("Castling and FEN…", systemImage: "doc.text") { showingPosition = true }
            }
        }
    }

    private var engineButton: some View {
        Button(model.isAnalyzing ? "Stop Analysis" : "Analyze",
               systemImage: model.isAnalyzing ? "stop.fill" : "play.fill") {
            model.toggleAnalysis()
        }
        .disabled(model.engine.status == .starting || model.invalidReason != nil || model.terminal != nil)
    }
}
