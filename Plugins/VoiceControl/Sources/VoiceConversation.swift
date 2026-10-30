import AppKit
import AVFoundation
import Combine
import MacToolsPluginKit

@MainActor
final class VoiceConversation: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var connected = false
    @Published private(set) var muted = false
    @Published private(set) var status = "准备就绪"
    @Published private(set) var turns: [VoiceTranscript.Turn] = []
    @Published private(set) var capturing = false
    @Published private(set) var inputLevels = Array(repeating: Float.zero, count: 24)
    @Published private(set) var outputLevels = Array(repeating: Float.zero, count: 24)
    var transcript: String {
        turns.map { text($0.speaker == .user ? "你：" : "助手：") + $0.text }.joined(separator: "\n\n")
    }
    @Published private(set) var speaking = false
    @Published private(set) var activity: String?
    @Published var excludedPluginIDs: Set<String> = []
    private(set) var sessionProviders: [PluginVoiceProvider] = []
    var allowedProviders: [PluginVoiceProvider] {
        active ? sessionProviders : context?.providers().filter { !excludedPluginIDs.contains($0.id) } ?? []
    }
    @Published private(set) var credentialPath: String?
    @Published private(set) var credentialStatus: String
    @Published private(set) var hasCredentials: Bool
    @Published private(set) var credentialMessage: String?
    @Published private(set) var credentialError = false
    @Published private(set) var credentialBusy = false
    var context: PluginVoiceControlHostContext? { didSet { if active { stop() } } }
    var onChange: (() -> Void)?
    let localization: PluginLocalization
    private let credentials: VoiceCredentialConfiguration
    private let audio: any VoiceAudioIO
    private let requestMicrophone: () async -> Bool
    private var socket: URLSessionWebSocketTask?
    // Reuse transport resources, never an idle Live session. No request runs until Start.
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private var receiveTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var toolTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var tools: VoiceTools?
    private var startupTimeoutFailure = VoiceFailure.connection
    private var epoch = UUID()
    private var calls: [String: [[String: String]]] = [:]
    private var delegations: [String: String] = [:]
    private var handled: Set<String> = []
    private var toolQueue: [(String, [[String: String]])] = []
    private var captions = VoiceTranscript()
    private var pendingInput = VoicePendingInput()
    private var startupInstant = ContinuousClock.now
    private(set) var startupTimings: [String: Double] = [:]

    init(context: PluginRuntimeContext, audio: any VoiceAudioIO = VoiceAudio(),
         requestMicrophone: @escaping () async -> Bool = {
             switch AVCaptureDevice.authorizationStatus(for: .audio) {
             case .authorized: return true
             case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
             default: return false
             }
         },
         secrets: any VoiceSecretStoring = VoiceSecretStore()) {
        self.audio = audio; self.requestMicrophone = requestMicrophone
        let credentials = VoiceCredentialConfiguration(storage: context.storage, secrets: secrets)
        self.credentials = credentials
        credentialPath = credentials.path; hasCredentials = credentials.isConfigured
        credentialStatus = Self.credentialStatus(for: credentials)
        localization = PluginLocalization(bundle: context.resourceBundle)
        audio.observePlayback { [weak self] playing in self?.speaking = playing && self?.active == true }
        audio.observeOutputLevel { [weak self] level in
            guard let self, active else { return }
            outputLevels = Array(outputLevels.dropFirst()) + [level]
        }
    }
    deinit { network.invalidateAndCancel() }
    func text(_ value: String) -> String { localization.string(value, defaultValue: value) }
    #if DEBUG
    func chooseCredentials() {
        guard !active, !credentialBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = text("选择已有的 OpenAI API 密钥文件；只保存文件位置。")
        if panel.runModal() == .OK, let url = panel.url {
            credentials.selectFile(url.path); refreshCredentials()
        }
    }

    #endif

    private static func credentialStatus(for credentials: VoiceCredentialConfiguration) -> String {
        guard credentials.isConfigured else { return "请添加你自己的 OpenAI API 密钥" }
        return switch credentials.source {
        case .keychain: "已保存在本机钥匙串"
        case .file: "使用你选择的密钥文件"
        case .environment: "使用本机开发环境密钥"
        case .none: "请添加你自己的 OpenAI API 密钥"
        }
    }

    private func refreshCredentials() {
        credentialPath = credentials.path; hasCredentials = credentials.isConfigured
        credentialStatus = Self.credentialStatus(for: credentials)
        credentialMessage = nil; credentialError = false
    }

    func saveKey(_ key: String) async -> Bool {
        guard !active, !credentialBusy else { return false }
        credentialBusy = true
        defer { credentialBusy = false }
        do {
            try await credentials.save(key); refreshCredentials()
            credentialMessage = "密钥已保存，开始对话时将验证 API 访问权限。"
            return true
        } catch {
            credentialError = true
            if case VoiceFailure.credentials = error { credentialMessage = "密钥格式不正确，请检查后重试。" }
            else { credentialMessage = "无法保存密钥，请检查钥匙串访问权限。" }
            return false
        }
    }

    func forgetKey() async {
        guard !active, !credentialBusy else { return }
        credentialBusy = true
        defer { credentialBusy = false }
        do { try await credentials.forget(); refreshCredentials() }
        catch { credentialError = true; credentialMessage = "无法移除密钥，请检查钥匙串访问权限。" }
    }

    func start() {
        guard !active, !credentialBusy, hasCredentials else { return }
        active = true; connected = false; muted = false; status = "正在连接…"
        captions = VoiceTranscript(); turns = []; pendingInput = VoicePendingInput()
        startupInstant = .now; startupTimings = [:]
        let token = UUID(); epoch = token
        onChange?()
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, epoch == token, active else { return }
            if !connected { fail(startupTimeoutFailure); return }
            try? await Task.sleep(for: .seconds(555))
            guard epoch == token, active else { return }
            status = "对话已到时，请重新开始"; stop(keepingStatus: true)
        }
        startupTask = Task { @MainActor [weak self] in
            guard let self, epoch == token, active else { return }
            do {
                guard let context else {
                    status = "请更新并重新启动 MacTools 后重试"; stop(keepingStatus: true); return
                }
                guard let grant = context.beginSession(excludingPluginIDs: excludedPluginIDs) else {
                    status = "请更新并重新启动 MacTools 后重试"; stop(keepingStatus: true); return
                }
                sessionProviders = context.providers().filter { !excludedPluginIDs.contains($0.id) }
                tools = VoiceTools(context: context, sessionID: grant)
                tools?.onActivity = { [weak self] title in self?.activity = title }
                startupTimeoutFailure = .credentials
                let key = try await credentials.loadForConversation()
                guard epoch == token, active else { return }
                recordStartup("credentials")
                startupTimeoutFailure = .microphone
                status = "正在准备麦克风…"
                let granted = await requestMicrophone()
                guard epoch == token, active else { return }
                guard granted else { throw VoiceFailure.microphone }
                var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let socket = network.webSocketTask(with: request)
                socket.maximumMessageSize = 2_000_000
                self.socket = socket; socket.resume()
                // TLS/session setup overlaps local audio startup. Speech remains bounded in
                // memory until session.started, then one audio task drains it in order.
                let stream = try audio.start()
                capturing = true; recordStartup("audioReady")
                startupTimeoutFailure = .connection
                status = "正在连接，可以开始说话"
                consumeAudio(stream, token: token)
                receiveTask = Task { @MainActor [weak self] in await self?.receive(token: token) }
                try await send(["type": "session.start", "session": VoiceTools.configuration], token: token)
            } catch { if epoch == token { fail(error) } }
        }
    }

    func toggleMute() {
        guard capturing else { return }
        muted.toggle()
        if muted { pendingInput = VoicePendingInput(); inputLevels = Array(repeating: 0, count: 24) }
    }
    func testSpeaker() { NSSound(named: "Glass")?.play() }

    func stop(keepingStatus: Bool = false) {
        epoch = UUID(); active = false; connected = false; capturing = false; muted = false; speaking = false; activity = nil; startupTimeoutFailure = .connection
        pendingInput = VoicePendingInput()
        inputLevels = Array(repeating: 0, count: 24); outputLevels = Array(repeating: 0, count: 24)
        tools?.stop(); tools = nil
        audio.stop()
        startupTask?.cancel(); startupTask = nil
        receiveTask?.cancel(); receiveTask = nil
        audioTask?.cancel(); audioTask = nil
        toolTask?.cancel(); toolTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        calls.removeAll(); delegations.removeAll(); handled.removeAll(); toolQueue.removeAll()
        let old = socket; socket = nil
        // Capture and host authorization end immediately; socket teardown has a bounded grace period.
        if let old {
            Task {
                try? await old.send(.string("{\"type\":\"session.close\"}"))
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                old.cancel(with: .normalClosure, reason: nil)
            }
        }
        if !keepingStatus { status = "对话已结束" }
        onChange?()
    }

    private func fail(_ error: Error) {
        if (socket?.response as? HTTPURLResponse)?.statusCode == 401 {
            status = "API 密钥未通过验证，请检查后重新保存。"
        } else {
            status = switch error as? VoiceFailure {
            case .credentials: "无法读取密钥，请检查 API 密钥设置。"
            case .microphone: "请在系统设置中允许麦克风访问"
            case .audio: "音频设备不可用，请检查麦克风和扬声器"
            case .overloaded: "音频传输跟不上，已结束对话"
            default: "连接已中断，请检查网络、API 额度和模型权限后重试"
            }
        }
        stop(keepingStatus: true)
    }

    private func send(_ object: [String: Any], token: UUID) async throws {
        guard epoch == token, active, let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { throw VoiceFailure.connection }
        try await socket.send(.string(string))
    }

    private func recordStartup(_ stage: String) {
        let elapsed = startupInstant.duration(to: .now).components
        startupTimings[stage] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private func consumeAudio(_ stream: AsyncThrowingStream<Data, Error>, token: UUID) {
        audioTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await data in stream {
                    guard epoch == token, active else { return }
                    inputLevels = Array(inputLevels.dropFirst()) + [muted ? 0 : VoiceAudioMeter.level(data)]
                    let input = muted ? Data(count: data.count) : data
                    if !connected { try pendingInput.append(input); continue }
                    let queued = pendingInput.take()
                    for chunk in queued {
                        let buffered = muted ? Data(count: chunk.count) : chunk
                        try await send(["type": "session.input_audio.append", "audio": buffered.base64EncodedString()], token: token)
                    }
                    let current = muted ? Data(count: input.count) : input
                    try await send(["type": "session.input_audio.append", "audio": current.base64EncodedString()], token: token)
                }
            } catch { if epoch == token, active { fail(error) } }
        }
    }

    private func receive(token: UUID) async {
        do {
            while epoch == token, active, let socket {
                let message = try await socket.receive()
                guard epoch == token, active else { return }
                let data: Data
                switch message { case let .data(value): data = value; case let .string(value): data = Data(value.utf8); @unknown default: throw VoiceFailure.protocolError }
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceFailure.protocolError }
                try await handle(event, token: token)
            }
        } catch { if epoch == token, active { fail(error) } }
    }

    private func handle(_ event: [String: Any], token: UUID) async throws {
        switch event["type"] as? String {
        case "session.started":
            guard !connected else { return }
            recordStartup("connected")
            connected = true; status = "正在聆听"; onChange?()
        case "session.output_audio.delta":
            if let encoded = event["delta"] as? String, let data = Data(base64Encoded: encoded) { try audio.play(data) }
        case "session.input_transcript.delta", "session.output_transcript.delta":
            if let delta = event["delta"] as? String {
                captions.append(delta, speaker: event["type"] as? String == "session.input_transcript.delta" ? .user : .assistant,
                                start: event["start_ms"] as? Int, end: event["end_ms"] as? Int)
                turns = captions.turns
            }
        case "session.closed": stop()
        case "error", "session.error": throw VoiceFailure.connection
        case "response.event":
            guard let nested = event["event"] as? [String: Any] else { return }
            let delegation = event["delegation_id"] as? String ?? ""
            if nested["type"] as? String == "response.created", let response = nested["response"] as? [String: Any], let id = response["id"] as? String {
                guard calls.count < 32 else { throw VoiceFailure.overloaded }
                delegations[delegation] = id; calls[id] = []
            } else if nested["type"] as? String == "response.output_item.done",
                      let item = nested["item"] as? [String: Any], item["type"] as? String == "function_call",
                      let id = nested["response_id"] as? String ?? delegations[delegation],
                      let callID = item["call_id"] as? String, let name = item["name"] as? String, let args = item["arguments"] as? String {
                guard (calls[id]?.count ?? 0) < 8, args.utf8.count < 4096 else { throw VoiceFailure.overloaded }
                calls[id, default: []].append(["call_id": callID, "name": name, "arguments": args])
            } else if nested["type"] as? String == "response.completed",
                      let response = nested["response"] as? [String: Any], let id = response["id"] as? String {
                let pending = calls.removeValue(forKey: id) ?? []
                delegations = delegations.filter { $0.value != id }
                guard !pending.isEmpty else { return }
                guard toolQueue.count < 8 else { throw VoiceFailure.overloaded }
                toolQueue.append((id, pending)); processTools(token: token)
            } else if ["response.failed", "response.incomplete"].contains(nested["type"] as? String ?? "") {
                throw VoiceFailure.connection
            }
        default: break
        }
    }

    private func processTools(token: UUID) {
        guard toolTask == nil else { return }
        toolTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if epoch == token { toolTask = nil } }
            do {
                while !toolQueue.isEmpty, epoch == token, active {
                    let (_, pending) = toolQueue.removeFirst()
                    for call in pending {
                        guard epoch == token, active, let tools, let id = call["call_id"], let name = call["name"], let args = call["arguments"] else { return }
                        // Replayed calls never execute a second hardware action.
                        guard !handled.contains(id), handled.count < 256 else { throw VoiceFailure.protocolError }
                        handled.insert(id)
                        let result = await tools.call(name: name, arguments: args)
                        try await send(["type": "response.item.create", "item": ["type": "function_call_output", "call_id": id, "output": result]], token: token)
                    }
                    try await send(["type": "response.create"], token: token)
                }
            } catch { if epoch == token, active { fail(error) } }
        }
    }
}
