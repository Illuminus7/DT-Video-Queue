import AppKit
import Combine
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum Family: String, Codable { case h3 = "H3", ltx = "LTX" }

struct ModelItem: Identifiable, Hashable {
    let file: String
    let name: String
    let family: Family
    var id: String { file }
}

enum VideoSize: String, Codable, CaseIterable, Identifiable {
    case large = "Large", normal = "Normal", small = "Small", extraSmall = "Extra Small"
    var id: String { rawValue }
    var title: String { self == .extraSmall ? "Very Small" : rawValue }
    var longSide: Int {
        switch self {
        case .large: 1152
        case .normal: 768
        case .small: 576
        case .extraSmall: 384
        }
    }
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case portrait = "2:3", square = "1:1", landscape = "3:2"
    var id: String { rawValue }

    func dimensions(longSide: Int) -> (width: Int, height: Int) {
        switch self {
        case .portrait: (longSide * 2 / 3, longSide)
        case .square: (longSide, longSide)
        case .landscape: (longSide, longSide * 2 / 3)
        }
    }
}

enum VideoTiming {
    // Draw Things H3 accepts a single frame or 17k + 5 frames, through 362.
    static let frameCounts = [1] + Array(stride(from: 5, through: 362, by: 17))
    static func seconds(frames: Int, family: Family?) -> Double {
        Double(frames) / (family == .ltx ? 25 : 24)
    }
}

struct VideoLine: Identifiable, Codable {
    var id = UUID()
    var startImage: String? = nil
    var endImage: String? = nil
    var prompt = ""
}

struct Project: Codable {
    var modelFile: String? = nil
    var lora1File: String? = nil
    var lora2File: String? = nil
    var lora1Strength = 1.0
    var lora2Strength = 1.0
    var size: VideoSize = .normal
    var aspectRatio: AspectRatio = .portrait
    var steps = 6
    var frameCount = 124
    var solAttentionEnabled = true
    var solAttentionStart = 2
    var solAttentionTau = 0.50
    var teaCacheEnabled = true
    var teaCacheStart = 5
    var teaCacheEnd = 6
    var teaCacheThreshold = 0.06
    var teaCacheMaxSkipSteps = 3
    var server = ServerSettings()
    var outputFolder: String? = nil
    var lines: [VideoLine] = [VideoLine()]
    var dimensions: (width: Int, height: Int) { aspectRatio.dimensions(longSide: size.longSide) }

