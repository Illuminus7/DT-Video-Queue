import Foundation
import GRPC
import NIO

// Draw Things imageService.proto uses protobuf messages containing a FlatBuffer config.
struct RPCMessage: GRPCPayload {
    var data: Data
    init(_ data: Data = Data()) { self.data = data }
    init(serializedByteBuffer: inout ByteBuffer) throws {
        data = Data(serializedByteBuffer.readBytes(length: serializedByteBuffer.readableBytes) ?? [])
    }
    func serialize(into buffer: inout ByteBuffer) throws { buffer.writeBytes(data) }
}

enum VideoError: LocalizedError {
    case failure(String), cancelled
    var errorDescription: String? {
        switch self {
        case .failure(let text): return text
        case .cancelled: return "Stopped."
        }
    }
}

struct Proto {
    struct Field { let number: Int; let value: UInt64; let bytes: Data }
    var data = Data()
    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 128 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value))
    }
    mutating func integer(_ field: Int, _ value: UInt64) { varint(UInt64(field << 3)); varint(value) }
    mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field << 3 | 2)); varint(UInt64(value.count)); data.append(value)
    }
    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func float(_ field: Int, _ value: Float) {
        varint(UInt64(field << 3 | 5)); data.appendLE(value.bitPattern)
    }
    static func fields(_ data: Data) throws -> [Field] {
        var cursor = 0
        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < data.count else { throw VideoError.failure("Truncated server message.") }
                let byte = data[cursor]; cursor += 1
                if shift == 63 && byte > 1 { throw VideoError.failure("Invalid server message.") }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw VideoError.failure("Invalid server message.")
        }
        var result: [Field] = []
        while cursor < data.count {
            let key = try readVarint(), number = Int(key >> 3), wire = key & 7
            guard number > 0 else { throw VideoError.failure("Invalid server field.") }
            if wire == 0 { result.append(Field(number: number, value: try readVarint(), bytes: Data())); continue }
            let length: Int
            switch wire {
            case 1: length = 8
            case 2:
                let count = try readVarint()
                guard count <= UInt64(data.count) else { throw VideoError.failure("Invalid server payload length.") }
                length = Int(count)
            case 5: length = 4
            default: throw VideoError.failure("Unsupported server wire type.")
            }
            guard length <= data.count - cursor else { throw VideoError.failure("Truncated server payload.") }
            result.append(Field(number: number, value: 0, bytes: Data(data[cursor..<(cursor + length)])))
            cursor += length
        }
        return result
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    mutating func putLE<T: FixedWidthInteger>(_ value: T, at index: Int) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { replaceSubrange(index..<(index + $0.count), with: $0) }
    }
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at index: Int) throws -> T {
        guard index >= 0, index <= count - MemoryLayout<T>.size else { throw VideoError.failure("Truncated tensor data.") }
        return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: T.self)) }
    }
}

// Forward FlatBuffer writer. Every slot is aligned to 8 bytes; field IDs match config.fbs.
struct ConfigBuffer {
    var data = Data(repeating: 0, count: 8)
    mutating func align(_ alignment: Int) { while data.count % alignment != 0 { data.append(0) } }
    mutating func table(_ fieldCount: Int) -> Int {
        align(2)
        let vtable = data.count
        data.appendLE(UInt16(4 + fieldCount * 2)); data.appendLE(UInt16(8 + fieldCount * 8))
        data.append(Data(repeating: 0, count: fieldCount * 2))
        align(8)
        let root = data.count
        data.append(Data(repeating: 0, count: 8 + fieldCount * 8))
        data.putLE(Int32(root - vtable), at: root)
        return root
    }
    mutating func field(_ root: Int, _ index: Int) -> Int {
        let distance = Int(try! data.readLE(Int32.self, at: root))
        data.putLE(UInt16(8 + index * 8), at: root - distance + 4 + index * 2)
        return root + 8 + index * 8
    }
    mutating func uint(_ root: Int, _ index: Int, _ value: UInt32) { let slot = field(root, index); data.putLE(value, at: slot) }
    mutating func ushort(_ root: Int, _ index: Int, _ value: UInt16) { let slot = field(root, index); data.putLE(value, at: slot) }
    mutating func float(_ root: Int, _ index: Int, _ value: Float) { uint(root, index, value.bitPattern) }
    mutating func byte(_ root: Int, _ index: Int, _ value: UInt8) { let slot = field(root, index); data[slot] = value }
    mutating func string(_ root: Int, _ index: Int, _ value: String) {
        let slot = field(root, index); align(4)
        data.putLE(UInt32(data.count - slot), at: slot)
        let bytes = Data(value.utf8); data.appendLE(UInt32(bytes.count)); data.append(bytes); data.append(0)
    }
    static func configuration(_ project: Project, family: Family) -> Data {
        var buffer = ConfigBuffer()
        let root = buffer.table(94)
        buffer.data.putLE(UInt32(root), at: 0)
        let size = project.dimensions
        buffer.ushort(root, 1, UInt16(size.width / 64)); buffer.ushort(root, 2, UInt16(size.height / 64))
        buffer.uint(root, 3, UInt32.random(in: 0...UInt32.max))
        buffer.uint(root, 4, UInt32(project.steps))
        buffer.float(root, 5, 1); buffer.float(root, 6, 1)
        buffer.string(root, 7, project.modelFile!)
        buffer.byte(root, 8, 16) // DDIM Trailing, matching H3's CLI default.
        buffer.uint(root, 46, UInt32(project.frameCount))
        buffer.float(root, 49, family == .h3 ? 12 : 1)
        buffer.uint(root, 72, UInt32(clamping: project.teaCacheStart))
        buffer.uint(root, 73, UInt32(clamping: project.teaCacheEnd))
        buffer.float(root, 74, Float(project.teaCacheThreshold))
        buffer.byte(root, 75, project.teaCacheEnabled ? 1 : 0)
        buffer.uint(root, 78, UInt32(clamping: project.teaCacheMaxSkipSteps))
        buffer.byte(root, 89, project.solAttentionEnabled ? 1 : 0)
        buffer.uint(root, 90, UInt32(clamping: project.solAttentionStart))
        buffer.float(root, 91, Float(project.solAttentionTau))
        let loras = project.loras
        let slot = buffer.field(root, 20)
        buffer.align(4)
        buffer.data.putLE(UInt32(buffer.data.count - slot), at: slot)
        buffer.data.appendLE(UInt32(loras.count))
        let vector = buffer.data.count
        buffer.data.append(Data(repeating: 0, count: loras.count * 4))
        for (index, lora) in loras.enumerated() {
            let table = buffer.table(3)
            buffer.data.putLE(UInt32(table - (vector + index * 4)), at: vector + index * 4)
            buffer.string(table, 0, lora.0); buffer.float(table, 1, Float(lora.1))
        }
        return buffer.data
    }
}
