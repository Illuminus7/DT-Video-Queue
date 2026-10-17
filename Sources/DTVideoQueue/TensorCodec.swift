import AppKit
import Compression
import Foundation
import FPZip

struct ImageTensor {
    let dimensions: [Int]
    let values: [Float]

    static func image(at path: String, width: Int, height: Int) throws -> Data {
        guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VideoError.failure("Could not read image: \(path)")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            // Fill the selected aspect ratio, keeping the source image's proportions.
            let scale = max(Double(width) / Double(cg.width), Double(height) / Double(cg.height))
            let w = Double(cg.width) * scale, h = Double(cg.height) * scale
            context.draw(cg, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
            return true
        }
        guard rendered else { throw VideoError.failure("Could not prepare reference image.") }
        var data = Data()
        data.appendLE(UInt32(0)) // Uncompressed NNC tensor.
        for value: Int32 in [1, 2, 0x4000, 0, 1, Int32(height), Int32(width), 3, 0, 0, 0, 0, 0, 0, 0, 0] { data.appendLE(value) }
        for i in 0..<(width * height) {
            for c in 0..<3 { data.appendLE((Float(pixels[i * 4 + c]) / 127.5 - 1).bitPattern) }
        }
        return data
    }

    static func decode(_ data: Data) throws -> ImageTensor {
        guard data.count >= 68 else { throw VideoError.failure("Invalid tensor returned by Draw Things.") }
        let codec = try data.readLE(UInt32.self, at: 0)
        let format = try data.readLE(Int32.self, at: 8)
        let type = try data.readLE(Int32.self, at: 12)
        var dimensions: [Int] = []
        var count = 1
        for i in 0..<12 {
            let d = Int(try data.readLE(Int32.self, at: 20 + i * 4))
            if d == 0 { break }
            guard d > 0, d <= 1_000_000, count <= 100_000_000 / d else { throw VideoError.failure("Invalid tensor dimensions.") }
            dimensions.append(d); count *= d
        }
        guard !dimensions.isEmpty, format == 2 || dimensions.count <= 2 else { throw VideoError.failure("Unsupported tensor layout.") }
        let elementSize: Int
        switch type { case 0x20000: elementSize = 2; case 0x4000: elementSize = 4; default: throw VideoError.failure("Unsupported tensor precision.") }
        let payload = Data(data.dropFirst(68))
        var raw: Data
        switch codec {
        case 0:
            guard payload.count == count * elementSize else { throw VideoError.failure("Incorrect tensor length.") }
            raw = payload
        case 0x217:
            raw = Data(repeating: 0, count: count * elementSize)
            let length = raw.withUnsafeMutableBytes { output in
                payload.withUnsafeBytes { input in
                    compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard length == raw.count else { throw VideoError.failure("Could not decompress tensor.") }
        case 0xf7217:
            guard payload.count >= 24 else { throw VideoError.failure("Truncated compressed tensor.") }
            var values = [Float](repeating: 0, count: count)
            let okay = payload.withUnsafeBytes { input -> Bool in
                guard let handle = fpzip_read_from_buffer(input.baseAddress) else { return false }
                defer { fpzip_read_close(handle) }
                guard fpzip_read_header(handle) != 0, handle.pointee.type == FPZIP_TYPE_FLOAT else { return false }
                let shape = [handle.pointee.nx, handle.pointee.ny, handle.pointee.nz, handle.pointee.nf]
                var size = 1
                for d in shape { guard d > 0, size <= count / Int(d) else { return false }; size *= Int(d) }
                guard size == count else { return false }
                return values.withUnsafeMutableBytes { fpzip_read(handle, $0.baseAddress) > 0 }
            }
            guard okay else { throw VideoError.failure("Could not decode floating-point tensor.") }
            return ImageTensor(dimensions: dimensions, values: values)
        default: throw VideoError.failure("Unsupported Draw Things tensor codec: \(codec).")
        }
        let values = try (0..<count).map { i -> Float in
            if elementSize == 2 { return Float(Float16(bitPattern: try raw.readLE(UInt16.self, at: i * 2))) }
            return Float(bitPattern: try raw.readLE(UInt32.self, at: i * 4))
        }
        return ImageTensor(dimensions: dimensions, values: values)
    }
}