    var optimizationError: String? {
        if solAttentionEnabled && (!(0...200).contains(solAttentionStart) || !solAttentionTau.isFinite || solAttentionTau < 0 || solAttentionTau > Double(Float.greatestFiniteMagnitude)) {
            return "Sol Attention requires a start step from 0 to 200 and a non-negative Tau."
        }
        if teaCacheEnabled && (!(0...200).contains(teaCacheStart) || !(0...200).contains(teaCacheEnd) || teaCacheEnd < teaCacheStart ||
            !teaCacheThreshold.isFinite || teaCacheThreshold < 0 || teaCacheThreshold > Double(Float.greatestFiniteMagnitude) || !(1...200).contains(teaCacheMaxSkipSteps)) {
            return "TeaCache requires start ≤ end (0–200), a non-negative threshold, and max skip steps from 1 to 200."
        }
        return nil
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case solAttentionEnabled, solAttentionStart, solAttentionTau
        case teaCacheEnabled, teaCacheStart, teaCacheEnd, teaCacheThreshold, teaCacheMaxSkipSteps
        case modelFile, lora1File, lora2File, lora1Strength, lora2Strength, size, aspectRatio, steps, frameCount, server, outputFolder, lines
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelFile = try values.decodeIfPresent(String.self, forKey: .modelFile)
        lora1File = try values.decodeIfPresent(String.self, forKey: .lora1File)
        lora2File = try values.decodeIfPresent(String.self, forKey: .lora2File)
        lora1Strength = try values.decodeIfPresent(Double.self, forKey: .lora1Strength) ?? 1
        lora2Strength = try values.decodeIfPresent(Double.self, forKey: .lora2Strength) ?? 1
        size = try values.decodeIfPresent(VideoSize.self, forKey: .size) ?? .normal
        aspectRatio = try values.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio) ?? .portrait
        steps = try values.decodeIfPresent(Int.self, forKey: .steps) ?? 6
        frameCount = try values.decodeIfPresent(Int.self, forKey: .frameCount) ?? 124
        guard VideoTiming.frameCounts.contains(frameCount) else {
            throw VideoError.failure("Frame count must be 1, or 5 through 362 in increments of 17.")
        }
        solAttentionEnabled = try values.decodeIfPresent(Bool.self, forKey: .solAttentionEnabled) ?? true
        solAttentionStart = try values.decodeIfPresent(Int.self, forKey: .solAttentionStart) ?? 2
        solAttentionTau = try values.decodeIfPresent(Double.self, forKey: .solAttentionTau) ?? 0.50
        teaCacheEnabled = try values.decodeIfPresent(Bool.self, forKey: .teaCacheEnabled) ?? true
        teaCacheStart = try values.decodeIfPresent(Int.self, forKey: .teaCacheStart) ?? 5
        teaCacheEnd = try values.decodeIfPresent(Int.self, forKey: .teaCacheEnd) ?? 6
        teaCacheThreshold = try values.decodeIfPresent(Double.self, forKey: .teaCacheThreshold) ?? 0.06
        teaCacheMaxSkipSteps = try values.decodeIfPresent(Int.self, forKey: .teaCacheMaxSkipSteps) ?? 3
        server = try values.decodeIfPresent(ServerSettings.self, forKey: .server) ?? ServerSettings()
        outputFolder = try values.decodeIfPresent(String.self, forKey: .outputFolder)
        lines = try values.decodeIfPresent([VideoLine].self, forKey: .lines) ?? [VideoLine()]
    }
}

