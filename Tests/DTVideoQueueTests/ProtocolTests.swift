import AVFoundation
import Compression
import FPZip
import XCTest
@testable import DTVideoQueue

final class ProtocolTests: XCTestCase {
    func testProjectCompatibilityAndServerPersistence() throws {
        let old = try JSONDecoder().decode(Project.self, from: Data("{\"steps\":6}".utf8))
        XCTAssertEqual(old.server.port, 7859)
        XCTAssertTrue(old.server.tls)
        XCTAssertEqual(old.frameCount, 124)
        XCTAssertTrue(old.solAttentionEnabled)
        XCTAssertEqual(old.solAttentionStart, 2)
        XCTAssertEqual(old.solAttentionTau, 0.5)
        XCTAssertTrue(old.teaCacheEnabled)
        XCTAssertEqual(old.teaCacheStart, 5)
        XCTAssertEqual(old.teaCacheEnd, 6)
        XCTAssertEqual(old.teaCacheThreshold, 0.06)
        XCTAssertEqual(old.teaCacheMaxSkipSteps, 3)
        var project = old; project.server.port = 7860; project.frameCount = 22
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored.server.port, 7860)
        XCTAssertEqual(restored.frameCount, 22)
        XCTAssertThrowsError(try JSONDecoder().decode(Project.self, from: Data("{\"frameCount\":24}".utf8)))
    }

    func testH3FrameCountsAndDuration() {
        XCTAssertEqual(VideoTiming.frameCounts, [1, 5, 22, 39, 56, 73, 90, 107, 124, 141, 158, 175, 192, 209, 226, 243, 260, 277, 294, 311, 328, 345, 362])
        XCTAssertEqual(VideoTiming.seconds(frames: 124, family: .h3), 124.0 / 24)
        XCTAssertEqual(VideoTiming.seconds(frames: 362, family: .h3), 362.0 / 24)
    }

    func testProtobufUnknownFieldsAndTruncation() throws {
        var p = Proto(); p.string(5, "hello"); p.integer(14, 1); p.bytes(127, Data([1, 2, 3]))
        let fields = try Proto.fields(p.data)
        XCTAssertEqual(fields.map(\.number), [5, 14, 127])
        XCTAssertEqual(String(data: fields[0].bytes, encoding: .utf8), "hello")
        XCTAssertThrowsError(try Proto.fields(Data(p.data.dropLast())))
    }

    func testConfigurationWireFields() throws {
        var project = Project(); project.modelFile = "minimax_h3_fl2va_i8x.ckpt"
        project.frameCount = 22
        project.solAttentionEnabled = false; project.solAttentionStart = 3; project.solAttentionTau = 0.75
        project.teaCacheEnabled = false; project.teaCacheStart = 1; project.teaCacheEnd = 4
        project.teaCacheThreshold = 0.12; project.teaCacheMaxSkipSteps = 7
        project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        project.size = .extraSmall; project.lora1File = "test.ckpt"; project.lora1Strength = 0.75
        let data = ConfigBuffer.configuration(project, family: .h3)
        let root = Int(try data.readLE(UInt32.self, at: 0))
        let vt = root - Int(try data.readLE(Int32.self, at: root))
        func field(_ index: Int) throws -> Int { root + Int(try data.readLE(UInt16.self, at: vt + 4 + index * 2)) }
        XCTAssertEqual(try data.readLE(UInt16.self, at: field(1)), 4)
        XCTAssertEqual(try data.readLE(UInt16.self, at: field(2)), 6)
        XCTAssertEqual(try data.readLE(UInt32.self, at: field(46)), 22)
        XCTAssertEqual(Float(bitPattern: try data.readLE(UInt32.self, at: field(49))), 12)
        XCTAssertEqual(try data.readLE(UInt32.self, at: field(72)), 1)
        XCTAssertEqual(try data.readLE(UInt32.self, at: field(73)), 4)
        XCTAssertEqual(Float(bitPattern: try data.readLE(UInt32.self, at: field(74))), 0.12)
        XCTAssertEqual(try data.readLE(UInt8.self, at: field(75)), 0)
        XCTAssertEqual(try data.readLE(UInt32.self, at: field(78)), 7)
        XCTAssertEqual(try data.readLE(UInt8.self, at: field(89)), 0)
        XCTAssertEqual(try data.readLE(UInt32.self, at: field(90)), 3)
        XCTAssertEqual(Float(bitPattern: try data.readLE(UInt32.self, at: field(91))), 0.75)
        let loraSlot = try field(20), vector = loraSlot + Int(try data.readLE(UInt32.self, at: loraSlot))
        XCTAssertEqual(try data.readLE(UInt32.self, at: vector), 1)
        let slot = vector + 4, table = slot + Int(try data.readLE(UInt32.self, at: slot))
        let loraVT = table - Int(try data.readLE(Int32.self, at: table))
        let weight = table + Int(try data.readLE(UInt16.self, at: loraVT + 6))
        XCTAssertEqual(Float(bitPattern: try data.readLE(UInt32.self, at: weight)), 0.75)
    }

    private func header(codec: UInt32, dimensions: [Int], type: Int32 = 0x4000) -> Data {
        var data = Data(); data.appendLE(codec)
        for value: Int32 in [1, 2, type, 0] { data.appendLE(value) }
        for i in 0..<12 { data.appendLE(Int32(i < dimensions.count ? dimensions[i] : 0)) }
        return data
    }

    func testTensorRawZipAndFPZip() throws {
        let values = (0..<192).map { Float($0 % 9) / 9 }
        let raw = values.withUnsafeBytes { Data($0) }
        let dimensions = [1, 8, 8, 3]
        var plain = header(codec: 0, dimensions: dimensions); plain.append(raw)
        XCTAssertEqual(try ImageTensor.decode(plain).values, values)
        var zipped = Data(repeating: 0, count: 2048)
        let length = zipped.withUnsafeMutableBytes { output in raw.withUnsafeBytes { input in
            compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        } }
        XCTAssertGreaterThan(length, 0)
        var zip = header(codec: 0x217, dimensions: dimensions); zip.append(zipped.prefix(length))
        XCTAssertEqual(try ImageTensor.decode(zip).values, values)
        var compressed = Data(repeating: 0, count: 4096)
        let size = compressed.withUnsafeMutableBytes { output -> Int in
            let fpz = fpzip_write_to_buffer(output.baseAddress, output.count)!
            defer { fpzip_write_close(fpz) }
            fpz.pointee.type = FPZIP_TYPE_FLOAT; fpz.pointee.prec = 32
            fpz.pointee.nx = 3; fpz.pointee.ny = 8; fpz.pointee.nz = 8; fpz.pointee.nf = 1
            fpzip_write_header(fpz)
            return values.withUnsafeBytes { Int(fpzip_write(fpz, $0.baseAddress)) }
        }
        XCTAssertGreaterThan(size, 0)
        var fpzip = header(codec: 0xf7217, dimensions: dimensions); fpzip.append(compressed.prefix(size))
        XCTAssertEqual(try ImageTensor.decode(fpzip).values, values)
        XCTAssertThrowsError(try ImageTensor.decode(Data(plain.dropLast())))
    }

    func testNativeMovieWithAudio() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dt-export-test-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let exporter = try MovieExporter(output: output, width: 64, height: 64, fps: 24)
        let frame = ImageTensor(dimensions: [1, 64, 64, 3], values: [Float](repeating: 0, count: 64 * 64 * 3))
        try exporter.append(frame); try exporter.append(frame)
        let audio = ImageTensor(dimensions: [2, 3200], values: [Float](repeating: 0, count: 6400))
        try exporter.finish(audio: [audio], sampleRate: 32000)
        let asset = AVURLAsset(url: output)
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 2.0 / 24, accuracy: 0.01)
    }

    func testLiveServerEchoOnly() throws {
        guard ProcessInfo.processInfo.environment["DT_QUEUE_CHECK_SERVER"] == "1" else { throw XCTSkip("Live server check is opt-in.") }
        let client = try GRPCVideoClient(settings: ServerSettings(), log: { _ in })
        try client.checkConnection()
    }
}
