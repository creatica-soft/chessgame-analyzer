// Prints a video's length and size, and saves frames from it as JPEG.
// usage: frames <video> <out-dir> <every-seconds> [max-side]
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4, let every = Double(args[3]) else {
    print("usage: frames <video> <out-dir> <every-seconds> [max-side]"); exit(1)
}
let maxSide = args.count > 4 ? Double(args[4]) ?? 1600 : 1600
let url = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let asset = AVURLAsset(url: url)
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let shown = size.applying(transform)
        print(String(format: "%@ %.2fs %dx%d (shown %dx%d) %.0f fps", url.lastPathComponent, duration,
                     Int(size.width), Int(size.height), Int(abs(shown.width)), Int(abs(shown.height)), fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        var t = 0.0
        var n = 0
        while t < duration {
            let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let file = out.appendingPathComponent(String(format: "%@-%03d.jpg", url.deletingPathExtension().lastPathComponent, n))
            let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            CGImageDestinationFinalize(dest)
            t += every
            n += 1
        }
    } catch {
        print("error: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()