private enum Catalog {
    private static var accountHome: URL {
        if let account = getpwuid(getuid()), let path = account.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static let defaultDirectory = accountHome
        .appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models")
    private static let cache = accountHome
        .appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Library/Caches/net")

    static func load(_ file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries
    }

    static func family(_ version: String, _ file: String) -> Family? {
        let v = version.lowercased(), f = file.lowercased()
        if v.contains("minimax_h3") || f.contains("minimax_h3") || f.hasPrefix("h3_") { return .h3 }
        if v.hasPrefix("ltx") || f.hasPrefix("ltx") { return .ltx }
        return nil
    }

    static func entries(named name: String, in directory: URL) -> [ModelItem] {
        let files = [directory.appendingPathComponent(name), cache.appendingPathComponent(name == "custom.json" ? "models.json" : "loras.json")]
        var result: [String: ModelItem] = [:]
        for source in files {
            for record in load(source) {
                guard let file = record["file"] as? String,
                      let family = family(record["version"] as? String ?? "", file),
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else { continue }
                let title = record["name"] as? String ?? file
                result[file] = ModelItem(file: file, name: title, family: family)
            }
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor final class QueueStore: ObservableObject {
    @Published var project = Project()
    @Published var models: [ModelItem] = []
    @Published var loras: [ModelItem] = []
    @Published var selectedLine: UUID?
    @Published var generated = 0
    @Published var total = 0
    @Published var processing = 0
    @Published var running = false
    @Published var terminal = ""
    @Published var message: String?
    @Published var catalogMessage: String?
    @Published var modelsDirectory = Catalog.defaultDirectory
    @Published var serverStatus: ServerStatus = .checking

    var server: ServerSettings {
        get { project.server }
        set { project.server = newValue }
    }
    private var generationTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var activeClient: GRPCVideoClient?
    private var stopRequested = false
    private var sleepActivity: NSObjectProtocol?
    private var autosave: AnyCancellable?
    private static let autosaveURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DT Video Queue/Last Session.json")
    private var queue: [VideoLine] = []
    private var hasFolderAccess = false
    private let bookmarkKey = "DrawThingsModelsFolderBookmark"

    init() {
        if let data = try? Data(contentsOf: Self.autosaveURL),
           let saved = try? JSONDecoder().decode(Project.self, from: data) {
            project = saved
            if project.lines.isEmpty { project.lines = [VideoLine()] }
        }
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let folder = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) {
                modelsDirectory = folder
                hasFolderAccess = folder.startAccessingSecurityScopedResource()
            }
        }
        if let data = UserDefaults.standard.data(forKey: "GRPCServerSettings"),
           let settings = try? JSONDecoder().decode(ServerSettings.self, from: data) { server = settings }
        refreshCatalog()
        monitorServer()
        // Keep prompts and settings across launches.
        autosave = $project.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main).sink { project in
            guard let data = try? JSONEncoder().encode(project) else { return }
            try? FileManager.default.createDirectory(at: Self.autosaveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.autosaveURL, options: .atomic)
        }
    }

    /// Polls the gRPC server with Echo every few seconds. While a queue runs, the stream itself proves the server is on.
    private func monitorServer() {
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.running {
                    let settings = self.server
                    let status = await Task.detached(priority: .utility) { () -> ServerStatus in
                        guard let client = try? GRPCVideoClient(settings: settings, log: { _ in }) else { return .off }
                        return client.probe()
                    }.value
                    if !self.running { self.serverStatus = status }
                } else { self.serverStatus = .on }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func saveServerSettings() {
        if let data = try? JSONEncoder().encode(server) { UserDefaults.standard.set(data, forKey: "GRPCServerSettings") }
    }

    var family: Family? { models.first { $0.file == project.modelFile }?.family }
    var availableLoras: [ModelItem] { loras.filter { $0.family == family } }

    func refreshCatalog() {
        models = Catalog.entries(named: "custom.json", in: modelsDirectory)
        loras = Catalog.entries(named: "custom_lora.json", in: modelsDirectory)
        let modelJSON = modelsDirectory.appendingPathComponent("custom.json")
        let loraJSON = modelsDirectory.appendingPathComponent("custom_lora.json")
        if !FileManager.default.isReadableFile(atPath: modelJSON.path) ||
           !FileManager.default.isReadableFile(atPath: loraJSON.path) {
            catalogMessage = "Draw Things model metadata is not readable. Choose the Models folder to grant access."
        } else if models.isEmpty {
            catalogMessage = "No installed H3 or LTX models were found in this Models folder."
        } else {
            catalogMessage = nil
        }
        if !models.isEmpty && !models.contains(where: { $0.file == project.modelFile }) {
            project.modelFile = models.first?.file
        }
        validateLoras()
    }

    func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = modelsDirectory
        panel.prompt = "Use Models Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("custom.json").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("custom_lora.json").path) else {
            message = "Choose the Draw Things Models folder containing custom.json and custom_lora.json."
            return
        }
        if hasFolderAccess { modelsDirectory.stopAccessingSecurityScopedResource() }
        modelsDirectory = folder
        hasFolderAccess = folder.startAccessingSecurityScopedResource()
        if let bookmark = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
        refreshCatalog()
    }

    func validateLoras() {
        let choices = Set(availableLoras.map(\.file))
        if let file = project.lora1File, !choices.contains(file) { project.lora1File = nil }
        if let file = project.lora2File, !choices.contains(file) { project.lora2File = nil }
    }

    func newProject() {
        guard !running else { return }
        project.lines = [VideoLine()]
        selectedLine = nil
        generated = 0
        total = 0
        processing = 0
        terminal = ""
    }

