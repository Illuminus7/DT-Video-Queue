import AVFoundation
import Foundation

final class MovieExporter {
    let output: URL
    let width: Int
    let height: Int
    let fps: Int32
    private let scratch: URL
    private let video: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private(set) var frameCount = 0
    private var complete = false

    init(output: URL, width: Int, height: Int, fps: Int32) throws {
        self.output = output; self.width = width; self.height = height; self.fps = fps
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DTVideoQueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        video = scratch.appendingPathComponent("video.mov")
        writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(5_000_000, width * height * 5)]
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw VideoError.failure("Movie encoder is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoError.failure("Could not start movie encoding.") }
        writer.startSession(atSourceTime: .zero)
    }

    deinit {
        if !complete { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: scratch)
    }

    func append(_ tensor: ImageTensor) throws {
        let shape = tensor.dimensions
        guard shape.count >= 3, shape.suffix(3).elementsEqual([height, width, 3]) else {
            throw VideoError.failure("Draw Things returned an unexpected frame size: \(shape).")
        }
        let frameElements = width * height * 3
        guard tensor.values.count % frameElements == 0 else { throw VideoError.failure("Incomplete movie frame.") }
        for offset in stride(from: 0, to: tensor.values.count, by: frameElements) {
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? VideoError.failure("Movie encoding stalled.") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { throw VideoError.failure("Movie pixel buffer is unavailable.") }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw VideoError.failure("Could not allocate a movie frame.") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let pixels = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            func byte(_ value: Float) -> UInt8 {
                guard value.isFinite else { return 0 }
                return UInt8(max(0, min(255, (value + 1) * 127.5)).rounded())
            }
            for y in 0..<height {
                for x in 0..<width {
                    let i = offset + (y * width + x) * 3, p = y * stride + x * 4
                    pixels[p] = byte(tensor.values[i + 2]); pixels[p + 1] = byte(tensor.values[i + 1])
                    pixels[p + 2] = byte(tensor.values[i]); pixels[p + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frameCount), timescale: fps)) else {
                throw writer.error ?? VideoError.failure("Could not encode movie frame.")
            }
            frameCount += 1
        }
    }

    func finish(audio: [ImageTensor], sampleRate: Int) throws {
        guard frameCount > 0 else { throw VideoError.failure("The server returned no video frames.") }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }; done.wait()
        guard writer.status == .completed else { throw writer.error ?? VideoError.failure("Could not finish movie encoding.") }
        if audio.isEmpty { try FileManager.default.moveItem(at: video, to: output) }
        else {
            let sound = scratch.appendingPathComponent("audio.wav")
            try writeAudio(audio, sampleRate: sampleRate, to: sound)
            let composition = AVMutableComposition()
            let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: sound)
            guard let sourceVideo = videoAsset.tracks(withMediaType: .video).first,
                  let sourceAudio = audioAsset.tracks(withMediaType: .audio).first,
                  let movieTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let soundTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoError.failure("Could not combine video and generated audio.")
            }
            let duration = CMTime(value: Int64(frameCount), timescale: fps)
            try movieTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
            try soundTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioAsset.duration)), of: sourceAudio, at: .zero)
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw VideoError.failure("Movie export is unavailable.") }
            export.outputURL = output; export.outputFileType = .mov
            let finished = DispatchSemaphore(value: 0)
            export.exportAsynchronously { finished.signal() }; finished.wait()
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                throw export.error ?? VideoError.failure("Could not export movie with audio.")
            }
        }
        complete = true
    }

    private func writeAudio(_ tensors: [ImageTensor], sampleRate: Int, to url: URL) throws {
        var samples = Data()
        for tensor in tensors {
            guard tensor.dimensions.count == 2, tensor.dimensions[0] == 2 else { throw VideoError.failure("Unsupported generated audio layout.") }
            let count = tensor.dimensions[1]
            for i in 0..<count {
                for channel in 0..<2 {
                    let value = tensor.values[channel * count + i]
                    let pcm = value.isFinite ? Int16(max(-32768, min(32767, value * 32767))) : 0
                    samples.appendLE(pcm)
                }
            }
        }
        guard samples.count <= Int(UInt32.max) - 36 else { throw VideoError.failure("Generated audio is too large.") }
        var wav = Data("RIFF".utf8); wav.appendLE(UInt32(36 + samples.count)); wav.append(Data("WAVEfmt ".utf8))
        wav.appendLE(UInt32(16)); wav.appendLE(UInt16(1)); wav.appendLE(UInt16(2))
        wav.appendLE(UInt32(sampleRate)); wav.appendLE(UInt32(sampleRate * 4)); wav.appendLE(UInt16(4)); wav.appendLE(UInt16(16))
        wav.append(Data("data".utf8)); wav.appendLE(UInt32(samples.count)); wav.append(samples)
        try wav.write(to: url)
    }
}
