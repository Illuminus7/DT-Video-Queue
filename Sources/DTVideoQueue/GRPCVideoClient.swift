import CryptoKit
import Foundation
import GRPC
import Logging
import NIO
import NIOSSL

struct ServerSettings: Codable {
    var host = "127.0.0.1"
    var port = 7859
    var tls = true
}

enum ServerStatus {
    case checking, on, off, needsSecret

    var label: String {
        switch self {
        case .checking: return "Checking gRPC server…"
        case .on: return "gRPC Server On"
        case .off: return "gRPC Server Off"
        case .needsSecret: return "gRPC Server On · Shared Secret enabled"
        }
    }
}

final class GRPCVideoClient {
    private let group: MultiThreadedEventLoopGroup
    private let channel: GRPCChannel
    private let log: (String) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var activeCall: ServerStreamingCall<RPCMessage, RPCMessage>?

    init(settings: ServerSettings, log: @escaping (String) -> Void) throws {
        self.log = log
        let security: GRPCChannelPool.Configuration.TransportSecurity
        if settings.tls {
            guard let url = Bundle.module.url(forResource: "root_ca", withExtension: "crt") else { throw VideoError.failure("Draw Things TLS certificate is missing.") }
            let certificate = try NIOSSLCertificate(file: url.path, format: .pem)
            security = .tls(.makeClientConfigurationBackedByNIOSSL(trustRoots: .certificates([certificate]), certificateVerification: .noHostnameVerification))
        } else { security = .plaintext }
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var configuration = GRPCChannelPool.Configuration.with(target: .host(settings.host.trimmingCharacters(in: .whitespacesAndNewlines), port: settings.port), transportSecurity: security, eventLoopGroup: group)
        configuration.maximumReceiveMessageLength = 1024 * 1024 * 1024
        configuration.backgroundActivityLogger = Logger(label: "DTVideoQueue", factory: { _ in SwiftLogNoOpLogHandler() })
        do { channel = try GRPCChannelPool.with(configuration: configuration) }
        catch { try? group.syncShutdownGracefully(); throw error }
    }

    deinit {
        let group = group
        channel.close().whenComplete { _ in group.shutdownGracefully { _ in } }
    }

    private var options: CallOptions {
        CallOptions(messageEncoding: .enabled(.responsesOnly(decompressionLimit: .absolute(1024 * 1024 * 1024))), logger: Logger(label: "DTVideoQueue", factory: { _ in SwiftLogNoOpLogHandler() }))
    }

    /// Stops the current generation; safe to call from any thread.
    func cancel() {
        lock.lock(); cancelled = true; let call = activeCall; lock.unlock()
        call?.cancel(promise: nil)
    }

    /// Sends Echo and returns whether the server requires a shared secret.
    private func echo(seconds: Int64) throws -> Bool {
        var echo = Proto(); echo.string(1, "DT Video Queue")
        var options = options; options.timeLimit = .timeout(.seconds(seconds))
        let call: UnaryCall<RPCMessage, RPCMessage> = channel.makeUnaryCall(path: "/ImageGenerationService/Echo", request: RPCMessage(echo.data), callOptions: options)
        let response = try call.response.wait()
        return try Proto.fields(response.data).contains(where: { $0.number == 4 && $0.value != 0 })
    }

    func checkConnection() throws {
        guard try !echo(seconds: 15) else { throw VideoError.failure("The server requires a shared secret. Disable Shared Secret in Draw Things for this localhost connection.") }
        log("Connected to Draw Things gRPC server.\n")
    }

    /// Quick Echo for the main window's server status indicator.
    func probe() -> ServerStatus {
        guard let needsSecret = try? echo(seconds: 3) else { return .off }
        return needsSecret ? .needsSecret : .on
    }