    func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Video Queue.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONEncoder().encode(project)
            try data.write(to: url, options: .atomic)
        } catch { message = "Could not save project: \(error.localizedDescription)" }
    }

    func loadProject() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            refreshCatalog()
            if project.lines.isEmpty { project.lines = [VideoLine()] }
            selectedLine = nil
            generated = 0
            total = 0
            processing = 0
            terminal = ""
        } catch { message = "Could not load project: \(error.localizedDescription)" }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Output Folder"
        if panel.runModal() == .OK { project.outputFolder = panel.url?.path }
    }

    func start() {
        guard !running else { return }
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(server.port) else { message = "Enter a server address and a port between 1 and 65535 in Settings."; return }
        guard project.modelFile != nil else { message = "Choose an installed H3 or LTX model."; return }
        guard project.lora1Strength.isFinite, project.lora2Strength.isFinite else {
            message = "LoRA strengths must be valid numbers."; return
        }
        guard (1...200).contains(project.steps) else {
            message = "Steps must be between 1 and 200."; return
        }
        guard VideoTiming.frameCounts.contains(project.frameCount) else {
            message = "Choose a valid H3 frame count: 1, or 5 through 362 in increments of 17."; return
        }
        if let error = project.optimizationError { message = error; return }
        let lines = project.lines.filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { message = "Enter a prompt for at least one line."; return }
        for line in lines {
            for path in [line.startImage, line.endImage].compactMap({ $0 }) where !FileManager.default.fileExists(atPath: path) {
                message = "Image file is missing: \(path)"; return
            }
            if line.endImage != nil && line.startImage == nil {
                message = "Add Image 1 before Image 2."; return
            }
        }
        if project.outputFolder == nil { chooseOutputFolder() }
        guard let folder = project.outputFolder else { return }
        guard FileManager.default.fileExists(atPath: folder) else { message = "The output folder no longer exists: \(folder)"; return }
        queue = lines
        generated = 0
        total = lines.count
        processing = 0
        terminal = ""
        running = true
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                              reason: "Generating videos with Draw Things")
        runNext()
    }

    func stop() {
        guard running, !stopRequested else { return }
        stopRequested = true
        appendTerminal("\nStopping…\n")
        activeClient?.cancel()
    }

    private func finishRun() {
        running = false
        processing = 0
        generationTask = nil
        activeClient = nil
        stopRequested = false
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
    }

    private func appendTerminal(_ text: String) {
        terminal += text
        if terminal.count > 150_000 { terminal.removeFirst(terminal.count - 150_000) }
    }

    private func runNext() {
        guard generated < queue.count else {
            finishRun()
            appendTerminal("\nQueue complete. \(generated) of \(total) videos generated.\n")
            return
        }
        processing = generated + 1
        let line = queue[generated]
        guard let model = project.modelFile, let folder = project.outputFolder, let family else {
            finishRun()
            message = "Choose an installed model and an output folder."
            return
        }
        let output = URL(fileURLWithPath: folder).appendingPathComponent(String(format: "video-%03d-%@.mov", processing, UUID().uuidString.prefix(8).description))
        let settings = server
        let snapshot = project
        let dimensions = project.dimensions
        appendTerminal("\n▶ Video \(processing) of \(total) · \(model) · \(dimensions.width) × \(dimensions.height)\n")
        appendTerminal("gRPC: \(settings.host):\(settings.port) · TLS \(settings.tls ? "on" : "off")\n")
        let client: GRPCVideoClient
        do {
            client = try GRPCVideoClient(settings: settings) { [weak self] text in
                Task { @MainActor in self?.appendTerminal(text) }
            }
        } catch {
            finishRun()
            appendTerminal("\nGeneration failed: \(error.localizedDescription)\n")
            message = "Video \(processing) failed: \(error.localizedDescription)"
            return
        }
        activeClient = client
        generationTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.generate(project: snapshot, family: family, line: line, output: output)
                }.value
                guard let self else { return }
                self.generated += 1
                self.appendTerminal("\n✓ Saved \(output.lastPathComponent)\n")
                if self.stopRequested {
                    self.finishRun()
                    self.appendTerminal("\nStopped. \(self.generated) of \(self.total) videos generated.\n")
                } else { self.runNext() }
            } catch {
                guard let self else { return }
                let stopped = self.stopRequested
                self.finishRun()
                if stopped {
                    self.appendTerminal("\nStopped. \(self.generated) of \(self.total) videos generated.\n")
                } else {
                    self.appendTerminal("\nGeneration failed: \(error.localizedDescription)\n")
                    self.message = "Video \(self.generated + 1) failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

@main struct DTVideoQueueApp: App {
    @StateObject private var store = QueueStore()
    var body: some Scene {
        WindowGroup("DT Video Queue") { MainView().environmentObject(store) }
            .defaultSize(width: 1120, height: 790)
        Window("Settings", id: "settings") { SettingsView().environmentObject(store) }
            .defaultSize(width: 460, height: 670)
    }
}

private struct MainView: View {
    @EnvironmentObject private var store: QueueStore
    @Environment(\.openWindow) private var openWindow
    @State private var showTerminal = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("DT Video Queue", systemImage: "film.stack.fill")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                ServerStatusBadge(status: store.serverStatus, address: "\(store.server.host):\(store.server.port)")
                    .padding(.leading, 12)
                Spacer()
                Button("New Project") { store.newProject() }.disabled(store.running)
                Button("Load Project") { store.loadProject() }.disabled(store.running)
                Button("Save Project") { store.saveProject() }
            }
            .padding(.horizontal, 25).padding(.top, 22).padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("GLOBAL SETTINGS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.chooseModelsFolder() } label: { Label("Models Folder…", systemImage: "folder") }
                        .buttonStyle(.borderless)
                    Button { store.refreshCatalog() } label: { Label("Refresh Models", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                    Button { openWindow(id: "settings") } label: { Label("Settings", systemImage: "gearshape") }
                }
                if let catalogMessage = store.catalogMessage {
                    Label(catalogMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Model").font(.caption).foregroundStyle(.secondary)
                        Picker("Model", selection: $store.project.modelFile) {
                            Text("Choose a model").tag(nil as String?)
                            ForEach(store.models) { item in Text("\(item.name) · \(item.family.rawValue)").tag(Optional(item.file)) }
                        }.labelsHidden().frame(width: 240)
                            .onChange(of: store.project.modelFile) { store.validateLoras() }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Steps").font(.caption).foregroundStyle(.secondary)
                        Stepper(value: $store.project.steps, in: 1...200) {
                            TextField("Steps", value: $store.project.steps, format: .number)
                                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 53)
                        }.frame(width: 112)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Video size").font(.caption).foregroundStyle(.secondary)
                        Picker("Video size", selection: $store.project.size) {
                            ForEach(VideoSize.allCases) { size in Text(size.title).tag(size) }
                        }.labelsHidden().frame(width: 140)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Aspect ratio").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("Aspect ratio", selection: $store.project.aspectRatio) {
                                ForEach(AspectRatio.allCases) { ratio in Text(ratio.rawValue).tag(ratio) }
                            }.labelsHidden().frame(width: 85)
                            Text("\(store.project.dimensions.width) × \(store.project.dimensions.height)")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Frames").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("Frames", selection: $store.project.frameCount) {
                                ForEach(VideoTiming.frameCounts, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }.labelsHidden().frame(width: 90)
                            Text("\(VideoTiming.seconds(frames: store.project.frameCount, family: store.family), specifier: "%.2f") s")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary).fixedSize()
                        }
                        .help("H3: 1 frame, or 5–362 frames in increments of 17. Duration uses 24 FPS for H3 and 25 FPS for LTX.")
                    }
                }
                HStack(spacing: 18) {
                    loraPicker("LoRA 1", selection: $store.project.lora1File, strength: $store.project.lora1Strength)
                    loraPicker("LoRA 2", selection: $store.project.lora2File, strength: $store.project.lora2Strength)
                }
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(store.project.outputFolder ?? "Choose a folder for generated movies")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Output Folder…") { store.chooseOutputFolder() }
                }
            }
            .disabled(store.running)
            .padding(18)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 15))
            .padding(.horizontal, 25)

            HStack {
                Text("VIDEO QUEUE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.project.lines.count) lines").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 27).padding(.top, 22).padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($store.project.lines) { $line in
                        LineView(line: $line, number: (store.project.lines.firstIndex(where: { $0.id == line.id }) ?? 0) + 1,
                                 selected: store.selectedLine == line.id)
                            .onTapGesture { store.selectedLine = line.id }
                    }
                }.padding(.horizontal, 25).padding(.bottom, 16)
            }

            Divider()
            HStack(spacing: 10) {
                Button { store.project.lines.append(VideoLine()) } label: { Label("Add Line", systemImage: "plus") }
                    .disabled(store.running)
                Button {
                    if let id = store.selectedLine, let index = store.project.lines.firstIndex(where: { $0.id == id }) {
                        store.project.lines.remove(at: index)
                    } else if !store.project.lines.isEmpty { store.project.lines.removeLast() }
                    store.selectedLine = nil
                } label: { Label("Remove Line", systemImage: "minus") }
                    .disabled(store.running || store.project.lines.isEmpty)
                Spacer()
                if store.running { ProgressView().controlSize(.small) }
                Text(store.running ? "Generating \(store.processing) of \(store.total) · \(store.generated) complete" : "\(store.generated) of \(store.total) generated")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { showTerminal = true } label: { Label("Terminal", systemImage: "terminal") }
                if store.running {
                    Button { store.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(FilledButtonStyle(color: Color(red: 1.0, green: 0.55, blue: 0.55)))
                } else {
                    Button { store.start() } label: { Label("Go", systemImage: "play.fill") }
                        .buttonStyle(FilledButtonStyle(color: Color(red: 0.45, green: 0.85, blue: 0.5)))
                }
            }.padding(20)
        }
        .frame(minWidth: 1040, minHeight: 610)
        .sheet(isPresented: $showTerminal) { TerminalView(text: store.terminal) }
        .alert("DT Video Queue", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }

    private func loraPicker(_ title: String, selection: Binding<String?>, strength: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker(title, selection: selection) {
                    Text("None").tag(nil as String?)
                    ForEach(store.availableLoras) { item in Text(item.name).tag(Optional(item.file)) }
                }.labelsHidden().frame(maxWidth: .infinity)
                TextField("Strength", value: strength, format: .number.precision(.fractionLength(1...3)))
                    .frame(width: 65).textFieldStyle(.roundedBorder)
            }
        }.frame(maxWidth: .infinity)
    }
}

