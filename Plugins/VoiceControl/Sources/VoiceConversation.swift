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
    @Published var featureAccess = VoiceFeatureAccess()
    var excludedPluginIDs: Set<String> {
        get { featureAccess.excludedPluginIDs }
        set { featureAccess.excludedPluginIDs = newValue }
    }
    private(set) var sessionProviders: [PluginVoiceProvider] = []
    var allowedProviders: [PluginVoiceProvider] {
        active ? sessionProviders : context?.providers().filter { featureAccess.isAllowed($0.id) } ?? []
    }
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
    private var socket: (any VoiceConnection)?
    private let makeConnection: ((URLRequest) -> any VoiceConnection)?
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
    private var idleTask: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private(set) var sessionMetrics = VoiceSessionMetrics(id: UUID())
    private(set) var recentSessionMetrics: [VoiceSessionMetrics] = []
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
         secrets: any VoiceSecretStoring = VoiceSecretStore(),
         makeConnection: ((URLRequest) -> any VoiceConnection)? = nil) {
        self.audio = audio; self.requestMicrophone = requestMicrophone; self.makeConnection = makeConnection
        let credentials = VoiceCredentialConfiguration(storage: context.storage, secrets: secrets)
        self.credentials = credentials
        hasCredentials = credentials.isConfigured
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
    private static func credentialStatus(for credentials: VoiceCredentialConfiguration) -> String {
        guard credentials.isConfigured else { return "请添加你自己的 OpenAI API 密钥" }
        return switch credentials.source {
        case .keychain: "已保存在本机钥匙串"
        case .none: "请添加你自己的 OpenAI API 密钥"
        }
    }

    private func refreshCredentials() {
        hasCredentials = credentials.isConfigured
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
        sessionMetrics = VoiceSessionMetrics(id: token); lastActivity = .now
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
                let providers = context.providers()
                let exclusions = featureAccess.exclusions(for: Set(providers.map(\.id)))
                guard let grant = context.beginSession(excludingPluginIDs: exclusions) else {
                    status = "请更新并重新启动 MacTools 后重试"; stop(keepingStatus: true); return
                }
                sessionProviders = providers.filter { featureAccess.isAllowed($0.id) }
                tools = VoiceTools(context: context, sessionID: grant)
                tools?.onActivity = { [weak self] title in
                    guard let self, epoch == token, active else { return }
                    activity = title
                }
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
                let socket = makeConnection?(request) ?? VoiceWebSocketConnection(network: network, request: request)
                self.socket = socket; socket.resume()
                // TLS/session setup overlaps local audio startup. Speech remains bounded in
                // memory until session.started, then one audio task drains it in order.
                let stream = try audio.start()
                capturing = true; recordStartup("audioReady")
                startupTimeoutFailure = .connection
                status = "正在连接，可以开始说话"
                consumeAudio(stream, token: token)
                receiveTask = Task { @MainActor [weak self] in await self?.receive(token: token, socket: socket) }
                try await send(["type": "session.start", "session": VoiceTools.configuration(providers: sessionProviders)], token: token)
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
        if active {
            recentSessionMetrics.append(sessionMetrics)
            recentSessionMetrics = Array(recentSessionMetrics.suffix(4))
        }
        epoch = UUID(); active = false; connected = false; capturing = false; muted = false; speaking = false; activity = nil; startupTimeoutFailure = .connection
        pendingInput = VoicePendingInput()
        inputLevels = Array(repeating: 0, count: 24); outputLevels = Array(repeating: 0, count: 24)
        tools?.stop(); tools = nil
        audio.stop()
        startupTask?.cancel(); startupTask = nil
        let oldReceiver = receiveTask; receiveTask = nil
        audioTask?.cancel(); audioTask = nil
        toolTask?.cancel(); toolTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        idleTask?.cancel(); idleTask = nil
        calls.removeAll(); delegations.removeAll(); handled.removeAll(); toolQueue.removeAll()
        let old = socket; socket = nil
        // Capture and grants end immediately. The old receiver drains only usage while
        // waiting briefly for session.closed; it cannot play audio or run another tool.
        if let old, !sessionMetrics.finalized {
            Task { try? await old.send(["type": "session.close"]) }
            Task {
                try? await Task.sleep(for: .milliseconds(1_500))
                old.cancel(); oldReceiver?.cancel()
            }
        } else { old?.cancel(); oldReceiver?.cancel() }
        if !keepingStatus { status = "对话已结束" }
        onChange?()
    }

    private func fail(_ error: Error) {
        if let service = error as? VoiceServiceFailure {
            status = service.message
        } else if let httpStatus = socket?.httpStatus, [401, 403, 404, 429].contains(httpStatus) {
            status = VoiceServiceFailure.classify(nil, httpStatus: httpStatus).message
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
        guard epoch == token, active, let socket else { throw VoiceFailure.connection }
        try await socket.send(object)
    }

    private func recordStartup(_ stage: String) {
        guard startupTimings[stage] == nil else { return }
        let elapsed = startupInstant.duration(to: .now).components
        startupTimings[stage] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private func consumeAudio(_ stream: AsyncThrowingStream<Data, Error>, token: UUID) {
        audioTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await data in stream {
                    guard epoch == token, active else { return }
                    let level = muted ? Float.zero : VoiceAudioMeter.level(data)
                    inputLevels = Array(inputLevels.dropFirst()) + [level]
                    let input = muted ? Data(count: data.count) : data
                    if !connected { try pendingInput.append(input); continue }
                    if level > 0 { recordStartup("firstInputAudio") }
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

    private func receive(token: UUID, socket: any VoiceConnection) async {
        do {
            while !Task.isCancelled {
                let event = try await socket.receive()
                if epoch == token, active {
                    sessionMetrics.observe(event)
                    do { try await handle(event, token: token) }
                    catch {
                        // A rejected service command can leave a healthy socket. Stop
                        // locally, then keep this receiver alive for the close accounting.
                        fail(error)
                    }
                } else if let index = recentSessionMetrics.firstIndex(where: { $0.id == token }) {
                    recentSessionMetrics[index].observe(event)
                }
                if event["type"] as? String == "session.closed" { socket.cancel(); return }
            }
        } catch { if epoch == token, active { fail(error) } }
    }

    func stopIfIdle(at now: ContinuousClock.Instant = .now) {
        guard active, connected, toolTask == nil,
              lastActivity.duration(to: now) >= .seconds(120) else { return }
        status = "一段时间没有活动，对话已结束。重新开始即可继续。"
        stop(keepingStatus: true)
    }

    private func handle(_ event: [String: Any], token: UUID) async throws {
        switch event["type"] as? String {
        case "session.started":
            guard !connected else { return }
            recordStartup("connected")
            connected = true; status = "正在聆听"; lastActivity = .now; onChange?()
            idleTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, epoch == token, active else { return }
                    stopIfIdle()
                }
            }
        case "session.output_audio.delta":
            if let encoded = event["delta"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty {
                guard data.count <= 480_000, data.count.isMultiple(of: 2) else { throw VoiceFailure.protocolError }
                recordStartup("firstOutputAudio")
                if VoiceAudioMeter.level(data) > 0.05 {
                    recordStartup("firstOutputSpeech"); lastActivity = .now
                }
                try audio.play(data)
            }
        case "session.input_transcript.delta", "session.output_transcript.delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                lastActivity = .now
                recordStartup(event["type"] as? String == "session.input_transcript.delta" ? "firstInputTranscript" : "firstOutputTranscript")
                captions.append(delta, speaker: event["type"] as? String == "session.input_transcript.delta" ? .user : .assistant,
                                start: event["start_ms"] as? Int, end: event["end_ms"] as? Int)
                turns = captions.turns
            }
        case "session.closed":
            switch event["reason"] as? String {
            case "expired": status = "对话已到时，请重新开始"
            case "content": status = "语音服务已结束此对话，请重新开始。"
            case "connection_lost": status = VoiceServiceFailure.connection.message
            default: status = "对话已结束"
            }
            stop(keepingStatus: true)
        case "error", "session.error": throw VoiceServiceFailure.classify(event["error"] as? [String: Any])
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
                let response = nested["response"] as? [String: Any]
                throw VoiceServiceFailure.classify(response?["error"] as? [String: Any])
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