    func generate(project: Project, family: Family, line: VideoLine, output: URL) throws {
        guard VideoTiming.frameCounts.contains(project.frameCount) else { throw VideoError.failure("Invalid H3 frame count.") }
        if let error = project.optimizationError { throw VideoError.failure(error) }
        try checkConnection()
        // Verify chosen files on the server; never upload or download models automatically.
        let files = [project.modelFile, project.lora1File, project.lora2File].compactMap { $0 }
        var query = Proto(); for file in files { query.string(1, file) }
        var fileOptions = options; fileOptions.timeLimit = .timeout(.seconds(15))
        let existence: UnaryCall<RPCMessage, RPCMessage> = channel.makeUnaryCall(path: "/ImageGenerationService/FilesExist", request: RPCMessage(query.data), callOptions: fileOptions)
        let reply = try Proto.fields(existence.response.wait().data)
        var present: [Bool] = []
        for field in reply where field.number == 2 {
            if field.bytes.isEmpty { present.append(field.value != 0) }
            else { present.append(contentsOf: field.bytes.map { $0 != 0 }) }
        }
        guard present.count == files.count else { throw VideoError.failure("Could not verify installed models on the server.") }
        for (file, exists) in zip(files, present) where !exists { throw VideoError.failure("The Draw Things server does not have \(file).") }

        var request = Proto()
        request.integer(2, 1); request.string(5, line.prompt)
        request.bytes(7, ConfigBuffer.configuration(project, family: family))
        request.string(10, "DT Video Queue"); request.integer(11, 2); request.integer(14, 1)
        let size = project.dimensions
        if let path = line.startImage {
            let tensor = try ImageTensor.image(at: path, width: size.width, height: size.height)
            request.bytes(1, Data(SHA256.hash(data: tensor))); request.bytes(12, tensor)
        }
        if let path = line.endImage {
            let tensor = try ImageTensor.image(at: path, width: size.width, height: size.height)
            var weighted = Proto(); weighted.bytes(1, Data(SHA256.hash(data: tensor))); weighted.float(2, 1)
            var hint = Proto(); hint.string(1, "shuffle"); hint.bytes(2, weighted.data)
            request.bytes(4, hint.data); request.bytes(12, tensor)
        }
        let exporter = try MovieExporter(output: output, width: size.width, height: size.height, fps: family == .h3 ? 24 : 25)
        var partialImage = Data(), partialAudio = Data()
        var failure: Error?
        var audio: [ImageTensor] = []
        log("Sol Attention: \(project.solAttentionEnabled ? "on" : "off") · start \(project.solAttentionStart) · Tau \(project.solAttentionTau)\n")
        log("TeaCache: \(project.teaCacheEnabled ? "on" : "off") · steps \(project.teaCacheStart)–\(project.teaCacheEnd) · threshold \(project.teaCacheThreshold) · max skip \(project.teaCacheMaxSkipSteps)\n")
        log("Generating \(project.frameCount) frames…\n")
        var generationOptions = options; generationOptions.timeLimit = .timeout(.hours(2))
        let call: ServerStreamingCall<RPCMessage, RPCMessage> = channel.makeServerStreamingCall(path: "/ImageGenerationService/GenerateImage", request: RPCMessage(request.data), callOptions: generationOptions) { response in
            guard failure == nil else { return }
            do {
                let fields = try Proto.fields(response.data)
                let more = fields.contains { $0.number == 8 && $0.value == 1 }
                for field in fields where field.number == 1 {
                    if more { partialImage.append(field.bytes) }
                    else {
                        let payload = partialImage + field.bytes; partialImage.removeAll(keepingCapacity: true)
                        try exporter.append(ImageTensor.decode(payload))
                    }
                }
                for field in fields where field.number == 10 {
                    if more { partialAudio.append(field.bytes) }
                    else {
                        audio.append(try ImageTensor.decode(partialAudio + field.bytes)); partialAudio.removeAll(keepingCapacity: true)
                    }
                }
                if let signpost = fields.first(where: { $0.number == 2 }) {
                    let stages = try Proto.fields(signpost.bytes)
                    if let sampling = stages.first(where: { $0.number == 3 }) {
                        let step = try Proto.fields(sampling.bytes).first { $0.number == 1 }?.value ?? 0
                        self.log("Sampling \(step + 1) / \(project.steps)\n")
                    } else if stages.contains(where: { $0.number == 1 }) { self.log("Prompt encoded.\n") }
                    else if stages.contains(where: { $0.number == 2 }) { self.log("Reference images encoded.\n") }
                }
            } catch { failure = error }
        }
        lock.lock(); activeCall = call; let stop = cancelled; lock.unlock()
        if stop { call.cancel(promise: nil) }
        let status = try call.status.wait()
        lock.lock(); activeCall = nil; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw VideoError.cancelled }
        if let failure { throw failure }
        guard status.code == .ok else { throw VideoError.failure("Draw Things: \(status.message ?? status.code.description)") }
        guard partialImage.isEmpty, partialAudio.isEmpty else { throw VideoError.failure("Draw Things returned an incomplete video.") }
        log("Encoding movie…\n")
        try exporter.finish(audio: audio, sampleRate: family == .h3 ? 32000 : (project.modelFile?.contains("2.3") == true || project.modelFile?.contains("2_3") == true ? 48000 : 24000))
        log("Received \(exporter.frameCount) frames.\n")
    }
}