private struct LineView: View {
    @Binding var line: VideoLine
    let number: Int
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", number)).font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.secondary).frame(width: 35, alignment: .leading).padding(.top, 8)
            ImageDropView(title: "Image 1", symbol: "photo.badge.plus", path: $line.startImage)
            ImageDropView(title: "Image 2", symbol: "photo.on.rectangle.angled", path: $line.endImage)
            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $line.prompt)
                    .font(.body).scrollContentBackground(.hidden)
                    .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                    .frame(minHeight: 94)
            }.frame(maxWidth: .infinity)
        }
        .padding(13)
        .background(.quaternary.opacity(selected ? 0.8 : 0.35), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

private struct ImageDropView: View {
    let title: String
    let symbol: String
    @Binding var path: String?
    @State private var targeted = false
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill().frame(width: 118, height: 72).clipped()
                } else {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(height: 72)
                }
                Text(title).font(.caption.weight(.medium))
                Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Drop or click")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 124, height: 112)
            .background(targeted ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(targeted ? Color.accentColor : .gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5])))
        }
        .buttonStyle(.plain)
        .task(id: path) { thumbnail = await Self.thumbnail(for: path) }
        .contextMenu { if path != nil { Button("Clear Image") { path = nil } } }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, NSImage(contentsOf: url) != nil else { return }
                DispatchQueue.main.async { path = url.path }
            }
            return true
        }
    }

    /// Small, cached preview so redraws during generation don't reload full-size images from disk.
    private static func thumbnail(for path: String?) async -> CGImage? {
        guard let path else { return nil }
        return await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 256]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { path = panel.url?.path }
    }
}

