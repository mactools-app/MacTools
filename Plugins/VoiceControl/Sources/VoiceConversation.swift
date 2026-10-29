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
    @Published private(set) var transcript = ""
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
    var context: PluginVoiceControlHostContext? { didSet { if active { stop() } } }
    var onChange: (() -> Void)?
    let localization: PluginLocalization
    private let credentials: VoiceCredentialConfiguration
    private let audio: any VoiceAudioIO
    private let requestMicrophone: () async -> Bool
    private var socket: URLSessionWebSocketTask?
    private var network: URLSession?
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
    private var captionRole: String?

    init(context: PluginRuntimeContext, audio: any VoiceAudioIO = VoiceAudio(),
         requestMicrophone: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) },
         secrets: any VoiceSecretStoring = VoiceSecretStore()) {
        self.audio = audio; self.requestMicrophone = requestMicrophone
        let credentials = VoiceCredentialConfiguration(storage: context.storage, secrets: secrets)
        self.credentials = credentials
        credentialPath = credentials.path; hasCredentials = credentials.isConfigured
        credentialStatus = Self.credentialStatus(for: credentials)
        localization = PluginLocalization(bundle: context.resourceBundle)
        audio.observePlayback { [weak self] playing in self?.speaking = playing && self?.active == true }
    }
    func text(_ value: String) -> String { localization.string(value, defaultValue: value) }
    #if DEBUG
    func chooseCredentials() {
        guard !active else { return }
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

    func saveKey(_ key: String) -> Bool {
        guard !active else { return false }
        do {
            try credentials.save(key); refreshCredentials()
            credentialMessage = "密钥已保存，开始对话时将验证 API 访问权限。"
            return true
        } catch {
            credentialError = true
            if case VoiceFailure.credentials = error { credentialMessage = "密钥格式不正确，请检查后重试。" }
            else { credentialMessage = "无法保存密钥，请检查钥匙串访问权限。" }
            return false
        }
    }

    func forgetKey() {
        guard !active else { return }
        do { try credentials.forget(); refreshCredentials() }
        catch { credentialError = true; credentialMessage = "无法移除密钥，请检查钥匙串访问权限。" }
    }

    func start() {
        guard !active, hasCredentials else { return }
        active = true; connected = false; muted = false; transcript = ""; status = "正在连接…"
        captionRole = nil
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
                startupTimeoutFailure = .microphone
                let granted = await requestMicrophone()
                guard epoch == token, active else { return }
                guard granted else { throw VoiceFailure.microphone }
                startupTimeoutFailure = .connection
                var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.urlCache = nil
                let network = URLSession(configuration: configuration)
                self.network = network
                let socket = network.webSocketTask(with: request)
                socket.maximumMessageSize = 2_000_000
                self.socket = socket; socket.resume()
                try await send(["type": "session.start", "session": VoiceTools.configuration], token: token)
                guard epoch == token, active else { return }
                receiveTask = Task { @MainActor [weak self] in await self?.receive(token: token) }
            } catch { if epoch == token { fail(error) } }
        }
    }

    func toggleMute() { guard connected else { return }; muted.toggle() }
    func testSpeaker() { NSSound(named: "Glass")?.play() }

    func stop(keepingStatus: Bool = false) {
        epoch = UUID(); active = false; connected = false; muted = false; speaking = false; activity = nil; startupTimeoutFailure = .connection
        tools?.stop(); tools = nil
        audio.stop()
        startupTask?.cancel(); startupTask = nil
        receiveTask?.cancel(); receiveTask = nil
        audioTask?.cancel(); audioTask = nil
        toolTask?.cancel(); toolTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        calls.removeAll(); delegations.removeAll(); handled.removeAll(); toolQueue.removeAll()
        let old = socket; socket = nil
        let oldNetwork = network; network = nil
        // Capture and host authorization end immediately; socket teardown has a bounded grace period.
        if let old {
            Task {
                try? await old.send(.string("{\"type\":\"session.close\"}"))
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                old.cancel(with: .normalClosure, reason: nil); oldNetwork?.invalidateAndCancel()
            }
        } else { oldNetwork?.invalidateAndCancel() }
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
            let stream = try audio.start()
            connected = true; status = "正在聆听"; onChange?()
            audioTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await data in stream {
                        guard epoch == token, active else { return }
                        let input = muted ? Data(count: data.count) : data
                        try await send(["type": "session.input_audio.append", "audio": input.base64EncodedString()], token: token)
                    }
                } catch { if epoch == token, active { fail(error) } }
            }
        case "session.output_audio.delta":
            if let encoded = event["delta"] as? String, let data = Data(base64Encoded: encoded) { try audio.play(data) }
        case "session.input_transcript.delta", "session.output_transcript.delta":
            if let delta = event["delta"] as? String {
                let role = event["type"] as? String
                if role != captionRole {
                    transcript += transcript.isEmpty ? "" : "\n\n"
                    transcript += role == "session.input_transcript.delta" ? text("你：") : text("助手：")
                    captionRole = role
                }
                transcript += delta
                if transcript.count > 12_000 { transcript = String(transcript.suffix(10_000)) }
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
