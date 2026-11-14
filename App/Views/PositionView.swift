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

    private struct CornerJob: Identifiable {
        let id = UUID()
        let photo: CGImage
        let quad: DiagramReader.Quad
        var note: String? = nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let reading = model.diagram {
                        DiagramCheckBar(model: model, reading: reading, showingPicture: $showingPicture) {
                            if let photo = reading.photo { corners = CornerJob(photo: photo, quad: reading.quad) }
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
                    if let page = pages.first { Task { await readDiagram(page) } }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $corners) { job in
                CornerEditor(photo: job.photo, quad: job.quad, note: job.note) { quad in
                    Task { await readCorners(job.photo, quad) }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { photo in Task { await readDiagram(photo) } }
                    .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { loadPhoto() }
            .overlay {
                if isReadingDiagram {
                    ProgressView("Reading the diagram…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Couldn't Read the Diagram", isPresented: Binding(
                get: { diagramError != nil }, set: { if !$0 { diagramError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(diagramError ?? "")
            }
            #if DEBUG
            .task {
                // -demoDiagram: reads a rendered diagram onto the board for checking.
                // -demoDiagramFile PATH: reads that picture instead.
                let args = ProcessInfo.processInfo.arguments
                // A path not starting with / is in the app's Documents (as Imports/<stamp>/page1.jpg).
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
                if let i = args.firstIndex(of: "-demoDiagramFile"), i + 1 < args.count,
                   let image = UIImage(contentsOfFile: args[i + 1].hasPrefix("/") ? args[i + 1] : documents + "/" + args[i + 1]) {
                    await readDiagram(image)
                    showingPicture = args.contains("-demoPicture")
                    if args.contains("-demoCorners"), let r = model.diagram, let photo = r.photo {
                        corners = CornerJob(photo: photo, quad: r.quad)
                    }
                    return
                }
                guard args.contains("-demoDiagram") else { return }
                await readDiagram(DemoGame.diagram())
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
            await readDiagram(image)
        }
    }

    private func readDiagram(_ image: UIImage) async {
        isReadingDiagram = true
        defer { isReadingDiagram = false }
        ImportLog.save(text: "", images: [image], source: "diagram")
        do {
            let reading = try await DiagramReader.read(image)
            showingPicture = false
            model.loadDiagram(reading)
        } catch DiagramReader.ReadError.noBoard {
            // Not found: the corners can still be set by hand.
            guard let photo = DiagramReader.upright(image) else { return }
            corners = CornerJob(photo: photo, quad: DiagramReader.defaultCorners(in: photo),
                                note: "No board was found. Drag the corners onto the board's corners, so the grid lines fall between the squares.")
        } catch {
            diagramError = error.localizedDescription
        }
    }

    private func readCorners(_ photo: CGImage, _ quad: DiagramReader.Quad) async {
        isReadingDiagram = true
        defer { isReadingDiagram = false }
        do {
            let reading = try await DiagramReader.read(photo, corners: quad)
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
                Section("Read a Diagram") {
                    if CameraPicker.isAvailable {
                        Button("Take Photo…", systemImage: "camera") { showingCamera = true }
                    }
                    if DocumentScanner.isSupported {
                        // The scanner lets the corners be dragged onto the board; its automatic
                        // shutter (on by default, switched off in its own controls) can catch a
                        // skewed frame.
                        Button("Scan and Crop…", systemImage: "camera.viewfinder") { showingScanner = true }
                    }
                    Button("Choose Photo…", systemImage: "photo") { showingPhotoPicker = true }
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