private struct TerminalView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Terminal", systemImage: "terminal").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            ScrollViewReader { reader in
                ScrollView {
                    Text(text.isEmpty ? "No generation activity yet." : text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .onAppear { reader.scrollTo("end", anchor: .bottom) }
                .onChange(of: text) { reader.scrollTo("end", anchor: .bottom) }
            }
            .padding(12).background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(18).frame(width: 760, height: 460)
    }
}

/// Keeps its color when the window is inactive, unlike `.borderedProminent`.
private struct FilledButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold)).foregroundStyle(.black.opacity(0.8))
            .frame(minWidth: 75).padding(.horizontal, 12).padding(.vertical, 5)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ServerStatusBadge: View {
    let status: ServerStatus
    let address: String
    private var color: Color {
        switch status {
        case .checking: return .gray
        case .on: return .green
        case .off: return .red
        case .needsSecret: return .orange
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(status.label).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
        .help("Draw Things gRPC server at \(address)")
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var store: QueueStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Settings", systemImage: "gearshape.fill").font(.title2.weight(.semibold))
                GroupBox("Sol Attention") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable", isOn: $store.project.solAttentionEnabled).toggleStyle(.switch)
                        VStack(spacing: 12) {
                            integerSetting("Start Step", value: $store.project.solAttentionStart, range: 0...200)
                            decimalSetting("Tau", value: $store.project.solAttentionTau)
                        }.disabled(!store.project.solAttentionEnabled)
                        Text("Start Step controls the initial steps using exact attention. Higher Tau increases approximation and may affect video and audio quality.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("TeaCache") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable", isOn: $store.project.teaCacheEnabled).toggleStyle(.switch)
                        VStack(spacing: 12) {
                            integerSetting("Start Step", value: $store.project.teaCacheStart, range: 0...200)
                            integerSetting("End Step", value: $store.project.teaCacheEnd, range: 0...200)
                            decimalSetting("Threshold", value: $store.project.teaCacheThreshold)
                            integerSetting("Max Skip Steps", value: $store.project.teaCacheMaxSkipSteps, range: 1...200)
                        }.disabled(!store.project.teaCacheEnabled)
                    }.padding(8)
                }
                GroupBox("Draw Things gRPC Server") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Host", text: $store.server.host)
                        HStack {
                            Text("Port:")
                            TextField("Port", value: $store.server.port, format: .number.grouping(.never)).frame(width: 90)
                            Toggle("TLS", isOn: $store.server.tls)
                        }
                        Text("Enable API Server → gRPC in Draw Things. The default connection is localhost:7859 with TLS enabled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                Text("These settings apply to every video and are saved with the project. Keep Draw Things open while the queue is processing.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).disabled(store.running)
        }
        .frame(minWidth: 420, minHeight: 450)
        .onChange(of: store.server.host) { store.saveServerSettings() }
        .onChange(of: store.server.port) { store.saveServerSettings() }
        .onChange(of: store.server.tls) { store.saveServerSettings() }
    }

    private func integerSetting(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: value, in: range) {
                TextField(title, value: value, format: .number.grouping(.never))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 66)
            }.fixedSize()
        }
    }

    private func decimalSetting(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: value, step: 0.01) {
                TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 66)
            }.fixedSize()
        }
    }
}
