import AVFoundation
import CoreImage
import SwiftUI

/// Reads a real board from the camera as it is pointed at it: the grid found is drawn over the
/// picture, frames are read one after another and their readings combined (`LiveBoardReader`),
/// and when the board has read the same for a while, with no square unsure, the reading goes to
/// the board for checking, as a photo's does. "Use This" takes the reading as it stands.
struct LiveBoardView: View {
    /// A movie read in place of the camera (debug: -demoLiveFile).
    var movie: URL? = nil
    let onDone: (DiagramReader.Reading, UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model = LiveBoardModel()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let feed = model.camera {
                    CameraPreview(feed: feed)
                } else if let picture = model.picture {
                    Image(decorative: picture, scale: 1).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                overlay(in: geo.size)
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { bottomPanel }
        }
        .task {
            await model.start(movie: movie)
        }
        .onDisappear { model.stop() }
        .onChange(of: model.result != nil) {
            if let (reading, image) = model.result {
                onDone(reading, image)
                dismiss()
            }
        }
    }

    /// The grid as last found, and the squares still unsure.
    private func overlay(in size: CGSize) -> some View {
        Canvas { context, _ in
            guard let grid = model.grid else { return }
            let map = DisplayMap(image: grid.imageSize, quarterTurns: grid.quarterTurns, view: size)
            let board = Projective(board: grid.corners)
            func point(_ f: Double, _ r: Double) -> CGPoint { map(board.map(f, r)) }
            var lines = Path()
            for i in 0...8 {
                let t = Double(i)
                lines.move(to: point(t, 0)); lines.addLine(to: point(t, 8))
                lines.move(to: point(0, t)); lines.addLine(to: point(8, t))
            }
            let colour: Color = grid.agrees ? .green : .yellow
            context.stroke(lines, with: .color(colour.opacity(0.8)), lineWidth: 1.5)
            for sq in grid.doubtful {
                let c = point(Double(sq % 8) + 0.5, Double(sq / 8) + 0.5)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.orange))
            }
        }
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { model.stop(); dismiss() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .tint(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            Text(model.status)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let hint = model.hint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Use This") { model.finish() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canFinish)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// Maps a point of a frame to the view showing it: the frame turned `quarterTurns` quarter turns
/// clockwise to stand as shown, then scaled to fill the view, centred.
struct DisplayMap {
    let image: CGSize
    let quarterTurns: Int
    let view: CGSize

    func callAsFunction(_ p: CGPoint) -> CGPoint {
        var q = p, size = image
        for _ in 0..<((quarterTurns % 4 + 4) % 4) {
            q = CGPoint(x: size.height - q.y, y: q.x)
            size = CGSize(width: size.height, height: size.width)
        }
        let scale = max(view.width / size.width, view.height / size.height)
        return CGPoint(x: (view.width - size.width * scale) / 2 + q.x * scale,
                       y: (view.height - size.height * scale) / 2 + q.y * scale)
    }
}

@MainActor @Observable
final class LiveBoardModel {
    struct Grid {
        var corners: [CGPoint]          // a1, h1, h8, a8 in the frame
        var imageSize: CGSize
        var quarterTurns: Int           // frame to screen
        var agrees: Bool                // the frame fitted the average
        var doubtful: [Int]
    }

    private(set) var camera: CameraFeed?
    private(set) var picture: CGImage?          // the movie's frame, when reading a movie
    private(set) var grid: Grid?
    private(set) var status = "Starting the camera…"
    private(set) var hint: String?
    private(set) var result: (DiagramReader.Reading, UIImage)?
    private var reader = LiveBoardReader()
    private var movieFeed: MovieFeed?
    private var lastFound = Date.distantPast
    private var finishing = false

    var canFinish: Bool { !reader.frames.isEmpty && !finishing }

    func start(movie: URL?) async {
        if let movie {
            let feed = MovieFeed(url: movie)
            movieFeed = feed
            feed.start { [weak self] image in self?.process(image, quarterTurns: 0) }
            status = "Looking for the board…"
            return
        }
        guard await CameraFeed.requestAccess() else {
            status = "No access to the camera"
            hint = "Allow Chess Analyzer to use the camera in Settings, under Privacy & Security."
            return
        }
        guard let feed = CameraFeed(position: .back) else {
            status = "The camera could not be started"
            return
        }
        camera = feed
        feed.start { [weak self] image, quarterTurns in self?.process(image, quarterTurns: quarterTurns) }
        status = "Looking for the board…"
        hint = "Hold the phone above the board from White's side, the whole board in view."
    }

    func stop() {
        camera?.stop()
        movieFeed?.stop()
    }

    /// Called on the feed's queue, one frame at a time: frames arriving meanwhile are dropped.
    nonisolated private func process(_ image: CGImage, quarterTurns: Int) {
        let frame = try? BoardReader.read(frame: image)
        Task { @MainActor in self.update(frame, image: image, quarterTurns: quarterTurns) }
    }

    private func update(_ frame: BoardReader.Frame?, image: CGImage, quarterTurns: Int) {
        guard !finishing else { return }
        if movieFeed != nil { picture = image }
        guard let frame else {
            if Date().timeIntervalSince(lastFound) > 1 {
                grid = nil
                status = "Looking for the board…"
                hint = reader.frames.isEmpty
                    ? "Hold the phone above the board from White's side, the whole board in view."
                    : "The board is out of view."
            }
            return
        }
        lastFound = Date()
        let outcome = reader.add(frame)
        // The frame as it stands in the average (turned to fit it), for the grid and its marks.
        let shown = outcome == .rejected ? frame : (reader.frames.last ?? frame)
        let doubtful = reader.doubtful
        // The frame read may have been turned to stand upright (`turns`); the screen shows the
        // camera's frame turned `quarterTurns`.
        grid = Grid(corners: shown.corners, imageSize: CGSize(width: shown.photo.width, height: shown.photo.height),
                    quarterTurns: quarterTurns - shown.turns,
                    agrees: outcome != .rejected, doubtful: outcome == .rejected ? [] : doubtful)
        if reader.isSettled {
            status = "Read"
            hint = nil
            finish()
        } else if doubtful.isEmpty {
            status = "Reading… hold steady"
            hint = nil
        } else {
            status = doubtful.count == 1 ? "Reading… 1 square unsure" : "Reading… \(doubtful.count) squares unsure"
            hint = "Move the phone a little, or higher, to see the marked squares better."
        }
    }

    /// The reading as it stands, to the board.
    func finish() {
        guard canFinish else { return }
        finishing = true
        stop()
        let reader = self.reader
        Task {
            let reading = try? await Task.detached(priority: .userInitiated) { try reader.reading() }.value
            if let reading, let photo = reading.photo {
                result = (reading, UIImage(cgImage: photo))
            } else {
                finishing = false
                status = "The board could not be read"
            }
        }
    }
}

// MARK: - Camera

/// The back camera's frames, upright as the phone is held, delivered one at a time on a queue of
/// their own; frames arriving while one is being read are dropped.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let preview: AVCaptureVideoPreviewLayer
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera frames", qos: .userInitiated)
    private let context = CIContext()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    private var onFrame: (@Sendable (CGImage, Int) -> Void)?
    /// The frames' rotation, as the coordinator last gave it (degrees clockwise).
    private var captureAngle: CGFloat = 90

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    init?(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        preview.videoGravity = .resizeAspectFill
        // The picture shown stays upright on the (portrait) screen; the frames read are turned to
        // stand upright as the phone is held, so that pieces rise up them.
        preview.connection?.videoRotationAngle = 90
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotation = coordinator
        setCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] c, _ in
            self?.setCaptureAngle(c.videoRotationAngleForHorizonLevelCapture)
        }
    }

    private func setCaptureAngle(_ angle: CGFloat) {
        queue.async {
            self.captureAngle = angle
            if let c = self.output.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
        }
    }

    func start(_ onFrame: @escaping @Sendable (CGImage, Int) -> Void) {
        queue.async {
            self.onFrame = onFrame
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            self.onFrame = nil
            self.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onFrame, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let frame = context.createCGImage(image, from: image.extent) else { return }
        // The screen shows the camera turned 90 degrees; the frame is turned captureAngle.
        let quarterTurns = Int(((90 - captureAngle) / 90).rounded())
        onFrame(frame, quarterTurns)
    }
}

/// The camera's picture, filling its view.
struct CameraPreview: UIViewRepresentable {
    let feed: CameraFeed

    final class PreviewView: UIView {
        var layerToShow: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let layerToShow { layer.addSublayer(layerToShow) }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            layerToShow?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerToShow = feed.preview
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

// MARK: - Movie (debug)

/// A movie's frames at the pace it plays, one at a time as they are read (for trying the live
/// reading in the simulator, which has no camera).
final class MovieFeed: @unchecked Sendable {
    private let url: URL
    private var running = true
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func start(_ onFrame: @escaping @Sendable (CGImage) -> Void) {
        let url = self.url
        Thread.detachNewThread { [self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            let duration = asset.duration.seconds
            let begin = Date()
            while isRunning {
                let t = Date().timeIntervalSince(begin)
                guard t < duration,
                      let image = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                else { break }
                onFrame(image)
            }
        }
    }

    private var isRunning: Bool { lock.withLock { running } }

    func stop() { lock.withLock { running = false } }
}
